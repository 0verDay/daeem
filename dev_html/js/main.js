/**
 * main.js —— 游戏入口：状态初始化 + 主循环 + 输入 + HUD
 */

import { CONFIG, RESOURCE_LABEL } from './config.js';
import { Grid, clamp, tileCenter, dist } from './util.js';
import { createMap, GENERAL_SPAWNS, spawnLayoutFor } from './map.js';
import { createZoneSystem, updateZones, ownedTileCount, refreshBuildingOwnership, zoneAt } from './zone.js';
import { Building, BUILDINGS, removeBuilding, updateTowers, updateBuildingEffects } from './building.js';
import { Unit, createGenerals, findOpenTileNear } from './unit.js';
import { findPath, nearestReachable, occupied, passable, segmentClear, smoothPath, findBlockingWallToward } from './path.js';
import {
  createCamera, centerOn, clampCam, fit, draw, screenToWorld, worldToTile, unitRadius,
} from './render.js';
import { DEFAULT_FACTION, SINGLE_PLAYER_ROSTER, FACTION_ROSTER, factionLabel } from './faction.js';
import {
  net, connect, send, makeSnapshot, applySnapshot, readNetIntent,
  SNAPSHOT_HZ, fallbackToSinglePlayer,
} from './net.js';

/* ------------------------------------------------------------------ */
/* 状态                                                                */
/* ------------------------------------------------------------------ */

const state = {
  time: 0,
  terrain: null,
  base: null,
  generalSpawns: GENERAL_SPAWNS,
  /**
   * ★ 每个阵营各自的将领出生点（key = 阵营）。
   * 单机时只有 'player' 一项，内容就是原版 GENERAL_SPAWNS。
   * 联机时 p1/p2 各在一角 —— 见 map.js 的 spawnLayoutFor()。
   */
  factionSpawns: {},
  /** ★ 每个阵营大本营的坐标（key = 阵营）。复活点、敌人 AI 目标都从这里取。 */
  factionBases: {},
  buildings: null,        // Grid<Building|null> —— 每个地块最多一个建筑
  buildingList: [],
  buildingRevision: 0,    // 建造/拆除时 +1，用于按需重算区块归属
  lastRevision: -1,
  zones: [],
  zoneLookup: [],
  units: [],
  /**
   * ★ 阵营表（多人联机的地基，见 faction.js）
   * myFaction 决定「我」是谁：谁能被选中、谁的单位回血、HUD 显示谁的地块。
   * 单机模式下它就是 'player'，与旧版本行为逐位一致。
   */
  factions: { myFaction: DEFAULT_FACTION, factions: SINGLE_PLAYER_ROSTER.slice(), enemyFaction: 'enemy' },
  camera: null,
  /**
   * 视口信息（**全部使用 CSS 像素**，与相机 / 输入换算保持一致）。
   * 画布后备缓冲按 dpr 放大，绘制前统一 ctx.scale(dpr)，
   * 这样高 DPI 屏上既清晰，鼠标位置又和地块严格对齐。
   */
  view: { w: 1, h: 1, dpr: 1 },
  resources: { food: CONFIG.resource.startFood, gold: CONFIG.resource.startGold },
  ownedTiles: 0,
  /** ★ 对战结算状态。联机时由房主判定并随快照同步；单机永远是 over = false */
  match: { over: false, winner: null, elapsed: 0, logged: false, limitSec: 0 },
  /**
   * ★ 准备界面状态（联机）。
   * 进房间后先停在这里，双方都点「准备」再开战 —— 见 startMatch()。
   * 单机永远 active = false。
   */
  lobby: { active: false, roster: [], ready: {}, countdown: 0, canStart: false, started: false },
  /**
   * ★ 对战规则总开关 —— **只有联机模式才置为 true**。
   * 单机必须保持 v0.3 行为：大本营不可摧毁、单位死了就没了（否则旧手感与旧测试都会被改写）。
   */
  pvpEnabled: false,
  enemySpawnTimer: 0,
  debugAutoSpawn: false,
  log: [],
  ui: {
    buildType: null,       // 'wall' | 'tower' | null
    hoverTile: null,
    hoverValid: false,
    hoverBuilding: null,
    selectedUnits: [],
    selectedBuilding: null,
    showZoneNames: true,
    toasts: [],
    mouseWorld: null,      // 鼠标所在世界坐标
    mouseScreen: null,     // 鼠标在画布内的 CSS 像素坐标（边缘滚屏用）
    edgeScrollPaused: false, // 按住空格可临时冻结边缘滚屏
    debugAim: false,       // 按 G 开关准星，用来核对坐标换算
  },
};

let canvas = null;
let paused = false;
const keys = new Set();
const el = {};

/* ------------------------------------------------------------------ */
/* 初始化                                                              */
/* ------------------------------------------------------------------ */

function init() {
  const map = createMap();
  state.map = map;
  state.terrain = map.terrain;
  state.base = map.base;
  state.buildings = new Grid(map.cols, map.rows, null);

  const zs = createZoneSystem(state);
  state.zones = zs.zones;
  state.zoneLookup = zs.lookup;

  /**
   * 关键顺序：先把**我这一方**的出生点算出来，再建大本营与将领。
   *
   * 单机（myFaction = 'player'）时 spawnLayoutFor 返回的就是原版点位，
   * 所以这一个函数同时覆盖了单机与联机，不需要分支。
   */
  applyFactionLayout(state.factions.myFaction, { log: false });

  // 战斗事件（警戒 / 阵亡 / 复活 / 建筑被拆）→ 事件日志 + 收尸
  state.onCombatEvent = onCombatEvent;
  // 复活点：unit.js 的 tickRespawn 通过它找自家大本营（unit.js 不 import main.js，避免循环依赖）
  state.homeBaseOf = homeBaseOf;

  state.camera = createCamera(state);
  bindUI();
  bindInput();
  selectBuildType(null);

  const baseZone = zoneAt(state, state.base.x, state.base.y);
  pushLog(`大本营位于 (${state.base.x}, ${state.base.y})，所在区块 ${baseZone ? baseZone.name : '无'}`);
  if (map.sealedIslands > 0) toast(`地图连通性修正：封住了 ${map.sealedIslands} 个孤立的可通行格`);
  pushLog('按 1 / 2 / 3 选择将领，右键点击地图移动。');
  requestAnimationFrame(loop);
  initNet();
}

/* ------------------------------------------------------------------ */
/* 联机（房主权威 + 服务器中继，协议见 js/net.js）                      */
/* ------------------------------------------------------------------ */

/**
 * 是否以联机模式启动：URL 带 #net=1（或 ?net=1）才启用。
 * 不加参数就是纯单机，现有行为与测试完全不受影响。
 *   http://<ip>:8080/rts-prototype.html#net=1            房主
 *   http://<ip>:8080/rts-prototype.html#net=1&room=abc   指定房间
 */
function initNet() {
  if (!readNetIntent().on) {
    pushLog('单机模式。想联机测试请用 …/rts-prototype.html#net=1 打开');
    return;
  }

  const intent = readNetIntent();

  /**
   * ★ 立刻把「我这一方」和联机身份对齐，不能等 welcome。
   *
   * 时序陷阱：init() 先建好了 'player' 的世界，本函数再跑。
   * 如果这里不先切到 p1，那么在 welcome 到达之前的那个窗口里
   *   net.isHost === true（房主）而 state.factions.myFaction === 'player'
   * → 玩家点右键时 orderMove 里的 units 过滤（按 myFaction）会找不到任何单位，
   *   命令静默失效。窗口不长，但联网慢的时候足够让人以为"游戏坏了"。
   */
  net.myFaction = FACTION_ROSTER[0];
  net.isHost = true;
  state.factions.myFaction = FACTION_ROSTER[0];
  state.factions.factions = FACTION_ROSTER.slice();

  /**
   * ★ 打开对战规则（**只影响联机**，单机行为一个字节都不变）。
   *   destructibleBase：大本营可被打掉 → 打掉即分胜负（单机保持"永远打不掉"）
   *   respawnSec：阵亡 8 秒后在自家大本营复活，否则玩家死一次就只能干看着
   *   pvpEnabled：总开关，unit.js 靠它决定要不要开复活
   */
  state.pvpEnabled = true;
  CONFIG.pvp.destructibleBase = true;
  state.match.limitSec = CONFIG.pvp.timeLimitSec || 0;

  rebuildLocalWorldForFaction(FACTION_ROSTER[0]);

  // net.js 不 import building.js（避免循环依赖），客机新建远端建筑时通过这里拿到构造器
  net._BuildingCtor = Building;

  net.onStatus = (text) => pushLog(`[联机] ${text}`);
  net.onCommand = handleNetCommand;
  net.onSnapshot = (msg) => applySnapshot(state, msg.s, performance.now());
  // 准备界面：收到别人的准备状态 / 房主的开战通知
  net.onReady = (msg) => setPeerReady(msg.f, msg.ready);
  net.onStart = onNetStart;
  // 客机：房主判定这局结束后，本地也弹一次（胜者由房主算，客机只显示）
  net.onMatchOver = (winner) => {
    if (!state.match.logged) finishMatch(winner);
  };
  net.onFallback = () => {
    /**
     * ★ 退回单机时，必须把「我这一方」同步切回默认阵营。
     *
     * 否则会留下一个坏状态：net.active=false（单机）但 state.factions.myFaction 还是 'p2'。
     * 单机世界里的将领是 'player' 阵营 —— 于是玩家选不中任何单位、也建不了东西
     * （orderMove / pickAt / tryBuildAt 都按 myFaction 过滤）。
     * 断线本身已经够糟了，不能再让页面变成"看上去能玩其实动不了"。
     */
    state.factions.myFaction = DEFAULT_FACTION;
    state.factions.factions = SINGLE_PLAYER_ROSTER.slice();
    state.lobby.active = false;
    state.lobby.started = false;
    state.lobby.countdown = 0;
    state.lobby.roster = [];
    state.lobby.ready = {};
    rebuildLocalWorldForFaction(DEFAULT_FACTION);
    pushLog('本地世界已切回单机阵营（player）');
  };

  pushLog('联机模式：正在连接服务器…');
  connect({ onWelcome: handleNetWelcome });
}

