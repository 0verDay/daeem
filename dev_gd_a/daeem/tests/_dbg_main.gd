## 一次性探针：test_view 里 main.world 到底是有效属性还是报错返回 null。用完即删。
extends SceneTree


func _initialize() -> void:
	await _probe()
	quit(0)


func _probe() -> void:
	var packed = load("res://view/main.tscn")
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	print("main script=", main.get_script().resource_path if main.get_script() != null else "null")
	print("main.has_method(get_world)=", main.has_method("get_world"))
	print("main.get('world')=", main.get("world"))
	var direct = main.world
	print("main.world（点号访问）=", direct)
	print("main.game=", main.game)
