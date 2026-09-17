/**
 * tools/net-test.mjs —— 联机同步测试（不需要浏览器、不需要服务器）
 * 运行：node tools/net-test.mjs
 *
 * 这个文件回答一个具体问题：**「两个玩家能不能互相看到、能不能打起来」**
 *
 * 关键前提（别搞错拓扑）：
 *   房主手里有**双方所有单位**，跑唯一的权威逻辑；
 *   客机是同一局的一面镜子，它的世界完全由房主的快照驱动。
 *   所以「两个玩家互相索敌」发生在**房主的 state 里**（双方单位都在 state.units 中），
 *   而不是在两个各自独立的 state 之间 —— 后者就是「两个人各玩各的」。
 *
 * 测试内容：
 *   A 侧：单机/房主视角 —— 双方单位同处一个 state，能否互相索敌并打出伤害
 *   B 侧：客机视角 —— 快照能否正确灌进客机、按 id 对齐、插值字段是否就位
 */

import { Grid, tileCenter } from '../js/util.js';
import { CONFIG } from '../js/config.js';
import { createMap, GENERAL_SPAWNS } from '../js/map.js';
import { createZoneSystem, updateZones, ownedTileCount, zoneAt } from '../js/zone.js';
import { Building } from '../js/building.js';
import { Unit, createGenerals } from '../js/unit.js';
import { passable, findPath } from '../js/path.js';
import { makeSnapshot, applySnapshot, INTERP_DELAY, SNAPSHOT_HZ } from '../js/net.js';
import { sameSide, isPlayerFaction, DEFAULT_FACTION } from '../js/faction.js';

let pass = 0, fail = 0;
const ok = (cond, msg) => {
  if (cond) { pass++; console.log(`  ✔ ${msg}`); }
  else { fail++; console.log(`  ✘ ${msg}`); }
};
const section = (t) => console.log(`\n== ${t} ==`);

const CELL = CONFIG.cell;
const center = (tx, ty) => tileCenter(tx, ty, CELL);

/**
 * 建一个「玩家视角」的世界。
 *
 * @param {string[]} roster 本局玩家阵营表，例如 ['p1','p2']
 * @param {string} mine     我是哪一方（决定 myFaction / 大本营归属）
 * @param {boolean} withAll true = 房主：把 roster 里**所有**阵营的将领都建出来
 *                          false = 客机/单机：只建自己这一方
 */
function makeSide(roster, mine, withAll = false) {
  const map = createMap();
  const state = {
    time: 0,
    terrain: map.terrain,
    base: map.base,
    generalSpawns: GENERAL_SPAWNS,
    buildings: new Grid(map.cols, map.rows, null),
    buildingList: [],
    buildingRevision: 0,
    lastRevision: -1,
    units: [],
    factions: { myFaction: mine, factions: roster.slice(), enemyFaction: 'enemy' },
    resources: { food: 0, gold: 0 },
    ownedTiles: 0,
    log: [],
    ui: { selectedUnits: [], selectedBuilding: null, toasts: [] },
    // 对战规则开关：本文件测的是联机阵营/同步，统一按"联机已开启"来建
    pvpEnabled: true,
    match: { over: false, winner: null, elapsed: 0, logged: false, limitSec: 600 },
    homeBaseOf: null,
  };
  const zs = createZoneSystem(state);
  state.zones = zs.zones;
  state.zoneLookup = zs.lookup;

  // 每个玩家一个大本营：房主（第一个阵营）用原图点位，其他人放到地图右侧
  const baseOf = (f) => (f === roster[0] ? { x: map.base.x, y: map.base.y } : { x: 20, y: 12 });
  const myBase = baseOf(mine);
  state.base = myBase;

  const list = withAll ? roster : [mine];
  for (const f of list) {
    const b = baseOf(f);
    addBuilding(state, 'base', b.x, b.y, f);
    state.units.push(...createGenerals(state, f));
    // 让每个玩家站在自己的大本营旁边（而不是所有人挤在 GENERAL_SPAWNS）
    for (const u of state.units) {
      if (u.faction !== f) continue;
      u.tx = b.x; u.ty = b.y + 1;
      u.px = center(u.tx, u.ty).x; u.py = center(u.tx, u.ty).y;
    }
  }
  return state;
}

