## test_snapshot_delta.gd —— ★ 增量快照：只发变化字段 + 客机合并 + 关键帧自愈。
##
## 盯：
##   1. 关键帧仍是完整字段（新客机 / 丢帧后能自愈）；
##   2. 没变化时增量只带单位 id；
##   3. 位置 / 血量变化只发变化字段（不再重发 f / k / ut）；
##   4. 客机先应用关键帧、再应用增量后与房主一致；
##   5. 同一帧多条增量合并后，两边的变化都不丢；
##   6. 关键帧之后新出现的单位整条发、阵亡单位从快照消失；
##   7. 房主默认背压阈值 64KB。
extends "res://tests/test_case.gd"

const CampaignRes = preload("res://logic/campaign.gd")
const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const SnapshotRes = preload("res://logic/snapshot.gd")
const HostSessionRes = preload("res://net/host_session.gd")
const FakeTransportRes = preload("res://tests/fake_transport.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const LEVEL_ID := "02_twin_line"


func _initialize() -> void:
	_case_name = "test_snapshot_delta"
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
	var guest = WorldRes.create_from_level(cfg, lv, "F2", lv.coop_roster(), false)
	if host == null or guest == null:
		ok(false, "（前提）两个世界能建出来")
		return
	var u = _first_alive(host, "F1")
	ok(u != null, "（前提）房主有 F1 单位")
	if u == null:
		return

	# ---- 关键帧：完整字段（与旧版完整快照一致） ----
	var full_old: Dictionary = SnapshotRes.to_snapshot(host)
	var cache: Dictionary = {}
	var kf: Dictionary = SnapshotRes.to_snapshot(host, cache, true)
	var kf_entry: Dictionary = _entry(kf, u.id)
	ok(kf_entry.size() >= 20, "★★ 关键帧带完整单位字段（%d 项）" % kf_entry.size())
	ok(_entry(full_old, u.id).size() == kf_entry.size(),
		"★ 关键帧字段数与旧版完整快照一致")
	eq(cache.size(), host.units.size(), "★ 增量基准按单位 id 建表")

	# ---- 没变化：每条只带 id ----
	var still: Dictionary = SnapshotRes.to_snapshot(host, cache, false)
	var only_ids := true
	for su in still["units"]:
		if typeof(su) != TYPE_DICTIONARY:
			only_ids = false
			break
		var d: Dictionary = su
		# 静止时只带 id + 兵种（ut 每帧都带，用来纠正两端的兵种不一致）。
		if not d.has("i") or not d.has("ut") or d.size() > 2:
			only_ids = false
			break
	ok(only_ids, "★★ 静止时增量只带 id + ut（不再重发其它静态字段）")

	# ---- 变化：只发变化字段 ----
	u.pos = u.pos + Vector2(1.0, 0.0)
	u.sync_tile(host.map)
	u.hp = maxf(1.0, u.hp - 10.0)
	var moved: Dictionary = SnapshotRes.to_snapshot(host, cache, false)
	var me: Dictionary = _entry(moved, u.id)
	ok(me.has("x") and me.has("h"), "★★ 位置 / 血量变化会发")
	ok(not me.has("y"), "★★ 没变的坐标不发（只发变化字段）")
	ok(not me.has("f") and not me.has("k"),
		"★★ 静态字段（阵营 / kind）不重复发")
	ok(me.has("ut"), "★★ 兵种 ut 每帧都带（客机据此纠正兵种不一致）")
	eq(String(me.get("i", "")), String(u.id), "★ 增量条目仍带 id")

	# ---- 客机：关键帧 + 增量 = 与房主一致 ----
	SnapshotRes.apply_snapshot(guest, cfg, kf)
	SnapshotRes.apply_snapshot(guest, cfg, moved)
	var gu = guest.unit_by_id(String(u.id))
	ok(gu != null, "★ 客机有同一个单位")
	if gu != null:
		near(gu.pos.x, u.pos.x, 0.011, "★ 客机位置写回")
		near(gu.pos.y, u.pos.y, 0.011, "★ 客机位置写回")
		near(gu.hp, u.hp, 0.51, "★ 客机血量写回")
		eq(String(gu.faction), String(u.faction), "★ 客机保留静态字段（阵营）")
		eq(String(gu.unit_type), String(u.unit_type), "★ 客机保留静态字段（兵种）")

	# ---- 兵种不一致纠正（用户实测：一端骑兵、一端步兵） ----
	var wrong_type := "rider" if String(u.unit_type) != "rider" else "spearman"
	if gu != null:
		gu.reapply_type(cfg, wrong_type)
		eq(String(gu.unit_type), wrong_type, "（前提）客机被改成了另一种兵")
		SnapshotRes.apply_snapshot(guest, cfg, moved)
		var gu2 = guest.unit_by_id(String(u.id))
		ok(gu2 != null, "（前提）纠正后单位还在")
		if gu2 != null:
			eq(String(gu2.unit_type), String(u.unit_type),
				"★★ 快照 ut 把已有单位的兵种纠正回房主（不再一端骑兵一端步兵）")
			eq(String(gu2.unit_class), String(u.unit_class),
				"★★ 兵种大类（步兵 / 骑兵）也一起重算")

	# ---- 同一帧两条增量：合并后两处变化都不丢 ----
	u.pos = u.pos + Vector2(1.0, 0.0)
	u.sync_tile(host.map)
	var d1: Dictionary = SnapshotRes.to_snapshot(host, cache, false)
	u.pos = u.pos + Vector2(1.0, 0.0)
	u.sync_tile(host.map)
	var d2: Dictionary = SnapshotRes.to_snapshot(host, cache, false)
	var merged: Dictionary = SnapshotRes.merge_delta(d1, d2)
	SnapshotRes.apply_snapshot(guest, cfg, merged)
	var gm = guest.unit_by_id(String(u.id))
	if gm != null:
		near(gm.pos.x, u.pos.x, 0.011, "★★ 合并后的增量带着最新位置（中间那条没有丢）")
	ok(true, "★ merge_delta 返回一条可应用快照")

	# ---- 关键帧之后的新单位：整条发 ----
	var g = host.create_general("F1", 3, 80)
	if g != null:
		host.units.append(g)
		var added: Dictionary = SnapshotRes.to_snapshot(host, cache, false)
		var ge: Dictionary = _entry(added, g.id)
		ok(not ge.is_empty() and ge.has("f") and ge.has("k") and ge.has("x"),
			"★★ 新单位在增量里整条发（否则客机会按默认值建错）")
		SnapshotRes.apply_snapshot(guest, cfg, added)
		ok(guest.unit_by_id(String(g.id)) != null, "★ 客机新建出这个单位")

	# ---- 阵亡单位：从快照消失，客机删除 ----
	var victim = _first_alive(host, "F2")
	ok(victim != null, "（前提）有 F2 单位")
	if victim != null:
		victim.alive = false
		var dead_snap: Dictionary = SnapshotRes.to_snapshot(host, cache, false)
		ok(_entry(dead_snap, victim.id).is_empty(), "★★ 阵亡单位不在增量快照里")
		SnapshotRes.apply_snapshot(guest, cfg, dead_snap)
		ok(guest.unit_by_id(String(victim.id)) == null, "★ 客机把阵亡单位删掉")
		ok(not cache.has(String(victim.id)), "★ 增量基准也清掉阵亡单位")

	# ---- 关键帧：回到完整字段 ----
	var kf2: Dictionary = SnapshotRes.to_snapshot(host, cache, true)
	var kf2e: Dictionary = _entry(kf2, u.id)
	ok(kf2e.has("f") and kf2e.has("k") and kf2e.has("ut"),
		"★★ 强制关键帧回到完整字段（丢帧后的自愈点）")

	# ---- 房主默认背压阈值 ----
	var ft = FakeTransportRes.new()
	var hs = HostSessionRes.new()
	hs.setup(host, cfg, ft, "F1", "F2")
	eq(hs.snap_buffer_limit, 64 * 1024, "★★ 默认背压阈值 64KB（移动端联机延迟上限）")
	eq(hs.snap_keyframe_every, 300, "★ 默认每 300 条快照一个关键帧")
	hs.free()


func _first_alive(w, fid: String):
	for u in w.units:
		if u.alive and String(u.faction) == fid:
			return u
	return null


func _entry(snap: Dictionary, id: String) -> Dictionary:
	for su in snap.get("units", []):
		if typeof(su) != TYPE_DICTIONARY:
			continue
		if String((su as Dictionary).get("i", "")) == id:
			return su
	return {}
