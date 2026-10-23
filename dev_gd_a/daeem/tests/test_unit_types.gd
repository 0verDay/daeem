## test_unit_types.gd —— 单位类型（兵种）与「步兵 / 骑兵」标签，以及地图上的 2D 图标
extends "res://tests/test_case.gd"

const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const UnitIconRes = preload("res://view/unit_icon.gd")
const SnapshotRes = preload("res://logic/snapshot.gd")

const DT := 1.0 / 60.0

const ESCORTS_PER_GENERAL := 3

func _initialize() -> void:
	_case_name = "test_unit_types"
	_run()

func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	_test_class_tags(cfg)
	_test_general_types(cfg)
	_test_recruit_all_three(cfg)
	_test_icons(cfg)
	_test_icon_chars(cfg)
	cleanup_escort_scaffold()

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)

func _test_class_tags(cfg) -> void:
	eq(cfg.unit_class_of(UnitRes.UNIT_TYPE_SPEARMAN), ConfigRes.CLASS_INFANTRY, "长枪兵属于步兵")
	eq(cfg.unit_class_of(UnitRes.UNIT_TYPE_LONGBOWMAN), ConfigRes.CLASS_INFANTRY, "长弓兵属于步兵")
	eq(cfg.unit_class_of(UnitRes.UNIT_TYPE_RIDER), ConfigRes.CLASS_CAVALRY, "骑手属于骑兵")
	ok(not cfg.unit_is_ranged(UnitRes.UNIT_TYPE_SPEARMAN), "长枪兵是近战")
	ok(cfg.unit_is_ranged(UnitRes.UNIT_TYPE_LONGBOWMAN), "★ 长弓兵是远程（需求：弓箭手算作远程步兵）")
	ok(not cfg.unit_is_ranged(UnitRes.UNIT_TYPE_RIDER), "骑手是近战骑兵")

	eq(cfg.unit_class_name(UnitRes.UNIT_TYPE_RIDER), "骑兵", "大类显示名 = 骑兵")
	eq(cfg.unit_class_line(UnitRes.UNIT_TYPE_SPEARMAN), "步兵", "近战步兵的标签就是「步兵」")
	eq(cfg.unit_class_line(UnitRes.UNIT_TYPE_LONGBOWMAN), "远程步兵", "★ 长弓兵的标签 = 远程步兵")
	eq(cfg.unit_class_line(UnitRes.UNIT_TYPE_RIDER), "骑兵", "骑手的标签 = 骑兵")

	eq(String(cfg.get_path_value("unit.classes.cavalry.ranged_name")), "远程骑兵",
		"★ 骑兵那一档也备着「远程骑兵」（马弓手的标签有地方放）")
	eq(String(cfg.get_path_value("unit.classes.infantry.ranged_name")), "远程步兵",
		"步兵那一档备着「远程步兵」")

	for id in cfg.unit_type_ids():
		var t := String(id)
		var entry: Dictionary = cfg.unit_type_entry(t)
		ok(entry.has("class") and String(entry["class"]) != "", "%s 有兵种大类" % t)
		ok(typeof(entry.get("ranged")) == TYPE_BOOL, "%s 的 ranged 是布尔量" % t)
		ok(cfg.unit_class_name(t) != "", "%s 的大类有显示名" % t)
		ok(String(entry.get("name", "")) != "", "%s 有显示名" % t)

	ok(not cfg.has_unit_type("enemy"),
		"★★ unit.types 里不再有「测试敌人」（已并入长枪兵）")

	eq(cfg.unit_class_of("no_such_type"), ConfigRes.CLASS_INFANTRY, "未知类型的大类是步兵（兜底）")
	ok(not cfg.unit_is_ranged("no_such_type"), "未知类型当成近战（兜底）")
	near(cfg.unit_hp_of("no_such_type"), cfg.unit_hp_max, 1e-6, "未知类型退回兜底血量")
	ok(cfg.unit_name_of("no_such_type") != "", "未知类型也有个显示名（不返回空串）")

