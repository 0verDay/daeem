## test_tutorial_ce_xs_2.gd —— 新手教程 2（ce_xs_2）的数据 / 剧本流程。
##
## 纯逻辑：宿主 null，对话自动推进；wait_until 由测试手动满足。
## 钉住：c0 无主 + 建筑不占区、初始 10 vs 3、建设计数、偏移扩图、
##       三个敌方阵地、占领三区 → 胜利。
extends "res://tests/test_case.gd"

const CampaignLibraryRes = preload("res://logic/campaign_library.gd")
const WorldRes = preload("res://logic/world.gd")
const StoryDirectorRes = preload("res://logic/story/story_director.gd")
const CombatRes = preload("res://logic/combat.gd")


func _initialize() -> void:
	_case_name = "test_tutorial_ce_xs_2"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	var camp = _load_campaign(cfg)
	if camp == null:
		return
	var lv = camp.level("ce_xs_2")
	ok(lv != null, "★ 教程关卡 ce_xs_2 能载入")
	if lv == null:
		return
	_test_level_data(cfg, lv)
	var w = WorldRes.create_from_level(cfg, lv, "p1", lv.build_roster(cfg, "p1"), true)
	ok(w != null, "★ ce_xs_2 能建出世界")
	if w == null:
		return
	_test_flow(cfg, w)


func _load_campaign(cfg):
	var option := {}
	for item in CampaignLibraryRes.list_campaigns(cfg):
		if String((item as Dictionary).get("id", "")) == "tutorial":
			option = item
			break
	ok(not option.is_empty(), "★ 战役目录能扫到 tutorial")
	if option.is_empty():
		return null
	return CampaignLibraryRes.load_campaign_by_option(option, cfg)


func _test_level_data(cfg, lv) -> void:
	eq(String(lv.map_id), "ce_xs_2_a", "★ 初始地图 id = ce_xs_2_a")
	ok(String(lv.map_path).ends_with("ce_xs_2_a.json"), "★ 初始地图指向 A 图")
	ok(bool(lv.story_driven), "★ 剧情关")
	ok(bool(lv.no_player_base), "★ 不自动建大本营")
	ok(bool(lv.no_building_zone_claim), "★★ 本关建筑不占区")
	eq(String(lv.faction_config("p1").get("clan", "")), "dynasty", "★ 玩家 = 王朝")
	eq(String(lv.faction_config("enemy").get("ai", "")), "garrison",
		"★ 敌人使用阵地性 AI")
	var blocks := 0
	for issue in lv.check(cfg.ai_factions()):
		if String((issue as Dictionary).get("sev", "")) == "block":
			blocks += 1
	eq(blocks, 0, "★★ 关卡没有 block 级校验问题")
	var b = load("res://logic/map_data.gd").load_from(
		"res://data/maps/ce_xs_2/ce_xs_2_b.json", cfg)
	ok(b != null, "★ B 图能载入")
	if b != null:
		ok(int(b.cols) > int(lv.map.cols), "★★ B 图比 A 图大")


