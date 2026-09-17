/**
 * zone.js —— 区块（领地）系统【占位逻辑】
 *
 * 需求原话：“一大片的地块会归属在一个『区块』下，己方单位站在区块内持续一段时间后，
 *            这个区块会转为己方。具体的区块划分后续在地图编辑时给出，现在自由写占位逻辑。”
 *
 * 因此当前实现：
 *   1. 把整张地图横竖均分成 CONFIG.zone.zoneCols × CONFIG.zone.zoneRows 个矩形区块；
 *      后续地图编辑器只需要提供一张 zoneId 网格（每个地块属于哪个区块），
 *      把 buildZones() 换成读网格即可，其余逻辑不用改。
 *   2. 区块状态：owner = null(无主) | 阵营字符串（'player' / 'p1' / 'p2' …）
 *   3. 占领进度 progress 0~1：
 *      - 区块内有某阵营的单位 → 该阵营进度每秒 +1/captureTimeSec
 *      - 没有 → 该阵营进度每秒 -decayPerSec
 *      - 某阵营进度到 1 → owner = 该阵营
 *      - CONFIG.zone.zoneOwnedByBuilding = true 时：区块内只要有某阵营的建筑，也直接算该阵营领地
 *   4. 资源：每秒 = 己方区块的“地块数量” × 每秒产出
 *
 * ★ 多人改造要点（v0.4）：进度改成**每阵营独立**存在 z.progressBy 里。
 *   旧实现只有一个全局 z.progress，联机下 p1 和 p2 同时站在同一区块会互相抵消
 *   （一个加、一个减，谁也占不下来）。现在各记各的，谁先到 1 谁拿走。
 */

import { CONFIG } from './config.js';
import { clamp } from './util.js';
import { DEFAULT_FACTION, isPlayerFaction } from './faction.js';

const ROW_LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

/** 该状态里所有会参与占领的阵营（玩家方 + NPC） */
function captureFactions(state) {
  const list = (state && state.factions && state.factions.factions) || [DEFAULT_FACTION];
  const enemy = (state && state.factions && state.factions.enemyFaction) || 'enemy';
  const out = list.slice();
  if (out.indexOf(enemy) < 0) out.push(enemy);
  return out;
}

export function buildZones(state) {
  const { zoneCols, zoneRows } = CONFIG.zone;
  const cols = CONFIG.mapCols;
  const rows = CONFIG.mapRows;
  const factions = captureFactions(state);
  const zones = [];

  for (let zy = 0; zy < zoneRows; zy++) {
    for (let zx = 0; zx < zoneCols; zx++) {
      const x0 = Math.floor((zx * cols) / zoneCols);
      const x1 = Math.floor(((zx + 1) * cols) / zoneCols) - 1;
      const y0 = Math.floor((zy * rows) / zoneRows);
      const y1 = Math.floor(((zy + 1) * rows) / zoneRows) - 1;
      const progressBy = {};
      for (const f of factions) progressBy[f] = 0;
      zones.push({
        id: zy * zoneCols + zx,
        name: `${ROW_LETTERS[zy]}${zx + 1}`,
        x0, y0, x1, y1,
        owner: null,
        progress: 0,        // 当前 owner（或领先者）的进度，渲染进度条用
        progressBy,         // ★ 每阵营各自的占领进度
        tileCount: (x1 - x0 + 1) * (y1 - y0 + 1),
      });
    }
  }
  return zones;
}

/**
 * 建立区块系统
 * @param {object} [state] 用于取出阵营表；不传则按单机处理（等价于旧行为）
 * @returns {{zones: Array, lookup: number[]}} lookup: 地块索引 -> 区块 id
 */
export function createZoneSystem(state) {
  const zones = buildZones(state);
  const lookup = new Array(CONFIG.mapCols * CONFIG.mapRows).fill(-1);
  for (const z of zones) {
    for (let y = z.y0; y <= z.y1; y++) {
      for (let x = z.x0; x <= z.x1; x++) lookup[y * CONFIG.mapCols + x] = z.id;
    }
  }
  return { zones, lookup };
}

/** 取得某个地块所属区块（越界返回 null） */
export function zoneAt(state, x, y) {
  if (x < 0 || y < 0 || x >= CONFIG.mapCols || y >= CONFIG.mapRows) return null;
  const id = state.zoneLookup[y * CONFIG.mapCols + x];
  return id < 0 ? null : state.zones[id];
}

/** 统计某方拥有的地块数（资源产出依据） */
export function ownedTileCount(state, owner = DEFAULT_FACTION) {
  let n = 0;
  for (const z of state.zones) if (z.owner === owner) n += z.tileCount;
  return n;
}

/** 区块内是否存在某方建筑 */
function zoneHasBuilding(state, zoneId, owner) {
  return state.buildingList.some((b) => b.zoneId === zoneId && b.owner === owner && b.alive);
}

/**
 * 重算建筑带给区块的归属（建筑建成/被毁时调用）。
 * 任意玩家阵营的建筑都能把区块直接收归自己 —— 旧实现只认 'player'。
 */
export function refreshBuildingOwnership(state) {
  if (!CONFIG.zone.zoneOwnedByBuilding) return;
  for (const z of state.zones) {
    for (const f of captureFactions(state)) {
      if (!isPlayerFaction(f)) continue;
      if (z.owner === f) continue;
      if (zoneHasBuilding(state, z.id, f)) {
        z.owner = f;
        if (!z.progressBy) z.progressBy = {};
        z.progressBy[f] = 1;
        z.progress = 1;
        z.claimedBy = 'building';
      }
    }
  }
}

/**
 * 每帧推进区块占领。
 * 注意：同一阵营的多个单位站在同一区块不会叠加加速（原话是“持续一段时间”），
 *       如需叠加，把 touched 改成计数即可。
 */
export function updateZones(state, dt) {
  const { captureTimeSec, decayPerSec } = CONFIG.zone;
  const factions = captureFactions(state);

  // 每个阵营分别统计「本帧有哪些区块被我的单位碰到」
  const touchedBy = {};
  for (const f of factions) touchedBy[f] = new Set();
  for (const u of state.units || []) {
    if (!u.alive) continue;
    const set = touchedBy[u.faction];
    if (!set) continue;
    const z = zoneAt(state, u.tx, u.ty);
    if (z && z.owner !== u.faction) set.add(z.id);
  }

  for (const z of state.zones) {
    if (!z.progressBy) {
      z.progressBy = {};
      for (const f of factions) z.progressBy[f] = 0;
    }
    for (const f of factions) {
      if (z.progressBy[f] === undefined) z.progressBy[f] = 0;
      if (z.owner === f) continue;                       // 已经是我的了，不用再推
      if (touchedBy[f] && touchedBy[f].has(z.id)) {
        z.progressBy[f] = clamp(z.progressBy[f] + dt / captureTimeSec, 0, 1);
      } else if (z.progressBy[f] > 0) {
        z.progressBy[f] = clamp(z.progressBy[f] - decayPerSec * dt, 0, 1);
      }
      if (z.progressBy[f] >= 1) {
        z.owner = f;
        z.claimedBy = 'unit';
        z.progressBy[f] = 1;
      }
    }

    // 渲染用的 progress = 当前领先者的进度（无主时显示最高的那一方）
    let lead = null, best = 0;
    for (const f of factions) {
      const v = z.progressBy[f] || 0;
      if (v > best) { best = v; lead = f; }
    }
    if (z.owner) {
      z.progress = z.progressBy[z.owner] !== undefined ? z.progressBy[z.owner] : 1;
    } else {
      z.progress = best;
      z.progressLead = lead;
    }
  }
}
