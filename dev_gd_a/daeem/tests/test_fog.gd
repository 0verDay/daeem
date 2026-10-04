## test_fog.gd —— 战争迷雾：视野 / 山脉遮挡 / 敌方建筑的「见过就记住」
##
## 需求原文（用户）：
##   1. 「战争迷雾用灰色遮罩显示，所有地形都是默认全图可见的」；
##   2. 「假如玩家没有发现地图上的敌方建筑物，则无法看见敌方建筑物，
##      当玩家看见过一次敌方建筑物时，该敌方建筑物就会显示在玩家视野中，
##      只有当其被摧毁才会被消除，若战争迷雾再次覆盖也不会消除」；
##   3. 「为单位和建筑加入视野范围这个属性」；
##   4. 「单位的视野会被山脉阻断，其他地形不会阻断」。
##
## ★★ 这个套件一半是**合成地图**上的断言（`_make_map` 现造一张 ASCII 小图）：
##    视野的规则（半径 / 山挡 / 林不挡）必须在**能控制地形**的地方验，
##    否则「山后面看不见」这条永远只能靠 README 里那句话成立。
##    另一半在**真地图 + 真 world** 上验「记忆与联动」（点进迷雾不可选中之类）。
##
## ⚠️ 迷雾的缓存是**按地形**建的（fog 的视野扇区）：
##    测试里手改 `map.terrain` 之后必须 `map.rebuild_terrain_masks()` + `fog.reset_cache()`，
##    否则看到的是旧地形的视野（而且不报错）。
extends "res://tests/test_case.gd"

const ConfigRes = preload("res://logic/config.gd")
const GridRes = preload("res://logic/grid.gd")
const MapDataRes = preload("res://logic/map_data.gd")
const FactionRes = preload("res://logic/faction.gd")
const FogRes = preload("res://logic/fog.gd")
const UnitRes = preload("res://logic/unit.gd")
const BuildingRes = preload("res://logic/building.gd")
const FogViewRes = preload("res://view/fog_view.gd")
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
	_test_fog_view_mask(cfg)
	_test_pick_blocked_by_fog(cfg)
	# ★ 最后一条要真的挂节点（`_initialize()` 阶段 add_child 静默失效）→ 先等一帧
	await process_frame
	await _test_game_scene_wires_fog()

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 合成地图 / 合成世界（视野规则要在能控制地形的地方验）
# ------------------------------------------------------------------

## 用 ASCII 造一张地图（仅测试用；不改 data/*.json）。
##
## 图例与地图编辑器的 layout 一致：'.' 草地、'^' 森林、'#' 山地。
## ★ 直接造 MapData 实例（不经过 `load_from`）是刻意的：`load_from` 会做连通性修正，
##   把孤立的可通行格**封成山** —— 那会让「山后面看不见」这类断言变成
##   「到处都是山」，测的东西就不是我们要测的了。
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


## 造一个「只有 fog 需要的那几个字段」的最小世界（不碰 world.gd，避免被无关逻辑干扰）。
##
## ★★ 为什么是一个**真 Object**（内层类）而不是 Dictionary：
##   `view/fog_view.gd` 的 `mask_for()` 收的是 world，`view/unit_view.gd` 的同名判据也一样 ——
##   它们读 `world.map` / `world.fog`。喂一个 Dictionary 进去会当场报
##   「Invalid access to property or key」，而**渲染代码里的报错不会让测试失败**
##   （只打红字），于是那几条断言会变成「永远失败或永远静默」。
##   用一个只有字段、没有方法的小对象替身，两边就都成立。
##
## ★ `world` 这个名字是 test_case 的保留成员（SceneTree.world_2d 的别名）——
##   所以局部变量一律叫 `fake`，绝不能写 `world`。
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
	# ⚠️ 建筑**没有** `id` 字段（它的 `def()["id"]` 是类型）—— 迷雾的记忆表按
	#    **对象引用**当键（见 logic/fog.gd 的 `_sighted`），所以这里的 id 参数只
	#    是为了让调用点读起来清楚（"b1" / "t1"），实现里用不上它。
	var b = BuildingRes.create(cfg, type, tx, ty, owner)
	fake.building_list.append(b)
	return b


