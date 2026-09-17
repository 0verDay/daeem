/**
 * unit.js —— 单位（3 个将领占位单位 + 调试用测试敌人）
 *
 * 移动：**点到哪走到哪，能走直线就走直线**。
 *   - A* 只负责给出“绕开山 / 城墙该走哪几个格子”的地块路线；
 *   - 随后用 path.js 的 smoothPath() 把这条路线“拉直”：只要两个点之间的直线
 *     全程可通行，就直接走直线，不再沿格心走阶梯（这就是以前“能走直线却走曲线”
 *     的原因：中间路径点全都在格心上）；
 *   - 终点仍然是玩家点击的那个像素位置，不吸附地块中心；
 *   - 点到的格子不可通行（山 / 城墙 / 建筑）时，自动改走到最近的可达格；
 *   - 站在森林里会减速（CONFIG.unit.forestMult）。
 *   单位不要求与地块一一对应 —— 多个单位可以叠在同一格。
 *
 * 战斗 / 警戒（数值见 CONFIG.combat）：
 *   - 每个单位都有攻击伤害、攻击距离、攻击间隔；
 *   - **警戒**：没有攻击目标、且处于静止的单位，会自动搜索警戒半径内的敌方单位，
 *     锁定最近的一个，然后**先移动靠近，进入攻击距离后再开火**；
 *   - 追击有上限（leash）：目标离“发现它的位置”超过 aggroRange × leashFactor 就放弃，
 *     不会一路追到地图另一头；
 *   - **拆建筑**：单位也可以把建筑当目标（setBuildingTarget），同样“先靠近、再攻击”；
 *     城墙会被打光（见 building.js 的 takeDamage），塌了就让出一条路；
 *   - 玩家右键下达的移动命令优先：会中断当前交战（orderMove）；
 *   - CONFIG.combat.enabled = false 可整体关掉，只保留移动。
 */

import { CONFIG } from './config.js';
import { tileCenter, clamp, dist } from './util.js';
import { findPath, passable, nearestReachable, smoothPath } from './path.js';
import { zoneAt } from './zone.js';
import { unitRadius } from './render.js';
import { sameSide, isPlayerFaction, DEFAULT_FACTION } from './faction.js';

/** 战斗事件回调（main.js 把 state.onCombatEvent 挂上，用来写事件日志 / 弹提示） */
function emitCombat(state, evt) {
  if (state && typeof state.onCombatEvent === 'function') state.onCombatEvent(evt);
}

export class Unit {
  constructor({ id, name, tx, ty, faction = DEFAULT_FACTION, kind = 'general', hotkey = null }) {
    this.id = id;
    this.name = name;
    this.kind = kind;             // 'general' | 'enemy'
    this.faction = faction;       // 'p1' | 'p2' | ... | 'enemy' | 'player'（单机默认）
    this.hotkey = hotkey;
    this.tx = tx;
    this.ty = ty;
    const c = tileCenter(tx, ty, CONFIG.cell);
    this.px = c.x;
    this.py = c.y;
    this.hpMax = kind === 'general' ? CONFIG.unit.hpMax : CONFIG.debug.enemyHp;
    this.hp = this.hpMax;
    this.alive = true;
    this.path = null;             // 剩余路径（**像素**坐标点的数组，见 moveTo）
    this.goal = null;             // 最终目标地块（仅用于 UI 显示）
    this.goalPt = null;           // 最终目标像素位置（点到哪就到哪）
    this.moving = false;
    this.selected = false;
    this.facing = 1;
    this.state = null;

    // ---- 战斗 / 警戒 ----
    this.target = null;           // 当前交战的敌方单位
    this.targetBuilding = null;    // 当前正在拆的建筑（敌人拆城墙走这条路）
    this.anchor = null;           // 发现目标时所站的位置，用于“追出去多远”的判定
    this.attackCd = 0;            // 攻击冷却剩余秒数
    this.attackFlash = 0;         // 攻击特效计时（1 → 0，仅渲染使用）
    this.lastTarget = null;       // 最近一次开火的目标单位（渲染攻击线用）
    this.lastBuilding = null;     // 最近一次攻击的建筑（渲染攻击线用）
    this.repathTimer = 0;         // 追击时下一次重新寻路的倒计时

    // ---- 对战：阵亡与复活（见 CONFIG.pvp.respawnSec） ----
    this.respawnTimer = 0;        // > 0 表示已阵亡且正在等待复活；数到 0 就地满血复活
    this.deaths = 0;              // 累计阵亡次数（HUD / 结算用）
  }

