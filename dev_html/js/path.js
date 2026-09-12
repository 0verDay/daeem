/**
 * path.js —— 四连通网格通行判定 + A* 寻路 + 直线拉平
 *
 * 通行规则集中在这里：
 *   - 地形：山完全阻挡，草地/森林可通行（森林减速）
 *   - 建筑：城墙对“己方单位”放行、对“敌方单位”阻挡（城墙填充整个地块）
 *           大本营/箭塔等占位建筑：单位不能站上去（点击它们时自动停在最近的可站格）
 *
 * 寻路分两步（这样单位在开阔地带走直线，而不是沿格心走阶梯）：
 *   1. findPath()  —— 四连通 A*，只负责回答“绕开山/城墙该走哪几个格子”；
 *   2. smoothPath()—— 把 A* 的折线拉直：每次贪心跳到“直线可达”的最远点，
 *                     直线是否可达由 segmentClear() 逐格判定。
 */

import { DIRS4, MinHeap, inBounds, idx } from './util.js';
import { CONFIG } from './config.js';

/** 地形：能否通行 */
export function terrainWalkable(terrain, x, y) {
  const t = terrain.get(x, y);
  return t !== 'mountain';
}

/** 地形：移动消耗倍率 */
export function terrainCost(terrain, x, y) {
  const t = terrain.get(x, y);
  if (t === 'forest') return 1 / CONFIG.unit.forestMult; // 森林更“贵”
  return 1;
}

/**
 * 某地块对指定阵营是否可通行
 * @param {object} state 游戏状态（需要 state.terrain / state.buildings）
 * @param {number} x
 * @param {number} y
 * @param {string} faction 'player' | 'enemy'
 */
export function passable(state, x, y, faction) {
  if (!inBounds(state.terrain, x, y)) return false;
  if (!terrainWalkable(state.terrain, x, y)) return false;
  const b = state.buildings.get(x, y);
  if (b) return b.blocks(faction) === false; // 城墙对己方放行、对敌方阻挡
  return true;
}

/** 是否被建筑占据（用于建造校验） */
export function occupied(state, x, y) {
  return !!state.buildings.get(x, y);
}

/**
 * A* 寻路（四连通）
 * @returns {Array<{x:number,y:number}>|null} 不含起点、含终点的地块列表
 */
export function findPath(state, from, to, faction) {
  const { cols, rows } = state.terrain;
  if (!inBounds(state.terrain, from.x, from.y) || !inBounds(state.terrain, to.x, to.y)) return null;
  if (from.x === to.x && from.y === to.y) return [];
  if (!passable(state, to.x, to.y, faction)) return null;

  const startIdx = idx(state.terrain, from.x, from.y);
  const goalIdx = idx(state.terrain, to.x, to.y);
  const gScore = new Map([[startIdx, 0]]);
  const cameFrom = new Map();
  const closed = new Set();
  const open = new MinHeap((n) => n.f);
  const h = (x, y) => Math.abs(x - to.x) + Math.abs(y - to.y);

  open.push({ i: startIdx, x: from.x, y: from.y, g: 0, f: h(from.x, from.y) });

  while (open.size > 0) {
    const cur = open.pop();
    if (cur.i === goalIdx) {
      // 回溯
      const out = [];
      let k = goalIdx;
      while (k !== startIdx) {
        out.push({ x: k % cols, y: Math.floor(k / cols) });
        k = cameFrom.get(k);
        if (k === undefined) return null;
      }
      out.reverse();
      return out;
    }
    if (closed.has(cur.i)) continue;
    closed.add(cur.i);

    for (const d of DIRS4) {
      const nx = cur.x + d.dx;
      const ny = cur.y + d.dy;
      if (!inBounds(state.terrain, nx, ny)) continue;
      // 终点允许是“不可站立但可通行”的格子吗？这里要求完全可通行
      if (!passable(state, nx, ny, faction)) continue;
      const ni = idx(state.terrain, nx, ny);
      if (closed.has(ni)) continue;
      const step = terrainCost(state.terrain, nx, ny);
      const ng = cur.g + step;
      const old = gScore.get(ni);
      if (old === undefined || ng < old - 1e-9) {
        gScore.set(ni, ng);
        cameFrom.set(ni, cur.i);
        open.push({ i: ni, x: nx, y: ny, g: ng, f: ng + h(nx, ny) });
      }
    }
  }
  return null;
}