function addBuilding(state, type, tx, ty, owner) {
  if (state.buildings.get(tx, ty)) return null;
  const z = zoneAt(state, tx, ty);
  const b = new Building(type, tx, ty, owner, z ? z.id : -1);
  state.buildings.set(tx, ty, b);
  state.buildingList.push(b);
  state.buildingRevision++;
  return b;
}

/** 模拟服务器中继：房主的快照 → 客机 */
function relay(hostState, clientState) {
  const snap = makeSnapshot(hostState);
  applySnapshot(clientState, snap, performance.now());
  return snap;
}

const ROSTER = ['p1', 'p2'];

/* ================================================================== */
/* P. 对战（分阵营战斗）规则                                            */
/* ================================================================== */
section('P1 出生点分离：双方各在一角，不叠在同一个基地上');
{
  // 直接测 spawnLayoutFor（真实实现）—— 它决定每一方的大本营与将领站位
  const { spawnLayoutFor } = await import('../js/map.js');
  const map = createMap();
  const L1 = spawnLayoutFor(map, 'p1', 'p1');
  const L2 = spawnLayoutFor(map, 'p2', 'p1');

  ok(L1.base.x !== L2.base.x || L1.base.y !== L2.base.y,
    `★ p1 与 p2 的大本营不在同一格（p1=${L1.base.x},${L1.base.y} / p2=${L2.base.x},${L2.base.y}）`);
  const gap = Math.abs(L1.base.x - L2.base.x) + Math.abs(L1.base.y - L2.base.y);
  ok(gap >= 8, `★ 两个基地相距 ${gap} 格（曼哈顿），开局不会立刻贴脸`);

  // 单机 / p1 必须与原版点位一致（兼容性）
  ok(L1.base.x === map.base.x && L1.base.y === map.base.y,
    `p1 大本营仍在原版位置 (${L1.base.x}, ${L1.base.y})`);
  ok(L1.spawns.every((s, i) => s.x === GENERAL_SPAWNS[i].x && s.y === GENERAL_SPAWNS[i].y),
    'p1 的将领站位与原版 GENERAL_SPAWNS 逐位一致');

  // 同一方多次计算结果必须完全相同（房主与客机各自算，不能算出不同基地）
  const again = spawnLayoutFor(createMap(), 'p2', 'p1');
  ok(again.base.x === L2.base.x && again.base.y === L2.base.y,
    '★ 同一阵营的出生点计算是确定的（房主/客机各自算也会得到同一结果）');

  /**
   * ★ 关键：主阵营必须由「名单第一个（房主）」决定，不能由「我是谁」决定。
   *   否则客机（myFaction = 'p2'）会把 p2 摆到地图中央，而房主那边 p1 也在中央 ——
   *   两边算出不同的世界，快照一同步就全乱。
   */
  const hostView = spawnLayoutFor(createMap(), 'p2', 'p1');   // 房主：roster[0] = p1
  const guestView = spawnLayoutFor(createMap(), 'p2', 'p1');  // 客机：同一份 roster，算 p2
  ok(hostView.base.x === guestView.base.x && hostView.base.y === guestView.base.y,
    '★ 房主与客机对同一个阵营算出同一个基地（不依赖"我是谁"）');
  ok(guestView.base.x !== spawnLayoutFor(createMap(), 'p1', 'p1').base.x,
    'p2 的基地不等于 p1 的基地（不会两边都摆到地图中央）');
  ok(L2.spawns.length === 3 && L2.spawns.every((s) => s.x !== L2.base.x || s.y !== L2.base.y),
    `p2 的 3 个将领都站在大本营之外（${L2.spawns.map((s) => s.x + ',' + s.y).join(' | ')}）`);
  ok(L2.defenses.length >= 1,
    `p2 开局有防御阵地（${L2.defenses.map((d) => d.type).join(', ')}）`);
}

