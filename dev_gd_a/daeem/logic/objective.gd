## objective.gd —— **目标与胜负**（一个文件管一件事：这一局怎么算赢、怎么算输）。
##
## ★★ 规则（写死，逐条进断言 —— 见 dev_plan_7 1.3.6 / 3.4）：
##   1. 只有一种目标：`{kind: "hold_zone", zone: <区划号>, hold_sec: <秒>}`
##      —— 「守住指定区划 N 秒」。「占领即胜」**不做**；
##   2. 判定「归玩家」一律走**同方**：
##      `FactionRes.side_of(owner) == FactionRes.side_of(玩家席位)`
##      —— 合作模式下 p2 守住也算（单机时它与 `owner == 自己` 等价）；
##   3. ★ **一旦目标区划不再归玩家同方 ⇒ 当场判负**（用户拍板：连「暂停不清零」都不要）；
##   4. `held >= hold_sec` ⇒ **当场判胜**（跨过阈值的那一帧就生效，不等下一帧）；
##   5. **常开失败条件**：玩家同方的**大本营全部被拆** ⇒ 负（★ 常开**不可关**）；
##      拆掉一半**不算** —— 「全部」是这条判据的关键字；
##   6. **额外失败条件**（`fail_conditions[]`，第一批只做 `zone_lost`）：指定的区划
##      一旦不再归玩家同方 ⇒ 负（可以配多个，谁先触发算谁的）；
##   7. 开局兜底：目标区划**开局就不归玩家同方** ⇒ 立刻 `lost`
##      （`reason = "objective_never_held"`）。★ 这条**不是静默**：它是数据写错，
##      要留一条痕迹 —— 编辑器的导出校验第 8 条会先拦一遍，这里是第二道。
##   8. 结算后 world **继续 tick**（不做 UI 冻结）；界面读 `state` / `reason` 播报一次。
##
## ★ 为什么「大本营被拆」是常开的：它是「这一局还能不能继续」的底线判据
##   （大本营没了就再也建不了东西）；其余失败条件都是关卡设计者的调味，所以可配。
##
## ★ 为什么结算要**放在 tick 末尾**（见 world.tick）：目标最后判 ⇒
##   「这一帧刚守满」能立刻结算，而不是等下一帧。
##
## ⚠️ 跨文件引用只用**本文件里的 preload 常量**（`--script` 下全局 class_name 不可用）。
extends RefCounted

const FactionRes = preload("res://logic/faction.gd")
const BuildingRes = preload("res://logic/building.gd")

## 状态
const STATE_RUNNING := "running"
const STATE_WON := "won"
const STATE_LOST := "lost"

## 判负原因（短名进快照；文案在 view/ 一处翻译，见 `reason_label()`）
const R_OBJECTIVE_LOST := "objective_lost"
const R_OBJECTIVE_NEVER := "objective_never_held"
const R_BASE_DESTROYED := "base_destroyed"
const R_ZONE_LOST := "zone_lost"


## 建一局的目标状态（由 `world.reset()` 末尾调，与 fog / faction_ai 同一处收口）。
##
## @param world 世界
## @param level `logic/level.gd` 的 Level（**可以是 null**：不做战役的老路径 / 测试）
## @param seats 本局的玩家席位（faction id 数组；空 → 用 `world.my_faction` 兜底）
## @return Dictionary 目标状态（同时挂到 `world.objective_state` 上）
##
## ★★ `level == null` 时返回**空状态**（`kind == ""` / `state == "running"`）：
##    于是「不做战役」的那条老路径上，`update()` 每一帧只多一次 `kind == ""` 判断，
##    **一个玩法行为都不受影响** —— 这是「向后兼容」那一条在逻辑层的写法。
static func setup(world, level, seats: Array) -> Dictionary:
	var st := _empty_state()
	if level == null:
		world.objective_state = st
		return st

	var seat := ""
	if not seats.is_empty():
		seat = String(seats[0])
	elif world != null:
		seat = String(world.my_faction)

	# 玩家同方的全部席位（合作：两个玩家都在这一份里）
	var mine: Array = []
	if not seats.is_empty():
		for s in seats:
			mine.append(String(s))
	elif seat != "":
		mine.append(seat)

	st["defend"] = mine
	st["seat"] = seat
	st["reason"] = ""

	# ---- 目标：**恰好取第一项**（校验会保证只有一项）----
	if not level.objectives.is_empty():
		var o: Dictionary = level.objectives[0]
		st["kind"] = String(o.get("kind", ""))
		st["zone"] = int(o.get("zone", -1))
		st["sec"] = float(o.get("hold_sec", 0.0))

	# ---- 额外的失败条件（第一批只有 zone_lost）----
	var fc: Array = []
	for item in level.fail_conditions:
		var d: Dictionary = item
		if String(d.get("kind", "")) != "zone_lost":
			continue
		fc.append(int(d.get("zone", -1)))
	st["fail"] = fc

	# ---- 开局兜底：目标区划开局就必须归玩家同方（否则第一帧就得判负）----
	if st["kind"] == "hold_zone":
		var owner := zone_owner(world, int(st["zone"]))
		if owner == "":
			st["state"] = STATE_LOST
			st["reason"] = R_OBJECTIVE_NEVER
		elif seat != "" and not _mine_side(owner, mine):
			st["state"] = STATE_LOST
			st["reason"] = R_OBJECTIVE_NEVER

	world.objective_state = st
	return st


