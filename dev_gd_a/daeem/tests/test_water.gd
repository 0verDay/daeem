## test_water.gd —— 水域地形：挡移动、**不挡视线**、不会被连通性修正改成山。
##
## 不截图：直接验 `MapData` 的通行性 / 掩码 / 孤岛修正。
extends "res://tests/test_case.gd"

const MapDataRes = preload("res://logic/map_data.gd")

const MAP_PATH := "user://test_water_map.json"


func _initialize() -> void:
	_case_name = "test_water"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return

	# 3 行 × 7 列：中间一列水，但最下面一行留通道 ⇒ 所有陆地仍然连通。
	#   这样 `_seal_unreachable()` 不会把水改成山（那正是本次最容易踩的坑）。
	var map := {
		"cols": 7,
		"rows": 3,
		"layout": [
			"..~....",
			"..~....",
			".......",
		],
		"faction_bases": {"p1": [0, 1]},
	}
	var f := FileAccess.open(MAP_PATH, FileAccess.WRITE)
	ok(f != null, "（前提）能写临时地图")
	if f == null:
		return
	f.store_string(JSON.stringify(map))
	f.close()

	var m = MapDataRes.load_from(MAP_PATH, cfg)
	ok(m != null, "★ 带水域的地图能载入")
	if m == null:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(MAP_PATH))
		return

	eq(String(m.terrain.get_cell(2, 1)), MapDataRes.TERRAIN_WATER, "★ '~' 解析成 water")
	eq(String(m.terrain.get_cell(0, 0)), MapDataRes.TERRAIN_GRASS, "草地仍然是草地")

	ok(not m.terrain_walkable(2, 1), "★ 水域不可通行")
	ok(not m.terrain_walkable(2, 0), "★ 水域（上面那格）也不可通行")
	ok(m.terrain_walkable(2, 2), "水下面的通道可以走")
	ok(m.terrain_walkable(0, 1), "出生点可以走")

	ok(m.is_water(2, 1), "★ is_water() 认出水域")
	ok(not m.is_water(0, 0), "草地不是水")
	ok(not m.is_mountain(2, 1), "★★ 水域**不是**山 —— 战争迷雾的视线不会被水挡住")
	ok(not m.is_forest(2, 1), "水域不是森林")

	# 水在 BFS 里不可穿越；但陆地绕得过去 ⇒ 不应该有孤岛被封闭。
	eq(m.sealed_islands, 0, "★ 水没有把地图切断（没有孤岛被封成山）")
	eq(String(m.terrain.get_cell(2, 1)), MapDataRes.TERRAIN_WATER,
		"★★ 连通性修正之后水仍然是水（没有被改成山）")

	var reach: Dictionary = m.flood_fill_terrain(Vector2i(0, 1))
	ok(not reach.has(m.terrain.idx(2, 1)), "洪水填充不穿过水域")
	ok(reach.has(m.terrain.idx(2, 2)), "水下面的通道在可达集合里")
	ok(reach.has(m.terrain.idx(6, 1)), "绕过去之后右岸也可达")

	var near_tile: Vector2i = m.nearest_walkable(2, 1, 4)
	ok(near_tile.x >= 0, "水域附近能找到可通行格")
	ok(m.terrain_walkable(near_tile.x, near_tile.y), "最近的落点真的可通行")

	# 手改地形之后掩码必须同步（与森林 / 山地同一条规矩）。
	m.terrain.set_cell(2, 1, MapDataRes.TERRAIN_GRASS)
	m.rebuild_terrain_masks()
	ok(not m.is_water(2, 1), "重建掩码后不再是水")
	ok(m.terrain_walkable(2, 1), "改成草地之后可以走")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(MAP_PATH))
