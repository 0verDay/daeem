## upgrade.gd —— 建筑升级 + 区划特化（右下「操作」页签里那几格）
##
## ★★ 需求原话：
##   「为所有单位/建筑都添加上『操作』页签，大本营的操作页签中有一个升级大本营选项，
##     点击后开始读条（和招募单位时的读条一样，可以复用招募单位的面板），
##     箭塔和城墙也有一个升级选项，区划中心有三个特化选项，分别是粮食特化，黄金特化，
##     人口特化，这三个特化玩家只能选一个升级，效果分别为本区块粮食产量 +10%、
##     本区块黄金产量 +10%、本区块人口产量 +10%，特化后的区块无法再次特化，
##     但选中特化后的区块可以在操作面板中选择『取消特化』去除其特化，同理，
##     特化也需要读条，取消特化也需要读条」。
##
## 这一层是**规则**（与 logic/tech.gd 同一个定位：world 持有状态，规则写在这里）：
##   · 升级能不能开（等级上限 / 读条占用 / 归属 / 钱够不够）→ `can_upgrade()`
##   · 特化能不能开（已经特化过 / 读条占用 / 归属 / 钱够不够）→ `can_specialize()`
##   · 取消（读条中取消升级 / 取消特化）→ `can_cancel_upgrade()` / `can_cancel_spec()`
##   · 每帧推进两条读条 → `tick()`
##
## ★★ 时间与账目字段挂在**被升级的那个东西自己身上**：
##   建筑升级 → `building.upgrade_*`；区划特化 → `zone["spec_*"]`。
##   理由与「招募队列挂在将领 / 区划上」完全一样：这是「这个东西正在干嘛」，
##   另开一张「id → 进度」的表就多出一份要对齐、要清理、要进快照的状态。
##
## ★ 读条语义（与招募逐条对齐）：
##   · **入队即扣**粮食 / 黄金（不看 economy.enabled 那个只管建造免费的开关）；
##   · 取消 → **全额退款**（按记账值退，不看「当前还剩几秒」）；
##   · 读条期间**不再接新的升级 / 特化**（拒因 `busy`），但**可以取消**；
##   · 同一时间只跑一条：**不做队列**（需求里升级只有一个选项，没有排队那回事）。
##
## ★ 读条期间建筑照常被打、照常有功能（它没有「动不了」这回事）——
##   与「将领招募期间钉在原地」刻意不同：那是将领自己的行动被占用了，
##   而建筑本来就不可移动，升级读条只锁「再升级」这一个入口。
##
## ★ 效果：
##   · 升级 = 等级 +1，血量上限 = `config.building.<type>.hp_max × hp_mult(等级)`
##     （tech 的「建筑血量 +10%」再乘在它上面，两者叠加）；
##   · 特化 = 该区划自己的 food / gold / population 产能 ×1.1（**只影响那一个区块**），
##     与科技的全局加成**叠加**（特化是乘在区划产能上，科技是每地块的加产量）。
##
## ⚠️ 三条边界（架构铁律）：不碰场景树、不读输入、数值全来自 config.json；
##    拒因只给**码**（"busy" / "max_level" / "cost" / "owner" / "spec_done" / …），
##    中文文案在 view/hud.gd 里翻译。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")
const FactionRes = preload("res://logic/faction.gd")
const EconomyRes = preload("res://logic/economy.gd")
## ⚠️ 这里**不要** preload zone.gd / building.gd / world.gd：
##    这一层只做静态查询与判定，`world` / `b` / `zone` 都是**参数传进来**的。
##    zone.gd 反过来 preload 了本文件（它要 `zone_spec_mult()` 算产能倍率），
##    形成环会让 `--script` 模式下的载入顺序变得不可预测。


# ------------------------------------------------------------------
# 判定（都给「拒因码」，不给文案）
# ------------------------------------------------------------------

## 这个建筑**现在**能不能开始升级。@return "" = 可以；否则是拒因码：
##   "type"       这一类型没有升级表（区划中心 / 未知类型）
##   "max_level"  已经到最高级（等级表的条数）
##   "busy"       ★ 已经在读条了（需求确认：读条期间拒绝新的升级请求）
##   "owner"      不是自己这一方的建筑
##   "cost"       粮食 / 黄金不够
static func can_upgrade(world, b, faction: String) -> String:
	if b == null or not b.alive:
		return "type"
	if not world.cfg.has_upgrade(b.type):
		return "type"
	if not FactionRes.same_side(b.owner, faction):
		return "owner"
	if b.is_upgrading():
		return "busy"
	if b.level >= world.cfg.upgrade_max_level(b.type):
		return "max_level"
	if not EconomyRes.can_afford(world.resources, world.cfg.upgrade_cost_to(b.type, b.level)):
		return "cost"
	return ""