  /** 是否正在等待复活 */
  get awaitingRespawn() {
    return !this.alive && this.respawnTimer > 0;
  }

  /** 基础移动速度（格 / 秒）；森林里减半 */
  get speed() {
    const base = this.kind === 'general' ? CONFIG.unit.speed : CONFIG.debug.enemySpeed;
    const onForest = this.state && this.state.terrain.get(this.tx, this.ty) === 'forest';
    return base * (onForest ? CONFIG.unit.forestMult : 1);
  }

  /** 该单位的战斗数值（将领 / 敌人分开配置） */
  get combat() {
    return this.kind === 'enemy' ? CONFIG.combat.enemy : CONFIG.combat.general;
  }

  /** 攻击距离（像素，不含目标体积） */
  get attackRangePx() {
    return this.combat.range * CONFIG.cell;
  }

  /** 警戒半径（像素） */
  get aggroRangePx() {
    return CONFIG.combat.aggroRange * CONFIG.cell;
  }

  /** 追击上限（像素）：目标离“警戒起点”超过这个距离就放弃 */
  get leashPx() {
    return this.aggroRangePx * CONFIG.combat.leashFactor;
  }

  /* ------------------------------------------------------------------ */
  /* 移动                                                                */
  /* ------------------------------------------------------------------ */

  /**
   * 底层移动：把单位送到某个**像素位置**（点到哪走到哪 + 能走直线就走直线）。
   * 不会动交战目标 —— 追击用它；玩家的明确命令走 orderMove()。
   * @param {{x:number,y:number}} worldPt 目标像素坐标（世界坐标）
   * @returns {boolean} 是否成功下达（目标不可达时返回 false）
   */
  moveTo(state, worldPt) {
    this.state = state;
    const cell = CONFIG.cell;
    const from = { x: this.tx, y: this.ty };

    let destPt = worldPt;
    let destTile = {
      x: clamp(Math.floor(worldPt.x / cell), 0, state.terrain.cols - 1),
      y: clamp(Math.floor(worldPt.y / cell), 0, state.terrain.rows - 1),
    };

    // 点到不可通行的格子（山 / 城墙 / 建筑）→ 自动改走到最近的可达格中心
    if (!passable(state, destTile.x, destTile.y, this.faction)) {
      const alt = nearestReachable(state, from, destTile, this.faction, 20)
        || nearestReachable(state, from, destTile, this.faction, 60);
      if (!alt) return false;
      destTile = alt;
      destPt = tileCenter(alt.x, alt.y, cell);
    }

    const tilePath = findPath(state, from, destTile, this.faction);
    if (tilePath === null) return false;

    // 地块路线 → 像素折线：中间点走格心，**最后一点就是点击的精确位置**
    const raw = [{ x: this.px, y: this.py }];
    for (const n of tilePath) {
      const c = tileCenter(n.x, n.y, cell);
      raw.push({ x: c.x, y: c.y });
    }
    if (tilePath.length > 0) raw[raw.length - 1] = { x: destPt.x, y: destPt.y };
    else if (dist(this.px, this.py, destPt.x, destPt.y) > 0.5) raw.push({ x: destPt.x, y: destPt.y });

    // ★ 关键一步：把折线拉直。开阔地带只剩一条直线，遇到山 / 城墙才保留拐点。
    const pts = smoothPath(state, raw, this.faction).slice(1);

    this.path = pts;
    this.goal = { x: destTile.x, y: destTile.y };
    this.goalPt = pts.length ? { x: destPt.x, y: destPt.y } : null;
    this.moving = this.path.length > 0;
    return true;
  }

