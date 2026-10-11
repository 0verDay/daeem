## test_outcome.gd —— **目标与胜负**断言（dev_plan_7 M7.1：`logic/objective.gd`）。
##
## 盯的是「不写就会静默错」的那一类：
##   · 守住计时只在目标区划归玩家**同方**时累加；
##   · ★ **目标区划一丢掉就判负**（不是暂停、不是清零 —— 用户拍板「丢掉即失败」）；
##   · 守满的那一帧**立刻**判胜（不等下一帧）；
##   · 大本营**全部**被拆才判负（拆一半不算）；
##   · `zone_lost` 额外失败条件（多条里谁先触发算谁的）；
##   · ★ 开局归属不合法时判负并带 `objective_never_held` 痕迹（运行时兜底那一道）；
##   · 没有目标的一局（不做战役的老路径）**一个玩法行为都不受影响**。
##
## ⚠️ 语言约定见 tests/test_case.gd（`--script` 下全局 class_name 不可用；只用 preload 常量）。
extends "res://tests/test_case.gd"

const CampaignRes = preload("res://logic/campaign.gd")
const LevelRes = preload("res://logic/level.gd")
const WorldRes = preload("res://logic/world.gd")
const ObjectiveRes = preload("res://logic/objective.gd")
const BuildingRes = preload("res://logic/building.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const TMP_ROOT := "res://.tmp_outcome_tests"
## 目标区划：样例地图上 c1（id=4）的开局归属是 F1 —— 正好可以当「一开局就是自己的」
const OBJ_ZONE := 4


func _initialize() -> void:
	run_all(Callable(self, "_run"))


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_clean_tmp()
	_group_hold(cfg)
	_group_lose_zone(cfg)
	_group_base(cfg)
	_group_extra_fail(cfg)
	_group_setup_guard(cfg)
	_group_no_level(cfg)
	_group_event(cfg)
	_clean_tmp()


# ------------------------------------------------------------------
# 一、守住计时
# ------------------------------------------------------------------
func _group_hold(cfg) -> void:
	var w = _make_world(cfg, {"objectives": [{"kind": "hold_zone", "zone": OBJ_ZONE, "hold_sec": 10.0}]})
	ok(w != null, "能造出带目标的单人世界")
	if w == null:
		return
	var st: Dictionary = w.objective_state
	eq(String(st["kind"]), "hold_zone", "目标种类是 hold_zone")
	eq(int(st["zone"]), OBJ_ZONE, "目标区划是 c1")
	near(float(st["sec"]), 10.0, 0.001, "目标 10 秒")
	near(float(st["held"]), 0.0, 0.001, "开局 held = 0（HUD 第一帧之前就是对的）")
	eq(String(st["state"]), "running", "开局状态 running")
	eq(st["defend"], ["F1"], "defend 是本局玩家席位")

	# 目标区划归自己 → 累加
	ObjectiveRes.update(w, cfg, st, 1.0)
	near(float(st["held"]), 1.0, 0.001, "目标归自己时 held += dt")
	ObjectiveRes.update(w, cfg, st, 0.5)
	near(float(st["held"]), 1.5, 0.001, "多次 update 累加")
	eq(String(st["state"]), "running", "还没守满 → 仍在进行中")

	# ★ 守满的那一帧**立刻**判胜（把 dt 一次给足，跨过阈值）
	ObjectiveRes.update(w, cfg, st, 20.0)
	eq(String(st["state"]), "won", "★ 跨过 hold_sec 的那一帧立刻判胜")
	near(float(st["held"]), 10.0, 0.001, "held 被夹在 hold_sec（不显示 21.5/10）")
	ok(ObjectiveRes.is_over(st), "结算后 is_over = true")
	near(ObjectiveRes.progress_ratio(st), 1.0, 0.001, "进度条到 100%")

	# 结算之后**不再改判**（界面靠这条只播报一次）
	ObjectiveRes.update(w, cfg, st, 100.0)
	eq(String(st["state"]), "won", "结算后不再改判")

	# 玩家席位走了（不再归自己）也不影响已经判胜的那一局
	eq(ObjectiveRes.reason_label(st), "", "胜局没有判负原因")


# ------------------------------------------------------------------
# 二、★ 丢掉即判负
# ------------------------------------------------------------------
func _group_lose_zone(cfg) -> void:
	var w = _make_world(cfg, {"objectives": [{"kind": "hold_zone", "zone": OBJ_ZONE, "hold_sec": 100.0}]})
	if w == null:
		return
	var st: Dictionary = w.objective_state
	ObjectiveRes.update(w, cfg, st, 5.0)
	near(float(st["held"]), 5.0, 0.001, "先守住 5 秒")

	# ★ 目标区划被敌方拿走 → 当场判负（不是暂停、不是清零）
	_set_owner(w, OBJ_ZONE, "E1")
	ObjectiveRes.update(w, cfg, st, 0.5)
	eq(String(st["state"]), "lost", "★ 目标区划一丢掉就判负")
	eq(String(st["reason"]), ObjectiveRes.R_OBJECTIVE_LOST, "原因是 objective_lost")
	near(float(st["held"]), 5.0, 0.001, "丢掉那一刻 held 不再增加（也没有被清零）")
	eq(ObjectiveRes.reason_label(st), "目标区划失守", "判负原因有人话文案")

	# 变成**无主**同样算丢（不是只有「归敌方」才算）
	var w2 = _make_world(cfg, {"objectives": [{"kind": "hold_zone", "zone": OBJ_ZONE, "hold_sec": 100.0}]})
	var st2: Dictionary = w2.objective_state
	_set_owner(w2, OBJ_ZONE, "")
	ObjectiveRes.update(w2, cfg, st2, 0.5)
	eq(String(st2["state"]), "lost", "★ 目标区划变成无主也算丢")
	eq(String(st2["reason"]), ObjectiveRes.R_OBJECTIVE_LOST, "无主也是 objective_lost")

	# ★ 一丢掉就不再累加（哪怕下一帧又抢回来）
	var w3 = _make_world(cfg, {"objectives": [{"kind": "hold_zone", "zone": OBJ_ZONE, "hold_sec": 100.0}]})
	var st3: Dictionary = w3.objective_state
	_set_owner(w3, OBJ_ZONE, "E1")
	ObjectiveRes.update(w3, cfg, st3, 1.0)
	_set_owner(w3, OBJ_ZONE, "F1")
	ObjectiveRes.update(w3, cfg, st3, 1.0)
	near(float(st3["held"]), 0.0, 0.001, "丢掉那一帧之后就不再累加（抢回来也不算）")


# ------------------------------------------------------------------
# 三、★ 大本营被拆（常开失败条件）
# ------------------------------------------------------------------
func _group_base(cfg) -> void:
	var w = _make_world(cfg, {"objectives": [{"kind": "hold_zone", "zone": OBJ_ZONE, "hold_sec": 100.0}]})
	if w == null:
		return
	var st: Dictionary = w.objective_state
	ok(w.find_base_of("F1") != null, "开局 F1 有大本营")

	# 拆掉自己的大本营 → 判负
	# ⚠️ 不能靠 `take_damage` 打死：大本营是**故意不可摧毁**的
	#    （`building.take_damage` 里 `cfg.destructible_base` 为 false 时血量地板是 1），
	#    所以这里模拟战斗结算那一刻：标死 + 从世界里摘掉（`_collect_destroyed_buildings` 干的事）。
	var base = w.find_base_of("F1")
	ok(base != null, "开局 F1 有大本营")
	if base == null:
		return
	_kill_building(w, base)
	ObjectiveRes.update(w, cfg, st, 0.5)
	eq(String(st["state"]), "lost", "★ 大本营被拆 → 判负")
	eq(String(st["reason"]), ObjectiveRes.R_BASE_DESTROYED, "原因是 base_destroyed")
	eq(ObjectiveRes.reason_label(st), "大本营被拆", "判负原因有人话文案")

	# ★★ 「任何一个玩家席位被拆 ⇒ 判负」（口径修正，见 objective.gd 的 `_has_any_base`）：
	#   原来这里是「两个玩家的大本营都被拆才判负（拆一半不算）」—— 那是**同方**口径，
	#   它有两个问题：① 合作模式里一个人的家没了还能继续打，不像「本关失守」；
	#   ② 一关两个可玩阵营时，盟友 AI 的家会被当成玩家的家 ⇒ 自家被拆光也不判负。
	#   现在判据是**席位**：拆掉任何一个 ⇒ 负。
	var w2 = _make_world_coop(cfg)
	ok(w2 != null, "能造出双人世界（两个大本营）")
	if w2 == null:
		return
	var st2: Dictionary = w2.objective_state
	ok(w2.find_base_of("F1") != null and w2.find_base_of("F2") != null,
		"双人世界两个席位各有一个大本营")
	eq((st2["defend"] as Array).size(), 2, "两个守方席位都在（F1 + F2）")
	var b1 = w2.find_base_of("F1")
	_kill_building(w2, b1)
	ObjectiveRes.update(w2, cfg, st2, 0.5)
	eq(String(st2["state"]), "lost", "★ 拆掉其中一个席位的大本营 → 判负")
	eq(String(st2["reason"]), ObjectiveRes.R_BASE_DESTROYED, "原因是 base_destroyed")

	# ★ 盟友 AI 的大本营被拆**不算**玩家丢家（只有玩家自己的席位算）
	var w2b = _make_world_coop(cfg)
	var st2b: Dictionary = w2b.objective_state
	# 把 F2 从「守方席位」里摘掉，模拟「F2 是盟友 AI、不是本机席位」
	st2b["defend"] = ["F1"]
	var b2only = w2b.find_base_of("F2")
	_kill_building(w2b, b2only)
	ObjectiveRes.update(w2b, cfg, st2b, 0.5)
	eq(String(st2b["state"]), "running",
		"★ 只拆掉**盟友 AI** 的家 → 不判负（它不在守方席位里）")

	# 拆掉**敌方**大本营不影响胜负（那不是玩家同方的）
	#
	# ⚠️ 用 **F2**（红方）当敌方：这一关是「选边关」，F1 与 F2 是对立的
	#   （样例地图上已经没有 E1 这个第三方了）。判据不变：只拆敌人（非玩家席位）的家 ⇒ 不判负。
	var w3 = _make_world(cfg, {"objectives": [{"kind": "hold_zone", "zone": OBJ_ZONE, "hold_sec": 100.0}]})
	var st3: Dictionary = w3.objective_state
	# ★ F2 是 AI 阵营 —— 本轮 AI **没有大本营**，它本来就没有家可拆。
	#   这一条验的是「非玩家席位的大本营被拆不影响玩家」，所以先确认它没有家。
	var eb = w3.find_base_of("F2")
	ok(eb == null, "★ AI 阵营 F2 没有大本营（本轮口径）")
	ObjectiveRes.update(w3, cfg, st3, 0.5)
	eq(String(st3["state"]), "running", "拆敌方的家不判负（判据只看玩家席位）")


# ------------------------------------------------------------------
# 四、`zone_lost` 额外失败条件
# ------------------------------------------------------------------
func _group_extra_fail(cfg) -> void:
	# 额外失败区划用 c2（id=5）—— 它开局**无主**，所以第 6 条会在第一帧就触发；
	# 为了只验「丢掉才判负」，先把它划给 F1
	var patch := {
		"zones": [{"id": OBJ_ZONE, "owner": "F1"}, {"id": 5, "owner": "F1"}],
		"fail_conditions": [{"kind": "zone_lost", "zone": 5}],
		"objectives": [{"kind": "hold_zone", "zone": OBJ_ZONE, "hold_sec": 100.0}],
	}
	var w = _make_world(cfg, patch)
	if w == null:
		return
	eq(String(_owner(w, 5)), "F1", "额外失败区划开局归我方")
	var st: Dictionary = w.objective_state
	eq(st["fail"], [5], "额外失败条件被读进来")
	ObjectiveRes.update(w, cfg, st, 1.0)
	eq(String(st["state"]), "running", "额外区划还在手上 → 不判负")

	_set_owner(w, 5, "E1")
	ObjectiveRes.update(w, cfg, st, 0.5)
	eq(String(st["state"]), "lost", "★ 额外区划失守 → 判负")
	eq(String(st["reason"]), "zone_lost:5", "原因带上区划号")
	eq(ObjectiveRes.reason_label(st), "额外区划 5 失守", "判负原因有人话文案")

	# 多条：谁先触发算谁的
	var w2 = _make_world(cfg, {
		"zones": [{"id": OBJ_ZONE, "owner": "F1"}, {"id": 5, "owner": "F1"}, {"id": 6, "owner": "F1"}],
		"fail_conditions": [{"kind": "zone_lost", "zone": 5}, {"kind": "zone_lost", "zone": 6}],
		"objectives": [{"kind": "hold_zone", "zone": OBJ_ZONE, "hold_sec": 100.0}],
	})
	var st2: Dictionary = w2.objective_state
	eq((st2["fail"] as Array).size(), 2, "两条额外失败条件都读进来")
	_set_owner(w2, 6, "E1")
	ObjectiveRes.update(w2, cfg, st2, 0.5)
	eq(String(st2["reason"]), "zone_lost:6", "★ 谁先触发算谁的（这里是 6）")

	# ★ 目标区划丢掉的优先级：它排在额外失败条件**之前**判
	var w3 = _make_world(cfg, {
		"zones": [{"id": OBJ_ZONE, "owner": "F1"}, {"id": 5, "owner": "F1"}],
		"fail_conditions": [{"kind": "zone_lost", "zone": 5}],
		"objectives": [{"kind": "hold_zone", "zone": OBJ_ZONE, "hold_sec": 100.0}],
	})
	var st3: Dictionary = w3.objective_state
	_set_owner(w3, OBJ_ZONE, "E1")
	_set_owner(w3, 5, "E1")
	ObjectiveRes.update(w3, cfg, st3, 0.5)
	eq(String(st3["reason"]), ObjectiveRes.R_OBJECTIVE_LOST,
		"目标区划与额外区划同时丢 → 报「目标区划失守」（它优先）")


# ------------------------------------------------------------------
# 五、★ 开局兜底（运行时那一道）
# ------------------------------------------------------------------
func _group_setup_guard(cfg) -> void:
	# 目标区划开局归**敌方** → 建状态的那一刻就判负，并留 objective_never_held 痕迹
	var w = _make_world(cfg, {
		"zones": [{"id": OBJ_ZONE, "owner": "E1"}],
		"objectives": [{"kind": "hold_zone", "zone": OBJ_ZONE, "hold_sec": 100.0}],
	})
	if w == null:
		return
	var st: Dictionary = w.objective_state
	eq(String(st["state"]), "lost", "★ 目标区划开局归敌方 → 立刻判负")
	eq(String(st["reason"]), ObjectiveRes.R_OBJECTIVE_NEVER, "★ 原因是 objective_never_held（留了痕迹）")
	ok(ObjectiveRes.reason_label(st).contains("数据写错"), "文案说明它是数据写错（不静默）")
	# 它**不会**在 update 里被改成别的（已经结算）
	ObjectiveRes.update(w, cfg, st, 1.0)
	eq(String(st["reason"]), ObjectiveRes.R_OBJECTIVE_NEVER, "结算后不再改判")

	# 目标区划开局**无主** → 同样立刻判负
	var w2 = _make_world(cfg, {
		"zones": [{"id": OBJ_ZONE, "owner": ""}],
		"objectives": [{"kind": "hold_zone", "zone": OBJ_ZONE, "hold_sec": 100.0}],
	})
	eq(String(w2.objective_state["state"]), "lost", "★ 目标区划开局无主 → 立刻判负")
	eq(String(w2.objective_state["reason"]), ObjectiveRes.R_OBJECTIVE_NEVER, "同样留痕迹")


# ------------------------------------------------------------------
# 六、不做战役的老路径：一个玩法行为都不受影响
# ------------------------------------------------------------------
func _group_no_level(cfg) -> void:
	# 老入口 `World.create(cfg, 路径, false)`
	var w = WorldRes.create(cfg, "res://data/maps/frontier/map.json", false)
	ok(w != null, "老入口照样能建世界")
	if w == null:
		return
	eq(w.level, null, "老入口的 world.level 是 null")
	ok(w.objective_state.has("kind"), "老入口也有一份 objective_state（空状态）")
	eq(String(w.objective_state["kind"]), "", "★ 空状态：kind 是空串（没有目标）")
	eq(String(w.objective_state["state"]), "running", "空状态永远是 running（不会自己判负）")
	# ★ 跑 20 秒：既不发 level_end，也不会被判负
	var ends := 0
	for i in 200:
		for e in w.tick(0.1):
			if String((e as Dictionary).get("type", "")) == "level_end":
				ends += 1
	eq(ends, 0, "★ 没有目标的一局永远不发 level_end")
	eq(String(w.objective_state["kind"]), "", "没有目标的一局状态没被改")
	ok(not ObjectiveRes.is_over(w.objective_state), "没有目标的一局不算结算")

	# 顶层 API 传 null level → 明确报错并返回 null（别静默造一个「没有关卡」的世界）
	ok(WorldRes.create_from_level(cfg, null, "F1", [], false) == null,
		"create_from_level(null) 明确失败（不静默）")


# ------------------------------------------------------------------
# 七、事件：结算只播报一次
# ------------------------------------------------------------------
func _group_event(cfg) -> void:
	var w = _make_world(cfg, {"objectives": [{"kind": "hold_zone", "zone": OBJ_ZONE, "hold_sec": 1.0}]})
	if w == null:
		return
	var wins := 0
	var last: Dictionary = {}
	for i in 100:                            # 跑 10 秒，守满 1 秒就该赢
		for e in w.tick(0.1):
			var ev: Dictionary = e
			if String(ev.get("type", "")) == "level_end":
				wins += 1
				last = ev
	eq(String(w.objective_state["state"]), "won", "守满 1 秒 → 判胜")
	eq(wins, 1, "★ level_end 只发一次（结算后 world 继续 tick，靠去重）")
	eq(String(last.get("result", "")), "win", "事件带 result = win")
	eq(String(last.get("reason", "")), "", "胜局没有原因")

	# 判负那条也发一次
	var w2 = _make_world(cfg, {
		"zones": [{"id": OBJ_ZONE, "owner": "F1"}, {"id": 5, "owner": "F1"}],
		"fail_conditions": [{"kind": "zone_lost", "zone": 5}],
		"objectives": [{"kind": "hold_zone", "zone": OBJ_ZONE, "hold_sec": 100.0}],
	})
	var loses := 0
	var last2: Dictionary = {}
	_set_owner(w2, 5, "E1")
	for i in 30:
		for e in w2.tick(0.1):
			var ev2: Dictionary = e
			if String(ev2.get("type", "")) == "level_end":
				loses += 1
				last2 = ev2
	eq(loses, 1, "★ 判负也只播报一次")
	eq(String(last2.get("result", "")), "lose", "事件带 result = lose")
	eq(String(last2.get("reason", "")), "zone_lost:5", "事件带原因")

	# world.reset() 之后去重标记要归零（重开一局还能再播报）
	w2.reset("F1", ["F1"])
	eq(String(w2.objective_state["state"]), "running", "reset 之后目标状态回到 running")
	eq(w2._objective_reported, "", "reset 之后「已播报」标记归零")


# ------------------------------------------------------------------
# 工具
# ------------------------------------------------------------------

## 造一个单人世界（F1），关卡数据 = 样例关卡 + patch。
func _make_world(cfg, patch: Dictionary):
	var lv = _make_level(cfg, "solo_lv", patch)
	if lv == null:
		return null
	return WorldRes.create_from_level(cfg, lv, "F1", ["F1"], true)


## 造一个双人世界（F1 + F2，同方）。
##
## ⚠️ `factions` 里**不要**给 F1 / F2 写 `ai`：写了（哪怕写 `none`）就等于
##   「关卡点名让这两方在这一局不动」，它们就不会被算进守方席位
##   （`world._setup_ai_factions()` 只把「本机在操作的」与「有 AI 的」分清楚）。
##   这里要造的是**两个真人合作**，所以只留一个 NPC 敌人 E1 当陪练。
func _make_world_coop(cfg):
	var lv = _make_level(cfg, "coop_lv", {
		"mode": "coop",
		"players": [{"faction": "F1", "base": [5, 10]}, {"faction": "F2", "base": [5, 1]}],
		"factions": [{"id": "E1", "ai": "faction", "base": [18, 10]}],
		"allies": [["F1", "F2"]],
		"zones": [{"id": OBJ_ZONE, "owner": "F1"}],
		"objectives": [{"kind": "hold_zone", "zone": OBJ_ZONE, "hold_sec": 1000.0}],
		"fail_conditions": [],
	})
	if lv == null:
		return null
	return WorldRes.create_from_level(cfg, lv, "F1", ["F1", "F2"], true)


## 用**样例关卡**做模板、按 patch 改字段，写成临时关卡文件再走真实载入路径。
func _make_level(cfg, name: String, patch: Dictionary):
	var raw := _read_json("%s/levels/01_beachhead.json" % DEMO_DIR)
	if raw.is_empty():
		return null
	for k in patch.keys():
		raw[k] = patch[k]
	var lvdir := "%s/%s" % [TMP_ROOT, name]
	_write("%s/campaign.json" % lvdir, JSON.stringify({"levels": [{"file": "levels/l.json"}]}))
	_write("%s/levels/l.json" % lvdir, JSON.stringify(raw))
	var c = CampaignRes.load_campaign(lvdir, cfg)
	if c == null:
		return null
	return c.level_at(0)


## 直接把某个区划的归属改掉（**测试专用**：绕开占领规则，模拟「这一帧它被拿走了」）。
##
## ⚠️ 区划是**字典**（`{"owner": …, "progress": …, "capture_faction": …}`），
##    不是 RefCounted —— 别写成 `z.owner = …`（那是另一个对象的语法）。
func _set_owner(w, zid: int, owner: String) -> void:
	var z = w.zone_by_id(zid)
	if z == null:
		return
	var d: Dictionary = z
	d["owner"] = owner
	d["capture_faction"] = ""
	d["capture_state"] = ""
	d["progress"] = 0.0


## 把一栋建筑真的从世界里拆掉（= 战斗结算那一刻）。
##
## ⚠️ 为什么不用 `take_damage`：**大本营故意是不可摧毁的**
##   （`building.take_damage` 里 `cfg.destructible_base` 为 false 时血量地板是 1）——
##   那是配置里的开关，不是本用例要验的东西。这里直接复刻
##   `world._collect_destroyed_buildings()` 那一步：标死 + 摘出列表。
func _kill_building(w, b) -> void:
	if b == null:
		return
	b.alive = false
	b.hp = 0.0
	w.remove_building(b, true)


func _owner(w, zid: int) -> String:
	var z = w.zone_by_id(zid)
	if z == null:
		return ""
	return String((z as Dictionary)["owner"])


func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var t := f.get_as_text()
	f.close()
	var v: Variant = JSON.parse_string(t)
	if typeof(v) != TYPE_DICTIONARY:
		return {}
	return v


func _write(path: String, text: String) -> void:
	var dir := path.get_base_dir()
	if dir != "":
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		ok(false, "能写临时文件：%s" % path)
		return
	f.store_string(text)
	f.close()


func _clean_tmp() -> void:
	if DirAccess.dir_exists_absolute(TMP_ROOT):
		_remove_dir(TMP_ROOT)


func _remove_dir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if d.current_is_dir():
			_remove_dir("%s/%s" % [path, n])
		else:
			DirAccess.remove_absolute("%s/%s" % [path, n])
		n = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)
