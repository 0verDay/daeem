## test_smoke.gd —— 脚手架自检 + 网格工具 + 数据载入（M0）
##
## M0 只测三件事（见 docs/route.md 第五节 M0）：
##   1. 脚手架本身能跑、退出码正确
##   2. GridRes 的索引换算与边界
##   3. config.json / test_map.json 能解析，且关键数值与 HTML 版一致
##
## ⚠️ 为什么先测 config：所有平衡数值都在 JSON 里，一旦它悄悄坏了，
##    表现是「手感不对」而不是「报错」，是最难查的一类问题。
## ⚠️ 用 preload 常量而不是全局类名：命令行 --script 启动时没有全局类缓存，
##    见 tests/test_case.gd 顶部注释（已实测）。
extends "res://tests/test_case.gd"

## GridRes / ConfigRes / MapDataRes 必须在**本文件**里声明：子类能用父类的 const，
## 但 `--script` 模式下类型解析不跨文件，跨文件类型一律走本文件的 preload 常量。
const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")

## `config.json` 的 grid 是「编辑器新画一张图的默认画布尺寸」，**不是**某张图的实际尺寸。
const EXPECTED_GRID_COLS := 24
const EXPECTED_GRID_ROWS := 16
## 随游戏发布的那张图（`data/test_map.json`，地图编辑器导出）的实际尺寸。
const EXPECTED_MAP_COLS := 27
const EXPECTED_MAP_ROWS := 22


func _initialize() -> void:
	_case_name = "test_smoke"
	run_all(_cases)