## 单位「走到」另一格（迷雾按 `tx/ty` 算，见 fog._collect_contributors）
func _move_unit(u, tx: int, ty: int) -> void:
	u.tx = tx
	u.ty = ty
	u.pos = GridRes.center_of(Vector2i(tx, ty))


## 「这一格对 fid 有视野吗」的短写法
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


# ------------------------------------------------------------------
# 0) 配置
# ------------------------------------------------------------------

func _assert_config(cfg) -> bool:
	ok(cfg.fog_enabled, "config 的 fog.enabled = true（迷雾默认开着）")
	ok(cfg.fog_vision_default > 0.0, "fog.vision_default > 0（%s）" % str(cfg.fog_vision_default))
	ok(cfg.fog_vision_building > 0.0, "fog.vision_building > 0（%s）" % str(cfg.fog_vision_building))
	# ★ 每个内置兵种都要有自己的视野 —— 少一个就会静默吃全局兜底值
	for t in ["spearman", "longbowman", "rider", "enemy"]:
		ok(cfg.has_unit_type(t), "单位类型表里有 %s" % t)
		ok(cfg.unit_vision_of(t) > 0.0, "%s 的视野 > 0（%s 格）" % [t, str(cfg.unit_vision_of(t))])
	# 长弓兵看得比长枪兵远、骑手居中 —— 这是 config.json 里写的那组数（编辑器可改）
	ok(cfg.unit_vision_of("longbowman") > cfg.unit_vision_of("spearman"),
		"长弓兵视野 > 长枪兵（10 > 8）")
	# 将领的视野默认跟随所属兵种
	eq(cfg.general_vision_at(0), cfg.unit_vision_of(cfg.general_type_at(0)),
		"将领 1 的视野 = 长枪兵的视野（没写覆盖时跟随兵种）")
	eq(cfg.general_vision_at(1), cfg.unit_vision_of("longbowman"),
		"将领 2 的视野 = 长弓兵的视野")
	return true


# ------------------------------------------------------------------
# 1) 扇区基本功：自己那格一定看得见
# ------------------------------------------------------------------

func _test_sector_basics(cfg) -> void:
	# 10×6 的开阔地：半径 2 的单位看得见 2 格，够不到 (0,0)（距离 2.83）
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


# ------------------------------------------------------------------
# 2) ★ 山脉挡视线（需求第 4 条的正题）
# ------------------------------------------------------------------

func _test_mountain_blocks(cfg) -> void:
	# 一条竖着的山脊：把地图切成左右两半。视野 8 的单位站在左边，
	# 山**自己那一列**看得见（否则玩家永远看不到那片山），山**右边**看不见。
	#
	#      0123456789
	#   0  ....#.....
	#   1  ....#.....
	#   2  ....#.....
	#   3  ....#.....
	#   4  ....#.....
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

	# 山脊上开一个缺口：从缺口望过去的格子应该重新看得见（视线是从格心画的）
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


# ------------------------------------------------------------------
# 3) 其他地形不挡视线（森林 / 草地）
# ------------------------------------------------------------------

func _test_other_terrain_does_not_block(cfg) -> void:
	# 14 格宽：长弓兵（视野 10）站在最左边，中间是一整片森林 —— 整片都看得穿，
	# 但 13 格那一端仍然超出半径（森林不挡 ≠ 无限远）。
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


# ------------------------------------------------------------------
# 4) 视野半径
# ------------------------------------------------------------------

func _test_radius(cfg) -> void:
	# 一条开阔的走廊：半径 3 的单位看得见 3 格远、看不见 4 格远。
	var row := "..........."
	var map = _make_map(cfg, [row, row, row, row, row])
	var fog = FogRes.create()
	var fake = _make_fake(cfg, map, ["p1", "enemy"])
	# 用半径 3 的临时单位（`vision` 是单位自己的字段，直接改它就是「这个兵看多远」）
	var u = _add_unit(fake, cfg, "u1", 5, 2, "p1")
	u.vision = 3.0
	fog.update(fake)
	_see(fog, "p1", 8, 2, "半径 3 → 3 格远看得见")
	_dont_see(fog, "p1", 9, 2, "半径 3 → 4 格远看不见")
	# 换成正对着的斜向：3² + 3² = 18 ≤ 9？不是 —— 对角 (3,3) 距离 4.24 > 3，看不见
	_dont_see(fog, "p1", 8, 5, "半径 3 → 对角 3+3 格（距离 4.24）看不见")

	# 视野 0 = 瞎子：只看得见自己那一格
	var fog0 = FogRes.create()
	var fake0 = _make_fake(cfg, map, ["p1", "enemy"])
	var u0 = _add_unit(fake0, cfg, "u1", 5, 2, "p1")
	u0.vision = 0.0
	fog0.update(fake0)
	_see(fog0, "p1", 5, 2, "视野 0 的单位仍然看得见自己站的那一格")
	_dont_see(fog0, "p1", 6, 2, "视野 0 → 旁边一格都看不见")


