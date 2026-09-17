/**
 * map.js —— 固定手写地图（24 × 16）
 *
 * 图例：
 *   '.' 草地（可通行，正常速度）
 *   '^' 森林（可通行，速度 × forestMult，用于验证地形对移动的影响）
 *   '#' 山地（不可通行）
 *   'B' 大本营（玩家开局自带，占 1 格；不可建造）
 *
 * 说明：地图是给“建筑”设计的，单位与地块不一一对应（多个单位可叠在同一格）。
 *       这里只是原型用的固定地图，后续地图编辑器会替换掉它。
 */

import { Grid } from './util.js';
import { CONFIG } from './config.js';
import { floodFill } from './path.js';
import { idx } from './util.js';

export const MAP_LAYOUT = [
  '........................',
  '........................',
  '........................',
  '....^^.......###########',   // 最后留一格作为北侧隘口
  '....^..........#........',
  '...............#........',
  '...............#........',
  '...............#........',
  '........................',
  '........................',
  '........................',
  '........................',
  '.............^^.........',
  '........................',
  '........................',
  '........................',
];

/** 将领（占位单位）开局站位 —— 单机模式使用，也是 P1 的出生点 */
export const GENERAL_SPAWNS = [
  { x: 8, y: 10 },
  { x: 10, y: 11 },
  { x: 11, y: 9 },
];

/**
 * 多人对战的起点坐标。地图是 24×16，所以这条对角线上两个点关于地图中心对称：
 *   P1 = (4, 4)  —— 左上；P2 = (19, 11) —— 右下
 * 直线距离约 √(15² + 7²) ≈ 16.6 格，双方要走一会儿才会接触。
 */
export const PVP_POINTS = [
  { x: 4, y: 4 },
  { x: 19, y: 11 },
  { x: 4, y: 11 },
  { x: 19, y: 4 },
  { x: 2, y: 8 },
  { x: 21, y: 7 },
  { x: 12, y: 1 },
  { x: 12, y: 14 },
];

/**
 * 取某个地图点位附近**最近的可行走格**。
 *
 * 为什么要做：上面这些点位是写死的，而地图会因地形（山/森林）变化。
 * 直接把大本营放到山上会导致寻路/建造直接坏掉，所以必须找个能站的地方。
 * 从内向外按"切比雪夫环"扩散，第一个可通行格即返回值。
 */
function nearestWalkable(terrain, x, y, maxRadius = 8) {
  const ok = (px, py) => terrain.has(px, py) && terrain.get(px, py) !== 'mountain';
  if (ok(x, y)) return { x, y };
  for (let r = 1; r <= maxRadius; r++) {
    for (let dy = -r; dy <= r; dy++) {
      for (let dx = -r; dx <= r; dx++) {
        if (Math.max(Math.abs(dx), Math.abs(dy)) !== r) continue;
        const px = x + dx, py = y + dy;
        if (ok(px, py)) return { x: px, y: py };
      }
    }
  }
  return null;
}

/**
 * 某一方的出生点：大本营位置 + 3 个将领站位 + 防御阵地（城墙 + 箭塔）。
 *
 * ★ 这是「分阵营对战」的地基。旧实现里双方共用地图中央那一个大本营 ——
 *   客机入场时只是把大本营的 owner 改成了自己，于是两个人挤在同一个基地上，
 *   开局就贴脸。现在每一方有**自己的**基地，关于地图中心对称。
 *
 * @param {object} map      createMap() 的返回值
 * @param {string} faction  阵营（'player' 单机 / 'p1' / 'p2' …）
 * @param {string} primary  主阵营（roster[0]）—— 单机与 P1 都用原版点位，保证兼容
 */
export function spawnLayoutFor(map, faction, primary) {
  const terrain = map.terrain;
  const isPrimary = !faction || faction === primary || faction === 'player';

  if (isPrimary) {
    // 单机 / P1：沿用原版地图中央的大本营与将领站位（v0.3 行为逐位不变）
    const base = nearestWalkable(terrain, map.base.x, map.base.y) || map.base;
    const spawns = GENERAL_SPAWNS.map((s) => nearestWalkable(terrain, s.x, s.y) || base);
    return { base, spawns, defenses: [] };
  }

  // 其他玩家：从 PVP_POINTS 里按「阵营序号」稳定取一个点（不依赖 map.base，避免双方重合）
  const n = parseInt(String(faction).replace(/^p/, ''), 10) || 2;
  const p = PVP_POINTS[(n - 1) % PVP_POINTS.length];
  const base = nearestWalkable(terrain, p.x, p.y) || map.base;

  // 将领围着大本营站（不挤在同一格）
  const ring = [[0, 1], [1, 0], [-1, 0], [0, -1], [1, 1], [-1, -1]];
  const spawns = [];
  for (let i = 0; i < 3; i++) {
    const o = ring[i % ring.length];
    spawns.push(nearestWalkable(terrain, base.x + o[0], base.y + o[1]) || base);
  }

  // 防御阵地：大本营正上方一段城墙 + 旁边一座箭塔（让开局有点"阵地感"，也顺带
  // 验证「城墙/箭塔按阵营归属」在多玩家下成立）。地形不允许时就少建几个。
  const defenses = [];
  const wallAt = { x: base.x, y: base.y - 1 };
  if (terrain.has(wallAt.x, wallAt.y) && terrain.get(wallAt.x, wallAt.y) !== 'mountain') {
    defenses.push({ type: 'wall', x: wallAt.x, y: wallAt.y });
  }
  const towerAt = { x: base.x + 2, y: base.y };
  if (terrain.has(towerAt.x, towerAt.y) && terrain.get(towerAt.x, towerAt.y) !== 'mountain') {
    defenses.push({ type: 'tower', x: towerAt.x, y: towerAt.y });
  }

  return { base, spawns, defenses };
}

export function createMap() {
  const cols = CONFIG.mapCols;
  const rows = CONFIG.mapRows;
  const terrain = new Grid(cols, rows, 'grass');
  let base = null;

  for (let y = 0; y < rows; y++) {
    const row = MAP_LAYOUT[y] || '';
    for (let x = 0; x < cols; x++) {
      const ch = row[x] || '.';
      if (ch === '#') terrain.set(x, y, 'mountain');
      else if (ch === '^') terrain.set(x, y, 'forest');
      else if (ch === 'B') {
        terrain.set(x, y, 'grass');
        base = { x, y };
      } else terrain.set(x, y, 'grass');
    }
  }

  if (!base) base = { x: Math.floor(cols / 2), y: Math.floor(rows / 2) };

  // 连通性修正：把从大本营四连通到达不了的“可通行但被隔离”的格子变成山，
  // 保证寻路永远不会出现“看着能走其实走不到”的情况。
  const reachable = floodFill({ terrain }, base);
  let sealed = 0;
  terrain.forEach((x, y, t) => {
    if (t === 'mountain') return;
    if (!reachable.has(idx(terrain, x, y))) {
      terrain.set(x, y, 'mountain');
      sealed++;
    }
  });

  return { terrain, base, cols, rows, sealedIslands: sealed };
}