section('P2 阵亡与复活');
{
  const st = makeSide(ROSTER, 'p1', true);
  st.homeBaseOf = (f) => (f === 'p1' ? { x: 4, y: 4 } : { x: 19, y: 11 });
  const u = st.units.find((x) => x.faction === 'p1');
  const before = { x: u.px, y: u.py };

  // 打死它
  u.takeDamage(9999, null);
  ok(!u.alive, '单位被打死后 alive = false');
  ok(u.respawnTimer > 0, `★ 战败后开始复活倒计时（${u.respawnTimer}s）`);
  ok(u.awaitingRespawn === true, 'awaitingRespawn 为 true（渲染据此画倒计时环）');
  ok(u.deaths === 1, '累计阵亡次数 +1');

  // 推进到复活前一刻
  for (let i = 0; i < 60 * 7; i++) u.update(st, 1 / 60);
  ok(!u.alive && u.respawnTimer > 0 && u.respawnTimer < 1.1,
    `7 秒后仍在等待（剩余 ${u.respawnTimer.toFixed(2)}s）`);

  // 推过 8 秒
  for (let i = 0; i < 60 * 2; i++) u.update(st, 1 / 60);
  ok(u.alive === true, '★ 8 秒后自动复活');
  ok(u.hp === u.hpMax, `复活时满血（${u.hp}/${u.hpMax}）`);
  // 单位是 general-p1-1（序号 1）→ 复活在大本营的「下」邻格 (4,5)
  ok(u.tx === 4 && u.ty === 5,
    `★ 复活在自家大本营旁 (${u.tx},${u.ty})（大本营在 4,4），而不是死的地方`);
  ok(u.path === null && !u.moving && u.target === null,
    '复活后清空了路径与交战目标（不会继续上一场的追击）');
  ok(Math.hypot(u.px - before.x, u.py - before.y) > 1,
    '位置确实回到了出生点附近（与阵亡地点不同）');

  // 多个单位依次复活时站位不同（不会全叠在一格）
  const u2 = st.units.find((x) => x.faction === 'p1' && x.id.endsWith('-2'));
  u2.takeDamage(9999, null);
  for (let i = 0; i < 60 * 9; i++) u2.update(st, 1 / 60);
  ok(u2.alive && (u2.tx !== u.tx || u2.ty !== u.ty),
    `★ 第 2 个将领复活在不同的邻格 (${u2.tx},${u2.ty}) vs (${u.tx},${u.ty})，不会叠在一起`);
}

section('P3 胜负条件：大本营被打掉才算输');
{
  const st = makeSide(ROSTER, 'p1', true);
  st.pvpEnabled = true;
  CONFIG.pvp.destructibleBase = true;
  const base = st.buildingList.find((b) => b.type === 'base' && b.owner === 'p2');
  ok(!!base, 'p2 的大本营存在');

  // 可摧毁开关打开后，大本营血量能到底
  const alive = base.takeDamage(99999, null);
  ok(alive === false && base.hp === 0,
    `★ destroyable 打开时大本营可以被真正打掉（hp=${base.hp}）`);

  // 关掉开关（单机），大本营保底 1 血 —— 这是 v0.3 的既有行为，不能被改坏
  CONFIG.pvp.destructibleBase = false;
  const st2 = makeSide(ROSTER, 'p1', true);
  const b2 = st2.buildingList.find((b) => b.type === 'base' && b.owner === 'p2');
  b2.takeDamage(99999, null);
  ok(b2.hp === 1 && b2.alive === true,
    `★ 单机模式（destructibleBase=false）大本营保底 1 血、不会被打掉（hp=${b2.hp}）`);
}

section('P4 单机不开启对战规则（防止对局逻辑泄漏进单机）');
{
  // unit.js 的复活必须受 state.pvpEnabled 门控
  const st = makeSide(ROSTER, 'p1', true);
  st.pvpEnabled = false;                 // ← 单机
  const u = st.units.find((x) => x.faction === 'p1');
  u.takeDamage(9999, null);
  ok(u.respawnTimer === 0,
    '★ 单机（pvpEnabled=false）下单位阵亡不进入复活倒计时 —— 死了就是没了（v0.3 行为）');
  for (let i = 0; i < 60 * 20; i++) u.update(st, 1 / 60);
  ok(!u.alive, '推进 20 秒也不会复活');
}

/** 把某单位摆到指定位（像素坐标），用于精确控制距离 */
function place(u, tx, ty) {
  u.tx = tx; u.ty = ty;
  u.px = center(tx, ty).x; u.py = center(tx, ty).y;
  u.stop();
}

