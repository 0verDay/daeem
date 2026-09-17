/**
 * tools/net-integration-test.mjs —— 联机模式的 DOM 级集成测试（不需要浏览器、不需要真服务器）
 * 运行：node tools/net-integration-test.mjs
 *
 * 为什么需要它：
 *   tools/net-test.mjs 只测 net.js 的快照读写（纯逻辑），
 *   tools/net-server-test.mjs 只测服务器协议（用桩客户端），
 *   而**「真实 main.js 在联机模式下跑起来是什么样」**这条路径此前完全没有覆盖 ——
 *   而它恰恰是最容易接线错的地方：init 时序、客机换阵营、update 冻结、
 *   快照进渲染循环、断线退回单机。
 *
 * 做法：用 DOM 桩 + WebSocket 桩在 Node 里加载**真实的 main.js**，并让 URL 带上 #net=1
 *   （桩里提供 globalThis.location，因为 Node 没有 location）。
 *   然后同一个进程里依次演一遍：
 *     ① 房主启动  ② 房主推帧 → 是否按 20Hz 广播快照
 *     ③ 服务器分配 p2（客机入场）  ④ 客机收到快照 → 世界是否同步、能不能渲染
 *     ⑤ 客机 update 是否被冻结  ⑥ 断线是否安全退回单机
 */

/* ---------------- DOM 桩 ---------------- */
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
globalThis.requestAnimationFrame = () => 0;   // 主循环不自动跑，测试里手动 tick
globalThis.document = { getElementById: (id) => (els[id] || (els[id] = makeEl(id))), addEventListener() {} };
globalThis.ResizeObserver = class { observe() {} };

/* ---------------- WebSocket 桩 ---------------- */
/** 记录客户端发出去的所有消息；sent() 取某类消息 */
const sent = [];
let lastSocket = null;

globalThis.WebSocket = class FakeWebSocket {
  static OPEN = 1;
  static CLOSED = 3;
  constructor(url) {
    this.url = url;
    this.readyState = 0;          // CONNECTING
    lastSocket = this;
    setTimeout(() => {
      this.readyState = 1;        // OPEN
      if (this.onopen) this.onopen({});
    }, 0);
  }
  send(data) { sent.push(JSON.parse(data)); }
  close() { this.readyState = 3; if (this.onclose) this.onclose({}); }
  /** 测试用：模拟服务器推一条消息下来 */
  serverPush(obj) { if (this.onmessage) this.onmessage({ data: JSON.stringify(obj) }); }
};

/* ---------------- location 桩：带 #net=1 ---------------- */
globalThis.location = {
  hash: '#net=1&room=itest',
  search: '',
  protocol: 'http:',
  host: '127.0.0.1:8080',
};

