/**
 * tools/smoke-test.mjs —— 无头冒烟测试（不需要浏览器）
 * 运行：node tools/smoke-test.mjs
 *
 * 特点：**直接 import js/ 下的真实模块**（不像 smoke_test.py 那样是 Python 镜像），
 *       所以移动 / 寻路 / 战斗这些逻辑改错了这里立刻会红。
 *
 * 覆盖：
 *   1. 地图是 24×16 四连通、无孤立可通行区域
 *   2. 四连通 A* 寻路：绕过山体、到达/拒绝不可达点
 *   3. 地块唯一建筑、城墙己方穿过 / 敌方阻挡
 *   4. 箭塔：单体伤害、射程、冷却
 *   5. 区块占领与资源增长
 *   6. 移动：能走直线就走直线（路径拉直）、遇到山墙才拐弯、逐帧位移均匀
 *   7. 战斗与警戒：静止索敌 → 靠近 → 开火 → 冷却 → 击杀；移动中不索敌；追击有上限
 *   8. 敌人 AI：把地块坐标当像素用的回归测试（旧版会一路走到地图左上角）
 */

import { Grid, tileCenter, idx } from '../js/util.js';
import { CONFIG } from '../js/config.js';
import { createMap, GENERAL_SPAWNS } from '../js/map.js';
import { createZoneSystem, updateZones, ownedTileCount, refreshBuildingOwnership, zoneAt } from '../js/zone.js';
import { Building, updateTowers, removeBuilding, updateBuildingEffects } from '../js/building.js';
import { Unit, createGenerals, findOpenTileNear } from '../js/unit.js';
import { findPath, passable, nearestReachable, occupied, segmentClear, smoothPath, reachableTiles, findBlockingWallToward } from '../js/path.js';
import { unitRadius } from '../js/render.js';

let pass = 0, fail = 0;
const ok = (cond, msg) => {
  if (cond) { pass++; console.log(`  ✔ ${msg}`); }
  else { fail++; console.log(`  ✘ ${msg}`); }
};
const section = (t) => console.log(`\n== ${t} ==`);

const CELL = CONFIG.cell;
const center = (tx, ty) => tileCenter(tx, ty, CELL);

function makeState() {
  const map = createMap();
  const state = {
    time: 0,
    terrain: map.terrain,
    base: map.base,
    generalSpawns: GENERAL_SPAWNS,
    buildings: new Grid(map.cols, map.rows, null),
    buildingList: [],
    buildingRevision: 0,
    units: [],
    resources: { food: 0, gold: 0 },
    ownedTiles: 0,
    sealedIslands: map.sealedIslands,
  };
  const zs = createZoneSystem();
  state.zones = zs.zones;
  state.zoneLookup = zs.lookup;
  return state;
}

function addBuilding(state, type, tx, ty, owner = 'player') {
  if (state.buildings.get(tx, ty)) return null;
  const z = zoneAt(state, tx, ty);
  const b = new Building(type, tx, ty, owner, z ? z.id : -1);
  state.buildings.set(tx, ty, b);
  state.buildingList.push(b);
  state.buildingRevision++;
  return b;
}

function makeUnit(state, opts) {
  const u = new Unit(Object.assign({ faction: 'player', kind: 'general' }, opts));
  u.state = state;
  return u;
}

/* ---------------- 1. 地图 ---------------- */
section('地图：尺寸 / 四连通 / 连通性');
const state = makeState();
ok(state.terrain.cols === 24 && state.terrain.rows === 16, '地图为 24 × 16');
ok(state.terrain.get(state.base.x, state.base.y) === 'grass', `大本营点位 (${state.base.x},${state.base.y}) 在草地上`);
ok(state.sealedIslands === 0, `不存在被隔离的可通行区域（已封堵 ${state.sealedIslands} 格）`);
{
  // 从大本营出发，所有非山地块都必须可达
  let walkable = 0, unreachable = 0;
  for (let y = 0; y < 16; y++) {
    for (let x = 0; x < 24; x++) {
      if (state.terrain.get(x, y) === 'mountain') continue;
      walkable++;
      if (!nearestReachable(state, state.base, { x, y }, 'player', 1)) unreachable++;
    }
  }
  ok(unreachable === 0, `全部 ${walkable} 个可通行地块都可从大本营走到`);
}

/* ---------------- 2. 寻路 ---------------- */
section('寻路：四连通 A*');
{
  // (19,4) 在右上口袋，必须从下方绕进去，长度应为 15
  const p = findPath(state, { x: 10, y: 10 }, { x: 19, y: 4 }, 'player');
  ok(p !== null, '(10,10) → (19,4) 有路径（绕过山体）');
  ok(p && p.length === 15, `路径长度为 15（实际 ${p ? p.length : 'null'}）`);
  ok(p && p.every((n, i) => {
    if (i === 0) return true;
    const d = Math.abs(n.x - p[i - 1].x) + Math.abs(n.y - p[i - 1].y);
    return d === 1;                       // 每一步都必须上下左右相邻 → 四连通
  }), '路径每一步都是上下左右相邻（四连通）');

  const blocked = findPath(state, { x: 10, y: 10 }, { x: 13, y: 3 }, 'player');
  ok(blocked === null, '目标是山体时返回 null（不可达）');
}

