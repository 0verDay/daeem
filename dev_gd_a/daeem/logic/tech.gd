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
## ★★ 2026.10.29：这张表**只装「已经生效」的**。预热中的在 `warmup_by_faction` 里，
##    所以 `is_active()` 在预热期间返回 false —— 「点下去了」≠「已经生效」。
var active_by_faction: Dictionary = {}

## ★★ 预热：阵营 → { 科技 id: 还剩几秒生效 }。
##   · 点下那一刻就进这里（并且**马上开始扣金**，见 `gold_drain_per_sec()`）；
##   · 预热期间**占名额**（`slot_count()` 把两张表一起算），但**不出效果**
##     （`effects_of()` 只读 `active_by_faction`）；
##   · 中途取消 = 从这张表里删掉，**已扣的金不退、不进冷却**（用户口径）。
var warmup_by_faction: Dictionary = {}

## ★★ 断金冷却：阵营 → 还剩几秒解禁（键存在 = 全科技锁定中）。
##   · 触发点是 `world._tick_upkeep()`：某一帧付不起科技金 ⇒ 调 `fail_all()`；
##   · 冷却期间 `can_activate()` 一律返回 "cooldown"（一格都点不了）；
##   · 冷却结束后要**重新点**，并且**再等一次 30 秒预热**（用户口径：一次断金 = 60 秒没科技）。
var cooldown_by_faction: Dictionary = {}


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
	warmup_by_faction = {}
	cooldown_by_faction = {}


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


## ---- ★★ 2026.10.29：预热 / 冷却（见文件头与 config.json 的 tech._comment）----

## 预热表中的那一份（阵营 → {id: 剩余秒}；没有就返回空字典）
func _warmup_map(faction: String) -> Dictionary:
	var v: Variant = warmup_by_faction.get(_key(faction), {})
	return v if typeof(v) == TYPE_DICTIONARY else {}


## 这条科技现在是不是**正在预热**（点下去了，但还没生效）
func is_warming(id: String, faction: String = "") -> bool:
	return _warmup_map(faction).has(id)


## 还要多久生效（秒；没在预热 → 0）
func warmup_left(id: String, faction: String = "") -> float:
	return maxf(0.0, float(_warmup_map(faction).get(id, 0.0)))


## 现在正在预热的有几条
func warming_count(faction: String = "") -> int:
	return _warmup_map(faction).size()


## 正在预热的那几条 id（给「断金时丢了哪些科技」的事件用）
func warming_ids(faction: String = "") -> Array:
	return _warmup_map(faction).keys()


## ★ 这一方**占用了几个名额** = 已生效 + 预热中。
##   ⚠️ 为什么预热也算名额：不算的话玩家可以先点满五条再让它们同时生效，
##      `max_active` 就形同虚设。
func slot_count(faction: String = "") -> int:
	return active_count(faction) + warming_count(faction)


## 全科技冷却还剩几秒（0 = 没有冷却）
func cooldown_left(faction: String = "") -> float:
	return maxf(0.0, float(cooldown_by_faction.get(_key(faction), 0.0)))


func in_cooldown(faction: String = "") -> bool:
	return cooldown_left(faction) > 0.0


## 某一方现在还有几个名额（预热中的也算占用）
func remaining_slots(faction: String = "") -> int:
	return maxi(0, max_active() - slot_count(faction))


func is_active(id: String, faction: String = "") -> bool:
	return (active_by_faction.get(_key(faction), []) as Array).has(id)