# ------------------------------------------------------------------
# 5) 按阵营算视野 + 单位给视野
# ------------------------------------------------------------------

func _test_faction_vision(cfg) -> void:
	# 24 格宽：p1 在左、enemy 在右，两边互相看不见
	# （p1 单位视野 8 在 (1,2) → 最远看到 x=9；enemy 单位视野 7 在 (19,2) → 最近看到 x=12）
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

	# 单位挪到新格 → 视野跟着挪（fog 的贡献格按 tx/ty 取）
	_move_unit(foe, 6, 2)
	ok(fog.refresh_needed(fake), "★ 单位挪到新格之后 refresh_needed 为 true（否则视野不会更新）")
	fog.update(fake)
	_see(fog, "enemy", 4, 2, "单位挪到 (6,2) 之后，enemy 那边看得见 p1 家门口了")

	# 阵亡的单位不再给视野
	foe.alive = false
	ok(fog.refresh_needed(fake), "阵亡的单位会让 refresh_needed 为 true")
	fog.update(fake)
	_dont_see(fog, "enemy", 4, 2, "阵亡的单位不再提供视野")


# ------------------------------------------------------------------
# 5.5) ★★ 迷雾按**同方**分桶：合作模式两名玩家共享视野
#
# 需求（dev_plan_7 1.3.8）：合作模式要求 p1、p2 **共享视野**，而「同一方」这件事
# 在 `logic/faction.gd` 里已经有一套判据（含传递闭包）。所以 fog 只把**分桶键**
# 从「阵营」换成 `FactionRes.side_of(阵营)`，查询也走同一个 key。
#
# ★ 单机时 `side_of(p1) == "p1"` ⇒ 与从前**逐位一致**（`_test_faction_vision` 那一段是回归）。
# ⚠️ 忘了改查询那一句的症状很隐蔽：掩码按方存了、查询还按阵营查 ⇒
#    p1（代表 id 恰好等于自己）一切正常，而 p2 永远查不到东西（整屏全黑）。
# ------------------------------------------------------------------

func _test_shared_vision_same_side(cfg) -> void:
	var row := "........................"
	var map = _make_map(cfg, [row, row, row, row, row])

	# ---- 同方：p1 与 p2 结盟 ⇒ 两人共用一份视野 ----
	# p1 在左（视野 8，最远看到 x=9），p2 在右（x=20 → 视野覆盖 x≈12..24 里可见的），
	# enemy 在中间看不到的地方（x=16）—— 这样「p2 能看到 p1 那边」只可能来自共享。
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
	# ⚠️ 这里**不能**写「中间那一段仍然看不见」：x=16 那儿站着敌方单位，
	#    它的**自己的视野**本来就照亮了周围那一圈（迷雾是按「谁有眼睛」算的，
	#    不是按「谁的脸」算的）—— 那条断言会假红，而且验的是错的东西。
	#    真正要钉的是「对**没有视野来源的第三方**严格」（见下面 enemy 那一条 +
	#    「解除结盟之后 p2 立刻看不见」那一条）。
	_dont_see(fog, "enemy", 3, 2, "★★ 共享视野不会泄漏给敌方")

	# 单位可见性也一起（三类查询必须同时改，见 fog.gd 那三条）
	var foe = fake.units[2]
	ok(fog.unit_visible("p2", foe), "p2 在自己的视野里看得见敌方单位")
	ok(not fog.unit_visible("enemy", fake.units[0]),
		"★ enemy 看不到 p1 的单位（哪怕 p1/p2 共享，也没泄漏给它）")

	# ---- 解除结盟 ⇒ 立刻不再共享 ----
	FactionRes.clear_allies()
	fog.reset_cache()                      # ★ 换关系 = 换桶键，缓存必须清（与换地图同一条约定）
	fog.update(fake)
	_dont_see(fog, "p2", 4, 2, "★ 解除结盟之后 p2 看不到 p1 那边了")
	_see(fog, "p2", 21, 2, "p2 自己的视野照旧")
	_see(fog, "p1", 4, 2, "p1 自己的视野照旧")

	# ---- 三方连成一方：传递闭包也算同一方（a-b、b-c ⇒ a 与 c 共享） ----
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

	# ⚠️ 收尾：`FactionRes` 的盟友表是 **static** —— 不清掉会串到后面的用例
	#    （那些用例默认「谁跟谁都不是盟友」，沿用加这个功能之前的行为）。
	FactionRes.clear_allies()


