## test_campaign_seats.gd —— **「选边关」**（一关两个可玩阵营，选一个来打）的断言。
extends "res://tests/test_case.gd"

const CampaignRes = preload("res://logic/campaign.gd")
const WorldRes = preload("res://logic/world.gd")
const ObjectiveRes = preload("res://logic/objective.gd")
const BuildingRes = preload("res://logic/building.gd")
const FactionRes = preload("res://logic/faction.gd")
const LevelRes = preload("res://logic/level.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const LEVEL_ID := "01_beachhead"
const OBJ_ZONE := 4

func _initialize() -> void:
	run_all(Callable(self, "_run"))

func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_group_data(cfg)
	_group_objective_pick(cfg)
	_group_ai_swap(cfg)
	_group_escort(cfg)
	_group_centers(cfg)
	_group_base_loss(cfg)
	_group_capture(cfg)
	_group_ai_ally_acts(cfg)
	_group_player_units_have_no_ai(cfg)

func _group_player_units_have_no_ai(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var base_level = camp.level(LEVEL_ID)
	if base_level == null:
		ok(false, "（前提）样例第一关能载入")
		return
	var obj_zone := int(base_level.objective_zone())

	var units: Array = []
	var y_off := {"F1": 10, "F2": 12}
	for fid in ["F1", "F2"]:
		for i in 3:
			units.append({"faction": fid, "kind": "enemy", "x": 4 + i, "y": int(y_off[fid]),
				"ai": "general", "zone": obj_zone, "name": "越权守军"})
	base_level.start_units = units

	for seat in ["F1", "F2"]:
		var w = _world(cfg, base_level, String(seat))
		ok(w != null, "[%s] 能建出世界" % seat)
		if w == null:
			continue
		var mine := _player_seat(w)
		var checked := 0
		var leaked: Array = []
		var ai_side_ok := 0
		for u in w.units:
			if not u.alive:
				continue
			var fid := String(u.faction)
			var is_garrison: bool = int(u.garrison_zone_id) >= 0
			if fid == mine:
				checked += 1
				if is_garrison or bool(u.hold_position):
					leaked.append("%s(gz=%d hold=%s)" % [String(u.id),
						int(u.garrison_zone_id), str(u.hold_position)])
			elif fid == "F1":
				if is_garrison:
					ai_side_ok += 1
		ok(checked > 0, "[%s] 场上真有本机那一方的单位（否则这段白测）" % seat)
		eq(leaked.size(), 0,
			"★★ [%s] 本机（%s）的单位**一个都不带** garrison / hold（漏的：%s）"
			% [seat, mine, str(leaked)])
		if String(seat) == "F2":
			ok(ai_side_ok > 0,
				"★ [%s] 对照组：由 AI 接管的 F1 照样拿到归属（%d 个，别修过头）"
				% [seat, ai_side_ok])
		for u in w.units:
			if String(u.faction) == mine:
				ok(not u.is_garrison(), "★ [%s] %s 不是「驻防单位」" % [seat, String(u.id)])
				break

func _player_seat(w) -> String:
	return String(w.my_faction)

func _group_data(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	ok(camp != null, "样例战役能载入")
	if camp == null:
		return
	eq(camp.playable_ids(), ["F1", "F2"], "★ 战役里可玩的是两个阵营（蓝方 F1 / 红方 F2）")

	var lv = camp.level(LEVEL_ID)
	ok(lv != null, "第一关能载入")
	if lv == null:
		return
	eq(lv.playable_ids(), ["F1", "F2"], "★ 第一关可选的两个阵营")
	ok(lv.has_per_faction_objectives(), "★ 这一关是「选边关」（目标按阵营分开）")

	FactionRes.set_allies(lv.effective_allies())
	ok(not FactionRes.same_side_for_attack("F1", "F2"),
		"★ 蓝方与红方是敌对关系（选边关的设计前提）")

	var blocks: Array = lv.blockers()
	var detail := ""
	for b in blocks:
		detail += " / %s" % String((b as Dictionary)["msg"])
	ok(blocks.is_empty(), "样例第一关没有拦截项%s" % detail)
	eq(lv.check(cfg.ai_factions()).size(), 0, "样例第一关连警告都没有")

func _group_objective_pick(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID)

	eq(String(lv.objective_of("F1")["kind"]), "hold_zone", "★ 蓝方的目标是**守住** c1")
	eq(String(lv.objective_of("F2")["kind"]), "capture_zone", "★ 红方的目标是**攻占** c1")
	eq(int(lv.objective_of("F1")["zone"]), OBJ_ZONE, "蓝方守的是 c1")
	eq(int(lv.objective_of("F2")["zone"]), OBJ_ZONE, "红方攻的也是 c1（同一个区划）")
	ok(lv.objective_for("ZZ") == null,
		"★ 没点名给某一方、也没有通用那一条时 → null（**不退回第一条**）")

	ok(lv.objective_label("F1").contains("守"), "蓝方那句话是「守住…」")
	ok(lv.objective_label("F2").contains("占领"), "红方那句话是「占领…」")

	var w1 = _world(cfg, lv, "F1")
	if w1 != null:
		eq(String(w1.objective_state["kind"]), "hold_zone", "★ 选蓝方 → 打的是「守住」那条")
		eq(String(w1.objective_state["state"]), "running", "开局是进行中")
	var w2 = _world(cfg, lv, "F2")
	if w2 != null:
		eq(String(w2.objective_state["kind"]), "capture_zone", "★ 选红方 → 打的是「攻占」那条")
		eq(String(w2.objective_state["state"]), "running",
			"★ 红方开局**不判负也不判胜**（c1 在蓝方手里，得自己打下来）")
		eq(w2.objective_state["defend"], ["F2"], "★ 守方席位只有本机操作的 F2")

func _group_ai_swap(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID)

	var w1 = _world(cfg, lv, "F1")
	ok(w1 != null, "选蓝方能建出世界")
	if w1 != null:
		ok(_piloted(w1).has("F2") and not _piloted(w1).has("F1"),
			"★ 选蓝方 → 红方 F2 由 AI 接管、本机 F1 **不在** AI 名单里（运行时摘掉）")
		eq(w1.player_factions, ["F1"], "★ 本机操作的是 F1")
		eq(w1.player_seats, ["F1", "F2"], "两个席位都在本机（两个家都要建出来）")
		ok(w1.faction_bases.has("F2"), "★ 没被选中的红方照样有大本营（在地图上真的存在）")
		ok(w1.resource_pool_for("F2") != null, "红方有 AI 资源池（它要招兵出兵）")

	var w2 = _world(cfg, lv, "F2")
	ok(w2 != null, "选红方能建出世界")
	if w2 != null:
		ok(_piloted(w2).has("F1") and not _piloted(w2).has("F2"),
			"★ 选红方 → 蓝方 F1 由 AI 接管、本机 F2 **不在** AI 名单里")
		eq(w2.player_factions, ["F2"], "★ 本机操作的是 F2")
		ok(w2.player_seats.has("F1") and w2.player_seats.has("F2"),
			"席位名单里两边都在（两个家都要建出来；顺序 = 我选的那一方在前）")
		ok(w2.faction_bases.has("F1"), "没被选中的蓝方照样有大本营")
		var garrisoned := 0
		var generals := 0
		for u in w2.units:
			if not u.alive or String(u.faction) != "F1":
				continue
			var k := String(u.kind)
			if k == "general" or k.begins_with("general_"):
				generals += 1
				if int(u.garrison_zone_id) >= 0:
					garrisoned += 1
		ok(generals > 0 and garrisoned == generals,
			"★ 蓝方（守家 AI）的将领都拿到了归属区划（%d/%d）" % [garrisoned, generals])

	if w1 != null and w2 != null:
		ok(_piloted(w1) != _piloted(w2), "★ 选蓝方与选红方的 AI 名单不一样")
		ok(not _piloted(w1).has("F1") and not _piloted(w2).has("F2"),
			"★ 选中哪一方，那一方就**不在** AI 名单里（运行时摘掉）")

	if w2 != null:
		var mine: Variant = w2.resource_pool_for("F2")
		var foe: Variant = w2.resource_pool_for("F1")
		ok(mine != null and foe != null, "两方都有资源池")
		ok(not is_same(mine, foe), "★ 本机钱包与对手的池子**不是同一个对象**")
		ok(is_same(mine, w2.resources),
			"★★ 本机席位的池子就是 `world.resources`（HUD 与扣费必须是同一份数）")

func _group_escort(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID)

	for seat in ["F1", "F2"]:
		var w = _world(cfg, lv, String(seat))
		if w == null:
			continue
		ok(w.units.size() > 0, "[%s] 世界里有单位" % seat)
		var foe := "F2" if String(seat) == "F1" else "F1"
		var placed: Array = lv.placed_units_for(foe)
		for u in placed:
			var ud: Dictionary = u
			var at := Vector2i(int(ud.get("x", -1)), int(ud.get("y", -1)))
			var found := false
			for wu in w.units:
				if String(wu.faction) == foe and wu.alive and Vector2i(wu.tx, wu.ty) == at:
					found = true
					break
			ok(found, "★★ [%s] 关卡给对手摆的单位 (%d,%d) 真的出现在场上（AI 摆的也算）"
				% [seat, at.x, at.y])
		var checked := 0
		for u in placed:
			var ud2: Dictionary = u
			var ei: int = LevelRes.escort_leader_index(ud2)
			if ei < 0:
				continue
			checked += 1
			var at2 := Vector2i(int(ud2.get("x", -1)), int(ud2.get("y", -1)))
			var sub = null
			for wu2 in w.units:
				if String(wu2.faction) == foe and Vector2i(wu2.tx, wu2.ty) == at2:
					sub = wu2
					break
			ok(sub != null, "（前提）找到那一格的附属兵")
			if sub == null:
				continue
			var want_ld: String = w.escort_of_index(foe, ei)
			eq(String(sub.leader_id), want_ld,
				"★★ [%s] escort_of=%d 的兵挂在 %s 上" % [seat, ei + 1, want_ld])
			var ld = w.unit_by_id(want_ld)
			ok(ld != null, "★★ [%s] 那位将领真的在场（%s）" % [seat, want_ld])
		ok(checked >= 0, "[%s] 对手摆了 %d 个附属兵（逐条验过）" % [seat, checked])
		var seen_ids: Dictionary = {}
		var dup := 0
		for wu3 in w.units:
			if String(wu3.faction) != foe or not wu3.alive:
				continue
			if seen_ids.has(String(wu3.id)):
				dup += 1
			seen_ids[String(wu3.id)] = true
		eq(dup, 0,
			"★★ [%s] 对手的单位 id 不重复（摆了将领就不该再自动生成一批同 id 的）" % seat)

func _group_centers(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID)
	var w = _world(cfg, lv, "F1")
	if w == null:
		return
	var missing: Array = []
	for z in w.zones.zones:
		var zd: Dictionary = z
		var c: Variant = zd["center"]
		if c == null:
			continue
		var t: Vector2i = c
		var b = w.building_at(t.x, t.y)
		if b == null or String(b.type) != BuildingRes.TYPE_ZONE_CENTER:
			var what := "空"
			if b != null:
				what = String(b.type)
			missing.append("c%d(%d,%d)=%s" % [int(zd["id"]), t.x, t.y, what])
	ok(missing.is_empty(), "★ 每个区划中心都建出来了（缺：%s）" % str(missing))

func _group_base_loss(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID)

	var w = _world(cfg, lv, "F1")
	if w == null:
		return
	var st: Dictionary = w.objective_state
	eq(st["defend"], ["F1"], "★ 守方席位只有本机操作的那一方")

	_kill_base(w, "F1")
	ObjectiveRes.update(w, cfg, st, 0.5)
	eq(String(st["state"]), "lost", "★ 拆掉自己席位的家 → 判负")
	eq(String(st["reason"]), ObjectiveRes.R_BASE_DESTROYED, "原因是 base_destroyed")

	var w2 = _world(cfg, lv, "F1")
	if w2 == null:
		return
	var st2: Dictionary = w2.objective_state
	ok(w2.find_base_of("F2") == null, "★ 被 AI 接管的对手 F2 没有大本营（本轮口径）")
	ObjectiveRes.update(w2, cfg, st2, 0.5)
	eq(String(st2["state"]), "running",
		"★ 对手的家不在守方席位里 → 不判负")

func _group_capture(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID)
	var w = _world(cfg, lv, "F2")
	if w == null:
		return
	var st: Dictionary = w.objective_state
	eq(String(st["kind"]), "capture_zone", "红方打的是攻占目标")
	var before := _owner(w, OBJ_ZONE)
	ok(before != "F2", "（前提）c1 开局不归红方（实际 %s）" % before)

	_set_owner(w, OBJ_ZONE, "F2")
	ObjectiveRes.update(w, cfg, st, 0.1)
	eq(String(st["state"]), "won", "★ 归属一翻过来就**立刻判胜**")
	eq(String(st["reason"]), "", "胜局没有原因")

	var w2 = _world(cfg, lv, "F2")
	if w2 == null:
		return
	var st2: Dictionary = w2.objective_state
	ObjectiveRes.update(w2, cfg, st2, 0.5)
	eq(String(st2["state"]), "running", "★ 没打下来之前一直进行中")

func _group_ai_ally_acts(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID)
	var w = _world(cfg, lv, "F1")
	if w == null:
		return
	ok(_piloted(w).has("F2"), "★ 选蓝方时红方 F2 由 AI 接管")
	var g2 := 0
	for u in w.units:
		if u.alive and String(u.faction) == "F2" and u.is_general():
			g2 += 1
	ok(g2 > 0, "红方有将领（%d 位）—— 阵地性 AI 靠它巡逻 / 招兵" % g2)

func _world(cfg, lv, seat: String):
	return WorldRes.create_from_level(cfg, lv, seat, lv.build_roster(cfg, seat), true)

func _piloted(w) -> Array:
	var out: Array = []
	for f in w.factions:
		if String(f) == String(w.my_faction):
			continue
		if w.ai_kind_of(String(f)) != "none":
			out.append(String(f))
	return out

func _unit_count(w, fid: String) -> int:
	var n := 0
	for u in w.units:
		if u.alive and String(u.faction) == fid:
			n += 1
	return n

func _general_count(w, fid: String) -> int:
	var n := 0
	for u in w.units:
		if not u.alive or String(u.faction) != fid:
			continue
		var k := String(u.kind)
		if k == "general" or k.begins_with("general_"):
			n += 1
	return n

func _escort_count(w, fid: String) -> int:
	var n := 0
	for u in w.units:
		if not u.alive or String(u.faction) != fid:
			continue
		if String(u.leader_id) != "":
			n += 1
	return n

func _kill_base(w, fid: String) -> void:
	var b = w.find_base_of(fid)
	if b == null:
		ok(false, "（前提）%s 有大本营" % fid)
		return
	b.alive = false
	b.hp = 0.0
	w.remove_building(b, true)

func _owner(w, zid: int) -> String:
	var z = w.zone_by_id(zid)
	if z == null:
		return ""
	return String((z as Dictionary)["owner"])

func _set_owner(w, zid: int, owner: String) -> void:
	var z = w.zone_by_id(zid)
	if z == null:
		return
	var d: Dictionary = z
	d["owner"] = owner
	d["capture_faction"] = ""
	d["capture_state"] = ""
	d["progress"] = 0.0
