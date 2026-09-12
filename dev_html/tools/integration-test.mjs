/**
 * tools/integration-test.mjs —— 无浏览器集成测试（不需要 Chrome / Edge）
 * 运行：node tools/integration-test.mjs
 *
 * 用**最小 DOM 桩**在 Node 里加载真实的 js/main.js：init()、主循环 update()、
 * 敌人 AI、战斗 / 警戒、事件日志、选中状态的清理都会真的跑一遍，
 * 所以“模块之间接线错了”这类问题（例如旧版把地块坐标塞进像素路径）能在这里抓到。
 *
 * 与另外两个测试的分工：
 *   - tools/smoke-test.mjs     ：直接 import 各模块，测纯逻辑（寻路 / 直线 / 战斗数值）
 *   - tools/integration-test.mjs：本文件，测 main.js 的整体接线与主循环
 *   - tools/browser-test.py    ：真实浏览器里的渲染与交互回归（需要 Chrome / Edge）
 */

const ctx2d = new Proxy({}, {
  get: (_t, k) => {
    if (k === 'getTransform') return () => ({ a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 });
    if (k === 'measureText') return () => ({ width: 10 });
    return () => {};
  },
  set: () => true,
});

const els = {};
function makeEl(id) {
  return {
    id, textContent: '', innerHTML: '', dataset: {}, style: {},
    clientWidth: 1200, clientHeight: 700, scrollTop: 0, scrollHeight: 0,
    classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
    addEventListener() {}, getBoundingClientRect: () => ({ left: 0, top: 0, width: 1200, height: 700 }),
    getContext: () => ctx2d,
  };
}

globalThis.window = globalThis;
globalThis.devicePixelRatio = 1;
globalThis.addEventListener = () => {};
globalThis.removeEventListener = () => {};
globalThis.requestAnimationFrame = () => 0;      // 不自动跑主循环，测试里手动 tick
globalThis.document = { getElementById: (id) => (els[id] || (els[id] = makeEl(id))), addEventListener() {} };
globalThis.ResizeObserver = class { observe() {} };

let pass = 0, fail = 0;
const ok = (cond, msg) => { if (cond) { pass++; console.log(`  ✔ ${msg}`); } else { fail++; console.log(`  ✘ ${msg}`); } };
const CELL = 120;

await import('../js/main.js');
const R = globalThis.RTS;
const s = R.state;
const step = (n) => { for (let i = 0; i < n; i++) R.tick(1 / 60); };

console.log('\n== 真实 main.js 集成（DOM 桩） ==');
ok(!!R && !!s, 'main.js 初始化完成，window.RTS 可用');
ok(s.units.filter((u) => u.faction === 'player').length === 3, `开局 3 个将领（实际 ${s.units.length} 个单位）`);
ok(!!s.buildings.get(s.base.x, s.base.y), '大本营已放置在地图上');
ok(s.zones.length === 24 && s.zoneLookup.length === 24 * 16, '区块系统建立完成');

// 直线移动
const g1 = s.units[0];
R.selectUnits([g1]);
const click = { x: 20 * CELL + 7.5, y: 12 * CELL + 108 };
ok(g1.orderMove(s, click) === true, '右键移动命令下达成功');
ok(g1.path.length === 1, `开阔地路径被拉直为一条直线（路径点 ${g1.path.length} 个）`);
ok(els.selDetail.textContent.indexOf('攻击') >= 0,
   `选中面板显示了攻击数值：“${els.selDetail.textContent.split('\n')[1] || ''}”`);
step(60 * 20);
ok(Math.abs(g1.px - click.x) < 0.01 && Math.abs(g1.py - click.y) < 0.01, '将领沿直线走到了点击位置');

let drawErr = null;
try { R.drawOnce(); } catch (err) { drawErr = String(err); }
ok(drawErr === null, `渲染一帧无异常${drawErr ? '：' + drawErr : ''}`);

// 敌人 AI：朝大本营推进（旧版把地块坐标当像素用，会一路走到地图左上角）
const before = s.units.length;
const e1 = R.spawnEnemy();
ok(!!e1 && s.units.length === before + 1, `刷出测试敌人 (${e1.tx},${e1.ty})`);
const d0 = Math.hypot(e1.px - (s.base.x + 0.5) * CELL, e1.py - (s.base.y + 0.5) * CELL);
step(60 * 3);
const d1 = Math.hypot(e1.px - (s.base.x + 0.5) * CELL, e1.py - (s.base.y + 0.5) * CELL);
ok(e1.alive && d1 < d0, `敌人朝大本营推进：${d0.toFixed(0)}px → ${d1.toFixed(0)}px`);
ok(e1.path && e1.path.every((p) => p.x >= 0 && p.x <= 24 * CELL && p.y >= 0 && p.y <= 16 * CELL),
   '敌人的路径点是像素坐标（旧版把地块坐标当像素用）');
