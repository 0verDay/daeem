/**
 * net.js —— 多人联机的客户端（房主 / 客机共用这一份代码）
 *
 * 架构：**房主权威 + 服务器中继**（详见 net/README.md）
 *
 *   房主（第一个进房间的人）
 *     · 照常跑完整的游戏逻辑（main.js 的 update 一行不改）
 *     · 每 SNAPSHOT_HZ 把权威状态打包成 snap 发出去
 *     · 收到客机的 cmd 就代为执行（它手里有唯一的权威 state）
 *
 *   客机（之后进房间的人）
 *     · update() 被冻结 —— 不跑游戏逻辑，避免两份状态漂移
 *     · 只发 cmd（移动 / 建造的意图），只收 snap（世界真值）
 *     · 本地仍然跑相机、选中、HUD、绘制，所以操作手感是即时的
 *
 * 为什么不让每个客户端各跑一局再互相同步：
 *   那就是「两个人各玩各的」，状态永远不会收敛。权威必须只有一份。
 *
 * 为什么服务器不跑逻辑：
 *   服务器不 import 任何游戏模块，只转发字节。这样就不需要把 main.js 拆成
 *   DOM 层与逻辑层（Node 里没有 document），也就不需要重写那 800 行规则。
 *   服务器是「哑的」→ 不可能出现服务端与客户端规则不一致这类最难查的 bug。
 *
 * 消息类型（全部是 JSON，第一阶段不做二进制优化）
 *   → hello     客户端 → 服务器：进房间
 *   → cmd       客户端 → 服务器：意图（由服务器转给房主）
 *   → snap      房主   → 服务器：权威快照（由服务器广播给其他人）
 *   ← welcome   服务器 → 客户端：分配 id / faction / 是不是房主
 *   ← peer      服务器 → 客户端：有人进/出房间
 *   ← cmd / snap 服务器 → 客户端：转发
 */

import { CONFIG } from './config.js';
import { DEFAULT_FACTION, FACTION_ROSTER } from './faction.js';

/** 快照广播频率（Hz）。20Hz ≈ 单人下行 35KB/s，小水管服务器带 6 人无压力。 */
export const SNAPSHOT_HZ = 20;

/** 客机渲染插值的缓冲时长（秒）。比 1/20Hz 略大，避免抖动。 */
export const INTERP_DELAY = 0.1;

const POS_DECIMALS = 2;   // 坐标小数位：2 位 ≈ 0.01px，肉眼无差别但体积减半

const num = (v, d = POS_DECIMALS) => Number(Number(v).toFixed(d));

/** 整数夹取（避免为此引入 util.js 的依赖） */
const clampInt = (v, lo, hi) => (v < lo ? lo : v > hi ? hi : v);

/**
 * 联机状态。main.js 会读它来决定「跑不跑逻辑 / 命令发不发给网络」。
 */
export const net = {
  active: false,        // 是否处于联机模式（#net=1 或 /?net=1）
  isHost: false,        // 我是不是房主（权威方）
  connected: false,     // WS 是否已连上
  myFaction: DEFAULT_FACTION,
  myId: null,
  room: 'default',
  peers: 0,
  lastError: null,
  snapCount: 0,
  lastSnapAt: 0,        // performance.now() 时刻，用于插值
  usingFallback: false, // 连不上服务器时是否已退回单机

  /* ---- 由 main.js 挂上的回调（net.js 不 import main.js，避免循环依赖） ---- */
  onCommand: null,      // (cmd) => void       房主收到客机意图
  onSnapshot: null,     // (snap) => void      客机收到权威快照
  onStatus: null,       // (text) => void      写进事件日志
  onFallback: null,     // () => void          退回单机时让 main.js 把世界切回默认阵营
  onMatchOver: null,    // (winner) => void    客机收到「这局结束了」
  onReady: null,        // (msg) => void       收到某人的准备状态（准备界面）
  onStart: null,        // (msg) => void       收到房主的「开战」通知

  /** 当前「我」控制的阵营 */
  get faction() {
    return this.active ? this.myFaction : DEFAULT_FACTION;
  },
};

function logStatus(text) {
  if (typeof net.onStatus === 'function') net.onStatus(text);
  else console.log('[net]', text);
}

/**
 * 判定本页是否要以联机模式启动（URL 里带 #net=1 / ?net=1 / #room=xxx）
 *
 * ⚠️ 必须容忍「没有 location」的环境：tools/integration-test.mjs 在 Node 里用 DOM 桩
 *    加载真实的 main.js，而 Node 里没有 location / window.location。旧写法会在模块
 *    初始化阶段直接抛 ReferenceError，连单机模式都跑不起来。
 */
