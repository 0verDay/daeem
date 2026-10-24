## ai_economy.gd —— 指挥官 AI 的经济判断（纯函数，状态都在控制器上）。
##
## ★ 口径：AI 有**自己的资源池**（`world.ai_faction_resources[faction]`），
##   收入由 `world.tick()` 每帧按占领区划产能加进去（见 world.gd 的 commander 经济段）。
##   这里只回答「有多少可花 / 买不买得起 / 该不该先攒钱」，不自己扣钱。
##
## ★ 所有花费仍然走世界接口（start_recruit / apply_build / start_building_upgrade…），
##   避免出现「AI 自己扣了钱、世界没记账」的坏状态。
extends RefCounted

const EconomyRes = preload("res://logic/economy.gd")


## 这一方的资源池（缺失时返回空池，绝不返回玩家池）。
static func pool(ai) -> Dictionary:
	var v: Variant = ai.world.ai_faction_resources.get(ai.faction, null)
	if typeof(v) == TYPE_DICTIONARY:
		return v
	return {}


static func food(ai) -> float:
	return float(pool(ai).get("food", 0.0))


static func gold(ai) -> float:
	return float(pool(ai).get("gold", 0.0))


## 扣掉 reserve 之后「可以自由花」的那一份。
static func available(ai) -> Dictionary:
	var eco: Dictionary = ai.profile.get("economy", {})
	return {
		"food": maxf(0.0, food(ai) - float(eco.get("reserve_food", 80.0))),
		"gold": maxf(0.0, gold(ai) - float(eco.get("reserve_gold", 80.0))),
	}


## 买得起吗（**不看 reserve**：保命花费也走它）。
static func can_afford(ai, cost: Dictionary) -> bool:
	if cost.is_empty():
		return true
	return EconomyRes.can_afford(pool(ai), cost)


## 在「不花掉 reserve」的前提下买得起吗（招兵 / 建造 / 升级的常规口径）。
static func can_afford_above_reserve(ai, cost: Dictionary) -> bool:
	if cost.is_empty():
		return true
	var avail: Dictionary = available(ai)
	for k in cost.keys():
		if float(avail.get(String(k), 0.0)) < float(cost[k]):
			return false
	return true


## 钱是不是已经明显花不完（浮存控制：超过 max_float 就该优先升级 / 科技 / 特化 / 箭塔）。
static func float_excess(ai) -> bool:
	var eco: Dictionary = ai.profile.get("economy", {})
	return food(ai) > float(eco.get("max_float_food", 600.0)) \
		or gold(ai) > float(eco.get("max_float_gold", 600.0))


## 当前可招兵种里最便宜的一单（food/gold 各取最小值；没有可招 → 空字典）。
## ★ 只用于「预算够不够」的粗判，不决定具体招谁（具体选兵在控制器里按编成权重）。
static func cheapest_cost(ai) -> Dictionary:
	var best: Dictionary = {}
	var best_sum := INF
	for item in ai.world.recruit_list():
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var kind := String((item as Dictionary).get("kind", ""))
		if kind == "" or not ai.world.unit_recruit_unlocked(ai.faction, kind):
			continue
		var c: Dictionary = ai.world.recruit_cost(kind)
		var s := float(c.get("food", 0.0)) + float(c.get("gold", 0.0))
		if s < best_sum:
			best_sum = s
			best = c
	return best


## 每轮生产最多能下几单（粗预算；真正的拦截在 `start_recruit` 里）。
static func production_budget(ai, army_count: int, target_cap: int) -> int:
	if army_count >= target_cap:
		return 0
	var c: Dictionary = cheapest_cost(ai)
	if c.is_empty():
		return 0
	var avail: Dictionary = available(ai)
	var food_cost: float = maxf(1.0, float(c.get("food", 0.0)))
	var gold_cost: float = maxf(1.0, float(c.get("gold", 0.0)))
	var by_food := int(floor(float(avail.get("food", 0.0)) / food_cost))
	var by_gold := int(floor(float(avail.get("gold", 0.0)) / gold_cost))
	return maxi(0, mini(mini(by_food, by_gold), target_cap - army_count))
