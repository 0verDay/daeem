## tech.gd —— 科技模块（占位科技：启用 / 弃用 + 效果聚合）
##
## ★★ 需求原话：
##   「当玩家什么都没选中时，原右下角只有一个建筑页签的地方添加一个科技页签，
##     同时该科技页签也会同步到选中大本营时的科技页签中」；
##   「玩家同一时间仅可启用三个占位科技，玩家需要通过点击科技以启用科技，
##     当玩家启用的科技数到 3 时，玩家再启用科技会被阻止并提示，
##     玩家可以点击已启用的科技以弃用科技」。
##
## 所以这一层只回答三个问题（**它不认识 Node、不认识 UI、不读输入**）：
##   1. 现在有哪几条科技（表在 `data/config.json` 的 `tech.list`，代码里不写死科技名）；
##   2. 某一方现在启用了哪几条（按阵营分开存 —— 单机只有 p1，但口径不写死）；
##   3. 启用之后**世界变成什么样**（`effects_of()` 把九条的效果聚合成几个数）。
##
## ★ 为什么要单独一个文件而不是塞进 world.gd：
##   world 已经 1600 多行，而科技这条线是**可独立演进**的（以后会有前置链、研究时间、花费）。
##   与 economy.gd / combat.gd 同一个定位：世界持有它，规则写在它里面。
##
## ★ 为什么状态存的是 **id 数组 + 查表**，而不是「条目字典的引用」：
##   效果是每帧读的（产量 / 人口增长），查一次 id 换条目的成本可以忽略；
##   而存引用会让快照 / 联机那条路没法序列化（条目里有嵌套字典）。
##
## ★ 效果只有三种形状（见 `effects_of()`）：**加产量（按地块）/ 血量倍率 / 人口增长倍率**。
##   加新效果形状要同时改这里与 world 的取用处；只加新科技条目则**不用改任何代码**。
##
## ★ 三条边界（与 docs/architecture.md 的铁律一致）：
##   · 不碰场景树、不读输入；
##   · 数值一律来自 config.json（`tech.max_active` 与每条科技的 effect 数值）；
##   · 拒因只给**码**（"unknown" / "limit"），中文文案在 view/hud.gd 里翻译。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")
const FactionRes = preload("res://logic/faction.gd")


var cfg: ConfigRes = null

## 阵营 → 已启用的科技 id 数组（顺序 = 启用顺序，方便界面显示「第几个」）。
## ★ 单机只有 `my_faction` 一项；`reset()` 会整表清空（重开一局不该带着上一局的科技）。
var active_by_faction: Dictionary = {}


func setup(p_cfg: ConfigRes) -> void:
	cfg = p_cfg


# ------------------------------------------------------------------
# 表
# ------------------------------------------------------------------

## 全部科技条目（顺序 = 命令卡九格的顺序）
func list() -> Array:
	return cfg.tech_list() if cfg != null else []


## 某个科技的条目（查不到返回空字典）
func entry(id: String) -> Dictionary:
	return cfg.tech_entry(id) if cfg != null else {}


func has(id: String) -> bool:
	return cfg != null and cfg.has_tech(id)


## 同一时间最多启用几个
func max_active() -> int:
	return cfg.tech_max() if cfg != null else 3


# ------------------------------------------------------------------
# 启用状态
# ------------------------------------------------------------------

## 清空（重开一局 / 重载地图时调）
func reset() -> void:
	active_by_faction = {}


## ★ 阵营键的归一化：**空串 = 本地玩家那一方**（`Config` 里没有阵营概念，
##   所以这一层要自己知道「谁是本地玩家」—— 用 `FactionRes.DEFAULT_FACTION`，单机就是它）。
##
## 为什么要这一层：`world` 那边一律传 `my_faction`（p1），而调用方可能传 ""（用默认值）。
## 不归一的话 `active_ids("")` 与 `active_ids("p1")` 会看成两方 ——
##   表现就是「明明启用了 3 条，`remaining_slots()` 却还说有 3 个名额」。
func _key(faction: String) -> String:
	return faction if faction != "" else FactionRes.DEFAULT_FACTION


## 某一方现在启用的 id 数组（**返回的是真身**，调用方只读；界面每帧取它画高亮）
func active_ids(faction: String = "") -> Array:
	return active_by_faction.get(_key(faction), [])


func active_count(faction: String = "") -> int:
	return (active_by_faction.get(_key(faction), []) as Array).size()


## 某一方现在还有几个名额
func remaining_slots(faction: String = "") -> int:
	return maxi(0, max_active() - active_count(faction))


func is_active(id: String, faction: String = "") -> bool:
	return (active_by_faction.get(_key(faction), []) as Array).has(id)


