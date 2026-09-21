## test_map_editor.gd —— 地图编辑器导出的地图（exists / zones 网格）
##
## 地图编辑器（dev_gd_a/tools/map_editor，Python）导出的是「老板地图 + 两张网格」：
##   · exists —— 1 = 这个地块存在，0 = 地图外（虚线格）→ **一律不可通行**
##   · zones  —— 每格一个区块 id（-1 = 不属于任何区块）→ zone 直接读它，不再均分
##
## 这个文件测的是**游戏侧**读这两张网格的行为（Python 侧自己有一套无头测试）：
##   1. 老地图（没有这两个字段）行为一字不变 —— 存在 = 全部、区块 = 6×4 均分
##   2. 地图外的格子：不可通行、不会被连通性修正塞成山、寻路绕开它
##   3. zones 网格：区块按网格划分（可非矩形）、名字从 zone_list 来、空区块也保留
##   4. exists 的几种写法（二维数组 / 字符串行 / 扁平数组）都认
##
## ⚠️ 测试地图写在 user:// 下（无头模式下也能写），不往 res:// 里塞临时文件。
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const MapDataRes = preload("res://logic/map_data.gd")
const ZoneRes = preload("res://logic/zone.gd")
const WorldRes = preload("res://logic/world.gd")

## ⚠️ 测试地图写在工程里的一个临时目录下（跑完就删）。不用 user://：
##    某些沙箱 / CI 环境下 user:// 不可写，会变成「测试自己写不出文件」的假失败。
const TMP_DIR := "res://.tmp_test_map_editor"


func _initialize() -> void:
	_case_name = "test_map_editor"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	DirAccess.make_dir_recursive_absolute(TMP_DIR)

	_test_legacy_unchanged(cfg)
	_test_exists_defaults(cfg)
	_test_exists_forms(cfg)
	_test_missing_tile_blocks(cfg)
	_test_zones_grid(cfg)
	_test_empty_zone_kept(cfg)
	_test_faction_bases(cfg)
	_test_world_with_editor_map(cfg)
	_test_real_test_map(cfg)

	_cleanup()