## 这个区划**现在**能不能做某个特化。@return "" = 可以；否则是拒因码：
##   "spec"      没有这种特化（表里查不到）
##   "zone"      没有这个区划 / 这个区划不是自己这一方的（无主也算）
##   "busy"      ★ 已经在读条了（正在特化，或正在取消特化）
##   "spec_done" ★ 已经特化过了（需求：只能选一个、特化后不能再次特化）
##   "cost"      粮食 / 黄金不够
##
## ⚠️ **顺序有讲究**：先判「读条中」，再判「已经特化过」。
##   反过来的话，正在特化的那 10 秒里点别的特化会拿到 `spec_done`
##   （"这个区划已经特化过了：先取消特化"）—— 而那时根本还没特化成功，
##   提示与实际状态驴唇不对马嘴（实测撞到过）。两条的界面文案完全不同。
static func can_specialize(world, zone, spec_id: String, faction: String) -> String:
	if not world.cfg.has_spec(spec_id):
		return "spec"
	var reason := _zone_reject(zone, faction)
	if reason != "":
		return reason
	if zone_is_busy(zone):
		return "busy"
	if String(zone.get("spec_done", "")) != "":
		return "spec_done"
	if not EconomyRes.can_afford(world.resources, world.cfg.spec_cost(spec_id)):
		return "cost"
	return ""


## 能不能取消**读条中的**那次升级。@return "" / "owner" / "idle"
##   "idle" = 现在没有在读条（界面上那一格根本不该出现）
static func can_cancel_upgrade(b, faction: String) -> String:
	if b == null or not b.alive:
		return "idle"
	if not FactionRes.same_side(b.owner, faction):
		return "owner"
	if not b.is_upgrading():
		return "idle"
	return ""


## 能不能取消特化。@return "" / "zone" / "busy" / "idle"
##
## ★★ 两种「取消」分开写（**这是本模块最容易混的一处**）：
##   · 特化**已经完成** → 这时点「取消特化」就是**发起一条「取消特化」读条**，
##     读完把特化去掉，并把当初特化扣掉的资源退回来（就是本函数判定的入口）；
##   · 读条中再点「取消特化」→ **拒**（拒因 `busy`）：那一单已经在跑了，
##     要撤掉它得走 `cancel_spec_bar()`；需求里没有「取消取消」这一说。
##
## ⚠️ 判据是 `spec_done`（**已经生效的那个特化**）而**不是** `spec_kind`
##   （`spec_kind` 只在读条期间非空）—— 第一版写成了后者，于是「特化做完了却永远
##   取消不掉」（实测：can_cancel_spec 恒返回 idle，界面那一格点了没反应）。
static func can_cancel_spec(zone, faction: String) -> String:
	var reason := _zone_reject(zone, faction)
	if reason != "":
		return reason
	if zone_is_busy(zone):
		return "busy"
	if String(zone.get("spec_done", "")) == "":
		return "idle"                      # 没特化过 → 没什么可取消
	return ""


## 取消**读条中的那条特化**（等于把这一单撤掉 + 退款）。
## ★ 两种情况下拒：
##   · 现在没有特化读条（`idle`）；
##   · 正在读的那条**本身就是「取消特化」**（也是 `idle`）—— 需求只说了
##     「取消特化要读条」，没有「取消取消」这一说；界面上那种状态下也只画这一格。
static func can_cancel_spec_bar(zone, faction: String) -> String:
	var reason := _zone_reject(zone, faction)
	if reason != "":
		return reason
	if not zone_is_busy(zone):
		return "idle"
	if zone_spec_is_cancel(zone):
		return "idle"
	return ""


## 区划归属这条判据（两处取消 + 特化共用）
static func _zone_reject(zone, faction: String) -> String:
	if typeof(zone) != TYPE_DICTIONARY:
		return "zone"
	if not FactionRes.same_side(String((zone as Dictionary).get("owner", "")), faction):
		return "zone"
	return ""