# ------------------------------------------------------------------
# 6) 建筑也给视野（需求第 3 条：单位和建筑都要有视野）
# ------------------------------------------------------------------

func _test_buildings_give_vision(cfg) -> void:
	# 16 格宽：建筑视野走**每个类型自己的** `building.<type>.vision`
	# （城墙 5 / 箭塔 12 / 大本营 9）—— 用 16 格是为了让「塔看得见、墙看不见」
	# 这一段两边都不碰到地图边缘（12 格视野需要足够长的一条走廊）。
	var row := "................"
	var map = _make_map(cfg, [row, row, row, row, row])
	var fog = FogRes.create()
	var fake = _make_fake(cfg, map, ["p1", "enemy"])
	_add_building(fake, cfg, "b1", 1, 2, "p1", "base")
	fog.update(fake)
	_see(fog, "p1", 4, 2, "★ 己方建筑自己就给视野（不需要有单位站在旁边）")
	_dont_see(fog, "p1", 11, 2, "大本营视野 9 → 10 格处看不见")
	_see(fog, "p1", 10, 2, "大本营视野 9 → 9 格处看得见")

	# ---- ★★ 每个建筑类型自己一个视野（与 unit.types.<id>.vision 对称的那一处）----
	eq(cfg.building_vision(), cfg.fog_vision_building,
		"`building_vision()` = config 的 fog.vision_building（没写 vision 时的兜底）")
	near(cfg.building_vision_of("tower"), 12.0, 1e-6, "箭塔自己的视野 12（瞭望塔看得最远）")
	near(cfg.building_vision_of("base"), 9.0, 1e-6, "大本营 9")
	near(cfg.building_vision_of("wall"), 5.0, 1e-6, "城墙 5（一堵墙不该看得跟塔一样远）")
	ok(cfg.building_vision_of("tower") > cfg.building_vision_of("wall"),
		"★ 箭塔看得比城墙远（这三个数是各写各的）")
	near(cfg.building_vision_of("no_such_type"), cfg.fog_vision_building, 1e-6,
		"★ 认不出来的建筑类型 → 退回 fog.vision_building（不报错、也不给 0）")

	# 真的按类型生效：同一条走廊上，塔看得见的地方墙看不见
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

	# 中立障碍（区划中心 / owner = ""）不给任何人视野
	var fog4 = FogRes.create()
	var fake4 = _make_fake(cfg, map, ["p1", "enemy"])
	_add_building(fake4, cfg, "c1", 5, 2, "", "zone_center")
	fog4.update(fake4)
	_dont_see(fog4, "p1", 5, 2, "★ 中立障碍（owner = \"\"）不给任何人视野")


# ------------------------------------------------------------------
# 7) ★★ 敌方建筑：见过一次就永久记住
# ------------------------------------------------------------------

