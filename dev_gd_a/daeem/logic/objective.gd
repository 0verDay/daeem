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
## @param seats 本局的**本地席位**（合作模式两个；判定「谁的家算玩家的家」用它）
## @param seat_arg ★ **本机在操作的那一方**（决定「打哪条目标」）。
##        缺省 = `seats[0]`（老调用不受影响）。
##
## ⚠️⚠️ 为什么 `seat_arg` 必须能单独传（实测踩到）：合作模式下 `seats` 是两个席位
##    （两个都是人）；而「选边关」里本地席位名单是 `[我选的那一方, 另一边]`，
##    其中**只有第一个是本机操作的**。如果在这里靠「第一个不是 AI 的席位」去猜目标，
##    选红方时会猜成蓝方 ⇒ 红方拿到「守住 c1」；而且 `defend` 会把**两边**都算成
##    「玩家的家」⇒ 蓝方无人指挥（玩家不动它、AI 又不管它）⇒ 红方一路平推。
## @return Dictionary 目标状态（同时挂到 `world.objective_state` 上）
static func setup(world, level, seats: Array, seat_arg: String = "") -> Dictionary:
	var st := _empty_state()
	if level == null:
		world.objective_state = st
		return st

	var seat := seat_arg
	if seat == "":
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

	# ---- 目标：★★ **按本机席位取属于它的那一条** ----
	#
	# 一关可以有两条目标（蓝方守住 / 红方攻占），选谁就取谁那条
	# （`logic/level.gd` 的 `objective_for()`；没有点名的那条是所有玩家通用的）。
	# ⚠️ 老数据（一条目标、没有 `for`）走的是同一个函数 ⇒ 行为逐位不变。
	if level.has_method("objective_for"):
		var o: Variant = level.objective_for(seat)
		if typeof(o) == TYPE_DICTIONARY:
			var od: Dictionary = o
			st["kind"] = String(od.get("kind", ""))
			st["zone"] = int(od.get("zone", -1))
			st["sec"] = float(od.get("hold_sec", 0.0))
	elif not level.objectives.is_empty():
		var o2: Dictionary = level.objectives[0]
		st["kind"] = String(o2.get("kind", ""))
		st["zone"] = int(o2.get("zone", -1))
		st["sec"] = float(o2.get("hold_sec", 0.0))

	# ---- 额外的失败条件（第一批只有 zone_lost）----
	var fc: Array = []
	for item in level.fail_conditions:
		var d: Dictionary = item
		if String(d.get("kind", "")) != "zone_lost":
			continue
		fc.append(int(d.get("zone", -1)))
	st["fail"] = fc

	# ---- 开局兜底：**守住**类的目标，区划开局就必须归玩家同方 ----
	#      （否则第一帧就成立「不再归我方」⇒ 第一帧判负）
	# ★ `capture_zone`（攻占）**不做这个兜底** —— 它要求的正好相反（区划在敌手里）。
	#   这一条由 `level._ck_allies()` 的第 8 条按目标种类分开拦。
	if st["kind"] == "hold_zone":
		var owner := zone_owner(world, int(st["zone"]))
		if owner == "":
			st["state"] = STATE_LOST
			st["reason"] = R_OBJECTIVE_NEVER
		elif seat != "" and not _mine_side(owner, mine):
			st["state"] = STATE_LOST
			st["reason"] = R_OBJECTIVE_NEVER
	elif st["kind"] == "capture_zone":
		# 兜底反面：数据写错（目标区划开局就归自己）时**别静默判胜**，留一条痕迹。
		var owner2 := zone_owner(world, int(st["zone"]))
		if owner2 != "" and seat != "" and _mine_side(owner2, mine):
			push_warning("「占领 %s」的目标区划开局就归玩家自己：一进关就会判胜（数据写错了）"
				% str(int(st["zone"])))

	world.objective_state = st
	return st


## 每帧推进（**由 `world.tick()` 在末尾调**）。
##
## @param world 世界
## @param cfg 配置
## @param st  `setup()` 返回的那一份状态（也等于 `world.objective_state`）
## @param dt  这一帧的秒数
##
## 两种目标：
##   · `hold_zone`（守住 N 秒）：累加 → 守满判胜；**丢掉即判负**。
##   · `capture_zone`（攻占）：区划归属翻成玩家同方的那一帧**立刻判胜**；
##     丢了不算输（本来就是对攻，允许反复）。
static func update(world, cfg, st: Dictionary, dt: float) -> void:
	var kind := String(st.get("kind", ""))
	if st.is_empty() or (kind != "hold_zone" and kind != "capture_zone"):
		return
	if String(st.get("state", STATE_RUNNING)) != STATE_RUNNING:
		return                              # 已经结算：不再改判（界面读它播报一次）
	if dt <= 0.0:
		return

	var zone := int(st.get("zone", -1))
	var mine: Array = st.get("defend", [])

	# 0) ★★ 攻占类：**归属翻过来的那一帧就赢**（不等下一帧、也不要求再守多久）
	if kind == "capture_zone":
		var own_now := zone_owner(world, zone)
		if own_now != "" and _mine_side(own_now, mine):
			st["held"] = float(st.get("held", 0.0)) + dt
			st["state"] = STATE_WON
			return
		# 还没打下来：继续。★ 丢了**不算输**（对攻关卡允许反复争夺）。
		return

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

	# 4) ★ 常开：玩家席位的**任何一个**大本营被拆 ⇒ 负（见 `_all_seat_bases_alive`）
	if not _all_seat_bases_alive(world, mine):
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


## 玩家**每一个席位**的大本营是不是都还在（有一个没了 → 它被拆了 → 判负）。
##
## ★★ 判据是**席位**，不是「同方」（实测踩到，两个理由）：
##
## 1. **同方会把盟友 AI 的家算进来**：一关可以有两个都可玩的阵营，玩家选一个、
##    另一个由盟友 AI 接管（`world.player_seats` 里有它，但 `player_factions` 里没有）。
##    用 `same_side` 判的话，玩家自己的家被拆光之后只要盟友的家还在就**永远不判负** ——
##    「大本营被拆 = 判负」这条常开规则就被静默废掉了。
## 2. **口径是「任何一个都没了 ⇒ 负」**，不是「全部都没了」：
##    合作模式里两个人各一个大本营，其中**任何一个**被拆 = 这一路已经守不住了，
##    所以当场判负（用户拍板：「自己那一个被拆就输」）。
##    ⚠️ 别写成「还有任意一个活着就放行」—— 那样拆掉一个玩家席位的大本营不会判负，
##       表现就是「家没了还能继续打」（实测踩到：`running`，期望 `lost`）。
##
## ⇒ 「同方」仍然管另外两件事：**目标区划归谁**（盟友守的也算）与**共享视野**。
##   两处不能混用同一个判据。
static func _all_seat_bases_alive(world, defend: Array) -> bool:
	if world == null:
		return false
	if defend.is_empty():
		return false
	for s in defend:
		if not _has_base_of(world, String(s)):
			return false
	return true


## 某一方在场上还有没有活着的大本营。
static func _has_base_of(world, faction: String) -> bool:
	if faction == "":
		return false
	for b in world.building_list:
		if not b.alive or String(b.type) != BuildingRes.TYPE_BASE:
			continue
		if String(b.owner) == faction:
			return true
	return false