/* ---------------- 3. 地块唯一建筑 ---------------- */
section('建筑：每格最多一个 / 城墙通行规则');
{
  const w = addBuilding(state, 'wall', 12, 10);
  ok(w !== null, '在 (12,10) 建造城墙成功');
  ok(addBuilding(state, 'wall', 12, 10) === null, '同一地块再建建筑被拒绝');
  ok(occupied(state, 12, 10) === true, 'occupied() 能识别建筑占据');

  ok(passable(state, 12, 10, 'player') === true, '城墙对己方单位放行（己方可以穿过）');
  ok(passable(state, 12, 10, 'enemy') === false, '城墙对敌方单位阻挡（敌方不可进入）');
  ok(passable(state, 12, 10, 'player') !== passable(state, 12, 10, 'enemy'), '同一地块对两个阵营判定不同');

  // 敌方绕墙、己方穿墙
  const pPlayer = findPath(state, { x: 10, y: 10 }, { x: 14, y: 10 }, 'player');
  ok(pPlayer && pPlayer.some((n) => n.x === 12 && n.y === 10), '己方路径直接穿过城墙所在格');
  const pEnemy = findPath(state, { x: 10, y: 10 }, { x: 14, y: 10 }, 'enemy');
  ok(pEnemy && !pEnemy.some((n) => n.x === 12 && n.y === 10), '敌方路径不会穿过城墙格');

  // 用城墙围死一个点，敌方应无路可走
  const s2 = makeState();
  for (const [dx, dy] of [[0, -1], [1, 0], [0, 1], [-1, 0]]) addBuilding(s2, 'wall', 5 + dx, 5 + dy);
  const boxed = findPath(s2, { x: 10, y: 10 }, { x: 5, y: 5 }, 'enemy');
  ok(boxed === null, '被城墙完全围住时，敌方无路径（阻挡生效）');
  ok(passable(s2, 5, 5, 'player') === true, '同一围城中己方仍可进入');

  // 目标被“己方也进不去的建筑”（箭塔 / 大本营）占据时，自动改走到最近的可站格
  addBuilding(state, 'tower', 14, 10);
  const near = nearestReachable(state, { x: 10, y: 10 }, { x: 14, y: 10 }, 'player');
  ok(near && !(near.x === 14 && near.y === 10), `目标被箭塔占据时改走邻格 (${near ? near.x + ',' + near.y : 'null'})`);
  // 而城墙对己方是放行的，所以己方可以站在城墙格上
  const wallTile = nearestReachable(state, { x: 10, y: 10 }, { x: 12, y: 10 }, 'player');
  ok(wallTile && wallTile.x === 12 && wallTile.y === 10, '己方可以走到城墙格上（城墙对己方不阻挡）');
  const wallTileEnemy = findPath(state, { x: 14, y: 11 }, { x: 12, y: 10 }, 'enemy');
  ok(wallTileEnemy === null || !wallTileEnemy.some((n) => n.x === 12 && n.y === 10), '敌方无法把城墙格当作终点');
}

/* ---------------- 4. 箭塔 ---------------- */
section('箭塔：单体伤害 / 射程 / 冷却');
{
  const s = makeState();
  const tower = addBuilding(s, 'tower', 5, 5);
  const far = makeUnit(s, { id: 'far', name: '远处敌人', tx: 5, ty: 5 + CONFIG.building.tower.range + 2, faction: 'enemy', kind: 'enemy' });
  const inRange = makeUnit(s, { id: 'in', name: '射程内敌人', tx: 5, ty: 5 + CONFIG.building.tower.range, faction: 'enemy', kind: 'enemy' });
  const friend = makeUnit(s, { id: 'ally', name: '己方将领', tx: 6, ty: 5 });
  s.units = [far, inRange, friend];

  const hpBefore = friend.hp;
  updateTowers(s, 0.016);
  ok(far.hp === far.hpMax, '射程外敌人不受伤');
  ok(inRange.hp === inRange.hpMax - CONFIG.building.tower.damage, `射程内敌人受到 ${CONFIG.building.tower.damage} 点单体伤害`);
  ok(friend.hp === hpBefore, '己方单位不会被己方箭塔误伤');

  const hpAfterFirst = inRange.hp;
  updateTowers(s, 0.016);
  ok(inRange.hp === hpAfterFirst, '冷却时间内不会重复开火');
  updateTowers(s, CONFIG.building.tower.cooldown + 0.01);
  ok(inRange.hp === hpAfterFirst - CONFIG.building.tower.damage, '冷却结束后可以再次开火');

  while (inRange.alive) updateTowers(s, CONFIG.building.tower.cooldown + 0.01);
  ok(inRange.alive === false, '敌人血量归零后死亡（alive = false）');

  ok(removeBuilding(s, tower) === true, '箭塔可以拆除');
  const baseB = addBuilding(s, 'base', 8, 8);
  ok(removeBuilding(s, baseB) === false, '大本营不可拆除');
}

