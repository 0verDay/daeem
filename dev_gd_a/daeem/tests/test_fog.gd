## test_fog.gd —— 战争迷雾：视野 / 山脉遮挡 / 敌方建筑的「见过就记住」
extends "res://tests/test_case.gd"
## ★ 这些用例只需要「一张能开局的图」：走 `main._on_test_pressed()` 直连默认地图
##   （界面入口已改为 test_1/2/3 与战役菜单，那两条走的是关卡路径）。
const MapLibraryRes = preload("res://logic/map_library.gd")

const ConfigRes = preload("res://logic/config.gd")
const GridRes = preload("res://logic/grid.gd")
const MapDataRes = preload("res://logic/map_data.gd")
const FactionRes = preload("res://logic/faction.gd")
const FogRes = preload("res://logic/fog.gd")
const UnitRes = preload("res://logic/unit.gd")
const BuildingRes = preload("res://logic/building.gd")
const GroundRes = preload("res://view/ground_view.gd")
const InputControllerRes = preload("res://view/input_controller.gd")

func _initialize() -> void:
	_case_name = "test_fog"
	_run()

func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	if not _assert_config(cfg):
		quit(1)
		return
	_test_sector_basics(cfg)
	_test_backend_equivalence(cfg)
	_test_mountain_blocks(cfg)
	_test_other_terrain_does_not_block(cfg)
	_test_radius(cfg)
	_test_faction_vision(cfg)
	_test_shared_vision_same_side(cfg)
	_test_buildings_give_vision(cfg)
	_test_building_discovery(cfg)
	_test_unit_no_memory(cfg)
	_test_sighted_forgotten_when_destroyed(cfg)
	_test_refresh_throttle(cfg)
	_test_pick_blocked_by_fog(cfg)
	await process_frame
	await _test_game_scene_wires_fog()

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)

func _make_map(cfg, rows: Array) -> RefCounted:
	var m = MapDataRes.new()
	m.cols = String(rows[0]).length()
	m.rows = rows.size()
	m.terrain = GridRes.new(m.cols, m.rows, MapDataRes.TERRAIN_GRASS)
	m.exists = GridRes.new(m.cols, m.rows, true)
	for y in m.rows:
		var line := String(rows[y])
		for x in m.cols:
			var ch := line.substr(x, 1)
			var t := MapDataRes.TERRAIN_GRASS
			if ch == "^":
				t = MapDataRes.TERRAIN_FOREST
			elif ch == "#":
				t = MapDataRes.TERRAIN_MOUNTAIN
			m.terrain.set_cell(x, y, t)
	m.base = Vector2i(0, 0)
	m.forest_mult = cfg.unit_forest_mult
	m.diagonal = cfg.path_diagonal
	m.dirs = GridRes.DIRS8 if m.diagonal else GridRes.DIRS4
	m.rebuild_terrain_masks()
	return m

class FakeWorld:
	extends RefCounted
	var cfg = null
	var map = null
	var factions: Array = []
	var units: Array = []
	var building_list: Array = []
	var my_faction: String = ""
	var fog = null

func _make_fake(p_cfg, p_map, p_factions: Array) -> FakeWorld:
	var f := FakeWorld.new()
	f.cfg = p_cfg
	f.map = p_map
	f.factions = p_factions
	f.my_faction = String(p_factions[0]) if p_factions.size() > 0 else ""
	return f

func _add_unit(fake, cfg, id: String, tx: int, ty: int, faction: String, unit_type: String = "spearman"):
	var u = UnitRes.create(cfg, id, id, Vector2i(tx, ty), faction, unit_type)
	fake.units.append(u)
	return u

func _add_building(fake, cfg, _id: String, tx: int, ty: int, owner: String, type: String = "tower"):
	var b = BuildingRes.create(cfg, type, tx, ty, owner)
	fake.building_list.append(b)
	return b

func _move_unit(u, tx: int, ty: int) -> void:
	u.tx = tx
	u.ty = ty
	u.pos = GridRes.center_of(Vector2i(tx, ty))

func _see(fog, fid: String, tx: int, ty: int, what: String) -> void:
	ok(fog.tile_visible(fid, tx, ty), what)

func _mask_count(mask: PackedByteArray) -> int:
	var n := 0
	for i in mask.size():
		if mask[i] != 0:
			n += 1
	return n

func _dont_see(fog, fid: String, tx: int, ty: int, what: String) -> void:
	ok(not fog.tile_visible(fid, tx, ty), what)