/**
 * 从起点做一次“按阵营通行规则”的 BFS，返回所有**走得到**的地块索引集合。
 * 与 floodFill 的区别：这里会用 passable()，也就是把城墙 / 建筑一起算进去。
 *
 * 用途：判断“某格是不是我真能走到”（例如挑拆墙目标、挑点击不可通行处时的落脚点）。
 */
export function reachableTiles(state, from, faction) {
  const seen = new Set();
  if (!inBounds(state.terrain, from.x, from.y)) return seen;
  // 起点自己也算在内：单位可能站在后来被建筑占住的格子上，得允许它走出来
  seen.add(idx(state.terrain, from.x, from.y));
  const queue = [from];
  while (queue.length) {
    const c = queue.shift();
    for (const d of DIRS4) {
      const nx = c.x + d.dx, ny = c.y + d.dy;
      if (!inBounds(state.terrain, nx, ny)) continue;
      const ni = idx(state.terrain, nx, ny);
      if (seen.has(ni)) continue;
      if (!passable(state, nx, ny, faction)) continue;
      seen.add(ni);
      queue.push({ x: nx, y: ny });
    }
  }
  return seen;
}

/**
 * 找到一个“离目标最近、**而且从 from 真的走得到**”的格子（BFS 扩散）
 * 用途：右键点到城墙/大本营/山上时，走到它旁边。
 *
 * ⚠️ 必须检查可达性：BFS 是从目标往外扩的，第一圈“可通行”的格子很可能是
 *    墙 / 山**另一侧**的格子。旧实现直接返回它，于是 findPath() 必然失败、
 *    调用方以为“哪都去不了”—— 这正是“敌人被城墙拦断后站在出生点发呆”的根因之一。
 */
export function nearestReachable(state, from, target, faction, maxRadius = 12) {
  if (passable(state, target.x, target.y, faction)) return { x: target.x, y: target.y };
  const region = reachableTiles(state, from, faction);
  const seen = new Set([idx(state.terrain, target.x, target.y)]);
  let frontier = [{ x: target.x, y: target.y }];
  for (let r = 0; r < maxRadius; r++) {
    const next = [];
    for (const c of frontier) {
      for (const d of DIRS4) {
        const nx = c.x + d.dx, ny = c.y + d.dy;
        if (!inBounds(state.terrain, nx, ny)) continue;
        const ni = idx(state.terrain, nx, ny);
        if (seen.has(ni)) continue;
        seen.add(ni);
        if (passable(state, nx, ny, faction)) {
          if (region.has(ni)) return { x: nx, y: ny };   // ★ 只认自己走得到的
          continue;                                      // 墙那一边的格子：当不了终点
        }
        next.push({ x: nx, y: ny });                     // 继续穿过障碍往外找
      }
    }
    frontier = next;
    if (frontier.length === 0) break;
  }
  return null;
}

/**
 * 线段是否“全程可通行”（直线移动的核心判定，单位是**像素**）。
 *
 * 用超覆盖 DDA（Amanatides & Woo 体素遍历的加强版）枚举线段“擦到”的每一个地块，
 * 包括只与线段相交于一个角的格子，所以直线不会从两座山 / 两段城墙的夹缝里穿过去。
 *
 * 注意：只检查线段**进入**的格子，起点所在格不检查 —— 单位可能正站在之后被
 *       建筑占住的格子上（例如脚下被盖了箭塔），此时仍必须允许它走出来。
 *
 * @returns {boolean} true = 这条直线可以走
 */