/* ---------------- 5. 区块占领 + 资源 ---------------- */
section('区块占领（占位规则）与资源增长');
{
  const s = makeState();
  const gens = createGenerals(s);
  s.units = gens;
  ok(s.zones.length === CONFIG.zone.zoneCols * CONFIG.zone.zoneRows, `区块数量 = ${CONFIG.zone.zoneCols} × ${CONFIG.zone.zoneRows} = ${s.zones.length}`);
  const totalTiles = s.zones.reduce((a, z) => a + z.tileCount, 0);
  ok(totalTiles === 24 * 16, `所有区块地块数之和 = ${totalTiles} = 全部地块`);

  // 把将领挪到无主区块 (0,0) 里
  const g = gens[0];
  g.tx = 0; g.ty = 0;
  const z = zoneAt(s, 0, 0);
  ok(z !== null && z.owner === null, `(0,0) 属于区块 ${z && z.name}，初始为无主`);

  const dt = 0.1;
  let elapsed = 0;
  while (z.owner !== 'player' && elapsed < 10) { updateZones(s, dt); elapsed += dt; }
  ok(z.owner === 'player', `站入 ${elapsed.toFixed(1)} 秒后区块 ${z.name} 转为己方（设定 ${CONFIG.zone.captureTimeSec} 秒）`);
  ok(Math.abs(elapsed - CONFIG.zone.captureTimeSec) < 0.25, '占领耗时与配置一致');

  // ⚠️ 另外两个将领站在原地（都在 C3）也会把 C3 占下来，所以己方地块是若干个完整区块，
  //    不一定是 (0,0) 所在的那一个（Python 版用单个将领，所以那边写的是严格相等）。
  const ownedAfter = ownedTileCount(s, 'player');
  ok(ownedAfter >= z.tileCount && ownedAfter % z.tileCount === 0,
     `己方地块数 = ${ownedAfter}，是区块地块数 ${z.tileCount} 的整数倍（其他将领也会占下自己所在的区块）`);

  // 资源按领地增长：模拟 1 秒
  s.resources.food += ownedAfter * CONFIG.resource.foodPerTilePerSec * 1;
  s.resources.gold += ownedAfter * CONFIG.resource.goldPerTilePerSec * 1;
  ok(s.resources.food === ownedAfter, `1 秒获得 ${s.resources.food} 粮食 = 己方地块数 × 1`);
  ok(s.resources.gold === ownedAfter, `1 秒获得 ${s.resources.gold} 黄金 = 己方地块数 × 1`);

  // 单位离开后进度回退
  const s3 = makeState();
  const g3 = createGenerals(s3)[0];
  s3.units = [g3];
  g3.tx = 23; g3.ty = 0;
  const z3 = zoneAt(s3, 23, 0);
  updateZones(s3, 2);
  const p1 = z3.progress;
  ok(p1 > 0 && p1 < 1, `占领进度增长中（${p1.toFixed(2)}）`);
  g3.tx = 0; g3.ty = 15;                    // 离开该区块
  updateZones(s3, 0.5);
  ok(z3.progress < p1, `单位离开后进度回退（${z3.progress.toFixed(2)} < ${p1.toFixed(2)}）`);

  // 建筑也算领地
  const s4 = makeState();
  s4.units = [];
  const z4 = zoneAt(s4, 2, 2);
  addBuilding(s4, 'tower', 2, 2);
  refreshBuildingOwnership(s4);
  ok(z4.owner === 'player', `区块 ${z4.name} 内建成建筑后直接归己方（zoneOwnedByBuilding = ${CONFIG.zone.zoneOwnedByBuilding}）`);
}

