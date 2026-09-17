/**
 * faction.js —— 阵营模型（多人联机的地基）
 *
 * 为什么需要单独一个模块：原来阵营是散落各处的字符串字面量 'player' / 'enemy'，
 * 两个玩家都会是 'player'，于是永远不会互相索敌（见 unit.js 的索敌判定），
 * 「互相看到 + 能打」这个目标根本无法达成。这里把阵营语义收敛到一处。
 *
 * 阵营取值：
 *   'p1'      玩家一（房主）
 *   'p2'      玩家二（客机）
 *   'p3'…'p8' 预留，最多 8 个玩家席位
 *   'enemy'   NPC / 调试用的测试敌人
 *   'player'  ★ 单机模式的默认阵营，等价于 P1，保留是为了让现有测试与传统单机行为成立
 *
 * 两条对称规则（注意它们方向相反，别搞混）：
 *   isPlayerFaction(f)  —— 这个阵营是不是「玩家控制的一方」？决定它是否索敌 / 占区块 / 回血
 *   sameSide(a, b)      —— 这两者是不是「同一方」？决定是否互相攻击、城墙是否放行
 *
 * 本模块只依赖 config.js，不依赖任何其他模块 —— 保持它在依赖图的最底层。
 */

import { CONFIG } from './config.js';

/** 单机默认阵营：等价于 P1，只是为了向后兼容而保留这个名字 */
export const DEFAULT_FACTION = 'player';

/** 联机时的玩家席位顺序：第一个连上的是房主 */
export const FACTION_ROSTER = ['p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7', 'p8'];

/** NPC 阵营（测试敌人） */
export const NPC_FACTION = 'enemy';

/** 单机模式（没有联机）下使用的阵营表 */
export const SINGLE_PLAYER_ROSTER = [DEFAULT_FACTION];

/** 这个阵营是不是玩家控制的一方？ */
export function isPlayerFaction(f) {
  return f === DEFAULT_FACTION || /^p[1-8]$/.test(f);
}

/** 两者是否同一方（用于索敌与城墙通行） */
export function sameSide(a, b) {
  return a === b;
}

/** 阵营显示名（HUD / 事件日志用） */
export function factionLabel(f) {
  if (f === DEFAULT_FACTION) return '己方';
  if (f === NPC_FACTION) return '敌方';
  if (isPlayerFaction(f)) return `玩家${f.slice(1)}`;
  return String(f);
}

/** 阵营配色（render.js 用它上色；单机下与旧配色逐字一致，保证观感不变） */
export function factionColor(f) {
  return CONFIG.colors.faction[f] || CONFIG.colors.faction[DEFAULT_FACTION];
}

/**
 * 根据「玩家席位表」生成一个状态里的阵营表。
 * 单机模式传 SINGLE_PLAYER_ROSTER（或什么都不传），得到一个等价于旧 'player' 的阵营。
 *
 * @param {string[]} roster 形如 ['p1','p2']
 * @returns {{myFaction:string, factions:string[], enemyFaction:string}}
 */
export function makeFactions(roster) {
  const list = (roster && roster.length) ? roster.slice() : SINGLE_PLAYER_ROSTER.slice();
  return {
    myFaction: list[0],
    factions: list,
    enemyFaction: NPC_FACTION,
  };
}

/**
 * 把一个「本地玩家阵营」映射到最接近的旧语义阵营。
 * 单机下是 no-op（'player' → 'player'）。
 *
 * 用途：让 zone.js / 资源产出 / HUD 在联机下知道「我」是哪一方。
 */
export function localOf(state) {
  return (state && state.factions && state.factions.myFaction) || DEFAULT_FACTION;
}