## 每帧推进（**由 `world.tick()` 在末尾调**）。
##
## @param world 世界
## @param cfg 配置
## @param st  `setup()` 返回的那一份状态（也等于 `world.objective_state`）
## @param dt  这一帧的秒数
static func update(world, cfg, st: Dictionary, dt: float) -> void:
	if st.is_empty() or String(st.get("kind", "")) != "hold_zone":
		return
	if String(st.get("state", STATE_RUNNING)) != STATE_RUNNING:
		return                              # 已经结算：不再改判（界面读它播报一次）
	if dt <= 0.0:
		return

	var zone := int(st.get("zone", -1))
	var mine: Array = st.get("defend", [])

	# 1) ★ 丢掉即判负（在累加之前判：这一帧已经不归我了，就不该再记 0.1 秒）
	var owner := zone_owner(world, zone)
	if owner == "" or not _mine_side(owner, mine):
		st["state"] = STATE_LOST
		st["reason"] = R_OBJECTIVE_LOST
		return

	# 2) 累加（只在这一帧仍然归玩家同方时）
	st["held"] = float(st.get("held", 0.0)) + dt

	# 3) 守满即胜（跨过阈值的那一帧就生效）
	if float(st["held"]) >= float(st.get("sec", 0.0)):
		st["held"] = float(st["sec"])
		st["state"] = STATE_WON
		return

	# 4) ★ 常开：玩家同方的大本营**全部**被拆 ⇒ 负（拆一半不算）
	if not _has_any_base(world, mine):
		st["state"] = STATE_LOST
		st["reason"] = R_BASE_DESTROYED
		return

	# 5) 额外的失败条件（谁先触发算谁的）
	for item in (st.get("fail", []) as Array):
		var zid := int(item)
		var own2 := zone_owner(world, zid)
		if own2 == "" or not _mine_side(own2, mine):
			st["state"] = STATE_LOST
			st["reason"] = "%s:%d" % [R_ZONE_LOST, zid]
			return


## 进快照的那一份（字段短名，见 dev_plan_7 3.8）。**只发玩家要看的**。
static func to_snapshot(st: Dictionary) -> Dictionary:
	if st.is_empty():
		return {}
	return {
		"zone": int(st.get("zone", -1)),
		"held": float(st.get("held", 0.0)),
		"sec": float(st.get("sec", 0.0)),
		"state": String(st.get("state", STATE_RUNNING)),
		"reason": String(st.get("reason", "")),
	}


## 从快照写回（**缺字段 = 保持本地现状**，见 snapshot.gd 那条铁律）。
static func apply_snapshot(st: Dictionary, snap: Dictionary) -> void:
	if st.is_empty() or snap.is_empty():
		return
	if snap.has("zone"):
		st["zone"] = int(snap["zone"])
	if snap.has("held"):
		st["held"] = float(snap["held"])
	if snap.has("sec"):
		st["sec"] = float(snap["sec"])
	if snap.has("state"):
		st["state"] = String(snap["state"])
	if snap.has("reason"):
		st["reason"] = String(snap["reason"])


## 这一局结算了吗（胜或负）。
static func is_over(st: Dictionary) -> bool:
	var s := String(st.get("state", STATE_RUNNING))
	return s == STATE_WON or s == STATE_LOST


## ★ 判负 / 判胜原因的人话（**只有这一处**写文案：逻辑层给参数，界面拿这句话）。
static func reason_label(st: Dictionary) -> String:
	var reason := String(st.get("reason", ""))
	if reason == "":
		return ""
	if reason == R_OBJECTIVE_LOST:
		return "目标区划失守"
	if reason == R_OBJECTIVE_NEVER:
		return "目标区划开局就不在我方手里（数据写错了）"
	if reason == R_BASE_DESTROYED:
		return "大本营被拆"
	if reason.begins_with(R_ZONE_LOST + ":"):
		var zid := reason.substr((R_ZONE_LOST + ":").length())
		return "额外区划 %s 失守" % zid
	return reason


## 进度条用的比例（0~1；没有目标 → 0）。
static func progress_ratio(st: Dictionary) -> float:
	var sec := float(st.get("sec", 0.0))
	if sec <= 0.0:
		return 0.0
	return clampf(float(st.get("held", 0.0)) / sec, 0.0, 1.0)


## 空状态（「这一局没有目标」—— 不做战役的老路径）。
static func _empty_state() -> Dictionary:
	return {
		"kind": "",
		"zone": -1,
		"sec": 0.0,
		"held": 0.0,
		"state": STATE_RUNNING,
		"reason": "",
		"defend": [],
		"fail": [],
		"seat": "",
	}


## 某个区划现在的归属（世界里的活数据；越界 / 没有 zone 系统 → ""）。
static func zone_owner(world, zid: int) -> String:
	if world == null or world.zones == null or zid < 0:
		return ""
	var z = world.zone_by_id(zid)
	if z == null:
		return ""
	return String((z as Dictionary).get("owner", ""))


## 这个归属方是不是**玩家同方**（含自己；合作模式下 p2 也算）。
static func _mine_side(owner: String, mine: Array) -> bool:
	if owner == "":
		return false
	for s in mine:
		if FactionRes.same_side_for_attack(owner, String(s)):
			return true
	return false


## 玩家同方**还有没有**大本营（一个都没有 → 全部被拆）。
##
## ★ 判据是「同方里有**任意一个**大本营还活着」—— 合作模式下两个人各有大本营，
##   一个被拆不算输（另一个还在），两个都被拆才算。
static func _has_any_base(world, mine: Array) -> bool:
	if world == null:
		return false
	for b in world.building_list:
		if not b.alive or String(b.type) != BuildingRes.TYPE_BASE:
			continue
		if _mine_side(String(b.owner), mine):
			return true
	return false
