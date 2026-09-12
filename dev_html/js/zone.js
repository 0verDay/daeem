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
 *   2. 区块状态：owner = null(无主) | 'player' | 'enemy'
 *   3. 占领进度 progress 0~1：
 *      - 区块内有己方单位 → 每秒 +1/captureTimeSec
 *      - 否则 → 每秒 -decayPerSec
 *      - progress 到 1 → owner = 'player'
 *      - CONFIG.zone.zoneOwnedByBuilding = true 时：区块内只要有己方建筑，也直接算己方领地
 *   4. 资源：每秒 = 己方区块的“地块数量” × 每秒产出
 */

import { CONFIG } from './config.js';
import { clamp } from './util.js';

const ROW_LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

export function buildZones() {
  const { zoneCols, zoneRows } = CONFIG.zone;
  const cols = CONFIG.mapCols;
  const rows = CONFIG.mapRows;
  const zones = [];

  for (let zy = 0; zy < zoneRows; zy++) {
    for (let zx = 0; zx < zoneCols; zx++) {
      const x0 = Math.floor((zx * cols) / zoneCols);
      const x1 = Math.floor(((zx + 1) * cols) / zoneCols) - 1;
      const y0 = Math.floor((zy * rows) / zoneRows);
      const y1 = Math.floor(((zy + 1) * rows) / zoneRows) - 1;
      zones.push({
        id: zy * zoneCols + zx,
        name: `${ROW_LETTERS[zy]}${zx + 1}`,
        x0, y0, x1, y1,
        owner: null,
        progress: 0,
        tileCount: (x1 - x0 + 1) * (y1 - y0 + 1),
      });
    }
  }
  return zones;
}

/**
 * 建立区块系统
 * @returns {{zones: Array, lookup: number[]}} lookup: 地块索引 -> 区块 id
 */
export function createZoneSystem() {
  const zones = buildZones();
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
export function ownedTileCount(state, owner = 'player') {
  let n = 0;
  for (const z of state.zones) if (z.owner === owner) n += z.tileCount;
  return n;
}

/** 区块内是否存在某方建筑 */
function zoneHasBuilding(state, zoneId, owner) {
  return state.buildingList.some((b) => b.zoneId === zoneId && b.owner === owner && b.alive);
}

/** 重算建筑带给区块的归属（建筑建成/被毁时调用） */
export function refreshBuildingOwnership(state) {
  if (!CONFIG.zone.zoneOwnedByBuilding) return;
  for (const z of state.zones) {
    if (z.owner === 'player') continue;
    if (zoneHasBuilding(state, z.id, 'player')) {
      z.owner = 'player';
      z.progress = 1;
      z.claimedBy = 'building';
    }
  }
}

/**
 * 每帧推进区块占领（占位规则）
 * 注意：多个单位站在同一区块不会叠加加速（原话是“持续一段时间”），
 *       如需叠加，改 hasFriendly 为计数即可。
 */
export function updateZones(state, dt) {
  const { captureTimeSec, decayPerSec } = CONFIG.zone;

  const friendlyUnits = (state.units || []).filter((u) => u.alive && u.faction === 'player');
  const touched = new Set();
  for (const u of friendlyUnits) {
    const z = zoneAt(state, u.tx, u.ty);
    if (z && z.owner !== 'player') touched.add(z.id);
  }

  for (const z of state.zones) {
    if (z.owner === 'player') continue;
    if (touched.has(z.id)) {
      z.progress = clamp(z.progress + dt / captureTimeSec, 0, 1);
      if (z.progress >= 1) {
        z.owner = 'player';
        z.claimedBy = 'unit';
        z.progress = 1;
      }
    } else if (z.progress > 0) {
      z.progress = clamp(z.progress - decayPerSec * dt, 0, 1);
    }
  }
}
