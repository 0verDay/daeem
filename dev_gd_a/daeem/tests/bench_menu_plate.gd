## bench_menu_plate.gd —— 主菜单左侧**雕版轮播**的分帧截图（只看样子，不是断言）。
##
## 用法（工程根下，必须 _console.exe，且**不要** --headless：它要真的画出来）：
##   <godot_console.exe> --path . --script res://tests/bench_menu_plate.gd
## 输出：`res://shots/plate/*.png`（看完可删；不参与 run-tests.ps1）。
extends SceneTree

const BgRes = preload("res://view/menu_background.gd")
const CycleRes = preload("res://view/menu_art/plate_cycle.gd")
const ConfigRes = preload("res://logic/config.gd")
const OUT_DIR := "res://shots/plate"

const VIEW := Vector2(1280.0, 1080.0)

var bg = null
var cycle = null


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	bg = BgRes.new()
	root.add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await _frames(2)

	var cfg = ConfigRes.load_default()
	cycle = CycleRes.new()
	cycle.setup(cfg)
	root.add_child(cycle)
	cycle.position = Vector2.ZERO
	cycle.size = VIEW
	cycle.set_process(false)
	await _frames(2)

	# ★ 按**扫描头的位置**取样而不是按时间：改了时长 / 相位之后给秒数会拍到
	#   「扫描头已经出画」的那几帧（第一次拍就是这样）。
	var xs := [-0.06, 0.18, 0.42, 0.66, 0.90, 1.06]
	var names := ["00_enter", "01_scan_a", "02_scan_mid", "03_scan_b", "04_scan_end",
		"05_pause"]
	for i in xs.size():
		cycle.set_time(cycle.time_for_x(float(xs[i]), 0))
		await _frames(3)
		_shoot("p1_%s" % String(names[i]))

	# 第二张：同样按位置取样（它从自己那一档的起点开始扫）
	for i in xs.size():
		cycle.set_time(cycle.time_for_x(float(xs[i]), 1))
		await _frames(3)
		_shoot("p2_%s" % String(names[i]))

	# 跨张溶解的那两帧：前一张渐隐、后一张渐显
	var cyc: float = cycle.cycle_sec()
	var fade: float = ConfigRes.load_default().num("menu.plate.fade_sec", 0.8)
	for k in 3:
		cycle.set_time(cyc - fade * (1.0 - float(k) / 2.0))
		await _frames(3)
		_shoot("fade_%d" % k)
	print("[SHOT] done plates=%d cycle=%.2fs" % [cycle.plate_count(), cyc])
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