  /**
   * 玩家 / AI 下达移动命令（点到哪走到哪）。
   * 会清除当前交战目标：明确的移动命令优先于警戒。
   */
  orderMove(state, worldPt) {
    const ok = this.moveTo(state, worldPt);
    if (ok) this.clearTarget();
    return ok;
  }

  /** 就地停下（保留交战目标）：进入攻击距离后站住开火 */
  halt() {
    this.path = null;
    this.goal = null;
    this.goalPt = null;
    this.moving = false;
  }

  /** 完全停止：停下并脱离交战 */
  stop() {
    this.halt();
    this.clearTarget();
  }

  /** 脱离当前交战目标（单位与建筑都清掉） */
  clearTarget() {
    this.target = null;
    this.targetBuilding = null;
    this.anchor = null;
    this.repathTimer = 0;
  }

  /* ------------------------------------------------------------------ */
  /* 战斗 / 警戒                                                         */
  /* ------------------------------------------------------------------ */

  /**
   * 警戒：**静止且没有目标**的单位搜索警戒半径内的敌方单位，锁定最近的一个。
   * 锁定后由 updateCombat() 负责“先靠近、再攻击”。
   * @returns {boolean} 是否发现了目标
   */
  acquireTarget(state) {
    if (!CONFIG.combat.enabled) return false;
    if (this.aggroRangePx <= 0) return false;

    let best = null;
    let bestD = Infinity;
    for (const u of state.units) {
      if (u === this || !u.alive || sameSide(u.faction, this.faction)) continue;
      const d = dist(this.px, this.py, u.px, u.py) - unitRadius(u.kind);
      if (d <= this.aggroRangePx && d < bestD) { bestD = d; best = u; }
    }
    if (!best) return false;

    this.target = best;
    this.anchor = { x: this.px, y: this.py };   // 从这里开始算“追出去多远”
    this.repathTimer = 0;
    emitCombat(state, { type: 'alert', unit: this, target: best });
    return true;
  }

  /**
   * 有目标时每帧的决策：
   *   够得着 → 站住开火；够不着 → 先移动靠近（追击）;
   *   追得太远 → 放弃。
   */
  updateCombat(state) {
    const t = this.target;
    if (!t || !t.alive || t === this) { this.clearTarget(); return; }

    const reach = this.attackRangePx + unitRadius(t.kind);
    const d = dist(this.px, this.py, t.px, t.py);

    if (d <= reach) {                       // 进入攻击距离：站住打
      this.halt();
      if (Math.abs(t.px - this.px) > 0.5) this.facing = t.px > this.px ? 1 : -1;
      if (this.attackCd <= 0) this.attack(t);
      return;
    }

    // 脱离：目标已经跑到“警戒起点”的追击上限之外
    if (this.anchor && dist(this.anchor.x, this.anchor.y, t.px, t.py) > this.leashPx) {
      this.clearTarget();
      return;
    }

    // 先移动靠近。目标一直在动，所以隔 repathSec 重新寻路一次，而不是每帧重算
    if (!this.path || this.path.length === 0 || this.repathTimer <= 0) {
      this.repathTimer = CONFIG.combat.repathSec;
      this.moveTo(state, { x: t.px, y: t.py });
    }
  }

  /** 开火：单体伤害 + 冷却（伤害值见 CONFIG.combat.general / enemy） */
  attack(t) {
    const cfg = this.combat;
    this.attackCd = Math.max(0.05, cfg.cooldownSec);
    this.attackFlash = 1;
    this.lastTarget = t;
    this.lastBuilding = null;
    t.takeDamage(cfg.damage, this);
  }