## 这个区划现在有没有一条特化读条在跑（特化 / 取消特化都算）
static func zone_is_busy(zone) -> bool:
	if typeof(zone) != TYPE_DICTIONARY:
		return false
	return String((zone as Dictionary).get("spec_kind", "")) != ""


## 这个区划的特化进度（0~1；没在读条 → 0）—— 视图只读它，不自己算（pitfalls 5.20）
##
## @param zone 区划字典（`logic/zone.gd` 的 spec_* 字段）
## @param cfg  配置（读条总时长按**这一单**的种类现查：特化查它自己那档、
##             取消特化查「当初特化那一档」——`spec_kind` 是 `__cancel__` 时读 `spec_done`）
static func zone_spec_progress(zone, cfg: ConfigRes) -> float:
	if typeof(zone) != TYPE_DICTIONARY or cfg == null:
		return 0.0
	var d: Dictionary = zone
	if String(d.get("spec_kind", "")) == "":
		return 0.0
	var total := _spec_bar_total(d, cfg)
	if total <= 0.0:
		return 0.0
	return clampf(1.0 - float(d.get("spec_remaining", 0.0)) / total, 0.0, 1.0)


## 这条读条还要多久（秒）
static func zone_spec_eta(zone, cfg: ConfigRes) -> float:
	if typeof(zone) != TYPE_DICTIONARY or cfg == null:
		return 0.0
	return maxf(0.0, float((zone as Dictionary).get("spec_remaining", 0.0)))


## 这一条读条的总时长：特化看它自己的档，「取消特化」看**当初特化那一档**
static func _spec_bar_total(zone: Dictionary, cfg: ConfigRes) -> float:
	if bool(zone.get("spec_cancel", false)):
		return cfg.spec_time_sec(String(zone.get("spec_done", "")))
	return cfg.spec_time_sec(String(zone.get("spec_kind", "")))


## 这个区划现在那条读条是在**做特化**还是在**取消特化**
static func zone_spec_is_cancel(zone) -> bool:
	if typeof(zone) != TYPE_DICTIONARY:
		return false
	return bool((zone as Dictionary).get("spec_cancel", false))


## 这个区划的产能倍率表：`{"food": 1.0/1.1, "gold": ..., "population": ...}`
## （没特化 / 正在读条中 → 全是 1.0；**只有读完那一下才生效**）
static func zone_spec_mult(zone, cfg: ConfigRes) -> Dictionary:
	var out := {"food": 1.0, "gold": 1.0, "population": 1.0}
	if typeof(zone) != TYPE_DICTIONARY:
		return out
	var done := String((zone as Dictionary).get("spec_done", ""))
	if done == "":
		return out
	var e: Variant = cfg.spec_entry(done).get("effect", {})
	if typeof(e) != TYPE_DICTIONARY:
		return out
	for k in (e as Dictionary).keys():
		var key := String(k)
		if out.has(key):
			out[key] = 1.0 + float((e as Dictionary)[k])
	return out


# ------------------------------------------------------------------
# 开始 / 取消
# ------------------------------------------------------------------

## 开始升级（`building_upgrade` 命令的唯一落点）。
## ★ 顺序与招募一致：**先校验 → 再扣费 → 最后开始读条** ——
##   反了会出现「钱扣了、没读条」这种查不出来的坏状态。
static func start_upgrade(world, b, faction: String) -> bool:
	var reason := can_upgrade(world, b, faction)
	if reason != "":
		world.push_event({"type": "upgrade_rejected", "reason": reason,
			"kind": "building_upgrade", "building": b})
		return false
	var cost: Dictionary = world.cfg.upgrade_cost_to(b.type, b.level)
	if not EconomyRes.spend(world.resources, cost):
		world.push_event({"type": "upgrade_rejected", "reason": "cost",
			"kind": "building_upgrade", "building": b})
		return false
	b.upgrade_remaining = world.cfg.upgrade_time_to(b.type, b.level)
	b.upgrade_total = b.upgrade_remaining
	# 记账：取消（或建筑没了）时按这三个数退款
	b.upgrade_cost_food = float(cost.get("food", 0.0))
	b.upgrade_cost_gold = float(cost.get("gold", 0.0))
	world.push_event({"type": "upgrade_started", "kind": "building_upgrade", "building": b})
	return true