/**
 * 服务器分配了身份（房主 / 客机 + 阵营）之后要做的事。
 *
 * 独立成函数而不是写在闭包里，有两个实际理由：
 *   1. 可测性 —— tools/net-integration-test.mjs 用 DOM 桩跑真实的 main.js，
 *      需要模拟服务器发来 welcome（否则「客机入场」这条最重要的路径在无浏览器环境下无法验证）；
 *   2. 重连 / 换房时可能再次收到 welcome，逻辑不该绑死在第一次 connect 的闭包里。
 */
function handleNetWelcome(msg) {
  if (!msg) return;
  if (msg.faction) state.factions.myFaction = msg.faction;
  if (msg.roster && msg.roster.length) state.factions.factions = msg.roster.slice();
  if (typeof msg.isHost === 'boolean') net.isHost = msg.isHost;
  if (msg.faction) net.myFaction = msg.faction;

  /**
   * ★ 进房间 → **停在准备界面**，不立刻开战。
   *
   * 这一步顺带解决了线上那个事故：房主先进房间、客机还没到的那段窗口里，
   * 名单有 8 个席位但只有 p1 有基地，胜负判定曾经据此判出「p1 获胜」。
   * 现在只有一个人在场时 lobby 根本不会放行，世界也不会被建出来。
   */
  enterLobby();
  updateHud();
}

/* ------------------------------------------------------------------ */
/* 准备界面（双方都点「准备」才开战）                                    */
/* ------------------------------------------------------------------ */

/** 进房间 → 停在准备界面（不建世界、不开始） */
function enterLobby() {
  const roster = (state.factions.factions || []).slice();
  state.lobby.active = true;
  state.lobby.started = false;
  state.lobby.roster = roster;
  state.lobby.ready = {};
  for (const f of roster) state.lobby.ready[f] = false;
  state.lobby.countdown = 0;
  state.lobby.canStart = false;

  // 准备阶段不跑对战逻辑：清掉结算状态，并把世界收成"只有我自己"的样子
  state.match.over = false; state.match.winner = null;
  state.match.elapsed = 0; state.match.logged = false;
  state.pvpEnabled = false;          // 准备阶段 checkVictory 直接返回
  state.units = [];
  state.factionSpawns = {};
  state.factionBases = {};
  for (const b of state.buildingList.slice()) removeBuilding(state, b, true);
  setLocalFaction(state.factions.myFaction);

  const me = state.factions.myFaction;
  pushLog(`已进入房间 ${net.room}（${factionLabel(me)}）—— 等待双方准备…`);
  if (net.isHost) pushLog('你是房主：双方都点「准备」后由你宣布开战');

  refreshLobbyState();
}

/** 重算「能不能开战」：名单里每一方都必须已准备 */
function refreshLobbyState() {
  const roster = state.lobby.roster || [];
  const ready = state.lobby.ready || {};
  // 准备界面至少要两个人 —— 一个人在场时永远不开战
  state.lobby.canStart = roster.length >= 2 && roster.every((f) => !!ready[f]);
}

/** 我点「准备」/「取消准备」 */
function toggleReady() {
  if (!state.lobby.active || state.lobby.countdown > 0) return false;
  const me = state.factions.myFaction;
  const next = !state.lobby.ready[me];
  state.lobby.ready[me] = next;
  refreshLobbyState();
  send({ t: 'ready', ready: next });
  pushLog(next ? '你已准备' : '你取消了准备');
  return next;
}

/** 收到别人的准备状态 */
function setPeerReady(faction, ready) {
  if (!faction) return;
  if (!state.lobby.roster.includes(faction)) state.lobby.roster.push(faction);
  if (state.lobby.ready[faction] === undefined) state.lobby.ready[faction] = false;
  state.lobby.ready[faction] = !!ready;
  refreshLobbyState();
  pushLog(`${factionLabel(faction)} ${ready ? '已准备' : '取消准备'}`);
}

/** 房主：双方都准备好了 → 广播开战并进入倒计时 */
function tryStartMatch() {
  if (!state.lobby.active || state.lobby.started) return false;
  if (!net.isHost) return false;
  if (!state.lobby.canStart) return false;
  const sec = (CONFIG.pvp && CONFIG.pvp.countdownSec) || 0;
  state.lobby.countdown = sec;
  state.lobby.started = true;
  send({ t: 'start', countdown: sec });
  pushLog(sec > 0 ? `双方已准备，${sec} 秒后开战` : '双方已准备，开战！');
  if (sec <= 0) startMatch();
  return true;
}

/** 收到房主的开战通知（客机） */
function onNetStart(msg) {
  if (!net.isHost) {
    const sec = (msg && typeof msg.countdown === 'number') ? msg.countdown : 0;
    state.lobby.started = true;
    state.lobby.countdown = sec;
    pushLog(sec > 0 ? `${sec} 秒后开战` : '开战！');
    if (sec <= 0) startMatch();
  }
}

/**
 * ★ 正式开战：为**名单里每一方**建出基地与部队，然后放开对战规则。
 *
 * 这是「客机也能正确建出全世界」的关键：双方都按同一份名单、同一套确定性规则
 * （spawnLayoutFor）建世界，所以谁在哪个角、基地在哪一格，两边算出来必然一致 ——
 * 不再依赖"谁先谁后"这种巧合。
 */
function startMatch() {
  // 幂等：倒计时结束与 start 广播可能都触发一次
  if (state.lobby.active && !state.lobby.canStart && state.units.length > 0) return;

  state.lobby.active = false;
  state.lobby.countdown = 0;

  const roster = (state.lobby.roster && state.lobby.roster.length)
    ? state.lobby.roster.slice() : state.factions.factions.slice();
  state.factions.factions = roster.slice();
  if (!roster.includes(state.factions.myFaction)) {
    state.factions.myFaction = roster[0];   // 兜底：名单变了也不再指向不存在的阵营
    net.myFaction = state.factions.myFaction;
  }

  // 推倒重来：清掉准备阶段留下的东西，按名单完整重建
  state.units = [];
  state.factionSpawns = {};
  state.factionBases = {};
  for (const b of state.buildingList.slice()) removeBuilding(state, b, true);
  for (const f of roster) applyFactionLayout(f);

  state.pvpEnabled = true;
  CONFIG.pvp.destructibleBase = true;
  state.match.over = false; state.match.winner = null;
  state.match.elapsed = 0; state.match.logged = false;
  state.match.limitSec = CONFIG.pvp.timeLimitSec || 0;

  selectUnits(state.units.filter((u) => u.faction === state.factions.myFaction).slice(0, 1));
  const home = homeBaseOf(state.factions.myFaction);
  if (state.camera && home) centerOn(state.camera, state, (home.x + 0.5) * CONFIG.cell, (home.y + 0.5) * CONFIG.cell);
  updateHud();
  pushLog(`★ 对战开始：${roster.map((f) => factionLabel(f)).join(' vs ')}（按 R 可再准备下一局）`);
  toast('★ 对战开始！');
}

/** 倒计时推进（由主循环调用；客机也走这里，因为它不跑 update 的模拟部分） */
function tickLobby(dt) {
  if (!state.lobby.active) return;
  if (state.lobby.countdown > 0) {
    state.lobby.countdown = Math.max(0, state.lobby.countdown - dt);
    if (state.lobby.countdown === 0) startMatch();
    return;
  }
  // 房主：条件满足就自动开战（不必再点一次按钮）
  if (net.isHost && !state.lobby.started) tryStartMatch();
}

/**
 * 确保本地世界属于指定阵营。
 *
 * ★ 这里刻意**不是**「只在阵营变化时重建」。只看变化会漏掉一类坏状态：
 *   服务器分配的阵营恰好与当前一致（例如重连、或本机此前已按该阵营跑过），
 *   于是跳过重建 —— 可本地世界可能还停在最初的单机 'player' 状态
 *   （init() 天生建的是 'player'，如果 initNet 的重建因为任何原因没生效，
 *     玩家就会「被告知自己是 p1，手里却是单机的部队」，选不中、也建不了东西）。
 *   现在的判据是「世界是不是真的属于这个阵营」，而不是「阵营有没有变」。
 */
function ensureLocalWorld(faction) {
  if (!faction) return;
  const hasOwnUnits = state.units.some((u) => u.alive && u.faction === faction);
  const isPlayerSide = faction === DEFAULT_FACTION || /^p[1-8]$/.test(faction);
  const isSinglePlayerRoster = state.factions.factions.length <= 1;
  /**
   * 世界与阵营不一致的三种情形：
   *   · 手里没有这一方的单位
   *   · 单机世界（只有 'player' 部队）却要当某个联机阵营
   *   · 反过来：联机阵营的部队，却被要求回到单机 'player'
   */
  const mismatched = !hasOwnUnits
    || (faction !== DEFAULT_FACTION && isPlayerSide && state.units.some((u) => u.alive && u.faction === DEFAULT_FACTION))
    || (faction === DEFAULT_FACTION && !isSinglePlayerRoster);
  if (!mismatched) return;
  rebuildLocalWorldForFaction(faction);
}