  /**
   * 锁定一个建筑开始拆它（main.js 的敌人 AI 用它拆挡路的城墙）。
   * 这里只负责“记下来”，靠近与开火交给 updateBuildingCombat()。
   */
  setBuildingTarget(b) {
    if (!b || !b.alive) return false;
    this.targetBuilding = b;
    this.target = null;
    this.anchor = null;
    this.repathTimer = 0;
    return true;
  }

  /**
   * 拆建筑：**先移动靠近，进入攻击距离后再打**（和打单位一样的手感）。
   * 建筑占满整格，所以攻击距离要算上“半个格子”，贴着墙就能打到。
   */
  updateBuildingCombat(state) {
    const b = this.targetBuilding;
    if (!b || !b.alive) { this.targetBuilding = null; return; }

    const c = b.center;
    const reach = this.combat.range * CONFIG.cell + CONFIG.cell * 0.5;
    const d = dist(this.px, this.py, c.x, c.y);

    if (d <= reach) {                       // 够得着：站住拆
      this.halt();
      if (Math.abs(c.x - this.px) > 0.5) this.facing = c.x > this.px ? 1 : -1;
      if (this.attackCd <= 0) this.attackBuilding(state, b);
      return;
    }

    // 够不着：朝建筑走（moveTo 会发现该格不可通行 → 自动改走到贴墙的可达格）
    if (!this.path || this.path.length === 0 || this.repathTimer <= 0) {
      this.repathTimer = CONFIG.combat.repathSec;
      this.moveTo(state, { x: c.x, y: c.y });
    }
  }

  /** 拆建筑的一击：墙体不反击，所以只需要冷却 + 伤害；打光后广播事件让 main.js 收尸 */
  attackBuilding(state, b) {
    this.attackCd = Math.max(0.05, this.combat.cooldownSec);
    this.attackFlash = 1;
    this.lastBuilding = b;
    this.lastTarget = null;
    if (!b.takeDamage(CONFIG.combat.buildingDamage, this)) {
      emitCombat(state, { type: 'buildingDown', building: b, source: this });
    }
  }

  takeDamage(amount, source = null) {
    this.hp = Math.max(0, this.hp - amount);
    if (this.hp <= 0) {
      this.alive = false;
      this.stop();
      this.deaths++;
      /**
       * 对战模式：阵亡后开始倒计时，到点在自家大本营满血复活。
       * 注意**单位不从 state.units 里移除** —— 移除之后就没法复活了。
       * 客机侧看不到这个单位：快照只发 alive 的单位（见 net.js 的 makeSnapshot），
       * 于是它在客机屏幕上消失，复活后又出现。
       *
       * ⚠️ 只有 state.pvpEnabled 时才开复活。单机必须是 v0.3 行为（死了就没了），
       *    否则"杀死测试敌人"这件事在单机下就不再成立。
       */
      const pvpOn = !!(this.state && this.state.pvpEnabled);
      const sec = (pvpOn && CONFIG.pvp) ? (CONFIG.pvp.respawnSec || 0) : 0;
      this.respawnTimer = sec > 0 ? sec : 0;
      emitCombat(this.state, { type: 'kill', unit: this, source });
    }
    return this.alive;
  }