func _cases() -> void:
	# ---- 1. 脚手架自检 ----
	ok(true, "脚手架能执行 _initialize()")
	eq(1 + 1, 2, "算术正常")

	# ---- 2. 网格工具 ----
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

	# 四连通方向：上、右、下、左，且没有对角线
	eq(GridRes.DIRS4.size(), 4, "DIRS4 是四个方向")
	var manhattan_sum = 0
	for d in GridRes.DIRS4:
		manhattan_sum += absi(d.x) + absi(d.y)
	eq(manhattan_sum, 4, "DIRS4 每步都是曼哈顿 1（没有对角线）")

	# 连续坐标 → 地块（logic/ 里位置是浮点、不吸附格心）
	v2i_eq(GridRes.tile_of(Vector2(0.0, 0.0)), Vector2i(0, 0), "tile_of 原点")
	v2i_eq(GridRes.tile_of(Vector2(1.99, 2.01)), Vector2i(1, 2), "tile_of 格内任意位置")
	v2i_eq(GridRes.tile_of(Vector2(2.0, 2.0)), Vector2i(2, 2), "tile_of 正好在格线上归后一格")
	near(GridRes.center_of(Vector2i(3, 4)).x, 3.5, 1e-6, "center_of.x")
	near(GridRes.center_of(Vector2i(3, 4)).y, 4.5, 1e-6, "center_of.y")

	# ---- 3. 配置 ----
	var cfg = require_config()
	if cfg == null:
		return

	eq(cfg.cols, EXPECTED_GRID_COLS, "config grid.cols")
	eq(cfg.rows, EXPECTED_GRID_ROWS, "config grid.rows")
	near(cfg.cell_px, 128.0, 1e-6, "渲染格宽 render.cell_px（已从 64 放大一倍）")

	# 手感数值：除下面标了 ★ 的三项（格宽与速度的本轮调整）之外，必须与 HTML 版逐个一致
	# （docs/porting.md 第四节）
	near(cfg.unit_speed, 0.6, 1e-6, "★ 单位速度 0.6 格/秒（降到 1/4）")
	near(cfg.unit_forest_mult, 0.5, 1e-6, "森林减速 ×0.5")
	near(cfg.unit_hp_max, 200.0, 1e-6, "将领生命 200")
	near(cfg.unit_radius_factor, 0.1, 1e-6, "单位半径系数 0.1")
	near(cfg.aggro_range, 4.0, 1e-6, "警戒半径 4 格")
	near(cfg.leash_factor, 1.8, 1e-6, "追击上限系数 1.8")
	near(cfg.repath_sec, 0.3, 1e-6, "追击重寻路 0.3 秒")
	near(cfg.building_damage, 40.0, 1e-6, "拆建筑伤害 40")
	near(cfg.general_damage, 26.0, 1e-6, "将领伤害 26")
	near(cfg.general_cooldown, 0.9, 1e-6, "将领攻击间隔 0.9s")
	near(cfg.enemy_damage, 10.0, 1e-6, "测试敌人伤害 10")
	near(cfg.enemy_cooldown, 1.2, 1e-6, "测试敌人攻击间隔 1.2s")
	near(cfg.enemy_speed, 0.45, 1e-6, "★ 测试敌人速度 0.45 格/秒（降到 1/4）")
	near(cfg.enemy_hp, 60.0, 1e-6, "测试敌人生命 60")
	eq(cfg.zone_cols, 6, "区块横向 6 列")
	eq(cfg.zone_rows, 4, "区块纵向 4 行")
	# ★ 这两个数是**需求定的**，但断言写成「等于 config 里的值」没意义 ——
	#   这里钉的是「载入路径通」+「量级对」。真正的历史沿革写在注释里：
	#     占领耗时 4 → 32 秒（需求「速度缩小为原来的 1/8」）
	#     回退 0.125 → 0.03125 每秒（需求「降低速度缩小为原来的 1/4」）
	near(cfg.capture_time_sec, 32.0, 1e-6, "占领耗时 32 秒（基准：1 个单位独自占下）")
	near(cfg.decay_per_sec, 0.03125, 1e-6, "进度回退 0.03125/秒（满条 32 秒退完）")
	# ★ 人数加成曲线的参数（本轮新机制）：上限 x2、k=2.5、指数 1.7
	near(cfg.zone_speed_max_mult, 2.0, 1e-6, "人数加成上限 x2")
	near(cfg.zone_speed_curve_k, 2.5, 1e-6, "人数加成归一化常数 k=2.5")
	near(cfg.zone_speed_curve_power, 1.7, 1e-6, "人数加成指数 p=1.7（>1 才是先慢后快）")
	near(cfg.unit_radius(), 0.1, 1e-6, "unit_radius() 单位是「格」而不是像素")

	# 城墙生命 / 箭塔数值在 building 段里
	eq(cfg.int_val("building.wall.hp_max", 0), 300, "城墙生命 300")
	eq(cfg.int_val("building.base.hp_max", 0), 1000, "大本营生命 1000")
	near(cfg.num("building.tower.damage", 0.0), 12.0, 1e-6, "箭塔伤害 12")
	near(cfg.num("building.tower.range", 0.0), 3.0, 1e-6, "箭塔射程 3 格")
	near(cfg.num("building.tower.cooldown", 0.0), 0.8, 1e-6, "箭塔间隔 0.8s")

	# 单机总开关：建造免费、大本营不可摧毁、不复活（v0.3 行为）
	eq(cfg.bool_val("economy.enabled", true), false, "单机建造免费（economy.enabled = false）")
	eq(cfg.destructible_base, false, "单机大本营不可摧毁")
	eq(cfg.respawn_sec, 8.0, "复活的数值留着（第 1 轮用），但由运行时开关控制")

	# 取值器：缺失字段不能用 0 冒充（那种「静默错值」最难查）
	eq(cfg.num("combat.不存在", 4.0), 4.0, "num() 缺字段时返回默认值")
	eq(cfg.str_val("不存在", "x"), "x", "str_val() 缺字段时返回默认值")

	# 颜色解析：'#rrggbb' 与 'rgba(r,g,b,a)' 两种写法都要对
	var grass = ConfigRes.parse_color("#33422f")
	near(grass.r, 0x33 / 255.0, 1e-4, "parse_color 解析 #rrggbb 的 r")
	near(grass.a, 1.0, 1e-6, "parse_color 十六进制不透明")
	var grid_line = ConfigRes.parse_color("rgba(255,255,255,0.055)")
	near(grid_line.r, 1.0, 1e-6, "parse_color 解析 rgba 的 r")
	near(grid_line.a, 0.055, 1e-6, "parse_color 解析 rgba 的 alpha")
	var zone_line = ConfigRes.parse_color("rgba(230,190,80,0.30)")
	near(zone_line.b, 80.0 / 255.0, 1e-4, "parse_color 解析 rgba 的 b")

	# 阵营配色：单机 'player' 与 p1 必须同为黄色（否则联机改造会改变单机观感）
	var c_player = cfg.faction_color("p1")
	var c_p1 = cfg.faction_color("p1")
	ok(c_player.is_equal_approx(c_p1), "player 与 p1 主色一致")
	var c_enemy = cfg.faction_color("enemy")
	ok(not c_player.is_equal_approx(c_enemy), "敌方配色与己方不同")
	# 配色表与席位表同源：p1..p8 全都有（HTML 版只到 p4，p5~p8 退化成 p1 的颜色）
	for i in range(1, 9):
		var f = "p%d" % i
		ok(cfg.get_path_value("colors.faction.%s.main" % f) != null, "配色表含 %s" % f)
	ok(cfg.faction_line_color("p1", 0.4).a > 0.39, "攻击线颜色能按 alpha 现算")

	# 读取任意路径
	near(cfg.num("combat.general.damage", 0.0), 26.0, 1e-6, "get_path_value 支持嵌套路径")

	# ---- 4. 地图 ----
	# ★★ 现在只有**一张**图（`data/test_map.json`，地图编辑器导出件，27×22）。
	#    `EXPECTED_MAP_*` 是**这一张图自己的尺寸**（改了地图就跟着改这两个常量），
	#    它不是「游戏要求地图多大」—— 游戏侧一切尺寸都从地图读（见下面那些断言）。
	#    ⚠️ 别再往测试里塞「(2,2) 是玩家大本营」这种坐标：地图是设计师手里的东西，
	#       搬一次家就会让一批断言集体假失败（这一轮已经领教过）。
	var m = require_map(cfg)
	if m == null:
		return

	eq(m.cols, EXPECTED_MAP_COLS, "地图列数与预期一致（%d）" % EXPECTED_MAP_COLS)
	eq(m.rows, EXPECTED_MAP_ROWS, "地图行数与预期一致（%d）" % EXPECTED_MAP_ROWS)
	eq(m.terrain.cols, EXPECTED_MAP_COLS, "地形网格列数")
	eq(m.terrain.rows, EXPECTED_MAP_ROWS, "地形网格行数")

	# 大本营 = 地图里 p1 那一格（faction_bases.p1）——**以地图为准**，不写死坐标
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

	# 连通性修正之后：所有可通行格都必须从大本营走得到（这是修正存在的唯一理由）
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

	# 森林更贵、草地是 1（找一格森林来测，别写死坐标）
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

	# 出生点布局：p1 用地图里指定的那一格（test_map.json 的 faction_bases.p1）
	var layout = m.spawn_layout_for("p1", "p1")
	v2i_eq(layout["base"], declared_p1, "p1 大本营就在地图指定的那一格")
	eq(layout["spawns"].size(), 3, "p1 有 3 个将领站位")
	# ★ 走的是 `_ring_layout`（出生点自带一小段城墙 + 一座箭塔）
	ok((layout["defenses"] as Array).size() > 0,
		"★ 带 faction_bases 的地图：出生点自带防御阵地（%d 个）"
		% (layout["defenses"] as Array).size())

	# ★ 老式大本营（JSON 里那个单数 base）已经彻底删掉
	#   ⚠️ 方法名是 `has_declared_base()`；以前这里写成 `file_has_declared_base()`，
	#      无头跑出来是一句 SCRIPT ERROR（那一条断言根本没执行）。
	ok(not m.has_declared_base(), "★ 发布图里没有老式 base 字段")
	eq(m.faction_bases.size(), 2, "★ 发布图带 faction_bases（p1 / p2 两个）")

	# ★「主阵营」只由名单顺序决定，不由「我是谁」决定。
	#   单机名单是 ['p1']，所以主阵营就是 p1。
	var p1_solo = m.spawn_layout_for("p1", "p1")
	v2i_eq(p1_solo["base"], declared_p1, "名单只有 p1 时，主阵营 p1 在它自己那一格")

	# 多玩家出生点互不重合、各自带防御阵地（第 1 轮联机的地基）
	var p1_layout = m.spawn_layout_for("p1", "p1")
	var p2_layout = m.spawn_layout_for("p2", "p1")
	ok(p2_layout["base"] != p1_layout["base"], "p2 的大本营与 p1 不重合")
	eq(p2_layout["spawns"].size(), 3, "p2 也是 3 个将领站位")
	ok((p2_layout["defenses"] as Array).size() > 0, "p2 自带防御阵地")
	for d in (p2_layout["defenses"] as Array):
		ok(m.terrain_walkable(int(d["x"]), int(d["y"])), "p2 的防御建筑落在可通行格上")
