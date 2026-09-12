/**
 * building.js —— 建筑：大本营 / 城墙 / 箭塔
 *
 * 核心规则：
 *   - 每个地块最多一个建筑
 *   - 城墙“填充整个地块”：己方单位可穿过，敌方单位不可进入（blocks(faction) 为 true 即阻挡）
 *   - **城墙有血量**（CONFIG.building.wall.hpMax）：被敌人打光就塌，让出一条路；
 *     敌人“先靠近、再拆”的行为见 unit.js 的 updateBuildingCombat / main.js 的 updateEnemies
 *   - 箭塔：每 cooldown 秒对射程内最近的敌人造成单体伤害
 *   - 血量等数值统一来自 CONFIG.building.*，这里不再写死数字
 */

import { CONFIG } from './config.js';
import { dist, tileCenter } from './util.js';
import { unitRadius } from './render.js';

export const BUILDINGS = {
  base: { id: 'base', name: '大本营', blocksEnemy: true, blocksPlayer: true, buildable: false,
          hpMax: CONFIG.building.base.hpMax },
  wall: { id: 'wall', name: '城墙', blocksEnemy: true, blocksPlayer: false, buildable: true,
          hpMax: CONFIG.building.wall.hpMax },
  tower: { id: 'tower', name: '箭塔', blocksEnemy: true, blocksPlayer: true, buildable: true,
           damage: CONFIG.building.tower.damage, range: CONFIG.building.tower.range, cooldown: CONFIG.building.tower.cooldown },
};

export class Building {
  constructor(type, tx, ty, owner = 'player', zoneId = -1) {
    const def = BUILDINGS[type];
    this.type = type;
    this.def = def;
    this.tx = tx;
    this.ty = ty;
    this.owner = owner;
    this.zoneId = zoneId;
    this.hp = def.hpMax ?? 300;
    this.hpMax = this.hp;
    this.alive = true;
    if (type === 'tower') this.cooldownLeft = 0;
    this.lastTarget = null;   // 仅用于渲染攻击线
    this.flash = 0;
  }

  /** 该建筑是否阻挡某个阵营的单位（城墙：挡敌人、不挡己方） */
  blocks(faction) {
    if (faction === 'player') return !!this.def.blocksPlayer;
    return !!this.def.blocksEnemy;
  }

  get center() {
    return tileCenter(this.tx, this.ty, CONFIG.cell);
  }

  /** 血量比例（渲染 / HUD 用） */
  get hpRatio() {
    return this.hpMax > 0 ? Math.max(0, Math.min(1, this.hp / this.hpMax)) : 0;
  }

  /**
   * 受到伤害（单位拆建筑都走这里）：扣血 + 记一次受击闪光。
   * @returns {boolean} 是否还活着（false = 该建筑已被打光，调用方负责 removeBuilding）
   */
  takeDamage(amount, source = null) {
    if (!this.alive) return false;
    this.lastHitBy = source;
    this.flash = 1;
    // 大本营本版不可摧毁：血量最低留 1，避免出现“活着但血量 0”的状态
    const floor = this.type === 'base' ? 1 : 0;
    this.hp = Math.max(floor, this.hp - amount);
    return this.hp > 0;
  }
}

/** 建筑受击闪光的衰减（只有渲染用；每帧调用一次，覆盖所有建筑） */
export function updateBuildingEffects(state, dt) {
  for (const b of state.buildingList) {
    if (b.flash > 0) b.flash = Math.max(0, b.flash - dt * 4);
  }
}

/** 箭塔开火：对射程内最近的敌人造成单体伤害 */
export function updateTowers(state, dt) {
  for (const b of state.buildingList) {
    if (!b.alive || b.type !== 'tower') continue;
    if (b.cooldownLeft > 0) b.cooldownLeft = Math.max(0, b.cooldownLeft - dt);

    const rangePx = b.def.range * CONFIG.cell;
    const pad = unitRadius('enemy');   // 允许打到"半个身子进射程"的敌人
    let target = null;
    let bestD = Infinity;
    for (const u of state.units) {
      if (!u.alive || u.faction === b.owner) continue;
      const d = dist(b.center.x, b.center.y, u.px, u.py);
      if (d <= rangePx + pad && d < bestD) { bestD = d; target = u; }
    }
    b.lastTarget = target;

    if (target && b.cooldownLeft <= 0) {
      target.takeDamage(b.def.damage, b);
      b.cooldownLeft = b.def.cooldown;
      b.flash = 1;
    }
  }
}

/** 拆除建筑（大本营不可拆） */
export function removeBuilding(state, b) {
  if (!b || !b.alive) return false;
  if (b.type === 'base') return false;
  b.alive = false;
  state.buildings.set(b.tx, b.ty, null);
  const i = state.buildingList.indexOf(b);
  if (i >= 0) state.buildingList.splice(i, 1);
  return true;
}
