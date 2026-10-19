## side_color.gd —— **局内「敌 / 友 / 己」的统一配色**（本轮新增）。
##
## 需求原文：「所有的敌人在我的视角下都显示红色，所有的友军在我的视角下都显示黄色，
##            所有的己方在我的视角下都显示蓝色」。
##
## ★★ 这一层解决的事：**同一个阵营在不同玩家眼里的颜色可能不同** ——
##   单机时 p1 是「我」（蓝），联机时 p2 看 p1 是「友军」（黄）。
##   所以颜色不能存在 `colors.faction`（那是**阵营身份色**，用于菜单 / 战役选择里
##   「选谁」的卡片），必须由「本机是谁」现算一次关系。判据只有这一处（`relation()`）。
##
## 三档 + 一档中立：
##   · `self`  —— 本机操作的阵营（合作时只有自己那一个）→ `colors.side.self`（蓝）
##   · `ally`  —— 同方的其他阵营（合作队友 / 盟友 AI）       → `colors.side.ally`（黄）
##   · `enemy` —— 其余全部                                   → `colors.side.enemy`（红）
##   · `neutral` —— 无主 / 过渡画面里还没选可玩阵营           → `colors.side.neutral`（灰）
##
## ★ 「同方」走 `FactionRes.same_side_for_attack()`（同阵营 **或** 盟友）——
##   与索敌 / 占领 / 建筑通行是同一份盟友表；战争迷雾的共享视野也是它，
##   所以「谁算友军」不会出现两套口径。
##
## ★ 只给 **view/** 用：`logic/` 不认识颜色（它只回答关系，见 `FactionRes`）。
##
## ⚠️ 跨文件引用只用本文件的 preload 常量（`--script` 下全局 class_name 不可用）。
extends RefCounted

const FactionRes = preload("res://logic/faction.gd")

const SELF := "self"
const ALLY := "ally"
const ENEMY := "enemy"
const NEUTRAL := "neutral"


## `faction` 在**本机视角**下属于哪一档（见文件头）。
##
## @param world 世界（读 `my_faction`；null → 中立）
## @param faction 要判断的阵营 id（"" → 中立）
static func relation(world, faction: String) -> String:
	if faction == "" or world == null:
		return NEUTRAL
	var me := String(world.my_faction)
	if me == "":
		return NEUTRAL
	if faction == me:
		return SELF
	# ★ 合作队友 / 盟友 AI 都落在这里（判据与索敌同一份盟友表）
	if FactionRes.same_side_for_attack(faction, me):
		return ALLY
	return ENEMY


## `faction` 在本机视角下的显示色。
##
## @param field `"main"` / `"bar"` 等（只为兼容旧调用点；三色档里两者同色）
## @return 三色档返回统一色；**中立**返回 `colors.side.neutral`（灰）。
static func color(cfg, world, faction: String, field: String = "main") -> Color:
	if cfg == null:
		return Color.MAGENTA
	match relation(world, faction):
		SELF:
			return cfg.side_color_self
		ALLY:
			return cfg.side_color_ally
		ENEMY:
			return cfg.side_color_enemy
	return cfg.side_color_neutral


## ★★ 过渡画面用：**没有 world**（还没建局），盟友关系直接来自关卡 / 地图数据。
##
## @param viewer 过渡画面里「当前选中的可玩阵营」；空串 = 还没选（返回 NEUTRAL 灰）
## @param allies `level.effective_allies()` 的 `[["A","B"], ...]`
static func relation_with_allies(viewer: String, faction: String, allies: Array) -> String:
	if viewer == "" or faction == "":
		return NEUTRAL
	if faction == viewer:
		return SELF
	if _same_side_in(faction, viewer, allies):
		return ALLY
	return ENEMY


## `relation_with_allies()` 的颜色版本（过渡缩略图用）。
static func color_with_allies(cfg, viewer: String, faction: String, allies: Array,
		field: String = "main") -> Color:
	if cfg == null:
		return Color.MAGENTA
	match relation_with_allies(viewer, faction, allies):
		SELF:
			return cfg.side_color_self
		ALLY:
			return cfg.side_color_ally
		ENEMY:
			return cfg.side_color_enemy
	return cfg.side_color_neutral


## 一对阵营在 `allies`（两两一对）里是不是同方。
## ★ 与 `FactionRes.same_side_for_attack()` 同一份「盟友对」语义；这里不碰全局表。
static func _same_side_in(a: String, b: String, allies: Array) -> bool:
	if a == b:
		return true
	for pair in allies:
		if typeof(pair) != TYPE_ARRAY or (pair as Array).size() < 2:
			continue
		var p: Array = pair
		var p0 := String(p[0])
		var p1 := String(p[1])
		if (p0 == a and p1 == b) or (p0 == b and p1 == a):
			return true
	return false


## 本机视角下这一档是不是「看得见的一方」（己方或友军）。
## ★ 红点菱形用不到它（那只问迷雾），但界面里「是不是我方阵地」这类判断会用到。
static func is_friendly(world, faction: String) -> bool:
	var r := relation(world, faction)
	return r == SELF or r == ALLY