# ------------------------------------------------------------------
# 8. 仓库里那张真地图（data/test_map.json）能开一局
# ------------------------------------------------------------------
##
## 前面那些用例都在 `user://` 里现场写小地图；这一条专门盯**盘上那张真图** ——
## 它是手画 + 编辑器反复编辑出来的，最容易带上「字段齐了但组合起来不能用」的问题
## （比如大本营落在山里、阵营 id 打错、区块网格和 exists 对不上）。
##
## 顺带一提：这里只**读**它，不改也不写回（测试不该动仓库里的文件）。
func _test_real_test_map(cfg) -> void:
	var path := "res://data/test_map.json"
	if not FileAccess.file_exists(path):
		ok(false, "仓库里有 %s" % path)
		return
	var m = MapDataRes.load_from(path, cfg)
	ok(m != null, "★ 仓库里的 test_map.json 能载入")
	if m == null:
		return
	ok(m.cols > 0 and m.rows > 0, "它有尺寸：%d×%d" % [m.cols, m.rows])
	ok(m.faction_bases.size() >= 1, "它带 faction_bases（%d 个阵营）" % m.faction_bases.size())

	# 每个阵营的大本营都得落在地图里、而且站得住
	for fid in m.faction_bases.keys():
		var b: Vector2i = m.faction_bases[fid]
		ok(m.tile_exists(b.x, b.y), "「%s」的大本营落在存在的格子上 %s" % [fid, str(b)])
		ok(m.terrain_walkable(b.x, b.y), "「%s」的大本营站得住（不是山/城墙）" % fid)

	# 真的开一局。⚠️ World.create() 走的是**单机名单**（只有 "p1"），
	#    所以这一局只该立起 player 一方的基地 —— p1/p2 的大本营这时用不到
	#    （它们在联机名单里才生效，下面单独验）。
	var w = WorldRes.create(cfg, path)
	ok(w != null, "★ 用仓库里的 test_map.json 能开出完整一局")
	if w == null:
		return
	var want_player: Vector2i = m.faction_bases["p1"]
	var got_player: Vector2i = w.home_base_of("p1")
	var dist := maxi(absi(got_player.x - want_player.x), absi(got_player.y - want_player.y))
	ok(dist <= 2, "★ player 的基地起在指定点附近（指定 %s，实际 %s）"
		% [str(want_player), str(got_player)])
	ok(w.find_base_of("p1") != null, "player 的基地真的立起来了（TYPE_BASE 建筑在）")
	ok(w.unit_by_id("general-1") != null, "将领正常生成了")
	# 区块数**以地图自己说的为准**（别写死：设计师往图里加一个区就会让这条假失败）
	eq(w.zones.zones.size(), m.zones_names.size(),
		"地图里声明的 %d 个区块都进了世界" % m.zones_names.size())
	ok(w.zones.zones.size() >= 10, "这张图至少有 10 个区块（实际 %d）" % w.zones.zones.size())
	var names: Array = []
	for z in w.zones.zones:
		names.append(String(z["name"]))
	ok("a1" in names and "c1" in names, "区块名（a1 / c1）读对了")

	# 联机名单里 p1 / p2 都在 → 两方各按地图指定的那一格建基地
	var w2 = WorldRes.new()
	w2.cfg = cfg
	w2.map = m
	w2.reset("p1", ["p1", "p2"])
	for fid in ["p1", "p2"]:
		var want: Vector2i = m.faction_bases[fid]
		var got: Vector2i = w2.home_base_of(fid)
		var d2 := maxi(absi(got.x - want.x), absi(got.y - want.y))
		ok(d2 <= 2, "★ 联机名单里的「%s」也按地图指定的点建基地（指定 %s，实际 %s）"
			% [fid, str(want), str(got)])
	ok(w2.find_base_of("p1") != null and w2.find_base_of("p2") != null,
		"★ 两方的基地都真的立起来了（不是只有一方）")