/**
 * 建立/重建「某一方」的基地与部队。
 *
 * 做四件事（顺序有讲究）：
 *   1. 算这一方的出生点（大本营 + 将领站位 + 防御阵地）—— 见 map.js 的 spawnLayoutFor
 *   2. 拆掉**这一方旧的**大本营（重建时会调这个函数，不能留下孤儿建筑）
 *   3. 建新的大本营（+ 防御阵地），并把大本营坐标记进 state.factionBases
 *   4. 建这一方的将领
 *
 * 单机（faction = 'player'）时出生点就是原版点位，所以这里没有单机/联机分支。
 *
 * ⚠️ 会被调用两次：init() 里一次、initNet() 里一次（那时相机/UI 已就绪）。
 *    所以每一步都要容忍「东西可能不在」。
 */
function applyFactionLayout(faction, opts = {}) {
  const map = state.map;
  if (!map) return;

  /**
   * ★「主阵营」= 名单里的第一个（房主），**不是"我这一方"**。
   *
   * 这点很关键：客机用 state.factions.factions = ['p1','p2']，但它的 myFaction 是 'p2'。
   * 如果拿 myFaction 当主阵营，客机就会把 p2 摆到地图中央的原版大本营上，
   * 而房主那边 p1 也在中央 —— 两边算出**不同的世界**，快照一同步就全乱。
   * 所以主阵营必须只由「名单顺序」决定，而名单来自服务器，两边一致。
   *
   * 兜底链：roster[0] → 我这一方 → 单机默认值。
   * （单机时 roster = ['player']，于是 player 是主阵营，行为与 v0.3 完全一致。）
   */
  const roster = (state.factions.factions && state.factions.factions.length)
    ? state.factions.factions : SINGLE_PLAYER_ROSTER;
  const primary = roster[0] || state.factions.myFaction || DEFAULT_FACTION;
  const layout = spawnLayoutFor(map, faction, primary);
  state.factionSpawns[faction] = layout.spawns;
  state.factionBases[faction] = layout.base;
  if (!state.base || state.factions.myFaction === faction) state.base = layout.base;
  // 单机兼容：state.generalSpawns 始终是这一方的站位（旧代码/测试读它）
  if (state.factions.myFaction === faction) state.generalSpawns = layout.spawns;

  // 2) 清掉需要重建的旧大本营
  //    · owner === 本阵营：这是同阵营重建（切回 p1 / 回退单机）
  //    · 'player' 且本阵营已不是单机默认值：这是 init() 阶段先按单机建出来的那一座，
  //      联机接管后它就成了孤儿（owner='player'，不匹配任何玩家阵营）。
  //      ★ 不清理它会导致「init 建的大本营」与「联机重建的大本营」叠在同一格上，
  //        而且 owner 停在 'player' —— 胜负判定与城墙通行规则都会因此错乱。
  const stale = state.buildingList.filter((b) => b.type === 'base' && (
    b.owner === faction || (b.owner === DEFAULT_FACTION && faction !== DEFAULT_FACTION)
  ));
  for (const b of stale) removeBuilding(state, b, true);   // force：大本营也要能清掉（内部重建）

  // 3) 大本营 + 防御阵地
  addBuilding('base', layout.base.x, layout.base.y, faction, { silent: true });
  for (const d of layout.defenses || []) {
    addBuilding(d.type, d.x, d.y, faction, { silent: true });
  }
  state.buildingRevision++;

  // 4) 将领
  //    ★ 多阵营共存：如果世界已经属于别人（roster 里有多个阵营），就**追加**本阵营的将领，
  //      而不是把 state.units 整个换掉。
  //      踩过的坑：这里原来无条件 `state.units = createGenerals(...)`，
  //      于是房主为 p2 建基地时会把 p1 的部队全部顶掉 ——
  //      结果是「双方基地都在、但地图上只有一方的兵」，根本打不起来。
  //      只有「我换阵营」才该整体重建，那条路径走 setLocalFaction()。
  const multiFaction = (state.factions.factions || []).length > 1;
  const fresh = createGenerals(state, faction);
  if (multiFaction) {
    // 先移除本阵营的旧部队（重建场景），保留其他阵营的
    state.units = state.units.filter((u) => u.faction !== faction);
    state.units.push(...fresh);
  } else {
    state.units = fresh;
  }
  if (state.ui) {
    state.ui.selectedUnits = state.ui.selectedUnits.filter((u) => state.units.indexOf(u) >= 0);
    if (state.ui.selectedBuilding && !state.ui.selectedBuilding.alive) state.ui.selectedBuilding = null;
  }
  if (state.factions.myFaction === faction) {
    const own = state.units.filter((u) => u.faction === faction && u.alive);
    selectUnits(own.length ? [own[0]] : []);
    if (state.camera && own.length) centerOn(state.camera, state, own[0].px, own[0].py);
  }
  updateSelectionPanel();

  if (opts.log) {
    pushLog(`本地世界已切换到 ${factionLabel(faction)}：大本营 (${layout.base.x}, ${layout.base.y})，`
      + `${layout.spawns.length} 个将领，${(layout.defenses || []).length} 个防御建筑`);
  }
}

/**
 * 换阵营 = 重建**本地**世界（id 前缀、大本营归属、出生点都要跟着换）。
 *
 * 与 applyFactionLayout 的区别：
 *   · setLocalFaction  —— 「我换到别的阵营了」：清空全部单位，重建新阵营的部队
 *   · applyFactionLayout —— 「为某个阵营准备它的基地/部队」：多阵营时**追加**，不动别人
 * 联机开局（initNet）与客机入场（handleNetWelcome）走前者；
 * 房主为客机准备基地走后者。
 */
function setLocalFaction(faction) {
  state.units = [];                    // 换阵营：旧阵营的部队不再属于我，整个清掉
  state.factionSpawns = {};
  applyFactionLayout(faction, { log: true });
}

/** @deprecated 旧名，保留给调试句柄使用 */
function rebuildLocalWorldForFaction(faction) {
  setLocalFaction(faction);
}

/** 某阵营的大本营坐标（复活点 / 敌人 AI 目标都从这里取） */
function homeBaseOf(faction) {
  return state.factionBases[faction] || state.base;
}
/**
 * 房主：执行客机的意图。
 * ★ 这里必须按「发送者自己的阵营」过滤单位 —— 否则客机可以操控房主的单位。
 */
function handleNetCommand(cmd) {
  if (!cmd || !net.isHost) return;
  const owner = cmd.f;
  const mine = (u) => u && u.alive && u.faction === owner;

  if (cmd.kind === 'move') {
    const ids = cmd.ids || [];
    let ok = 0;
    for (const id of ids) {
      const u = state.units.find((x) => x.id === id);
      if (!mine(u)) continue;
      if (u.orderMove(state, { x: cmd.x, y: cmd.y })) ok++;
    }
    void ok;
  } else if (cmd.kind === 'build') {
    tryBuildAt(cmd.tx, cmd.ty, owner);
  } else if (cmd.kind === 'spawnEnemy') {
    spawnEnemy(cmd.tx, cmd.ty);
  }
}

/* ------------------------------------------------------------------ */
/* 建筑                                                                */
/* ------------------------------------------------------------------ */

function addBuilding(type, tx, ty, owner = null, opts = {}) {
  if (!state.terrain.has(tx, ty)) return null;
  if (state.buildings.get(tx, ty)) return null;   // 每个地块仅能建造一个建筑
  const who = owner || state.factions.myFaction;
  const z = zoneAt(state, tx, ty);
  const b = new Building(type, tx, ty, who, z ? z.id : -1);
  state.buildings.set(tx, ty, b);
  state.buildingList.push(b);
  state.buildingRevision++;
  if (!opts.silent) {
    refreshBuildingOwnership(state);
    pushLog(`${BUILDINGS[type].name} 建造于 (${tx}, ${ty})${z ? ' · 区块 ' + z.name : ''}`);
  }
  return b;
}

function canBuildAt(type, tx, ty) {
  if (!state.terrain.has(tx, ty)) return false;
  if (state.terrain.get(tx, ty) === 'mountain') return false;
  if (occupied(state, tx, ty)) return false;
  return true;
}

/**
 * 建造。owner 默认为「我这一方」。
 * ★ 联机下客机不能直接建造（它不跑逻辑），要把意图发给房主；见 tryBuildCmd。
 */
function tryBuildAt(tx, ty, owner = null) {
  const type = state.ui.buildType;
  if (!type) return false;
  if (!canBuildAt(type, tx, ty)) {
    toast('该地块无法建造（已有建筑或地形阻挡）');
    return false;
  }
  const def = CONFIG.building[type];
  if (CONFIG.economy.enabled && def.cost) {
    for (const k of Object.keys(def.cost)) {
      if (state.resources[k] < def.cost[k]) { toast(`${RESOURCE_LABEL[k]}不足`); return false; }
    }
    for (const k of Object.keys(def.cost)) state.resources[k] -= def.cost[k];
  }
  addBuilding(type, tx, ty, owner || state.factions.myFaction);
  return true;
}

/** 联机：把建造意图发给房主（客机走这里） */
function tryBuildViaNet(tx, ty) {
  return send({ t: 'cmd', kind: 'build', f: net.faction, tx, ty });
}

/* ------------------------------------------------------------------ */
/* 选择                                                                */
/* ------------------------------------------------------------------ */

