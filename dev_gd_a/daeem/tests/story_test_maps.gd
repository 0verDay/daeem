## story_test_maps.gd —— 演出换图测试用的临时地图生成 / 清理（被 test_*.gd preload）。
##
## 6×6 → 8×8 的「可扩展地图」：旧区域逐格一致，新区域右侧 / 下侧各加一区。
## `bad` 图在旧区域放一座山，用来验证「旧区域地形不一致 → 拒绝换图」。
extends RefCounted

const TMP_DIR := "res://.tmp_story_map_expand"


static func prepare(dir: String = TMP_DIR) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	write_map(dir + "/small.json", 6, 6, false)
	write_map(dir + "/big.json", 8, 8, false)
	write_map(dir + "/smaller.json", 5, 5, false)
	write_map(dir + "/bad.json", 8, 8, true)


static func cleanup(dir: String = TMP_DIR) -> void:
	for name in ["small.json", "big.json", "smaller.json", "bad.json"]:
		var p := ProjectSettings.globalize_path(dir + "/" + name)
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	var d := ProjectSettings.globalize_path(dir)
	if DirAccess.dir_exists_absolute(d):
		DirAccess.remove_absolute(d)


static func write_map(path: String, cols: int, rows: int, bad: bool) -> void:
	var layout: Array = []
	for y in rows:
		var row := ""
		for x in cols:
			if bad and x == 2 and y == 2 and x < 6 and y < 6:
				row += "#"
			else:
				row += "."
		layout.append(row)

	var zones: Array = []
	for y in rows:
		var row: Array = []
		for x in cols:
			if x < 6 and y < 6:
				var zx := 0 if x < 3 else 1
				var zy := 0 if y < 3 else 2
				row.append(zx + zy)
			elif x >= 6:
				row.append(4)
			else:
				row.append(5)
		zones.append(row)

	var zone_list: Array = [
		{"id": 0, "name": "NW", "kind": "food", "center": [1, 1]},
		{"id": 1, "name": "NE", "kind": "gold", "center": [4, 1]},
		{"id": 2, "name": "SW", "kind": "population", "center": [1, 4]},
		{"id": 3, "name": "SE", "kind": "population", "center": [4, 4]},
	]
	if cols > 6:
		zone_list.append({"id": 4, "name": "E", "kind": "gold", "center": [7, 1]})
	if rows > 6:
		zone_list.append({"id": 5, "name": "S", "kind": "food", "center": [2, 7]})

	var data := {
		"id": path.get_file().get_basename(),
		"name": "story expand test",
		"cols": cols,
		"rows": rows,
		"layout": layout,
		"zones": zones,
		"zone_list": zone_list,
		"factions": [{"id": "p1", "name": "p1", "color": "#5AC8FF"}],
		"faction_bases": {"p1": [0, 5]},
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data))
		f.close()