## 两份掩码逐字节比较；失败时只报**首个差异下标**（不要把 594 个字节全打出来）。
func _assert_mask_equal(a: PackedByteArray, b: PackedByteArray, what: String) -> void:
	eq(a.size(), b.size(), what + "（长度）")
	var first := -1
	for i in mini(a.size(), b.size()):
		if a[i] != b[i]:
			first = i
			break
	eq(first, -1, what if first < 0 else "%s（首个差异下标 %d）" % [what, first])

func _assert_config(cfg) -> bool:
	ok(cfg.fog_enabled, "config 的 fog.enabled = true（迷雾默认开着）")
	ok(cfg.fog_vision_default > 0.0, "fog.vision_default > 0（%s）" % str(cfg.fog_vision_default))
	ok(cfg.fog_vision_building > 0.0, "fog.vision_building > 0（%s）" % str(cfg.fog_vision_building))
	for t in ["spearman", "longbowman", "rider"]:
		ok(cfg.has_unit_type(t), "单位类型表里有 %s" % t)
		ok(cfg.unit_vision_of(t) > 0.0, "%s 的视野 > 0（%s 格）" % [t, str(cfg.unit_vision_of(t))])
	ok(cfg.unit_vision_of("longbowman") > cfg.unit_vision_of("spearman"),
		"长弓兵视野 > 长枪兵（10 > 8）")
	eq(cfg.general_vision_at(0), cfg.unit_vision_of(cfg.general_type_at(0)),
		"将领 1 的视野 = 长枪兵的视野（没写覆盖时跟随兵种）")
	eq(cfg.general_vision_at(1), cfg.unit_vision_of("longbowman"),
		"将领 2 的视野 = 长弓兵的视野")
	return true

func _test_sector_basics(cfg) -> void:
	var map = _make_map(cfg, [
		"..........", "..........", "..........",
		"..........", "..........", "..........",
	])
	var fog = FogRes.create()
	var fake = _make_fake(cfg, map, ["p1", "enemy"])
	var u0 = _add_unit(fake, cfg, "u1", 2, 2, "p1")
	u0.vision = 2.0
	fog.update(fake)
	_see(fog, "p1", 2, 2, "单位站在哪一格，那一格自己有视野")
	_see(fog, "p1", 2, 3, "半径内的相邻格有视野")
	_see(fog, "p1", 4, 2, "半径边缘（正好 2 格）也有视野")
	_dont_see(fog, "p1", 0, 0, "半径之外没有视野（到 (0,0) 是 2.83 格 > 2）")

## ★★ C# 视野内核 vs GDScript 实现：**同一份世界、逐位一样的掩码**。
##
## 为什么必须有这一条（而不是只跑 test_fog 的语义断言）：
##   语义断言只能覆盖「某几格看得见 / 看不见」。内核与 GDScript 版本一旦在某条
##   边界规则上分叉（穿格点、山自己那格、半径边界），测试可能仍然全绿，
##   而玩家会看到一圈「多出来 / 少掉」的视野。这里直接拿两份掩码逐字节比。
func _test_backend_equivalence(cfg) -> void:
	var map = _make_map(cfg, [
		"............",
		"....#.......",
		"...###......",
		"....#...^...",
		".........#..",
		"..^^.....#..",
		".........#..",
		"............",
	])
	var fake = _make_fake(cfg, map, ["p1", "p2", "enemy"])
	var u1 = _add_unit(fake, cfg, "a", 2, 2, "p1")
	u1.vision = 6.0
	var u2 = _add_unit(fake, cfg, "b", 3, 5, "p1", "longbowman")
	u2.vision = 10.0
	var u3 = _add_unit(fake, cfg, "c", 9, 2, "p2")
	u3.vision = 5.0
	var u4 = _add_unit(fake, cfg, "d", 10, 6, "enemy")
	u4.vision = 7.0
	_add_building(fake, cfg, "t", 6, 6, "p1", "tower")
	_add_building(fake, cfg, "t2", 1, 6, "enemy", "tower")

	var f_cs = FogRes.create()
	ok(f_cs.kernel != null, "★ C# 视野内核加载成功（logic/FogKernel.cs）")
	ok(f_cs._use_csharp(cfg), "★ config 的 fog.backend = csharp 时真的走内核")
	var f_gd = FogRes.create()
	f_gd.kernel = null                           # 强制退回 GDScript 实现
	ok(not f_gd._use_csharp(cfg), "（前提）第二份强制走 GDScript")

	f_cs.update(fake)
	f_gd.update(fake)

	eq(f_cs.sight.size(), f_gd.sight.size(), "★ 两套实现产生的「方」数量一致")
	for side in f_gd.sight.keys():
		ok(f_cs.sight.has(side), "★ C# 版也有这一方的掩码（%s）" % side)
		if f_cs.sight.has(side):
			_assert_mask_equal(f_cs.sight[side], f_gd.sight[side],
				"★★ %s 的视野掩码逐字节一致" % side)

	# 再来一帧：把单位挪到新格，覆盖「扇区缓存命中 / 半径变化」两条路
	_move_unit(u1, 7, 4)
	_move_unit(u3, 2, 1)
	f_cs.update(fake)
	f_gd.update(fake)
	for side2 in f_gd.sight.keys():
		_assert_mask_equal(f_cs.sight[side2], f_gd.sight[side2],
			"★★ 单位移动后 %s 的掩码仍然逐字节一致" % side2)