/** 「我」控制的阵营。单机 = 'player'；联机 = 服务器分配的 p1 / p2 */
function myFaction() {
  return state.factions.myFaction;
}

function selectUnits(units) {
  for (const u of state.units) u.selected = false;
  state.ui.selectedUnits = units.filter(Boolean);
  for (const u of state.ui.selectedUnits) u.selected = true;
  state.ui.selectedBuilding = null;
  updateSelectionPanel();
}

function selectBuilding(b) {
  for (const u of state.units) u.selected = false;
  state.ui.selectedUnits = [];
  state.ui.selectedBuilding = b;
  updateSelectionPanel();
}

function selectGeneralByHotkey(key) {
  const u = state.units.find((x) => x.alive && x.faction === myFaction() && x.hotkey === key);
  if (u) {
    selectUnits([u]);
    centerOn(state.camera, state, u.px, u.py);
  }
}

/* ------------------------------------------------------------------ */
/* 主循环                                                              */
/* ------------------------------------------------------------------ */

let last = 0;
let frameCount = 0;
function loop(now) {
  frameCount++;
  const dt = Math.min(0.05, (now - last) / 1000 || 0);
  last = now;
  if (!paused) update(dt);
  updateNet(now, dt);
  // 准备界面的倒计时 / 自动开战：客机的 update() 是冻结的，所以这一步必须放在
  // update 之外，否则客机永远不会从准备界面走进对战。
  if (!paused) tickLobby(dt);
  draw(state, canvas, state.camera, buildUiSnapshot(now));
  updateHud();
  requestAnimationFrame(loop);
}

/**
 * 联机每帧：房主广播快照，客机只做插值（世界数据已在 applySnapshot 里更新）。
 *
 * ★ 客机的 update() 是冻结的（见 update 开头），但相机、选中、HUD、绘制照常跑，
 *   所以客机的操作手感是即时的 —— 只有世界状态是等房主的。
 */
function updateNet(now, dt) {
  if (!net.active) return;

  if (net.isHost) {
    net._snapAcc = (net._snapAcc || 0) + dt;
    const period = 1 / SNAPSHOT_HZ;
    if (net._snapAcc >= period) {
      net._snapAcc = 0;
      send({ t: 'snap', s: makeSnapshot(state) });
    }
  } else {
    // 客机的世界由房主的快照驱动（applySnapshot 已更新 state）。
    // 这里不需要再做什么 —— 时间基准由快照自带（net.lastSnapTime），见 render.js 的 unitDrawPos。
  }
}

function buildUiSnapshot(now) {
  return {
    time: state.time,
    /** 本帧时刻（毫秒）。客机靠它做单位位置的插值，见 render.js 的 unitDrawPos */
    now: typeof now === 'number' ? now : performance.now(),
    buildMode: !!state.ui.buildType,
    buildType: state.ui.buildType,
    hoverTile: state.ui.hoverTile,
    hoverValid: state.ui.hoverValid,
    hoverBuilding: state.ui.hoverBuilding,
    selectedUnits: state.ui.selectedUnits,
    selectedBuilding: state.ui.selectedBuilding,
    showZoneNames: state.ui.showZoneNames,
    // ★ 渲染层需要知道「我是哪一方」才能上色（render.js 不 import 游戏状态）
    myFaction: myFaction(),
    /** 我的大本营坐标（阵亡时在它上面画复活倒计时） */
    myBase: homeBaseOf(myFaction()),
    /** 对战结算状态（画结束横幅用） */
    match: state.match,
    /** 准备界面状态（画准备面板用） */
    lobby: state.lobby,
  };
}

function update(dt) {
  /**
   * ★ 联机下只有房主跑权威逻辑。
   * 客机的世界完全由房主的快照驱动（applySnapshot）；如果客机也跑一遍 update，
   * 两份状态会各自漂移，几秒后就会出现「我看到的位置和实际位置不一样」。
   * 注意客机的相机 / 选中 / HUD / 绘制仍然照常跑（它们在 loop 里，不在 update 里）。
   */
  if (net.active && !net.isHost) return;

  state.time += dt;

  // 1) 区块占领（占位规则）
  updateZones(state, dt);

  // 2) 建筑归属变化时才重算
  if (state.buildingRevision !== state.lastRevision) {
    refreshBuildingOwnership(state);
    state.lastRevision = state.buildingRevision;
  }

  // 3) 资源：按己方占领地块数实时增长（「己方」= state.factions.myFaction）
  const tiles = ownedTileCount(state, state.factions.myFaction);
  if (tiles !== state.ownedTiles) {
    const names = ownedZoneNames();
    state.ownedTiles = tiles;
    pushLog(`领地变化：己方地块 ${tiles} 块（区块：${names || '无'}）`);
  }
  state.resources.food += tiles * CONFIG.resource.foodPerTilePerSec * dt;
  state.resources.gold += tiles * CONFIG.resource.goldPerTilePerSec * dt;

  // 4) 单位：移动 + 战斗 / 警戒（参数见 CONFIG.combat）
  for (const u of state.units) u.update(state, dt);
  /**
   * ⚠️ 这里**不能**再按 alive 过滤 state.units（v0.3 是那么写的）。
   *    对战模式下阵亡的单位要留在列表里等复活（unit.js 的 tickRespawn）——
   *    一旦被过滤掉就永远活不过来了。
   *    真正需要清理的只有两种：复活倒计时没开（respawnSec = 0）的死单位、以及被移出战场很久的。
   */
  if (state.units.some((u) => !u.alive)) {
    const keep = (u) => u.alive || u.awaitingRespawn || u.keepDead;
    state.units = state.units.filter(keep);
    // 选中列表 / 选中建筑可能刚刚阵亡或被拆掉，及时清干净
    selectedUnitsClearIfDead();
    if (state.ui.selectedBuilding && !state.ui.selectedBuilding.alive) {
      state.ui.selectedBuilding = null;
      updateSelectionPanel();
    }
  }

  // 5) 箭塔开火 + 建筑受击闪光的衰减
  updateTowers(state, dt);
  updateBuildingEffects(state, dt);

  // 6) 调试：自动刷敌人
  if (state.debugAutoSpawn) {
    state.enemySpawnTimer -= dt;
    if (state.enemySpawnTimer <= 0) {
      spawnEnemy();
      state.enemySpawnTimer = CONFIG.debug.spawnIntervalSec;
    }
  }

  // 7) 相机：键盘平移 + 鼠标边缘滚屏
  updateCameraKeyboard(dt);
  updateCameraEdgeScroll(dt);

  // 8) 敌人 AI（朝玩家据点推进；被城墙挡住时锁定城墙来拆）
  updateEnemies();

  // 9) 胜负判定（大本营被打掉 / 超时比血量）
  checkVictory(dt);

  // 10) 提示气泡过期清理
  const now = performance.now();
  state.ui.toasts = state.ui.toasts.filter((t) => now - t.at < 2600);
}

/* ------------------------------------------------------------------ */
/* 胜负判定（对战）                                                     */
/* ------------------------------------------------------------------ */

/**
 * 判定这一局是否结束。
 *
 * 规则：**某一方的大本营被打掉 → 该方落败**。
 * 前提是 CONFIG.pvp.destructibleBase = true（联机时打开；单机保持不可摧毁）。
 * 另外 CONFIG.pvp.timeLimitSec 到点后按「大本营剩余血量比例」判胜负，防止无限拖时间。
 * 时间上限设为 0 则不限时。
 *
 * ★ 分母必须是「**在场**的阵营」，不能是「名单里的席位」。
 *
 * 线上事故：名单 FACTION_ROSTER 有 8 个席位（p1..p8），但开局只有房主 p1 进了房间、
 * 也就只有 p1 有基地。用名单当分母就会得出「8 个玩家只剩 1 个活着」，
 * 于是**第 0 帧直接判 p1 获胜** —— 两个玩家一打开页面就看见"P1 赢了"，根本没法玩。
 * 现在只统计已经建出基地的阵营（见 spawnedFactions），一个人玩就永远不会"分出胜负"。
 */
function checkVictory(dt) {
  if (state.match.over) return;
  // 单机不谈胜负（大本营本来就打不掉）
  if (!state.pvpEnabled) return;

  const players = spawnedFactions();
  const alive = players.filter((f) => !!findBaseOf(f));

  // 只有**确实有两个以上玩家在场**时才谈"输赢"；只剩一个说明对手已被淘汰
  if (players.length >= 2 && alive.length <= 1) {
    state.match.over = true;
    state.match.winner = alive[0] || null;
    finishMatch(state.match.winner);
    return;
  }

  const limit = (CONFIG.pvp && CONFIG.pvp.timeLimitSec) || 0;
  if (limit <= 0 || players.length < 2) return;
  state.match.elapsed += dt;
  if (state.match.elapsed < limit) return;

  // 超时：按大本营剩余血量比例高者胜
  const score = (f) => {
    const b = findBaseOf(f);
    return b && b.hpMax ? b.hp / b.hpMax : 0;
  };
  const ranked = players.slice().sort((a, b) => score(b) - score(a));
  state.match.over = true;
  state.match.winner = score(ranked[0]) > score(ranked[1]) ? ranked[0] : null;
  finishMatch(state.match.winner, '时间到');
}

/** 某阵营当前的大本营建筑（没有则 null） */
function findBaseOf(faction) {
  return state.buildingList.find((x) => x.alive && x.type === 'base' && x.owner === faction) || null;
}

