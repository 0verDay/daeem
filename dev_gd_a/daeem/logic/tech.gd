## tech.gd —— 科技模块（一次性科技：打出即启用 + 效果聚合）
##
## ★★ 需求原话（2026.11.18 改版）：
##   「科技在被打出后就视为启用且不可再被打出（不可取消科技），
##     当启用的科技为3个时将其余的科技手牌销毁」。
##
## 所以这一层只回答三个问题（**它不认识 Node、不认识 UI、不读输入**）：
##   1. 现在有哪几条科技（表在 `data/config.json` 的 `tech.list`，代码里不写死科技名）；
##   2. 某一方现在启用了哪几条（按阵营分开存 —— 单机只有 p1，但口径不写死）；
##   3. 启用之后**世界变成什么样**（`effects_of()` 把九条的效果聚合成几个数）。
##
## ★★ 2026.11.18：
##   · 科技**只能启用一次**，没有「弃用」；`toggle()` / `activate()` 只做单向写入。
##   · 启用的科技仍留在科技页（由 world.tech_entries 标成不可再拖），不是取消。
##   · 科技**不再持续扣金**（`gold_drain_per_sec()` 恒为 0）。
##
## ★ 为什么要单独一个文件而不是塞进 world.gd：
##   world 已经 1600 多行，而科技这条线是**可独立演进**的（以后会有前置链、研究时间、花费）。
##   与 economy.gd / combat.gd 同一个定位：世界持有它，规则写在它里面。
##
## ★ 为什么状态存的是 **id 数组 + 查表**，而不是「条目字典的引用」：
##   效果是每帧读的（产量 / 人口增长），查一次 id 换条目的成本可以忽略；
##   而存引用会让快照 / 联机那条路没法序列化（条目里有嵌套字典）。
##
## ★ 效果只有三种形状（见 `effects_of()`）：**总体产能百分比 / 血量倍率 / 人口增长倍率**。
##   加新效果形状要同时改这里与 world 的取用处；只加新科技条目则**不用改任何代码**。
##
## ★ 三条边界（与 docs/architecture.md 的铁律一致）：
##   · 不碰场景树、不读输入；
##   · 数值一律来自 config.json（`tech.max_active` 与每条科技的 effect 数值）；
##   · 拒因只给**码**（"unknown" / "tier" / "limit" / "gold_deficit"），中文文案在 view/hud.gd 里翻译。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")
const FactionRes = preload("res://logic/faction.gd")


var cfg: ConfigRes = null

## 阵营 → 已启用的科技 id 数组（顺序 = 启用顺序，方便界面显示「第几个」）。
## ★ 单机只有 `my_faction` 一项；`reset()` 会整表清空（重开一局不该带着上一局的科技）。
## ★★ 2026.10.30：科技点下即生效；这里就是全部权威状态。
## ★★ 预热与断金冷却已删除。金库被扣到 0 时科技**不会自动弃用**，
##    只是金库停在 0；是否能再启用由 world 的「黄金净收入赤字」判定把关。
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


## 这一方占用了几个名额（科技点下即生效 ⇒ 就是已启用数）。
func slot_count(faction: String = "") -> int:
	return active_count(faction)


## 某一方现在还有几个名额
func remaining_slots(faction: String = "") -> int:
	return maxi(0, max_active() - slot_count(faction))


func is_active(id: String, faction: String = "") -> bool:
	return (active_by_faction.get(_key(faction), []) as Array).has(id)


## ★ 能不能启用这一条。@return "" = 可以；否则是拒因码：
##   "unknown"  没有这条科技（表里查不到 —— 界面上不该发生，防手改 / 旧快照）
##   "played"   ★ 已经启用过（科技不可重复打出 / 不可取消）
##   "tier"     ★ 这条科技的「阶」超过当前大本营允许的阶数
##   "limit"    ★ 已经启用满 max_active 条
##
## ★★ 2026.11.18：「黄金净收入赤字」已随科技持续耗金一起删除。
##
## @param max_active_override / max_tier_override
##   大本营等级决定的上限（由 `world.tech_can_activate()` 传进来）。
##   负数 = 不覆盖（直接调用 tech 的旧路径 / 测试保持原行为）。
func can_activate(id: String, faction: String = "",
		max_active_override: int = -1, max_tier_override: int = -1) -> String:
	if not has(id):
		return "unknown"
	if is_active(id, faction):
		return "played"
	if max_tier_override >= 0:
		var tier := cfg.tech_tier(id) if cfg != null else 0
		if tier > max_tier_override:
			return "tier"
	var cap: int = max_active_override if max_active_override >= 0 else max_active()
	if slot_count(faction) >= cap:
		return "limit"
	return ""


