## test_snapshot_coop.gd —— M12.2：合作快照新增字段的往返与「缺字段 = 保持现状」。
extends "res://tests/test_case.gd"

const CampaignRes = preload("res://logic/campaign.gd")
const WorldRes = preload("res://logic/world.gd")
const SnapshotRes = preload("res://logic/snapshot.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const LEVEL_ID := "02_twin_line"

func _initialize() -> void:
	_case_name = "test_snapshot_coop"
	run_all(Callable(self, "_run"))


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID) if camp != null else null
	if lv == null:
		ok(false, "（前提）合作关能载入")
		return
	var host = WorldRes.create_from_level(cfg, lv, "F1", lv.coop_roster(), true)
	var guest = WorldRes.create_from_level(cfg, lv, "F2", lv.coop_roster(), true)
	if host == null or guest == null:
		ok(false, "（前提）两个世界能建出来")
		return

	# ---- 造一组「和开局不一样」的权威状态，确保不是拿默认值蒙混过关 ----
	host.player_resources["F1"]["food"] = 111.0
	host.player_resources["F1"]["gold"] = 222.0
	host.player_resources["F2"]["food"] = 333.0
	host.player_resources["F2"]["gold"] = 444.0
	host.objective_state["held"] = 42.0
	host.objective_state["state"] = "running"
	var base = host.find_base_of("F1")
	ok(base != null, "（前提）F1 有大本营")
	if base != null:
		base.level = 2
		base.hp_max = 999.0
		base.upgrade_remaining = 3.0
		base.upgrade_total = 5.0
		# ★ 大本营重生队列（本轮新增）：造一条「和默认不一样」的状态。
		base.enqueue_respawn(host.units[0], 7.0)
		base.respawn_remaining = 4.0
	var zone = _zone_owned_by(host, "F1")
	ok(zone != null, "（前提）F1 占着一块区")
	if zone != null:
		zone["spec_done"] = "food"
		zone["spec_kind"] = "gold"
		zone["spec_remaining"] = 2.0
		zone["spec_total"] = 10.0
		zone["spec_cancel"] = false
	var tech_id := ""
	for item in host.tech_list():
		tech_id = String((item as Dictionary).get("id", ""))
		if tech_id != "":
			break
	if tech_id != "":
		ok(host.set_tech_active(tech_id, true, "F2"), "（前提）F2 能启用一条科技")

	var snap: Dictionary = SnapshotRes.to_snapshot(host)
	ok(snap.has("pres"), "★ 快照带按席位资源 pres")
	ok(snap.has("obj"), "★ 快照带目标 obj")
	ok(snap.has("tech"), "★ 快照带科技 tech")
	# ★★ 将领招募池 / 冷却：先造一个**和默认不一样**的「已拥有」集合 + 冷却。
	var host_pool: Dictionary = host.general_recruit_pools["F1"]
	host_pool["taken"] = ["general_1", "general_4"]
	host_pool["cooldown"] = 12.5
	host_pool["cooldown_total"] = 30.0
	snap = SnapshotRes.to_snapshot(host)
	ok(snap.has("gp"), "★ 快照带将领招募池 gp")
	ok(snap["gp"].has("F1") and snap["gp"].has("F2"), "gp 有房主与客机两份")
	ok(snap["pres"].has("F1") and snap["pres"].has("F2"), "pres 有房主与客机两份")
	var b0: Dictionary = snap["buildings"][0]
	ok(b0.has("lv") and b0.has("mh") and b0.has("ur") and b0.has("ut"),
		"★ 建筑带等级 / 血量上限 / 升级读条")
	var z0: Dictionary = snap["zones"][int(zone["id"])] if zone != null else {}
	if zone != null:
		ok(z0.has("sk") and z0.has("sr") and z0.has("st") and z0.has("sd"),
			"★ 区划带特化读条 / 已完成特化")

	SnapshotRes.apply_snapshot(guest, cfg, snap)
	guest.refresh_after_snapshot()

	eq(float(guest.resource_pool_for("F1")["food"]), 111.0, "★ 客机看到房主的钱是房主那份")
	eq(float(guest.resource_pool_for("F2")["food"]), 333.0, "★★ 客机自己的钱是客机那份")
	eq(float(guest.resources["gold"]), 444.0, "★★ world.resources 指向客机自己那一份")
	eq(float(guest.objective_state["held"]), 42.0, "★ 目标进度写回客机")
	eq(String(guest.objective_state["kind"]), "hold_zone", "★ 目标种类写回客机")
	if tech_id != "":
		ok(guest.active_tech_ids("F2").has(tech_id), "★ 客机的科技高亮状态写回")
	ok(guest.general_recruit_owned("F1", "general_1"), "★ 客机看到 #1 已拥有")
	ok(guest.general_recruit_owned("F1", "general_4"), "★ 客机看到 #4 已拥有")
	ok(not guest.general_recruit_owned("F1", "general_2"), "★ 未招过的 #2 仍可招募")
	near(guest.general_recruit_cooldown_left("F1"), 12.5, 1e-6,
		"★ 客机看到同一个招募冷却剩余")
	near(guest.general_recruit_cooldown_total("F1"), 30.0, 1e-6,
		"★ 总冷却时长也写回（界面画「已过 / 总」）")
	if base != null:
		var gb = guest.find_base_of("F1")
		ok(gb != null, "（前提）客机也有 F1 大本营")
		if gb != null:
			eq(gb.level, 2, "★ 建筑等级写回")
			eq(gb.hp_max, 999.0, "★ 建筑血量上限写回")
			near(gb.upgrade_remaining, 3.0, 0.001, "★ 建筑升级剩余写回")
			ok(gb.is_respawning(), "★★ 客机也看到大本营在重生")
			eq(gb.respawn_count(), 1, "★ 重生队列人数写回")
			near(gb.respawn_eta(), 4.0, 0.001, "★ 重生剩余秒数写回")
			eq(gb.respawn_current_name(), String(host.units[0].name),
				"★ 正在重生的将领名字写回")
	if zone != null:
		var gz = _zone_owned_by(guest, "F1")
		ok(gz != null, "（前提）客机也有 F1 区划")
		if gz != null:
			eq(String(gz["spec_done"]), "food", "★ 已完成特化写回")
			near(float(gz["spec_remaining"]), 2.0, 0.001, "★ 特化读条剩余写回")

	# ---- 缺字段 = 保持本地现状 ----
	var old: Dictionary = snap.duplicate(true)
	old.erase("pres")
	old.erase("obj")
	old.erase("tech")
	old.erase("gp")
	for sb in old["buildings"]:
		(sb as Dictionary).erase("mh")
		(sb as Dictionary).erase("lv")
	# 先给客机换一组「别的已拥有」，用来验证「缺 gp → 保持现状」。
	guest.general_recruit_pools["F1"]["taken"] = ["general_2"]
	SnapshotRes.apply_snapshot(guest, cfg, old)
	eq(float(guest.resource_pool_for("F2")["food"]), 333.0, "缺 pres → 客机资源保持现状")
	ok(guest.general_recruit_owned("F1", "general_2"),
		"缺 gp → 客机的「已拥有」集合保持现状")
	near(guest.general_recruit_cooldown_left("F1"), 12.5, 1e-6,
		"缺 gp → 客机的招募冷却也保持现状")
	eq(float(guest.objective_state["held"]), 42.0, "缺 obj → 目标保持现状")
	eq(String(guest.objective_state["kind"]), "hold_zone", "缺 obj → 目标种类保持现状")
	if base != null:
		var gb2 = guest.find_base_of("F1")
		if gb2 != null:
			eq(gb2.level, 2, "缺 lv → 建筑等级保持现状")
			eq(gb2.hp_max, 999.0, "缺 mh → 血量上限保持现状")
	if zone != null:
		var gz2 = _zone_owned_by(guest, "F1")
		if gz2 != null:
			near(float(gz2["spec_remaining"]), 2.0, 0.001, "缺 sr → 特化读条保持现状")


func _zone_owned_by(w, fid: String):
	for z in w.zones.zones:
		if String(z.get("owner", "")) == fid:
			return z
	return null