/**
 * **在场**的玩家阵营 = 已经为它建出基地的那些。
 *
 * 这是胜负判定与"重开一局"的分母。不能直接用 state.factions.factions ——
 * 那是服务器分配的**席位名单**（含还没进房间的 p3..p8）。
 */
function spawnedFactions() {
  const list = playerFactionList();
  return list.filter((f) => !!state.factionBases[f]);
}

function finishMatch(winner, reason) {
  const mine = myFaction();
  if (!state.match.logged) {
    if (!winner) {
      pushLog(`对战结束：平局${reason ? `（${reason}）` : ''}`);
      toast('对战结束：平局');
    } else if (winner === mine) {
      pushLog(`★ 对战结束：${factionLabel(winner)} 获胜！`);
      toast('★ 你赢了！');
    } else {
      pushLog(`对战结束：${factionLabel(winner)} 获胜`);
      toast('你输了');
    }
    state.match.logged = true;
  }
  void reason;
}

/**
 * 重开一局：清空结算状态、让所有单位回到自家基地并满血。
 *
 * 房主调用后，客机会通过后续快照自然跟上（快照里带 match，且单位位置由房主说了算）。
 * 单机也能用（等价于"重置"）。
 */
function resetMatch() {
  state.match.over = false;
  state.match.winner = null;
  state.match.elapsed = 0;
  state.match.logged = false;

  for (const u of state.units) {
    // ★ 只清理 NPC 敌人，玩家单位要复活并送回基地
    //   （写成 `=== 'enemy'` 会让所有玩家单位被跳过、停在 alive=false，
    //     紧接着的过滤器就把它们全删了 —— 重开一局后一个单位都不剩）
    if (u.faction === 'enemy') { u.alive = false; u.keepDead = false; continue; }
    const home = homeBaseOf(u.faction);
    const n = parseInt(String(u.id).split('-').pop(), 10);
    const slot = Number.isFinite(n) ? Math.max(1, n) : 1;
    const RING = [[0, 1], [1, 0], [-1, 0], [0, -1], [1, 1], [-1, -1], [1, -1], [-1, 1]];
    let spot = home;
    for (let k = 0; k < RING.length; k++) {
      const o = RING[(slot - 1 + k) % RING.length];
      if (passable(state, home.x + o[0], home.y + o[1], u.faction)) {
        spot = { x: home.x + o[0], y: home.y + o[1] };
        break;
      }
    }
    u.alive = true;
    u.hp = u.hpMax;
    u.tx = spot.x; u.ty = spot.y;
    u.px = (spot.x + 0.5) * CONFIG.cell;
    u.py = (spot.y + 0.5) * CONFIG.cell;
    u.path = null; u.goal = null; u.goalPt = null; u.moving = false;
    u.respawnTimer = 0;
    u.attackCd = 0;
    u.clearTarget();
  }
  // 敌人死透后清出战场（★ 只清敌人，别把玩家单位一起清掉）
  state.units = state.units.filter((u) => u.faction !== 'enemy' || u.alive);
  /**
   * ★ 关键：把**在场**的玩家大本营恢复到满血。
   *   否则上一局被打掉的那个基地不复原，checkVictory 会立刻又判一次胜负，
   *   这一局刚开就结束。
   *   用 spawnedFactions 而不是 playerFactionList —— 别给还没进房间的席位凭空造基地。
   */
  for (const f of spawnedFactions()) {
    const g = homeBaseOf(f);
    const b = state.buildings.get(g.x, g.y);
    if (b && b.type === 'base') { b.hp = b.hpMax; b.alive = true; }
    else addBuilding('base', g.x, g.y, f, { silent: true });
  }
  state.buildingRevision++;
  selectedUnitsClearIfDead();
  pushLog('新的一局开始');
}

/** 选中列表里剔除已阵亡的单位（空列表时面板也会跟着重置） */
function selectedUnitsClearIfDead() {
  const alive = state.ui.selectedUnits.filter((u) => u.alive);
  if (alive.length !== state.ui.selectedUnits.length) selectUnits(alive);
}

/* ------------------------------------------------------------------ */
/* 敌人（本版没有正式敌人，仅调试用）                                    */
/* ------------------------------------------------------------------ */

function spawnEnemy(tx, ty) {
  // 默认从地图右侧（北侧隘口附近）出现
  const spawn = tx == null ? { x: state.terrain.cols - 1, y: 3 } : { x: tx, y: ty };
  const open = passable(state, spawn.x, spawn.y, 'enemy') ? spawn : findOpenTileNear(state, spawn, 'enemy');
  if (!open) { toast('找不到可用的敌方出生点'); return null; }
  const e = new Unit({
    // ★ id 必须由房主生成：客机用 Math.random() 会算出不同的 id，导致快照对齐时单位错位/闪烁。
    //   客机刷敌人走 trySpawnEnemyViaNet()，请求房主代为生成。
    id: `enemy-${Math.random().toString(36).slice(2, 8)}`,
    name: '测试敌人', tx: open.x, ty: open.y, faction: 'enemy', kind: 'enemy',
  });
  e.state = state;
  state.units.push(e);
  pushLog(`调试：测试敌人在 (${open.x}, ${open.y}) 出现`);
  return e;
}

/** 联机：请房主代刷一个测试敌人（客机的 Math.random 与房主不一致，不能自己生成 id） */
function trySpawnEnemyViaNet(tx, ty) {
  return send({ t: 'cmd', kind: 'spawnEnemy', f: net.faction, tx, ty });
}

/**
 * 找出敌人该往哪个「玩家据点」推进。
 * 单机下永远只有一个 state.base（阵营 'player'），行为与旧版一致；
 * 联机下按最近的玩家单位/建筑决定，免得两个玩家时敌人只认死一个目标。
 */
function playerFactionList() {
  const list = (state.factions && state.factions.factions) || [DEFAULT_FACTION];
  return list.length ? list : [DEFAULT_FACTION];
}

function nearestPlayerBase(from) {
  let best = state.base, bestD = Infinity;
  for (const b of state.buildingList) {
    if (!b.alive || b.type !== 'base') continue;
    if (playerFactionList().indexOf(b.owner) < 0) continue;
    const d = Math.abs(b.tx - from.x) + Math.abs(b.ty - from.y);
    if (d < bestD) { bestD = d; best = { x: b.tx, y: b.ty }; }
  }
  return best;
}
function updateEnemies() {
  for (const u of state.units) {
    if (!u.alive || u.faction !== 'enemy') continue;

    // 正在交战（警戒发现了我方单位）：交给 unit.js 的攻击 / 追击逻辑
    if (u.target) continue;
    // 正在拆建筑（通常是挡路的城墙）：交给 unit.js 的 updateBuildingCombat
    if (u.targetBuilding) continue;

    const goalBase = nearestPlayerBase({ x: u.tx, y: u.ty });

    // 已经贴到据点了就停下（本版不做近战拆家）
    if (Math.abs(u.tx - goalBase.x) + Math.abs(u.ty - goalBase.y) <= 1) { u.stop(); continue; }
    if (u.path && u.path.length) continue;

    // 按“敌方通行规则”寻路：城墙会阻挡，所以只能绕路或拆墙
    const goal = nearestReachable(state, { x: u.tx, y: u.ty }, goalBase, 'enemy');
    if (goal && (u.tx !== goal.x || u.ty !== goal.y)) {
      // ⚠️ moveTo 收的是**像素**坐标，而 A* 给的是**地块**坐标：这里必须换算成格心像素，
      //    否则单位会把地块坐标当成像素坐标，朝地图左上角走（旧版本的 bug）。
      const goalPt = tileCenter(goal.x, goal.y, CONFIG.cell);
      if (u.moveTo(state, goalPt) && u.moving) continue;      // 还在赶路
    }

    // 已经站在“能走到的最近处”（典型情况：大本营被城墙围住，或路线被一整条墙拦断）
    // → 锁定挡路的城墙，由 unit.js 负责“先靠近、再一下一下拆”。
    // 注意这里**不能**只看 moveTo 的返回值：原地不动时 moveTo 也返回 true，
    // 会让敌人站在墙边发呆（这曾经是“敌人不拆墙”的原因）。
    const blocker = findBlockingWallToward(state, { x: u.tx, y: u.ty }, goalBase, u.faction, 'wall');
    if (blocker) u.setBuildingTarget(blocker);
  }
}

/**
 * 找出「该拆的那一段城墙」：挨着敌人自己可达的区域、且离目标据点最近的那一段。
 * 判定逻辑在 path.js 的 findBlockingWallToward()（测试直接用同一个函数，避免两份实现走偏）。
 *
 * 保留这个「面向单位」的包装（而不是只内联调用），是因为它是 window.RTS 的公开调试 API：
 * tools/browser-test.py 与控制台都通过 R.findBlockingWall(state, unit) 使用它。
 */
function findBlockingWall(state, u) {
  const to = nearestPlayerBase({ x: u.tx, y: u.ty }) || state.base;
  return findBlockingWallToward(state, { x: u.tx, y: u.ty }, to, u.faction, 'wall');
}

/* ------------------------------------------------------------------ */
/* 相机：键盘平移 + 鼠标边缘滚屏                                        */
/* ------------------------------------------------------------------ */

function updateCameraKeyboard(dt) {
  const base = CONFIG.camera.keyPanSpeed / state.camera.scale;
  let dx = 0, dy = 0;
  if (keys.has('a') || keys.has('arrowleft')) dx -= 1;
  if (keys.has('d') || keys.has('arrowright')) dx += 1;
  if (keys.has('w') || keys.has('arrowup')) dy -= 1;
  if (keys.has('s') || keys.has('arrowdown')) dy += 1;
  if (dx || dy) {
    state.camera.x += dx * base * dt;
    state.camera.y += dy * base * dt;
    clampCam(state.camera, state);
  }
}

