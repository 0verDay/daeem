## test_campaign.gd —— 战役 / 关卡的**数据契约**断言（dev_plan_7 M7.0）。
##
## 盯的是「不写就会静默错」的那一类：
##   · 目录扫描（多战役 / 坏 JSON 跳过 / 名字退回目录名）；
##   · 关卡载入 + 缺字段默认值；
##   · ★★ **覆盖规则**（关卡 vs 地图：阵营 / 大本营 / 摆放 / allies / 区块归属 / AI 名单）；
##   · 2.5 那 16 条校验 —— **每条各造一个坏样例**（不是只测「合法数据能过」）；
##   · 坏输入（坏 JSON / 文件不存在）→ 说清楚而不是静默崩；
##   · ★ 整场测试跑完，`data/campaigns/**` 与样例地图**一个字节都没被改**。
##
## ⚠️ 语言约定（见 tests/test_case.gd 与 docs/pitfalls.md 第五节）：
##   · 只用 `load()` / preload 常量，不用全局 class_name 作类型；
##   · 返回值是 Variant 时用 `=` 而不是 `:=`（否则 "Cannot infer the type"）；
##   · 输出只用 ASCII（中文 Windows 的 GBK 控制台会因此崩掉）。
extends "res://tests/test_case.gd"

const CampaignRes = preload("res://logic/campaign.gd")
const LevelRes = preload("res://logic/level.gd")
const LibraryRes = preload("res://logic/campaign_library.gd")
const MapLibraryRes = preload("res://logic/map_library.gd")
## 「可玩阵营必须互为同方」那条断言要用它（校验第 7 条用的是同一个 `side_of`）。
const FactionRes = preload("res://logic/faction.gd")

## 随游戏发布的那份样例战役（**测试不许改它**，见最后那一组断言）。
const DEMO_DIR := "res://data/campaigns/demo"
## 样例地图（也是本战役引用的那张）
const DEMO_MAP := "res://data/maps/dongzheng/map.json"
## 临时目录：坏样例 / 临时战役都写在这里（**工程内**，测试自己清理）。
##
## ⚠️ 为什么不用 `user://`：那一条路径在这个工程的运行环境里建不出来
##   （`DirAccess.make_dir_recursive_absolute("user://…")` 实测返回「Could not create
##   directory」，`FileAccess.open(..., WRITE)` 直接返回 null），于是整套坏样例都写不进去。
##   工程内的临时目录一定能写，而且测试末尾会把它整个删掉 —— 不留痕迹。
const TMP_ROOT := "res://.tmp_campaign_tests"


func _initialize() -> void:
	# ★★ 在**跑任何断言之前**先把样例数据的指纹记下来；最后一条断言再算一次对比。
	#    这是 unit_editor 里那条兜底断言的同款：测试只许写 user://。
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