export function readNetIntent() {
  const loc = (typeof location !== 'undefined' && location) ? location : null;
  if (!loc) return { on: false, room: 'default' };
  const hash = (loc.hash || '').replace(/^#/, '');
  const q = loc.search || '';
  const hp = new URLSearchParams(hash);
  const qp = new URLSearchParams(q);
  const on = hp.get('net') === '1' || qp.get('net') === '1'
    || /(^|&)net=1(&|$)/.test(hash) || /(^|&)net=1(&|$)/.test(q);
  const room = hp.get('room') || qp.get('room') || 'default';
  return { on, room };
}

/**
 * 建面板快照（房主调用）。
 * ★ 刻意**不**同步 state.terrain / camera / view / log —— 那些是本地的东西。
 */
export function makeSnapshot(state) {
  const units = [];
  for (const u of state.units) {
    if (!u.alive) continue;         // 阵亡的单位不发 —— 客机上看它就"消失了"，复活后再出现
    units.push({
      i: u.id, f: u.faction, k: u.kind,
      x: num(u.px), y: num(u.py),
      h: Math.round(u.hp),
      m: u.moving ? 1 : 0,
      fa: u.facing > 0 ? 1 : -1,
      hk: u.hotkey || null,
    });
  }
  const buildings = [];
  for (const b of state.buildingList) {
    if (!b.alive) continue;
    buildings.push({ t: b.type, x: b.tx, y: b.ty, o: b.owner, h: Math.round(b.hp) });
  }
  const zones = [];
  for (const z of state.zones) {
    zones.push({ o: z.owner, p: num(z.progress, 2) });
  }
  return {
    units,
    buildings,
    zones,
    res: [num(state.resources.food, 1), num(state.resources.gold, 1)],
    owned: state.ownedTiles,
    time: num(state.time, 2),
    /**
     * ★ 对战结算状态。由房主判定，客机只负责显示 ——
     *   所以胜者是谁不存在"两边算出不同结果"的问题。
     *   用可选链容错：调用方（测试桩 / 旧版本）可能没有 state.match。
     */
    match: {
      over: !!(state.match && state.match.over),
      winner: (state.match && state.match.winner) || null,
      elapsed: num((state.match && state.match.elapsed) || 0, 1),
    },
  };
}

/**
 * 应用权威快照（客机调用）。
 * 按 id 对齐单位：有的就地更新，没有的新建（别人刚刷出来的），快照里没有的删掉。
 */
export function applySnapshot(state, snap, nowMs) {
  if (!snap) return;
  const seen = new Set();

  for (const su of snap.units || []) {
    seen.add(su.i);
    let u = state.units.find((x) => x.id === su.i);
    if (!u) {
      // 客机本地新建：kind 决定体积与战斗数值，faction 决定颜色
      u = makeRemoteUnit(state, su);
      if (!u) continue;
      state.units.push(u);
    }
    u.alive = true;
    u.faction = su.f;
    u.hp = su.h;
    u.moving = !!su.m;
    u.facing = su.fa || 1;
    if (su.hk) u.hotkey = su.hk;
    /**
     * ★ 权威位置：必须同时写回 px/py 与 tx/ty。
     *   只写 netPx/netPy 是不够的 —— 渲染靠插值看起来正常，但 state 里
     *   px/py/tx/ty 会一直是旧值，于是点选判定、射程判定、HUD 全都是错的。
     */
    u.px = su.x;
    u.py = su.y;
    u.tx = clampInt(Math.floor(su.x / CONFIG.cell), 0, state.terrain.cols - 1);
    u.ty = clampInt(Math.floor(su.y / CONFIG.cell), 0, state.terrain.rows - 1);

    // 记下「网络目标位置」与时刻，渲染时做插值（见 render.js 的 unitDrawPos）：
    // 上一帧的目标位置挪到 netPx0/netPy0，这样渲染可以在这两点之间平滑过渡
    if (u.netPx === undefined) {
      u.netPx0 = su.x; u.netPy0 = su.y; u.netAt0 = nowMs;
    } else {
      u.netPx0 = u.netPx; u.netPy0 = u.netPy; u.netAt0 = u.netAt;
    }
    u.netPx = su.x;
    u.netPy = su.y;
    u.netAt = nowMs;
  }

  // 快照里没有的单位 = 已经阵亡（客机上的世界完全以快照为准）
  state.units = state.units.filter((u) => seen.has(u.id));

  // 建筑：整表替换（数量少、结构简单，比按 id 对齐更不容易出错）
  syncBuildings(state, snap.buildings || []);

  // 区块归属
  for (let i = 0; i < state.zones.length && i < (snap.zones || []).length; i++) {
    const z = state.zones[i];
    const sz = snap.zones[i];
    z.owner = sz.o;
    z.progress = sz.p;
  }
  if (snap.res) {
    state.resources.food = snap.res[0];
    state.resources.gold = snap.res[1];
  }
  if (typeof snap.owned === 'number') state.ownedTiles = snap.owned;
  if (typeof snap.time === 'number') state.time = snap.time;

  /**
   * 对战结算状态：房主说了算，客机只显示。
   * ★ 快照里**没有** match 字段时，保持本地原样 —— 不能当成"未结束"把它重置掉。
   *   否则一条不含该字段的包（旧版本房主、或将来某个精简包）会把已经结算的画面又打回进行中。
   */
  if (snap.match && state.match) {
    const wasOver = state.match.over;
    state.match.over = !!snap.match.over;
    state.match.winner = snap.match.winner || null;
    state.match.elapsed = snap.match.elapsed || 0;
    if (!wasOver && state.match.over && typeof net.onMatchOver === 'function') {
      net.onMatchOver(state.match.winner);
    }
  }

  net.snapCount++;
  net.lastSnapAt = nowMs;
  net.lastSnapTime = snap.time || 0;
}

/** 客机本地新建一个远端单位（从快照字段还原） */
function makeRemoteUnit(state, su) {
  const cell = CONFIG.cell;
  const slot = (su.f || '').replace(/^p/, '') || '?';
  const u = {
    id: su.i,
    name: su.f === 'enemy' ? '测试敌人' : `P${slot}·将领${su.hk || ''}`,
    kind: su.k, faction: su.f, hotkey: su.hk || null,
    tx: Math.floor(su.x / cell), ty: Math.floor(su.y / cell),
    px: su.x, py: su.y, hpMax: su.k === 'enemy' ? CONFIG.debug.enemyHp : CONFIG.unit.hpMax,
    hp: su.h, alive: true,
    path: null, goal: null, goalPt: null, moving: !!su.m, selected: false,
    facing: su.fa || 1, state,
    target: null, targetBuilding: null, anchor: null,
    attackCd: 0, attackFlash: 0, lastTarget: null, lastBuilding: null, repathTimer: 0,
    netPx: su.x, netPy: su.y, netAt: performance.now(),
    // 客机上的单位没有真实逻辑，但渲染与 HUD 会读 combat / speed，所以给个安全值
    get combat() { return this.kind === 'enemy' ? CONFIG.combat.enemy : CONFIG.combat.general; },
    get speed() { return CONFIG.unit.speed; },
    get attackRangePx() { return this.combat.range * cell; },
    get aggroRangePx() { return CONFIG.combat.aggroRange * cell; },
    get leashPx() { return this.aggroRangePx * CONFIG.combat.leashFactor; },
    update() {}, halt() {}, stop() {}, clearTarget() {}, acquireTarget() { return false; },
    takeDamage() { return true; },
  };
  return u;
}

/** 客机：让本地建筑表与快照一致（按 (type,tx,ty,owner) 对齐，保留现有对象以减少闪烁） */
function syncBuildings(state, list) {
  const key = (b) => `${b.type}:${b.tx}:${b.ty}:${b.owner}`;
  const existing = new Map();
  for (const b of state.buildingList) existing.set(key(b), b);

  const out = [];
  for (const sb of list) {
    const k = `${sb.t}:${sb.x}:${sb.y}:${sb.o}`;
    let b = existing.get(k);
    if (b) {
      existing.delete(k);
      b.hp = sb.h;
      b.alive = true;
      out.push(b);
    } else {
      const z = state.zones[state.zoneLookup[sb.y * CONFIG.mapCols + sb.x]];
      b = makeRemoteBuilding(state, sb, z ? z.id : -1);
      out.push(b);
    }
  }

  state.buildingList = out;
  state.buildings = state.buildings;   // 保持 grid 引用
  rebuildBuildingGrid(state);
}

function makeRemoteBuilding(state, sb, zoneId) {
  // 延迟 import 会带来循环依赖，这里直接用 building.js 的类（见 main.js 的注册）
  const Ctor = net._BuildingCtor;
  if (Ctor) {
    const b = new Ctor(sb.t, sb.x, sb.y, sb.o, zoneId);
    b.hp = sb.h;
    return b;
  }
  // 兜底：没有注册构造器时用一个最小对象（不会发生在正常流程里）
  return {
    type: sb.t, tx: sb.x, ty: sb.y, owner: sb.o, zoneId, hp: sb.h, hpMax: sb.h, alive: true,
    def: CONFIG.building[sb.t] || {}, flash: 0, lastTarget: null,
    get center() { return { x: (sb.x + 0.5) * CONFIG.cell, y: (sb.y + 0.5) * CONFIG.cell }; },
    get hpRatio() { return this.hpMax > 0 ? this.hp / this.hpMax : 0; },
    blocks() { return true; }, takeDamage() { return true; },
  };
}

function rebuildBuildingGrid(state) {
  state.buildings.data.fill(null);
  for (const b of state.buildingList) {
    if (b.alive) state.buildings.set(b.tx, b.ty, b);
  }
}

/* ------------------------------------------------------------------ */
/* WebSocket                                                          */
/* ------------------------------------------------------------------ */

let ws = null;
let reconnectTimer = null;

function wsUrl() {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${proto}//${location.host}/ws`;
}

/**
 * 连接服务器并进入房间。
 * @param {object} [opts]
 * @param {string} [opts.room]
 * @param {(evt:object)=>void} [opts.onWelcome]
 */
export function connect(opts = {}) {
  const intent = readNetIntent();
  const room = opts.room || intent.room || 'default';
  net.active = true;
  net.room = room;

  let url;
  try {
    url = wsUrl();
  } catch (e) {
    net.lastError = String(e);
    return;
  }

  try {
    ws = new WebSocket(url);
  } catch (e) {
    net.lastError = String(e);
    logStatus(`联机失败：${e}（已退回单机）`);
    fallbackToSinglePlayer();
    return;
  }

  ws.onopen = () => {
    net.connected = true;
    send({ t: 'hello', room });
    logStatus(`已连接服务器，正在加入房间 ${room} …`);
  };

  ws.onmessage = (ev) => {
    let msg;
    try { msg = JSON.parse(ev.data); } catch { return; }
    handleMessage(msg, opts);
  };

  ws.onclose = () => {
    net.connected = false;
    if (!net.active) return;
    logStatus('与服务器的连接断开（已退回单机模式）');
    fallbackToSinglePlayer();
  };

  ws.onerror = () => {
    net.lastError = 'websocket error';
  };
}

function handleMessage(msg, opts) {
  switch (msg.t) {
    case 'welcome': {
      net.myId = msg.id;
      net.isHost = !!msg.isHost;
      net.peers = msg.peers || 1;
      net.myFaction = msg.faction || (net.isHost ? FACTION_ROSTER[0] : FACTION_ROSTER[1]);
      logStatus(net.isHost
        ? `你是房主（阵营 ${net.myFaction}）—— 本局由你的浏览器跑权威逻辑`
        : `已加入房间（阵营 ${net.myFaction}，房主是别人）—— 等待世界同步…`);
      if (typeof opts.onWelcome === 'function') opts.onWelcome(msg);
      break;
    }
    case 'peer':
      net.peers = msg.peers || net.peers;
      logStatus(msg.event === 'join' ? '有玩家加入房间' : '有玩家离开房间');
      break;
    case 'cmd':
      // 房主收到客机意图
      if (typeof net.onCommand === 'function') net.onCommand(msg);
      break;
    case 'ready':
      // 准备界面：谁的准备状态变了
      if (typeof net.onReady === 'function') net.onReady(msg);
      break;
    case 'start':
      // 房主宣布开战
      if (typeof net.onStart === 'function') net.onStart(msg);
      break;
    case 'snap':
      net.peers = msg.peers || net.peers;
      if (typeof net.onSnapshot === 'function') net.onSnapshot(msg);
      break;
    case 'error':
      net.lastError = msg.msg || 'server error';
      logStatus(`服务器：${msg.msg}`);
      break;
    default:
      break;
  }
}

/** 发一条消息（未连接时静默丢弃，单机模式下不会走到这里） */
export function send(msg) {
  if (!ws || ws.readyState !== WebSocket.OPEN) return false;
  try {
    ws.send(JSON.stringify(msg));
    return true;
  } catch {
    return false;
  }
}

/** 连不上服务器 / 连接断开时退回单机，保证页面仍然可玩（不会白屏） */
export function fallbackToSinglePlayer() {
  if (net.usingFallback) return;
  net.usingFallback = true;
  net.active = false;
  net.isHost = true;
  net.myFaction = DEFAULT_FACTION;
  if (typeof net.onFallback === 'function') net.onFallback();
  if (typeof net.onStatus === 'function') net.onStatus('已切换为单机模式（原来的世界继续跑）');
}

/**
 * 复位「已退回单机」这个单向闩锁 —— **仅供测试**。
 *
 * usingFallback 的设计意图是「只退一次，别反复弹提示」，所以生产环境不该复位。
 * 但自动化测试需要在一进程里反复演练「联机 → 断线 → 退回单机」，
 * 没有这个钩子就只能靠重新加载 main.js，而 main.js 自带副作用、无法重复 import。
 */
export function resetFallbackLatch() {
  net.usingFallback = false;
  net.lastError = null;
}