func _test_building_discovery(cfg) -> void:
	# 一张 20 格宽的长走廊：p1 的单位在最左边，敌方箭塔在最右边。
	# 用视野 3 的单位，于是「走过去 → 看见 → 走回来 → 仍然看得见 → 塔被拆 → 忘掉」
	# 这条完整的链路可以在一张图上一次走完。
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

	# 走过去：视野 3 → 站在 (13,2) 时塔在 (16,2) 正好 3 格
	_move_unit(scout, 13, 2)
	fog.update(fake)
	ok(fog.building_visible("p1", tower), "★ 走进视野之后，敌方建筑显示了")
	ok(fog.is_building_sighted("p1", tower), "★ 同时被登记进「已知敌方建筑」")

	# 走回来：塔出了视野，但记忆还在
	_move_unit(scout, 1, 2)
	fog.update(fake)
	_dont_see(fog, "p1", 16, 2, "★★ 走回来之后，那一格本身又没有视野了")
	ok(fog.building_visible("p1", tower),
		"★★ 但敌方建筑**仍然可见**（需求：若战争迷雾再次覆盖也不会消除）")
	eq(fog.known_buildings("p1").size(), 1, "记忆表里有 1 栋楼")

	# 侦察兵阵亡：记忆仍然不消失
	scout.alive = false
	fog.update(fake)
	ok(fog.building_visible("p1", tower), "★ 侦察兵死了也不影响已经记住的敌方建筑")

	# 塔被摧毁 → 记忆清掉（需求：只有被摧毁才会被消除）
	tower.alive = false
	fog.update(fake)
	ok(not fog.building_visible("p1", tower), "★ 建筑被摧毁之后不再显示")
	eq(fog.known_buildings("p1").size(), 0, "★ 记忆表里也清掉了")

	# ⚠️ 反向：**己方建筑**不需要记忆（本来就一直看得见）
	var own = _add_building(fake, cfg, "own1", 20, 2, "p1", "wall")
	fog.update(fake)
	ok(fog.building_visible("p1", own), "己方建筑永远可见（与视野无关）")
	ok(not fog.is_building_sighted("p1", own), "己方建筑不进「敌方建筑」记忆表")


# ------------------------------------------------------------------
# 8) 敌方单位：只显示当前视野里的（不保留记忆）
# ------------------------------------------------------------------

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

	# 阵亡的单位不显示
	foe.alive = false
	ok(not fog.unit_visible("p1", foe), "阵亡的敌方单位不显示")

	# 己方单位永远可见（哪怕在自己的视野之外 —— 自己的部队不会被自己的雾盖住）
	var own = _add_unit(fake, cfg, "s2", 22, 2, "p1")
	fog.update(fake)
	ok(fog.unit_visible("p1", own), "★ 己方单位永远可见（不受迷雾影响）")
	# 中立 / 其它阵营看 p1 的单位：按它们自己的视野判。
	# （p1 的单位在 (22,2)，而这张图上 enemy 一个视野来源都没有 ⇒ 看不见它）
	ok(not fog.unit_visible("enemy", own), "enemy 看不到视野之外的 p1 单位")


# ------------------------------------------------------------------
# 9) 摧毁 → 记忆清空的补充：拆除（alive = false）与换主
# ------------------------------------------------------------------

func _test_sighted_forgotten_when_destroyed(cfg) -> void:
	var row := "............"
	var map = _make_map(cfg, [row, row, row, row, row])
	var fog = FogRes.create()
	var fake = _make_fake(cfg, map, ["p1", "enemy"])
	_add_unit(fake, cfg, "u1", 1, 2, "p1")
	var b = _add_building(fake, cfg, "b1", 3, 2, "enemy", "wall")
	fog.update(fake)
	ok(fog.is_building_sighted("p1", b), "视野里的敌方建筑被登记")

	# 换主：它变成自己的了 → 不再需要记忆（`_prune_sighted` 会把不属于敌方的清掉）
	b.owner = "p1"
	fog.update(fake)
	ok(not fog.is_building_sighted("p1", b), "★ 建筑换成己方之后，不再留在「敌方建筑」记忆里")
	ok(fog.building_visible("p1", b), "但它作为己方建筑仍然可见")

	# 反过来：它现在是 enemy 眼里的**敌方建筑**。给 enemy 一个看得见它的单位，
	# 这条断言才真的在验迷雾（否则「没人有视野」也会让 visible 为 false ——
	# 那种断言看着对、其实什么都没验，是本项目最忌讳的假绿灯）。
	_add_unit(fake, cfg, "obs", 4, 2, "enemy")
	fog.update(fake)
	_see(fog, "enemy", 3, 2, "（前提）enemy 的单位在 (4,2) 看得见 (3,2)")
	ok(fog.building_visible("enemy", b),
		"★ 换成 p1 之后，这在 enemy 眼里是一栋敌方建筑 —— 它有视野就看得见")


# ------------------------------------------------------------------
# 10) 性能前提：没变化就不重算
# ------------------------------------------------------------------