# ------------------------------------------------------------------
# 一、目录扫描（照 map_library 那四条）
# ------------------------------------------------------------------
func _group_scan(cfg) -> void:
	# ⚠️ 显式传 cfg：`Level` 里要载入地图，而地图需要 config（列地图表 / 阵营表 / 地形代价）。
	#    另外那条「不带参数」的入口（`list_campaigns()`）由**游戏侧**用全局配置兜底 ——
	#    测试里不重复建一份 config。
	var listed: Array = LibraryRes.list_campaigns(cfg)
	ok(listed.size() >= 1, "扫描能列出至少一个战役（找到 %d 个）" % listed.size())

	var demo: Variant = null
	for it in listed:
		if String((it as Dictionary)["id"]) == "demo":
			demo = it
	ok(demo != null, "样例战役 demo 被扫出来")
	if demo != null:
		eq(String((demo as Dictionary)["name"]), "东征·第一章", "显示名取 campaign.json 的 name")
		eq(int((demo as Dictionary)["levels"]), 2, "样例战役有 2 关")
		eq(String((demo as Dictionary)["default_mode"]), "solo", "样例战役默认单人")
		eq(String((demo as Dictionary)["dir"]), DEMO_DIR, "战役目录就是 res://data/campaigns/demo")

	# ★ 加一个战役目录 = 多一项（代码与配置一个字不改）
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

	# ★ levels[] 缺省 → 退化成「levels/ 目录下所有 *.json 按文件名排序」
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

	# 坏 JSON 的战役目录 → 载入失败（扫描时会跳过它，不冒泡）
	var bad := "%s/scan_bad" % TMP_ROOT
	_write("%s/campaign.json" % bad, "{ this is not json ")
	ok(CampaignRes.load_campaign(bad, cfg) == null, "坏 JSON 的战役目录 → 载入失败（不崩）")
	ok(CampaignRes.load_campaign("%s/does_not_exist" % TMP_ROOT, cfg) == null,
		"目录不存在 → 载入失败（不崩）")

	# 一关都没有的战役 → 失败（空战役没有意义，且会让界面以为载入成功）
	var empty := "%s/scan_empty" % TMP_ROOT
	_write("%s/campaign.json" % empty, JSON.stringify({"levels": []}))
	ok(CampaignRes.load_campaign(empty, cfg) == null, "一关都没有的战役 → 载入失败")

	# `unlock` 写了个不认识的值 → 退回顺序解锁，并留一条说明
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

	# ★★ 解锁是**纯函数**（为以后的进度存档留的口子，见 dev_plan_7 3.10）
	var demo_c = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var progress: Dictionary = {}
	var un = LibraryRes.unlocked_levels(demo_c, progress)
	eq(un.size(), 1, "没有任何进度时只解锁第一关")
	LibraryRes.mark_cleared(progress, "demo", "01_beachhead")
	var un2 = LibraryRes.unlocked_levels(demo_c, progress)
	eq(un2.size(), 2, "通关第一关之后第二关解锁")
	ok(LibraryRes.is_cleared(progress, "demo", "01_beachhead"), "is_cleared 认得出已通关")
	ok(not LibraryRes.is_cleared(progress, "demo", "02_twin_line"), "没通关的就是没通关")


# ------------------------------------------------------------------
# 二、关卡载入 + 缺字段默认值
# ------------------------------------------------------------------
func _group_load(cfg) -> void:
	var c = CampaignRes.load_campaign(DEMO_DIR, cfg)
	ok(c != null, "样例战役能载入（含全部关卡）")
	if c == null:
		return
	eq(int(c.level_count()), 2, "样例战役载入 2 关")
	eq(String(c.level_at(0).id), "01_beachhead", "第一关 id 来自 levels[]")
	eq(String(c.level_at(0).name), "第一关·渡口", "第一关显示名来自 levels[]")
	eq(String(c.level_at(1).mode), "coop", "第二关是合作关（关卡文件里的 mode）")
	# ★★ 两个阵营都可玩（用户要求「选择两个阵营其中的一个进行游戏」）：
	#   顺序 = `present_ids()` 的顺序（本关席位在前，然后是关卡点名的参展阵营）。
	eq(c.playable_ids(), ["F1", "F2"], "战役里可玩的是 F1 与 F2")

	var lv = c.level("01_beachhead")
	ok(lv != null, "按 id 取关卡")
	if lv == null:
		return
	eq(String(lv.map_id), "dongzheng", "关卡引用的地图 id")
	ok(lv.map != null, "关卡的地图载入成功")
	eq(String(lv.mode), "solo", "单人关")
	eq(lv.seat_count(), 1, "单人关 1 个席位")
	eq(String(lv.seats()[0]), "F1", "席位是 F1")
	eq(lv.objective_zone(), 4, "目标区划是 c1")
	# ★ 断言的是**关系**（`objective_label()` 由同一份 hold_sec 拼出来），不是那一版数值。
	#   ⚠️ 原来这里写死 `90.0` / `"守住 c1 90 秒"`：那种断言会在**调平衡**（改关卡时长）时
	#   假红，而它想钉的其实是「两个函数读的是同一份数据」。数值合理性只钉「大于 0」。
	var hold: float = lv.objective_hold_sec()
	ok(hold > 0.0, "守住的秒数是正数（%s）" % str(hold))
	var label: String = lv.objective_label()
	ok(label.begins_with("守住 c1 ") and label.ends_with(" 秒"),
		"目标一句话的格式 = 「守住 <区划> <秒> 秒」（界面直接用，实际 = %s）" % label)
	ok(label.contains(str(int(roundf(hold)))) if absf(hold - roundf(hold)) < 0.001 else true,
		"那句话里的秒数与 hold_sec 一致（%s）" % label)
	eq(lv.start_buildings.size(), 1, "开局摆放 1 栋建筑")
	eq(String((lv.start_buildings[0] as Dictionary)["type"]), "tower", "摆放的是箭塔")
	# ⚠️ 顺序 = `players[]` 的席位在前，然后**关卡 `factions[]` 的声明顺序**。
	#    ★★ 样例第一关本轮多了一方：渡口守军从「挂在 F1 名下」改成**独立阵营 GD1**
	#       （`allies: ["F1","GD1"]`）—— 挂在 F1 名下时它们是**玩家自己的部队**
	#       （能选中、能下令），手玩报回来的正是这条。判定与这个名单是**同一份数据**。
	eq(lv.rosters(), ["F1", "GD1", "F2"],
		"出场名单 = 席位 + 参展阵营（蓝方 F1 / 守军 GD1 / 红方 F2）")
	ok(lv.summary().contains("单人"), "summary() 里有模式")

	# ★ 缺字段默认值：只写最少的字段，看它怎么补
	#
	# ⚠️⚠️ 这一条用 `_minimal_level`（**从零**写一份），不用 `_load_level` ——
	#   后者的补丁是盖在样例第一关之上的，而样例第一关现在写了
	#   `allies: [["F1","F2"]]`（两个可玩阵营必须互为同方），于是「没写 allies」
	#   会被悄悄继承成「写了 allies」，这条断言就验成另一件事了（实测踩到）。
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

	# 合作关的席位顺序（拍板第 18 项：房主第 1 个、客机第 2 个）
	var lc = c.level("02_twin_line")
	eq(lc.seats(), ["F1", "F2"], "合作关席位顺序 = players[] 的顺序")
	eq(lc.seat_count(), 2, "合作关两个席位")
	eq(lc.fail_conditions.size(), 1, "合作关配了一条额外失败条件")
	eq(int((lc.fail_conditions[0] as Dictionary)["zone"]), 6, "额外失败条件是 f1")


