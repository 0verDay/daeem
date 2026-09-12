/**
 * main.js —— 游戏入口：状态初始化 + 主循环 + 输入 + HUD
 */

import { CONFIG, RESOURCE_LABEL } from './config.js';
import { Grid, clamp, tileCenter, dist } from './util.js';
import { createMap, GENERAL_SPAWNS } from './map.js';
import { createZoneSystem, updateZones, ownedTileCount, refreshBuildingOwnership, zoneAt } from './zone.js';
import { Building, BUILDINGS, removeBuilding, updateTowers, updateBuildingEffects } from './building.js';
import { Unit, createGenerals, findOpenTileNear } from './unit.js';
import { findPath, nearestReachable, occupied, passable, segmentClear, smoothPath, findBlockingWallToward } from './path.js';
import {
  createCamera, centerOn, clampCam, fit, draw, screenToWorld, worldToTile, unitRadius,
} from './render.js';

/* ------------------------------------------------------------------ */
/* 状态                                                                */
/* ------------------------------------------------------------------ */

const state = {
  time: 0,
  terrain: null,
  base: null,
  generalSpawns: GENERAL_SPAWNS,
  buildings: null,        // Grid<Building|null> —— 每个地块最多一个建筑
  buildingList: [],
  buildingRevision: 0,    // 建造/拆除时 +1，用于按需重算区块归属
  lastRevision: -1,
  zones: [],
  zoneLookup: [],
  units: [],
  camera: null,
  /**
   * 视口信息（**全部使用 CSS 像素**，与相机 / 输入换算保持一致）。
   * 画布后备缓冲按 dpr 放大，绘制前统一 ctx.scale(dpr)，
   * 这样高 DPI 屏上既清晰，鼠标位置又和地块严格对齐。
   */
  view: { w: 1, h: 1, dpr: 1 },
  resources: { food: CONFIG.resource.startFood, gold: CONFIG.resource.startGold },
  ownedTiles: 0,
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
  state.terrain = map.terrain;
  state.base = map.base;
  state.buildings = new Grid(map.cols, map.rows, null);

  const zs = createZoneSystem();
  state.zones = zs.zones;
  state.zoneLookup = zs.lookup;

  // 大本营：开局自带，不可建造、不可拆除
  addBuilding('base', state.base.x, state.base.y, 'player', { silent: true });

  // 三个将领占位单位
  state.units = createGenerals(state);
  // 战斗事件（警戒 / 阵亡）→ 事件日志
  state.onCombatEvent = onCombatEvent;
  selectUnits([state.units[0]]);

  state.camera = createCamera(state);
  bindUI();
  bindInput();
  selectBuildType(null);

  const baseZone = zoneAt(state, state.base.x, state.base.y);
  pushLog(`大本营位于 (${state.base.x}, ${state.base.y})，所在区块 ${baseZone ? baseZone.name : '无'}`);
  if (map.sealedIslands > 0) toast(`地图连通性修正：封住了 ${map.sealedIslands} 个孤立的可通行格`);
  pushLog('按 1 / 2 / 3 选择将领，右键点击地图移动。');
  requestAnimationFrame(loop);
}

/* ------------------------------------------------------------------ */
/* 建筑                                                                */
/* ------------------------------------------------------------------ */

function addBuilding(type, tx, ty, owner = 'player', opts = {}) {
  if (!state.terrain.has(tx, ty)) return null;
  if (state.buildings.get(tx, ty)) return null;   // 每个地块仅能建造一个建筑
  const z = zoneAt(state, tx, ty);
  const b = new Building(type, tx, ty, owner, z ? z.id : -1);
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

function tryBuildAt(tx, ty) {
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
  addBuilding(type, tx, ty, 'player');
  return true;
}

/* ------------------------------------------------------------------ */
/* 选择                                                                */
/* ------------------------------------------------------------------ */

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
  const u = state.units.find((x) => x.alive && x.faction === 'player' && x.hotkey === key);
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
  draw(state, canvas, state.camera, buildUiSnapshot());
  updateHud();
  requestAnimationFrame(loop);
}