## ★ 能不能启用这一条。@return "" = 可以；否则是拒因码：
##   "unknown"  没有这条科技（表里查不到 —— 界面上不该发生，防手改 / 旧快照）
##   "cooldown" ★★ 全科技冷却中（断金之后那 30 秒，一格都点不了）
##   "warming"  ★★ 这一条已经在预热队列里（再点一下应当是「取消」，不是「再启用」）
##   "tier"     ★ 这条科技的「阶」超过当前大本营允许的阶数
##   "limit"    ★ 已经启用满 max_active 条（需求：到 3 个时再启用会被阻止并提示）
##
## @param max_active_override / max_tier_override
##   大本营等级决定的上限（由 `world.tech_can_activate()` 传进来）。
##   负数 = 不覆盖（直接调用 tech 的旧路径 / 测试保持原行为）。
##
## ⚠️ 已经启用的那条**不算占用新名额**（点它是弃用，见 `toggle()`）——
##   所以这里对「已启用」返回 "limit" 是不对的，得先看它是不是已经在用。
func can_activate(id: String, faction: String = "",
		max_active_override: int = -1, max_tier_override: int = -1) -> String:
	if not has(id):
		return "unknown"
	if is_active(id, faction):
		return ""
	# ★★ 2026.10.29：冷却最优先（断金之后整张表都锁着，连提示都该是「冷却中」）。
	if in_cooldown(faction):
		return "cooldown"
	if is_warming(id, faction):
		return "warming"
	if max_tier_override >= 0:
		var tier := cfg.tech_tier(id) if cfg != null else 0
		if tier > max_tier_override:
			return "tier"
	var cap: int = max_active_override if max_active_override >= 0 else max_active()
	if slot_count(faction) >= cap:
		return "limit"
	return ""


## 点一下某条科技：**没启用 → 开始预热；已启用 / 预热中 → 弃用**。
##
## @return {"ok": bool, "active": bool, "reason": String}
##   ok     命令有没有生效
##   active 生效之后这条科技是不是「已启用」（界面用它决定要不要弹提示）
##   reason 没生效时的拒因码（"" = 成功）
##
## ★★ 2026.10.29 起「点一下」的语义变成**开始预热**（`begin()`），不是立刻生效。
##   这里只是给「不关心预热」的旧调用留的一条捷径：真正按下按钮那条路走
##   `world.set_tech_active()` → `tech.begin()`。
func toggle(id: String, faction: String = "") -> Dictionary:
	if is_active(id, faction) or is_warming(id, faction):
		deactivate(id, faction)
		return {"ok": true, "active": false, "reason": ""}
	var reason := can_activate(id, faction)
	if reason != "":
		return {"ok": false, "active": false, "reason": reason}
	begin(id, faction)
	return {"ok": true, "active": false, "reason": ""}


## ★★ 按下「启用」：进预热队列（`warmup_sec` 秒后才真正生效）。
## @return true = 这一次真的改动了状态
## ⚠️ 与 `activate()` 的分工：`activate()` 是**立刻生效**的底层原语（快照回读 / 调试用），
##   玩家点格子走这里。别在别的地方绕过预热直接调 `activate()`。
func begin(id: String, faction: String = "") -> bool:
	if not has(id) or is_active(id, faction) or is_warming(id, faction):
		return false
	var seconds: float = cfg.tech_warmup_sec if cfg != null else 0.0
	if seconds <= 0.0:
		return activate(id, faction)          # 配置成 0 = 回到「点了就生效」
	var key := _key(faction)
	if not warmup_by_faction.has(key):
		warmup_by_faction[key] = {}
	(warmup_by_faction[key] as Dictionary)[id] = seconds
	return true


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


## 弃用一条（**没启用 / 没在预热时什么都不做**）
## @return true = 这一次真的改动了状态
## ★ 预热中取消也走这里：从预热表里删掉即可，**不进冷却、已扣的金不退**。
func deactivate(id: String, faction: String = "") -> bool:
	var key := _key(faction)
	var changed := false
	if is_active(id, faction):
		var arr: Array = active_by_faction.get(key, [])
		arr.erase(id)
		active_by_faction[key] = arr
		changed = true
	var warm: Dictionary = _warmup_map(faction)
	if warm.has(id):
		warm.erase(id)
		if warm.is_empty():
			warmup_by_faction.erase(key)
		else:
			warmup_by_faction[key] = warm
		changed = true
	return changed


