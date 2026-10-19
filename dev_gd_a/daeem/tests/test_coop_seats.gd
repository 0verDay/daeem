## test_coop_seats.gd —— 合作模式 M12.1：**两个席位各控自己**的规则断言。
##
## 本轮不联网：用两个本地世界分别扮演房主（F1）与客机（F2），
## 把「谁能命令谁 / 谁的钱是谁的 / 视野是不是共享」先在没有网络的情况下钉死。
extends "res://tests/test_case.gd"

const CampaignRes = preload("res://logic/campaign.gd")
const WorldRes = preload("res://logic/world.gd")
const CommandRes = preload("res://logic/command_processor.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const LEVEL_ID := "02_twin_line"
const OBJ_ZONE := 4

func _initialize() -> void:
	_case_name = "test_coop_seats"
	run_all(Callable(self, "_run"))


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_group_roster_order(cfg)
	_group_strict_owner(cfg)
	_group_resources_and_fog(cfg)
	_group_command_reject(cfg)


func _group_roster_order(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	ok(camp != null, "（前提）样例战役能载入")
	if camp == null:
		return
	var lv = camp.level(LEVEL_ID)
	ok(lv != null, "（前提）合作关 02_twin_line 能载入")
	if lv == null:
		return

	eq(lv.coop_roster(), ["F1", "F2"], "★ 合作席位按 players[] 原序（房主第 1、客机第 2）")
	eq(lv.seats(), ["F1", "F2"], "（前提）seats() 也是原序")

	var host = _world(cfg, lv, "F1")
	var guest = _world(cfg, lv, "F2")
	ok(host != null and guest != null, "★ 两个席位各自建出世界")
	if host == null or guest == null:
		return

	eq(host.factions, ["F1", "F2"], "★ 房主世界 factions 原序 = [F1, F2]")
	eq(guest.factions, ["F1", "F2"], "★ 客机世界 factions 也原序（两端必须同序）")
	eq(host.my_faction, "F1", "房主操作 F1")
	eq(guest.my_faction, "F2", "客机操作 F2")
	eq(host.player_seats, ["F1", "F2"], "★ 两端都建两个席位（两个家 / 两份钱包）")
	eq(host.player_factions, ["F1", "F2"], "★ 合作关两方都没挂 AI ⇒ 都是玩家")
	eq(guest.player_factions, ["F1", "F2"], "客机侧同样是两个玩家席位")

	ok(host.is_own_seat("F1"), "★ 房主只认 F1 是自己的")
	ok(not host.is_own_seat("F2"), "★ 房主不能把 F2 当成自己")
	ok(guest.is_own_seat("F2"), "★ 客机只认 F2 是自己的")
	ok(not guest.is_own_seat("F1"), "★ 客机不能把 F1 当成自己")


func _group_strict_owner(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID) if camp != null else null
	if lv == null:
		ok(false, "（前提）合作关载入失败")
		return
	var w = _world(cfg, lv, "F1")
	if w == null:
		ok(false, "（前提）房主世界建不出来")
		return

	var f1 = _first_general(w, "F1")
	var f2 = _first_general(w, "F2")
	ok(f1 != null and f2 != null, "（前提）两边都有将领")
	if f1 == null or f2 == null:
		return

	ok(w.accepts_owner(String(f1.faction), "F1"), "F1 的单位接受 F1 的命令")
	ok(not w.accepts_owner(String(f1.faction), "F2"), "★ F1 的单位拒绝 F2 的命令（严格归属）")
	eq(w.leader_reject_reason(f2, "F1"), "faction",
		"★ 房主不能拿 F2 的将领当招募对象")
	eq(w.can_recruit_zone(_zone_kind(w), _zone_id_owned_by(w, "F1"), "F2"), "zone_owner",
		"★ 客机不能在房主的区划里招募")

	var z = _zone_owned_by_dict(w, "F1")
	ok(z != null, "（前提）F1 至少占着一块区")
	if z != null:
		var c: Variant = z.get("center", null)
		if typeof(c) == TYPE_VECTOR2I:
			var t: Vector2i = c
			ok(w.zone_allows_build(t.x, t.y, "F1"), "F1 能/允许在自家区划建造")
			ok(not w.zone_allows_build(t.x, t.y, "F2"), "★ F2 不能在 F1 的区划建造")


func _group_resources_and_fog(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID) if camp != null else null
	if lv == null:
		return
	var host = _world(cfg, lv, "F1")
	var guest = _world(cfg, lv, "F2")
	if host == null or guest == null:
		return

	var p1: Variant = host.resource_pool_for("F1")
	var p2: Variant = host.resource_pool_for("F2")
	ok(p1 != null and p2 != null, "两个玩家席位各自有资源池")
	ok(not is_same(p1, p2), "★★ 两个席位的钱包不是同一个对象")
	ok(is_same(p1, host.resources), "★★ 房主的 `world.resources` 就是 F1 那一份")
	ok(is_same(guest.resource_pool_for("F2"), guest.resources),
		"★★ 客机的 `world.resources` 就是 F2 那一份")

	host.fog.update(host)
	var f2 = _first_general(host, "F2")
	if f2 == null:
		return
	ok(host.fog.tile_visible("F2", f2.tx, f2.ty), "（前提）F2 看得见自己脚下")
	eq(host.fog.tile_visible("F1", f2.tx, f2.ty), true,
		"★★ 共享视野：F2 脚下那一格，F1 也看得见")

	eq(host.objective_state.get("defend", []), ["F1", "F2"],
		"★★ 目标 defend 席位 = 两个玩家（谁守住都算）")
	eq(String(host.objective_state.get("kind", "")), "hold_zone", "合作关目标是「守住」")
	eq(int(host.objective_state.get("zone", -1)), OBJ_ZONE, "目标区划是 c1")
	eq(float(host.objective_state.get("sec", 0.0)), 120.0, "守 120 秒")

	var w_old = _world(cfg, lv, "F1")
	ok(w_old != null, "同一张图再建一个世界（旧路径的判据不变）")
	if w_old != null:
		ok(not w_old.is_own_seat("F2"),
			"★ 单机 / 旧路径也是严格同阵营：盟友的兵不能指挥（逐位不变）")


func _group_command_reject(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID) if camp != null else null
	if lv == null:
		return
	var w = _world(cfg, lv, "F1")
	if w == null:
		return
	var f1 = _first_general(w, "F1")
	if f1 == null:
		return

	var before: Vector2 = f1.pos
	ok(not CommandRes.apply(w, cfg, {"kind": "move", "ids": [f1.id],
		"x": before.x + 1.0, "y": before.y, "faction": "F2"}),
		"★★ 客机用 F2 的命令移动 F1 的将领 → 被拒")
	v2_near(f1.pos, before, 0.01, "★ 被拒之后 F1 的将领没有动")

	ok(not CommandRes.apply(w, cfg, {"kind": "stop", "ids": [f1.id], "faction": "F2"}),
		"★★ 客机用 F2 的命令让 F1 停下 → 被拒")
	ok(CommandRes.apply(w, cfg, {"kind": "stop", "ids": [f1.id], "faction": "F1"}),
		"房主用 F1 的命令让 F1 停下 → 接受（别修过头）")


# ------------------------------------------------------------------
# 辅助
# ------------------------------------------------------------------

func _world(cfg, lv, seat: String):
	return WorldRes.create_from_level(cfg, lv, seat, lv.coop_roster(), true)


func _first_general(w, fid: String):
	for u in w.units:
		if u.alive and String(u.faction) == fid and u.is_general():
			return u
	return null


func _zone_owned_by_dict(w, fid: String):
	for z in w.zones.zones:
		if String(z.get("owner", "")) == fid:
			return z
	return null


func _zone_id_owned_by(w, fid: String) -> int:
	var z = _zone_owned_by_dict(w, fid)
	return int(z.get("id", -1)) if z != null else -1


func _zone_kind(w) -> String:
	var list: Array = w.zone_recruit_list()
	if list.is_empty():
		return ""
	return String((list[0] as Dictionary).get("kind", ""))