func _test_refresh_throttle(cfg) -> void:
	var row := ".........."
	var map = _make_map(cfg, [row, row, row, row, row])
	var fog = FogRes.create()
	var fake = _make_fake(cfg, map, ["p1", "enemy"])
	_add_unit(fake, cfg, "u1", 1, 2, "p1")
	fog.update(fake)
	ok(not fog.refresh_needed(fake),
		"★★ 什么都没动 → refresh_needed 为 false（这是 1000 单位下的性能前提）")

	# 单位在同一格里挪一点点（还没跨格）→ 仍然不必重算（视野是**格**粒度的）
	var u = fake.units[0]
	u.pos = Vector2(1.2, 2.4)
	ok(not fog.refresh_needed(fake), "★ 同一格内的小移动不触发重算")

	# 真的跨格了 → 要重算
	u.tx = 2
	ok(fog.refresh_needed(fake), "跨格之后要重算")

	# 多一个单位 / 多一栋建筑也要重算
	var fog2 = FogRes.create()
	var fake2 = _make_fake(cfg, map, ["p1", "enemy"])
	_add_unit(fake2, cfg, "u1", 1, 2, "p1")
	fog2.update(fake2)
	_add_unit(fake2, cfg, "u2", 5, 2, "p1")
	ok(fog2.refresh_needed(fake2), "新单位出现 → 要重算（它带来新的视野来源）")
	fog2.update(fake2)
	_add_building(fake2, cfg, "b1", 8, 2, "p1", "tower")
	ok(fog2.refresh_needed(fake2), "新建筑出现 → 要重算")


# ------------------------------------------------------------------
# 11) 灰色遮罩的掩码（view/fog_view.gd）
# ------------------------------------------------------------------

func _test_fog_view_mask(cfg) -> void:
	# 10 格宽：单位在 (5,2)、视野 3 —— (0,0) 在半径外（距离 5.39 > 3）
	var row := ".........."
	var map = _make_map(cfg, [row, row, row, row, row])
	var fog = FogRes.create()
	var fake = _make_fake(cfg, map, ["p1", "enemy"])
	var u = _add_unit(fake, cfg, "u1", 5, 2, "p1")
	u.vision = 3.0
	fog.update(fake)
	fake.fog = fog

	var mask: PackedByteArray = FogViewRes.mask_for(cfg, fake, "p1")
	eq(mask.size(), map.cols * map.rows, "掩码长度 = 地图格数")
	eq(int(mask[map.terrain.idx(5, 2)]), 1, "有视野的格子在掩码里是 1")
	eq(int(mask[map.terrain.idx(0, 0)]), 0, "没视野的格子在掩码里是 0")

	# 烘出来的贴图：有视野 = 全透明、没视野 = 不透明（颜色由 modulate 给）
	var img: Image = FogViewRes._bake(mask, map, map.cols, map.rows).get_image()
	eq(img.get_width(), map.cols, "贴图宽 = 地图列数（1 像素 = 1 格）")
	eq(img.get_height(), map.rows, "贴图高 = 地图行数")
	near(img.get_pixel(5, 2).a, 0.0, 0.001, "★ 有视野的格子烘成全透明（不盖灰）")
	near(img.get_pixel(0, 0).a, 1.0, 0.001, "★ 没视野的格子烘成不透明（盖灰）")

	# ★ 地图外的格子（exists = false）不该被盖：那里本来什么都没有
	map.exists.set_cell(0, 0, false)
	var img2: Image = FogViewRes._bake(mask, map, map.cols, map.rows).get_image()
	near(img2.get_pixel(0, 0).a, 0.0, 0.001, "★ 地图外的格子烘成透明（不在地图上盖灰）")

	# 拿不到掩码时（fog 还没算过）返回全 0 = 全图盖灰（宁可盖住也不要「全图点亮」）
	var empty_fake := _make_fake(cfg, map, ["p1", "enemy"])
	var empty: PackedByteArray = FogViewRes.mask_for(cfg, empty_fake, "p1")
	eq(empty.size(), map.cols * map.rows, "没有 fog 时也返回正确长度的掩码")
	eq(int(empty[map.terrain.idx(5, 2)]), 0, "★ 没有 fog 时掩码全 0（整屏盖灰，而不是全亮）")


# ------------------------------------------------------------------
# 12) ★ 被迷雾盖住的敌人不能被选中 / 不能被点名攻击
# ------------------------------------------------------------------

