## test_all_levels_outcome.gd —— ★★ 「所有关卡都有胜负判定」的验收（本轮新增）
##
## 逐关 × 逐可玩阵营地建一遍世界，确认四件事：
##   1. 每一关的每一个可玩阵营都有 `objective_state`（kind = hold_zone / capture_zone）；
##   2. 玩家席位的大本营真的存在；
##   3. **完成目标** ⇒ `won`（守住类：把 held 推到阈值；攻占类：把归属翻过来）；
##   4. **大本营丢失** ⇒ `lost`（两种目标都必须判负）、
##      **目标失败** ⇒ `lost`（守住类：目标区划失守；攻占类：额外失败区划失守）。
##
## ★ 为什么需要它：`logic/objective.gd` 的 `capture_zone` 分支曾经提前 return，
##   于是「攻占方的大本营被拆 / 额外失败条件」永远不判负 —— 单测 test_outcome 里
##   补了通用用例，这里再从**真实关卡数据**跑一遍，防止某一关的配置把它绕过去。
extends "res://tests/test_case.gd"

const CampaignLibraryRes = preload("res://logic/campaign_library.gd")
const WorldRes = preload("res://logic/world.gd")
const ObjectiveRes = preload("res://logic/objective.gd")

func _initialize() -> void:
	_case_name = "test_all_levels_outcome"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	var options: Array = CampaignLibraryRes.list_campaigns(cfg)
	ok(not options.is_empty(), "扫描到至少一个战役（否则这条测试没有意义）")
	var checked := 0
	for opt in options:
		var c = CampaignLibraryRes.load_campaign_by_option(opt, cfg)
		ok(c != null, "战役可载入：%s" % String((opt as Dictionary).get("id", "")))
		if c == null:
			continue
		for i in c.level_count():
			var lv = c.level_at(i)
			ok(lv != null, "关卡可载入：%s 第 %d 关" % [String(c.id), i])
			if lv == null:
				continue
			var seats: Array = lv.playable_ids()
			ok(not seats.is_empty(), "关卡 %s/%s 有可玩阵营" % [String(c.id), String(lv.id)])
			for seat in seats:
				_check_level(cfg, c, lv, String(seat))
				checked += 1
	ok(checked > 0, "至少验收了一个「关卡 × 可玩阵营」组合")

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _check_level(cfg, c, lv, seat: String) -> void:
	var tag := "%s/%s/%s" % [String(c.id), String(lv.id), seat]
	var roster: Array = lv.build_roster(cfg, seat)
	var w = WorldRes.create_from_level(cfg, lv, seat, roster, true)
	ok(w != null, "%s 能建出世界" % tag)
	if w == null:
		return

	var st: Dictionary = w.objective_state
	ok(not st.is_empty(), "%s 有 objective_state" % tag)
	var kind := String(st.get("kind", ""))
	ok(kind == "hold_zone" or kind == "capture_zone",
		"%s 目标种类是 hold_zone / capture_zone（实际 %s）" % [tag, kind])
	eq(String(st.get("state", "")), "running", "%s 开局进行中" % tag)
	var defend: Array = st.get("defend", [])
	ok(not defend.is_empty(), "%s 有守方席位" % tag)
	for d in defend:
		ok(w.find_base_of(String(d)) != null, "%s 玩家席位 %s 有大本营" % [tag, String(d)])
	var zone := int(st.get("zone", -1))

	# ---- 1) 完成目标 ⇒ 胜 ----
	w.reset(seat, roster)
	st = w.objective_state
	_set_owner(w, zone, seat)
	if kind == "hold_zone":
		st["held"] = float(st.get("sec", 0.0))
	ObjectiveRes.update(w, cfg, st, 0.1)
	eq(String(st.get("state", "")), "won", "%s ★ 完成目标判胜" % tag)

	# ---- 2) 大本营丢失 ⇒ 负（hold / capture 都必须判）----
	w.reset(seat, roster)
	st = w.objective_state
	var home_base = w.find_base_of(String(defend[0]))
	ok(home_base != null, "%s 能拿到玩家大本营（准备拆）" % tag)
	if home_base != null:
		_kill_building(w, home_base)
		ObjectiveRes.update(w, cfg, st, 0.5)
		eq(String(st.get("state", "")), "lost", "%s ★ 大本营丢失判负" % tag)
		eq(String(st.get("reason", "")), ObjectiveRes.R_BASE_DESTROYED,
			"%s 判负原因是 base_destroyed" % tag)

	# ---- 3) 目标失败 ⇒ 负 ----
	w.reset(seat, roster)
	st = w.objective_state
	if kind == "hold_zone":
		_set_owner(w, zone, "")
		ObjectiveRes.update(w, cfg, st, 0.5)
		eq(String(st.get("state", "")), "lost", "%s ★ 目标区划失守判负" % tag)
		eq(String(st.get("reason", "")), ObjectiveRes.R_OBJECTIVE_LOST,
			"%s 判负原因是 objective_lost" % tag)
	else:
		var fail: Array = st.get("fail", [])
		if fail.is_empty():
			# 攻占类的设计：丢目标**不算输**（允许反复争夺）；只验它确实继续。
			_set_owner(w, zone, "")
			ObjectiveRes.update(w, cfg, st, 0.5)
			eq(String(st.get("state", "")), "running",
				"%s 攻占类丢目标不算输（设计如此）" % tag)
		else:
			var fz := int(fail[0])
			_set_owner(w, fz, "")
			ObjectiveRes.update(w, cfg, st, 0.5)
			eq(String(st.get("state", "")), "lost", "%s ★ 额外失败区划失守判负" % tag)
			eq(String(st.get("reason", "")), "zone_lost:%d" % fz,
				"%s 判负原因带区划号" % tag)


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
