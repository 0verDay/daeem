extends "res://tests/test_case.gd"
const MapDataRes = preload("res://logic/map_data.gd")
const WorldRes = preload("res://logic/world.gd")
const BuildingRes = preload("res://logic/building.gd")

var _w = null


func _initialize() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	var m = MapDataRes.load_from("res://data/test_map.json", cfg)
	_w = WorldRes.new()
	_w.cfg = cfg
	_w.map = m
	# 用轮询代替回调：reset 后每次看建筑表的变化
	_w.reset("p1", ["p1", "p2"])
	print("reset 之后 p1 的 base = ", _w.find_base_of("p1"))
	print("现在调一次 refresh_ownership()，看它会不会动建筑：")
	var n_before = _w.building_list.size()
	_w.refresh_ownership()
	print("   建筑数 ", n_before, " -> ", _w.building_list.size())
	for b in _w.building_list:
		print("   ", b.type, " owner=", b.owner, " at ", b.tx, ",", b.ty)
	print("p1 base 现在 = ", _w.find_base_of("p1"))
	print("DONE")
