## test_coop_catalog.gd —— 合作地图目录：扫 coop 关卡、地图路径 / 名称 / 描述。
extends "res://tests/test_case.gd"

const CoopCatalogRes = preload("res://logic/coop_catalog.gd")


func _initialize() -> void:
	_case_name = "test_coop_catalog"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	var entries := CoopCatalogRes.entries(cfg)
	ok(entries.size() >= 1, "★ 至少扫出一张合作地图（实际 %d）" % entries.size())
	var found := false
	for item in entries:
		var d: Dictionary = item
		ok(String(d.get("campaign", "")) != "", "条目带战役 id")
		ok(String(d.get("level", "")) != "", "条目带关卡 id")
		ok(String(d.get("level_name", "")) != "", "条目带关卡显示名")
		ok(String(d.get("map_id", "")) != "", "条目带地图 id")
		ok(String(d.get("map_path", "")).begins_with("res://data/maps/"), "地图路径在 data/maps 下")
		ok(FileAccess.file_exists(String(d.get("map_path", ""))), "地图文件存在")
		ok(String(d.get("map_name", "")) != "", "地图有显示名")
		ok(String(d.get("desc", "")) != "", "描述来自 briefing / summary")
		var m = CoopCatalogRes.load_map(String(d.get("map_path", "")), cfg)
		ok(m != null, "能载入 MapData（缩略图用）")
		if String(d.get("level", "")) == "02_twin_line":
			found = true
			eq(String(d.get("campaign", "")), "demo", "02_twin_line 在 demo 战役")
			eq(String(d.get("map_id", "")), "dongzheng", "02_twin_line 用 dongzheng 图")
	ok(found, "★ demo 的 02_twin_line 在目录里")

	var e := CoopCatalogRes.find_entry(entries, "demo", "02_twin_line")
	ok(not e.is_empty(), "find_entry 按 campaign/level 找到")
	ok(CoopCatalogRes.find_entry(entries, "demo", "不存在").is_empty(), "找不到 → 空字典")