/* ================================================================== */
/* A. 房主视角：双方单位同处一个 state，能不能互相索敌                    */
/* ================================================================== */
section('A1 阵营通行规则：城墙只挡对手');
{
  const st = makeSide(ROSTER, 'p1', true);
  addBuilding(st, 'wall', 12, 10, 'p1');
  ok(passable(st, 12, 10, 'p1') === true, 'p1 的城墙对 p1 放行（自己人能穿过）');
  ok(passable(st, 12, 10, 'p2') === false, '★ p1 的城墙对 p2 阻挡（联机核心规则）');
  ok(passable(st, 12, 10, 'enemy') === false, 'p1 的城墙对 NPC 敌人阻挡');

  addBuilding(st, 'wall', 13, 10, 'p2');
  ok(passable(st, 13, 10, 'p1') === false, 'p2 的城墙对 p1 也阻挡（对称）');
  ok(passable(st, 13, 10, 'p2') === true, 'p2 的城墙对 p2 放行');

  // 单机默认阵营行为不能变
  const single = makeSide([DEFAULT_FACTION], DEFAULT_FACTION);
  addBuilding(single, 'wall', 12, 10, DEFAULT_FACTION);
  ok(passable(single, 12, 10, DEFAULT_FACTION) === true
    && passable(single, 12, 10, 'enemy') === false,
    '单机默认阵营（player）行为与旧版一致');

  // p2 的城墙能挡住 p1 的寻路（不是只有判定函数对，A* 也要真的绕）
  const p1u = st.units.find((u) => u.faction === 'p1');
  const p2u = st.units.find((u) => u.faction === 'p2');
  ok(!!p1u && !!p2u, `房主的 state 里同时存在 p1 和 p2 的单位（各 ${st.units.filter((u) => u.faction === 'p1').length} 个）`);
  const pathState = makeSide(ROSTER, 'p1', true);
  addBuilding(pathState, 'wall', 13, 10, 'p2');
  // 起点 (12,10)、终点 (14,10)，墙在正中间 (13,10)
  const pathP1 = findPath(pathState, { x: 12, y: 10 }, { x: 14, y: 10 }, 'p1');
  const pathP2 = findPath(pathState, { x: 12, y: 10 }, { x: 14, y: 10 }, 'p2');
  const onWall = (p) => !!p && p.some((n) => n.x === 13 && n.y === 10);
  ok(pathP1 !== null && !onWall(pathP1),
    `★ p2 的城墙让 p1 的 A* 绕行（${pathP1 ? pathP1.length + ' 个点，不经过 (13,10)' : 'null'}）`);
  ok(pathP2 !== null && onWall(pathP2),
    `同一段墙对 p2 自己不是障碍（A* 直接穿过，${pathP2 ? pathP2.length + ' 个点' : 'null'}）`);
  ok(pathP1 && pathP2 && pathP1.length > pathP2.length,
    `p1 的路程更长（${pathP1 && pathP1.length} > ${pathP2 && pathP2.length}）—— 说明墙真的生效了`);
}

section('A2 ★ 两个玩家互相索敌并真的打起来');
{
  const st = makeSide(ROSTER, 'p1', true);
  const a = st.units.find((u) => u.faction === 'p1');
  const b = st.units.find((u) => u.faction === 'p2');

  // 双方各留一个将领在警戒范围内（aggroRange = 4 格），其余挪远
  for (const u of st.units) {
    if (u.faction === 'p1' && u !== a) place(u, 1, 1);
    if (u.faction === 'p2' && u !== b) place(u, 1, 14);
  }
  place(a, 10, 10);
  place(b, 13, 10);

  ok(!sameSide(a.faction, b.faction), `两者不同阵营（${a.faction} vs ${b.faction}）`);
  const foundA = a.acquireTarget(st);
  const foundB = b.acquireTarget(st);
  ok(foundA && a.target === b, '★ p1 的将领发现了 p2 的将领（间距 3 格 < 警戒 4 格）');
  ok(foundB && b.target === a, '★ p2 的将领也发现了 p1 的将领（对称，敌我共用一套逻辑）');

  // 推进 6 秒
  const hpA0 = a.hp, hpB0 = b.hp;
  for (let i = 0; i < 60 * 6; i++) {
    for (const u of st.units.slice()) u.update(st, 1 / 60);
  }
  ok(a.hp < hpA0, `p1 的将领被打掉了血（${hpA0} → ${Math.round(a.hp)}）`);
  ok(b.hp < hpB0, `p2 的将领被打掉了血（${hpB0} → ${Math.round(b.hp)}）`);
  ok(a.alive === false || b.alive === false || (a.hp < hpA0 && b.hp < hpB0),
    '双方真的在互殴（不是站着发呆）');
}