# ------------------------------------------------------------------
# 阵营大本营（地图编辑器「阵营」页签划出来的 faction_bases）
# ------------------------------------------------------------------
##
## 这一条要钉住的就一件事：**老地图（没有 faction_bases）的行为一字不变**，
## 而带 faction_bases 的地图按它建房 —— 两边都不能错。
func _test_faction_bases(cfg) -> void:
	# ---- 1. 老地图（**自己拼一张**：只有 layout + 旧格式的 base）：
	#         空 faction_bases → 走原来的兜底规则
	# ★ 不读 map_01.json：它已经搬到新格式了（有 faction_bases），当不了「老地图」样本。
	var legacy = MapDataRes.load_from(_write_map("legacy_for_factions.json", {
		"cols": 24, "rows": 16,
		"layout": _flat_layout(24, 16),
		"base": [12, 8],
		"pvp_points": [[12, 14]],
	}), cfg)
	ok(legacy != null, "老地图能载入")
	if legacy == null:
		return
	eq(legacy.faction_bases.size(), 0, "★ 老地图没有 faction_bases（空字典）")
	eq(legacy.factions_meta.size(), 0, "老地图也没有 factions 元数据")
	v2i_eq(legacy.spawn_layout_for("p1", "p1")["base"], Vector2i(12, 8),
		"★ 没有 faction_bases 时，player 仍然用地图里写的那个 base（老行为）")
	var legacy_p2: Dictionary = legacy.spawn_layout_for("p2", "p1")
	ok(legacy_p2["base"] != Vector2i(12, 8),
		"★ 没有 faction_bases 时，p2 仍然从 pvp_points 取点（老行为，不会跟玩家重合）")

	# ---- 2. 编辑器导出的地图：每一方按自己那一格建房
	var path := _write_map("faction_bases.json", {
		"cols": 12, "rows": 8,
		"layout": [
			"............", "............", "............", "............",
			"............", "............", "............", "............",
		],
		"faction_bases": {"p1": [1, 1], "p2": [10, 6]},
		"factions": [{"id": "p1", "name": "玩家", "color": "#FFD166"}],
		"base": [6, 4],
	})
	var m = MapDataRes.load_from(path, cfg)
	if m == null:
		ok(false, "带 faction_bases 的地图能载入")
		return
	eq(m.faction_bases.size(), 2, "★ 两方的大本营都读进来了")
	v2i_eq(m.faction_bases["p1"], Vector2i(1, 1), "player 的大本营读对了")
	v2i_eq(m.faction_bases["p2"], Vector2i(10, 6), "p2 的大本营读对了")
	eq(m.factions_meta.size(), 1, "阵营元数据也进来了（给 UI 用）")

	v2i_eq(m.spawn_layout_for("p1", "p1")["base"], Vector2i(1, 1),
		"★ player 用地图指定的那一格，**不再**用中心 base")
	v2i_eq(m.spawn_layout_for("p2", "p1")["base"], Vector2i(10, 6),
		"★ p2 也用地图指定的那一格（不再走 pvp_points）")
	eq(m.spawn_layout_for("p2", "p1")["spawns"].size(), 3, "指定大本营的那一方也有 3 个将领站位")
	ok((m.spawn_layout_for("p2", "p1")["defenses"] as Array).size() > 0,
		"指定大本营的那一方自带防御阵地（与 pvp_points 那条路一致）")

	# 只给了 player 的大本营时：p2 仍然退回老规则（互不影响）
	var path2 := _write_map("faction_bases_partial.json", {
		"cols": 12, "rows": 8,
		"layout": [
			"............", "............", "............", "............",
			"............", "............", "............", "............",
		],
		"faction_bases": {"p1": [2, 2]},
		"pvp_points": [[9, 1]],
	})
	var m2 = MapDataRes.load_from(path2, cfg)
	if m2 == null:
		ok(false, "只给一方的大本营也能载入")
		return
	v2i_eq(m2.spawn_layout_for("p1", "p1")["base"], Vector2i(2, 2),
		"player 用指定的那一格")
	v2i_eq(m2.spawn_layout_for("p2", "p1")["base"], Vector2i(9, 1),
		"★ 没指定的那一方仍然走 pvp_points（一条一条独立）")

	# ---- 3. 大本营落在山地上 → 就近换一个能站的格子（不崩、不塞进山里）
	var path3 := _write_map("faction_bases_mountain.json", {
		"cols": 12, "rows": 8,
		"layout": [
			"............", "............", "............", "............",
			".....#......", "............", "............", "............",
		],
		"faction_bases": {"p1": [5, 4]},
	})
	var m3 = MapDataRes.load_from(path3, cfg)
	if m3 == null:
		ok(false, "大本营在山上也能载入")
		return
	var b3: Vector2i = m3.spawn_layout_for("p1", "p1")["base"]
	ok(m3.terrain_walkable(b3.x, b3.y),
		"★ 大本营被放在山上时会就近换到可通行的格子（%s）" % str(b3))

	# ---- 4. 越界的大本营：丢掉，不崩
	var path4 := _write_map("faction_bases_oob.json", {
		"cols": 12, "rows": 8,
		"layout": [
			"............", "............", "............", "............",
			"............", "............", "............", "............",
		],
		"faction_bases": {"p1": [99, 99]},
	})
	var m4 = MapDataRes.load_from(path4, cfg)
	if m4 == null:
		ok(false, "越界大本营的地图也能载入")
		return
	eq(m4.faction_bases.size(), 0, "★ 越界的大本营被丢掉（不会让游戏去找图外的格子）")
	v2i_eq(m4.spawn_layout_for("p1", "p1")["base"], Vector2i(6, 4),
		"★ 丢掉之后退回地图中心的 base")