/* ---------------- 6. 直线移动 ---------------- */
section('移动：能走直线就走直线（路径拉直 + 不再沿格心走阶梯）');
{
  const s = makeState();
  const g = makeUnit(s, { id: 'g1', name: '将领 1', tx: 8, ty: 10 });
  s.units = [g];

  // 开阔地：起点 (8,10) → 目标格 (20,12) 内偏右下，两点之间没有山，应该直接走直线
  const click = { x: 20 * CELL + 7.5, y: 12 * CELL + 108 };
  ok(g.orderMove(s, click) === true, '开阔地：下令成功');
  ok(g.path && g.path.length === 1, `开阔地路径被拉直成一条直线（路径点 ${g.path ? g.path.length : 'null'} 个；旧实现是十几个格心点连成的阶梯）`);
  ok(Math.abs(g.path[0].x - click.x) < 1e-9 && Math.abs(g.path[0].y - click.y) < 1e-9,
     '直线的终点就是点击位置（不吸附格心）');

  // 沿直线走完全程：逐帧位移 = 速度预算，且每一步都严格落在起点→终点的连线上
  const start = { x: g.px, y: g.py };
  const lineLen = Math.hypot(click.x - start.x, click.y - start.y);
  const budget = CONFIG.unit.speed * CELL / 60;
  const deltas = [];
  let maxDeviation = 0;
  let frames = 0;
  while (g.moving && frames < 60 * 60) {
    const px = g.px, py = g.py;
    g.update(s, 1 / 60);
    deltas.push(Math.hypot(g.px - px, g.py - py));
    // 点到直线的距离（叉积 / 斜边长）
    const dev = Math.abs((click.x - start.x) * (py - start.y) - (click.y - start.y) * (px - start.x)) / lineLen;
    if (dev > maxDeviation) maxDeviation = dev;
    frames++;
  }
  ok(frames > 10, `共推进 ${frames} 帧`);
  const body = deltas.slice(0, -1);
  ok(body.every((d) => Math.abs(d - budget) < 1e-6),
     `除最后一帧外每帧位移都等于草地预算 ${budget.toFixed(2)}px（没有走走停停）`);
  ok(maxDeviation < 0.01, `轨迹与起点→终点的直线最大偏差 ${maxDeviation.toFixed(4)}px（确实是直线，不是阶梯）`);
  ok(g.tx === 20 && g.ty === 12, `走到了点击所在格 (${g.tx},${g.ty})`);
  ok(Math.abs(g.px - click.x) < 0.01 && Math.abs(g.py - click.y) < 0.01, '精确停在点击位置');

  // 同格内的小范围移动：也要能走直线挪一小步
  const g1b = makeUnit(s, { id: 'g1b', name: '将领 1b', tx: 8, ty: 10 });
  s.units = [g1b];
  const micro = { x: g1b.px + 40, y: g1b.py + 15 };
  ok(g1b.orderMove(s, micro) === true && g1b.path.length === 1, '同一格内挪一小步也是一条直线');
  for (let i = 0; i < 600 && g1b.moving; i++) g1b.update(s, 1 / 60);
  ok(Math.abs(g1b.px - micro.x) < 0.01 && Math.abs(g1b.py - micro.y) < 0.01, '小范围移动也精确停在目标位置');

  // 有山阻挡：直线不可达时必须保留拐点绕行，而且每一段直线本身都是可通行的
  const g2 = makeUnit(s, { id: 'g2', name: '将领 2', tx: 8, ty: 10 });
  s.units = [g2];
  const blockedClick = { x: 19 * CELL + 60, y: 4 * CELL + 60 };     // 右上口袋，必须绕山
  ok(g2.orderMove(s, blockedClick) === true, '目标在山体另一侧：下令成功');
  ok(g2.path && g2.path.length > 1, `绕行路线保留了 ${g2.path ? g2.path.length : 'null'} 个拐点（没有被错误地拉成一条直线）`);
  let prev = { x: g2.px, y: g2.py };
  let allSegmentsClear = true;
  for (const p of g2.path) {
    if (!segmentClear(s, prev.x, prev.y, p.x, p.y, 'player')) allSegmentsClear = false;
    prev = p;
  }
  ok(allSegmentsClear, '拉直后的每一段直线都通过了通行判定（不会为了走直线而翻山）');

  // 走完全程：全程都不会站到不可通行的地块上
  let offBlocked = 0;
  const seen = new Set();
  let f2 = 0;
  while (g2.moving && f2 < 60 * 60) {
    g2.update(s, 1 / 60);
    f2++;
    const key = g2.tx + ',' + g2.ty;
    if (!seen.has(key)) { seen.add(key); if (!passable(s, g2.tx, g2.ty, 'player')) offBlocked++; }
  }
  ok(offBlocked === 0, `绕行途中没有踩到山 / 建筑格（经过 ${seen.size} 格）`);
  ok(g2.tx === 19 && g2.ty === 4, `绕行后到达目标格 (${g2.tx},${g2.ty})`);

  // 点山 / 点建筑 → 自动改走最近可达处（旧行为保持不变）
  const g3 = makeUnit(s, { id: 'g3', name: '将领 3', tx: 10, ty: 10 });
  s.units = [g3];
  const mountainPt = center(15, 5);                        // (15,5) 是山
  ok(!passable(s, 15, 5, 'player'), '前提：(15,5) 确实不可通行');
  ok(g3.orderMove(s, mountainPt) === true, '点到山体：仍然能下令（自动改走最近可达格）');
  ok(g3.goal && !(g3.goal.x === 15 && g3.goal.y === 5), `目标格被改成最近的可达格 (${g3.goal ? g3.goal.x + ',' + g3.goal.y : 'null'})`);
  ok(!g3.path.some((p) => p.x === mountainPt.x && p.y === mountainPt.y), '不会把山体中心当作终点');
}

/* ---------------- 6.5 直线通行判定本身 ---------------- */
section('直线通行判定：segmentClear / smoothPath');
{
  const s = makeState();
  addBuilding(s, 'wall', 12, 10);
  ok(segmentClear(s, center(11, 10).x, center(11, 10).y, center(13, 10).x, center(13, 10).y, 'player') === true,
     '穿过城墙格的一条直线：己方可以走');
  ok(segmentClear(s, center(11, 10).x, center(11, 10).y, center(13, 10).x, center(13, 10).y, 'enemy') === false,
     '同一條直线：敌方不可走（城墙只挡敌方）');
  ok(segmentClear(s, center(10, 10).x, center(10, 10).y, center(16, 5).x, center(16, 5).y, 'player') === false,
     '穿过山体的直线被拒绝');
  ok(segmentClear(s, center(16, 4).x, center(16, 4).y, center(18, 6).x, center(18, 6).y, 'player') === true,
     '开阔地的直线被接受');
  // 只从山体一个角上蹭过去也要拒绝（超覆盖判定，避免单位贴着山尖穿过去）
  ok(segmentClear(s, center(14, 4).x, center(14, 4).y, center(15, 5).x, center(15, 5).y, 'player') === false,
     '只从山体一个角上蹭过去的对角线被拒绝（超覆盖判定）');

  const poly = [center(10, 10), center(11, 10), center(12, 10), center(13, 10)];
  const flat = smoothPath(s, poly, 'player');
  ok(flat.length === 2, `己方：4 点折线被拉直成 2 点（直线穿过城墙）`);
  const flatEnemy = smoothPath(s, poly, 'enemy');
  ok(flatEnemy.length > 2, `敌方：同样的折线不会被拉直（城墙挡路），保留 ${flatEnemy.length} 个点`);
}