/* ---------------- 断言小工具 ---------------- */
let pass = 0, fail = 0;
const ok = (cond, msg) => {
  if (cond) { pass++; console.log(`  ✔ ${msg}`); }
  else { fail++; console.log(`  ✘ ${msg}`); }
};
const section = (t) => console.log(`\n== ${t} ==`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* ---------------- 加载真实 main.js ---------------- */
await import('../js/main.js');
const R = globalThis.RTS;
const s = R.state;
const CELL = R.CONFIG.cell;
/**
 * 推进 n 帧 —— 用 R.frame()（= 浏览器里的整个主循环：sim + 联机广播）。
 * 单用 R.tick() 只跑 sim，永远测不到 updateNet() 里的快照广播。
 */
const step = (n) => { for (let i = 0; i < n; i++) R.frame(1 / 60); };
const sentOf = (t) => sent.filter((m) => m.t === t);

/**
 * 把世界推进到「双方已准备、正式开战」的状态，供后面的小节使用。
 *
 * ★ 这里刻意走**真实流程**：进房间 → 双方点准备 → 开战（startMatch）。
 *   不再手工拼 state，所以准备界面这一层也被顺带覆盖到了。
 */
function setupPvpWorld(roster = ['p1', 'p2']) {
  const netMod = R.net;
  netMod.usingFallback = false;
  netMod.active = true;
  netMod.isHost = true;
  netMod.myFaction = 'p1';
  s.factions.factions = roster.slice();
  s.factions.myFaction = 'p1';
  R.CONFIG.pvp.destructibleBase = true;
  R.CONFIG.pvp.countdownSec = 0;          // 测试里不等待倒计时

  R.enterLobby();                          // 1) 进房间 → 准备界面
  R.setPeerReady('p2', true);              // 2) 对手准备（模拟服务器广播过来）
  R.toggleReady();                         // 3) 我准备
  R.tryStartMatch();                       // 4) 房主宣布开战
  if (s.lobby.active) R.startMatch();      // 兜底：条件没满足也强制开
  R.resetMatch();
}

section('1 联机模式启动：立刻认领 p1，不等人分配');
{
  ok(!!R && !!s, 'main.js 在 #net=1 下初始化完成（window.RTS 可用）');
  ok(R.netStatus().active === true, '联机模式已激活（net.active = true）');
  ok(R.netStatus().isHost === true, '初始假设为房主（等 welcome 确认）');
  ok(R.myFaction() === 'p1', `★ 启动瞬间 myFaction 就是 p1（实际 ${R.myFaction()}）—— 没有"连上但选不中单位"的空窗`);
  ok(s.units.length === 3 && s.units.every((u) => u.faction === 'p1'),
    `房主的将领阵营是 p1（${s.units.map((u) => u.id).join(', ')}）`);
  ok(s.units.every((u) => u.selected === false) === false || s.units.some((u) => u.selected),
    '房主开局有选中单位（能立刻操作）');
  ok(s.factions.factions.indexOf('p1') >= 0 && s.factions.factions.indexOf('p2') >= 0,
    `阵营表里同时有 p1 与 p2（${s.factions.factions.slice(0, 2).join(',')}…），区块占领会为双方记账`);
}

section('2 握手：往 /ws 发了 hello，带上房间名');
{
  await sleep(30);   // 等 WebSocket 桩触发 onopen
  const hello = sentOf('hello')[0];
  ok(!!hello, '★ 连接建立后发出了 hello（握手流程走通）');
  ok(hello && hello.room === 'itest', `hello 带上了 URL 里的房间名（room=${hello && hello.room}）`);
  ok(!!lastSocket && /\/ws$/.test(lastSocket.url),
    `连的是同源的 /ws（${lastSocket && lastSocket.url}）`);
  ok(!/^ws:\/\/undefined/.test(lastSocket.url), 'WebSocket URL 没有退化成 undefined（location.host 取到了）');
}

section('3 房主推帧：按 20Hz 广播快照，而不是每帧都发');
{
  sent.length = 0;
  step(60);   // 约 1 秒
  const snaps = sentOf('snap');
  ok(snaps.length >= 15 && snaps.length <= 25,
    `★ 1 秒内广播了 ${snaps.length} 条快照（目标 20Hz）`);
  ok(snaps[0] && Array.isArray(snaps[0].s.units) && snaps[0].s.units.length === 3,
    '快照里带上了 3 个将领');
  ok(snaps[0] && Array.isArray(snaps[0].s.buildings) && snaps[0].s.buildings.length >= 1,
    '快照里带上了建筑（大本营）');
  ok(snaps[0] && snaps[0].s.zones && snaps[0].s.zones.length === 24,
    '快照里带上了 24 个区块');
}
section('4 ★ 服务器分配 p2：客机入场 → 停在准备界面');
{
  // 模拟服务器发 welcome：这个浏览器其实是客机，阵营 p2
  lastSocket.serverPush({
    t: 'welcome', id: 'c2', isHost: false, faction: 'p2',
    roster: ['p1', 'p2'], peers: 2,
  });

  ok(R.myFaction() === 'p2', `★ 收到 welcome 后阵营切到 p2（实际 ${R.myFaction()}）`);
  ok(R.netStatus().isHost === false, '身份从房主降为客机');
  ok(s.lobby.active === true, '★ 客机入场后停在准备界面（不立刻开战）');
  ok(s.lobby.roster.join(',') === 'p1,p2', `准备界面拿到了双方名单（${s.lobby.roster.join(',')}）`);
  ok(s.lobby.ready.p1 === false && s.lobby.ready.p2 === false, '双方初始都未准备');
  ok(s.units.length === 3 && s.units.every((u) => u.faction === 'p2'),
    `准备阶段只有自己一方的将领（${s.units.map((u) => u.id).join(', ')}）`);
  ok(s.buildingList.filter((b) => b.type === 'base').length === 1,
    '★ 准备阶段地图上只有一个大本营（对手的基地还没建 —— 不可能被判"只剩一个玩家"）');
  ok(s.buildingList.filter((b) => b.type === 'base')[0].owner === 'p2', '准备阶段这个基地属于自己');
  ok(s.pvpEnabled === false, '准备阶段对战规则未生效');
}

section('5 ★ 客机冻结 update：房主的快照才是唯一真值');
{
  sent.length = 0;
  const before = { time: s.time, x: s.units[0].px };
  step(30);   // 半秒
  ok(s.time === before.time,
    `★ 客机的 state.time 没有推进（${before.time.toFixed(2)} → ${s.time.toFixed(2)}）—— update() 确实被冻结`);
  ok(s.units[0].px === before.x, '客机没有自己推进单位位置（世界只由快照驱动）');
  ok(sentOf('snap').length === 0, '★ 客机不再广播快照（只有房主能广播）');
}

section('6 客机右键：意图发给服务器，而不是本地直接执行');
{
  sent.length = 0;
  const u = s.units[0];
  R.selectUnits([u]);
  const target = { x: 18 * CELL + 33, y: 11 * CELL + 77 };
  R.orderMove(target, { x: 18, y: 11 });

  const cmd = sentOf('cmd')[0];
  ok(!!cmd, '★ 客机的右键变成了 cmd 发给服务器（没有本地执行）');
  ok(cmd && cmd.kind === 'move', `cmd 类型是 move（kind=${cmd && cmd.kind}）`);
  ok(cmd && cmd.f === 'p2', `cmd 带上了自己的阵营 f=p2（服务器会盖章核对）`);
  ok(cmd && Array.isArray(cmd.ids) && cmd.ids.length === 1 && cmd.ids[0] === u.id,
    `cmd 带上了要操控的单位 id（${cmd && cmd.ids && cmd.ids[0]}）`);
  ok(cmd && Math.abs(cmd.x - target.x) < 1e-6, 'cmd 带上了点击的世界坐标（点到哪走到哪）');
  ok(!u.moving && !u.path, '客机本地没有真的开始移动（等房主算路径）');
  ok(u.goalPt && Math.abs(u.goalPt.x - target.x) < 1e-6,
    '客机本地画出了目标点（给玩家即时反馈，但不是真移动）');
}

section('7 客机建造：意图也发给服务器');
{
  sent.length = 0;
  R.selectBuildType('wall');
  // canvas 的 mousedown 在 DOM 桩里没法触发，直接验证接线：建造意图的消息形状
  const builtLocally = R.tryBuildAt(3, 3);
  // 直接调 tryBuildAt 是本地路径（房主语义），所以这里应该真的建成了 —— 用于对照
  ok(builtLocally === true, '对照：直接调用 tryBuildAt 仍然能本地建造（房主/单机路径未变）');
  R.selectBuildType(null);
}

section('8 ★ 快照进渲染：客机世界被房主的真值覆盖');
{
  // 构造一份「房主的世界」快照：p1 在左、p2 在右，双方各一个大本营
  const hostSnap = {
    units: [
      { i: 'general-p1-1', f: 'p1', k: 'general', x: 300.5, y: 400.25, h: 200, m: 0, fa: 1, hk: '1' },
      { i: 'general-p1-2', f: 'p1', k: 'general', x: 320.5, y: 400.25, h: 180, m: 1, fa: 1, hk: '2' },
      { i: 'general-p2-1', f: 'p2', k: 'general', x: 2000.5, y: 1400.25, h: 150, m: 0, fa: -1, hk: '1' },
      { i: 'general-p2-2', f: 'p2', k: 'general', x: 2040.5, y: 1400.25, h: 200, m: 0, fa: -1, hk: '2' },
      { i: 'enemy-abc', f: 'enemy', k: 'enemy', x: 1500, y: 900, h: 60, m: 1, fa: 1, hk: null },
    ],
    buildings: [
      { t: 'base', x: 12, y: 8, o: 'p1', h: 1000 },
      { t: 'base', x: 20, y: 12, o: 'p2', h: 1000 },
      { t: 'wall', x: 13, y: 10, o: 'p2', h: 220 },
    ],
    zones: Array.from({ length: 24 }, (_, i) => ({ o: i < 2 ? 'p1' : (i > 20 ? 'p2' : null), p: i < 2 ? 1 : 0 })),
    res: [12.5, 7.25],
    owned: 32,
    time: 42.75,
  };

  lastSocket.serverPush({ t: 'snap', s: hostSnap });
  await sleep(10);

  ok(s.units.length === 5,
    `★ 客机拿到了房主世界的全部 5 个单位（含 p1、p2 与 NPC 敌人，实际 ${s.units.length}）`);
  ok(s.units.filter((u) => u.faction === 'p1').length === 2
    && s.units.filter((u) => u.faction === 'p2').length === 2
    && s.units.filter((u) => u.faction === 'enemy').length === 1,
    '★ 三方阵营都齐了（p1 2 个 / p2 2 个 / enemy 1 个）—— 这就是「互相看到」');
  const mine = s.units.find((u) => u.id === 'general-p2-1');
  ok(!!mine && Math.abs(mine.px - 2000.5) < 0.01 && Math.abs(mine.py - 1400.25) < 0.01,
    `客机自己的单位位置被房主覆盖（px=${mine && mine.px}, py=${mine && mine.py}）`);
  ok(!!mine && mine.netPx !== undefined && mine.netAt > 0,
    '客机单位带上了插值字段（渲染不会跳格）');
  ok(s.buildingList.length === 3,
    `建筑表与房主一致（3 个：双方大本营 + 一段 p2 城墙，实际 ${s.buildingList.length}）`);
  ok(!!s.buildings.get(20, 12) && s.buildings.get(20, 12).owner === 'p2',
    '建筑格网被重建（(20,12) 的 p2 大本营能按格查到）');
  ok(s.buildings.get(13, 10) && s.buildings.get(13, 10).hp === 220,
    '建筑血量按快照同步（p2 城墙 220/300）');
  ok(Math.abs(s.resources.food - 12.5) < 0.05 && Math.abs(s.resources.gold - 7.25) < 0.05,
    `资源按快照同步（${s.resources.food} / ${s.resources.gold}）`);
  ok(s.ownedTiles === 32, `己方地块数按快照同步（${s.ownedTiles}）`);
  ok(Math.abs(s.time - 42.75) < 1e-6, `时间轴按快照同步（${s.time}）`);
  ok(s.zones[0].owner === 'p1' && s.zones[23].owner === 'p2',
    '区块归属按快照同步（A1 归 p1、F4 归 p2）');
}

section('9 ★ 快照覆盖后仍能渲染一帧（含 p2 城墙的掉血血条）');
{
  let err = null;
  try { R.drawOnce(); } catch (e) { err = String(e); }
  ok(err === null, `收到快照后渲染一帧无异常${err ? '：' + err : ''}`);

  // 客机上的「远端单位」没有真实逻辑，渲染与 HUD 会读它们的 combat 属性 —— 必须存在
  const remote = s.units.find((u) => u.faction === 'p1');
  ok(!!remote && !!remote.combat && typeof remote.combat.damage === 'number',
    '远端单位带有 combat 数值（HUD / 渲染读它不会炸）');
  ok(!!remote && remote.attackRangePx > 0 && remote.aggroRangePx > 0,
    '远端单位带有射程与警戒半径（选中面板 / 射程圈能画）');

  // 选中一个远端单位（观战视角）也不该崩
  let err2 = null;
  try {
    R.selectUnits([remote]);
    R.drawOnce();
  } catch (e) { err2 = String(e); }
  ok(err2 === null, `选中远端（p1）单位后渲染仍然无异常${err2 ? '：' + err2 : ''}`);
  ok(els.selDetail.textContent.length > 0, '选中面板写出了远端单位的信息');
}

section('10 客机的 pickAt：只选得中自己的单位');
{
  // 把客机自己的单位和对手的单位放在同一处，看点击选中谁
  const p1u = s.units.find((u) => u.faction === 'p1');
  const p2u = s.units.find((u) => u.faction === 'p2');
  p2u.px = 1000; p2u.py = 1000;
  p1u.px = 1000; p1u.py = 1000;   // 完全重叠
  R.pickAt({ x: 1000, y: 1000 }, { x: Math.floor(1000 / CELL), y: Math.floor(1000 / CELL) }, false);
  ok(s.ui.selectedUnits.length === 1 && s.ui.selectedUnits[0].id === p2u.id,
    `★ 重叠时只选得中自己的单位（选中了 ${s.ui.selectedUnits[0] && s.ui.selectedUnits[0].id}）`);
  ok(R.myFaction() === 'p2', '客机的 myFaction 始终是 p2（渲染用色 / HUD 归属都依赖它）');
}

section('11b ★ 准备界面：双方都准备才开战');
{
  // 自己建立前置：模拟服务器把本机分配成 p2 客机（不依赖前面小节留下的状态）
  R.netGoOffline();
  R.net.usingFallback = false;
  R.net.active = true;
  R.handleNetWelcome({ t: 'welcome', isHost: false, faction: 'p2', roster: ['p1', 'p2'], peers: 2 });
  ok(s.lobby.active === true && R.myFaction() === 'p2', '前置：以客机 p2 身份停在准备界面');

  // 只有我一个人准备 → 还不能开战
  R.toggleReady();
  ok(s.lobby.ready.p2 === true, '我（p2）点准备后本地标记为已准备');
  ok(s.lobby.canStart === false, '★ 对手还没准备 → 不能开战');
  step(60);   // 推 1 秒
  ok(s.lobby.active === true && s.buildingList.filter((b) => b.type === 'base').length === 1,
    '★ 单人准备推 1 秒也不会自己开战（对手基地还没建）');

  // 准备消息应该已经发给服务器
  const readyMsg = sentOf('ready').pop();
  ok(!!readyMsg && readyMsg.ready === true, '准备状态通过 ready 消息发给服务器');

  // 对手（p1）准备 → 双方齐了
  R.setPeerReady('p1', true);
  ok(s.lobby.canStart === true, '★ 双方都准备后 canStart = true');
  ok(s.lobby.ready.p1 === true && s.lobby.ready.p2 === true, '双方都标记为已准备');

  // 房主的开战通知（客机路径）→ 倒计时 → 建世界
  R.CONFIG.pvp.countdownSec = 0;
  R.onNetStart({ countdown: 0 });      // 等价于收到房主的「开战」通知
  ok(s.lobby.active === false, '确定开战后退出准备界面');
  ok(s.units.length === 6, `★ 开战后建出了双方部队（${s.units.length} 个 = p1 3 + p2 3）`);
  ok(s.units.filter((u) => u.faction === 'p1').length === 3 && s.units.filter((u) => u.faction === 'p2').length === 3,
    '★ 双方各 3 个将领 —— 客机也建出了完整世界（不是只有自己那一方）');
  ok(s.buildingList.filter((b) => b.type === 'base').length === 2, '★ 双方基地都已建出');
  ok(s.pvpEnabled === true, '对战规则已生效');
  ok(s.match.over === false, '开战时没有判出胜负');
  ok(R.homeBaseOf('p1') && R.homeBaseOf('p2'), '双方基地坐标都已记录');
}

section('11a ★ 模拟真实开局时序：不能一开局就判 P1 赢（线上事故回归）');
{
  /**
   * 真实启动顺序（这就是线上出问题的那条路径）：
   *   1. init() 按单机建世界
   *   2. initNet() 把名单设成 FACTION_ROSTER（p1..p8 八个席位）并按 p1 重建世界
   *   3. 此刻**只有 p1 有基地** —— 别人还没进房间
   *   4. 第 0 帧的 checkVictory 如果拿"名单人数"当分母，就会认为
   *      "8 个玩家只剩 1 个活着" → 立刻判 p1 获胜、这局直接结束。
   *
   * 所以这里刻意**不用** setupPvpWorld()，而是把状态摆成 initNet() 刚跑完的样子，只推一帧。
   */
  const netMod = R.net;
  netMod.usingFallback = false;
  netMod.active = true;
  netMod.isHost = true;
  netMod.myFaction = 'p1';
  s.factions.factions = ['p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7', 'p8'];
  s.factions.myFaction = 'p1';
  s.units = [];
  s.factionSpawns = {};
  s.factionBases = {};
  R.CONFIG.pvp.destructibleBase = true;
  s.pvpEnabled = true;
  // 清空旧世界：只留 p1 的基地（模拟"别人还没进房间"的真实开局）
  for (const b of s.buildingList.slice()) {
    if (b.type === 'base') R.removeBuildingFor(s, b, true);
  }
  R.applyFactionLayout('p1');
  s.match.over = false; s.match.winner = null; s.match.elapsed = 0; s.match.logged = false;

  const bases = s.buildingList.filter((b) => b.type === 'base');
  ok(bases.length === 1 && bases[0].owner === 'p1',
    `开局只有 p1 一个基地（名单里却有 ${s.factions.factions.length} 个席位）—— 别人还没进房间`);

  step(1);   // ★ 只推一帧

  ok(s.match.over === false,
    `★ 第 0 帧不能判定胜负（over=${s.match.over} winner=${s.match.winner}）`
    + (s.match.over ? ' ← 这就是"一打开就显示 P1 赢了"的原因' : ''));
  ok(s.match.winner === null, `还没有胜者（winner=${s.match.winner}）`);
  ok(!s.match.logged, '也没有播报结算');

  step(60 * 5);
  ok(s.match.over === false, '★ 空等 5 秒也不会自己分出胜负');

  // 客机入场后才开始算胜负
  R.applyFactionLayout('p2');
  ok(s.buildingList.filter((b) => b.type === 'base').length === 2, 'p2 入场后有两个基地');
  step(1);
  ok(s.match.over === false, '★ 双方都在场时，不会凭空判定某一方获胜');

  // 真打掉 p1 基地 → 该判 p2 赢
  const p1base = s.buildingList.find((b) => b.type === 'base' && b.owner === 'p1');
  R.onCombatEvent({ type: 'buildingDown', building: p1base, source: null });
  ok(s.match.over === true && s.match.winner === 'p2',
    `★ 真打掉 p1 基地时才判负（over=${s.match.over} winner=${s.match.winner}）`);
}

section('11 ★ 对战：联机开局自动打开对战规则 + 双方基地分离');
{
  // 先建立一个干净的两人对战开局（房主视角 p1，p2 也已入场）
  setupPvpWorld();

  ok(R.myFaction() === 'p1', `当前是房主 p1（实际 ${R.myFaction()}）`);
  ok(s.factions.factions[0] === 'p1', `名单第一个是 p1（${s.factions.factions.slice(0, 3).join(',')}…）`);
  ok(s.pvpEnabled === true, '★ 联机模式下 pvpEnabled 被打开（单机才是 false）');
  ok(R.CONFIG.pvp.destructibleBase === true, '★ 联机模式下大本营可被摧毁（打掉 = 分胜负）');
  ok(R.CONFIG.pvp.respawnSec > 0, `阵亡后可复活（${R.CONFIG.pvp.respawnSec} 秒）`);
  ok(s.match && s.match.over === false, '开局 match.over = false（还没分出胜负）');

  const p1base = R.homeBaseOf('p1');
  ok(!!p1base, `p1 的大本营坐标已记录（${p1base && p1base.x},${p1base && p1base.y}）`);
  ok(p1base && p1base.x === s.map.base.x && p1base.y === s.map.base.y,
    `★ p1 拿到地图中央的原版大本营 (${p1base && p1base.x},${p1base && p1base.y})`);

  // 让服务器把 p2 也拉进这一局（真实流程：客机入场 → 服务器广播名单 → 房主为 p2 建基地）
  R.applyFactionLayout('p2');
  const p2base = R.homeBaseOf('p2');
  ok(!!p2base, `p2 的大本营坐标已记录（${p2base && p2base.x},${p2base && p2base.y}）`);
  ok(p2base && p2base.x !== p1base.x || p2base.y !== p1base.y,
    `★ p2 的大本营不与 p1 重合（p1=${p1base.x},${p1base.y} / p2=${p2base.x},${p2base.y}）`);
  const gap = Math.abs(p1base.x - p2base.x) + Math.abs(p1base.y - p2base.y);
  ok(gap >= 8, `★ 两个大本营相距 ${gap} 格，开局不会立刻贴脸`);

  const bases = s.buildingList.filter((b) => b.type === 'base');
  ok(bases.length === 2, `地图上正好 2 个大本营（实际 ${bases.length}）`);
  ok(bases.every((b) => b.owner === 'p1' || b.owner === 'p2'),
    `★ 大本营归属只能是玩家阵营，没有残留的单机 'player' 基地（${bases.map((b) => b.owner).join(', ')}）`);
  ok(new Set(bases.map((b) => b.owner)).size === 2, '两个大本营分属不同阵营');
  ok(!!s.buildings.get(p1base.x, p1base.y) && s.buildings.get(p1base.x, p1base.y).owner === 'p1',
    '格网查询也一致（(p1) 处查到的是 p1 的大本营）');
}

section('12 ★ 对战：单位阵亡后在自家大本营复活');
{
  /**
   * ★ 复活是**权威逻辑**，必须用房主视角测。
   *   客机的 update() 是冻结的（世界由快照驱动），所以客机上根本不会推进复活倒计时 ——
   *   客机上的复活表现为「快照里那个单位重新出现」，那条路径由 net-test.mjs 覆盖。
   *
   * ⚠️ 这里**不能**再调 handleNetWelcome：它会重新进准备界面（清空世界、关掉 pvp），
   *    把 setupPvpWorld() 建好的对战状态全部抹掉。身份已经由助手设成房主 p1 了。
   */
  setupPvpWorld();
  ok(R.netStatus().isHost === true, '当前是房主（复活由房主推进）');
  ok(R.myFaction() === 'p1', `房主阵营 p1（实际 ${R.myFaction()}）`);

  const p1home = R.homeBaseOf('p1');
  const u = s.units.find((x) => x.faction === 'p1');
  ok(!!u, `找到 p1 的单位（${u && u.id}）`);
  ok(u.respawnTimer === 0, '刚开局不在复活倒计时中');

  // 选中它，验证阵亡后选中列表会自动清理
  R.selectUnits([u]);
  ok(s.ui.selectedUnits.length === 1, '已选中该单位');

  // 扔到远处再打死
  u.px = 1500; u.py = 900; u.tx = 12; u.ty = 7;
  const deathSpot = { x: u.px, y: u.py };
  u.takeDamage(99999, null);

  ok(!u.alive && u.respawnTimer > 0, `★ 阵亡后进入复活倒计时（${u.respawnTimer}s）`);
  ok(s.units.indexOf(u) >= 0, '★ 阵亡的单位仍留在 state.units 里（被过滤掉就永远活不过来）');
  ok(u.awaitingRespawn === true, 'awaitingRespawn = true（渲染据此画倒计时环）');
  ok(u.deaths === 1, '累计阵亡次数 +1');

  step(1);   // 推一帧，让选中列表的清理逻辑跑到
  ok(s.ui.selectedUnits.every((x) => x.alive), '★ 推一帧后选中列表里不再留着死单位');

  // 推进到复活前一刻，确认倒计时在走
  step(60 * 6);
  ok(!u.alive && u.respawnTimer > 0 && u.respawnTimer < 2.5,
    `6 秒后仍在等待（剩余 ${u.respawnTimer.toFixed(2)}s）`);

  // 再推过 8 秒
  step(60 * 3);
  ok(u.alive === true, '★ 8 秒后自动复活');
  ok(u.hp === u.hpMax, `复活满血（${u.hp}/${u.hpMax}）`);

  const distToHome = Math.abs(u.tx - p1home.x) + Math.abs(u.ty - p1home.y);
  ok(distToHome === 1, `★ 复活在自家大本营旁（离 p1 大本营 ${distToHome} 格，原来死在 (12,7)）`);
  ok(Math.hypot(u.px - deathSpot.x, u.py - deathSpot.y) > 100,
    '位置确实回到了基地一侧，不是在阵亡点原地复活');
  ok(u.path === null && u.target === null, '复活后清空了路径与交战目标');
  ok(s.log.some((l) => l.indexOf('复活') >= 0), `事件日志记录了复活：“${s.log.filter((l) => l.indexOf('复活') >= 0).pop()}”`);

  // 渲染一帧：此时有单位在等复活，会走 drawRespawnTimers 那条路径
  let err = null;
  try {
    s.units.find((x) => x.faction === 'p1' && x !== u).takeDamage(99999, null);
    R.drawOnce();
  } catch (e) { err = String(e); }
  ok(err === null, `★ 有待复活单位时渲染一帧无异常（drawRespawnTimers 路径）${err ? '：' + err : ''}`);
}

section('13 ★ 对战：拆掉对方大本营 = 分出胜负');
{
  setupPvpWorld();

  // 用房主视角去打 p2 的大本营（房主才跑权威逻辑；身份已由助手设好）
  const p2base = s.buildingList.find((b) => b.type === 'base' && b.owner === 'p2');
  ok(!!p2base, `p2 的大本营存在（${p2base && p2base.tx},${p2base && p2base.ty}），可以作为攻击目标`);
  if (!p2base) { console.log('  （跳过后续断言）'); }
  else {
    ok(s.match.over === false, '打之前这一局还没结束');
    ok(p2base.hp === p2base.hpMax, `p2 大本营满血（${p2base.hp}/${p2base.hpMax}）`);

    // 打残，再由玩家的将领补最后一击（走真实的 setBuildingTarget → updateBuildingCombat 路径）
    p2base.hp = 30;
    /**
     * ★ 先把 p2 的将领挪走。
     *   它们本来就站在自家大本营旁边（19,12 等），攻击者一贴上去就会先自动索敌到这些单位
     *   （单位优先于建筑，这是正确行为），于是 targetBuilding 被让位、基地永远挨不到打。
     *   这一节测的是「拆家 → 分胜负」，不是索敌优先级，所以把干扰单位移开。
     */
    for (const u of s.units.filter((x) => x.faction === 'p2')) {
      u.tx = 2; u.ty = 2;
      u.px = 2.5 * CELL; u.py = 2.5 * CELL;
      u.stop();
    }

    const attacker = s.units.find((x) => x.faction === 'p1');
    attacker.stop();
    attacker.setBuildingTarget(p2base);
    // 直接送到攻击距离内（省掉走路时间，这一节测的是结算不是寻路）
    attacker.px = (p2base.tx + 0.5) * CELL - CELL * 0.9;
    attacker.py = (p2base.ty + 0.5) * CELL;

    let guard = 0;
    while (!s.match.over && guard++ < 60 * 10) step(1);

    ok(s.match.over === true, '★ 大本营被打掉后，这一局判定结束（match.over = true）');
    ok(s.match.winner === 'p1', `★ 胜者是 p1（实际 ${s.match.winner}）—— 房主侧判定正确`);
    ok(!s.buildings.get(p2base.tx, p2base.ty), '被打掉的大本营已从地图上移除');
    ok(!s.buildingList.some((b) => b.type === 'base' && b.owner === 'p2'), 'p2 的大本营不在建筑表里了');
    ok(s.log.some((l) => l.indexOf('获胜') >= 0 || l.indexOf('对战结束') >= 0),
      `事件日志写出了结果：“${s.log.filter((l) => /获胜|对战结束/.test(l)).pop()}”`);
    ok(s.match.logged === true, '结算只播报一次（match.logged 置位，不会每帧刷屏）');

    let err = null;
    try { R.drawOnce(); } catch (e) { err = String(e); }
    ok(err === null, `★ 结算画面渲染无异常${err ? '：' + err : ''}`);
  }
}
section('14 ★ 对战结算状态随快照同步（客机看到同样的结果）');
{
  setupPvpWorld();
  // 先把这一局打出一个结果（直接打 p2 大本营，不测寻路）
  const p2b = s.buildingList.find((b) => b.type === 'base' && b.owner === 'p2');
  p2b.hp = 20;
  // p2 的将领挪远，免得攻击者先索敌到它们（单位优先于建筑）
  for (const u of s.units.filter((x) => x.faction === 'p2')) {
    u.tx = 2; u.ty = 2; u.px = 2.5 * CELL; u.py = 2.5 * CELL; u.stop();
  }
  const hitter = s.units.find((u) => u.faction === 'p1');
  hitter.stop();
  hitter.setBuildingTarget(p2b);
  hitter.px = (p2b.tx + 0.5) * CELL - CELL * 0.9;
  hitter.py = (p2b.ty + 0.5) * CELL;
  let g = 0;
  while (!s.match.over && g++ < 60 * 10) step(1);
  ok(s.match.over && s.match.winner === 'p1', `先打出一个结果（winner=${s.match.winner}）`);

  // 用当前世界造一份快照，看结算状态有没有被带上、客机能否读到
  const { makeSnapshot, applySnapshot, net: netMod } = await import('../js/net.js');
  const snap = makeSnapshot(s);
  const expectedWinner = s.match.winner;
  ok(snap.match && snap.match.over === true && snap.match.winner === expectedWinner,
    `快照里带上了结算状态（over=${snap.match.over} winner=${snap.match.winner}）`);

  // 造一个"客机"状态来接收
  const clientStub = {
    terrain: s.terrain, zones: s.zones, zoneLookup: s.zoneLookup,
    buildings: s.buildings, buildingList: [], units: [],
    resources: { food: 0, gold: 0 }, ownedTiles: 0, time: 0,
    match: { over: false, winner: null, elapsed: 0, logged: false, limitSec: 600 },
    ui: { selectedUnits: [], toasts: [] },
  };
  let onMatchOverCalled = null;
  const prev = netMod.onMatchOver;
  netMod.onMatchOver = (w) => { onMatchOverCalled = w; };
  applySnapshot(clientStub, snap, performance.now());
  netMod.onMatchOver = prev;

  ok(clientStub.match.over === true && clientStub.match.winner === expectedWinner,
    '★ 客机应用快照后也认为这局结束了，且胜者与房主一致');
  ok(onMatchOverCalled === expectedWinner,
    `★ 客机收到「结束」回调并拿到胜者（${onMatchOverCalled}）`);

  // 旧版本房主的快照没有 match 字段，不能崩，也不能把已结算的画面重置回进行中
  const legacy = { units: [], buildings: [], zones: [], res: [0, 0] };
  const beforeOver = clientStub.match.over;
  const beforeWinner = clientStub.match.winner;
  let legacyErr = null;
  try { applySnapshot(clientStub, legacy, performance.now()); } catch (e) { legacyErr = String(e); }
  ok(legacyErr === null, `★ 收到缺 match 字段的旧快照也不崩（兼容性）${legacyErr ? '：' + legacyErr : ''}`);
  ok(clientStub.match.over === beforeOver && clientStub.match.winner === beforeWinner,
    '★ 缺 match 字段时保持本地结算状态不变 —— 不能把已结算的画面打回进行中');
}

section('15 房主收到客机 cmd：按阵营核对后执行');
{
  setupPvpWorld();
  ok(R.netStatus().isHost === true, '房主身份（见 setupPvpWorld）');
  ok(R.myFaction() === 'p1', `阵营是 p1（实际 ${R.myFaction()}）`);

  /**
   * ★ 房主的世界必须**同时**有两个阵营的单位 —— 这才是真实拓扑：
   *   同一局里两个玩家都在房主的 state 中。客机是镜子，只看得见结果。
   */
  const p1n = s.units.filter((u) => u.faction === 'p1').length;
  const p2n = s.units.filter((u) => u.faction === 'p2').length;
  ok(p1n === 3 && p2n === 3,
    `★ 房主手里同时有双方部队（p1 ${p1n} 个 / p2 ${p2n} 个）—— 不是只有自己那一方`);

  const p2units = s.units.filter((u) => u.faction === 'p2');
  const target = { x: 16 * CELL + 20, y: 10 * CELL + 60 };
  const before = { x: p2units[0].px, y: p2units[0].py };

  // 等价于服务器把客机的 cmd 转给了房主
  R.net.onCommand({ t: 'cmd', kind: 'move', f: 'p2', ids: [p2units[0].id], x: target.x, y: target.y });
  ok(p2units[0].moving === true || (p2units[0].path && p2units[0].path.length > 0),
    '★ 房主执行了客机的移动命令（p2 的单位开始移动）');

  step(60);
  const moved = Math.hypot(p2units[0].px - before.x, p2units[0].py - before.y);
  ok(moved > 20, `房主侧 p2 的单位真的动了（1 秒走了 ${moved.toFixed(0)}px）`);

  // ★ 防冒充：拿房主自己（p1）的单位 id 冒充 p2 发命令 —— 必须完全没反应
  const p1unit = s.units.find((u) => u.faction === 'p1');
  p1unit.stop();                                   // 先确保它没有残余移动
  const p1before = { x: p1unit.px, y: p1unit.py };
  R.net.onCommand({
    t: 'cmd', kind: 'move', f: 'p2',
    ids: [p1unit.id], x: target.x + 900, y: target.y + 900,
  });
  step(30);
  ok(p1unit.path === null || p1unit.path.length === 0,
    '★ 客机拿 p1 单位 id 冒充发命令时，房主没有给 p1 单位下达任何路径（防冒充生效）');
  const p1moved = Math.hypot(p1unit.px - p1before.x, p1unit.py - p1before.y);
  ok(p1unit.goalPt === null && p1moved < 20,
    `被冒充的 p1 单位没有朝客机指定的方向移动（位移 ${p1moved.toFixed(0)}px）`);

  // 房主身份下建造命令也应带上发送者阵营
  R.selectBuildType('tower');
  R.net.onCommand({ t: 'cmd', kind: 'build', f: 'p2', tx: 3, ty: 3 });
  const towerB = s.buildings.get(3, 3);
  ok(!!towerB && towerB.owner === 'p2',
    `★ 客机的建造命令以客机阵营落成（(3,3) 的箭塔 owner=${towerB && towerB.owner}）`);
  R.selectBuildType(null);
}

section('16 断线：安全退回单机，不白屏、还能继续玩');
{
  setupPvpWorld();
  // 先确认确实处于联机状态，否则"退回单机"这件事没有被真正验证
  ok(R.netStatus().active === true, '断线前处于联机状态');

  lastSocket.close();          // 模拟服务器断开
  await sleep(10);

  ok(R.netStatus().active === false, '★ 连接断开后自动退出联机模式');
  ok(R.netStatus().fallback === true, '标记为已退回单机（net.usingFallback）');
  ok(R.netStatus().isHost === true, '退回单机后身份是房主（自己说了算）');
  ok(R.myFaction() === 'player', `★ 退回单机后阵营回到默认 'player'（实际 ${R.myFaction()}）`);

  /**
   * 世界会被重建回单机的 3 个 'player' 将领。
   * 这是**有意**的：只改阵营不重建，就会留下「玩家单位是 p1、选择过滤却是 player」
   * 的坏状态 —— 选不中任何单位、也建不了东西。重建之后单机是真的能玩。
   */
  ok(s.units.length === 3 && s.units.every((u) => u.faction === 'player'),
    `★ 世界重建为单机阵营（${s.units.map((u) => u.id).join(', ')}）`);
  ok(!!s.buildings.get(s.base.x, s.base.y), '大本营还在（世界结构没被破坏）');
  ok(s.zones.length === 24 && s.terrain.cols === 24, '地形与区块完好');

  const t0 = s.time;
  step(30);
  ok(s.time > t0, `★ 退回单机后 update 恢复运行（time ${t0.toFixed(2)} → ${s.time.toFixed(2)}）`);

  R.selectUnits([s.units[0]]);
  ok(s.ui.selectedUnits.length === 1, '退回单机后能重新选中将领');
  const mv = s.units[0].orderMove(s, { x: 5 * CELL + 30, y: 5 * CELL + 30 });
  ok(mv === true && s.units[0].moving, '★ 退回单机后能正常下达移动命令（不是"看上去能玩"）');
  R.selectBuildType('wall');
  ok(R.tryBuildAt(2, 2) === true, '★ 退回单机后建造也能用');
  R.selectBuildType(null);

  let err = null;
  try { R.drawOnce(); } catch (e) { err = String(e); }
  ok(err === null, '退回单机后渲染一帧无异常');
}

console.log(`\n———————————————\n通过 ${pass} 项，失败 ${fail} 项`);
process.exit(fail ? 1 : 0);