function buildUiSnapshot() {
  return {
    time: state.time,
    buildMode: !!state.ui.buildType,
    buildType: state.ui.buildType,
    hoverTile: state.ui.hoverTile,
    hoverValid: state.ui.hoverValid,
    hoverBuilding: state.ui.hoverBuilding,
    selectedUnits: state.ui.selectedUnits,
    selectedBuilding: state.ui.selectedBuilding,
    showZoneNames: state.ui.showZoneNames,
  };
}

function update(dt) {
  state.time += dt;

  // 1) 区块占领（占位规则）
  updateZones(state, dt);

  // 2) 建筑归属变化时才重算
  if (state.buildingRevision !== state.lastRevision) {
    refreshBuildingOwnership(state);
    state.lastRevision = state.buildingRevision;
  }

  // 3) 资源：按己方占领地块数实时增长
  const tiles = ownedTileCount(state, 'player');
  if (tiles !== state.ownedTiles) {
    const names = ownedZoneNames();
    state.ownedTiles = tiles;
    pushLog(`领地变化：己方地块 ${tiles} 块（区块：${names || '无'}）`);
  }
  state.resources.food += tiles * CONFIG.resource.foodPerTilePerSec * dt;
  state.resources.gold += tiles * CONFIG.resource.goldPerTilePerSec * dt;

  // 4) 单位：移动 + 战斗 / 警戒（参数见 CONFIG.combat）
  for (const u of state.units) u.update(state, dt);
  if (state.units.some((u) => !u.alive)) {
    state.units = state.units.filter((u) => u.alive);
    // 选中列表 / 选中建筑可能刚刚阵亡或被拆掉，及时清干净
    if (state.ui.selectedUnits.some((u) => !u.alive)) {
      selectUnits(state.ui.selectedUnits.filter((u) => u.alive));
    }
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

  // 8) 敌人 AI（朝大本营推进；被城墙挡住时锁定城墙来拆）
  updateEnemies();

  // 9) 提示气泡过期清理
  const now = performance.now();
  state.ui.toasts = state.ui.toasts.filter((t) => now - t.at < 2600);
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
    id: `enemy-${Math.random().toString(36).slice(2, 8)}`,
    name: '测试敌人', tx: open.x, ty: open.y, faction: 'enemy', kind: 'enemy',
  });
  e.state = state;
  state.units.push(e);
  pushLog(`调试：测试敌人在 (${open.x}, ${open.y}) 出现`);
  return e;
}

function updateEnemies() {
  for (const u of state.units) {
    if (!u.alive || u.faction !== 'enemy') continue;

    // 正在交战（警戒发现了我方单位）：交给 unit.js 的攻击 / 追击逻辑
    if (u.target) continue;
    // 正在拆建筑（通常是挡路的城墙）：交给 unit.js 的 updateBuildingCombat
    if (u.targetBuilding) continue;

    // 已经贴到大本营就停下（本版不做近战拆家）
    if (Math.abs(u.tx - state.base.x) + Math.abs(u.ty - state.base.y) <= 1) { u.stop(); continue; }
    if (u.path && u.path.length) continue;

    // 按“敌方通行规则”寻路：城墙会阻挡，所以只能绕路或拆墙
    const goal = nearestReachable(state, { x: u.tx, y: u.ty }, state.base, 'enemy');
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
    const blocker = findBlockingWall(state, u);
    if (blocker) u.setBuildingTarget(blocker);
  }
}

/**
 * 找出“该拆的那一段城墙”：挨着敌人自己可达的区域、且离大本营最近的那一段。
 * 判定逻辑在 path.js 的 findBlockingWallToward()（测试直接用同一个函数，避免两份实现走偏）。
 */
