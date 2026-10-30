## upgrade.gd —— 建筑升级（右下「操作」页签里那几格）
##
## ★★ 2026.10.30：区划特化机制已移除；本文件只剩**建筑升级**（实际上只有大本营可升）。
##
## 这一层是**规则**（与 logic/tech.gd 同一个定位：world 持有状态，规则写在这里）：
##   · 升级能不能开（等级上限 / 读条占用 / 归属 / 钱够不够）→ `can_upgrade()`
##   · 取消读条中的升级 → `can_cancel_upgrade()`
##   · 每帧推进升级读条 → `tick()`
##
## ★★ 时间与账目字段挂在**被升级的那个东西自己身上**：建筑升级 → `building.upgrade_*`。
##   理由与「招募队列挂在将领 / 区划上」完全一样：这是「这个东西正在干嘛」，
##   另开一张「id → 进度」的表就多出一份要对齐、要清理、要进快照的状态。
##
## ★ 读条语义（与招募逐条对齐）：
##   · **入队即扣**粮食 / 黄金（不看 economy.enabled 那个只管建造免费的开关）；
##   · 取消 → **全额退款**（按记账值退，不看「当前还剩几秒」）；
##   · 读条期间**不再接新的升级**（拒因 `busy`），但**可以取消**；
##   · 同一时间只跑一条：**不做队列**。
##
## ★ 读条期间建筑照常被打、照常有功能（它没有「动不了」这回事）——
##   建筑本来就不可移动，升级读条只锁「再升级」这一个入口。
##
## ★ 效果：升级 = 等级 +1，血量上限 = `config.building.<type>.hp_max × hp_mult(等级)`
##   （tech 的「建筑血量 +10%」再乘在它上面，两者叠加）。
##
## ⚠️ 三条边界（架构铁律）：不碰场景树、不读输入、数值全来自 config.json；
##    拒因只给**码**（"busy" / "max_level" / "cost" / "owner" / …），
##    中文文案在 view/hud.gd 里翻译。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")
const FactionRes = preload("res://logic/faction.gd")
const EconomyRes = preload("res://logic/economy.gd")
## ⚠️ 这里**不要** preload zone.gd / building.gd / world.gd：
##    这一层只做静态查询与判定，`world` / `b` 都是**参数传进来**的。


# ------------------------------------------------------------------
# 判定（都给「拒因码」，不给文案）
# ------------------------------------------------------------------

## 这个建筑**现在**能不能开始升级。@return "" = 可以；否则是拒因码：
##   "type"       这一类型没有升级表（区划中心 / 未知类型）
##   "max_level"  已经到最高级（等级表的条数）
##   "busy"       ★ 已经在读条了（需求确认：读条期间拒绝新的升级请求）
##   "owner"      不是自己这一方的建筑
##   "generals"   ★ 大本营将领挡位不足（门槛读 config 的 need_generals：升 2 本要 2 将、升 3 本要 4 将）
##   "cost"       粮食 / 黄金不够
static func can_upgrade(world, b, faction: String) -> String:
	if b == null or not b.alive:
		return "type"
	# ★★ 2026.10.26：只有大本营可以升级；木墙 / 哨塔 / 石墙 / 警戒塔不再有升级机制。
	#    即使有人手写了一张等级表，这里也不会放行。
	if not b.is_base():
		return "type"
	if not world.cfg.has_upgrade(b.type):
		return "type"
	if b.neutralized:
		return "neutralized"          # 大本营没了：残余建筑停止升级
	if not world.accepts_owner(String(b.owner), faction):
		return "owner"
	if b.is_upgrading():
		return "busy"
	# ★★ 大本营正在排队重生将领 → 不能**开始新的**升级（进行中的不打断）。
	if b.is_base() and b.is_respawning():
		return "respawning"
	if b.level >= world.cfg.upgrade_max_level(b.type):
		return "max_level"
	# ★★ 大本营升级的将领挡位：读**目标行**的 `need_generals`（升 2 本 2 将 / 升 3 本 4 将）。
	#   ⚠️ 不要回头借用 `max_generals`（上限 2/5/6）—— 门槛与上限是两件事，见 config 注释。
	if b.is_base():
		var need_generals: int = int(world.cfg.upgrade_need_generals(b.type, int(b.level)))
		if need_generals > 0 \
				and world.general_count_of(String(b.owner)) < need_generals:
			return "generals"
	var pool: Variant = world.resource_pool_for(String(b.owner))
	if not EconomyRes.can_afford(pool, world.cfg.upgrade_cost_to(b.type, b.level)):
		return "cost"
	return ""


## 能不能取消**读条中的**那次升级。@return "" / "owner" / "idle"
##   "idle" = 现在没有在读条（界面上那一格根本不该出现）
## @param world 可选：合作模式下用它做**严格归属**判断；老调用不传 → 沿用 same_side。
static func can_cancel_upgrade(b, faction: String, world = null) -> String:
	if b == null or not b.alive:
		return "idle"
	var owner_ok: bool = (world.accepts_owner(String(b.owner), faction)
		if world != null else FactionRes.same_side(String(b.owner), faction))
	if not owner_ok:
		return "owner"
	if not b.is_upgrading():
		return "idle"
	return ""


# ------------------------------------------------------------------
# 开始 / 取消
# ------------------------------------------------------------------