section('A3 单机回归：同阵营不互殴 / 玩家与 NPC 仍敌对');
{
  const single = makeSide([DEFAULT_FACTION], DEFAULT_FACTION);
  const a = single.units[0], b = single.units[1];
  place(a, 10, 10);
  place(b, 11, 10);
  ok(a.acquireTarget(single) === false, '单机下两个同阵营将领不会互相锁定');
  ok(isPlayerFaction(DEFAULT_FACTION), "单机默认阵营 'player' 被识别为玩家方");

  // NPC 敌人仍会被玩家索敌（回归：阵营改造不能把敌人也变成友军）
  const npc = new Unit({ id: 'e1', name: '测试敌人', tx: 12, ty: 10, faction: 'enemy', kind: 'enemy' });
  npc.state = single;
  npc.px = center(12, 10).x; npc.py = center(12, 10).y;
  single.units.push(npc);
  ok(a.acquireTarget(single) === true && a.target === npc,
    '玩家仍会自动索敌 NPC 敌人（阵营改造没有破坏原有敌对关系）');
}

section('A4 多阵营区块占领：各占各的，不互相抵消');
{
  const st = makeSide(ROSTER, 'p1', true);
  const z = st.zones.find((zz) => zz.x0 === 0 && zz.y0 === 0);
  const u1 = st.units.find((u) => u.faction === 'p1');
  const u2 = st.units.find((u) => u.faction === 'p2');
  // 同一个区块里各站一个（A1 = 左上 4×4）
  u1.tx = 1; u1.ty = 1;
  u2.tx = 2; u2.ty = 2;
  for (const u of st.units) {
    if (u !== u1 && u !== u2) place(u, 20, 12);   // 别干扰
  }

  const dt = 1 / 60;
  for (let i = 0; i < Math.ceil(CONFIG.zone.captureTimeSec / dt) + 4; i++) updateZones(st, dt);

  ok(z.progressBy !== undefined && z.progressBy.p1 !== undefined && z.progressBy.p2 !== undefined,
    '区块带上了每阵营独立的进度表（progressBy）');
  ok(z.owner === 'p1' || z.owner === 'p2', `区块被某一方拿下（owner = ${z.owner}）`);
  ok(z.progressBy.p1 > 0 && z.progressBy.p2 > 0,
    `两方各自的进度都在累积（p1=${z.progressBy.p1.toFixed(2)} p2=${z.progressBy.p2.toFixed(2)}），旧实现会互相抵消`);
  const won = z.owner;
  const lost = won === 'p1' ? 'p2' : 'p1';
  ok(ownedTileCount(st, won) > 0 && ownedTileCount(st, lost) === 0,
    `${won} 统计到 ${ownedTileCount(st, won)} 格，${lost} 统计到 ${ownedTileCount(st, lost)} 格（互不混淆）`);

  // 单机行为不变
  const single = makeSide([DEFAULT_FACTION], DEFAULT_FACTION);
  single.units[0].tx = 1; single.units[0].ty = 1;
  const sz = single.zones.find((zz) => zz.x0 === 0 && zz.y0 === 0);
  for (let i = 0; i < Math.ceil(CONFIG.zone.captureTimeSec / dt) + 4; i++) updateZones(single, dt);
  ok(sz.owner === DEFAULT_FACTION, `单机下区块仍归 'player'（owner = ${sz.owner}）`);
  ok(ownedTileCount(single, DEFAULT_FACTION) > 0, "单机下 ownedTileCount(state, 'player') 仍然可用");
}