## 取消**读条中的**升级（全额退款）。@return true = 真的取消了
static func cancel_upgrade(world, b, faction: String) -> bool:
	var reason := can_cancel_upgrade(b, faction)
	if reason != "":
		world.push_event({"type": "upgrade_cancel_rejected", "reason": reason,
			"kind": "building_upgrade"})
		return false
	var food: float = b.upgrade_cost_food
	var gold: float = b.upgrade_cost_gold
	b.upgrade_remaining = 0.0
	b.upgrade_total = 0.0
	b.upgrade_cost_food = 0.0
	b.upgrade_cost_gold = 0.0
	_refund_resources(world, food, gold)
	world.push_event({"type": "upgrade_cancelled", "kind": "building_upgrade", "building": b,
		"refund_food": food, "refund_gold": gold})
	return true


## 开始特化（`zone_specialize` 命令的唯一落点）。
static func start_specialize(world, zone, spec_id: String, faction: String) -> bool:
	var reason := can_specialize(world, zone, spec_id, faction)
	if reason != "":
		world.push_event({"type": "upgrade_rejected", "reason": reason,
			"kind": "zone_specialize", "spec": spec_id, "zone_id": _zone_id(zone)})
		return false
	var cost: Dictionary = world.cfg.spec_cost(spec_id)
	if not EconomyRes.spend(world.resources, cost):
		world.push_event({"type": "upgrade_rejected", "reason": "cost",
			"kind": "zone_specialize", "spec": spec_id, "zone_id": _zone_id(zone)})
		return false
	zone["spec_kind"] = spec_id                 # ★ 读条中：这一格就是「在读什么」
	zone["spec_cancel"] = false
	zone["spec_total"] = world.cfg.spec_time_sec(spec_id)
	zone["spec_remaining"] = zone["spec_total"]
	zone["spec_cost_food"] = float(cost.get("food", 0.0))
	zone["spec_cost_gold"] = float(cost.get("gold", 0.0))
	world.push_event({"type": "upgrade_started", "kind": "zone_specialize",
		"spec": spec_id, "zone_id": _zone_id(zone)})
	return true


## 发起一条「取消特化」读条（需求：取消特化也需要读条）。
##
## ★ 它读完要退的是**当初特化扣掉的**资源，所以那两个数必须活到读完 ——
##   它们记在 `spec_cost_food / spec_cost_gold` 上，特化完成时**不清零**。
static func cancel_spec(world, zone, faction: String) -> bool:
	var reason := can_cancel_spec(zone, faction)
	if reason != "":
		world.push_event({"type": "upgrade_rejected", "reason": reason,
			"kind": "zone_spec_cancel", "zone_id": _zone_id(zone)})
		return false
	var done := String(zone.get("spec_done", ""))
	zone["spec_kind"] = "__cancel__"            # 读条占位：这一格现在忙着「取消特化」
	zone["spec_cancel"] = true
	zone["spec_total"] = world.cfg.spec_time_sec(done)
	zone["spec_remaining"] = zone["spec_total"]
	world.push_event({"type": "upgrade_started", "kind": "zone_spec_cancel",
		"spec": done, "zone_id": _zone_id(zone)})
	return true


## 撤掉**读条中的那条特化**（= 放弃这一单 + 退款）。
static func cancel_spec_bar(world, zone, faction: String) -> bool:
	var reason := can_cancel_spec_bar(zone, faction)
	if reason != "":
		world.push_event({"type": "upgrade_cancel_rejected", "reason": reason,
			"kind": "zone_specialize"})
		return false
	var food := float(zone.get("spec_cost_food", 0.0))
	var gold := float(zone.get("spec_cost_gold", 0.0))
	# 只有「正在做特化」的那条读条要退钱；「取消特化」那条本来就没再扣钱
	if not bool(zone.get("spec_cancel", false)):
		_refund_resources(world, food, gold)
		_clear_spec_bar(zone)
		zone["spec_cost_food"] = 0.0
		zone["spec_cost_gold"] = 0.0
	else:
		_clear_spec_bar(zone)
	world.push_event({"type": "upgrade_cancelled", "kind": "zone_specialize",
		"zone_id": _zone_id(zone), "refund_food": food, "refund_gold": gold})
	return true


static func _clear_spec_bar(zone) -> void:
	zone["spec_kind"] = ""
	zone["spec_cancel"] = false
	zone["spec_remaining"] = 0.0
	zone["spec_total"] = 0.0