/* ---------------- 7. 战斗与警戒 ---------------- */
section('战斗：攻击 / 冷却 / 警戒索敌 / 先靠近再攻击');
{
  const s = makeState();
  const g = makeUnit(s, { id: 'g1', name: '将领 1', tx: 10, ty: 10 });
  const e = makeUnit(s, { id: 'e1', name: '测试敌人', tx: 10, ty: 13, faction: 'enemy', kind: 'enemy' });
  s.units = [g, e];

  const startD = Math.hypot(g.px - e.px, g.py - e.py);
  ok(startD <= CONFIG.combat.aggroRange * CELL && startD > CONFIG.combat.general.range * CELL,
     `初始间距 ${startD.toFixed(0)}px：在警戒半径内、但够不着`);

  g.update(s, 1 / 60);
  ok(g.target === e, '静止的将领在警戒半径内发现敌人并锁定目标');
  ok(g.anchor !== null, '记录“警戒起点”，用于之后的追击上限判定');

  // 先靠近，再攻击
  let f = 0;
  while (f < 60 * 10 && e.hp === e.hpMax) { g.update(s, 1 / 60); f++; }
  ok(f < 60 * 10, `发现目标后开始追击（${(f / 60).toFixed(2)} 秒后开火）`);
  ok(g.moving === false, '进入攻击距离后站住不再移动');
  const dAttack = Math.hypot(g.px - e.px, g.py - e.py);
  ok(dAttack < startD, `先移动靠近再攻击：距离 ${startD.toFixed(0)}px → ${dAttack.toFixed(0)}px`);
  ok(dAttack <= CONFIG.combat.general.range * CELL + unitRadius('enemy') + 1e-6,
     `开火时确实在攻击距离内（${dAttack.toFixed(1)}px ≤ ${(CONFIG.combat.general.range * CELL + unitRadius('enemy')).toFixed(1)}px）`);
  ok(e.hp === e.hpMax - CONFIG.combat.general.damage, `造成一次 ${CONFIG.combat.general.damage} 点单体伤害（敌人 ${e.hpMax} → ${e.hp}）`);

  // 冷却
  const hp1 = e.hp;
  g.update(s, 0.05);
  ok(e.hp === hp1, '冷却时间内不会重复开火');
  g.update(s, CONFIG.combat.general.cooldownSec + 0.01);
  ok(e.hp === hp1 - CONFIG.combat.general.damage, '冷却结束后可以再次开火');

  // 击杀 + 战斗事件（日志 / 提示）
  const events = [];
  s.onCombatEvent = (evt) => events.push(evt);
  let f2 = 0;
  while (e.alive && f2 < 60 * 30) { g.update(s, 1 / 60); f2++; }
  ok(e.alive === false, '敌人血量归零后死亡');
  ok(events.some((ev) => ev.type === 'kill' && ev.source === g), '阵亡会触发战斗事件，并带上击杀者（main.js 用它写事件日志）');
  g.update(s, 1 / 60);
  ok(g.target === null, '目标死亡后自动脱离交战');

  // 玩家命令优先：下达移动命令会中断交战
  const s2 = makeState();
  const g2 = makeUnit(s2, { id: 'g2', name: '将领 2', tx: 10, ty: 10 });
  const e2 = makeUnit(s2, { id: 'e2', name: '测试敌人 2', tx: 10, ty: 12, faction: 'enemy', kind: 'enemy' });
  s2.units = [g2, e2];
  g2.update(s2, 1 / 60);
  ok(g2.target === e2, '锁定目标');
  ok(g2.orderMove(s2, { x: 3 * CELL + 60, y: 3 * CELL + 60 }) === true, '右键下达移动命令');
  ok(g2.target === null, '明确的移动命令会中断交战（玩家操作优先）');

  // 移动中的单位不做警戒索敌
  const s3 = makeState();
  const g3 = makeUnit(s3, { id: 'g3', name: '将领 3', tx: 10, ty: 10 });
  const e3 = makeUnit(s3, { id: 'e3', name: '测试敌人 3', tx: 10, ty: 12, faction: 'enemy', kind: 'enemy' });
  s3.units = [g3, e3];
  g3.orderMove(s3, { x: 4 * CELL + 60, y: 10 * CELL + 60 });
  g3.update(s3, 1 / 60);
  ok(g3.moving === true && g3.target === null, '正在执行移动命令的单位不会半路索敌（只有静止时才警戒）');

  // 追击上限：目标跑太远就放弃
  const s4 = makeState();
  const g4 = makeUnit(s4, { id: 'g4', name: '将领 4', tx: 10, ty: 10 });
  const e4 = makeUnit(s4, { id: 'e4', name: '测试敌人 4', tx: 10, ty: 12, faction: 'enemy', kind: 'enemy' });
  s4.units = [g4, e4];
  g4.update(s4, 1 / 60);
  ok(g4.target === e4, '锁定近距离目标');
  const flee = CONFIG.combat.aggroRange * CONFIG.combat.leashFactor + 1;
  e4.px = center(10, 10).x;
  e4.py = center(10, 10).y + flee * CELL;
  g4.update(s4, 1 / 60);
  ok(g4.target === null, `目标跑出追击上限（${flee} 格）后放弃，不会一路追到地图另一头`);

  // CONFIG.combat.enabled = false 时整体关闭
  const s5 = makeState();
  const g5 = makeUnit(s5, { id: 'g5', name: '将领 5', tx: 10, ty: 10 });
  const e5 = makeUnit(s5, { id: 'e5', name: '测试敌人 5', tx: 10, ty: 12, faction: 'enemy', kind: 'enemy' });
  s5.units = [g5, e5];
  CONFIG.combat.enabled = false;
  g5.update(s5, 1 / 60);
  ok(g5.target === null, 'CONFIG.combat.enabled = false 时不做警戒索敌');
  CONFIG.combat.enabled = true;
  g5.update(s5, 1 / 60);
  ok(g5.target === e5, '重新打开后恢复索敌');
}