  /**
   * 复活倒计时。到点后满血、回到自家大本营旁边、清空所有交战状态。
   *
   * 位置用「单位序号」决定（general-p2-2 → 第 2 个位置），而不是按死亡次数漂移 ——
   * 这样同一批将领每次复活的站位是固定、可预测的，不会几轮之后跑到奇奇怪怪的地方。
   * 大本营所在的格子被建筑占住（passable 为 false），所以先试一圈相邻格，都不行就退回原地。
   *
   * @returns {boolean} 本帧是否发生了复活
   */
  tickRespawn(state, dt) {
    if (this.alive || this.respawnTimer <= 0) return false;
    this.respawnTimer = Math.max(0, this.respawnTimer - dt);
    if (this.respawnTimer > 0) return false;

    const home = state.homeBaseOf ? state.homeBaseOf(this.faction) : null;
    const cell = CONFIG.cell;

    let tx = this.tx, ty = this.ty;
    if (home) {
      const n = parseInt(String(this.id).split('-').pop(), 10);
      const slot = Number.isFinite(n) ? Math.max(1, n) : 1;
      const RING = [[0, 1], [1, 0], [-1, 0], [0, -1], [1, 1], [-1, -1], [1, -1], [-1, 1]];
      let pick = null;
      for (let k = 0; k < RING.length; k++) {
        const o = RING[(slot - 1 + k) % RING.length];
        if (passable(state, home.x + o[0], home.y + o[1], this.faction)) {
          pick = { x: home.x + o[0], y: home.y + o[1] };
          break;
        }
      }
      if (pick) { tx = pick.x; ty = pick.y; }
    }

    this.alive = true;
    this.hp = this.hpMax;
    this.tx = tx;
    this.ty = ty;
    this.px = (tx + 0.5) * cell;
    this.py = (ty + 0.5) * cell;
    this.path = null;
    this.goal = null;
    this.goalPt = null;
    this.moving = false;
    this.clearTarget();                            // 复活后不再记得上一场交战
    this.attackCd = 0;
    this.state = state;
    this.syncTile(state);
    emitCombat(state, { type: 'respawn', unit: this });
    return true;
  }

  /* ------------------------------------------------------------------ */
  /* 每帧更新                                                            */
  /* ------------------------------------------------------------------ */

  update(state, dt) {
    this.state = state;
    // 阵亡中的单位只跑复活倒计时（对战模式）；复活后本帧就正常参与逻辑
    if (!this.alive) { this.tickRespawn(state, dt); return; }

    if (this.attackCd > 0) this.attackCd = Math.max(0, this.attackCd - dt);
    if (this.attackFlash > 0) this.attackFlash = Math.max(0, this.attackFlash - dt / Math.max(0.01, CONFIG.combat.flashSec));
    if (this.repathTimer > 0) this.repathTimer = Math.max(0, this.repathTimer - dt);

    // 己方单位站在己方领地内缓慢回血（便于观察领地归属是否生效）
    // ★ 联机下「己方领地」= 自己这一方的区块，所以这里用 this.faction 比对，而不是写死 'player'
    if (isPlayerFaction(this.faction)) {
      const z = zoneAt(state, this.tx, this.ty);
      if (z && z.owner === this.faction && this.hp < this.hpMax) this.hp = Math.min(this.hpMax, this.hp + 4 * dt);
    }

    if (!CONFIG.combat.enabled) {
      if (this.target || this.targetBuilding) this.clearTarget();   // 关掉战斗时不保留旧目标
    } else if (this.target) {
      this.updateCombat(state);
    } else {
      // 警戒：只有静止的单位才会索敌；附近有敌方单位就先打单位，没有才继续拆建筑
      if (!this.moving) this.acquireTarget(state);
      if (this.target) this.updateCombat(state);
      else if (this.targetBuilding) this.updateBuildingCombat(state);
    }

    if (this.path && this.path.length > 0) this.stepAlongPath(state, dt);
  }

