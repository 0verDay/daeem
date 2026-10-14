## test_outcome.gd —— **目标与胜负**断言（dev_plan_7 M7.1：`logic/objective.gd`）。
extends "res://tests/test_case.gd"

const CampaignRes = preload("res://logic/campaign.gd")
const LevelRes = preload("res://logic/level.gd")
const WorldRes = preload("res://logic/world.gd")
const ObjectiveRes = preload("res://logic/objective.gd")
const BuildingRes = preload("res://logic/building.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const TMP_ROOT := "res://.tmp_outcome_tests"
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

	ObjectiveRes.update(w, cfg, st, 1.0)
	near(float(st["held"]), 1.0, 0.001, "目标归自己时 held += dt")
	ObjectiveRes.update(w, cfg, st, 0.5)
	near(float(st["held"]), 1.5, 0.001, "多次 update 累加")
	eq(String(st["state"]), "running", "还没守满 → 仍在进行中")

	ObjectiveRes.update(w, cfg, st, 20.0)
	eq(String(st["state"]), "won", "★ 跨过 hold_sec 的那一帧立刻判胜")
	near(float(st["held"]), 10.0, 0.001, "held 被夹在 hold_sec（不显示 21.5/10）")
	ok(ObjectiveRes.is_over(st), "结算后 is_over = true")
	near(ObjectiveRes.progress_ratio(st), 1.0, 0.001, "进度条到 100%")

	ObjectiveRes.update(w, cfg, st, 100.0)
	eq(String(st["state"]), "won", "结算后不再改判")

	eq(ObjectiveRes.reason_label(st), "", "胜局没有判负原因")

func _group_lose_zone(cfg) -> void:
	var w = _make_world(cfg, {"objectives": [{"kind": "hold_zone", "zone": OBJ_ZONE, "hold_sec": 100.0}]})
	if w == null:
		return
	var st: Dictionary = w.objective_state
	ObjectiveRes.update(w, cfg, st, 5.0)
	near(float(st["held"]), 5.0, 0.001, "先守住 5 秒")

	_set_owner(w, OBJ_ZONE, "E1")
	ObjectiveRes.update(w, cfg, st, 0.5)
	eq(String(st["state"]), "lost", "★ 目标区划一丢掉就判负")
	eq(String(st["reason"]), ObjectiveRes.R_OBJECTIVE_LOST, "原因是 objective_lost")
	near(float(st["held"]), 5.0, 0.001, "丢掉那一刻 held 不再增加（也没有被清零）")
	eq(ObjectiveRes.reason_label(st), "目标区划失守", "判负原因有人话文案")

	var w2 = _make_world(cfg, {"objectives": [{"kind": "hold_zone", "zone": OBJ_ZONE, "hold_sec": 100.0}]})
	var st2: Dictionary = w2.objective_state
	_set_owner(w2, OBJ_ZONE, "")
	ObjectiveRes.update(w2, cfg, st2, 0.5)
	eq(String(st2["state"]), "lost", "★ 目标区划变成无主也算丢")
	eq(String(st2["reason"]), ObjectiveRes.R_OBJECTIVE_LOST, "无主也是 objective_lost")

	var w3 = _make_world(cfg, {"objectives": [{"kind": "hold_zone", "zone": OBJ_ZONE, "hold_sec": 100.0}]})
	var st3: Dictionary = w3.objective_state
	_set_owner(w3, OBJ_ZONE, "E1")
	ObjectiveRes.update(w3, cfg, st3, 1.0)
	_set_owner(w3, OBJ_ZONE, "F1")
	ObjectiveRes.update(w3, cfg, st3, 1.0)
	near(float(st3["held"]), 0.0, 0.001, "丢掉那一帧之后就不再累加（抢回来也不算）")

func _group_base(cfg) -> void:
	var w = _make_world(cfg, {"objectives": [{"kind": "hold_zone", "zone": OBJ_ZONE, "hold_sec": 100.0}]})
	if w == null:
		return
	var st: Dictionary = w.objective_state
	ok(w.find_base_of("F1") != null, "开局 F1 有大本营")

	var base = w.find_base_of("F1")
	ok(base != null, "开局 F1 有大本营")
	if base == null:
		return
	_kill_building(w, base)
	ObjectiveRes.update(w, cfg, st, 0.5)
	eq(String(st["state"]), "lost", "★ 大本营被拆 → 判负")
	eq(String(st["reason"]), ObjectiveRes.R_BASE_DESTROYED, "原因是 base_destroyed")
	eq(ObjectiveRes.reason_label(st), "大本营被拆", "判负原因有人话文案")

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

	var w2b = _make_world_coop(cfg)
	var st2b: Dictionary = w2b.objective_state
	st2b["defend"] = ["F1"]
	var b2only = w2b.find_base_of("F2")
	_kill_building(w2b, b2only)
	ObjectiveRes.update(w2b, cfg, st2b, 0.5)
	eq(String(st2b["state"]), "running",
		"★ 只拆掉**盟友 AI** 的家 → 不判负（它不在守方席位里）")

	var w3 = _make_world(cfg, {"objectives": [{"kind": "hold_zone", "zone": OBJ_ZONE, "hold_sec": 100.0}]})
	var st3: Dictionary = w3.objective_state
	var eb = w3.find_base_of("F2")
	ok(eb == null, "★ AI 阵营 F2 没有大本营（本轮口径）")
	ObjectiveRes.update(w3, cfg, st3, 0.5)
	eq(String(st3["state"]), "running", "拆敌方的家不判负（判据只看玩家席位）")

func _group_extra_fail(cfg) -> void:
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

func _group_setup_guard(cfg) -> void:
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
	ObjectiveRes.update(w, cfg, st, 1.0)
	eq(String(st["reason"]), ObjectiveRes.R_OBJECTIVE_NEVER, "结算后不再改判")

	var w2 = _make_world(cfg, {
		"zones": [{"id": OBJ_ZONE, "owner": ""}],
		"objectives": [{"kind": "hold_zone", "zone": OBJ_ZONE, "hold_sec": 100.0}],
	})
	eq(String(w2.objective_state["state"]), "lost", "★ 目标区划开局无主 → 立刻判负")
	eq(String(w2.objective_state["reason"]), ObjectiveRes.R_OBJECTIVE_NEVER, "同样留痕迹")

func _group_no_level(cfg) -> void:
	var w = WorldRes.create(cfg, "res://data/maps/frontier/map.json", false)
	ok(w != null, "老入口照样能建世界")
	if w == null:
		return
	eq(w.level, null, "老入口的 world.level 是 null")
	ok(w.objective_state.has("kind"), "老入口也有一份 objective_state（空状态）")
	eq(String(w.objective_state["kind"]), "", "★ 空状态：kind 是空串（没有目标）")
	eq(String(w.objective_state["state"]), "running", "空状态永远是 running（不会自己判负）")
	var ends := 0
	for i in 200:
		for e in w.tick(0.1):
			if String((e as Dictionary).get("type", "")) == "level_end":
				ends += 1
	eq(ends, 0, "★ 没有目标的一局永远不发 level_end")
	eq(String(w.objective_state["kind"]), "", "没有目标的一局状态没被改")
	ok(not ObjectiveRes.is_over(w.objective_state), "没有目标的一局不算结算")

	ok(WorldRes.create_from_level(cfg, null, "F1", [], false) == null,
		"create_from_level(null) 明确失败（不静默）")

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

	w2.reset("F1", ["F1"])
	eq(String(w2.objective_state["state"]), "running", "reset 之后目标状态回到 running")
	eq(w2._objective_reported, "", "reset 之后「已播报」标记归零")

func _make_world(cfg, patch: Dictionary):
	var lv = _make_level(cfg, "solo_lv", patch)
	if lv == null:
		return null
	return WorldRes.create_from_level(cfg, lv, "F1", ["F1"], true)

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

func _set_owner(w, zid: int, owner: String) -> void:
	var z = w.zone_by_id(zid)
	if z == null:
		return
	var d: Dictionary = z
	d["owner"] = owner
	d["capture_faction"] = ""
	d["capture_state"] = ""
	d["progress"] = 0.0

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