# ------------------------------------------------------------------
# 1. 老地图：没有 exists / zones 时行为一字不变
# ------------------------------------------------------------------
func _test_legacy_unchanged(cfg) -> void:
	# ★★ 这里**故意自己拼一张「老地图」**（而不是读 map_01.json）：
	#    随游戏发布的那张图已经被搬到新格式了（有 zones / zone_centers / faction_bases），
	#    而这一节要钉的恰恰是「**没有**那些字段时行为一字不变」。
	#    老地图长什么样：只有 cols/rows/layout（+ 那个已废弃的 base），没有 exists /
	#    zones / zone_list / zone_centers / factions / faction_bases。
	var path := _write_map("legacy_plain.json", {
		"cols": 24, "rows": 16,
		"layout": _flat_layout(24, 16),
		"base": [12, 8],
	})
	var m = MapDataRes.load_from(path, cfg)
	ok(m != null, "老地图（只有 layout）能载入")
	if m == null:
		return
	eq(m.cols, 24, "老地图 cols")
	eq(m.rows, 16, "老地图 rows")
	ok(m.exists != null, "老地图也会建出 exists 网格（全部为存在）")
	var all_true := true
	for y in m.rows:
		for x in m.cols:
			if not m.tile_exists(x, y):
				all_true = false
	ok(all_true, "老地图：所有地块都存在（没有 exists 字段 = 处处存在）")
	ok(m.zones_grid.is_empty(), "老地图没有 zones 网格")
	eq(m.zones_names.size(), 0, "老地图没有区块名字表")
	ok(m.zones_centers.is_empty(), "★ 老地图没有区划中心（不会凭空立起障碍）")
	ok(m.factions_meta.is_empty(), "★ 老地图没有 factions 元数据")

	var zs = ZoneRes.build_from_map(m, cfg, ["p1"])
	eq(zs.zones.size(), 24, "★ 老地图的区块仍然是 6×4 均分 = 24 块")
	eq(String(zs.zones[0]["name"]), "A1", "老地图第一块仍然叫 A1")
	eq(int(zs.zones[0]["tile_count"]), 16, "老地图每块仍然 16 格")
	eq(zs.lookup[m.terrain.idx(5, 4)], 7, "老地图的 lookup 与老实现一致（(5,4) → 行块 1、列块 1 → id 7）")


## 生成一整片草地的 layout（24×16 的老地图形状）
func _flat_layout(cols: int, rows: int) -> Array:
	var out: Array = []
	for i in rows:
		out.append(".".repeat(cols))
	return out


# ------------------------------------------------------------------
# 2. 没有 exists 字段 = 全部存在
# ------------------------------------------------------------------
func _test_exists_defaults(cfg) -> void:
	var path := _write_map("no_exists.json", {
		"cols": 4, "rows": 3,
		"layout": [".#..", ".^^.", "...."],
		"base": [0, 0],
	})
	var m = MapDataRes.load_from(path, cfg)
	ok(m != null, "没有 exists 的地图能载入")
	if m == null:
		return
	ok(m.tile_exists(0, 0) and m.tile_exists(3, 2), "缺省时所有格子都存在")
	ok(m.tile_exists(1, 1) and m.tile_exists(2, 1), "森林格子也存在（存在与否只看 exists，与地形无关）")
	ok(m.terrain_walkable(0, 0), "缺省时草地可通行")
	ok(not m.terrain_walkable(1, 0), "山不可通行")
	ok(m.terrain_walkable(2, 1), "森林可通行（只有山与地图外不可通行）")