export function segmentClear(state, ax, ay, bx, by, faction) {
  const cell = CONFIG.cell;
  const x0 = ax / cell, y0 = ay / cell;
  const dx = bx / cell - x0, dy = by / cell - y0;
  let tx = Math.floor(x0), ty = Math.floor(y0);

  const stepX = dx > 0 ? 1 : -1;
  const stepY = dy > 0 ? 1 : -1;
  const tDeltaX = dx !== 0 ? Math.abs(1 / dx) : Infinity;
  const tDeltaY = dy !== 0 ? Math.abs(1 / dy) : Infinity;
  let tMaxX = dx !== 0 ? (dx > 0 ? tx + 1 - x0 : x0 - tx) * tDeltaX : Infinity;
  let tMaxY = dy !== 0 ? (dy > 0 ? ty + 1 - y0 : y0 - ty) * tDeltaY : Infinity;

  let guard = 0;
  while (guard++ < 8192) {
    if (tMaxX > 1 && tMaxY > 1) return true;        // 线段已经走完
    if (tMaxX < tMaxY) {
      tx += stepX; tMaxX += tDeltaX;
      if (!passable(state, tx, ty, faction)) return false;
    } else if (tMaxY < tMaxX) {
      ty += stepY; tMaxY += tDeltaY;
      if (!passable(state, tx, ty, faction)) return false;
    } else {
      // 正好穿过格点：对角两侧都得让得开，才允许走这条直线
      if (!passable(state, tx + stepX, ty, faction)) return false;
      if (!passable(state, tx, ty + stepY, faction)) return false;
      tx += stepX; ty += stepY; tMaxX += tDeltaX; tMaxY += tDeltaY;
      if (!passable(state, tx, ty, faction)) return false;
    }
  }
  return false;
}

/**
 * 把像素折线“拉直”（string pulling / 漏斗算法的贪心版）。
 *
 * 从第一个点出发，每次找“直线可达的最远点”作为下一个拐点；
 * 于是开阔地带会退化成一条直线，遇到山/城墙才保留必要的拐点。
 * 因为每一段都用 segmentClear() 验证过，所以拉直不会让单位穿墙或翻山。
 *
 * 输入与输出都是**像素坐标**；输出长度 ≤ 输入长度，且首尾点不变。
 */
export function smoothPath(state, points, faction) {
  if (!points || points.length <= 2) return (points || []).slice();
  const out = [points[0]];
  let i = 0;
  while (i < points.length - 1) {
    let j = points.length - 1;
    while (j > i + 1 && !segmentClear(state, points[i].x, points[i].y, points[j].x, points[j].y, faction)) j--;
    out.push(points[j]);
    i = j;
  }
  return out;
}

/**
 * 找出“挡住 from → to 这条路”的建筑（默认城墙）里，离 to 最近的那一个。
 *
 * 两个条件缺一不可：
 *   1. 建筑必须挨着“from 这边真的走得到”的区域（否则拆了也过不去）；
 *   2. 在候选里挑离 to 最近的 —— 这样拆穿一段后可达区域扩大，下一次自然接着往目标方向拆。
 *
 * 用途：敌人被城墙拦断时决定先拆哪一段（见 main.js 的 updateEnemies）。
 * 注意旧实现是“在单位身边 2 格内找墙”，玩家用一整条墙拦断路线时根本找不到，敌人会发呆。
 */
export function findBlockingWallToward(state, from, to, faction, type = 'wall') {
  const region = reachableTiles(state, from, faction);
  let best = null;
  let bestD = Infinity;
  for (const b of state.buildingList) {
    if (!b.alive || b.type !== type || b.owner === faction) continue;
    let touches = false;
    for (const d of DIRS4) {
      const nx = b.tx + d.dx, ny = b.ty + d.dy;
      if (!inBounds(state.terrain, nx, ny)) continue;
      if (region.has(idx(state.terrain, nx, ny))) { touches = true; break; }
    }
    if (!touches) continue;
    const d = Math.abs(b.tx - to.x) + Math.abs(b.ty - to.y);
    if (d < bestD) { bestD = d; best = b; }
  }
  return best;
}

/** 从起点做 BFS，返回所有连通格（用于地图连通性修正） */
export function floodFill(state, start) {
  const seen = new Set();
  const queue = [start];
  seen.add(idx(state.terrain, start.x, start.y));
  while (queue.length) {
    const c = queue.shift();
    for (const d of DIRS4) {
      const nx = c.x + d.dx, ny = c.y + d.dy;
      if (!inBounds(state.terrain, nx, ny)) continue;
      const ni = idx(state.terrain, nx, ny);
      if (seen.has(ni)) continue;
      if (!terrainWalkable(state.terrain, nx, ny)) continue;
      seen.add(ni);
      queue.push({ x: nx, y: ny });
    }
  }
  return seen;
}
