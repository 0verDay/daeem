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
static func can_afford(resources: Dictionary, cost: Dictionary) -> bool:
	if cost.is_empty():
		return true
	for k in cost.keys():
		if float(resources.get(k, 0.0)) < float(cost[k]):
			return false
	return true


## 无条件扣费。@return true = 扣成功；false = 买不起（**一分钱都不扣**）。
##
## ★ 为什么招募走这里而不是 try_spend：`economy.enabled` 这个总开关的语义是
##   「建造免费」（本版建筑 cost 全是 0），而招募的 50 粮食 / 50 黄金是**玩法需求**，
##   不该被那个开关静默变成免费。所以 招募 → can_afford + spend（强制），
##   建造 → try_spend（受开关控制）。
static func spend(resources: Dictionary, cost: Dictionary) -> bool:
	if not can_afford(resources, cost):
		return false
	for k in cost.keys():
		resources[k] = float(resources.get(k, 0.0)) - float(cost[k])
	return true