func _test_mountain_blocks(cfg) -> void:
	var map = _make_map(cfg, [
		"....#.....",
		"....#.....",
		"....#.....",
		"....#.....",
		"....#.....",
	])
	var fog = FogRes.create()
	var fake = _make_fake(cfg, map, ["p1", "enemy"])
	_add_unit(fake, cfg, "u1", 1, 2, "p1", "longbowman")     # 视野 10，足够够到对面
	fog.update(fake)

	_see(fog, "p1", 1, 2, "山这一侧（自己在的地方）有视野")
	_see(fog, "p1", 4, 2, "★ 山**自己那一格**看得见（山不该把自己挡掉）")
	_dont_see(fog, "p1", 5, 2, "★★ 山**后面**那一格看不见（山脉挡住视线）")
	_dont_see(fog, "p1", 8, 2, "山后更远处也看不见")
	_dont_see(fog, "p1", 6, 0, "斜着穿过山脊的方向同样被挡住")

	var map2 = _make_map(cfg, [
		"....#.....",
		"....#.....",
		"....#.....",
		"....#.....",
		"....#.....",
	])
	map2.terrain.set_cell(4, 2, MapDataRes.TERRAIN_GRASS)
	map2.rebuild_terrain_masks()
	var fog2 = FogRes.create()
	var fake2 = _make_fake(cfg, map2, ["p1", "enemy"])
	_add_unit(fake2, cfg, "u1", 1, 2, "p1", "longbowman")
	fog2.update(fake2)
	_see(fog2, "p1", 5, 2, "★ 山脊有缺口时，缺口正后方看得见（视线是算法算的，不是规则硬编码）")
	_dont_see(fog2, "p1", 5, 0, "缺口旁边（斜线仍被山挡）看不见")

func _test_other_terrain_does_not_block(cfg) -> void:
	var map = _make_map(cfg, [
		"..............",
		"....^^^^^^....",
		"....^^^^^^....",
		"..............",
		"..............",
	])
	var fog = FogRes.create()
	var fake = _make_fake(cfg, map, ["p1", "enemy"])
	_add_unit(fake, cfg, "u1", 1, 2, "p1", "longbowman")
	fog.update(fake)
	_see(fog, "p1", 5, 2, "★ 森林里那一格有视野（森林不挡视线）")
	_see(fog, "p1", 8, 2, "★ 整片森林后面也看得见（只有山挡）")
	_see(fog, "p1", 11, 2, "★ 森林后面 10 格处仍然在视野半径内")
	_dont_see(fog, "p1", 13, 2, "但视野半径（10）之外仍然看不见")

func _test_radius(cfg) -> void:
	var row := "..........."
	var map = _make_map(cfg, [row, row, row, row, row])
	var fog = FogRes.create()
	var fake = _make_fake(cfg, map, ["p1", "enemy"])
	var u = _add_unit(fake, cfg, "u1", 5, 2, "p1")
	u.vision = 3.0
	fog.update(fake)
	_see(fog, "p1", 8, 2, "半径 3 → 3 格远看得见")
	_dont_see(fog, "p1", 9, 2, "半径 3 → 4 格远看不见")
	_dont_see(fog, "p1", 8, 5, "半径 3 → 对角 3+3 格（距离 4.24）看不见")

	var fog0 = FogRes.create()
	var fake0 = _make_fake(cfg, map, ["p1", "enemy"])
	var u0 = _add_unit(fake0, cfg, "u1", 5, 2, "p1")
	u0.vision = 0.0
	fog0.update(fake0)
	_see(fog0, "p1", 5, 2, "视野 0 的单位仍然看得见自己站的那一格")
	_dont_see(fog0, "p1", 6, 2, "视野 0 → 旁边一格都看不见")