func _test_general_types(cfg) -> void:
	var w = require_world_with_escorts(cfg, ESCORTS_PER_GENERAL)
	var types: Array = cfg.general_types()
	eq(types.size(), 9, "配置里给了九位将领的类型（前 3 位开局 + 后 6 位招募池）")

	var expect: Array = [
		UnitRes.UNIT_TYPE_SPEARMAN, UnitRes.UNIT_TYPE_LONGBOWMAN, UnitRes.UNIT_TYPE_RIDER,
		UnitRes.UNIT_TYPE_SPEARMAN, UnitRes.UNIT_TYPE_LONGBOWMAN, UnitRes.UNIT_TYPE_RIDER,
		UnitRes.UNIT_TYPE_SPEARMAN, UnitRes.UNIT_TYPE_LONGBOWMAN, UnitRes.UNIT_TYPE_RIDER,
	]
	eq(types, expect, "★ 九位将领按长枪兵 / 长弓兵 / 骑手循环")

	for i in 3:
		var g = w.unit_by_id("general-%d" % (i + 1))
		ok(g != null, "有 general-%d" % (i + 1))
		if g == null:
			continue
		var want := String(types[i])
		eq(g.kind, UnitRes.KIND_GENERAL, "将领的 kind 仍是 general（队伍 / 招募都按它判）")
		eq(String(g.unit_type), want, "★ general-%d 的类型是 %s" % [i + 1, want])
		ok(g.is_general(), "★ is_general() 为真（描边加粗与将领科技共用这条判据）")
		near(g.hp_max, cfg.unit_hp_of(want), 1e-6, "将领血量 = 类型血量")
		near(g.combat_damage(cfg), float(cfg.unit_combat_of(want)["damage"]), 1e-6, "将领伤害 = 类型伤害")
		near(g.combat_range(cfg), float(cfg.unit_combat_of(want)["range"]), 1e-6, "将领射程 = 类型射程")
		near(g.combat_cooldown(cfg), float(cfg.unit_combat_of(want)["cooldown_sec"]), 1e-6,
			"将领间隔 = 类型间隔")
		eq(g.unit_class, cfg.unit_class_of(want), "将领的兵种大类")
		eq(g.ranged, cfg.unit_is_ranged(want), "将领的远近标记")

	for i in 3:
		var g2 = w.unit_by_id("general-%d" % (i + 1))
		var want_n: int = ESCORTS_PER_GENERAL
		var ret = w.retinue_of(g2.id)
		eq(ret.size(), want_n, "general-%d 带 %d 个附属兵（关卡摆的）" % [i + 1, want_n])
		for s in ret:
			eq(String(s.unit_type), String(g2.unit_type), "★ 附属兵与将领同类型")
			eq(s.kind, String(g2.unit_type), "附属兵的 kind 就是它的类型")
			ok(not s.is_general(), "附属兵不是将领")

	var g2b = w.unit_by_id("general-2")
	ok(g2b.combat_range(cfg) > 1.0, "★ 长弓兵将领是远程（射程 %.1f 格）" % g2b.combat_range(cfg))
	ok(cfg.unit_speed_of(UnitRes.UNIT_TYPE_RIDER) > cfg.unit_speed_of(UnitRes.UNIT_TYPE_SPEARMAN),
		"★ 骑手比长枪兵快（%.2f > %.2f）" % [
			cfg.unit_speed_of(UnitRes.UNIT_TYPE_RIDER), cfg.unit_speed_of(UnitRes.UNIT_TYPE_SPEARMAN)])
	var g3 = w.unit_by_id("general-3")
	eq(String(g3.unit_type), UnitRes.UNIT_TYPE_RIDER, "★ general-3 是骑手（所以它跑得比将领 1 快）")

	for i in 3:
		eq(cfg.unit_type_of("general_%d" % (i + 1)), String(types[i]),
			"general_%d 的类型与第 %d 个开局将领一致" % [i + 1, i + 1])