# ------------------------------------------------------------------
# 三、覆盖规则（关卡 vs 地图）
# ------------------------------------------------------------------
func _group_merge(cfg) -> void:
	# ★★ `_erase`：样例第一关现在写了 `allies`（两个可玩阵营必须互为同方），
	#    而这一组要验的是「关卡**没写** allies 时会怎样」⇒ 必须把它删掉再载入。
	var lv = _load_level(cfg, "merge_base", {"zones": [], "_erase": ["allies"]})
	ok(lv != null, "构造一个用于合并测试的关卡")
	if lv == null:
		return
	# ⚠️ 期望值来自**样例地图上的现成点位**（`data/maps/dongzheng/map.json` 的
	#    `faction_bases`）—— 它们由 `tests/_gen_demo_campaign.py` 算出来。
	#    地图一改这两条就会红，那正是它们的作用：钉住「关卡没写 base 时用的是地图的」。
	var map_base_f1 = lv.map.faction_bases.get("F1", Vector2i(-1, -1))
	var map_base_f2 = lv.map.faction_bases.get("F2", Vector2i(-1, -1))
	ok(map_base_f1.x >= 0 and map_base_f2.x >= 0, "样例地图给 F1 / F2 都划了基地")
	# ★ 地图**自己**那份归属数（合并是「返回新对象」，不许改原始地图）——
	#   先记下来，下面用它做「一个不多一个不少」的判据（不写死数字）。
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
	# ★ 关卡写了 base 就**覆盖**地图的（拿两个明显不同的点位来验）
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
	# ★ 合并**不改**关卡自己那份地图（校验必须在原始数据上跑，见 merge_over_map 的说明）：
	#    原始那份的归属就是**地图自己**写的那几个区划（样例地图现在只划 F1 的北带，
	#    其余开局无主要靠关卡 `zones[]` 决定）。这里钉的是**关系**：
	#    「合并前后，原始 map 的归属数一个都没变」。
	eq(lv.map.zones_owners.size(), lv_orig_owners,
		"★ merge_over_map 不改原始 map（原始那 %d 个归属一个不多一个不少）" % lv_orig_owners)

	# 关卡 `zones[].owner` 覆盖地图的开局归属
	var lvz = _load_level(cfg, "merge_zones", {"zones": [{"id": 6, "owner": "F1"}]})
	eq(String(lvz.map.zones_owners.get(6, "")), "", "原始地图里 f1 开场无主")
	var mergedz: Dictionary = lvz.merge_over_map(cfg.ai_factions())
	eq(String((mergedz["map"] as RefCounted).zones_owners.get(6, "")), "F1",
		"★ 关卡 zones[].owner 覆盖地图的开局归属")

	# 盟友：关卡写了就用关卡的
	var lv2 = _load_level(cfg, "merge_allies", {"allies": [["F1", "E1"]]})
	ok(lv2.allies_declared, "关卡写了 allies → declared = true")
	eq(lv2.effective_allies(), [["F1", "E1"]], "allies 用关卡的")
	ok(not lv.allies_declared, "关卡没写 allies → declared = false")
	eq(lv.effective_allies(), lv.map.allies, "关卡没写 → 用地图的")

	# 阵营表：地图没有的阵营会被追加（界面要显示它）
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

	# AI 名单：关卡写了 ai 的优先；没写的照旧吃 config（**向后兼容**）
	var stub: Array = [
		{"id": "E1", "base": Vector2i(1, 1), "resource_mult": 9.0, "start_food": 7.0, "start_gold": 7.0},
		{"id": "CONF", "base": Vector2i(2, 2), "resource_mult": 2.0, "start_food": 1.0, "start_gold": 1.0},
	]
	var lv4 = _load_level(cfg, "merge_ai", {})
	var roster: Array = lv4.merged_ai_factions(stub)
	var ids: Array = []
	for e in roster:
		ids.append(String((e as Dictionary)["id"]))
	ok(ids.has("E1"), "关卡写了 ai 的 E1 在名单里")
	ok(ids.has("CONF"), "关卡没写的阵营照旧吃 config（向后兼容）")
	for e in roster:
		var it: Dictionary = e
		if String(it["id"]) == "F2":
			# ★ 断言的是**关系**，不是调平衡用的那几个数字：
			#   「关卡写了的就用关卡那一份」= 与关卡数据里的值一致，且**不等于** config 的 9.0。
			#   ⚠️ 原来这里写死 1.6 / 700：那种断言会在**改关卡难度**时假红，
			#   而它想钉的其实是「覆盖规则走的是关卡那一份」（实测踩到）。
			var f2_meta: Dictionary = lv4.faction_config("F2")
			near(float(it["resource_mult"]), float(f2_meta["resource_mult"]), 0.001,
				"★ 关卡写了 ai 的用关卡的倍率（随关卡数据）")
			near(float(it["start_food"]), float(f2_meta["start_food"]), 0.001,
				"关卡的开局资源（随关卡数据）")
			ok(not is_equal_approx(float(it["resource_mult"]), 9.0),
				"★★ 用的**不是** config 那一份（9.0）—— 这才是「关卡覆盖生效」的判据")
			ok(bool(it["from_level"]), "关卡来的条目 from_level = true")
		if String(it["id"]) == "CONF":
			near(float(it["resource_mult"]), 2.0, 0.001, "config 的阵营用 config 的倍率")
			ok(not bool(it["from_level"]), "config 来的条目 from_level = false")

	# 关卡显式写 ai: none ⇒ **不进** AI 名单（明确关掉）
	var lv5 = _load_level(cfg, "merge_ai_none", {"factions": [{"id": "E1", "ai": "none"}, {"id": "F1"}]})
	var ids5: Array = []
	for e in lv5.merged_ai_factions(stub):
		ids5.append(String((e as Dictionary)["id"]))
	ok(not ids5.has("E1"), "★ 关卡写 ai: none ⇒ E1 不进 AI 名单（哪怕 config 里有它）")
	ok(ids5.has("CONF"), "其余 config 阵营照旧")

	# 关卡写 ai: general ⇒ 进名单但**不是**阵营 AI（靠单位上的将领性 AI）
	var lv6 = _load_level(cfg, "merge_ai_general", {
		"factions": [{"id": "E1", "ai": "general", "base": [18, 10]}]})
	var mode6 := ""
	for e in lv6.merged_ai_factions(stub):
		if String((e as Dictionary)["id"]) == "E1":
			mode6 = String((e as Dictionary)["ai"])
	eq(mode6, "general", "关卡写 ai: general ⇒ 名单里 ai = general")
	ok(not lv6.faction_ai_ids(stub).has("E1"), "★ ai: general 的不进「阵营 AI」那一份")
	ok(lv4.faction_ai_ids(stub).has("E1"), "ai: faction 的进「阵营 AI」那一份")

	# 关卡自己按阵营覆盖 AI 参数（波次节奏与规模在这里）
	var f2c: Dictionary = lv.faction_config("F2")
	var fa: Variant = f2c["faction_ai"]
	ok(typeof(fa) == TYPE_DICTIONARY, "关卡给 F2（红方攻方）配了 faction_ai")
	if typeof(fa) == TYPE_DICTIONARY:
		ok(float((fa as Dictionary)["attack_repeat_sec"]) > 0.0,
			"出兵间隔是正数（实际 %s）" % str((fa as Dictionary)["attack_repeat_sec"]))
		# ★★ `generals` 必须与「世界初始化给这一方建的将领数」一致
		#   （`world.create_generals` 一次建 3 位）。写小了不会少建、写大了会无限增兵，
		#   所以这条断言钉的是**两者对得上**，而不是某个具体数字。
		eq(int((fa as Dictionary)["generals"]), 3,
			"★ 这一方的将领数 = 世界初始化建的那 3 位（写别的值会让 AI 超额招将）")
		ok(int((fa as Dictionary)["min_ready"]) >= 1,
			"一波至少派 1 位（实际 %d）" % int((fa as Dictionary)["min_ready"]))

	# 派生入口
	eq(String((lv.faction_config("F2") as Dictionary)["ai"]), "faction",
		"faction_config 能读到 ai（红方是阵营性 AI）")
	eq(String(lv.faction_config("F1")["ai"]), "general",
		"★ 蓝方挂的是将领性（守家）AI —— 只守 c1 周边、不反推")
	eq(String(lv.attack_target_of("F2").get("kind")), "zone",
		"attack_target_of 读到红方的进攻目标（指向 c1）")
	ok(lv.attack_target_of("F1") == null, "没写的阵营 → attack_target 是 null")
	# ⚠️ 「可玩」是**战役级**属性，而 `_load_level` 造出来的关卡**不属于任何战役**
	#    （`campaign == null`）—— 所以这里必须用**真的那份战役**来验它。
	ok(not lv.is_playable("F1"), "没挂战役时谁也谈不上「可玩」（可玩是战役级属性）")
	var c_demo = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv_demo = c_demo.level("01_beachhead")
	ok(lv_demo.is_playable("F1"), "样例战役里 F1 可玩")
	ok(lv_demo.is_playable("F2"), "★ 样例战役里 F2 也可玩（两个阵营任选一个）")
	eq(lv_demo.playable_ids(), ["F1", "F2"], "样例关卡可玩阵营 = [F1, F2]")
	# ★★ 这个样例关卡是**「选边关」**：两个可玩阵营各有一条属于自己的目标
	#    （蓝方守 c1 / 红方攻 c1），所以它们**不是**同盟 —— 这正是设计。
	#    「可玩阵营必须互为同方」那条规则只在**普通关卡**（目标只有一份）上成立，
	#    见 `logic/level.gd` 的 `_ck_allies()` 第 7 条那两条分支。
	ok(not FactionRes.same_side_for_attack("F1", "F2"),
		"★ 选边关里两个可玩阵营是**对立的**（蓝方守 / 红方攻）")
	# ★ 每条目标都点名给了谁 —— 这是「选谁就打谁那条」的依据
	ok(lv_demo.has_per_faction_objectives(), "★ 第一关是按阵营分开的目标（选边关）")
	eq(String(lv_demo.objective_of("F1")["kind"]), "hold_zone", "蓝方的目标是守住")
	eq(String(lv_demo.objective_of("F2")["kind"]), "capture_zone", "红方的目标是攻占")
	eq(int(lv_demo.objective_of("F1")["zone"]), int(lv_demo.objective_of("F2")["zone"]),
		"两边打的是**同一个**区划（c1）")