func _test_flow(cfg, w) -> void:
	var z0 = w.zone_by_id(0)
	eq(String(z0.get("owner", "")), "", "★ c0 开局无主")
	eq(int(w.zone_by_id(0).get("population", 0)), 20, "★ c0 初始人口 20")

	var d = StoryDirectorRes.new()
	ok(d.setup(null, w, "tutorial", "ce_xs_2"), "★ ce_xs_2 剧本能装配")
	d.tick(0.016, [])

	# 1) 基地 + 双方部队
	var base = w.find_base_of("p1")
	ok(base != null, "★★ 步骤 1：玩家大本营存在")
	if base != null:
		eq(Vector2i(int(base.tx), int(base.ty)), Vector2i(5, 7), "★★ 大本营在 (5,7)")
		ok(not base.is_under_construction(), "★ 大本营已建成")
	eq(String(w.zone_by_id(0).get("owner", "")), "",
		"★★ 基地放下后 c0 仍无主（建筑不占区）")
	eq(_count_units(w, "p1"), 10, "★★ 步骤 2：己方 10 个单位")
	eq(_count_generals(w, "p1"), 2, "★★ 己方 2 个将领")
	eq(_count_type(w, "p1", "dy_spear_guard"), 4, "★★ 己方 4 个协防军枪")
	eq(_count_type(w, "p1", "dy_archer_guard"), 4, "★★ 己方 4 个协防军弓")
	eq(_count_units(w, "enemy"), 3, "★★ 步骤 2：敌方 3 个单位")
	eq(_count_generals(w, "enemy"), 1, "★ 敌方 1 个枪将")
	eq(_count_type(w, "enemy", "dy_spear_guard"), 1, "★ 敌方 1 个枪")
	eq(_count_type(w, "enemy", "dy_archer_guard"), 1, "★ 敌方 1 个弓")
	ok(not d.is_input_allowed("select"), "★★ 步骤 2：开局锁输入")
	ok(not d.is_input_allowed("order"), "★ 移动也锁")

	# 3) 真实推演开场战斗（不手动改归属）：双方自动行军，玩家应打下 c0。
	var battle_won := false
	for i in 1200:
		w.tick(1.0 / 30.0)
		d.tick(1.0 / 30.0, [])
		if String(w.zone_by_id(0).get("owner", "")) == "p1":
			battle_won = true
			break
	ok(battle_won, "★★ 步骤 3：初始战斗自动打下 c0")
	ok(d.is_input_allowed("select"), "★★ 步骤 3：占领 c0 后解锁输入")
	ok(d.is_input_allowed("order"), "★ 移动解锁")
	# 记一个旧单位，扩图后验证它整体平移 (14,13)
	var sample = null
	for u in w.units:
		if u != null and u.alive and String(u.faction) == "p1":
			sample = u
			break
	var sample_pos := Vector2.ZERO
	var sample_tx := -1
	var sample_ty := -1
	if sample != null:
		sample_pos = sample.pos
		sample_tx = int(sample.tx)
		sample_ty = int(sample.ty)
	ok(float(w.resources.get("food", 0.0)) >= 1000.0, "★★ 步骤 5：1000 粮食")
	ok(float(w.resources.get("gold", 0.0)) >= 1000.0, "★★ 步骤 5：1000 黄金")
	var title := String(w.story_objective.get("title", ""))
	eq(title, "建立防御0/6 建造粮田0/2", "★★ 步骤 6：建设目标标题")
	eq(String(w.story_objective.get("desc", "")),
		"在建筑页签中选择哨塔/木墙/粮田进行建造", "★ 建设目标描述")
	ok(bool(w.story_objective.get("quiet", false)), "★ 计数目标不重播打字机")

	# 6) 建 5 个防御 + 1 块田：计数应实时更新，但还不能完成
	for i in 5:
		_add_building(w, "wall" if i % 2 == 0 else "tower")
	_add_building(w, "farm")
	d.tick(0.016, [])
	eq(String(w.story_objective.get("title", "")),
		"建立防御5/6 建造粮田1/2", "★★ 计数实时更新（5/6、1/2）")
	eq(int(w.map.cols), 14, "★ 未完成前不扩图")

	# 补满 6 防御 + 2 田 → 扩图
	_add_building(w, "tower")
	_add_building(w, "farm")
	d.tick(0.016, [])
	eq(int(w.map.cols), 42, "★★ 步骤 7：扩图到 ce_xs_2_b（42 列）")
	eq(int(w.map.rows), 24, "★★ 扩图后 24 行")
	var z0b = w.zone_by_id(0)
	ok(z0b != null, "★ 扩图后 c0 仍在")
	if z0b != null:
		eq(String(z0b.get("owner", "")), "p1", "★ 旧区划归属保留")
		eq(Vector2i(z0b.get("center", Vector2i(-1, -1))), Vector2i(22, 20),
			"★★ c0 中心按偏移 (14,13) 平移")
	if base != null and is_instance_valid(base):
		eq(Vector2i(int(base.tx), int(base.ty)), Vector2i(19, 20),
			"★★ 大本营随地图偏移平移到 (19,20)")
	if sample != null:
		eq(Vector2i(int(sample.tx), int(sample.ty)),
			Vector2i(sample_tx + 14, sample_ty + 13), "★★ 旧单位格子随偏移平移")
		ok(sample.pos.is_equal_approx(sample_pos + Vector2(14, 13)),
			"★★ 旧单位坐标随偏移平移")
	for zid in [1, 2, 3]:
		eq(String(w.zone_by_id(zid).get("owner", "")), "enemy",
			"★★ 步骤 7：c%d 判给敌人" % zid)

	# 三个区划各 1 将 + 6 兵，绑到该区划
	for zid in [1, 2, 3]:
		var leaders := []
		for u in w.units:
			if u == null or not u.alive:
				continue
			if String(u.faction) != "enemy" or int(u.garrison_zone_id) != zid:
				continue
			if String(u.leader_id) == "":
				leaders.append(u)
		eq(leaders.size(), 1, "★★ c%d 有 1 个阵地将领" % zid)
		if leaders.size() == 1:
			var g = leaders[0]
			var retinue: Array = w.retinue_of(String(g.id), true)
			eq(retinue.size(), 6, "★★ c%d 将领带 6 个附属兵" % zid)
			var spears := 0
			var archers := 0
			for e in retinue:
				if String(e.unit_type) == "dy_spear_guard":
					spears += 1
				elif String(e.unit_type) == "dy_archer_guard":
					archers += 1
			eq(spears, 3, "★★ c%d 附属兵 3 枪" % zid)
			eq(archers, 3, "★★ c%d 附属兵 3 弓" % zid)
			ok(bool(g.hold_position), "★ c%d 将领原地驻守" % zid)

	# 7b) 靠 c0 的两格边带是禁行区
	var no1: Array = w.zones.no_go_tiles_of(1)
	ok(no1.size() >= 10, "★★ c1 有靠 c0 的两行禁行区（%d 格）" % no1.size())
	ok(w.zones.is_no_go(1, 20, 12), "★★ c1 底行 (20,12) 禁行")
	ok(not w.zones.is_no_go(1, 20, 10), "★ c1 远离 c0 的格不禁行")
	ok(w.zones.is_no_go(2, 28, 20), "★★ c2 靠 c0 的两列禁行")
	ok(w.zones.is_no_go(3, 13, 20), "★★ c3 靠 c0 的两列禁行")

	# 8) 对话 + 9) 占领任务
	eq(String(w.story_objective.get("title", "")), "占领剩余区划0/3",
		"★★ 步骤 9：占领任务标题")

	# ★★ 守军不自动索敌自己区划外的玩家建筑：
	#   在 c0 再放一座塔；c1 守军 aggro=100 时旧逻辑一定会选中它。
	ok(_add_building(w, "tower"), "（前提）c0 里放一座玩家塔")
	var g1 = null
	for u in w.units:
		if u != null and u.alive and String(u.faction) == "enemy" \
				and int(u.garrison_zone_id) == 1 and String(u.leader_id) == "":
			g1 = u
			break
	ok(g1 != null, "（前提）找到 c1 守将")
	if g1 != null:
		ok(CombatRes.nearest_enemy_building(w, w.cfg, g1, 100.0) == null,
			"★★ 阵地守军不会自动索敌自己区划外的玩家建筑")

	var captured := 0
	for zid in [1, 2, 3]:
		w.zone_by_id(zid)["owner"] = "p1"
		captured += 1
		d.tick(0.016, [])
		eq(String(w.story_objective.get("title", "")),
			"占领剩余区划%d/3" % captured, "★★ 占领计数实时更新 %d/3" % captured)
	eq(String(w.objective_state.get("state", "")), "won", "★★ 占领三区后胜利")


# ------------------------------------------------------------------
func _count_units(w, faction: String) -> int:
	var n := 0
	for u in w.units:
		if u != null and u.alive and String(u.faction) == faction:
			n += 1
	return n


func _count_generals(w, faction: String) -> int:
	var n := 0
	for u in w.units:
		if u != null and u.alive and String(u.faction) == faction \
				and String(u.kind) == "general":
			n += 1
	return n


func _count_type(w, faction: String, unit_type: String) -> int:
	var n := 0
	for u in w.units:
		if u != null and u.alive and String(u.faction) == faction \
				and String(u.kind) != "general" \
				and String(u.unit_type) == unit_type:
			n += 1
	return n


func _add_building(w, type: String) -> bool:
	for y in int(w.map.rows):
		for x in int(w.map.cols):
			if w.building_at(x, y) != null:
				continue
			if not w.map.terrain_walkable(x, y):
				continue
			var z = w.zones.zone_at(x, y)
			if z == null or int((z as Dictionary).get("id", -1)) != 0:
				continue
			if w.add_building(type, x, y, "p1", true, true, "") != null:
				return true
	return false