## 打出一张科技牌：**只能从未启用 → 启用**。
##
## @return {"ok": bool, "active": bool, "reason": String}
func toggle(id: String, faction: String = "") -> Dictionary:
	if is_active(id, faction):
		return {"ok": false, "active": true, "reason": "played"}
	var reason := can_activate(id, faction)
	if reason != "":
		return {"ok": false, "active": false, "reason": reason}
	var changed := begin(id, faction)
	return {"ok": changed, "active": changed, "reason": ""}


## ★★ 启用一条：**点下即生效**（预热已删除）。
## @return true = 这一次真的改动了状态
func begin(id: String, faction: String = "") -> bool:
	return activate(id, faction)


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


## 内部回滚接口（**不是玩家可用的取消**）：旧快照 / 测试重置时把一条从启用表里拿掉。
## ★ 游戏内不再有「弃用科技」这条路；UI / 命令层不要调它。
## @return true = 这一次真的改动了状态
func deactivate(id: String, faction: String = "") -> bool:
	if not is_active(id, faction):
		return false
	var key := _key(faction)
	var arr: Array = active_by_faction.get(key, [])
	arr.erase(id)
	active_by_faction[key] = arr
	return true


## 直接把状态设成 on / off（与 begin / deactivate 等价；保留给快照回读 / 调试）。
func set_active(id: String, on: bool, faction: String = "") -> bool:
	if on:
		return activate(id, faction)
	return deactivate(id, faction)


## ★★ 2026.11.18：科技**不再持续扣金**。保留函数是为了让 world / AI / HUD 的旧调用点
##   继续拿到 0，不再需要各处判空。
func gold_drain_per_sec(_faction: String = "") -> float:
	return 0.0


# ------------------------------------------------------------------
# 效果聚合
# ------------------------------------------------------------------

## 把某一方**当前启用（已生效）**的所有科技效果聚合成一份「世界要用的数」。
##
## @return {
##   "food_production_mult":    float,   # ★ 总体**粮食**产能加成（0.1 = +10%，多条加法叠加）
##   "gold_production_mult":    float,   # ★ 总体**黄金**产能加成
##   "building_hp_mult":        float,   # 建筑血量**上限倍率**（1.0 = 没加成，1.1 = +10%）
##   "leader_hp_mult":          float,   # 将领血量上限倍率
##   "zone_population_mult":    float,   # 己方区划人口自然增长速度的倍率
## }
##
## ★★ 2026.10.29：产量那两条从「每地块每秒的加值」改成了**总体产能的百分比**。
##   「总体」= 区划基础产能 **+ 特化加成**（world 那边先算完这两项再整体乘倍率），
##   所以它**不再随领土面积线性膨胀** —— 这正是本次经济改版要掐掉的那一项。
## ★ 倍率字段的语义是**从 1.0 起加百分比**（配置里写 0.1 表示 +10%），
##   所以聚合是「1.0 + 各条之和」，不是「相乘」——
##   三条产量科技满配 = +60%，不是 1.1×1.2×1.3。
## ★ 每帧都会调它（产量每帧算一次）—— 聚合本身只是几条加法，
##   但调用方拿到的字典**每次都是新的**，不要当缓存使。
## ★ 只读 `active_by_faction`：启用的那几条就是全部生效项。
func effects_of(faction: String = "") -> Dictionary:
	var eff := default_effects()
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