/**
 * 鼠标推到视野边缘 → 视角持续平移。
 * 越靠近边缘滚得越快（靠边距归一化后取平方，手感更细腻）。
 */
function updateCameraEdgeScroll(dt) {
  const ui = state.ui;
  if (!CONFIG.camera.edgeScroll || !ui.mouseScreen || ui.edgeScrollPaused) return;
  const v = state.view;
  const m = ui.mouseScreen;
  const edge = CONFIG.camera.edgeSize;
  const maxSpeed = CONFIG.camera.edgeMaxSpeed;

  const ramp = (dist) => {
    const t = clamp((edge - dist) / edge, 0, 1);
    return t * t * maxSpeed;
  };

  let vx = 0, vy = 0;
  if (m.x <= edge) vx = -ramp(m.x);
  else if (m.x >= v.w - edge) vx = ramp(v.w - m.x);
  if (m.y <= edge) vy = -ramp(m.y);
  else if (m.y >= v.h - edge) vy = ramp(v.h - m.y);

  if (vx === 0 && vy === 0) return;
  // 屏幕像素/秒 → 世界像素/秒
  state.camera.x += (vx / state.camera.scale) * dt;
  state.camera.y += (vy / state.camera.scale) * dt;
  clampCam(state.camera, state);
}

/* ------------------------------------------------------------------ */
/* HUD                                                                 */
/* ------------------------------------------------------------------ */

const $ = (id) => document.getElementById(id);

const UI_IDS = [
  'food', 'gold', 'tiles', 'rate', 'zoneList', 'selName', 'selDetail', 'selHp', 'log', 'toasts',
  'btnWall', 'btnTower', 'btnCancel', 'btnPause', 'btnFit', 'btnZones', 'btnSpawn', 'btnAutoSpawn',
  'btnClearEnemies', 'btnHelp', 'helpBox', 'buildHint', 'statUnits', 'statEnemies',
  'statBuildings', 'statRevision', 'debugAim', 'btnAim', 'btnEdge',
  'btnReady', 'lobbyHint',
];

function initDom() {
  canvas = $('game');
  for (const id of UI_IDS) el[id] = $(id);
  resizeCanvas();
}

function resizeCanvas() {
  const wrap = $('stage');
  const dpr = window.devicePixelRatio || 1;
  const w = Math.max(1, wrap.clientWidth);
  const h = Math.max(1, wrap.clientHeight);

  // 后备缓冲 = CSS 像素 × dpr；绘制时按 dpr 对齐（见 render.js 的 draw）
  canvas.width = Math.round(w * dpr);
  canvas.height = Math.round(h * dpr);
  // 用与 wrap.clientWidth 完全相同的整数值，避免元素被拉伸造成亚像素错位
  canvas.style.width = w + 'px';
  canvas.style.height = h + 'px';

  state.view.w = w;
  state.view.h = h;
  state.view.dpr = dpr;
}

/** 事件坐标 → 画布内的 CSS 像素坐标（与相机/绘制坐标同一套，保证指哪打哪） */
function eventToCanvas(e) {
  const rect = canvas.getBoundingClientRect();
  return { x: e.clientX - rect.left, y: e.clientY - rect.top };
}

/** 取鼠标位置并从当前相机换算出世界坐标与地块 */
function pointerInfo(e) {
  const p = eventToCanvas(e);
  const world = screenToWorld(state.camera, p.x, p.y);
  return { p, world, tile: worldToTile(world.x, world.y) };
}

function updateHud() {
  const mine = myFaction();
  el.food.textContent = state.resources.food.toFixed(CONFIG.resource.decimals);
  el.gold.textContent = state.resources.gold.toFixed(CONFIG.resource.decimals);
  el.tiles.textContent = String(state.ownedTiles);
  el.rate.textContent = `+${(state.ownedTiles * CONFIG.resource.foodPerTilePerSec).toFixed(1)} / +${(state.ownedTiles * CONFIG.resource.goldPerTilePerSec).toFixed(1)} 每秒`;
  el.zoneList.textContent = ownedZoneNames() || '（无）';
  el.statUnits.textContent = String(state.units.filter((u) => u.alive && u.faction === mine).length);
  el.statEnemies.textContent = String(state.units.filter((u) => u.alive && u.faction === 'enemy').length);
  el.statBuildings.textContent = String(state.buildingList.length);
  el.statRevision.textContent = String(state.buildingRevision);
  updateSelectionPanel();
  updateReadyHint();

  if (el.log.dataset.n !== String(state.log.length)) {
    el.log.dataset.n = String(state.log.length);
    el.log.innerHTML = state.log.map((l) => `<div>${l}</div>`).join('');
    el.log.scrollTop = el.log.scrollHeight;
  }

  const now = performance.now();
  const active = state.ui.toasts.filter((t) => now - t.at < 2600);
  const key = active.map((t) => t.msg).join('|');
  if (el.toasts.dataset.k !== key) {
    el.toasts.dataset.k = key;
    el.toasts.innerHTML = active.map((t) => `<div class="toast">${t.msg}</div>`).join('');
  }

  // 坐标调试读数（按 G 开关）
  if (el.debugAim) {
    const ui = state.ui;
    if (!ui.debugAim) {
      el.debugAim.classList.add('hidden');
    } else {
      el.debugAim.classList.remove('hidden');
      const mw = ui.mouseWorld;
      const cam = state.camera;
      el.debugAim.textContent = mw
        ? `dpr ${state.view.dpr} · 视口 ${state.view.w}×${state.view.h} · 缩放 ${cam.scale.toFixed(2)}x\n`
          + `鼠标世界坐标 (${mw.x.toFixed(1)}, ${mw.y.toFixed(1)}) → 地块 (${Math.floor(mw.x / CONFIG.cell)}, ${Math.floor(mw.y / CONFIG.cell)})`
        : `dpr ${state.view.dpr} · 视口 ${state.view.w}×${state.view.h} · 缩放 ${cam.scale.toFixed(2)}x（把鼠标移到地图上）`;
    }
  }
}

function updateSelectionPanel() {
  const u = state.ui.selectedUnits[0];
  const b = state.ui.selectedBuilding;
  const mine = myFaction();
  if (b) {
    const hpTxt = `生命 ${Math.ceil(b.hp)} / ${b.hpMax}`;
    el.selName.textContent = `${BUILDINGS[b.type].name}（${b.owner === mine ? '己方' : factionLabel(b.owner)}）`;
    el.selDetail.textContent = b.type === 'tower'
      ? `( ${b.tx}, ${b.ty} ) ${hpTxt} · 攻击 ${b.def.damage} / 射程 ${b.def.range} 格 / 间隔 ${b.def.cooldown}s`
      : `( ${b.tx}, ${b.ty} ) 占据 1 个地块 · ${hpTxt}`;
    el.selHp.style.width = (100 * clamp(b.hp / b.hpMax, 0, 1)) + '%';
    return;
  }
  if (u) {
    const z = zoneAt(state, u.tx, u.ty);
    const goal = u.goal ? ` → (${u.goal.x}, ${u.goal.y})` : '';
    const zoneTxt = z
      ? `${z.name}${z.owner === mine ? '·己方' : z.progress > 0 ? `·占领 ${Math.round(z.progress * 100)}%` : '·无主'}`
      : '无';
    const atk = `攻击 ${u.combat.damage} / 距离 ${u.combat.range} 格 / 间隔 ${u.combat.cooldownSec}s · 警戒 ${CONFIG.combat.aggroRange} 格`;
    const tgt = u.target && u.target.alive
      ? `\n交战中：${u.target.name}（${(dist(u.px, u.py, u.target.px, u.target.py) / CONFIG.cell).toFixed(1)} 格）`
      : '';
    el.selName.textContent = `${u.name}（快捷键 ${u.hotkey}）`;
    el.selDetail.textContent = `位置 (${u.tx}, ${u.ty})${goal} · 所在区块 ${zoneTxt}\n${atk}${tgt}`;
    el.selHp.style.width = (100 * clamp(u.hp / u.hpMax, 0, 1)) + '%';
    return;
  }
  el.selName.textContent = '未选中';
  el.selDetail.textContent = '按 1 / 2 / 3 或左键点击选择将领';
  el.selHp.style.width = '0%';
}

function ownedZoneNames() {
  return state.zones.filter((z) => z.owner === myFaction()).map((z) => z.name).join(', ');
}

function pushLog(msg) {
  state.log.push(msg);
  if (state.log.length > 120) state.log.splice(0, state.log.length - 120);
}