## 把鼠标摆到某一格上（等价于 poll_mouse 每帧做的那两行）。
## ★ 走的是 input_controller 自己的 `_sync_hover_from_mouse()`（同一个口径），
##   不自己算 `hover_tile` —— 免得测试与实现各写一份换算（pitfalls 3.1 那类错位）。
func _aim_at(ctrl, tx: int, ty: int) -> void:
	ctrl.mouse_world = GridRes.center_of(Vector2i(tx, ty))
	ctrl._sync_hover_from_mouse()


func _test_pick_blocked_by_fog(cfg) -> void:
	# 在**真地图 + 真 world** 上验（这条要求联动 input_controller，合成世界不够）
	var w = require_world(cfg)
	ok(w != null, "world 能建出来（真地图）")
	if w == null:
		return
	# 对家据点（data/maps/frontier/map.json 的 buildings：base(14,14) / tower(14,12) / tower(16,14) / 墙×3）
	var tower = null
	for b in w.building_list:
		if b.owner == "enemy" and b.type == "tower":
			tower = b
			break
	ok(tower != null, "真地图上有敌方的箭塔（对家据点）")
	if tower == null:
		return
	# 开局：p1 的单位在家里（7,2 附近），对家据点在 (14,14) —— 一定看不见
	ok(not w.fog.building_visible(w.my_faction, tower),
		"★★ 开局看不见对家的箭塔（p1 大本营在 (7,2)、据点在 (14,14)）")

	var ctrl = InputControllerRes.new()
	ctrl.setup(cfg, w, null)

	# ---- 左键点那座塔：迷雾里 → 什么都不选中 ----
	_aim_at(ctrl, tower.tx, tower.ty)
	ctrl._on_left_click(false)
	eq(ctrl.selected_building, null, "★★ 迷雾里的敌方建筑左键点不中（不会被选中）")

	# ---- 右键点那座塔：不能被当成「点名拆它」 ----
	# 先选上自己的部队（不给它就发不出命令 —— _on_right_click 开头会直接返回）
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

	# ---- 把单位挪到塔旁边（2 格）→ 立刻发现，也就能选中 / 点名 ----
	_move_unit(u, tower.tx - 2, tower.ty)
	ctrl.select_units([])
	w.fog.update(w)
	ok(w.fog.building_visible(w.my_faction, tower),
		"★★ 单位走到旁边之后，对家的箭塔被发现了")
	_aim_at(ctrl, tower.tx, tower.ty)
	ctrl._on_left_click(false)
	ok(ctrl.selected_building == tower, "★ 现在左键点得中它了")

	# ---- 走开：记忆还在 → 仍然点得中（需求第 2 条） ----
	_move_unit(u, 7, 2)
	ctrl.select_units([])
	w.fog.update(w)
	_aim_at(ctrl, tower.tx, tower.ty)
	ctrl._on_left_click(false)
	ok(ctrl.selected_building == tower,
		"★★ 走开之后（迷雾重新盖住）仍然点得中它 —— 见过一次就永久记住")

	# ---- 迷雾里的敌方**单位**同样点不到 ----
	# ★★ 敌人**现造**（`w.spawn_enemy()`），不依赖地图预置单位：
	#    `data/maps/*/map.json` 的 `units[]` 已经废弃（运行时不读它），所以
	#    原来那句「从 w.units 里找一个敌方单位」在真地图上永远是 null。
	#    ⚠️ 不能写死坐标：默认刷兵点在地图右边缘，而那张图右边缘那一列不可通行
	#    （实测），所以这里挑一个**确实刷出来**的坐标，并断言它真的刷出来了 ——
	#    刷不出来时下面那几条断言会全部静默跳过，那就是假绿灯。
	var foe = w.spawn_enemy(20, 20)
	ok(foe != null, "刷出一个敌方单位来做「迷雾里的敌人」这条用例")
	if foe != null:
		ok(not w.fog.unit_visible(w.my_faction, foe), "开局看不见刷出来的那个敌人")
		eq(ctrl._pick_foe_unit_at(GridRes.center_of(Vector2i(foe.tx, foe.ty))), null,
			"★★ 迷雾里的敌方单位不能被点名（_pick_foe_unit_at 返回 null）")
		# 把 p1 的单位挪到它旁边 → 立刻能被点名
		_move_unit(u, foe.tx - 1, foe.ty)
		w.fog.update(w)
		ok(w.fog.unit_visible(w.my_faction, foe), "走到旁边之后看得见它")
		ok(ctrl._pick_foe_unit_at(GridRes.center_of(Vector2i(foe.tx, foe.ty))) == foe,
			"★ 现在能点名打它了")