# ------------------------------------------------------------------
# 3. exists 的几种写法
# ------------------------------------------------------------------
func _test_exists_forms(cfg) -> void:
	# 二维数组（编辑器导出的形式）
	var a := _write_map("exists_2d.json", {
		"cols": 3, "rows": 2,
		"layout": ["...", "..."],
		"exists": [[1, 1, 0], [0, 1, 1]],
		"base": [1, 0],
	})
	var ma = MapDataRes.load_from(a, cfg)
	ok(ma != null, "exists 二维数组能载入")
	if ma != null:
		ok(ma.tile_exists(1, 0), "二维数组：存在的格子")
		ok(not ma.tile_exists(2, 0), "二维数组：地图外的格子")
		ok(not ma.tile_exists(0, 1), "二维数组：第二行第一个是地图外")
		ok(ma.tile_exists(2, 1), "二维数组：第二行最后一个是存在")

	# 字符串行
	var b := _write_map("exists_str.json", {
		"cols": 3, "rows": 2,
		"layout": ["...", "..."],
		"exists": ["110", "011"],
		"base": [1, 0],
	})
	var mb = MapDataRes.load_from(b, cfg)
	ok(mb != null, "exists 字符串行能载入")
	if mb != null:
		ok(not mb.tile_exists(2, 0), "字符串行：'0' = 地图外")
		ok(mb.tile_exists(2, 1), "字符串行：'1' = 存在")

	# 扁平数组 [1,1,0, 0,1,1] → 第 0 行 ("110")、第 1 行 ("011")
	var c := _write_map("exists_flat.json", {
		"cols": 3, "rows": 2,
		"layout": ["...", "..."],
		"exists": [1, 1, 0, 0, 1, 1],
		"base": [1, 0],
	})
	var mc = MapDataRes.load_from(c, cfg)
	ok(mc != null, "exists 扁平数组能载入")
	if mc != null:
		ok(mc.tile_exists(0, 0), "扁平数组：下标 0 = (0,0) 存在")
		ok(not mc.tile_exists(2, 0), "扁平数组：下标 2 = (2,0) 是地图外")
		ok(not mc.tile_exists(0, 1), "扁平数组：下标 3 = (0,1) 是地图外")
		ok(mc.tile_exists(2, 1), "扁平数组：下标 5 = (2,1) 存在")


# ------------------------------------------------------------------
# 4. 地图外的格子：不可通行、不被连通性修正动过、寻路绕开
# ------------------------------------------------------------------
func _test_missing_tile_blocks(cfg) -> void:
	# 3×3 里挖掉中间左边一格：地图外
	var path := _write_map("hole.json", {
		"cols": 3, "rows": 3,
		"layout": ["...", "...", "..."],
		"exists": [[1, 1, 1], [0, 1, 1], [1, 1, 1]],
		"base": [1, 1],
	})
	var m = MapDataRes.load_from(path, cfg)
	ok(m != null, "带洞的地图能载入")
	if m == null:
		return
	ok(not m.tile_exists(0, 1), "挖掉的那格不存在")
	ok(not m.terrain_walkable(0, 1), "★ 地图外不可通行")
	eq(String(m.terrain.get_cell(0, 1)), "grass", "★ 地图外不会被连通性修正塞成山（它本来就不是地形问题）")
	eq(m.sealed_islands, 0, "★ 连通性修正不会把地图外算成孤岛")
	ok(m.terrain_walkable(0, 0), "挨着洞的格子照样能走")
	ok(m.terrain_walkable(0, 2), "洞下面那格也能走")

	# 被地图外包住的孤岛：全部格子都存在，但左上角那格被山围死 → 应当被塞成山
	var path2 := _write_map("island.json", {
		"cols": 5, "rows": 5,
		"layout": [".....",
		           ".###.",
		           ".#.#.",
		           ".###.",
		           "....."],
		"base": [0, 0],
	})
	var m2 = MapDataRes.load_from(path2, cfg)
	if m2 != null:
		ok(String(m2.terrain.get_cell(2, 2)) == "mountain",
			"被山围死的孤岛格会被连通性修正封成山（老行为仍在）")
		ok(m2.sealed_islands > 0, "孤岛计数 > 0")