ok(s.log.some((l) => l.indexOf('测试敌人') >= 0), '刷兵会写事件日志');

// 警戒 + 战斗
const g3 = s.units.find((u) => u.faction === 'player' && u.alive);
g3.stop();
const e2 = R.spawnEnemy(g3.tx + 3, g3.ty);
ok(!!e2, `在将领 ${g3.name} 旁边刷出敌人 (${e2.tx},${e2.ty})`);
step(1);
ok(g3.target === e2, '静止的将领自动警戒并锁定附近敌人');
ok(s.log.some((l) => l.indexOf('进入警戒') >= 0),
   `事件日志记录警戒：“${s.log.filter((l) => l.indexOf('进入警戒') >= 0).pop()}”`);
const hp0 = e2.hp;
step(60 * 3);
ok(e2.hp < hp0, `将领主动接敌并造成伤害（敌人 ${hp0} → ${e2.hp}）`);
step(60 * 20);
ok(!e2.alive && s.units.indexOf(e2) < 0, '敌人被击杀并从单位表里移除');
ok(s.log.some((l) => l.indexOf('阵亡') >= 0),
   `事件日志记录阵亡：“${s.log.filter((l) => l.indexOf('阵亡') >= 0).pop()}”`);

// 选中单位阵亡后自动清理选中状态
R.selectUnits([g3]);
ok(s.ui.selectedUnits.length === 1, '选中一个将领');
g3.takeDamage(99999);
step(1);
ok(s.ui.selectedUnits.length === 0, '选中的将领阵亡后，选中列表自动清空（不会指向死单位）');
ok(s.ui.toasts.some((t) => t.msg.indexOf('阵亡') >= 0),
   `阵亡会弹提示（toast 数据：“${(s.ui.toasts.filter((t) => t.msg.indexOf('阵亡') >= 0)[0] || {}).msg}”）`);

// 战斗总开关
const g4 = s.units.find((u) => u.faction === 'player' && u.alive);
g4.stop();
const e3 = R.spawnEnemy(g4.tx + 2, g4.ty);
R.CONFIG.combat.enabled = false;
step(60);
ok(g4.target === null && e3.alive && e3.hp === e3.hpMax, 'CONFIG.combat.enabled=false 时不索敌、不造成伤害');
R.CONFIG.combat.enabled = true;

// ---- 城墙血量 + 敌人拆墙：真实 updateEnemies 走完整条链路 ----
s.units = s.units.filter((u) => u.faction !== 'enemy');            // 先清场
s.units.filter((u) => u.faction === 'player').forEach((u) => {      // 将领挪远，别插手拆墙
  u.tx = 2; u.ty = 2; u.px = 2.5 * CELL; u.py = 2.5 * CELL; u.stop();
});
R.selectBuildType('wall');
const ring = [[0, -1], [1, 0], [0, 1], [-1, 0]].map(([dx, dy]) => [s.base.x + dx, s.base.y + dy]);
ring.forEach(([x, y]) => R.tryBuildAt(x, y));
R.selectBuildType(null);
const walls = ring.map(([x, y]) => s.buildings.get(x, y));
ok(walls.every((w) => w && w.hp === R.CONFIG.building.wall.hpMax),
   `把大本营围住的 ${walls.length} 段城墙都是满血 ${R.CONFIG.building.wall.hpMax}`);
R.selectBuilding(walls[0]);
ok(els.selDetail.textContent.indexOf('生命') >= 0,
   `选中城墙后面板显示血量：“${els.selDetail.textContent}”`);

const e4 = R.spawnEnemy(ring[1][0] + 2, ring[1][1]);               // 从东侧靠近围墙
ok(!!e4, `在围墙外刷出敌人 (${e4.tx},${e4.ty})`);
let lockTicks = 0;
while (lockTicks < 60 * 8 && !e4.targetBuilding) { step(1); lockTicks++; }
ok(!!e4.targetBuilding && e4.targetBuilding.type === 'wall',
   `敌人被围墙挡住后锁定城墙来拆（${(lockTicks / 60).toFixed(1)} 秒，目标 ${e4.targetBuilding ? '(' + e4.targetBuilding.tx + ',' + e4.targetBuilding.ty + ')' : 'null'}）`);