# ------------------------------------------------------------------
# 13) ★ 真游戏场景里的接线：遮罩画得出来、view 真的按迷雾剔除
#
# ★★ 为什么非要挂一次真场景：这一层最容易**静默失败** ——
#    `_draw()` 里的报错不会让测试失败（只打红字），
#    `z_index` 排错了（遮罩压在单位下面）也不会报错、只是画面上看不到灰。
#    所以这里既钉「有没有画」这个可数的痕迹，也钉「谁在谁上面」这个顺序。
# ------------------------------------------------------------------

func _test_game_scene_wires_fog() -> void:
	var cfg = require_config()
	var packed = load("res://view/main.tscn")
	ok(packed != null, "能载入主场景 main.tscn")
	if packed == null:
		return
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	main._on_test_pressed(main.start_screen.selected_map_path())
	await process_frame
	await process_frame

	var game = main.game
	ok(game != null, "按下 test 之后建出了游戏内场景")
	if game == null:
		main.queue_free()
		return

	# ---- 场景里真的有一个迷雾节点，而且排在地形之上、单位之上、覆盖层之下 ----
	ok(game.fog_view != null, "★★ GameScene 里建出了 FogView（灰色遮罩那一层）")
	ok(game.fog_view.z_index > game.terrain_view.z_index,
		"★ 遮罩盖在地形之上（z_index %d > %d）"
		% [game.fog_view.z_index, game.terrain_view.z_index])
	ok(game.fog_view.z_index > game.unit_view.z_index,
		"★ 遮罩盖在单位之上（看不见的敌人本来也不画，但灰要压在看得见的东西上）")
	ok(game.fog_view.z_index < game.overlay.z_index,
		"★★ 遮罩在覆盖层之下 —— 自己的移动标记 / 框选矩形不被雾吃掉")

	# ---- 世界有迷雾，而且**进游戏第一帧之前**就算过了 ----
	var w = game.world
	ok(w.fog != null, "world 上有 fog")
	if w.fog != null:
		eq(w.fog.sight.size() > 0, true, "★ 开局就算过一次视野（不是等到第一次 tick）")
		var base_b = w.find_base_of(w.my_faction)
		if base_b != null:
			ok(w.fog.tile_visible(w.my_faction, base_b.tx, base_b.ty),
				"★ 家里那一块有视野（开局屏上不是一整片灰）")

	# ---- 遮罩真的发出了绘制指令（可数的痕迹）----
	game.fog_view._draw()
	eq(game.fog_view.draw_count, 1, "★★ 迷雾层发出一张铺满地图的遮罩（一次 draw_texture_rect）")

	# ---- 单位视图真的按迷雾剔除：把敌人的位置搬到「没视野」的角落再看 ----
	var uv = game.unit_view
	var my_units: Array = w.alive_units_of(w.my_faction)
	ok(my_units.size() > 0, "己方有单位")
	if my_units.size() > 0:
		ok(uv._visible_to_me(my_units[0]), "★ 己方单位永远可见（不会被自己的雾藏起来）")
	# 找一个**现在没视野**的格子，把敌人的坐标挪过去：应当立刻不可见
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
			# ★ 小地图住在 hud 上（不是 game_scene 的字段）—— 同一条判据、同一份掩码
			var mm = game.hud.minimap if game.hud != null else null
			ok(mm != null, "HUD 里有小地图控件")
			if mm != null:
				ok(not mm._unit_visible(enemy),
					"★★ 小地图也读同一份判据（两边不会各显示一套）")

	main.queue_free()


## 找一个**当前没视野**的格子（给上面那条「躲起来就看不见」用）。
## ★ 用「遍历地图」而不是写死坐标：换地图之后这条断言照样成立（pitfalls 5.51）。
func _first_invisible_tile(w, fid: String) -> Vector2i:
	for ty in w.map.rows:
		for tx in w.map.cols:
			if not w.map.tile_exists(tx, ty):
				continue
			if not w.fog.tile_visible(fid, tx, ty):
				return Vector2i(tx, ty)
	return Vector2i(-1, -1)