func _test_recruit_all_three(cfg) -> void:
	cfg.combat_enabled = false
	var w = require_world(cfg)
	var kept: Array = []
	for u in w.units:
		if u.faction == w.my_faction:
			kept.append(u)
	w.units = kept

	var g1 = w.unit_by_id("general-1")
	w.resources["food"] = 5000.0
	w.resources["gold"] = 5000.0
	w.zones.zone_at(g1.tx, g1.ty)["population"] = 100.0

	# ★★ 这里要的是「单位页能招的三个兵种」，不是将领名册 ——
	#    将领名册（general_types）本轮扩到了 9 位，拿它当招募表会去招将领。
	var types: Array = []
	for item in w.recruit_list():
		types.append(String((item as Dictionary).get("kind", "")))
	eq(types.size(), 3, "三个可招募兵种")
	for t in types:
		var tt := String(t)
		ok(w.is_recruitable(tt), "★ %s 在 config.recruit.list 里" % tt)
		ok(w.recruit_short_of(tt) != "", "%s 有短名（信息栏格子要写）" % tt)
		ok(w.recruit_label_of(tt) != tt, "%s 有显示名" % tt)
		ok(w.recruit_train_sec(tt) > 0.0, "%s 有读条时间" % tt)

	var before: int = w.retinue_of(g1.id).size()
	for t2 in types:
		ok(w.start_recruit(String(t2), g1.id, "p1"), "排 %s 进队列" % t2)
	for _i in int(ceil(32.0 / DT)):
		w.tick(DT)
	eq(w.retinue_of(g1.id).size(), before + 3, "★ 三单都读完了（名下多 3 个）")

	var got: Array = []
	var all_ret: Array = w.retinue_of(g1.id)
	for i in range(all_ret.size() - 3, all_ret.size()):
		got.append(String(all_ret[i].unit_type))
	eq(got, [String(types[0]), String(types[1]), String(types[2])],
		"★ 招出来的三个单位类型就是三个兵种（一个不多一个不少）")

	var fresh = all_ret[all_ret.size() - 1]
	eq(fresh.leader_id, g1.id, "新兵挂在招它的将领名下")
	near(fresh.hp_max, cfg.unit_hp_of(String(fresh.unit_type)), 1e-6, "新兵血量走自己的类型")
	ok(fresh.alive and w.map.terrain_walkable(fresh.tx, fresh.ty), "新兵站在可通行格上")
	cfg.combat_enabled = true

func _test_icons(cfg) -> void:
	ok(UnitIconRes.EXTENT > UnitIconRes.DISC_R, "贴图半宽装得下圆盘")
	ok(UnitIconRes.EXTENT >= UnitIconRes.DISC_R + UnitIconRes.OUTLINE_W_LEADER,
		"★ 最粗的那一圈描边也不会被贴图边缘切掉（%.2f + %.2f <= %.2f）"
			% [UnitIconRes.DISC_R, UnitIconRes.OUTLINE_W_LEADER, UnitIconRes.EXTENT])
	ok(UnitIconRes.OUTLINE_W_LEADER > UnitIconRes.OUTLINE_W,
		"★ 将领那一档的描边**常量**更粗（%.2f > %.2f）"
			% [UnitIconRes.OUTLINE_W_LEADER, UnitIconRes.OUTLINE_W])
	ok(UnitIconRes.OUTLINE_W > 0.0, "★ 普通单位也有描边（圆盘要有边，不然在浅色地形上看不清）")
	ok(UnitIconRes.outline_w(true) > UnitIconRes.outline_w(false), "outline_w() 与常量一致")

	var troop_tex: ImageTexture = UnitIconRes.bake(false)
	var leader_tex: ImageTexture = UnitIconRes.bake(true)
	ok(troop_tex != null and leader_tex != null, "普通 / 将领两张圆盘都烘得出来")
	if troop_tex != null and leader_tex != null:
		ok(troop_tex != leader_tex, "★ 将领的圆盘与普通单位**不是同一张**")
		var troop_img := troop_tex.get_image()
		var leader_img := leader_tex.get_image()
		ok(_count_pixels(troop_img, true) > 0, "圆盘底真的画了东西（不透明像素 %d）"
			% _count_pixels(troop_img, true))
		var dark_troop := _count_pixels(troop_img, false)
		var dark_leader := _count_pixels(leader_img, false)
		ok(dark_leader > dark_troop,
			"★★ 将领那圈的深色像素**明显更多**（%d > %d）—— 描边真的画粗了"
				% [dark_leader, dark_troop])
		var center := troop_img.get_pixel(troop_img.get_width() / 2, troop_img.get_height() / 2)
		ok(center.a > 0.9 and center.r > 0.9 and center.g > 0.9 and center.b > 0.9,
			"★ 圆盘中心是**白色**（阵营色是运行时 modulate 上去的）")
	eq(UnitIconRes.bake(false), troop_tex, "同一档圆盘走缓存（同一个对象）")

	var distinct: Dictionary = {}
	for id in [UnitRes.UNIT_TYPE_SPEARMAN, UnitRes.UNIT_TYPE_LONGBOWMAN,
			UnitRes.UNIT_TYPE_RIDER]:
		var t := String(id)
		var ch: String = cfg.unit_icon_of(t)
		eq(ch.length(), 1, "%s 的地图图标**正好一个字**（实际 %r）" % [t, ch])
		ok(ch != "?" and ch != "", "%s 的字不是兜底占位（%r）" % [t, ch])
		distinct[ch] = true
	eq(distinct.size(), 3, "★ 三个兵种各是一个不同的字")

	eq(cfg.unit_icon_of(UnitRes.UNIT_TYPE_SPEARMAN), "枪", "长枪兵的字来自 config（枪）")
	eq(cfg.unit_icon_of(UnitRes.UNIT_TYPE_LONGBOWMAN), "弓", "长弓兵（弓）")
	eq(cfg.unit_icon_of(UnitRes.UNIT_TYPE_RIDER), "骑", "骑手（骑）")

	eq(cfg.unit_icon_of("general"), cfg.unit_icon_of(UnitRes.UNIT_TYPE_SPEARMAN),
		"★ 将领 1 画长枪兵那个字")
	eq(cfg.unit_icon_of("general_3"), cfg.unit_icon_of(UnitRes.UNIT_TYPE_RIDER),
		"★ basic general_3（区划招募的骑手将领）也画骑手那个字")

	var cfg2 = require_config()
	cfg2.data["unit"]["types"]["spearman"].erase("icon")
	var cfg3 = _reload_cfg(cfg2)
	eq(cfg3.unit_icon_of(UnitRes.UNIT_TYPE_SPEARMAN), "长",
		"★ 没写 icon → 用名字的第一个字（长枪兵 → 长）")
	cfg3.data["unit"]["types"]["ghost"] = {"name": "", "class": "infantry"}
	eq(_reload_cfg(cfg3).unit_icon_of("ghost"), "?",
		"★ 名字也是空的 → 兜底成 ? （不崩、不留空白）")
	eq(cfg3.unit_icon_of("no_such_type"), "单",
		"★ 认不出来的类型用兜底名「单位」的第一个字（总有字可画）")

	var cfg4 = require_config()
	cfg4.data["unit"]["types"]["rider"]["icon"] = "骑手"
	eq(_reload_cfg(cfg4).unit_icon_of(UnitRes.UNIT_TYPE_RIDER), "骑",
		"★ 手改写了两个字也只取第一个")

	ok(UnitIconRes.font_size_for(13.44) > UnitIconRes.font_size_for(8.0), "半径越大字号越大")
	ok(UnitIconRes.font_size_for(0.0) >= UnitIconRes.MIN_FONT_SIZE, "字号有下限（不缩成 0）")
	for radius_px in [8.0, 11.52, 13.44, 20.0]:
		var fsize: float = float(UnitIconRes.font_size_for(radius_px))
		var disc_d: float = 2.0 * UnitIconRes.DISC_R * radius_px
		ok(fsize <= disc_d,
			"★ 半径 %.1fpx 时字号 %.0f 装得进圆盘（盘直径 %.1fpx）" % [radius_px, fsize, disc_d])