func _test_faction_vision(cfg) -> void:
	var row := "........................"
	var map = _make_map(cfg, [row, row, row, row, row])
	var fog = FogRes.create()
	var fake = _make_fake(cfg, map, ["p1", "enemy"])
	_add_unit(fake, cfg, "a1", 1, 2, "p1")
	var foe = _add_unit(fake, cfg, "e1", 19, 2, "enemy")
	fog.update(fake)
	_see(fog, "p1", 4, 2, "p1 的视野按自己的单位算")
	_dont_see(fog, "p1", 14, 2, "p1 看不到 enemy 那边的远处（单位在 (1,2)、视野 8 → 最远 x=9）")
	_see(fog, "enemy", 14, 2, "★ enemy 也有一份自己的视野（不是只有玩家方算）")
	_dont_see(fog, "enemy", 5, 2, "enemy 看不到 p1 家门口（它在 (19,2)、视野 7 → 最近 x=12）")

	_move_unit(foe, 6, 2)
	ok(fog.refresh_needed(fake), "★ 单位挪到新格之后 refresh_needed 为 true（否则视野不会更新）")
	fog.update(fake)
	_see(fog, "enemy", 4, 2, "单位挪到 (6,2) 之后，enemy 那边看得见 p1 家门口了")

	foe.alive = false
	ok(fog.refresh_needed(fake), "阵亡的单位会让 refresh_needed 为 true")
	fog.update(fake)
	_dont_see(fog, "enemy", 4, 2, "阵亡的单位不再提供视野")

func _test_shared_vision_same_side(cfg) -> void:
	var row := "........................"
	var map = _make_map(cfg, [row, row, row, row, row])

	FactionRes.set_allies([["p1", "p2"]])
	eq(FactionRes.side_of("p1"), FactionRes.side_of("p2"), "（前提）p1 / p2 现在是同一方")
	var fog = FogRes.create()
	var fake = _make_fake(cfg, map, ["p1", "p2", "enemy"])
	_add_unit(fake, cfg, "a1", 1, 2, "p1")
	_add_unit(fake, cfg, "b1", 20, 2, "p2")
	_add_unit(fake, cfg, "e1", 16, 2, "enemy")
	fog.update(fake)
	_see(fog, "p1", 4, 2, "p1 看得见自己单位周围")
	_see(fog, "p2", 21, 2, "p2 看得见自己单位周围")
	_see(fog, "p2", 4, 2, "★★ p2 看得见 p1 那边（两人共享视野）")
	_see(fog, "p1", 21, 2, "★★ 反过来也一样（共享是双向的）")
	_dont_see(fog, "enemy", 3, 2, "★★ 共享视野不会泄漏给敌方")

	var foe = fake.units[2]
	ok(fog.unit_visible("p2", foe), "p2 在自己的视野里看得见敌方单位")
	ok(not fog.unit_visible("enemy", fake.units[0]),
		"★ enemy 看不到 p1 的单位（哪怕 p1/p2 共享，也没泄漏给它）")

	FactionRes.clear_allies()
	fog.reset_cache()                      # ★ 换关系 = 换桶键，缓存必须清（与换地图同一条约定）
	fog.update(fake)
	_dont_see(fog, "p2", 4, 2, "★ 解除结盟之后 p2 看不到 p1 那边了")
	_see(fog, "p2", 21, 2, "p2 自己的视野照旧")
	_see(fog, "p1", 4, 2, "p1 自己的视野照旧")

	FactionRes.set_allies([["p1", "p2"], ["p2", "p3"]])
	eq(FactionRes.side_of("p1"), FactionRes.side_of("p3"),
		"（前提）隔着 p2 也算同一方（传递闭包）")
	var fog3 = FogRes.create()
	var fake3 = _make_fake(cfg, map, ["p1", "p2", "p3", "enemy"])
	_add_unit(fake3, cfg, "a1", 1, 2, "p1")
	_add_unit(fake3, cfg, "c1", 21, 2, "p3")
	fog3.update(fake3)
	_see(fog3, "p1", 21, 2, "★★ 三方连成一方时，p1 也看得见 p3 那边")
	_see(fog3, "p3", 4, 2, "★★ 反过来也一样")
	_dont_see(fog3, "enemy", 3, 2, "★ 还是不会泄漏给没结盟的 enemy")

	FactionRes.clear_allies()