# ------------------------------------------------------------------
# 5. zones 网格
# ------------------------------------------------------------------
func _test_zones_grid(cfg) -> void:
	# 4×3，两块地：左上是 0 号（非矩形：L 形），剩下的是 1 号
	var path := _write_map("zones.json", {
		"cols": 4, "rows": 3,
		"layout": ["....", "....", "...."],
		"zones": [[0, 0, 1, 1],
		          [0, 1, 1, 1],
		          [1, 1, 1, 1]],
		"zone_list": [
			{"id": 0, "name": "东关", "tiles": [[0, 0], [1, 0], [0, 1]]},
			{"id": 1, "name": "江陵"},
		],
		"base": [3, 2],
	})
	var m = MapDataRes.load_from(path, cfg)
	ok(m != null, "带 zones 网格的地图能载入")
	if m == null:
		return
	eq(m.zones_grid.size(), 3, "zones 网格读进来了")
	eq(m.zones_names.size(), 2, "区块名字表读进来了")

	var zs = ZoneRes.build_from_map(m, cfg, ["p1"])
	eq(zs.zones.size(), 2, "★ 区块数量由网格决定（不再是 6×4 均分的 24）")
	eq(String(zs.zones[0]["name"]), "东关", "第一块叫「东关」（名字来自 zone_list）")
	eq(String(zs.zones[1]["name"]), "江陵", "第二块叫「江陵」")
	eq(int(zs.zones[0]["tile_count"]), 3, "★ 东关有 3 个地块（非矩形：L 形）")
	eq(int(zs.zones[1]["tile_count"]), 9, "江陵有 9 个地块")
	eq(int(zs.zones[0]["x0"]), 0, "东关的包围盒 x0")
	eq(int(zs.zones[0]["y0"]), 0, "东关的包围盒 y0")
	eq(int(zs.zones[0]["x1"]), 1, "东关的包围盒 x1（由地块算出来，不是均分）")
	eq(int(zs.zones[0]["y1"]), 1, "东关的包围盒 y1")

	ok(zs.zone_at(0, 0) != null and int(zs.zone_at(0, 0)["id"]) == 0, "(0,0) 属于东关")
	ok(zs.zone_at(2, 0) != null and int(zs.zone_at(2, 0)["id"]) == 1, "(2,0) 属于江陵")
	ok(zs.zone_at(0, 2) != null and int(zs.zone_at(0, 2)["id"]) == 1, "(0,2) 属于江陵")


# ------------------------------------------------------------------
# 6. -1 的地块不属于任何区块；空区块也要保留
# ------------------------------------------------------------------
func _test_empty_zone_kept(cfg) -> void:
	var path := _write_map("zones_empty.json", {
		"cols": 3, "rows": 2,
		"layout": ["...", "..."],
		"zones": [[-1, 0, 0],
		          [-1, 0, 0]],
		"zone_list": [
			{"id": 0, "name": "有地的"},
			{"id": 7, "name": "还没划地的"},
		],
		"base": [1, 0],
	})
	var m = MapDataRes.load_from(path, cfg)
	if m == null:
		ok(false, "带 -1 与空区块的地图能载入")
		return
	var zs = ZoneRes.build_from_map(m, cfg, ["p1"])
	eq(zs.zones.size(), 2, "★ 一个地块都没有的区块也会被建出来（id=7）")
	ok(zs.zone_at(0, 0) == null, "-1 的地块不属于任何区块")
	ok(zs.zone_at(0, 1) == null, "第二行的 -1 也不属于任何区块")
	eq(int(zs.zones[1]["tile_count"]), 0, "空区块的 tile_count = 0（不会抢资源）")
	ok(zs.zone_at(1, 0) != null, "划了地的那块正常")

	# 地块不属于任何区块时，区块系统不会把它算进任何一方
	eq(zs.owned_tile_count("p1"), 0, "开局谁的地块数都是 0")