## 开始升级（`building_upgrade` 命令的唯一落点）。
## ★ 顺序与招募一致：**先校验 → 再扣费 → 最后开始读条** ——
##   反了会出现「钱扣了、没读条」这种查不出来的坏状态。
static func start_upgrade(world, b, faction: String) -> bool:
	var reason := can_upgrade(world, b, faction)
	if reason != "":
		# ⚠️ `b` 可能是 **null**（命令指到一格没有建筑的地块 —— `can_upgrade` 会返回 "none"），
		#   而这里要读 `b.owner` ⇒ 必须分开写，否则越界命令会当场报
		#   "Invalid access to property 'owner' on a base object of type Nil"（实测踩到）。
		var ev := {"type": "upgrade_rejected", "reason": reason, "kind": "building_upgrade"}
		if b != null:
			ev["building"] = b
			ev["faction"] = String(b.owner)
			# ★ 文案要「升到几级 / 要几名 / 现在几名」，在逻辑层算好，视图不自己猜。
			ev["target_level"] = int(b.level) + 1
			ev["need"] = int(world.cfg.upgrade_need_generals(b.type, int(b.level)))
			ev["have"] = int(world.general_count_of(String(b.owner)))
		world.push_event(ev)
		return false
	var cost: Dictionary = world.cfg.upgrade_cost_to(b.type, b.level)
	# ★ 钱从**这栋楼的归属方**自己的池子里扣（不是写死的 world.resources）——
	#   AI 升级自己的建筑不该掏玩家的兜。池子为 null = 那一方没有资源库（见 resource_pool_for）。
	if not EconomyRes.spend(world.resource_pool_for(String(b.owner)), cost):
		world.push_event({"type": "upgrade_rejected", "reason": "cost",
			"kind": "building_upgrade", "building": b, "faction": String(b.owner)})
		return false
	# ★★ 读条时长在**这一帧定死**（`building_upgrade_time` 内含「≥N 将走提速档」的选档）：
	#    读条中将领数再变，`upgrade_total` 也不会重算。
	var secs: float = world.building_upgrade_time(b)
	b.upgrade_remaining = secs
	b.upgrade_total = secs
	# 记账：取消（或建筑没了）时按这三个数退款
	b.upgrade_cost_food = float(cost.get("food", 0.0))
	b.upgrade_cost_gold = float(cost.get("gold", 0.0))
	# ★★ 播报用的事件：带上阵营与目标等级（`view/game_interaction.gd` 据此弹顶部横幅）。
	#    `cancel_upgrade()` 不透支它 ⇒ 取消不撤播报；取消后再升会再推一条。
	world.push_event({"type": "upgrade_started", "kind": "building_upgrade",
		"building": b, "faction": String(b.owner),
		"level": int(b.level), "target_level": int(b.level) + 1, "secs": secs})
	return true


## 取消**读条中的**升级（全额退款）。@return true = 真的取消了
static func cancel_upgrade(world, b, faction: String) -> bool:
	var reason := can_cancel_upgrade(b, faction, world)
	if reason != "":
		# ⚠️ 与 start_upgrade 同一条：`b` 可能是 null（命令指到空格），别去读 `b.owner`
		var ev := {"type": "upgrade_cancel_rejected", "reason": reason,
			"kind": "building_upgrade"}
		if b != null:
			ev["building"] = b
			ev["faction"] = String(b.owner)
		world.push_event(ev)
		return false
	var food: float = b.upgrade_cost_food
	var gold: float = b.upgrade_cost_gold
	var owner := String(b.owner)
	b.upgrade_remaining = 0.0
	b.upgrade_total = 0.0
	b.upgrade_cost_food = 0.0
	b.upgrade_cost_gold = 0.0
	_refund_resources(world, owner, food, gold)
	world.push_event({"type": "upgrade_cancelled", "kind": "building_upgrade", "building": b,
		"refund_food": food, "refund_gold": gold})
	return true


## 退款：退给**下单那一方自己的池子**（不是写死的 world.resources）。
##
## ⚠️ `faction` 必须由调用方传进来：退款那几处的对象（建筑 / 区划）在退款之前
##    可能已经易主 / 被清场，而钱当初是从**原来那一方**扣的。
##    这与 `world._refund` 里那句「zid 必须由调用方传进来」是**同一个坑**。
## ★ 池子为 null（那一方没有资源库）→ 本来就一分没扣，这里也不加（见 resource_pool_for）。
static func _refund_resources(world, faction: String, food: float, gold: float) -> void:
	var pool: Variant = world.resource_pool_for(faction)
	if pool == null:
		return
	pool["food"] = float(pool.get("food", 0.0)) + food
	pool["gold"] = float(pool.get("gold", 0.0)) + gold


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

## 推进所有建筑升级的读条。
##
## ★ 与 `_tick_recruitment` 用同一套「一帧可能读满好几单」的预算算法：
##   把剩下的时间接着往下算，而不是整帧丢给下一帧（否则时间轴会随帧率漂）。
static func tick(world, dt: float) -> void:
	_tick_buildings(world, dt)


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
	# ★★ 大本营等级决定资源加成 / 所在区划的人口加成 ⇒ 当场刷新产出与人口上限。
	world.refresh_zone_production()
	world.push_event({"type": "upgrade_done", "kind": "building_upgrade",
		"building": b, "level": b.level})