func _count_pixels(img: Image, opaque: bool) -> int:
	if img == null:
		return 0
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a < 0.05:
				continue
			if opaque:
				n += 1
			elif c.r < 0.5 and c.g < 0.5 and c.b < 0.5:
				n += 1
	return n

func _reload_cfg(src) -> RefCounted:
	var cfg = ConfigRes.new()
	cfg.data = src.data
	cfg._cache_scalars()
	return cfg

func _test_icon_chars(cfg) -> void:
	var w = require_world_with_escorts(cfg, ESCORTS_PER_GENERAL)
	var g1 = w.unit_by_id("general-1")
	var g3 = w.unit_by_id("general-3")      # 骑手将领
	ok(g1 != null and g3 != null, "有长枪兵将领 general-1 与骑手将领 general-3")
	if g1 != null and g3 != null:
		eq(UnitIconRes.char_of(cfg, String(g3.unit_type)), "骑", "★ general-3 画的是「骑」")
		eq(UnitIconRes.char_of(cfg, String(g1.unit_type)), "枪", "★ general-1 画的是「枪」")

	var snap = SnapshotRes.to_snapshot(w)
	var w2 = require_world(cfg)
	SnapshotRes.apply_snapshot(w2, cfg, snap)
	var remote3 = w2.unit_by_id("general-3")
	ok(remote3 != null, "快照重建出了 general-3")
	if remote3 != null:
		eq(String(remote3.unit_type), UnitRes.UNIT_TYPE_RIDER, "★ 快照往返后骑手将领还是骑手")
		eq(remote3.unit_class, ConfigRes.CLASS_CAVALRY, "客机侧的兵种大类也对")