## ★★ 2026.11：全部效果键的**基数**（聚合 = 「基数 + 各条之和」）。
##
## 两套基数并存，别混：
##   · 老键（2026.10）—— 倍率类基数 **1.0**（`building_hp_mult` / `leader_hp_mult` /
##     `zone_population_mult`），百分比类基数 **0.0**（`food/gold_production_mult`）；
##   · 新键（2026.11，派系科技）—— 一律 **0.0 的「加法增量」**，读取处写成 `1.0 + 增量`。
##     这样「同一条键的多条科技叠加」永远是加法，也不会出现「两条 +10% 变 +21%」。
##
## ⚠️ 新增效果键**必须**同时改这里，否则 `effects_of()` 会把那一行当未知字段静默丢掉。
static func default_effects() -> Dictionary:
	return {
		"food_production_mult": 0.0,
		"gold_production_mult": 0.0,
		"building_hp_mult": 1.0,
		"leader_hp_mult": 1.0,
		"zone_population_mult": 1.0,
		# ---- 2026.11 派系科技（全部是加法增量；读取处一律 `1.0 + 它`）----
		"unit_speed_mult": 0.0,
		"capture_time_mult": 0.0,
		"zone_population_cap_add": 0.0,
		"unit_melee_reduction_add": 0.0,
		"unit_ranged_reduction_add": 0.0,
		"base_gold_per_sec_add": 0.0,
		"building_gold_per_sec_add": 0.0,
		"building_food_per_sec_add": 0.0,
		"per_zone_attack_mult": 0.0,
		"per_zone_armor_mult": 0.0,
		"per_squad_member_attack_mult": 0.0,
		"unit_upkeep_mult": 0.0,
		"upkeep_idle_exempt": 0.0,
		"recruit_tier_unlock": 0.0,
		"recruit_gold_to_food": 0.0,
		"zone_convert_restore": 0.0,
		"charge_damage_mult": 0.0,
		# ---- ★★ 2026.11.18：义勇军 / 教会军那两条线（全部是加法增量；读取处在 logic/world.gd）----
		# 「侵略如火」：敌方区划被己方单位踩住时的压制（pop/prod 增量 + 两条上限）
		"blitz_pop_debuff": 0.0,
		"blitz_prod_debuff": 0.0,
		"blitz_pop_cap": 0.0,
		"blitz_prod_cap": 0.0,
		# 「不动如山 / 血战到底」：血量上限增量（分别只作用于步兵 / 全单位）、步兵额外护甲
		"infantry_hp_mult_add": 0.0,
		"unit_hp_mult_add": 0.0,
		"infantry_armor_add": 0.0,
		# 「游击战术」：攻击速度增量、护甲归零
		"unit_attack_speed_add": 0.0,
		"unit_armor_zero": 0.0,
		# 「血战到底」：致命伤回满 + 暴走的伤害/掉血
		"fatal_refill": 0.0,
		"blood_war_attack_add": 0.0,
		"blood_war_drain": 0.0,
		# 「会水」：给步兵补「水性」状态
		"grant_water_walk": 0.0,
		# 「不自由税 / 自由税」：每个单位每秒给的金（两条互补）
		"gold_per_unit_no_freedom": 0.0,
		"gold_per_unit_freedom": 0.0,
		# 「沐浴自由」：含自由的单位在染疫区划里的攻/防增量
		"freedom_plague_attack_add": 0.0,
		"freedom_plague_armor_add": 0.0,
		# 「信仰不死」：致命伤锁血的点数 / 无敌秒数 / 触发冷却
		"fatal_invincible_sec": 0.0,
		"fatal_hp_lock": 0.0,
		"fatal_invincible_cooldown": 0.0,
		# 「传教」：脱战单位站在敌方区划里 ⇒ 该区划染疫
		"missionary_plague": 0.0,
	}


## 只取某一条科技自己的效果（**没启用也算**）—— 给界面画「这一格是干什么的」用。
## ★ 与 `effects_of()` 的区别：那个是「现在世界上的实际加成」，这个是「这条科技本身」。
func effect_of(id: String) -> Dictionary:
	var e: Variant = entry(id).get("effect", {})
	return e if typeof(e) == TYPE_DICTIONARY else {}