function findBlockingWall(state, u) {
  return findBlockingWallToward(state, { x: u.tx, y: u.ty }, state.base, u.faction, 'wall');
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
  el.food.textContent = state.resources.food.toFixed(CONFIG.resource.decimals);
  el.gold.textContent = state.resources.gold.toFixed(CONFIG.resource.decimals);
  el.tiles.textContent = String(state.ownedTiles);
  el.rate.textContent = `+${(state.ownedTiles * CONFIG.resource.foodPerTilePerSec).toFixed(1)} / +${(state.ownedTiles * CONFIG.resource.goldPerTilePerSec).toFixed(1)} 每秒`;
  el.zoneList.textContent = ownedZoneNames() || '（无）';
  el.statUnits.textContent = String(state.units.filter((u) => u.alive && u.faction === 'player').length);
  el.statEnemies.textContent = String(state.units.filter((u) => u.alive && u.faction === 'enemy').length);
  el.statBuildings.textContent = String(state.buildingList.length);
  el.statRevision.textContent = String(state.buildingRevision);
  updateSelectionPanel();

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
  if (b) {
    const hpTxt = `生命 ${Math.ceil(b.hp)} / ${b.hpMax}`;
    el.selName.textContent = `${BUILDINGS[b.type].name}（${b.owner === 'player' ? '己方' : '敌方'}）`;
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
      ? `${z.name}${z.owner === 'player' ? '·己方' : z.progress > 0 ? `·占领 ${Math.round(z.progress * 100)}%` : '·无主'}`
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
  return state.zones.filter((z) => z.owner === 'player').map((z) => z.name).join(', ');
}

function pushLog(msg) {
  state.log.push(msg);
  if (state.log.length > 120) state.log.splice(0, state.log.length - 120);
}

/** 战斗事件（unit.js 通过 state.onCombatEvent 回调进来）→ 事件日志 / 提示 / 建筑收尸 */
function onCombatEvent(evt) {
  if (!evt) return;
  if (evt.type === 'alert') {
    if (evt.unit.faction === 'player') pushLog(`${evt.unit.name} 发现 ${evt.target.name}，进入警戒`);
  } else if (evt.type === 'kill') {
    const by = evt.source ? `（${actorName(evt.source)} 击杀）` : '';
    pushLog(`${evt.unit.name} 阵亡${by}`);
    if (evt.unit.faction === 'player') toast(`${evt.unit.name} 阵亡${by}`);
  } else if (evt.type === 'buildingDown') {
    const b = evt.building;
    const by = evt.source ? `被 ${actorName(evt.source)} 拆毁` : '被拆毁';
    pushLog(`${actorName(b)} (${b.tx}, ${b.ty}) ${by}`);
    if (b.owner === 'player') toast(`${actorName(b)} 被拆毁！`);
    removeBuilding(state, b);
    state.buildingRevision++;
  }
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
  el.btnSpawn.addEventListener('click', () => spawnEnemy());
  el.btnAutoSpawn.addEventListener('click', () => {
    state.debugAutoSpawn = !state.debugAutoSpawn;
    state.enemySpawnTimer = 0;
    el.btnAutoSpawn.classList.toggle('active', state.debugAutoSpawn);
  });
  el.btnClearEnemies.addEventListener('click', () => {
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
      if (state.ui.buildType) { tryBuildAt(t.x, t.y); return; }
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

function orderMove(world, tile) {
  const units = state.ui.selectedUnits.filter((u) => u.alive && u.faction === 'player');
  if (!units.length) return;
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
  let best = null, bestD = Infinity;
  for (const u of state.units) {
    if (!u.alive || u.faction !== 'player') continue;
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
  drawOnce: () => draw(state, canvas, state.camera, buildUiSnapshot()),
  findPathFor: (st, from, to, faction) => findPath(st, from, to, faction),
  // 直线移动：某条直线是否可走 / 折线拉直的结果
  segmentClearFor: (st, a, b, faction) => segmentClear(st, a.x, a.y, b.x, b.y, faction),
  smoothPathFor: (st, pts, faction) => smoothPath(st, pts, faction),
  findBlockingWall,
  removeBuildingFor: (st, b) => removeBuilding(st, b),
  pointerInfo,
  eventToCanvas,
  resize: resizeCanvas,
  // 坐标换算（测试里用来核对“鼠标点 ↔ 地块”是否一致）
  screenToWorld: (sx, sy) => screenToWorld(state.camera, sx, sy),
  worldToTile,
  tileCenter: (tx, ty) => tileCenter(tx, ty, CONFIG.cell),
  fitView: () => fit(state.camera, state),
};
