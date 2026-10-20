## test_campaign.gd —— 战役 / 关卡的**数据契约**断言（dev_plan_7 M7.0）。
extends "res://tests/test_case.gd"

const CampaignRes = preload("res://logic/campaign.gd")
const LevelRes = preload("res://logic/level.gd")
const LibraryRes = preload("res://logic/campaign_library.gd")
const MapLibraryRes = preload("res://logic/map_library.gd")
const FactionRes = preload("res://logic/faction.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const DEMO_MAP := "res://data/maps/dongzheng/map.json"
const TMP_ROOT := "res://.tmp_campaign_tests"

func _initialize() -> void:
	_demo_hash = _hash_tree(DEMO_DIR)
	_demo_map_hash = _hash_file(DEMO_MAP)
	run_all(Callable(self, "_run"))

var _demo_hash: String = ""
var _demo_map_hash: String = ""

func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_clean_tmp()
	_group_scan(cfg)
	_group_load(cfg)
	_group_merge(cfg)
	_group_check(cfg)
	_group_bad_input(cfg)
	_group_files_untouched()
	_clean_tmp()

func _group_scan(cfg) -> void:
	var listed: Array = LibraryRes.list_campaigns(cfg)
	ok(listed.size() >= 1, "扫描能列出至少一个战役（找到 %d 个）" % listed.size())

	var demo: Variant = null
	for it in listed:
		if String((it as Dictionary)["id"]) == "demo":
			demo = it
	ok(demo != null, "样例战役 demo 被扫出来")
	if demo != null:
		eq(String((demo as Dictionary)["name"]), "东征·第一章", "显示名取 campaign.json 的 name")
		var n_levels := int((demo as Dictionary)["levels"])
		ok(n_levels >= 2, "样例战役至少 2 关（实际 %d）" % n_levels)
		eq(String((demo as Dictionary)["default_mode"]), "solo", "样例战役默认单人")
		eq(String((demo as Dictionary)["dir"]), DEMO_DIR, "战役目录就是 res://data/campaigns/demo")

	var tmp := "%s/scan_extra" % TMP_ROOT
	_write("%s/campaign.json" % tmp, JSON.stringify({
		"levels": [{"id": "only", "file": "levels/only.json"}],
	}))
	_write("%s/levels/only.json" % tmp, JSON.stringify({
		"map": "dongzheng", "players": [{"faction": "F1", "base": [5, 10]}],
		"objectives": [{"kind": "hold_zone", "zone": 4, "hold_sec": 30}],
	}))
	var c = CampaignRes.load_campaign(tmp, cfg)
	ok(c != null, "能直接载入一个指定目录的战役")
	if c != null:
		eq(String(c.name), "scan_extra", "name 缺省 → 退回目录名")
		eq(String(c.default_mode), "solo", "default_mode 缺省 → solo")
		eq(int(c.level_count()), 1, "levels[] 有一关")
		eq(String(c.level_at(0).id), "only", "levels[].id 覆盖文件名")
		eq(c.playable_ids().size(), 0, "campaign.json 没写 factions → 一个可玩阵营都没有")

	var scan := "%s/scan_order" % TMP_ROOT
	_write("%s/campaign.json" % scan, JSON.stringify({}))
	for n in ["02_second", "01_first", "10_tenth"]:
		_write("%s/levels/%s.json" % [scan, n], JSON.stringify({
			"map": "dongzheng", "players": [{"faction": "F1", "base": [5, 10]}],
			"objectives": [{"kind": "hold_zone", "zone": 4, "hold_sec": 5}],
		}))
	var c2 = CampaignRes.load_campaign(scan, cfg)
	ok(c2 != null, "levels[] 缺省时靠扫目录也能载入")
	if c2 != null:
		eq(int(c2.level_count()), 3, "扫到 3 关")
		eq(String(c2.level_at(0).id), "01_first", "按文件名排序（第一关是 01_first）")
		eq(String(c2.level_at(2).id), "10_tenth", "按文件名排序（最后是 10_tenth）")

	var bad := "%s/scan_bad" % TMP_ROOT
	_write("%s/campaign.json" % bad, "{ this is not json ")
	ok(CampaignRes.load_campaign(bad, cfg) == null, "坏 JSON 的战役目录 → 载入失败（不崩）")
	ok(CampaignRes.load_campaign("%s/does_not_exist" % TMP_ROOT, cfg) == null,
		"目录不存在 → 载入失败（不崩）")

	var empty := "%s/scan_empty" % TMP_ROOT
	_write("%s/campaign.json" % empty, JSON.stringify({"levels": []}))
	ok(CampaignRes.load_campaign(empty, cfg) == null, "一关都没有的战役 → 载入失败")

	var unl := "%s/scan_unlock" % TMP_ROOT
	_write("%s/campaign.json" % unl, JSON.stringify({
		"unlock": "free", "levels": [{"file": "levels/a.json"}]}))
	_write("%s/levels/a.json" % unl, JSON.stringify({
		"map": "dongzheng", "players": [{"faction": "F1", "base": [5, 10]}],
		"objectives": [{"kind": "hold_zone", "zone": 4, "hold_sec": 5}],
	}))
	var c3 = CampaignRes.load_campaign(unl, cfg)
	ok(c3 != null, "unlock 写了不认识的值也能载入")
	if c3 != null:
		eq(String(c3.unlock), "in_order", "unlock 退回顺序解锁")
		ok(String(c3.load_error) != "", "unlock 写错留了一条说明（不静默）")

	var demo_c = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var progress: Dictionary = {}
	var un = LibraryRes.unlocked_levels(demo_c, progress)
	eq(un.size(), 1, "没有任何进度时只解锁第一关")
	LibraryRes.mark_cleared(progress, "demo", "01_beachhead")
	var un2 = LibraryRes.unlocked_levels(demo_c, progress)
	eq(un2.size(), 2, "通关第一关之后第二关解锁")
	ok(LibraryRes.is_cleared(progress, "demo", "01_beachhead"), "is_cleared 认得出已通关")
	ok(not LibraryRes.is_cleared(progress, "demo", "02_twin_line"), "没通关的就是没通关")

func _group_load(cfg) -> void:
	var c = CampaignRes.load_campaign(DEMO_DIR, cfg)
	ok(c != null, "样例战役能载入（含全部关卡）")
	if c == null:
		return
	ok(int(c.level_count()) >= 2, "样例战役载入 ≥2 关（实际 %d）" % c.level_count())
	eq(String(c.level_at(0).id), "01_beachhead", "第一关 id 来自 levels[]")
	eq(String(c.level_at(0).name), "第一关·渡口", "第一关显示名来自 levels[]")
	eq(String(c.level_at(1).mode), "coop", "第二关是合作关（关卡文件里的 mode）")
	eq(c.level_at(0).playable_ids(), ["F1", "F2"],
		"★ 第一关自带可玩阵营 F1 / F2（阵营表跟着关卡走）")
	ok(c.faction_meta.is_empty(),
		"★★ campaign.json 不再有阵营表（旧格式才会读到 factions[]）")

	var lv = c.level("01_beachhead")
	ok(lv != null, "按 id 取关卡")
	if lv == null:
		return
	eq(String(lv.map_id), "dongzheng", "关卡引用的地图 id")
	ok(lv.map != null, "关卡的地图载入成功")
	eq(String(lv.mode), "solo", "单人关")
	eq(lv.seat_count(), 2, "单人关（选边关）2 个席位 —— 席位由两个可玩阵营派生")
	eq(String(lv.seats()[0]), "F1", "第一个席位是 F1")
	eq(lv.objective_zone(), 4, "目标区划是 c1")
	var hold: float = lv.objective_hold_sec()
	ok(hold > 0.0, "守住的秒数是正数（%s）" % str(hold))
	var label: String = lv.objective_label()
	ok(label.begins_with("守住 c1 ") and label.ends_with(" 秒"),
		"目标一句话的格式 = 「守住 <区划> <秒> 秒」（界面直接用，实际 = %s）" % label)
	ok(label.contains(str(int(roundf(hold)))) if absf(hold - roundf(hold)) < 0.001 else true,
		"那句话里的秒数与 hold_sec 一致（%s）" % label)
	eq(lv.start_buildings.size(), 1, "开局摆放 1 栋建筑")
	eq(String((lv.start_buildings[0] as Dictionary)["type"]), "tower", "摆放的是箭塔")
	eq(lv.rosters(), ["F1", "F2", "GD1"],
		"出场名单 = 席位（两个可玩阵营）+ 参展阵营（渡口守军 GD1）")
	ok(lv.summary().contains("单人"), "summary() 里有模式")

	var m = _minimal_level(cfg, "minimal", {
		"map": "dongzheng", "players": [{"faction": "F1"}],
		"objectives": [{"kind": "hold_zone", "zone": 4, "hold_sec": 10}],
	})
	ok(m != null, "最小字段的战役能载入")
	if m != null:
		eq(String(m.mode), "solo", "mode 缺省 → 战役 default_mode → solo")
		eq(String(m.name), "m", "name 缺省 → 文件名")
		eq((m.players[0] as Dictionary)["base"], Vector2i(-1, -1), "players[].base 缺省 → (-1,-1)")
		eq(m.faction_meta.size(), 0, "factions 缺省 → 空表")
		eq(m.start_units.size(), 0, "start_units 缺省 → 空表")
		eq(m.fail_conditions.size(), 0, "fail_conditions 缺省 → 空表")
		eq(m.briefing.size(), 0, "briefing 缺省 → 空表")
		eq(m.zone_owners.size(), 0, "zones 缺省 → 空覆盖表")
		ok(not m.allies_declared, "allies 没写 → allies_declared = false")
		eq(m.effective_allies(), m.map.allies, "allies 没写 → 用地图的")
		eq(String((m.faction_config("nobody") as Dictionary)["ai"]), "none", "没参展的阵营 → ai = none")
		ok(not bool((m.faction_config("nobody") as Dictionary)["declared"]), "没参展的阵营 → declared = false")
		eq((m.faction_config("nobody") as Dictionary)["base"], Vector2i(-1, -1), "没参展的阵营 → 没有大本营")

	var lc = c.level("02_twin_line")
	eq(lc.seats(), ["F1", "F2"], "合作关席位顺序 = players[] 的顺序")
	eq(lc.seat_count(), 2, "合作关两个席位")
	eq(lc.fail_conditions.size(), 1, "合作关配了一条额外失败条件")
	eq(int((lc.fail_conditions[0] as Dictionary)["zone"]), 6, "额外失败条件是 f1")

func _group_merge(cfg) -> void:
	var lv = _load_level(cfg, "merge_base", {"zones": [], "_erase": ["allies"]})
	ok(lv != null, "构造一个用于合并测试的关卡")
	if lv == null:
		return
	var map_base_f1 = lv.map.faction_bases.get("F1", Vector2i(-1, -1))
	var map_base_f2 = lv.map.faction_bases.get("F2", Vector2i(-1, -1))
	ok(map_base_f1.x >= 0 and map_base_f2.x >= 0, "样例地图给 F1 / F2 都划了基地")
	var lv_orig_owners: int = lv.map.zones_owners.size()
	var merged: Dictionary = lv.merge_over_map(cfg.ai_factions())
	var map = merged["map"]
	ok(map != null, "合并能得到一张地图")
	if map == null:
		return
	eq(map.faction_bases.get("F1", Vector2i(-1, -1)), map_base_f1,
		"关卡没写 players[].base 时用的是地图的（F1）")
	eq(map.faction_bases.get("F2", Vector2i(-1, -1)), map_base_f2,
		"关卡没写 factions[].base 时用的是地图的（F2）")
	var lv_ov = _load_level(cfg, "merge_base_override", {
		"players": [{"faction": "F1", "base": [4, 15]}],
		"factions": [{"id": "E1", "ai": "faction", "base": [19, 4]}],
		"zones": [],
	})
	var merged_ov: Dictionary = lv_ov.merge_over_map(cfg.ai_factions())
	var map_ov = merged_ov["map"]
	eq(map_ov.faction_bases.get("F1", Vector2i(-1, -1)), Vector2i(4, 15),
		"★ 关卡 players[].base 覆盖地图的（F1）")
	eq(map_ov.faction_bases.get("E1", Vector2i(-1, -1)), Vector2i(19, 4),
		"★ 关卡 factions[].base 覆盖地图的（E1）")
	eq(lv_ov.map.faction_bases.get("F1", Vector2i(-1, -1)), map_base_f1,
		"★ 合并不改原始地图（F1 还是地图上那个点位）")
	eq(String(map.zones_owners.get(6, "")), "", "地图没给归属的区划合并后仍然无主")
	eq(lv.map.zones_owners.size(), lv_orig_owners,
		"★ merge_over_map 不改原始 map（原始那 %d 个归属一个不多一个不少）" % lv_orig_owners)

	var lvz = _load_level(cfg, "merge_zones", {"zones": [{"id": 6, "owner": "F1"}]})
	eq(String(lvz.map.zones_owners.get(6, "")), "", "原始地图里 f1 开场无主")
	var mergedz: Dictionary = lvz.merge_over_map(cfg.ai_factions())
	eq(String((mergedz["map"] as RefCounted).zones_owners.get(6, "")), "F1",
		"★ 关卡 zones[].owner 覆盖地图的开局归属")

	var lv2 = _load_level(cfg, "merge_allies", {"allies": [["F1", "E1"]]})
	ok(lv2.allies_declared, "关卡写了 allies → declared = true")
	eq(lv2.effective_allies(), [["F1", "E1"]], "allies 用关卡的")
	ok(not lv.allies_declared, "关卡没写 allies → declared = false")
	eq(lv.effective_allies(), lv.map.allies, "关卡没写 → 用地图的")

	var lv3 = _load_level(cfg, "merge_faction", {
		"factions": [{"id": "F1"}, {"id": "ZZ", "ai": "faction", "base": [18, 10]}],
	})
	ok(lv3 != null, "能载入带新阵营的关卡")
	var merged3: Dictionary = lv3.merge_over_map(cfg.ai_factions())
	var has_zz := false
	for m in (merged3["map"] as RefCounted).factions_meta:
		if String((m as Dictionary).get("id", "")) == "ZZ":
			has_zz = true
	ok(has_zz, "关卡新加的阵营被追加进合并后地图的 factions 表")
	var orig_has_zz := false
	for m in lv3.map.factions_meta:
		if String((m as Dictionary).get("id", "")) == "ZZ":
			orig_has_zz = true
	ok(not orig_has_zz, "★ 原始地图的 factions 表没被改（合并是只读的）")

	var stub: Array = [
		{"id": "CONF", "base": Vector2i(2, 2)},
	]
	var lv4 = _load_level(cfg, "merge_ai", {})
	var roster: Array = lv4.merged_ai_factions(stub)
	var ids: Array = []
	for e in roster:
		ids.append(String((e as Dictionary)["id"]))
	ok(ids.has("F2"), "关卡点名过的 F2 在名单里")
	ok(ids.has("CONF"), "关卡没写的阵营照旧吃 config（向后兼容）")
	for e in roster:
		var it: Dictionary = e
		ok(not it.has("resource_mult"), "★ 名单条目不再带 resource_mult（%s）" % String(it["id"]))
		ok(not it.has("start_food"), "★ 不再带 start_food")
		ok(it.has("garrison_ai"), "有 garrison_ai 覆盖位")
		ok(it.has("reddot_ai"), "有 reddot_ai 覆盖位")
		ok(it.has("spawn_region"), "有 spawn_region（红点生成区域）")
		if String(it["id"]) == "F2":
			ok(bool(it["from_level"]), "关卡来的条目 from_level = true")
		if String(it["id"]) == "CONF":
			ok(not bool(it["from_level"]), "config 来的条目 from_level = false")

	var lv5 = _load_level(cfg, "merge_ai_none", {"factions": [{"id": "F2", "ai": "none"}, {"id": "F1"}]})
	var ids5: Array = []
	for e in lv5.merged_ai_factions(stub):
		ids5.append(String((e as Dictionary)["id"]))
	ok(not ids5.has("F2"), "★ 关卡写 ai: none ⇒ F2 不进 AI 名单（哪怕 config 里有它）")
	ok(ids5.has("CONF"), "其余 config 阵营照旧")

	var lv6 = _load_level(cfg, "merge_ai_general", {
		"factions": [{"id": "F2", "ai": "general", "base": [18, 10]}]})
	var mode6 := ""
	for e in lv6.merged_ai_factions(stub):
		if String((e as Dictionary)["id"]) == "F2":
			mode6 = String((e as Dictionary)["ai"])
	eq(mode6, "garrison", "★ 旧值 ai: general ⇒ 名单里归一成 garrison")

	var lv7 = _load_level(cfg, "merge_ai_reddot", {
		"factions": [{"id": "F2", "ai": "reddot", "base": [18, 10]}]})
	ok(lv7.reddot_ai_ids(stub).has("F2"), "★ ai: reddot 的进「红点 AI」那一份")
	ok(not lv4.reddot_ai_ids(stub).has("F2"), "ai: garrison 的不进「红点 AI」那一份")

	var f2c: Dictionary = lv.faction_config("F2")
	ok(f2c.has("garrison_ai"), "关卡 faction_config 带 garrison_ai 覆盖位")
	ok(f2c.has("reddot_ai"), "关卡 faction_config 带 reddot_ai 覆盖位")
	ok(f2c.has("spawn_region"), "关卡 faction_config 带 spawn_region")

	eq(String((lv.faction_config("F2") as Dictionary)["ai"]), "garrison",
		"faction_config 能读到 ai（红方归一成阵地性 AI）")
	eq(String(lv.faction_config("F1")["ai"]), "garrison",
		"★ 蓝方也是阵地性（守家）AI —— 只守 c1 周边、不反推")
	eq(String(lv.attack_target_of("F2").get("kind")), "zone",
		"attack_target_of 读到红方的进攻目标（指向 c1）")
	ok(lv.attack_target_of("F1") == null, "没写的阵营 → attack_target 是 null")
	# ★ 2026.10.19 口径变化：`Level.load_level(campaign = null, ...)` 是**客机路径**
	#   （联机 `start` 里只带 level_data），此时 `playable` 从 `players[]` 补 ——
	#   否则客机的 `is_playable` / 界面会空。所以这里不再断言「没挂战役就都不可玩」，
	#   改为钉住「来源是 players[]，且 campaign_id 仍然为空」。
	ok(lv.is_playable("F1") and lv.is_playable("F2"),
		"★ 没挂战役时 playable 由 players[] 补齐（客机联机路径）")
	eq(String(lv.campaign_id), "",
		"★ 但 campaign_id 仍然为空（可玩的来源换成了 players[]，不是战役表）")
	var c_demo = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv_demo = c_demo.level("01_beachhead")
	ok(lv_demo.is_playable("F1"), "样例战役里 F1 可玩")
	ok(lv_demo.is_playable("F2"), "★ 样例战役里 F2 也可玩（两个阵营任选一个）")
	eq(lv_demo.playable_ids(), ["F1", "F2"], "样例关卡可玩阵营 = [F1, F2]")
	ok(not FactionRes.same_side_for_attack("F1", "F2"),
		"★ 选边关里两个可玩阵营是**对立的**（蓝方守 / 红方攻）")
	ok(lv_demo.has_per_faction_objectives(), "★ 第一关是按阵营分开的目标（选边关）")
	eq(String(lv_demo.objective_of("F1")["kind"]), "hold_zone", "蓝方的目标是守住")
	eq(String(lv_demo.objective_of("F2")["kind"]), "capture_zone", "红方的目标是攻占")
	eq(int(lv_demo.objective_of("F1")["zone"]), int(lv_demo.objective_of("F2")["zone"]),
		"两边打的是**同一个**区划（c1）")

func _group_check(cfg) -> void:
	var c = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var shipped := ["01_beachhead", "02_twin_line"]
	for lv in c.levels:
		var issues: Array = lv.check(cfg.ai_factions())
		var blocks: Array = lv.blockers()
		var detail := ""
		for b in blocks:
			detail += " / %s" % String((b as Dictionary)["msg"])
		ok(blocks.is_empty(), "样例关卡「%s」没有拦截项%s" % [String(lv.name), detail])
		if shipped.has(String((lv as RefCounted).id)):
			ok(issues.size() == 0, "样例关卡「%s」连警告都没有" % String(lv.name))

	var cases: Array = [
		[{"map": "no_such_map"}, "map_not_found"],
		[{"map": ""}, "map_missing_field"],
		[{"mode": "coop", "players": [{"faction": "F1"}]}, "players_count_coop"],
		[{"mode": "coop", "players": [{"faction": "F1"}, {"faction": "E1"},
			{"faction": "E2"}]}, "players_count_coop"],
		[{"players": []}, "players_empty"],
		[{"mode": "coop", "players": [{"faction": "F1"}, {"faction": "F1"}]}, "players_same_faction"],
		[{"_playable": ["ZZ"], "factions": [{"id": "ZZ"}]}, "faction_no_base"],
		[{"players": [{"faction": "F1", "base": [5, 12]}]}, "point_on_zone_center"],
		[{"players": [{"faction": "F1", "base": [0, 9]}]}, "point_on_mountain"],
		[{"players": [{"faction": "F1", "base": [99, 99]}]}, "point_outside"],
		[{"start_units": [{"faction": "E1", "kind": "enemy", "x": 0, "y": 9}]}, "point_on_mountain"],
		[{"mode": "coop", "allies": [], "_playable": ["F1", "F2"],
			"objectives": [{"kind": "hold_zone", "zone": 4, "hold_sec": 10}]},
			"playable_not_same_side"],
		[{"_playable": ["F1", "F2"],
			"objectives": [{"for": "F1", "kind": "hold_zone", "zone": 4, "hold_sec": 10},
				{"for": "F3", "kind": "hold_zone", "zone": 5, "hold_sec": 10}]},
			"playable_no_objective"],
		[{"zones": [{"id": 4, "owner": "F2"}]}, "objective_not_players"],
		[{"zones": [{"id": 4, "owner": ""}]}, "objective_unowned"],
		[{"zones": [{"id": 4, "owner": "F2"}],
			"objectives": [{"for": "F1", "kind": "hold_zone", "zone": 4, "hold_sec": 10},
				{"for": "F2", "kind": "capture_zone", "zone": 4}]}, "objective_already_mine"],
		[{"objectives": []}, "objective_empty"],
		[{"objectives": [{"kind": "hold_zone", "zone": 4, "hold_sec": 10},
			{"kind": "hold_zone", "zone": 5, "hold_sec": 10}]}, "objective_too_many"],
		[{"objectives": [{"kind": "hold_zone", "zone": 4, "hold_sec": 0}]}, "objective_hold_sec"],
		[{"objectives": [{"kind": "hold_zone", "zone": 99, "hold_sec": 10}]}, "objective_zone_missing"],
		[{"objectives": [{"for": "F2", "kind": "teleport_zone", "zone": 4}]}, "objective_kind"],
		[{"factions": [{"id": "E1", "ai": "faction", "base": [18, 10],
			"attack_target": {"kind": "zone", "zone": 99}}]}, "attack_target_zone"],
		[{"factions": [{"id": "E1", "ai": "faction", "base": [18, 10],
			"attack_target": {"kind": "point", "x": 99, "y": 99}}]}, "attack_target_outside"],
		[{"factions": [{"id": "E1", "ai": "faction", "base": [18, 10],
			"attack_target": {"kind": "point", "x": 0, "y": 9}}]}, "attack_target_mountain"],
		[{"factions": [{"id": "E1", "ai": "faction", "base": [18, 10],
			"attack_target": {"kind": "wormhole"}}]}, "attack_target_kind"],
		[{"factions": [{"id": "E1", "ai": "faction", "base": [18, 10],
			"attack_target": {"kind": "base"}}]}, "attack_target_base"],
		[{"fail_conditions": [{"kind": "zone_lost", "zone": 4}]}, "fail_zone_is_objective"],
		[{"fail_conditions": [{"kind": "zone_lost", "zone": 99}]}, "fail_zone_missing"],
		[{"fail_conditions": [{"kind": "all_units_dead"}]}, "fail_kind"],
		[{"fail_conditions": [{"kind": "zone_lost", "zone": 6}]}, "fail_zone_unowned"],
		[{"zones": [{"id": 3, "owner": "F2"}],
			"fail_conditions": [{"kind": "zone_lost", "zone": 3}]}, "fail_zone_not_players"],		# 12) 挂了将领性 AI 却没有归属区划
		[{"start_units": [{"faction": "E1", "kind": "enemy", "x": 10, "y": 4, "ai": "general"}]},
			"unit_general_no_zone"],
		[{"start_units": [{"faction": "NOPE", "kind": "enemy", "x": 10, "y": 4}]}, "faction_unknown"],
		[{"start_buildings": [{"type": "tower", "x": 11, "y": 11, "owner": "NOPE"}]}, "faction_unknown"],
	]
	var _case_seq := 0
	for entry in cases:
		var patch: Dictionary = (entry as Array)[0]
		var code := String((entry as Array)[1])
		var ai_cfg: Array = cfg.ai_factions()
		if (entry as Array).size() >= 3:
			ai_cfg = (entry as Array)[2]
		_case_seq += 1
		var lv = _load_level(cfg, "ck_%s_%d" % [code, _case_seq], patch)
		if lv == null:
			ok(false, "坏样例能载入（%s）" % code)
			continue
		var issues: Array = lv.check(ai_cfg)
		var hit := ""
		for i in issues:
			var it: Dictionary = i
			if String(it["code"]) == code and String(it["sev"]) == "block":
				hit = String(it["msg"])
		ok(hit != "", "★ 校验拦住了：%s（%s）" % [code, JSON.stringify(patch)])
		ok(lv.has_blocker(), "有拦截项时 has_blocker() = true（%s）" % code)
		for i in lv.blockers():
			eq(String((i as Dictionary)["sev"]), "block", "blockers() 里全是 block")

	var lv_ai = _load_level(cfg, "ck_ai_no_base", {
		"_playable": ["F1"],
		"factions": [{"id": "F1"}, {"id": "ZZ", "ai": "garrison"}]})
	ok(lv_ai != null, "AI 无基地的样例能载入")
	var ai_base_block := false
	for i in lv_ai.blockers():
		if String((i as Dictionary)["code"]) == "faction_no_base":
			ai_base_block = true
	ok(not ai_base_block, "★★ AI 阵营没有大本营 → 不报 faction_no_base（只有可玩阵营要求）")

	var warn_cases: Array = [
		[{"zones": [{"id": 4, "owner": "F2"}],
			"factions": [{"id": "F2", "ai": "reddot", "base": [10, 1],
				"attack_target": {"kind": "zone", "zone": 4}}]}, "attack_target_own_land"],
		[{"allies": [["F1", "ZZ"]]}, "ally_unknown"],
	]
	for entry in warn_cases:
		var patch2: Dictionary = (entry as Array)[0]
		var code2 := String((entry as Array)[1])
		var lv2 = _load_level(cfg, "warn_%s" % code2, patch2)
		if lv2 == null:
			ok(false, "警告样例能载入（%s）" % code2)
			continue
		var issues2: Array = lv2.check(cfg.ai_factions())
		var found := ""
		for i in issues2:
			var it2: Dictionary = i
			if String(it2["code"]) == code2 and String(it2["sev"]) == "warn":
				found = String(it2["msg"])
		ok(found != "", "★ 校验给出了警告：%s" % code2)

	var lv3 = _load_level(cfg, "warn_no_target", {
		"factions": [{"id": "E1", "ai": "reddot", "base": [18, 10]}],
		"start_units": [{"faction": "E1", "kind": "enemy", "x": 18, "y": 10}]})
	var issues3: Array = lv3.check(cfg.ai_factions())
	var found3 := ""
	for i in issues3:
		if String((i as Dictionary)["code"]) == "no_attack_target":
			found3 = String((i as Dictionary)["msg"])
	ok(found3 != "", "★ 全都没写进攻目标 → 警告")
	ok(not lv3.has_blocker(), "全都没写进攻目标**不拦**导出")

	ok(lv3.warnings().size() >= 1, "warnings() 能拿到警告")
	for i in lv3.warnings():
		eq(String((i as Dictionary)["sev"]), "warn", "warnings() 里全是 warn")

func _group_bad_input(cfg) -> void:
	var bad := "%s/bad_json" % TMP_ROOT
	_write("%s/campaign.json" % bad, JSON.stringify({
		"levels": [
			{"id": "broken", "file": "levels/broken.json"},
			{"id": "ok2", "file": "levels/ok2.json"},
		],
	}))
	_write("%s/levels/broken.json" % bad, "not json at all")
	_write("%s/levels/ok2.json" % bad, JSON.stringify({
		"map": "dongzheng", "players": [{"faction": "F1", "base": [5, 10]}],
		"objectives": [{"kind": "hold_zone", "zone": 4, "hold_sec": 10}],
	}))
	var c = CampaignRes.load_campaign(bad, cfg)
	ok(c != null, "一关坏了的战役照样能载入（跳过坏的那一关）")
	if c != null:
		eq(int(c.level_count()), 1, "只剩好的那一关")
		eq(String(c.level_at(0).id), "ok2", "留下的是好的那一关")
		ok(String(c.load_error) != "", "跳过坏关卡留了一条说明（不静默）")

	ok(LevelRes.load_level(null, "%s/levels/broken.json" % bad, cfg) == null,
		"坏 JSON 的关卡 → 载入失败（不崩）")
	ok(LevelRes.load_level(null, "%s/levels/nope.json" % bad, cfg) == null,
		"不存在的关卡文件 → 载入失败（不崩）")
	ok(LevelRes.load_level(null, "%s/levels/ok2.json" % bad, cfg) != null,
		"同一目录里好的那一关照旧能载入")
	var lv = LevelRes.load_level(null, "%s/levels/ok2.json" % bad, cfg)
	var lv_bad = _load_level(cfg, "bad_map", {"map": "nope"})
	ok(lv_bad != null, "地图不存在的关卡照样能载入（界面要能打开并报错）")
	ok(lv_bad.map == null, "地图不存在时 map 是 null")
	lv_bad.check(cfg.ai_factions())
	ok(lv_bad.has_blocker(), "地图不存在的关卡必然被校验拦住")

func _group_files_untouched() -> void:
	eq(_hash_tree(DEMO_DIR), _demo_hash, "★ data/campaigns/demo 一个字节都没被测试改坏")
	eq(_hash_file(DEMO_MAP), _demo_map_hash, "★ data/maps/dongzheng/map.json 没被改坏")

	eq(MapLibraryRes.default_map_path(), "res://data/maps/frontier/map.json",
		"★ 加了战役图之后，默认地图仍然是 frontier（向后兼容那一条）")
	ok(MapLibraryRes.is_hidden(DEMO_MAP), "样例战役图身上写了 hidden: true")
	ok(not MapLibraryRes.is_placeholder(DEMO_MAP), "它不是占位图（两种标记含义不同）")
	ok(MapLibraryRes.is_hidden("res://data/maps/frontier/map.json") == false,
		"frontier 不是战役专用图（它照样在自由对战的选择条上）")
	var listed: Array = MapLibraryRes.list_maps()
	var ids: Array = []
	for m in listed:
		ids.append(String((m as Dictionary)["id"]))
	ok(not ids.has("dongzheng"), "★ 战役专用图不进自由对战的选择条")
	ok(ids.has("frontier"), "正式图照样在")
	ok(ids.has("arena"), "★ 占位图**照样列出**（只是不当默认 —— 加 arena 那次定的口径）")

func _load_level(cfg, name: String, patch: Dictionary):
	var raw := _demo_level_raw()
	if raw.is_empty():
		return null
	for k in patch.keys():
		if String(k) == "_playable" or String(k) == "_erase":
			continue
		raw[k] = patch[k]
	if patch.has("_erase"):
		for k2 in (patch["_erase"] as Array):
			raw.erase(String(k2))
	var p := "%s/%s/levels/l.json" % [TMP_ROOT, name]
	_write(p, JSON.stringify(raw))
	var lv = LevelRes.load_level(null, p, cfg)
	if lv == null:
		return null
	if patch.has("_playable"):
		var ov: Array = []
		for fid in (patch["_playable"] as Array):
			ov.append(String(fid))
		lv.playable_override = ov
	return lv

func _minimal_level(cfg, name: String, data: Dictionary):
	var dir := "%s/%s" % [TMP_ROOT, name]
	_write("%s/campaign.json" % dir, JSON.stringify({"levels": [{"file": "levels/m.json"}]}))
	_write("%s/levels/m.json" % dir, JSON.stringify(data))
	var c = CampaignRes.load_campaign(dir, cfg)
	return c.level_at(0) if c != null else null

func _demo_level_raw() -> Dictionary:
	var data: Variant = _read_json("%s/levels/01_beachhead.json" % DEMO_DIR)
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	return (data as Dictionary).duplicate(true)

func _read_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var t := f.get_as_text()
	f.close()
	return JSON.parse_string(t)

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

func _hash_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "MISSING"
	var text := f.get_as_text()
	f.close()
	return "%s:%d" % [text.md5_text(), text.length()]

func _hash_tree(dir: String) -> String:
	var d := DirAccess.open(dir)
	if d == null:
		return "MISSING"
	var parts: Array = []
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if d.current_is_dir():
			parts.append("%s/%s" % [n, _hash_tree("%s/%s" % [dir, n])])
		else:
			parts.append("%s=%s" % [n, _hash_file("%s/%s" % [dir, n])])
		n = d.get_next()
	d.list_dir_end()
	parts.sort()
	return "|".join(parts)
