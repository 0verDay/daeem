/**
 * map.js —— 固定手写地图（24 × 16）
 *
 * 图例：
 *   '.' 草地（可通行，正常速度）
 *   '^' 森林（可通行，速度 × forestMult，用于验证地形对移动的影响）
 *   '#' 山地（不可通行）
 *   'B' 大本营（玩家开局自带，占 1 格；不可建造）
 *
 * 说明：地图是给“建筑”设计的，单位与地块不一一对应（多个单位可叠在同一格）。
 *       这里只是原型用的固定地图，后续地图编辑器会替换掉它。
 */

import { Grid } from './util.js';
import { CONFIG } from './config.js';
import { floodFill } from './path.js';
import { idx } from './util.js';

export const MAP_LAYOUT = [
  '........................',
  '........................',
  '........................',
  '....^^.......###########',   // 最后留一格作为北侧隘口
  '....^..........#........',
  '...............#........',
  '...............#........',
  '...............#........',
  '........................',
  '........................',
  '........................',
  '........................',
  '.............^^.........',
  '........................',
  '........................',
  '........................',
];

/** 将领（占位单位）开局站位 */
export const GENERAL_SPAWNS = [
  { x: 8, y: 10 },
  { x: 10, y: 11 },
  { x: 11, y: 9 },
];

export function createMap() {
  const cols = CONFIG.mapCols;
  const rows = CONFIG.mapRows;
  const terrain = new Grid(cols, rows, 'grass');
  let base = null;

  for (let y = 0; y < rows; y++) {
    const row = MAP_LAYOUT[y] || '';
    for (let x = 0; x < cols; x++) {
      const ch = row[x] || '.';
      if (ch === '#') terrain.set(x, y, 'mountain');
      else if (ch === '^') terrain.set(x, y, 'forest');
      else if (ch === 'B') {
        terrain.set(x, y, 'grass');
        base = { x, y };
      } else terrain.set(x, y, 'grass');
    }
  }

  if (!base) base = { x: Math.floor(cols / 2), y: Math.floor(rows / 2) };

  // 连通性修正：把从大本营四连通到达不了的“可通行但被隔离”的格子变成山，
  // 保证寻路永远不会出现“看着能走其实走不到”的情况。
  const reachable = floodFill({ terrain }, base);
  let sealed = 0;
  terrain.forEach((x, y, t) => {
    if (t === 'mountain') return;
    if (!reachable.has(idx(terrain, x, y))) {
      terrain.set(x, y, 'mountain');
      sealed++;
    }
  });

  return { terrain, base, cols, rows, sealedIslands: sealed };
}