/* ---------------- 7.5 城墙血量 ---------------- */
section('城墙血量：受伤 / 血条 / 摧毁 / 大本营不可摧毁');
{
  const s = makeState();
  const wall = addBuilding(s, 'wall', 12, 10);
  ok(wall.hp === CONFIG.building.wall.hpMax && wall.hpMax === CONFIG.building.wall.hpMax,
     `新建城墙满血 ${wall.hp}/${wall.hpMax}（数值来自 CONFIG.building.wall.hpMax）`);
  ok(wall.hpRatio === 1 && wall.flash === 0, '初始血条比例 1、没有受击闪光');

  const need = (hp) => Math.ceil(hp / CONFIG.combat.buildingDamage);
  ok(wall.takeDamage(CONFIG.combat.buildingDamage, null) === true
     && wall.hp === CONFIG.building.wall.hpMax - CONFIG.combat.buildingDamage,
     `挨一下扣 ${CONFIG.combat.buildingDamage} 点血（${CONFIG.building.wall.hpMax} → ${wall.hp}）`);
  ok(wall.flash === 1, '受击会置闪光标记（渲染时闪一下红）');
  ok(Math.abs(wall.hpRatio - wall.hp / wall.hpMax) < 1e-9, 'hpRatio 与血量一致（血条按比例画）');
  updateBuildingEffects(s, 1 / 60);
  ok(wall.flash > 0 && wall.flash < 1, '闪光会随时间衰减');

  ok(need(wall.hpMax) === 8, `打光一堵墙需要 ${need(wall.hpMax)} 下（${CONFIG.building.wall.hpMax} ÷ ${CONFIG.combat.buildingDamage}）`);
  const hpLeft = wall.hp;
  for (let i = 0; i < need(hpLeft) - 1; i++) {
    ok(wall.takeDamage(CONFIG.combat.buildingDamage, null) === true, `第 ${i + 2} 下之后城墙还在（hp=${wall.hp}）`);
  }
  ok(wall.hp > 0 && wall.hp <= CONFIG.combat.buildingDamage, `血只剩最后一下：${wall.hp}`);
  ok(wall.takeDamage(CONFIG.combat.buildingDamage, null) === false, '打光的那一下返回 false（调用方该拆掉它了）');
  ok(wall.hp === 0 && wall.alive === true, 'takeDamage 自己不负责移除（由 main.js 收尸，避免建筑还挂在格子上）');

  const s2 = makeState();
  const baseB = addBuilding(s2, 'base', 8, 8);
  ok(baseB.takeDamage(99999, null) === true && baseB.hp === 1 && baseB.alive === true,
     '大本营被打到 0 血时保留 1 点（本版不可摧毁）');
}