func _test_buildings_give_vision(cfg) -> void:
	var row := "................"
	var map = _make_map(cfg, [row, row, row, row, row])
	var fog = FogRes.create()
	var fake = _make_fake(cfg, map, ["p1", "enemy"])
	_add_building(fake, cfg, "b1", 1, 2, "p1", "base")
	fog.update(fake)
	_see(fog, "p1", 4, 2, "★ 己方建筑自己就给视野（不需要有单位站在旁边）")
	_dont_see(fog, "p1", 11, 2, "大本营视野 9 → 10 格处看不见")
	_see(fog, "p1", 10, 2, "大本营视野 9 → 9 格处看得见")

	eq(cfg.building_vision(), cfg.fog_vision_building,
		"`building_vision()` = config 的 fog.vision_building（没写 vision 时的兜底）")
	near(cfg.building_vision_of("tower"), 12.0, 1e-6, "箭塔自己的视野 12（瞭望塔看得最远）")
	near(cfg.building_vision_of("base"), 9.0, 1e-6, "大本营 9")
	near(cfg.building_vision_of("wall"), 5.0, 1e-6, "城墙 5（一堵墙不该看得跟塔一样远）")
	ok(cfg.building_vision_of("tower") > cfg.building_vision_of("wall"),
		"★ 箭塔看得比城墙远（这三个数是各写各的）")
	near(cfg.building_vision_of("no_such_type"), cfg.fog_vision_building, 1e-6,
		"★ 认不出来的建筑类型 → 退回 fog.vision_building（不报错、也不给 0）")

	var fog2 = FogRes.create()
	var fake2 = _make_fake(cfg, map, ["p1", "enemy"])
	_add_building(fake2, cfg, "w1", 1, 2, "p1", "wall")
	fog2.update(fake2)
	_see(fog2, "p1", 4, 2, "城墙视野 5 → 3 格处看得见")
	_dont_see(fog2, "p1", 8, 2, "★ 城墙视野 5 → 7 格处看不见")
	var fog3 = FogRes.create()
	var fake3 = _make_fake(cfg, map, ["p1", "enemy"])
	_add_building(fake3, cfg, "t1", 1, 2, "p1", "tower")
	fog3.update(fake3)
	_see(fog3, "p1", 8, 2, "★★ 同一格换成**箭塔** → 7 格处就看得见了（各类型各算各的）")

	var fog4 = FogRes.create()
	var fake4 = _make_fake(cfg, map, ["p1", "enemy"])
	_add_building(fake4, cfg, "c1", 5, 2, "", "zone_center")
	fog4.update(fake4)
	_dont_see(fog4, "p1", 5, 2, "★ 中立障碍（owner = \"\"）不给任何人视野")

func _test_building_discovery(cfg) -> void:
	var row := "........................"
	var map = _make_map(cfg, [row, row, row, row, row])
	var fog = FogRes.create()
	var fake = _make_fake(cfg, map, ["p1", "enemy"])
	var scout = _add_unit(fake, cfg, "s1", 1, 2, "p1")
	scout.vision = 3.0
	var tower = _add_building(fake, cfg, "t1", 16, 2, "enemy", "tower")
	fog.update(fake)

	ok(not fog.building_visible("p1", tower),
		"★★ 没发现之前看不见敌方建筑（需求第 2 条）")
	ok(not fog.is_building_sighted("p1", tower), "这时候还没登记进记忆表")
	eq(fog.known_buildings("p1").size(), 0, "记忆表是空的")

	_move_unit(scout, 13, 2)
	fog.update(fake)
	ok(fog.building_visible("p1", tower), "★ 走进视野之后，敌方建筑显示了")
	ok(fog.is_building_sighted("p1", tower), "★ 同时被登记进「已知敌方建筑」")

	_move_unit(scout, 1, 2)
	fog.update(fake)
	_dont_see(fog, "p1", 16, 2, "★★ 走回来之后，那一格本身又没有视野了")
	ok(fog.building_visible("p1", tower),
		"★★ 但敌方建筑**仍然可见**（需求：若战争迷雾再次覆盖也不会消除）")
	eq(fog.known_buildings("p1").size(), 1, "记忆表里有 1 栋楼")

	scout.alive = false
	fog.update(fake)
	ok(fog.building_visible("p1", tower), "★ 侦察兵死了也不影响已经记住的敌方建筑")

	tower.alive = false
	fog.update(fake)
	ok(not fog.building_visible("p1", tower), "★ 建筑被摧毁之后不再显示")
	eq(fog.known_buildings("p1").size(), 0, "★ 记忆表里也清掉了")

	var own = _add_building(fake, cfg, "own1", 20, 2, "p1", "wall")
	fog.update(fake)
	ok(fog.building_visible("p1", own), "己方建筑永远可见（与视野无关）")
	ok(not fog.is_building_sighted("p1", own), "己方建筑不进「敌方建筑」记忆表")