## ★ 能不能启用这一条。@return "" = 可以；否则是拒因码：
##   "unknown"  没有这条科技（表里查不到 —— 界面上不该发生，防手改 / 旧快照）
##   "limit"    ★ 已经启用满 max_active 条（需求：到 3 个时再启用会被阻止并提示）
##
## ⚠️ 已经启用的那条**不算占用新名额**（点它是弃用，见 `toggle()`）——
##   所以这里对「已启用」返回 "limit" 是不对的，得先看它是不是已经在用。
func can_activate(id: String, faction: String = "") -> String:
	if not has(id):
		return "unknown"
	if is_active(id, faction):
		return ""
	if active_count(faction) >= max_active():
		return "limit"
	return ""


## 点一下某条科技：**没启用 → 启用；已启用 → 弃用**（需求：点已启用 = 弃用）。
##
## @return {"ok": bool, "active": bool, "reason": String}
##   ok     命令有没有生效
##   active 生效之后这条科技是不是「已启用」（界面用它决定要不要弹提示）
##   reason 没生效时的拒因码（"" = 成功）
##
## ★ 这里是**唯一**改启用状态的地方：命令层（tech_toggle）与以后的研究系统都走它，
##   免得「谁能改状态」有两份实现。
func toggle(id: String, faction: String = "") -> Dictionary:
	if is_active(id, faction):
		deactivate(id, faction)
		return {"ok": true, "active": false, "reason": ""}
	var reason := can_activate(id, faction)
	if reason != "":
		return {"ok": false, "active": false, "reason": reason}
	activate(id, faction)
	return {"ok": true, "active": true, "reason": ""}


## 启用一条（**已经启用时什么都不做**，不会重复入列）
## @return true = 这一次真的改动了状态
func activate(id: String, faction: String = "") -> bool:
	if not has(id) or is_active(id, faction):
		return false
	var key := _key(faction)
	var arr: Array = active_by_faction.get(key, [])
	arr.append(id)
	active_by_faction[key] = arr
	return true


## 弃用一条（**没启用时什么都不做**）
## @return true = 这一次真的改动了状态
func deactivate(id: String, faction: String = "") -> bool:
	if not is_active(id, faction):
		return false
	var key := _key(faction)
	var arr: Array = active_by_faction.get(key, [])
	arr.erase(id)
	active_by_faction[key] = arr
	return true


## 直接把状态设成 on / off（调试句柄与将来的读档用；返回「有没有变化」）
func set_active(id: String, on: bool, faction: String = "") -> bool:
	if on:
		return activate(id, faction)
	return deactivate(id, faction)


# ------------------------------------------------------------------
# 效果聚合
# ------------------------------------------------------------------

## 把某一方**当前启用**的所有科技效果聚合成一份「世界要用的数」。
##
## @return {
##   "food_per_tile_per_sec":   float,   # 每地块每秒的**加**产量（0 = 没有加成）
##   "gold_per_tile_per_sec":   float,
##   "building_hp_mult":        float,   # 建筑血量**上限倍率**（1.0 = 没加成，1.1 = +10%）
##   "leader_hp_mult":          float,   # 将领血量上限倍率
##   "zone_population_mult":    float,   # 己方区划人口自然增长速度的倍率
## }
##
## ★ 倍率字段的语义是**从 1.0 起加百分比**（配置里写 0.1 表示 +10%），
##   所以聚合是「1.0 + 各条之和」，不是「相乘」——
##   以后加第二条 +10% 建筑血量的科技时是 +20%，符合玩家的直觉。
## ★ 加产量字段是**求和**（+1 与 +2 同时启用 = +3/地块/秒）。
## ★ 每帧都会调它（产量每帧算一次）—— 聚合本身只是几条加法，
##   但调用方拿到的字典**每次都是新的**，不要当缓存使。
func effects_of(faction: String = "") -> Dictionary:
	var eff := {
		"food_per_tile_per_sec": 0.0,
		"gold_per_tile_per_sec": 0.0,
		"building_hp_mult": 1.0,
		"leader_hp_mult": 1.0,
		"zone_population_mult": 1.0,
	}
	for id in active_ids(faction):
		var e: Dictionary = entry(String(id)).get("effect", {})
		for k in e.keys():
			var key := String(k)
			if not eff.has(key):
				continue                   # 不认识的字段直接忽略（数据写错不该崩游戏）
			# ⚠️ 加产量与倍率的聚合**都是加法**（倍率的初值是 1.0，见上面的注释）——
			#    写成「倍率相乘」的话，两条 +10% 会变成 +21% 而不是 +20%。
			eff[key] = float(eff[key]) + float(e[k])
	return eff


## 只取某一条科技自己的效果（**没启用也算**）—— 给界面画「这一格是干什么的」用。
## ★ 与 `effects_of()` 的区别：那个是「现在世界上的实际加成」，这个是「这条科技本身」。
func effect_of(id: String) -> Dictionary:
	var e: Variant = entry(id).get("effect", {})
	return e if typeof(e) == TYPE_DICTIONARY else {}