/* ---------------- 7.6 敌人拆墙 ---------------- */
section('敌人拆墙：先靠近 → 贴墙一下一下拆 → 打光后让路');
{
  const s = makeState();
  const wall = addBuilding(s, 'wall', 12, 10);
  const e = makeUnit(s, { id: 'e', name: '测试敌人', tx: 12, ty: 13, faction: 'enemy', kind: 'enemy' });
  s.units = [e];
  ok(e.setBuildingTarget(wall) === true && e.targetBuilding === wall, '锁定挡路的城墙作为目标');
  ok(e.setBuildingTarget(null) === false, '拒绝空目标');

  // 一开始够不着（3 格）→ 应该先走过去
  const d0 = Math.hypot(e.px - wall.center.x, e.py - wall.center.y);
  const reach = CONFIG.combat.enemy.range * CELL + CELL * 0.5;   // 建筑占满整格，攻击距离算半格
  let f = 0;
  while (f < 60 * 20 && wall.hp === wall.hpMax) { e.update(s, 1 / 60); f++; }
  const d1 = Math.hypot(e.px - wall.center.x, e.py - wall.center.y);
  ok(d1 < d0, `先移动靠近再拆：${d0.toFixed(0)}px → ${d1.toFixed(0)}px`);
  ok(d1 <= reach + 1e-6, `贴到墙边才开始拆（${d1.toFixed(1)}px ≤ ${reach.toFixed(1)}px）`);
  ok(e.moving === false, '拆墙时站住不动');
  ok(wall.hp === CONFIG.building.wall.hpMax - CONFIG.combat.buildingDamage,
     `拆一下 ${CONFIG.combat.buildingDamage} 点血（${CONFIG.building.wall.hpMax} → ${wall.hp}）`);
  ok(e.attackFlash > 0, '拆墙也会触发攻击特效（渲染攻击线用）');

  const hp1 = wall.hp;
  e.update(s, 0.05);
  ok(wall.hp === hp1, '冷却时间内不会连续拆');
  e.update(s, CONFIG.combat.enemy.cooldownSec + 0.01);
  ok(wall.hp === hp1 - CONFIG.combat.buildingDamage, '冷却结束后再拆一下');

  // 打光 → 广播 buildingDown 事件；main.js 收到后 removeBuilding（这里按同样的方式接上）
  const events = [];
  s.onCombatEvent = (evt) => {
    events.push(evt);
    if (evt.type === 'buildingDown') removeBuilding(s, evt.building);
  };
  let f2 = 0;
  while (wall.alive && f2 < 60 * 60) { e.update(s, 1 / 60); f2++; }
  ok(wall.alive === false, `城墙被打光并拆掉（从 ${CONFIG.building.wall.hpMax} 血开始，用了 ${(f2 / 60).toFixed(1)} 秒）`);
  const down = events.filter((ev) => ev.type === 'buildingDown');
  ok(down.length === 1 && down[0].building === wall && down[0].source === e,
     '只广播一次 buildingDown 事件，并带上“是谁拆的”');
  ok(s.buildings.get(12, 10) === null, '城墙从地图格子与建筑表里都摘掉了');
  e.update(s, 1 / 60);
  ok(e.targetBuilding === null, '建筑没了以后自动脱离目标');
  ok(e.moving === false, '目标消失后站住（等 main.js 的 AI 重新指路）');
}

/* ---------------- 7.7 用一整条墙拦断路线（回归：敌人站在出生点发呆） ---------------- */
section('城墙拦断整条路线：可达性判定 + 敌人必须动起来');
{
  const s = makeState();
  addBuilding(s, 'base', s.base.x, s.base.y);
  let built = 0, blockedCol = 0;
  for (let y = 0; y < 16; y++) {
    if (s.terrain.get(13, y) === 'mountain') { blockedCol++; continue; }   // 山地本来就不通
    if (addBuilding(s, 'wall', 13, y)) { built++; blockedCol++; }
  }
  ok(blockedCol === 16, `用一整列城墙 + 山地把地图切成东西两块（新建 ${built} 段，col 13 整列不通）`);

  const spawn = { x: 22, y: 2 };
  const region = reachableTiles(s, spawn, 'enemy');
  ok(!region.has(idx(s.terrain, s.base.x, s.base.y)), '敌人的可达区域里不包含大本营（路线被彻底拦断）');
  ok(region.has(idx(s.terrain, 14, 2)) && !region.has(idx(s.terrain, 12, 2)),
     '墙确实切开了区域：东侧 (14,2) 可达、西侧 (12,2) 不可达');

  // ★ 回归 1：nearestReachable 不能返回“墙那一边、自己根本走不到”的格子
  //   （旧实现忽略 from 参数，BFS 从大本营往外扩一圈就直接返回 (12,7)，
  //    于是 findPath 必然 null，敌人以为哪都去不了 → 站在出生点发呆）
  const nearBase = nearestReachable(s, spawn, s.base, 'enemy', 20);
  ok(nearBase === null || region.has(idx(s.terrain, nearBase.x, nearBase.y)),
     `返回的落脚点必须是自己走得到的（返回 ${nearBase ? nearBase.x + ',' + nearBase.y : 'null'}；旧实现会返回墙那一边的 (12,7)）`);
  ok(nearBase === null || findPath(s, spawn, nearBase, 'enemy') !== null,
     '而且到那个落脚点的路线真的存在（旧实现返回的格子 findPath 为 null）');
  const nearWall = nearestReachable(s, spawn, { x: 13, y: 2 }, 'enemy', 20);
  ok(nearWall && Math.abs(nearWall.x - 13) + Math.abs(nearWall.y - 2) === 1
     && region.has(idx(s.terrain, nearWall.x, nearWall.y)),
     `朝“挨着自己区域的墙”找落脚点 → (${nearWall ? nearWall.x + ',' + nearWall.y : 'null'})，是自己这一侧的邻格`);
  const nearMountain = nearestReachable(s, { x: 10, y: 10 }, { x: 15, y: 5 }, 'player', 20);
  ok(nearMountain && nearMountain.x === 16 && nearMountain.y === 5,
     `同一张图上己方点山体仍能找到最近可达格 (${nearMountain ? nearMountain.x + ',' + nearMountain.y : 'null'})`);

  // ★ 回归 2：该拆哪段墙 —— 挨着自己区域、离大本营最近的那段
  const e = makeUnit(s, { id: 'e', name: '测试敌人', tx: 22, ty: 2, faction: 'enemy', kind: 'enemy' });
  s.units = [e];
  const blocker = findBlockingWallToward(s, { x: e.tx, y: e.ty }, s.base, 'enemy', 'wall');
  ok(blocker && blocker.tx === 13 && blocker.ty === 2,
     `挑中 (${blocker ? blocker.tx + ',' + blocker.ty : 'null'})：挨着可达区域、离大本营最近的那段墙`);
  ok(!blocker || !(blocker.tx === 13 && blocker.ty === 8),
     '没有挑离大本营最近、但自己根本走不到的 (13,8)（它在墙的另一侧）');
  ok(findBlockingWallToward(makeState(), { x: 10, y: 10 }, { x: 12, y: 8 }, 'enemy', 'wall') === null,
     '地图上没有城墙时返回 null（不会凭空挑一个目标）');

  // ★ 回归 3：下令后必须**动起来**（旧实现：0px，永远站在出生点）
  ok(e.setBuildingTarget(blocker) === true, '锁定要拆的城墙');
  const p0 = { x: e.px, y: e.py };
  for (let i = 0; i < 60 * 8; i++) e.update(s, 1 / 60);
  const moved = Math.hypot(e.px - p0.x, e.py - p0.y);
  ok(moved > 200, `敌人动起来了：8 秒走了 ${moved.toFixed(0)}px（修复前是 0px）`);
  ok(e.tx === 14 && e.ty === 2, `从自己这一侧贴到墙边 (${e.tx},${e.ty})，没有绕到墙的另一侧`);
  ok(blocker.hp < blocker.hpMax, `已经开始拆墙（${blocker.hp}/${blocker.hpMax}）`);

  // 拆穿之后可达区域扩大到大本营旁边
  s.onCombatEvent = (evt) => { if (evt.type === 'buildingDown') removeBuilding(s, evt.building); };
  let f = 0;
  while (blocker.alive && f < 60 * 60) { e.update(s, 1 / 60); f++; }
  ok(blocker.alive === false, `把这段墙拆掉了（再花 ${(f / 60).toFixed(1)} 秒）`);
  const region2 = reachableTiles(s, { x: e.tx, y: e.ty }, 'enemy');
  ok(region2.has(idx(s.terrain, s.base.x, s.base.y - 1)),
     '拆穿后可达区域扩大到大本营旁边（缺口打开）');
  const after = nearestReachable(s, { x: e.tx, y: e.ty }, s.base, 'enemy', 20);
  ok(after && Math.abs(after.x - s.base.x) + Math.abs(after.y - s.base.y) === 1,
     `缺口打开后能找到大本营旁的落脚点 (${after ? after.x + ',' + after.y : 'null'})`);
}

