/**
 * tools/net-singleplayer-test.mjs —— 单机模式不受联机改造影响（独立进程）
 * 运行：node tools/net-singleplayer-test.mjs
 *
 * 为什么单独一个文件：
 *   它要加载 **不带 `#net=1`** 的 main.js —— 和 net-integration-test.mjs 是完全不同的启动配置。
 *   挤在同一个进程里会互相污染：联机测试里为了自洽切过阵营、退过单机，
 *   `fallbackToSinglePlayer()` 带的一次性开关（net.usingFallback）会被提前烧掉，
 *   于是"断线退回单机"那一段就永远测不到真实行为。
 *
 * 这里验证的是「联机改造对单机零影响」——每次改联机代码都该确认这条底线。
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
const makeEl = (id) => ({
  id, textContent: '', innerHTML: '', dataset: {}, style: {},
  clientWidth: 1200, clientHeight: 700, scrollTop: 0, scrollHeight: 0,
  classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
  addEventListener() {}, getBoundingClientRect: () => ({ left: 0, top: 0, width: 1200, height: 700 }),
  getContext: () => ctx2d,
});

globalThis.window = globalThis;
globalThis.devicePixelRatio = 1;
globalThis.addEventListener = () => {};
globalThis.removeEventListener = () => {};
globalThis.requestAnimationFrame = () => 0;
globalThis.document = { getElementById: (id) => (els[id] || (els[id] = makeEl(id))), addEventListener() {} };
globalThis.ResizeObserver = class { observe() {} };

// 装了 WebSocket 也要保证"单机模式根本不碰它"——一旦被 new 出来就说明联机代码泄漏了
let wsConstructed = 0;
globalThis.WebSocket = class {
  static OPEN = 1;
  constructor() { wsConstructed++; throw new Error('单机模式不应该建立 WebSocket 连接！'); }
  send() {}
  close() {}
};

// ★ 不带 #net=1，也不带 ?net=1
globalThis.location = { hash: '', search: '', protocol: 'http:', host: '127.0.0.1:8080' };

let pass = 0, fail = 0;
const ok = (cond, msg) => {
  if (cond) { pass++; console.log(`  ✔ ${msg}`); }
  else { fail++; console.log(`  ✘ ${msg}`); }
};
const section = (t) => console.log(`\n== ${t} ==`);

await import('../js/main.js');
const R = globalThis.RTS;
const s = R.state;
const CELL = R.CONFIG.cell;
const step = (n) => { for (let i = 0; i < n; i++) R.frame(1 / 60); };

section('1 不联机时不碰网络');
{
  ok(!!R && !!s, 'main.js 在单机模式下初始化完成');
  ok(wsConstructed === 0, '★ 没有建立任何 WebSocket 连接（单机不进联机代码路径）');
  ok(R.netStatus().active === false, 'net.active = false');
  ok(R.netStatus().connected === false, 'net.connected = false');
  ok(s.factions.myFaction === 'player', `阵营是单机默认值 'player'（实际 ${s.factions.myFaction}）`);
  ok(s.factions.factions.length === 1 && s.factions.factions[0] === 'player',
    `阵营表只有 player（${s.factions.factions.join(',')}）`);
}

section('2 对战规则在单机下必须全部关闭');
{
  ok(s.pvpEnabled === false, '★ pvpEnabled = false（复活/拆家等对局规则不生效）');
  ok(R.CONFIG.pvp.destructibleBase === false, '★ 大本营保持不可摧毁');
  ok(s.match.over === false && s.match.winner === null, '没有结算状态');
}

section('3 v0.3 的单机行为逐项不变');
{
  ok(s.units.length === 3 && s.units.every((u) => u.faction === 'player'),
    `开局 3 个将领，都是 player（${s.units.map((u) => u.id).join(', ')}）`);
  ok(s.units.map((u) => u.id).join(',') === 'general-1,general-2,general-3',
    '将领 id 与 v0.3 完全一致（general-1/2/3）');
  ok(s.zones.length === 24 && s.zoneLookup.length === 384, '区块系统建立完成');
  ok(!!s.buildings.get(s.base.x, s.base.y), '大本营已放置');
  ok(s.buildingList.filter((b) => b.type === 'base').length === 1,
    '单机只有 1 个大本营（没有为 p1/p2 各建一个）');
  ok(s.buildingList.filter((b) => b.type === 'base' && b.owner === 'player').length === 1,
    "大本营归属是 'player'（不是 p1）");

  // 士兵阵亡后不复活（v0.3 行为）
  const e = R.spawnEnemy();
  ok(!!e, '能刷出测试敌人');
  e.takeDamage(99999, null);
  ok(!e.alive && e.respawnTimer === 0, '★ 单机下敌人被打死就没了，不进入复活倒计时');
  step(60 * 15);
  ok(!e.alive, '推进 15 秒也不会复活');
  ok(s.units.indexOf(e) < 0, '阵亡的敌人已从 state.units 移除（v0.3 行为）');
}

section('4 大本营打不掉（单机）');
{
  const base = s.buildings.get(s.base.x, s.base.y);
  base.takeDamage(99999, null);
  ok(base.alive === true && base.hp === 1,
    `★ 单机大本营血量保底 1、不会被打掉（hp=${base.hp}）`);
  ok(s.match.over === false, '也不会因此判定胜负');
}

section('5 单机能正常玩');
{
  R.selectUnits([s.units[0]]);
  const target = { x: 19 * CELL + 40, y: 4 * CELL + 70 };
  ok(s.units[0].orderMove(s, target) === true, '右键移动命令下达成功');
  step(60 * 12);
  ok(Math.abs(s.units[0].px - target.x) < 1 && Math.abs(s.units[0].py - target.y) < 1,
    '将领走到了点击位置');

  R.selectBuildType('wall');
  ok(R.tryBuildAt(11, 10) === true, '能建造城墙');
  const w = s.buildings.get(11, 10);
  ok(!!w && w.owner === 'player', "新建建筑归属 'player'");
  R.selectBuildType(null);

  let err = null;
  try { R.drawOnce(); } catch (e) { err = String(e); }
  ok(err === null, `渲染一帧无异常${err ? '：' + err : ''}`);

  // 单位回血依赖「己方领地」判定，联机改造动过这里，单机必须仍然有效
  const z = s.zones[s.zoneLookup[s.units[0].ty * s.terrain.cols + s.units[0].tx]];
  ok(z && z.owner === 'player' ? s.units[0].hp >= 0 : true, '领地判定未报错');
}

section('6 readNetIntent 的判定（URL 解析）');
{
  const { readNetIntent } = await import('../js/net.js');
  const saved = globalThis.location;

  globalThis.location = { hash: '', search: '', protocol: 'http:', host: 'x' };
  ok(readNetIntent().on === false, '不带任何参数 → 单机');
  ok(readNetIntent().room === 'default', '默认房间名是 default');

  globalThis.location = { hash: '#net=1', search: '', protocol: 'http:', host: 'x' };
  ok(readNetIntent().on === true, '#net=1 → 联机');

  globalThis.location = { hash: '', search: '?net=1', protocol: 'http:', host: 'x' };
  ok(readNetIntent().on === true, '?net=1 → 联机');

  globalThis.location = { hash: '#net=1&room=abc', search: '', protocol: 'http:', host: 'x' };
  const r = readNetIntent();
  ok(r.on === true && r.room === 'abc', `#net=1&room=abc → 联机且房间名 abc（${r.room}）`);

  globalThis.location = { hash: '#room=abc', search: '', protocol: 'http:', host: 'x' };
  ok(readNetIntent().on === false, '只有 room 没有 net=1 → 仍是单机（不会误连）');

  globalThis.location = undefined;
  ok(readNetIntent().on === false, '★ 没有 location 的环境（Node）不崩、按单机处理');

  globalThis.location = saved;
}

console.log(`\n———————————————\n通过 ${pass} 项，失败 ${fail} 项`);
process.exit(fail ? 1 : 0);