static func _zone_id(zone) -> int:
	if typeof(zone) != TYPE_DICTIONARY:
		return -1
	return int((zone as Dictionary).get("id", -1))


static func _refund_resources(world, food: float, gold: float) -> void:
	world.resources["food"] = float(world.resources.get("food", 0.0)) + food
	world.resources["gold"] = float(world.resources.get("gold", 0.0)) + gold


## 建筑离场（被打掉 / 被拆）时调：**读条作废、不退款**。
## ★ 为什么不退：钱已经花在这栋楼上，楼没了就是没了（与「将领阵亡」不同 ——
##   那边退的是**还没造出来的兵**的钱，这一单的成果同样是没了，但它是**建筑**的一部分）。
##   ⚠️ 要改成退款就在这里加 `_refund_resources`（并补测试）。
static func cancel_upgrade_on_removed(b) -> void:
	if b == null:
		return
	b.upgrade_remaining = 0.0
	b.upgrade_total = 0.0
	b.upgrade_cost_food = 0.0
	b.upgrade_cost_gold = 0.0


# ------------------------------------------------------------------
# 每帧推进（world.tick 里调）
# ------------------------------------------------------------------

## 推进所有建筑升级 + 区划特化的读条。
##
## ★ 与 `_tick_recruitment` 用同一套「一帧可能读满好几单」的预算算法：
##   把剩下的时间接着往下算，而不是整帧丢给下一帧（否则时间轴会随帧率漂）。
static func tick(world, dt: float) -> void:
	_tick_buildings(world, dt)
	_tick_zones(world, dt)


static func _tick_buildings(world, dt: float) -> void:
	for b in world.building_list:
		if not b.alive or not b.is_upgrading():
			continue
		var budget := dt
		var guard := 0
		while b.is_upgrading() and budget > 0.0 and guard < 8:
			guard += 1
			if b.upgrade_remaining > budget:
				b.upgrade_remaining -= budget
				budget = 0.0
				break
			budget -= b.upgrade_remaining
			b.upgrade_remaining = 0.0
			_finish_upgrade(world, b)


static func _finish_upgrade(world, b) -> void:
	b.level += 1
	b.upgrade_total = 0.0
	b.upgrade_cost_food = 0.0
	b.upgrade_cost_gold = 0.0
	# ★ 等级变了 → 血量上限要按新等级重算（并把当前血量**按比例**带过去：
	#   半血的墙升完级还是半血，与科技的加成同一条约定）。
	world.apply_building_level_hp(b)
	world.push_event({"type": "upgrade_done", "kind": "building_upgrade",
		"building": b, "level": b.level})


static func _tick_zones(world, dt: float) -> void:
	if world.zones == null:
		return
	for z in world.zones.zones:
		if not zone_is_busy(z):
			continue
		var budget := dt
		var guard := 0
		while zone_is_busy(z) and budget > 0.0 and guard < 8:
			guard += 1
			var left := maxf(0.0, float(z.get("spec_remaining", 0.0)))
			if left > budget:
				z["spec_remaining"] = left - budget
				budget = 0.0
				break
			budget -= left
			_finish_spec(world, z)


static func _finish_spec(world, z) -> void:
	var kind := String(z.get("spec_kind", ""))
	var was_cancel := bool(z.get("spec_cancel", false))
	_clear_spec_bar(z)
	if was_cancel:
		var food := float(z.get("spec_cost_food", 0.0))
		var gold := float(z.get("spec_cost_gold", 0.0))
		z["spec_done"] = ""
		z["spec_cost_food"] = 0.0
		z["spec_cost_gold"] = 0.0
		_refund_resources(world, food, gold)
		world.refresh_zone_production()
		world.push_event({"type": "upgrade_done", "kind": "zone_spec_cancel",
			"zone_id": _zone_id(z), "refund_food": food, "refund_gold": gold})
		return
	z["spec_done"] = kind
	# ⚠️ `spec_cost_food / gold` **不清零**：它们要留着给「取消特化」退款用
	#    （见 cancel_spec 的说明）。
	# ★ 特化改了本区块产能 → HUD 那个「+n/秒」当场跟上
	#   （`world.refresh_zone_production` 的注释里有实测踩过的原因）
	world.refresh_zone_production()
	world.push_event({"type": "upgrade_done", "kind": "zone_specialize",
		"spec": kind, "zone_id": _zone_id(z)})