# ------------------------------------------------------------------
# 四、2.5 那 16 条校验（**每条各造一个坏样例**）
# ------------------------------------------------------------------
func _group_check(cfg) -> void:
	# 先验：样例战役的两关都通过（一个 block 都没有）
	var c = CampaignRes.load_campaign(DEMO_DIR, cfg)
	for lv in c.levels:
		var issues: Array = lv.check(cfg.ai_factions())
		var blocks: Array = lv.blockers()
		var detail := ""
		for b in blocks:
			detail += " / %s" % String((b as Dictionary)["msg"])
		ok(blocks.is_empty(), "样例关卡「%s」没有拦截项%s" % [String(lv.name), detail])
		ok(issues.size() == 0, "样例关卡「%s」连警告都没有" % String(lv.name))

	# 每条规则一个坏样例：patch = 改哪几个字段，code = 期望命中的校验码
	var cases: Array = [
		# 1) 地图不存在 / 没写
		[{"map": "no_such_map"}, "map_not_found"],
		[{"map": ""}, "map_missing_field"],
		# 2) 席位数
		[{"mode": "solo", "players": [{"faction": "F1"}, {"faction": "F2"}]}, "players_count_solo"],
		[{"mode": "coop", "players": [{"faction": "F1"}]}, "players_count_coop"],
		[{"players": []}, "players_empty"],
		# 3) 两个玩家占同一阵营
		[{"mode": "coop", "players": [{"faction": "F1"}, {"faction": "F1"}]}, "players_same_faction"],
		# 4) 非玩家方没有大本营：★ 用一个「config 里有、地图与关卡都没有」的阵营来造
		#    （地图上划过的阵营天然有基地，拿它测不出这一条）
		[{"factions": [{"id": "F1"}, {"id": "CONF2", "ai": "faction"}]}, "faction_no_base",
			[{"id": "CONF2"}]],
		# 5) 大本营压在区划中心上（c1 的中心是 (5,12)）
		[{"players": [{"faction": "F1", "base": [5, 12]}]}, "point_on_zone_center"],
		# 6) 大本营落在山里 / 地图外
		[{"players": [{"faction": "F1", "base": [0, 9]}]}, "point_on_mountain"],
		[{"players": [{"faction": "F1", "base": [99, 99]}]}, "point_outside"],
		[{"start_units": [{"faction": "E1", "kind": "enemy", "x": 0, "y": 9}]}, "point_on_mountain"],
		# 7) ★ 可玩阵营必须互为同方（**普通关卡**：目标只有一份、走同一方判定）
		#    ★★ 样例第一关现在是「选边关」（**每个可玩阵营都有带 `for` 的目标**），
		#    走的是另一条口径（7b）—— 所以这里要用一份**没有 per-faction 目标**的关卡
		#    来造「两个可玩阵营各占一边」：清掉 `objectives[].for`，让目标变成通用的。
		[{"allies": [], "_playable": ["F1", "F2"],
			"objectives": [{"kind": "hold_zone", "zone": 4, "hold_sec": 10}]},
			"playable_not_same_side"],
		# 7b) ★★ 选边关：每个可玩阵营都要有属于它的目标（漏一个 = 选了没得打）
		#    ⚠️ 造这个坏样例要**显式给 `_playable`**：`_load_level` 造出来的关卡
		#       不属于任何战役 ⇒ `playable` 是空的（`is_playable()` 全 false）——
		#       不给覆盖的话「可玩阵营」一个都没有，这条规则根本不会被触发。
		[{"_playable": ["F1", "F2"],
			"objectives": [{"for": "F1", "kind": "hold_zone", "zone": 4, "hold_sec": 10},
				{"for": "F3", "kind": "hold_zone", "zone": 5, "hold_sec": 10}]},
			"playable_no_objective"],
		# 8) ★ 目标区划开局不归这一方 / 无主（空串 = 显式清空那一格的归属）
		[{"zones": [{"id": 4, "owner": "F2"}]}, "objective_not_players"],
		[{"zones": [{"id": 4, "owner": ""}]}, "objective_unowned"],
		# 8b) ★★ 攻占类的反面：目标区划开局就归自己 ⇒ 一进关就判胜，必须拦。
		#     用两份 patch（普通关 + 两条带 `for` 的目标里红方那条是 capture_zone）
		[{"zones": [{"id": 4, "owner": "F2"}],
			"objectives": [{"for": "F1", "kind": "hold_zone", "zone": 4, "hold_sec": 10},
				{"for": "F2", "kind": "capture_zone", "zone": 4}]}, "objective_already_mine"],
		# 9) 目标条数 / 种类 / 秒数 / 区划存在
		[{"objectives": []}, "objective_empty"],
		[{"objectives": [{"kind": "hold_zone", "zone": 4, "hold_sec": 10},
			{"kind": "hold_zone", "zone": 5, "hold_sec": 10}]}, "objective_too_many"],
		[{"objectives": [{"kind": "hold_zone", "zone": 4, "hold_sec": 0}]}, "objective_hold_sec"],
		[{"objectives": [{"kind": "hold_zone", "zone": 99, "hold_sec": 10}]}, "objective_zone_missing"],
		# ⚠️ `capture_zone` 现在是**认识的**种类了（一关两目标用的就是它），
		#    所以「种类不认识」这条要用一个真的不存在的名字来造。
		[{"objectives": [{"for": "F2", "kind": "teleport_zone", "zone": 4}]}, "objective_kind"],
		# 10) 进攻目标：区划不存在 / 地图外 / 山地 / 种类不认识 / 指向没有家的一方
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
		# 11) 额外失败条件：不能是目标区划 / 区划必须存在 / 种类认识
		[{"fail_conditions": [{"kind": "zone_lost", "zone": 4}]}, "fail_zone_is_objective"],
		[{"fail_conditions": [{"kind": "zone_lost", "zone": 99}]}, "fail_zone_missing"],
		[{"fail_conditions": [{"kind": "all_units_dead"}]}, "fail_kind"],
		# 11b) ★★ 额外失败条件的区划开局也必须归玩家同方（否则第一帧就判负）
		#     f1（id=6）在样例地图上开场无主 —— 直接拿它当失败条件就是那个坑
		[{"fail_conditions": [{"kind": "zone_lost", "zone": 6}]}, "fail_zone_unowned"],
		# 给 c2（id=3）显式划给敌方 AI（F2）—— 额外失败条件的区划不许开局就归敌人
		[{"zones": [{"id": 3, "owner": "F2"}],
			"fail_conditions": [{"kind": "zone_lost", "zone": 3}]}, "fail_zone_not_players"],		# 12) 挂了将领性 AI 却没有归属区划
		[{"start_units": [{"faction": "E1", "kind": "enemy", "x": 10, "y": 4, "ai": "general"}]},
			"unit_general_no_zone"],
		# 13) 关卡摆放里用到的 faction 没有定义
		[{"start_units": [{"faction": "NOPE", "kind": "enemy", "x": 10, "y": 4}]}, "faction_unknown"],
		[{"start_buildings": [{"type": "tower", "x": 11, "y": 11, "owner": "NOPE"}]}, "faction_unknown"],
		# 4) 关卡点名了一个**地图上完全没有**的阵营、又不给大本营 —— 必须拦
		[{"factions": [{"id": "ZZ", "ai": "faction"}]}, "faction_no_base"],
	]
	var _case_seq := 0
	for entry in cases:
		var patch: Dictionary = (entry as Array)[0]
		var code := String((entry as Array)[1])
		# 可选的第三项 = 这一条要用**哪一份**全局 AI 名单来校验（缺省 = 工程里那一份）
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

	# 14/15/16) 三条**警告**（不是拦截）
	var warn_cases: Array = [
		# 14) 进攻目标指向自己的地（把 c1 划给 AI 那一方，它再打 c1 就是打自己的地）
		[{"zones": [{"id": 4, "owner": "F2"}],
			"factions": [{"id": "F2", "ai": "faction", "base": [10, 1],
				"attack_target": {"kind": "zone", "zone": 4}}]}, "attack_target_own_land"],
		# 16) 盟友表里有未定义的阵营
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

	# 15) 一个都没写进攻目标 → 警告（**不是**拦截：那是设计者的自由）
	#
	# ⚠️⚠️ 补丁必须**连 `start_units` 一起换掉**：样例第一关本轮摆了
	#    F1 / GD1 / F2 三方的单位（`start_units[]`），只换 `factions[]` 的话
	#    那些摆放单位指向的阵营就「没有定义」了 ⇒ 校验第 13 条会**正确地**报
	#    `faction_unknown`（拦截），于是这条断言验的就不再是「进攻目标」那件事。
	var lv3 = _load_level(cfg, "warn_no_target", {
		"factions": [{"id": "E1", "ai": "faction", "base": [18, 10]}],
		"start_units": [{"faction": "E1", "kind": "enemy", "x": 18, "y": 10}]})
	var issues3: Array = lv3.check(cfg.ai_factions())
	var found3 := ""
	for i in issues3:
		if String((i as Dictionary)["code"]) == "no_attack_target":
			found3 = String((i as Dictionary)["msg"])
	ok(found3 != "", "★ 全都没写进攻目标 → 警告")
	ok(not lv3.has_blocker(), "全都没写进攻目标**不拦**导出")

	# 警告与拦截分开两个入口
	ok(lv3.warnings().size() >= 1, "warnings() 能拿到警告")
	for i in lv3.warnings():
		eq(String((i as Dictionary)["sev"]), "warn", "warnings() 里全是 warn")


# ------------------------------------------------------------------
# 五、坏输入
# ------------------------------------------------------------------
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
	# 坏的那一关**跳过、不冒泡**，好的照旧在（一张坏数据不该让整个列表空掉）
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
	# 「地图不存在」的关卡**能载入**（载入失败的是 map 对象），但一定会被校验拦住 ——
	# 这是有意的：界面要能打开它、并告诉设计者「地图没了」。
	var lv = LevelRes.load_level(null, "%s/levels/ok2.json" % bad, cfg)
	var lv_bad = _load_level(cfg, "bad_map", {"map": "nope"})
	ok(lv_bad != null, "地图不存在的关卡照样能载入（界面要能打开并报错）")
	ok(lv_bad.map == null, "地图不存在时 map 是 null")
	lv_bad.check(cfg.ai_factions())
	ok(lv_bad.has_blocker(), "地图不存在的关卡必然被校验拦住")


# ------------------------------------------------------------------
# 六、真文件一字未改
# ------------------------------------------------------------------
func _group_files_untouched() -> void:
	eq(_hash_tree(DEMO_DIR), _demo_hash, "★ data/campaigns/demo 一个字节都没被测试改坏")
	eq(_hash_file(DEMO_MAP), _demo_map_hash, "★ data/maps/dongzheng/map.json 没被改坏")

	# ★★ 战役专用图（`hidden: true`）不许改变**自由对战**的既有行为：
	#   · 「不选就按 test」进的那张图不能因为多了一张战役图而换掉；
	#   · 战役图不进地图选择条（它有剧情与平衡，不是试炼场的一张图）；
	#   · 但关卡照样能按 id 引用它（上面那些 `_load_level` 用例已经验过）。
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


# ------------------------------------------------------------------
# 工具
# ------------------------------------------------------------------

## 用样例关卡做模板、按 patch 改几个字段，写进临时目录再**走真实载入路径**读回来。
func _load_level(cfg, name: String, patch: Dictionary):
	var raw := _demo_level_raw()
	if raw.is_empty():
		return null
	for k in patch.keys():
		if String(k) == "_playable" or String(k) == "_erase":
			continue
		raw[k] = patch[k]
	# ★★ `_erase`：把继承自样例关卡的那几个键**删掉**，用来验「这个键没写会怎样」。
	#
	# 为什么需要一个独立的开关（而不是传 `"allies": []`）：
	#   补丁是**盖在样例第一关之上**的，所以「不写 allies」这件事没法用补丁表达 ——
	#   样例第一关现在写了 `allies: [["F1","F2"]]`（两个可玩阵营必须互为同方，校验第 7 条）。
	#   而 `allies_declared` 判的是**这个键在不在**（`logic/level.gd`），
	#   传空数组等于「写了但是空的」—— 语义完全不同，会把断言验成另一件事。
	if patch.has("_erase"):
		for k2 in (patch["_erase"] as Array):
			raw.erase(String(k2))
	var p := "%s/%s/levels/l.json" % [TMP_ROOT, name]
	_write(p, JSON.stringify(raw))
	var lv = LevelRes.load_level(null, p, cfg)
	if lv == null:
		return null
	# `_playable`：把「这一战哪几方可以玩」显式覆盖掉（校验第 7 条要用它）
	if patch.has("_playable"):
		var ov: Array = []
		for fid in (patch["_playable"] as Array):
			ov.append(String(fid))
		lv.playable_override = ov
	return lv


## 直接写一份**最小**关卡文件（不继承样例关卡的任何东西）。
##
## ⚠️ 「缺字段默认值」那一组必须用**这个**，不能用 `_load_level` ——
##    补丁是盖在样例关卡之上的，样例里写过的键（现在有 `allies`）会悄悄继承下来，
##    于是「没写 X → 用缺省」这类断言验的其实是「样例里那份 X」。
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
