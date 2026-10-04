## economy.gd —— 资源产出（对应 HTML 版 main.js 里按地块数增长的那两行）
##
## ★★ 口径变过一次（用户需求「新增区划产能」）：
##   旧：每秒产出 = **己方占领地块数** × 全局固定值（config.resource.*_per_tile_per_sec）。
##   新：每秒产出 = **己方拥有的各区划** 的（该区划产量 × 该区划地块数）之和 ——
##       产量来自地图数据（地图编辑器里给每个区划配的「粮食产能 / 黄金产能」，单位
##       n 资源/地块/秒），由 `zone.production_of(owner)` 聚合好再传进来。
##   于是「抢区块 = 抢产能」：占的地方好不好，比占得多不多更重要。
##   `config.resource.food_per_tile_per_sec` 只作为**没有产能数据时的兜底参考**
##   （见 docs/route.md 第十五节）；游戏里真正的产出完全由地图的 zone_list 决定。
##
## 为什么单独一个文件而不是塞进 world.gd：路线图 M4 要求经济有独立位置，
## 第 2 轮要做「按地形/建筑给不同产出」时，改动只落在这里。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")


## 推进一帧。`rates` 是「每秒产出」{"food": float, "gold": float}（由 zone 聚合好）。
## 返回本帧的 {food, gold} 增量（调用方决定怎么记日志）。
static func tick(cfg: ConfigRes, dt: float, rates: Dictionary, resources: Dictionary) -> Dictionary:
	var food := float(rates.get("food", 0.0)) * dt
	var gold := float(rates.get("gold", 0.0)) * dt
	resources["food"] = float(resources.get("food", 0.0)) + food
	resources["gold"] = float(resources.get("gold", 0.0)) + gold
	return {"food": food, "gold": gold}


## 建造消耗校验（economy.enabled = false 时永远通过 —— 本版建造免费）。
## 返回 true = 可以建造（并已扣费）。
static func try_spend(cfg: ConfigRes, resources: Dictionary, cost: Dictionary) -> bool:
	if not cfg.bool_val("economy.enabled", false):
		return true
	return spend(resources, cost)


## 买得起吗（**无条件**判断，不看 economy 总开关）。
##
## ★★ `resources == null` 的语义是「这一方**没有资源库** = 资源无限」，不是「没钱」。
##
## 需求原文（将领性 / 防御性 AI）：「其没有资源库，没有大本营……会无资源消耗地招募单位
## （或者可以认定该类 AI 资源无限）」。
## 所以 null 一律**判得过**（连有消耗的 cost 也过）——
## 这条与 `can_afford_recruit` / `can_afford_zone_recruit` 里那句
## 「`pool != null and not can_afford(...)`」是**同一条语义**，两处必须一致。
##
## ⚠️ 参数类型必须是 `Variant`（不能是 `Dictionary`）：GDScript 对**有类型**的参数
##    会把 null 判成「Cannot convert argument 1 from Nil to Dictionary」直接报错 ——
##    这正是「驻防将领无消耗招兵」第一版撞到的那个错。
## ⚠️ 那为什么还会有人想「无消耗」？因为 `world.start_recruit(free = true)` 会把
##    **cost 清空**（那才是免费的真正落点）。null 池子只是「它没有账」，
##    两者不是同一件事：一个有池子的 AI 仍然要按表付钱。
static func can_afford(resources: Variant, cost: Dictionary) -> bool:
	if cost.is_empty():
		return true
	if resources == null:
		return true
	for k in cost.keys():
		if float((resources as Dictionary).get(k, 0.0)) < float(cost[k]):
			return false
	return true


## 无条件扣费。@return true = 扣成功；false = 买不起（**一分钱都不扣**）。
##
## ★ 为什么招募走这里而不是 try_spend：`economy.enabled` 这个总开关的语义是
##   「建造免费」（本版建筑 cost 全是 0），而招募的 50 粮食 / 50 黄金是**玩法需求**，
##   不该被那个开关静默变成免费。所以 招募 → can_afford + spend（强制），
##   建造 → try_spend（受开关控制）。
## ★★ `resources == null`（这一方没有资源库 = 资源无限）：`can_afford` 判得过，
##   而这里**什么都不扣**（没有账可扣）就返回 true。
##   ⚠️ 它不等于「免费那一档」：免费是调用方把 cost 清空
##      （见 world.start_recruit 的 `free`），而这里只是「它没有账」。
static func spend(resources: Variant, cost: Dictionary) -> bool:
	if not can_afford(resources, cost):
		return false
	if resources == null:
		return true
	for k in cost.keys():
		resources[k] = float(resources.get(k, 0.0)) - float(cost[k])
	return true