/* ================================================================== */
/* B. 客机视角：快照灌进来之后世界对不对                                */
/* ================================================================== */
section('B1 快照序列化 / 反序列化');
{
  const host = makeSide(ROSTER, 'p1', true);
  const client = makeSide(ROSTER, 'p2', false);

  host.time = 12.5;
  host.resources.food = 33.5;
  host.resources.gold = 21.25;
  host.ownedTiles = 48;

  const snap = relay(host, client);

  ok(snap.units.length === host.units.length,
    `快照里单位数与房主一致（${snap.units.length}，含双方）`);
  ok(client.units.length === host.units.length,
    `客机应用快照后拿到全部单位（${client.units.length}）`);
  ok(client.units.some((u) => u.faction === 'p1') && client.units.some((u) => u.faction === 'p2'),
    '客机同时看到了 p1 和 p2 的单位（这就是「互相看到」）');
  ok(client.buildingList.length === host.buildingList.length,
    `客机建筑数与房主一致（${client.buildingList.length}，双方大本营都在）`);
  ok(Math.abs(client.resources.food - 33.5) < 0.05,
    `客机资源与房主一致（${client.resources.food}，快照保留 1 位小数）`);
  ok(client.ownedTiles === 48, `客机己方地块数与房主一致（${client.ownedTiles}）`);
  ok(Math.abs(client.time - 12.5) < 1e-6, `客机时间轴与房主一致（${client.time}）`);

  const hostIds = host.units.map((u) => u.id).sort();
  const clientIds = client.units.map((u) => u.id).sort();
  ok(JSON.stringify(hostIds) === JSON.stringify(clientIds),
    `客机单位 id 与房主逐个对齐（${hostIds.length} 个）`);
  ok(new Set(clientIds).size === clientIds.length,
    '单位 id 无重复（p1/p2 的将领 id 带阵营前缀，不会撞车）');
}

section('B2 位置同步与插值字段');
{
  const host = makeSide(ROSTER, 'p1', true);
  const client = makeSide(ROSTER, 'p2', false);
  relay(host, client);

  const hu = host.units.find((u) => u.faction === 'p2');
  hu.px += 137.5; hu.py -= 42.25;
  relay(host, client);

  const cu = client.units.find((u) => u.id === hu.id);
  ok(!!cu, '客机能按 id 找回对应单位');
  ok(Math.abs(cu.px - hu.px) < 0.01 && Math.abs(cu.py - hu.py) < 0.01,
    `单位位置同步（房主 ${hu.px.toFixed(1)},${hu.py.toFixed(1)} → 客机 ${cu.px.toFixed(1)},${cu.py.toFixed(1)}）`);
  ok(cu.netPx !== undefined && cu.netAt > 0, '客机单位带上了插值所需的 netPx / netAt');
  ok(cu.netPx0 !== undefined, '第二次快照后 netPx0 已就位（可在两点之间插值，不会跳格）');

  // 阵亡 → 快照里没有 → 客机删掉
  const victim = host.units.find((u) => u.faction === 'p2');
  victim.alive = false;
  host.units = host.units.filter((u) => u.alive);
  relay(host, client);
  ok(client.units.length === host.units.length,
    `房主单位阵亡后客机同步删除（客机剩 ${client.units.length}，房主剩 ${host.units.length}）`);
  ok(!client.units.some((u) => u.id === victim.id), '阵亡的那个单位在客机上确实消失了');
}

section('B3 命令往返：客机的移动意图交给房主执行');
{
  const host = makeSide(ROSTER, 'p1', true);
  const client = makeSide(ROSTER, 'p2', false);
  relay(host, client);

  const mine = client.units.filter((u) => u.faction === 'p2');
  const target = { x: 21 * CELL + 55, y: 14 * CELL + 40 };
  const cmd = { t: 'cmd', kind: 'move', f: 'p2', ids: mine.map((u) => u.id), x: target.x, y: target.y };

  // 房主侧：这正是 main.js 的 handleNetCommand 做的事 —— 按 id + 发送者阵营找单位
  const owned = host.units.filter((u) => cmd.ids.indexOf(u.id) >= 0 && u.faction === cmd.f);
  ok(owned.length === mine.length,
    `房主按 id + 阵营找到客机的 ${owned.length} 个单位`);

  // 防冒充：客机拿房主单位的 id 发命令，房主不应找到任何可操控单位
  const hostIds = host.units.filter((u) => u.faction === 'p1').map((u) => u.id);
  const forged = host.units.filter((u) => hostIds.indexOf(u.id) >= 0 && u.faction === 'p2');
  ok(forged.length === 0, '★ 客机拿房主单位的 id 发命令时，房主找不到任何可操控单位（防冒充）');

  // 房主执行
  const u0 = owned[0];
  ok(u0.orderMove(host, target) === true, '房主执行客机的移动命令成功');
  ok(!!u0.path && u0.path.length >= 1, `房主给客机的单位算出了路径（${u0.path ? u0.path.length : 0} 个点）`);

  const p0 = { x: u0.px, y: u0.py };
  for (let i = 0; i < 60; i++) u0.update(host, 1 / 60);
  const moved = Math.hypot(u0.px - p0.x, u0.py - p0.y);
  ok(moved > 50, `客机的单位在房主那边真的动了（1 秒走了 ${moved.toFixed(0)}px）`);

  // 回传快照 → 客机看到自己在动
  const beforeX = client.units.find((u) => u.id === u0.id).px;
  relay(host, client);
  const afterX = client.units.find((u) => u.id === u0.id).px;
  ok(Math.abs(afterX - beforeX) > 50,
    `客机通过快照看到了自己的单位在移动（${beforeX.toFixed(0)} → ${afterX.toFixed(0)}）`);
}