## 直接把状态设成 on / off（**立刻生效 / 立刻失效，不过预热**）。
## ★ 只给「快照回读 / 调试句柄 / 测试」用：玩家点格子走 `begin()`。
## ⚠️ on=true 时如果它正在预热，会顺手把预热那一份清掉（避免同一格出现两条路）。
func set_active(id: String, on: bool, faction: String = "") -> bool:
	if on:
		var key := _key(faction)
		var warm: Dictionary = _warmup_map(faction)
		if warm.has(id):
			warm.erase(id)
			if warm.is_empty():
				warmup_by_faction.erase(key)
			else:
				warmup_by_faction[key] = warm
		return activate(id, faction)
	return deactivate(id, faction)


## ★★ 断金：**把这一方所有科技（含预热中的）全部弃用，并进入全科技冷却**。
## @return true = 之前至少有一条科技（所以这一次是真的"掉了东西"）
## 由 `world._tick_upkeep()` 在「这一帧付不起科技金」时调用。
func fail_all(faction: String = "") -> bool:
	var key := _key(faction)
	var had: bool = not (active_by_faction.get(key, []) as Array).is_empty() \
		or not _warmup_map(faction).is_empty()
	active_by_faction.erase(key)
	warmup_by_faction.erase(key)
	var cd: float = cfg.tech_shortfall_cooldown_sec if cfg != null else 0.0
	if cd > 0.0:
		cooldown_by_faction[key] = cd
	return had


## ★★ 推进预热与冷却（`world.tick` 每帧调一次，且在重算科技效果**之前**）。
## @return 本帧刚"读完预热、真正生效"的条目，每项 {"faction": String, "id": String}
##   —— 调用方据此发事件 / 刷一次血量倍率（`_apply_tech_effects`）。
func tick(dt: float) -> Array:
	var finished: Array = []
	if dt <= 0.0:
		return finished
	# ── 预热倒计时 ──
	for key in warmup_by_faction.keys():
		var m: Variant = warmup_by_faction[key]
		if typeof(m) != TYPE_DICTIONARY:
			warmup_by_faction.erase(key)
			continue
		var mm: Dictionary = m
		for id in mm.keys():
			var left: float = float(mm[id]) - dt
			if left <= 0.0:
				finished.append({"faction": String(key), "id": String(id)})
				mm.erase(id)
			else:
				mm[id] = left
		if mm.is_empty():
			warmup_by_faction.erase(key)
	# ── 读完预热的搬进「已生效」──
	for it in finished:
		var key2 := String(it.get("faction", ""))
		var id2 := String(it.get("id", ""))
		var arr: Array = active_by_faction.get(key2, [])
		if not arr.has(id2):
			arr.append(id2)
		active_by_faction[key2] = arr
	# ── 冷却倒计时 ──
	for key3 in cooldown_by_faction.keys():
		var left3: float = float(cooldown_by_faction[key3]) - dt
		if left3 <= 0.0:
			cooldown_by_faction.erase(key3)
		else:
			cooldown_by_faction[key3] = left3
	return finished


## ★★ 这一方**每秒要付多少科技金** = 已生效 + 预热中（预热也从点下那刻开始付）。
## 由 `world._tick_upkeep()` 每帧读一次，再乘 dt。
func gold_drain_per_sec(faction: String = "") -> float:
	if cfg == null:
		return 0.0
	var total := 0.0
	for id in active_ids(faction):
		total += cfg.tech_gold_per_sec_of(String(id))
	for id2 in _warmup_map(faction).keys():
		total += cfg.tech_gold_per_sec_of(String(id2))
	return total


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
## ★ 只读 `active_by_faction`：**预热中的不算**（点下去了但还没生效）。
func effects_of(faction: String = "") -> Dictionary:
	var eff := {
		"food_production_mult": 0.0,
		"gold_production_mult": 0.0,
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