func _test_unit_no_memory(cfg) -> void:
	var row := "........................"
	var map = _make_map(cfg, [row, row, row, row, row])
	var fog = FogRes.create()
	var fake = _make_fake(cfg, map, ["p1", "enemy"])
	var scout = _add_unit(fake, cfg, "s1", 1, 2, "p1")
	scout.vision = 3.0
	var foe = _add_unit(fake, cfg, "e1", 16, 2, "enemy")
	fog.update(fake)
	ok(not fog.unit_visible("p1", foe), "视野外的敌方单位看不见")

	_move_unit(scout, 13, 2)
	fog.update(fake)
	ok(fog.unit_visible("p1", foe), "★ 走进视野之后看得见敌方单位")

	_move_unit(scout, 1, 2)
	fog.update(fake)
	ok(not fog.unit_visible("p1", foe),
		"★★ 走出视野之后敌方单位**又消失了**（单位不保留记忆 —— 与建筑相反的规则）")

	foe.alive = false
	ok(not fog.unit_visible("p1", foe), "阵亡的敌方单位不显示")

	var own = _add_unit(fake, cfg, "s2", 22, 2, "p1")
	fog.update(fake)
	ok(fog.unit_visible("p1", own), "★ 己方单位永远可见（不受迷雾影响）")
	ok(not fog.unit_visible("enemy", own), "enemy 看不到视野之外的 p1 单位")

func _test_sighted_forgotten_when_destroyed(cfg) -> void:
	var row := "............"
	var map = _make_map(cfg, [row, row, row, row, row])
	var fog = FogRes.create()
	var fake = _make_fake(cfg, map, ["p1", "enemy"])
	_add_unit(fake, cfg, "u1", 1, 2, "p1")
	var b = _add_building(fake, cfg, "b1", 3, 2, "enemy", "wall")
	fog.update(fake)
	ok(fog.is_building_sighted("p1", b), "视野里的敌方建筑被登记")

	b.owner = "p1"
	fog.update(fake)
	ok(not fog.is_building_sighted("p1", b), "★ 建筑换成己方之后，不再留在「敌方建筑」记忆里")
	ok(fog.building_visible("p1", b), "但它作为己方建筑仍然可见")

	_add_unit(fake, cfg, "obs", 4, 2, "enemy")
	fog.update(fake)
	_see(fog, "enemy", 3, 2, "（前提）enemy 的单位在 (4,2) 看得见 (3,2)")
	ok(fog.building_visible("enemy", b),
		"★ 换成 p1 之后，这在 enemy 眼里是一栋敌方建筑 —— 它有视野就看得见")

func _test_refresh_throttle(cfg) -> void:
	var row := ".........."
	var map = _make_map(cfg, [row, row, row, row, row])
	var fog = FogRes.create()
	var fake = _make_fake(cfg, map, ["p1", "enemy"])
	_add_unit(fake, cfg, "u1", 1, 2, "p1")
	fog.update(fake)
	ok(not fog.refresh_needed(fake),
		"★★ 什么都没动 → refresh_needed 为 false（这是 1000 单位下的性能前提）")

	var u = fake.units[0]
	u.pos = Vector2(1.2, 2.4)
	ok(not fog.refresh_needed(fake), "★ 同一格内的小移动不触发重算")

	u.tx = 2
	ok(fog.refresh_needed(fake), "跨格之后要重算")

	var fog2 = FogRes.create()
	var fake2 = _make_fake(cfg, map, ["p1", "enemy"])
	_add_unit(fake2, cfg, "u1", 1, 2, "p1")
	fog2.update(fake2)
	_add_unit(fake2, cfg, "u2", 5, 2, "p1")
	ok(fog2.refresh_needed(fake2), "新单位出现 → 要重算（它带来新的视野来源）")
	fog2.update(fake2)
	_add_building(fake2, cfg, "b1", 8, 2, "p1", "tower")
	ok(fog2.refresh_needed(fake2), "新建筑出现 → 要重算")