  /**
   * 平滑移动：路径点是像素坐标（最后一个点就是玩家点击的位置）。
   * 每帧按剩余距离沿折线推进；跨过拐点时把多余距离带到下一段，
   * 这样即使一帧跨过好几个地块，速度也是均匀的、不会抖动或卡顿。
   */
  stepAlongPath(state, dt) {
    let remaining = this.speed * CONFIG.cell * dt;   // 本帧可移动的像素距离
    let guard = 0;

    while (remaining > 1e-9 && this.path && this.path.length > 0 && guard++ < 512) {
      const node = this.path[0];
      const dx = node.x - this.px;
      const dy = node.y - this.py;
      const d = Math.hypot(dx, dy);

      if (d <= 1e-6) {                 // 已经在这一段终点上
        this.path.shift();
        this.syncTile(state);
        continue;
      }
      if (Math.abs(dx) > 0.5) this.facing = dx > 0 ? 1 : -1;

      if (remaining >= d) {
        // 走完这一段还有余量 → 落到拐点，继续走下一段
        this.px = node.x;
        this.py = node.y;
        remaining -= d;
        this.path.shift();
        this.syncTile(state);
      } else {
        // 本帧走不完这一段 → 沿方向推进，单位停在地块之间的连续位置上
        this.px += (dx / d) * remaining;
        this.py += (dy / d) * remaining;
        remaining = 0;
        this.syncTile(state);
      }
    }

    if (!this.path || this.path.length === 0) {
      // 到达玩家点击的位置就停下（不吸附到格心，所以可能停在地块内的任意处）
      this.px = this.goalPt ? this.goalPt.x : this.px;
      this.py = this.goalPt ? this.goalPt.y : this.py;
      this.syncTile(state);
      this.path = null;
      this.moving = false;
      this.goal = null;
      this.goalPt = null;
    }
  }

  /** 把像素位置换算成所在地块（tx/ty 只用于占区块/资源/箭塔/警戒判定） */
  syncTile(state) {
    this.tx = clamp(Math.floor(this.px / CONFIG.cell), 0, state.terrain.cols - 1);
    this.ty = clamp(Math.floor(this.py / CONFIG.cell), 0, state.terrain.rows - 1);
  }
}

/**
 * 建立某一阵营的将领。
 *
 * ★ 签名同时接受字符串与对象两种形式：
 *     createGenerals(state)                    → state.factions.myFaction（单机 = 'player'）
 *     createGenerals(state, 'p2')              → 指定阵营
 * 保留字符串形式是为了让现有测试（tools/smoke-test.mjs 等）原样通过。
 *
 * 站位：所有阵营共用 GENERAL_SPAWNS（开局站在一起）。多人测试阶段这是有意的 ——
 * 双方开局就贴脸，方便立刻验证「互相索敌 → 开打」这条链路。
 * 后续要做正式出生点分离时，把 spawns 参数化即可。
 */
export function createGenerals(state, factionArg) {
  const faction = typeof factionArg === 'string'
    ? factionArg
    : (factionArg && factionArg.myFaction)
      || (state && state.factions && state.factions.myFaction)
      || DEFAULT_FACTION;
  const prefix = faction === DEFAULT_FACTION ? 'general' : `general-${faction}`;
  const names = ['将领 1', '将领 2', '将领 3'];
  return names.map((name, i) => {
    /**
     * 出生点优先取「本阵营自己的」站位（联机下双方各在一角），
     * 没有时退回 state.generalSpawns（单机 = 原版中点附近），再退回大本营。
     * 见 map.js 的 spawnLayoutFor()。
     */
    const own = state.factionSpawns && state.factionSpawns[faction];
    const sp = (own && own[i]) || state.generalSpawns[i] || { x: state.base.x, y: state.base.y };
    const u = new Unit({
      id: `${prefix}-${i + 1}`, name, tx: sp.x, ty: sp.y,
      faction, kind: 'general', hotkey: String(i + 1),
    });
    u.state = state;
    return u;
  });
}

/** 找到一个可站立的空格（靠近大本营），用于调试刷兵 */
export function findOpenTileNear(state, from, faction) {
  for (let r = 0; r < 20; r++) {
    for (let dy = -r; dy <= r; dy++) {
      for (let dx = -r; dx <= r; dx++) {
        if (Math.max(Math.abs(dx), Math.abs(dy)) !== r) continue;
        const x = from.x + dx, y = from.y + dy;
        if (passable(state, x, y, faction)) return { x, y };
      }
    }
  }
  return null;
}