/* ---------------- 8. 敌人 AI（回归：地块坐标 ≠ 像素坐标） ---------------- */
section('敌人 AI：朝大本营推进（旧版把地块坐标当像素用的回归测试）');
{
  const s = makeState();
  addBuilding(s, 'base', s.base.x, s.base.y);       // 和 init() 一样：大本营占住一格

  // 和 main.js spawnEnemy() 一样：默认出生点在右侧隘口，不可站就挪到最近的可站格
  const spawn = { x: s.terrain.cols - 1, y: 3 };
  const open = passable(s, spawn.x, spawn.y, 'enemy') ? spawn : findOpenTileNear(s, spawn, 'enemy');
  ok(open !== null && passable(s, open.x, open.y, 'enemy') === true,
     `出生点选在可通行的格子上 (${open ? open.x + ',' + open.y : 'null'})（(23,3) 是山，会自动挪开）`);

  const e = makeUnit(s, { id: 'e', name: '测试敌人', tx: open.x, ty: open.y, faction: 'enemy', kind: 'enemy' });
  s.units = [e];

  const goal = nearestReachable(s, { x: e.tx, y: e.ty }, s.base, 'enemy');
  ok(goal !== null, `找到一个靠近大本营的可站格 (${goal ? goal.x + ',' + goal.y : 'null'})`);
  const goalPt = tileCenter(goal.x, goal.y, CELL);
  ok(e.moveTo(s, goalPt) === true, '按 main.js 的写法下达推进命令（像素坐标）');

  const worldW = s.terrain.cols * CELL, worldH = s.terrain.rows * CELL;
  ok(e.path.every((p) => p.x >= 0 && p.x <= worldW && p.y >= 0 && p.y <= worldH),
     '路径点全都落在地图世界范围内（说明塞进 path 的是像素坐标，而不是 0~23 的地块坐标）');

  let steppedOnBlocked = 0, frames = 0;
  const seen = new Set();
  while (e.moving && frames < 60 * 60) {
    e.update(s, 1 / 60);
    frames++;
    const key = e.tx + ',' + e.ty;
    if (!seen.has(key)) {
      seen.add(key);
      if (!passable(s, e.tx, e.ty, 'enemy')) steppedOnBlocked++;
    }
  }
  const dBase = Math.abs(e.tx - s.base.x) + Math.abs(e.ty - s.base.y);
  ok(!e.moving, `在 ${(frames / 60).toFixed(1)} 秒内走完了路线`);
  ok(dBase <= 1, `停在大本营旁边 (${e.tx},${e.ty})，与大本营的曼哈顿距离 ${dBase}（旧版会停在像素 (12,7) 打转）`);
  ok(steppedOnBlocked === 0, `全程没有踩到不可通行的地块（经过 ${seen.size} 格）`);
  ok(!(e.tx <= 1 && e.ty <= 1), '没有像旧版那样走到地图左上角 (0,0)');
}

/* ---------------- 汇总 ---------------- */
console.log(`\n———————————————\n通过 ${pass} 项，失败 ${fail} 项`);
process.exit(fail === 0 ? 0 : 1);