/** 战斗事件（unit.js 通过 state.onCombatEvent 回调进来）→ 事件日志 / 提示 / 建筑收尸 */
function onCombatEvent(evt) {
  if (!evt) return;
  const mine = myFaction();
  if (evt.type === 'alert') {
    if (evt.unit.faction === mine) pushLog(`${evt.unit.name} 发现 ${evt.target.name}，进入警戒`);
  } else if (evt.type === 'kill') {
    const by = evt.source ? `（${actorName(evt.source)} 击杀）` : '';
    const wait = CONFIG.pvp && CONFIG.pvp.respawnSec > 0
      ? `，${CONFIG.pvp.respawnSec} 秒后复活` : '';
    pushLog(`${evt.unit.name} 阵亡${by}${wait}`);
    if (evt.unit.faction === mine) toast(`${evt.unit.name} 阵亡${by}${wait}`);
  } else if (evt.type === 'respawn') {
    // 只给自家单位写日志，免得对面每复活一个就刷一条
    if (evt.unit.faction === mine) {
      pushLog(`${evt.unit.name} 已在自家大本营复活（第 ${evt.unit.deaths} 次阵亡）`);
    }
  } else if (evt.type === 'buildingDown') {
    const b = evt.building;
    const by = evt.source ? `被 ${actorName(evt.source)} 拆毁` : '被拆毁';
    pushLog(`${actorName(b)} (${b.tx}, ${b.ty}) ${by}`);
    if (b.owner === mine) toast(`${actorName(b)} 被拆毁！`);
    const wasBase = b.type === 'base';
    const loser = b.owner;
    /**
     * ★ 必须 force = true。
     *
     * removeBuilding 的默认规则是「大本营不可拆」——那是给**玩家主动拆除**（X / Delete）
     * 用的，防止玩家把自家大本营拆了。但这里走的是**战斗摧毁**：血量已经被打到 0，
     * 建筑必须真的从地图上消失。
     *
     * 踩过的坑：这里没传 force，于是拆到 0 血的大本营原地不动、还是 alive，
     * 而胜负却已经判了 —— 出现「基地明明被打爆了却还立在那里」的坏状态。
     * 传 force 之后，玩家手动拆大本营依然是禁止的（那条路径不经过这里）。
     */
    removeBuilding(state, b, true);
    state.buildingRevision++;

    /**
     * ★ 胜负条件：大本营被打掉 → 该方落败。
     * 只用**在场**的阵营判断（见 spawnedFactions）—— 名单里那些还没进房间的席位不算数，
     * 否则会出现「打掉一个基地就宣布只剩一个玩家」的误判。
     */
    if (wasBase && !state.match.over && spawnedFactions().length >= 2) {
      state.match.over = true;
      const survivors = spawnedFactions().filter((f) => f !== loser);
      state.match.winner = survivors.length === 1 ? survivors[0] : null;
      finishMatch(state.match.winner, `${factionLabel(loser)} 大本营被拆`);
    }  }
}

/** 日志里显示攻击者名字：单位有 name，建筑有 def.name */
function actorName(x) {
  return x.name || (x.def && x.def.name) || '未知';
}

function toast(msg) {
  state.ui.toasts.push({ msg, at: performance.now() });
}

/* ------------------------------------------------------------------ */
/* UI 绑定                                                             */
/* ------------------------------------------------------------------ */

function selectBuildType(type) {
  state.ui.buildType = type;
  if (el.btnWall) el.btnWall.classList.toggle('active', type === 'wall');
  if (el.btnTower) el.btnTower.classList.toggle('active', type === 'tower');
  if (el.buildHint) {
    el.buildHint.textContent = type
      ? `建造模式：${type === 'wall' ? '城墙' : '箭塔'} —— 左键放置，右键 / Esc 退出。本版建造免费。`
      : '建造模式关闭（按 B 建城墙 / T 建箭塔）';
  }
  updateReadyHint();
}

/** 把「准备」按钮的文字与状态刷新出来（准备界面 / 对战中都可能变） */
function updateReadyHint() {
  if (!el.btnReady) return;
  const inLobby = state.lobby.active;
  const meReady = !!state.lobby.ready[state.factions.myFaction];
  el.btnReady.textContent = inLobby
    ? (meReady ? '✓ 已准备（点此取消）' : '✅ 准备 (R)')
    : '↻ 再来一局 / 重新准备 (R)';
  el.btnReady.classList.toggle('active', inLobby && meReady);
  el.btnReady.classList.toggle('hidden', !net.active);
  if (el.lobbyHint) {
    const others = (state.lobby.roster || []).filter((f) => f !== state.factions.myFaction);
    const readyN = (state.lobby.roster || []).filter((f) => state.lobby.ready[f]).length;
    el.lobbyHint.textContent = inLobby
      ? `准备阶段：${readyN} / ${state.lobby.roster.length} 人已准备`
        + (others.length ? '' : '（目前只有你一个人，等对手进同一个房间）')
      : (state.match.over ? '这一局结束了 —— 按 R 或点按钮再开一局' : '');
  }
}

function bindUI() {
  el.btnWall.addEventListener('click', () => selectBuildType(state.ui.buildType === 'wall' ? null : 'wall'));
  el.btnTower.addEventListener('click', () => selectBuildType(state.ui.buildType === 'tower' ? null : 'tower'));
  el.btnCancel.addEventListener('click', () => selectBuildType(null));
  el.btnPause.addEventListener('click', () => {
    paused = !paused;
    el.btnPause.textContent = paused ? '▶ 继续' : '⏸ 暂停';
    el.btnPause.classList.toggle('active', paused);
  });
  el.btnFit.addEventListener('click', () => fit(state.camera, state));
  el.btnZones.addEventListener('click', () => {
    state.ui.showZoneNames = !state.ui.showZoneNames;
    el.btnZones.classList.toggle('active', state.ui.showZoneNames);
  });
  el.btnZones.classList.toggle('active', state.ui.showZoneNames);
  el.btnSpawn.addEventListener('click', () => {
    // ★ 客机不能自己刷：敌人 id 由 Math.random() 生成，两边算出来不一样会导致快照对不上
    if (net.active && !net.isHost) { trySpawnEnemyViaNet(); return; }
    spawnEnemy();
  });
  el.btnAutoSpawn.addEventListener('click', () => {
    if (net.active && !net.isHost) { toast('自动刷敌由房主控制'); return; }
    state.debugAutoSpawn = !state.debugAutoSpawn;
    state.enemySpawnTimer = 0;
    el.btnAutoSpawn.classList.toggle('active', state.debugAutoSpawn);
  });
  el.btnClearEnemies.addEventListener('click', () => {
    if (net.active && !net.isHost) { toast('清除敌人由房主控制'); return; }
    state.units = state.units.filter((u) => u.faction !== 'enemy');
    pushLog('调试：清除全部测试敌人');
  });
  el.btnAim.addEventListener('click', toggleAimDebug);
  el.btnEdge.addEventListener('click', () => {
    CONFIG.camera.edgeScroll = !CONFIG.camera.edgeScroll;
    el.btnEdge.classList.toggle('active', CONFIG.camera.edgeScroll);
    toast(CONFIG.camera.edgeScroll ? '边缘滚屏：开（鼠标推到视野边缘即移动视角）' : '边缘滚屏：关');
  });
  el.btnEdge.classList.toggle('active', CONFIG.camera.edgeScroll);
  el.btnHelp.addEventListener('click', () => el.helpBox.classList.toggle('hidden'));
  // 准备 / 再来一局
  if (el.btnReady) el.btnReady.addEventListener('click', () => {
    if (state.lobby.active) { toggleReady(); return; }
    // 对战已结束：重新回到准备界面，等双方再点准备
    if (state.match.over) { enterLobby(); toast('已回到准备界面，双方点「准备」再开一局'); return; }
    toggleReady();
  });
}

/** 坐标调试准星开关（按钮与 G 键共用） */
function toggleAimDebug() {
  state.ui.debugAim = !state.ui.debugAim;
  if (el.btnAim) el.btnAim.classList.toggle('active', state.ui.debugAim);
  toast(state.ui.debugAim
    ? '坐标调试准星：开（红叉=鼠标点，绿圈=判定地块中心，两者应重合）'
    : '坐标调试准星：关');
}

/* ------------------------------------------------------------------ */
/* 输入                                                               */
/* ------------------------------------------------------------------ */

