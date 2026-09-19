## faction.gd —— 阵营模型（对应 HTML 版 js/faction.js）
##
## 为什么要有单独一个模块：原来阵营是散落各处的字符串字面量 'player' / 'enemy'，
## 两个玩家都会是 'player'，于是永远不会互相索敌，「互相看到 + 能打」根本无法达成。
## 这里把阵营语义收敛到一处。
##
## 阵营取值：
##   'p1'      玩家一（房主）；★ **单机也用它** —— 不再有 'player' 这个别名
##   'p2'      玩家二（客机）
##   'p3'…'p8' 预留，最多 8 个玩家席位
##   'enemy'   NPC / 调试用的测试敌人
##
## ★★ 两条对称规则，方向相反，**别搞混**：
##   is_player_faction(f) —— 这个阵营是不是「玩家控制的一方」？决定它是否索敌 / 占区块 / 回血
##   same_side(a, b)      —— 这两者是不是「同一方」？决定是否互相攻击、城墙是否放行
##
## ★ 为什么没有 'player' 了（改过一版）：原来单机用 'player'、联机用 'p1'…'p8'，
##   于是「地图里写的大本营属于谁」要对两套名字 —— 地图编辑器划出来的是 p1/p2，
##   而单机引擎找的是 'player'，两边对不上（症状：地图里明明给 p1 划了大本营，
##   单机跑起来却用默认点位）。现在**只有一套 id**：单机 / 房主就是 p1。
##   ⚠️ 老地图里写的 "player" 因此**不再被识别**（地图导入不看这个标签了）。
##
## 本模块不依赖任何其它 logic 模块 —— 保持它在依赖图最底层。
##
## ⚠️ 跨文件引用规则见 logic/config.gd 顶部：`--script` 模式下全局 class_name 不可用，
##    所以本文件不写 class_name，调用方用 preload 常量。
extends RefCounted

## 默认阵营 = P1：单机（没有联机名单）与联机的房主都用它
const DEFAULT_FACTION := "p1"

## NPC 阵营（测试敌人）
const NPC_FACTION := "enemy"

## 联机时的玩家席位顺序：第一个连上的是房主
const FACTION_ROSTER: Array[String] = ["p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8"]

## 单机模式（没有联机）下使用的阵营表
const SINGLE_PLAYER_ROSTER: Array[String] = [DEFAULT_FACTION]


## 这个阵营是不是玩家控制的一方？
##
## 两种「玩家方」的区分（别搞混）：
##   DEFAULT_FACTION（'p1'）+ FACTION_ROSTER（'p1'..'p8'）→ 是玩家方
##   NPC_FACTION（'enemy'）→ 不是
## 只有玩家方才会自动索敌、占区块、在自家领地回血。
static func is_player_faction(f: String) -> bool:
	return f in FACTION_ROSTER


## 两者是否同一方（用于索敌与城墙通行）
static func same_side(a: String, b: String) -> bool:
	return a == b


## 是不是某条名单里的玩家阵营
static func is_player_side(f: String) -> bool:
	return is_player_faction(f)


## 阵营显示名（事件日志用，如「己方」「敌方」）
static func faction_label(f: String) -> String:
	if f == DEFAULT_FACTION:
		return "己方"
	if f == NPC_FACTION:
		return "敌方"
	if is_player_faction(f):
		return "玩家%s" % f.substr(1)
	return f


## 阵营显示名（对局文案用，不预设「我」是谁，如「P1」「P2」「敌人」）
static func faction_name(f: String) -> String:
	if f == NPC_FACTION:
		return "敌人"
	if f == DEFAULT_FACTION:
		return "P1"
	if is_player_faction(f):
		return f.to_upper()
	return f


## 单机模式（没有联机）下的阵营表
static func make_single_player_roster() -> Array[String]:
	return SINGLE_PLAYER_ROSTER.duplicate()