func _aim_at(ctrl, tx: int, ty: int) -> void:
	ctrl.mouse_world = GridRes.center_of(Vector2i(tx, ty))
	ctrl._sync_hover_from_mouse()

func _test_pick_blocked_by_fog(cfg) -> void:
	var w = require_world(cfg)
	ok(w != null, "world 能建出来（真地图）")
	if w == null:
		return
	var tower = null
	for b in w.building_list:
		if b.owner == "enemy" and b.type == "tower":
			tower = b
			break
	ok(tower != null, "真地图上有敌方的箭塔（对家据点）")
	if tower == null:
		return
	ok(not w.fog.building_visible(w.my_faction, tower),
		"★★ 开局看不见对家的箭塔（p1 大本营在 (7,2)、据点在 (14,14)）")

	var ctrl = InputControllerRes.new()
	ctrl.setup(cfg, w, null)

	_aim_at(ctrl, tower.tx, tower.ty)
	ctrl._on_left_click(false)
	eq(ctrl.selected_building, null, "★★ 迷雾里的敌方建筑左键点不中（不会被选中）")

	var my_units: Array = []
	for cand in w.units:
		if FactionRes.same_side(cand.faction, w.my_faction):
			my_units.append(cand)
	ok(my_units.size() > 0, "p1 有单位可以下令")
	if my_units.is_empty():
		w = null
		return
	ctrl.selected_units = [my_units[0]]
	var u = my_units[0]
	var before: Vector2 = u.pos
	_aim_at(ctrl, tower.tx, tower.ty)
	ctrl._on_right_click(false)
	ok(u.pos == before, "★ 右键点迷雾里的塔 = 普通移动（不会立刻瞬移，位置不变）")
	ok(u.ordered_building == null, "★★ 迷雾里的敌方建筑不会被指定为攻击目标")

	_move_unit(u, tower.tx - 2, tower.ty)
	ctrl.select_units([])
	w.fog.update(w)
	ok(w.fog.building_visible(w.my_faction, tower),
		"★★ 单位走到旁边之后，对家的箭塔被发现了")
	_aim_at(ctrl, tower.tx, tower.ty)
	ctrl._on_left_click(false)
	eq(ctrl.selected_enemy, tower, "★ 现在左键点得中它了（进 selected_enemy）")
	ok(ctrl.selected_buildings.is_empty(),
		"★ 它不进己方建筑列表（否则会对着一座敌塔弹出「升级」）")

	_move_unit(u, 7, 2)
	ctrl.select_units([])
	w.fog.update(w)
	_aim_at(ctrl, tower.tx, tower.ty)
	ctrl._on_left_click(false)
	eq(ctrl.selected_enemy, tower,
		"★★ 走开之后（迷雾重新盖住）仍然点得中它 —— 见过一次就永久记住")

	var foe = w.spawn_enemy(20, 20)
	ok(foe != null, "刷出一个敌方单位来做「迷雾里的敌人」这条用例")
	if foe != null:
		ok(not w.fog.unit_visible(w.my_faction, foe), "开局看不见刷出来的那个敌人")
		eq(ctrl._pick_foe_unit_at(GridRes.center_of(Vector2i(foe.tx, foe.ty))), null,
			"★★ 迷雾里的敌方单位不能被点名（_pick_foe_unit_at 返回 null）")
		_move_unit(u, foe.tx - 1, foe.ty)
		w.fog.update(w)
		ok(w.fog.unit_visible(w.my_faction, foe), "走到旁边之后看得见它")
		ok(ctrl._pick_foe_unit_at(GridRes.center_of(Vector2i(foe.tx, foe.ty))) == foe,
			"★ 现在能点名打它了")