const locked = e4.targetBuilding;
const hpBefore = locked.hp;
step(60 * 3);
ok(locked.hp < hpBefore, `城墙挨打掉血：${hpBefore} → ${locked.hp}（每次 ${R.CONFIG.combat.buildingDamage}）`);
ok((hpBefore - locked.hp) % R.CONFIG.combat.buildingDamage === 0,
   '掉血量是单次伤害的整数倍（一下一下拆，不是每帧扣一点）');
let siegeErr = null;
try { R.drawOnce(); } catch (err) { siegeErr = String(err); }
ok(siegeErr === null, `掉血中的城墙渲染一帧无异常（血条 / 受击闪光）${siegeErr ? '：' + siegeErr : ''}`);

let siege = 0;
while (siege < 60 * 40 && locked.alive) { step(1); siege++; }
ok(!locked.alive && s.buildings.get(locked.tx, locked.ty) === null,
   `城墙被打光后从地图上移除（再花 ${(siege / 60).toFixed(1)} 秒）`);
ok(s.log.some((l) => l.indexOf('拆毁') >= 0),
   `事件日志记录拆毁：“${s.log.filter((l) => l.indexOf('拆毁') >= 0).pop()}”`);
let after = 0;
while (after < 60 * 10 && Math.abs(e4.tx - s.base.x) + Math.abs(e4.ty - s.base.y) > 1) { step(1); after++; }
ok(Math.abs(e4.tx - s.base.x) + Math.abs(e4.ty - s.base.y) <= 1,
   `围墙出现缺口后敌人走了进来，停在大本营旁 (${e4.tx},${e4.ty})`);

// ---- 回归：用一整条城墙拦断“敌人 → 大本营”的路线（修复前敌人会站在出生点发呆） ----
s.units = s.units.filter((u) => u.faction !== 'enemy');
s.units.filter((u) => u.faction === 'player').forEach((u) => {
  u.tx = 2; u.ty = 2; u.px = 2.5 * CELL; u.py = 2.5 * CELL; u.stop();
});
s.buildingList.slice().forEach((b) => { if (b.type === 'wall') R.removeBuildingFor(s, b); });
R.selectBuildType('wall');
let line = 0, blockedCol = 0;
for (let y = 0; y < 16; y++) {
  if (R.tryBuildAt(13, y)) line++;
  if (s.terrain.get(13, y) === 'mountain' || s.buildings.get(13, y)) blockedCol++;
}
R.selectBuildType(null);
ok(line === 15 && blockedCol === 16,
   `用一整列城墙 + 山地拦断路线（新建 ${line} 段，col 13 整列 ${blockedCol}/16 格不通）`);

const e5 = R.spawnEnemy(22, 2);
ok(!!e5, `敌人在东侧出生 (${e5.tx},${e5.ty})`);
const stuck0 = { x: e5.px, y: e5.py };
step(60 * 2);
const movedEarly = Math.hypot(e5.px - stuck0.x, e5.py - stuck0.y);
ok(movedEarly > 100, `★ 出生后不再发呆：2 秒走了 ${movedEarly.toFixed(0)}px（修复前恒为 0px）`);
ok(e5.targetBuilding === null || e5.targetBuilding.type === 'wall',
   '途中只会锁定城墙，不会去追别的目标');

let seekT = 0;
while (seekT < 60 * 25 && !e5.targetBuilding) { step(1); seekT++; }
ok(!!e5.targetBuilding,
   `自己走到墙边并锁定要拆的那一段 (${e5.targetBuilding ? e5.targetBuilding.tx + ',' + e5.targetBuilding.ty : 'null'})（${(seekT / 60).toFixed(1)} 秒）`);
const lineWall = e5.targetBuilding;

let breakT = 0;
while (breakT < 60 * 60 && lineWall.alive) { step(1); breakT++; }
ok(!lineWall.alive, `把拦路的墙拆穿（${(breakT / 60).toFixed(1)} 秒）`);
ok(s.log.some((l) => l.indexOf('拆毁') >= 0),
   `事件日志记录拆毁：“${s.log.filter((l) => l.indexOf('拆毁') >= 0).pop()}”`);

let arriveT = 0;
while (arriveT < 60 * 30 && Math.abs(e5.tx - s.base.x) + Math.abs(e5.ty - s.base.y) > 1) { step(1); arriveT++; }
ok(Math.abs(e5.tx - s.base.x) + Math.abs(e5.ty - s.base.y) <= 1,
   `从缺口走到大本营旁 (${e5.tx},${e5.ty})（出生 → 到达约 ${((2 + seekT + breakT + arriveT) / 60).toFixed(0)} 秒）`);

console.log(`\n———————————————\n通过 ${pass} 项，失败 ${fail} 项`);
process.exit(fail === 0 ? 0 : 1);