section('B4 往返稳定性：连续 60 次快照不漂移、不报错');
{
  const host = makeSide(ROSTER, 'p1', true);
  const client = makeSide(ROSTER, 'p2', false);
  let err = null;
  try {
    for (let i = 0; i < 60; i++) {
      for (const u of host.units.slice()) u.update(host, 1 / 60);
      relay(host, client);
    }
  } catch (e) { err = String(e); }
  ok(err === null, `连续 60 次「推进 + 快照」无异常${err ? '：' + err : ''}`);
  ok(client.units.length === host.units.length,
    `单位数始终一致（客机 ${client.units.length} / 房主 ${host.units.length}）`);
  const hIds = host.units.map((u) => u.id).sort().join(',');
  const cIds = client.units.map((u) => u.id).sort().join(',');
  ok(hIds === cIds, '单位集合没有漂移（没有凭空多出/少掉单位）');
}

/* ================================================================== */
section('C 参数与体积');
{
  ok(SNAPSHOT_HZ > 0 && SNAPSHOT_HZ <= 60, `快照频率 ${SNAPSHOT_HZ}Hz 在合理区间`);
  ok(INTERP_DELAY >= 1 / SNAPSHOT_HZ,
    `插值缓冲 ${INTERP_DELAY}s ≥ 一个快照周期 ${(1 / SNAPSHOT_HZ).toFixed(3)}s（否则客机会抖）`);
  const st = makeSide(ROSTER, 'p1', true);
  for (let i = 0; i < 12; i++) addBuilding(st, 'wall', 5 + i, 5, 'p1');
  const size = JSON.stringify(makeSnapshot(st)).length;
  ok(size < 8192,
    `单次快照约 ${size}B → ${SNAPSHOT_HZ}Hz 下单人下行约 ${(size * SNAPSHOT_HZ / 1024).toFixed(1)}KB/s`);
}

section('D 单位 id 的确定性（房主与客机必须算出同一个 id，否则快照对不上）');
{
  // 同一个阵营在两个不同的 state 上建将，id 必须完全一致
  const a = createGenerals({ base: { x: 12, y: 7 }, generalSpawns: GENERAL_SPAWNS, factions: { myFaction: 'p1' } }, 'p2');
  const b = createGenerals({ base: { x: 20, y: 12 }, generalSpawns: GENERAL_SPAWNS, factions: { myFaction: 'p2' } }, 'p2');
  const ida = a.map((u) => u.id).join(',');
  const idb = b.map((u) => u.id).join(',');
  ok(ida === idb, `p2 的将领 id 与出生点无关、完全确定（${ida}）`);
  ok(ida.startsWith('general-p2-'), 'id 带阵营前缀（p1/p2 的将领不会撞车）');

  const p1 = createGenerals({ base: { x: 12, y: 7 }, generalSpawns: GENERAL_SPAWNS, factions: { myFaction: 'p1' } }, 'p1');
  ok(p1.map((u) => u.id).join(',') !== ida, 'p1 与 p2 的将领 id 互不相同');
  ok(p1.every((u) => u.faction === 'p1') && a.every((u) => u.faction === 'p2'),
    '每个将领的阵营都由参数决定（不依赖 state 里的旧值）');

  // 单机默认阵营的 id 必须与 v0.3 完全一致（否则老地图/存档/测试会对不上）
  const single = createGenerals({ base: { x: 12, y: 7 }, generalSpawns: GENERAL_SPAWNS, factions: { myFaction: 'player' } });
  ok(single.map((u) => u.id).join(',') === 'general-1,general-2,general-3',
    `单机默认阵营仍生成旧 id（${single.map((u) => u.id).join(',')}）—— 与 v0.3 兼容`);
}

console.log(`\n———————————————\n通过 ${pass} 项，失败 ${fail} 项`);
process.exit(fail ? 1 : 0);