func _test_game_scene_wires_fog() -> void:
	var cfg = require_config()
	var packed = load("res://view/main.tscn")
	ok(packed != null, "能载入主场景 main.tscn")
	if packed == null:
		return
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	main._on_test_pressed(String(MapLibraryRes.default_map_path()))
	await process_frame
	await process_frame

	var game = main.game
	ok(game != null, "按下 test 之后建出了游戏内场景")
	if game == null:
		main.queue_free()
		return

	ok(game.ground != null, "★★ 场景里建出了地面层（迷雾是它的一部分）")
	ok(game.overlay != null, "★★ 场景里建出了覆盖层（标记 / 拖框在它上面）")
	var fog_layer = game.ground._fog_mesh if game.ground != null else null
	ok(fog_layer != null, "★★ 地面层里有独立的迷雾层（灰色遮罩那一层）")
	if fog_layer != null:
		ok(fog_layer != game.ground._mesh, "★ 迷雾是独立的一块平面（不与地面共用 mesh）")
		ok(fog_layer.position.y > game.ground._mesh.position.y,
			"★ 迷雾抬在地面之上（抬高 %.1f，避免 z-fighting）"
			% (fog_layer.position.y - game.ground._mesh.position.y))

	var w = game.world
	ok(w.fog != null, "world 上有 fog")
	if w.fog != null:
		eq(w.fog.sight.size() > 0, true, "★ 开局就算过一次视野（不是等到第一次 tick）")
		var base_b = w.find_base_of(w.my_faction)
		if base_b != null:
			ok(w.fog.tile_visible(w.my_faction, base_b.tx, base_b.ty),
				"★ 家里那一块有视野（开局屏上不是一整片灰）")

	if game.ground != null and game.ground._fog_tex != null:
		var fsz: Vector2i = game.ground._fog_tex.get_size()
		eq(fsz.x, int(w.map.cols) * GroundRes.FOG_PX_PER_TILE,
			"★★ 迷雾贴图铺满整张地图（宽 = 格数 × 每格像素）")
		eq(fsz.y, int(w.map.rows) * GroundRes.FOG_PX_PER_TILE,
			"★★ 迷雾贴图铺满整张地图（高 = 格数 × 每格像素）")
		ok(game.ground.fog_bake_count > 0, "★ 迷雾贴图真的烘过（烘图次数 > 0）")
	else:
		ok(false, "拿不到迷雾贴图（`ground._fog_tex` 是 null —— 迷雾层没建出来）")

	var uv = game.unit_view
	var my_units: Array = w.alive_units_of(w.my_faction)
	ok(my_units.size() > 0, "己方有单位")
	if my_units.size() > 0:
		ok(uv._visible_to_me(my_units[0]), "★ 己方单位永远可见（不会被自己的雾藏起来）")
	var enemy = null
	for cand in w.units:
		if not FactionRes.same_side(cand.faction, w.my_faction) and cand.alive:
			enemy = cand
			break
	if enemy != null:
		var far := _first_invisible_tile(w, w.my_faction)
		if far.x >= 0:
			enemy.tx = far.x
			enemy.ty = far.y
			enemy.pos = GridRes.center_of(far)
			ok(not uv._visible_to_me(enemy),
				"★★ 躲在没视野的格子里 → unit_view 判它不可见（一个图元都不会发）")
			var mm = game.hud.minimap if game.hud != null else null
			ok(mm != null, "HUD 里有小地图控件")
			if mm != null:
				ok(not mm._unit_visible(enemy),
					"★★ 小地图也读同一份判据（两边不会各显示一套）")

	# ★★ 小地图迷雾烘图（本轮手机端优化）：掩码没变 ⇒ 复用；变了 ⇒ 重烘。
	#   ⚠️ 这一条防的是「PackedByteArray 的 == 其实是同一性比较」这类静默失败：
	#      那样迷雾图会永远停在第一帧，而画面上只是看起来「有点旧」。
	var mmp = game.hud.minimap if game.hud != null else null
	if mmp != null:
		mmp._fog_texture()
		var bakes: int = mmp.fog_bake_count
		mmp._fog_texture()
		eq(mmp.fog_bake_count, bakes, "★★ 小地图迷雾：掩码没变时不重烘")
		var side := FactionRes.side_of(w.my_faction)
		var mask: PackedByteArray = w.fog.sight.get(side, PackedByteArray())
		if not mask.is_empty():
			mask[0] = 1 if mask[0] == 0 else 0
			w.fog.sight[side] = mask
			mmp._fog_texture()
			ok(mmp.fog_bake_count > bakes,
				"★★ 小地图迷雾：掩码变化后重烘（%d → %d）" % [bakes, mmp.fog_bake_count])

	main.queue_free()

func _first_invisible_tile(w, fid: String) -> Vector2i:
	for ty in w.map.rows:
		for tx in w.map.cols:
			if not w.map.tile_exists(tx, ty):
				continue
			if not w.fog.tile_visible(fid, tx, ty):
				return Vector2i(tx, ty)
	return Vector2i(-1, -1)