# ------------------------------------------------------------------
# 7. 编辑器导出的地图能真的开局（world 能起来）
# ------------------------------------------------------------------
func _test_world_with_editor_map(cfg) -> void:
	var path := _write_map("playable.json", {
		"cols": 12, "rows": 8,
		"exists": [
			[0, 0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 0],
			[0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0],
			[0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0],
			[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
			[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
			[0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0],
			[0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0],
			[0, 0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 0],
		],
		"layout": [
			"....^^......",
			"...^^^^.....",
			"..^^^^^^....",
			"............",
			"............",
			"..^^^^^^^^..",
			"...^^^^^^...",
			"....^^......",
		],
		"zones": [
			[-1, -1, -1, 0, 0, 0, 0, 1, 1, -1, -1, -1],
			[-1, -1, 0, 0, 0, 0, 0, 1, 1, 1, -1, -1],
			[-1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, -1],
			[0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1],
			[0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1],
			[-1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, -1],
			[-1, -1, 0, 0, 0, 0, 0, 1, 1, 1, -1, -1],
			[-1, -1, -1, 0, 0, 0, 0, 1, 1, -1, -1, -1],
		],
		"zone_list": [
			# ★ 人口上限（编辑器导出 zone_list[].population_cap）：西境填了 7，
			#   东境**没填** → 游戏侧按默认 1 处理（用户需求：没填就是 1）
			{"id": 0, "name": "西境", "population_cap": 7},
			{"id": 1, "name": "东境"},
		],
		"base": [2, 3],
	})
	var m = MapDataRes.load_from(path, cfg)
	if m == null:
		ok(false, "可玩地图能载入")
		return
	eq(m.base, Vector2i(2, 3), "大本营点位读对了")
	ok(not m.tile_exists(0, 0), "角落是地图外（八边形地图）")
	ok(m.tile_exists(0, 3), "中间那行顶到了最左边")

	var w = WorldRes.create(cfg, path)
	ok(w != null, "★ 编辑器导出的地图能开出完整一局（world.create）")
	if w == null:
		return
	eq(w.zones.zones.size(), 2, "世界里是 2 个区块")
	eq(String(w.zones.zones[0]["name"]), "西境", "区块名进了世界")
	ok(w.unit_by_id("general-1") != null, "将领正常生成了")
	ok(w.faction_bases.has("p1"), "玩家大本营立起来了")
	var b: Vector2i = w.faction_bases["p1"]
	ok(m.tile_exists(b.x, b.y), "大本营落在存在的格子上（不会被塞进地图外）")
	ok(m.terrain_walkable(b.x, b.y), "大本营站得住（可通行）")

	# 地图外的格子不该被当成区块：它既不属于西境也不属于东境
	ok(w.zones.zone_at(0, 0) == null, "地图外的角落不属于任何区块")
	eq(w.zones.lookup[m.terrain.idx(0, 0)], -1, "lookup 对地图外是 -1")

	# ---- ★ 人口上限（用户需求：每个区块都要有，没填 = 1）
	var zw: Dictionary = w.zones.zones[0]
	var ze: Dictionary = w.zones.zones[1]
	eq(String(zw["name"]), "西境", "第 0 个区块是西境")
	near(w.zones.population_cap_of(zw), 7.0, 1e-9, "★ 地图里填的上限被读进世界（7）")
	near(w.zones.population_cap_of(ze), 1.0, 1e-9, "★ 没填的那一块按默认 1")
	# 世界真的按上限停涨：西境速率设成很大，跑一秒也只能到 7
	zw["production"] = {"food": 0.0, "gold": 0.0, "population": 100.0}
	w.tick(1.0)
	near(w.zones.population_of(zw), 7.0, 1e-6, "★ 人口涨到地图给的上限就停住")


# ------------------------------------------------------------------
# 工具
# ------------------------------------------------------------------

## 写一张测试地图到 user:// 下，返回 res:// 风格的路径（MapData 用 FileAccess 读，
## user:// 与 res:// 都认）。
func _write_map(file_name: String, data: Dictionary) -> String:
	var path := "%s/%s" % [TMP_DIR, file_name]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		ok(false, "测试地图写得出来：%s" % path)
		return path
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	return path


func _cleanup() -> void:
	var dir := DirAccess.open(TMP_DIR)
	if dir == null:
		return
	for name in dir.get_files():
		DirAccess.remove_absolute("%s/%s" % [TMP_DIR, name])
	dir.list_dir_begin()
	var sub := dir.get_next()
	while sub != "":
		if dir.current_is_dir() and sub != "." and sub != "..":
			DirAccess.remove_absolute("%s/%s" % [TMP_DIR, sub])
		sub = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(TMP_DIR)
