## test_smoke.gd —— 脚手架自检 + 网格工具 + 数据载入（M0）
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const UnitRes = preload("res://logic/unit.gd")

const EXPECTED_GRID_COLS := 24
const EXPECTED_GRID_ROWS := 16
const EXPECTED_MAP_COLS := 27
const EXPECTED_MAP_ROWS := 22

func _initialize() -> void:
	_case_name = "test_smoke"
	run_all(_cases)

func _cases() -> void:
	ok(true, "脚手架能执行 _initialize()")
	eq(1 + 1, 2, "算术正常")

	var g = GridRes.new(4, 3, 0)
	eq(g.cols, 4, "Grid.cols")
	eq(g.rows, 3, "Grid.rows")
	eq(g.data.size(), 12, "Grid 底层一维数组长度 = cols*rows")
	ok(g.has(3, 2), "has 边界内")
	ok(not g.has(4, 2), "has 越界列")
	ok(not g.has(-1, 0), "has 越界负值")
	ok(g.get_cell(-1, 0) == null, "越界 get_cell 返回 null 而不是崩")
	ok(not g.set_cell(9, 9, 7), "越界 set_cell 返回 false")
	eq(g.idx(3, 2), 2 * 4 + 3, "idx = y*cols+x（列 4 行 3 时，(3,2) → 11）")

	g.set_cell(1, 2, 42)
	eq(g.get_cell(1, 2), 42, "set/get 往返")
	var clone = g.clone()
	eq(clone.get_cell(1, 2), 42, "clone 复制数据")
	clone.set_cell(1, 2, 7)
	eq(g.get_cell(1, 2), 42, "clone 是深拷贝（改克隆不影响原对象）")

	eq(g.count_where(func(v, _x, _y): return v == 0), 11, "count_where 数默认值")
	eq(g.count_where(func(v, _x, _y): return v == 42), 1, "count_where 数写入值")

	eq(GridRes.DIRS4.size(), 4, "DIRS4 是四个方向")
	var manhattan_sum = 0
	for d in GridRes.DIRS4:
		manhattan_sum += absi(d.x) + absi(d.y)
	eq(manhattan_sum, 4, "DIRS4 每步都是曼哈顿 1（没有对角线）")

	v2i_eq(GridRes.tile_of(Vector2(0.0, 0.0)), Vector2i(0, 0), "tile_of 原点")
	v2i_eq(GridRes.tile_of(Vector2(1.99, 2.01)), Vector2i(1, 2), "tile_of 格内任意位置")
	v2i_eq(GridRes.tile_of(Vector2(2.0, 2.0)), Vector2i(2, 2), "tile_of 正好在格线上归后一格")
	near(GridRes.center_of(Vector2i(3, 4)).x, 3.5, 1e-6, "center_of.x")
	near(GridRes.center_of(Vector2i(3, 4)).y, 4.5, 1e-6, "center_of.y")

	var cfg = require_config()
	if cfg == null:
		return

	eq(cfg.cols, EXPECTED_GRID_COLS, "config grid.cols")
	eq(cfg.rows, EXPECTED_GRID_ROWS, "config grid.rows")
	near(cfg.cell_px, 128.0, 1e-6, "渲染格宽 render.cell_px（已从 64 放大一倍）")

	near(cfg.unit_speed, 0.6, 1e-6, "★ 单位速度 0.6 格/秒（降到 1/4）")
	near(cfg.unit_forest_mult, 0.5, 1e-6, "森林减速 ×0.5")
	near(cfg.unit_hp_max, 200.0, 1e-6, "兜底生命 200")
	near(cfg.unit_radius_factor, 0.1, 1e-6, "单位半径系数 0.1（兜底）")
	near(cfg.aggro_range, 4.0, 1e-6, "警戒半径 4 格")
	near(cfg.leash_factor, 1.8, 1e-6, "追击上限系数 1.8")
	near(cfg.repath_sec, 0.3, 1e-6, "追击重寻路 0.3 秒")
	near(cfg.building_damage, 40.0, 1e-6, "拆建筑伤害 40")

	near(cfg.unit_hp_of(UnitRes.UNIT_TYPE_SPEARMAN), 140.0, 1e-6, "长枪兵生命 140")
	near(cfg.unit_hp_of(UnitRes.UNIT_TYPE_LONGBOWMAN), 80.0, 1e-6, "长弓兵生命 80")
	near(cfg.unit_hp_of(UnitRes.UNIT_TYPE_RIDER), 110.0, 1e-6, "骑手生命 110")
	near(cfg.unit_speed_of(UnitRes.UNIT_TYPE_SPEARMAN), 0.6, 1e-6, "长枪兵速度 0.6")
	near(cfg.unit_speed_of(UnitRes.UNIT_TYPE_RIDER), 1.2, 1e-6, "★ 骑手更快（1.2 格/秒）")
	near(float(cfg.unit_combat_of(UnitRes.UNIT_TYPE_LONGBOWMAN)["range"]), 4.0, 1e-6,
		"★ 长弓兵是远程（4 格）")
	near(float(cfg.unit_combat_of(UnitRes.UNIT_TYPE_SPEARMAN)["range"]), 1.0, 1e-6,
		"长枪兵是近战（1 格）")
	eq(cfg.unit_class_of(UnitRes.UNIT_TYPE_SPEARMAN), ConfigRes.CLASS_INFANTRY, "长枪兵 = 步兵")
	eq(cfg.unit_class_of(UnitRes.UNIT_TYPE_LONGBOWMAN), ConfigRes.CLASS_INFANTRY, "长弓兵 = 步兵")
	eq(cfg.unit_class_of(UnitRes.UNIT_TYPE_RIDER), ConfigRes.CLASS_CAVALRY, "骑手 = 骑兵")
	ok(not cfg.unit_is_ranged(UnitRes.UNIT_TYPE_SPEARMAN), "长枪兵不是远程")
	ok(cfg.unit_is_ranged(UnitRes.UNIT_TYPE_LONGBOWMAN), "★ 长弓兵是远程步兵（弓箭手那一类）")
	ok(not cfg.unit_is_ranged(UnitRes.UNIT_TYPE_RIDER), "骑手是近战骑兵")
	eq(cfg.unit_class_line(UnitRes.UNIT_TYPE_LONGBOWMAN), "远程步兵", "★ 长弓兵的标签是「远程步兵」")
	eq(cfg.unit_class_line(UnitRes.UNIT_TYPE_RIDER), "骑兵", "骑手的标签是「骑兵」")
	eq(cfg.general_types().size(), 10, "配置里给了十位将领的类型（#0 + 可招募 #1-9）")
	eq(cfg.general_type_at(0), UnitRes.UNIT_TYPE_SPEARMAN, "将领 1 = 长枪兵")
	eq(cfg.general_type_at(1), UnitRes.UNIT_TYPE_LONGBOWMAN, "将领 2 = 长弓兵")
	eq(cfg.general_type_at(2), UnitRes.UNIT_TYPE_RIDER, "将领 3 = 骑手")
	eq(cfg.general_type_at(9), UnitRes.UNIT_TYPE_SPEARMAN, "★ 开局将领 #0 = 长枪兵")
	eq(cfg.unit_type_of("general_2"), UnitRes.UNIT_TYPE_LONGBOWMAN, "general_2 也是长弓兵")
	eq(cfg.unit_type_of("general_0"), UnitRes.UNIT_TYPE_SPEARMAN, "general_0 = 长枪兵")
	eq(cfg.unit_type_of("general"), UnitRes.UNIT_TYPE_SPEARMAN, "general 默认取第一个类型")
	eq(cfg.unit_name_of(UnitRes.UNIT_TYPE_RIDER), "骑手", "unit_name_of 走类型表")
	eq(cfg.unit_name_of("general_1"), "将领", "将领类的显示名仍是「将领」")
	ok(not cfg.has_method("general_escort_at"), "★★ 全局缺省编制已删除：cfg 没有 general_escort_at()")
	ok(not cfg.has_method("general_escort_count"), "★★ 也没有 general_escort_count()")

	ok(not cfg.has_method("enemy_damage_at"), "（形状）cfg 不再有敌人专用数值入口")
	ok(not cfg.has_unit_type("enemy"), "★★ unit.types 里不再有 enemy 这个类型")
	ok(cfg.has_unit_type(UnitRes.UNIT_TYPE_SPEARMAN), "★★ 长枪兵仍然是合法类型（调试刷兵用它）")
	near(cfg.unit_hp_of(UnitRes.UNIT_TYPE_SPEARMAN), 140.0, 1e-6, "长枪兵血量 140")
	eq(cfg.zone_cols, 6, "区块横向 6 列")
	eq(cfg.zone_rows, 4, "区块纵向 4 行")
	near(cfg.capture_time_sec, 16.0, 1e-6, "占领耗时 16 秒（基准：1 个单位独自占下）")
	near(cfg.decay_per_sec, 0.0625, 1e-6, "进度回退 0.0625/秒（满条 16 秒退完，与占领 1:1）")
	near(cfg.zone_speed_max_mult, 2.0, 1e-6, "人数加成上限 x2")
	near(cfg.zone_speed_curve_k, 2.5, 1e-6, "人数加成归一化常数 k=2.5")
	near(cfg.zone_speed_curve_power, 1.7, 1e-6, "人数加成指数 p=1.7（>1 才是先慢后快）")
	near(cfg.unit_radius(), 0.1, 1e-6, "unit_radius() 单位是「格」而不是像素")

	eq(cfg.int_val("building.wall.hp_max", 0), 300, "木墙生命 300")
	eq(cfg.int_val("building.stone_wall.hp_max", 0), 700, "★★ 石墙生命 700")
	eq(cfg.int_val("building.base.hp_max", 0), 1000, "大本营生命 1000")
	near(cfg.num("building.tower.damage", 0.0), 12.0, 1e-6, "哨塔伤害 12")
	near(cfg.num("building.tower.range", 0.0), 3.0, 1e-6, "哨塔射程 3 格")
	near(cfg.num("building.tower.cooldown", 0.0), 0.8, 1e-6, "哨塔间隔 0.8s")
	near(cfg.num("building.watch_tower.damage", 0.0), 16.0, 1e-6, "★★ 警戒塔伤害 16")
	near(cfg.num("building.watch_tower.range", 0.0), 4.0, 1e-6, "★★ 警戒塔射程 4 格")
	near(cfg.building_ranged_reduction("wall"), 0.9, 1e-6, "★★ 木墙远程免伤 90%")
	near(cfg.building_ranged_reduction("base"), 0.9, 1e-6, "★★ 大本营也有 90% 远程免伤")
	ok(not cfg.has_upgrade("wall"), "★★ 木墙没有升级表")
	ok(not cfg.has_upgrade("tower"), "★★ 哨塔没有升级表")

	eq(cfg.bool_val("economy.enabled", false), true,
		"★ 建造不再免费（economy.enabled = true）—— 木墙 / 哨塔的 cost 不再是空转的")
	eq(cfg.destructible_base, false, "单机大本营不可摧毁")
	eq(cfg.respawn_sec, 8.0, "复活的数值留着（第 1 轮用），但由运行时开关控制")

	eq(cfg.num("combat.不存在", 4.0), 4.0, "num() 缺字段时返回默认值")
	eq(cfg.str_val("不存在", "x"), "x", "str_val() 缺字段时返回默认值")

	var grass = ConfigRes.parse_color("#33422f")
	near(grass.r, 0x33 / 255.0, 1e-4, "parse_color 解析 #rrggbb 的 r")
	near(grass.a, 1.0, 1e-6, "parse_color 十六进制不透明")
	var grid_line = ConfigRes.parse_color("rgba(255,255,255,0.055)")
	near(grid_line.r, 1.0, 1e-6, "parse_color 解析 rgba 的 r")
	near(grid_line.a, 0.055, 1e-6, "parse_color 解析 rgba 的 alpha")
	var zone_line = ConfigRes.parse_color("rgba(230,190,80,0.30)")
	near(zone_line.b, 80.0 / 255.0, 1e-4, "parse_color 解析 rgba 的 b")

	var c_player = cfg.faction_color("p1")
	var c_p1 = cfg.faction_color("p1")
	ok(c_player.is_equal_approx(c_p1), "player 与 p1 主色一致")
	var c_enemy = cfg.faction_color("enemy")
	ok(not c_player.is_equal_approx(c_enemy), "敌方配色与己方不同")
	for i in range(1, 9):
		var f = "p%d" % i
		ok(cfg.get_path_value("colors.faction.%s.main" % f) != null, "配色表含 %s" % f)
	ok(cfg.faction_line_color("p1", 0.4).a > 0.39, "攻击线颜色能按 alpha 现算")

	var unit_raw: Dictionary = cfg.get_path_value("unit") as Dictionary
	var dmg: float = float(unit_raw["types"]["spearman"]["damage"])
	near(cfg.num("unit.types.spearman.damage", 0.0), dmg, 1e-6, "get_path_value 支持嵌套路径")
	ok(cfg.get_path_value("unit.general.types") is Array, "get_path_value 也能取数组（将领类型表）")

	var m = require_map(cfg)
	if m == null:
		return

	eq(m.cols, EXPECTED_MAP_COLS, "地图列数与预期一致（%d）" % EXPECTED_MAP_COLS)
	eq(m.rows, EXPECTED_MAP_ROWS, "地图行数与预期一致（%d）" % EXPECTED_MAP_ROWS)
	eq(m.terrain.cols, EXPECTED_MAP_COLS, "地形网格列数")
	eq(m.terrain.rows, EXPECTED_MAP_ROWS, "地形网格行数")

	var declared_p1 := Vector2i(int(m.faction_bases["p1"][0]), int(m.faction_bases["p1"][1]))
	v2i_eq(m.base, declared_p1, "主阵营参考点 = faction_bases.p1")
	ok(m.terrain_walkable(m.base.x, m.base.y), "大本营所在地块可通行（不是山）")
	eq(m.general_spawns.size(), 3, "3 个将领出生点")

	var mountains = 0
	var walkable = 0
	for y in m.rows:
		for x in m.cols:
			if m.terrain_walkable(x, y):
				walkable += 1
			else:
				mountains += 1
	eq(mountains + walkable, m.cols * m.rows, "地形格数 = 列 × 行")

	var reach = m.flood_fill_terrain(m.base)
	var unreachable = 0
	for y in m.rows:
		for x in m.cols:
			if not m.terrain_walkable(x, y):
				continue
			if not reach.has(m.terrain.idx(x, y)):
				unreachable += 1
	eq(unreachable, 0, "连通性修正后不存在走不到的可通行格")
	ok(reach.size() > 100, "可通行区域是一大片（不是几个格子）")

	var forest_tile := Vector2i(-1, -1)
	for y in m.rows:
		for x in m.cols:
			if m.is_forest(x, y):
				forest_tile = Vector2i(x, y)
				break
		if forest_tile.x >= 0:
			break
	ok(forest_tile.x >= 0, "地图里有森林格")
	if forest_tile.x >= 0:
		ok(m.terrain_cost(forest_tile.x, forest_tile.y) > 1.0, "森林的移动代价高于草地")
	near(m.terrain_cost(m.base.x, m.base.y), 1.0, 1e-6, "草地（大本营格）的移动代价是 1")

	var layout = m.spawn_layout_for("p1", "p1")
	v2i_eq(layout["base"], declared_p1, "p1 大本营就在地图指定的那一格")
	eq(layout["spawns"].size(), 3, "p1 有 3 个将领站位")
	ok(not layout.has("defenses"),
		"★ 出生点**不再**自动生成防御阵地（城墙 / 箭塔）")

	ok(not m.has_declared_base(), "★ 发布图里没有老式 base 字段")
	eq(m.faction_bases.size(), 2, "★ 发布图带 faction_bases（p1 / p2 两个）")

	var p1_solo = m.spawn_layout_for("p1", "p1")
	v2i_eq(p1_solo["base"], declared_p1, "名单只有 p1 时，主阵营 p1 在它自己那一格")

	var p1_layout = m.spawn_layout_for("p1", "p1")
	var p2_layout = m.spawn_layout_for("p2", "p1")
	ok(p2_layout["base"] != p1_layout["base"], "p2 的大本营与 p1 不重合")
	eq(p2_layout["spawns"].size(), 3, "p2 也是 3 个将领站位")
	ok(not p2_layout.has("defenses"), "p2 也不再自带防御阵地")
