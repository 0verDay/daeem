## bench_menu_plate.gd —— 主菜单左侧那张雕版图的**扫描分帧截图**（只看样子，不是断言）。
##
## 用法（工程根下，必须 _console.exe，且**不要** --headless：它要真的画出来）：
##   <godot_console.exe> --path . --script res://tests/bench_menu_plate.gd
## 输出：`res://shots/plate/*.png`（看完可删；不参与 run-tests.ps1）。
extends SceneTree

const BgRes = preload("res://view/menu_background.gd")
const PlateRes = preload("res://view/menu_art/etched_plate.gd")
const ConfigRes = preload("res://logic/config.gd")
const OUT_DIR := "res://shots/plate"

const VIEW := Vector2(1280.0, 1080.0)

var bg = null
var plate = null


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	bg = BgRes.new()
	root.add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await _frames(2)

	plate = PlateRes.new()
	plate.setup(ConfigRes.load_default())
	root.add_child(plate)
	plate.position = Vector2.ZERO
	plate.size = VIEW
	plate.set_process(false)
	await _frames(2)

	var cfg = ConfigRes.load_default()
	var scan: float = cfg.num("menu.plate.scan_sec", 9.0)
	# ★ 按**扫描头的位置**取样而不是按时间：进菜单时相位已经偏了 start_frac，
	#   直接给秒数会拍到「扫描头已经出画」的那几帧（第一次拍就是这样）。
	var xs := [-0.06, 0.18, 0.42, 0.66, 0.90, 1.06]
	var names := ["00_enter", "01_scan_a", "02_scan_mid", "03_scan_b", "04_scan_end",
		"05_pause"]
	for i in xs.size():
		plate.set_time(plate.time_for_x(float(xs[i])))
		await _frames(3)
		_shoot("%s" % String(names[i]))
	print("[SHOT] done scan=%.1fs" % scan)
	quit(0)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _shoot(name: String) -> void:
	var img: Image = root.get_texture().get_image()
	if img == null:
		printerr("no image")
		return
	var path := "%s/%s.png" % [OUT_DIR, name]
	var err := img.save_png(path)
	print("[SHOT] ", ProjectSettings.globalize_path(path), " err=", err)