function bindInput() {
  const onResize = () => {
    resizeCanvas();
    clampCam(state.camera, state);
  };
  window.addEventListener('resize', onResize);
  // 侧栏/帮助面板折叠等造成画布尺寸变化时也要重算
  if (window.ResizeObserver) new ResizeObserver(onResize).observe($('stage'));

  canvas.addEventListener('contextmenu', (e) => e.preventDefault());

  canvas.addEventListener('mousemove', (e) => {
    const { p, world, tile: t } = pointerInfo(e);
    state.ui.mouseWorld = world;
    state.ui.mouseScreen = p;
    const inside = state.terrain.has(t.x, t.y);
    state.ui.hoverTile = inside ? t : null;
    state.ui.hoverValid = inside && state.ui.buildType ? canBuildAt(state.ui.buildType, t.x, t.y) : false;
    state.ui.hoverBuilding = inside ? state.buildings.get(t.x, t.y) : null;
  });

  canvas.addEventListener('mouseleave', () => {
    state.ui.hoverTile = null;
    state.ui.hoverBuilding = null;
    state.ui.mouseWorld = null;
    state.ui.mouseScreen = null;   // 鼠标离开画布 → 停止边缘滚屏
  });

  canvas.addEventListener('mousedown', (e) => {
    const { world, tile: t } = pointerInfo(e);

    if (e.button === 2) {
      if (state.ui.buildType) { selectBuildType(null); return; }
      orderMove(world, t);
      return;
    }
    if (e.button === 0) {
      // ★ 客机：建造意图发给房主（本地不跑逻辑），房主收到后再真正落成
      if (state.ui.buildType) {
        if (net.active && !net.isHost) { tryBuildViaNet(t.x, t.y); return; }
        tryBuildAt(t.x, t.y);
        return;
      }
      pickAt(world, t, e.shiftKey);
    }
  });

  canvas.addEventListener('wheel', (e) => {
    e.preventDefault();
    const p = eventToCanvas(e);
    // 以光标为锚点缩放：缩放前后光标下的世界坐标保持不变
    const before = screenToWorld(state.camera, p.x, p.y);
    const factor = Math.exp(-e.deltaY * 0.0012);
    state.camera.scale = clamp(state.camera.scale * factor, state.camera.minScale, state.camera.maxScale);
    const after = screenToWorld(state.camera, p.x, p.y);
    state.camera.x += before.x - after.x;
    state.camera.y += before.y - after.y;
    clampCam(state.camera, state);
  }, { passive: false });

  window.addEventListener('keydown', (e) => {
    const k = e.key.toLowerCase();
    keys.add(k);
    if (k === ' ') { state.ui.edgeScrollPaused = true; }   // 空格：临时冻结边缘滚屏
    if (k === '1' || k === '2' || k === '3') { selectGeneralByHotkey(k); return; }
    if (k === 'b') { selectBuildType(state.ui.buildType === 'wall' ? null : 'wall'); return; }
    if (k === 't') { selectBuildType(state.ui.buildType === 'tower' ? null : 'tower'); return; }
    if (k === 'escape') { selectBuildType(null); selectUnits([]); return; }
    if (k === 'f') { fit(state.camera, state); return; }
    if (k === 'home') {
      centerOn(state.camera, state, (state.base.x + 0.5) * CONFIG.cell, (state.base.y + 0.5) * CONFIG.cell);
      return;
    }
    if (k === 'g') { toggleAimDebug(); return; }
    if (k === 'n') {
      state.ui.showZoneNames = !state.ui.showZoneNames;
      el.btnZones.classList.toggle('active', state.ui.showZoneNames);
      return;
    }
    if (k === 'p') {
      paused = !paused;
      el.btnPause.textContent = paused ? '▶ 继续' : '⏸ 暂停';
      el.btnPause.classList.toggle('active', paused);
      return;
    }
    if (k === 'e') { spawnEnemy(); return; }
    if (k === 'r') { toggleReady(); return; }
    if (k === 'delete' || k === 'x') {
      const b = state.ui.selectedBuilding;
      if (b) {
        if (removeBuilding(state, b)) {
          state.buildingRevision++;
          state.ui.selectedBuilding = null;
          pushLog(`拆除 ${BUILDINGS[b.type].name} (${b.tx}, ${b.ty})`);
        } else toast('大本营不可拆除');
      }
      return;
    }
    if (k === 'h') { el.helpBox.classList.toggle('hidden'); return; }
  });

  window.addEventListener('keyup', (e) => {
    const k = e.key.toLowerCase();
    keys.delete(k);
    if (k === ' ') state.ui.edgeScrollPaused = false;
  });
  window.addEventListener('blur', () => {
    keys.clear();
    state.ui.edgeScrollPaused = false;
  });
}

/**
 * 右键下达移动命令。
 *
 * ★ 联机分支：客机不跑逻辑，所以它把「哪些单位、走到哪个像素点」发给房主，
 *   由房主在自己的权威世界上下达。只发**坐标和单位 id**，不发路径 ——
 *   路径由房主算（它才知道最新的城墙/单位位置），这样也天然避免了路径欺骗。
 */
function orderMove(world, tile) {
  const mine = myFaction();
  const units = state.ui.selectedUnits.filter((u) => u.alive && u.faction === mine);
  if (!units.length) return;

  if (net.active && !net.isHost) {
    send({
      t: 'cmd', kind: 'move', f: mine,
      ids: units.map((u) => u.id),
      x: world.x, y: world.y,
    });
    // 客机本地立刻给一点反馈：把目标点画出来（真正的移动等房主快照）
    units.forEach((u, i) => {
      const target = i === 0 ? world : spreadTarget(world, i);
      u.goalPt = target;
      u.goal = { x: Math.floor(target.x / CONFIG.cell), y: Math.floor(target.y / CONFIG.cell) };
    });
    return;
  }

  let ok = 0;
  units.forEach((u, i) => {
    // 单位直接走向**鼠标点击的那个像素位置**（点到哪走到哪）
    const target = i === 0 ? world : spreadTarget(world, i);
    if (u.orderMove(state, target)) ok++;
  });
  if (ok === 0) toast('无法到达该位置（被地形或建筑挡住）');
}

/** 多选时给每个单位错开一个小偏移（像素），避免完全重叠 */
function spreadTarget(worldPt, i) {
  const offs = [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [-1, -1]];
  const o = offs[i % offs.length];
  const d = CONFIG.cell * 0.28;
  return { x: worldPt.x + o[0] * d, y: worldPt.y + o[1] * d };
}

function pickAt(world, tile, additive) {
  // 1) 先看点到的建筑
  const b = state.buildings.get(tile.x, tile.y);
  if (b) { selectBuilding(b); return; }

  // 2) 再找附近的己方单位（点击容差 = 单位半径 + 配置容差）
  const tol = unitRadius('general') + CONFIG.unit.hitPad;
  const mine = myFaction();
  let best = null, bestD = Infinity;
  for (const u of state.units) {
    if (!u.alive || u.faction !== mine) continue;
    const d = Math.hypot(u.px - world.x, u.py - world.y);
    if (d <= tol && d < bestD) { bestD = d; best = u; }
  }
  if (best) {
    if (additive) {
      const list = state.ui.selectedUnits.slice();
      const i = list.indexOf(best);
      if (i >= 0) list.splice(i, 1); else list.push(best);
      selectUnits(list);
    } else selectUnits([best]);
    return;
  }
  if (!additive) selectUnits([]);
}

/* ------------------------------------------------------------------ */
/* 启动                                                                */
/* ------------------------------------------------------------------ */

initDom();
init();

/* ------------------------------------------------------------------ */
/* 调试句柄：浏览器控制台里可直接查看 / 操作内部状态                      */
/* 例：RTS.state.units.length、RTS.state.ownedTiles、RTS.spawnEnemy()    */
/* ------------------------------------------------------------------ */

window.RTS = {
  state,
  CONFIG,
  get frames() { return frameCount; },
  spawnEnemy,
  addBuilding,
  tryBuildAt,
  selectBuildType,
  selectUnits,
  selectBuilding,
  selectGeneralByHotkey,
  ownedZoneNames,
  pickAt,
  orderMove,
  // 下面是给自动化测试 / 控制台调试用的
  tick: update,
  /**
   * 推进**一整个主循环帧**（update + updateNet），这是 loop() 里真正做的事。
   *
   * 为什么需要它：快照广播在 updateNet() 里，而 tick() 只跑 update()。
   * 想验证「房主是不是按 20Hz 广播」就必须走完整的 loop 路径，
   * 否则联机广播这一段永远测不到（tools/net-integration-test.mjs 用它）。
   */
  frame: (dt = 1 / 60, now = performance.now()) => {
    if (!paused) update(dt);
    updateNet(now, dt);
  },
  drawOnce: (now = performance.now()) => draw(state, canvas, state.camera, buildUiSnapshot(now)),
  findPathFor: (st, from, to, faction) => findPath(st, from, to, faction),
  // 直线移动：某条直线是否可走 / 折线拉直的结果
  segmentClearFor: (st, a, b, faction) => segmentClear(st, a.x, a.y, b.x, b.y, faction),
  smoothPathFor: (st, pts, faction) => smoothPath(st, pts, faction),
  findBlockingWall,
  removeBuildingFor: (st, b, force = false) => removeBuilding(st, b, force),
  pointerInfo,
  eventToCanvas,
  resize: resizeCanvas,
  // 坐标换算（测试里用来核对“鼠标点 ↔ 地块”是否一致）
  screenToWorld: (sx, sy) => screenToWorld(state.camera, sx, sy),
  worldToTile,
  tileCenter: (tx, ty) => tileCenter(tx, ty, CONFIG.cell),
  fitView: () => fit(state.camera, state),

  /* ---- 联机调试句柄（控制台里用来观察联机状态） ---- */
  net,                                          // net.isHost / net.myFaction / net.peers / net.snapCount
  myFaction,
  netStatus: () => ({
    active: net.active, isHost: net.isHost, connected: net.connected,
    faction: net.myFaction, peers: net.peers, snaps: net.snapCount,
    error: net.lastError, fallback: net.usingFallback,
  }),
  netSend: (msg) => send(msg),
  netGoOffline: () => fallbackToSinglePlayer(),
  handleNetWelcome,                             // 模拟服务器分配身份（调试 / 自动化测试）
  rebuildLocalWorldForFaction,                  // 手动切换阵营
  applyFactionLayout,                           // 重建某一方的基地与部队
  homeBaseOf,                                   // 某阵营的大本营坐标
  myBase: () => homeBaseOf(myFaction()),
  matchState: () => ({ ...state.match }),
  resetMatch,                                   // 重开一局（清结算、单位回基地满血）
  ensureLocalWorld,                             // 确保本地世界属于指定阵营
  onCombatEvent,                                // 事件处理器（测试"拆掉建筑"这条路径用）
  /* ---- 准备界面 ---- */
  enterLobby,                                   // 回到准备界面
  startMatch,                                   // 立即开战（跳过倒计时；测试与调试用）
  toggleReady,                                  // 我点准备 / 取消
  setPeerReady,                                 // 模拟收到别人的准备状态
  tryStartMatch,                                // 房主：条件满足就开战
  tickLobby,                                    // 推进准备倒计时
  onNetStart,                                   // 模拟收到房主的「开战」通知
  lobbyState: () => ({
    active: state.lobby.active, started: state.lobby.started,
    roster: state.lobby.roster.slice(), ready: { ...state.lobby.ready },
    countdown: state.lobby.countdown, canStart: state.lobby.canStart,
  }),
};
