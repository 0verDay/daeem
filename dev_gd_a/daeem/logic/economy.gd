## economy.gd —— 资源产出（对应 HTML 版 main.js 里按地块数增长的那两行）
##
## 规则极简：每秒产出 = **己方占领地块数** × 每秒产出（config.resource）。
## 「己方」= 本地玩家阵营，不写死 'player' —— 联机下就是服务器分配给我的那一方。
##
## 为什么单独一个文件而不是塞进 world.gd：路线图 M4 要求经济有独立位置，
## 第 2 轮要做「按地形/建筑给不同产出」时（config.resource 扩展），改动只落在这里。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")


## 推进一帧。返回本帧的 {food, gold} 增量（调用方决定怎么记日志）。
static func tick(cfg: ConfigRes, dt: float, owned_tiles: int, resources: Dictionary) -> Dictionary:
	var food := float(owned_tiles) * cfg.food_per_tile_per_sec * dt
	var gold := float(owned_tiles) * cfg.gold_per_tile_per_sec * dt
	resources["food"] = float(resources.get("food", 0.0)) + food
	resources["gold"] = float(resources.get("gold", 0.0)) + gold
	return {"food": food, "gold": gold}


## 建造消耗校验（economy.enabled = false 时永远通过 —— 本版建造免费）。
## 返回 true = 可以建造（并已扣费）。
static func try_spend(cfg: ConfigRes, resources: Dictionary, cost: Dictionary) -> bool:
	if not cfg.bool_val("economy.enabled", false):
		return true
	if cost.is_empty():
		return true
	for k in cost.keys():
		if float(resources.get(k, 0.0)) < float(cost[k]):
			return false
	for k in cost.keys():
		resources[k] = float(resources.get(k, 0.0)) - float(cost[k])
	return true
