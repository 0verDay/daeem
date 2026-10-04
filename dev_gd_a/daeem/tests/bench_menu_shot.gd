## bench_menu_shot.gd —— 把进入界面渲染成 PNG（**只用于人工看样子**，不是断言）
##
## 为什么需要它：无头测试能钉住「底色是暗的 / 边框是金的 / 控件不吃鼠标」这类契约，
## 但钉不住「它好不好看」——那只能看一眼真实渲染出来的画面。
## 本脚本用真实渲染（不用 --headless）跑几帧，把入场页 / 主界面 / 战役页各存一张 PNG。
##
## 用法（在工程根下）：
##   <godot_console.exe> --path . --script res://tests/bench_menu_shot.gd
## 输出：`res://shots/*.png`（绝对路径会打在控制台里；看完可以直接删掉这个目录）
##
## ⚠️ 它**不参与** `tools/run-tests.ps1`：那个脚本只跑 `test_*.gd`，
##    而本文件按惯例叫 bench_*（与 bench_fps.gd / bench_crowd.gd 同类）。
## ⚠️ 必须用 **_console.exe** 跑：GUI 版会 detach，控制台拿不到输出（也没法知道成没成）。
## ⚠️ `--script` 模式下**没有** `_ready`：入口是 SceneTree 的 `_initialize()`（见 test_case.gd）。
extends SceneTree

const MainScene := preload("res://view/main.tscn")

## 存哪儿：`res://shots/`（看完随手删；不要提交）
const OUT_DIR := "res://shots"

## 每张图之前等几帧（Tween / 排版都要时间落定）
const SETTLE_FRAMES := 24


func _initialize() -> void:
	# ★ 脚本模式下 root 视口就是窗口尺寸（project.godot 里 1920×1080），
	#   这里再显式设一次，免得在别的窗口尺寸下跑出怪比例。
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	print("[SHOT] out dir = ", ProjectSettings.globalize_path(OUT_DIR))

	var main = MainScene.instantiate()
	root.add_child(main)
	await _wait(SETTLE_FRAMES)

	# 1) 入场页：等淡入与扫光跑完（这两个都是 Tween，太快截会拍到中间态）
	await _wait(80)
	await _shoot("01_intro")

	# 2) 主界面：点掉入场页
	main.start_screen.dismiss_intro()
	await _wait(SETTLE_FRAMES)
	await _shoot("02_menu")

	# 3) 单人战役占位页
	main._on_campaign_test_pressed()
	await _wait(SETTLE_FRAMES)
	await _shoot("03_campaign")

	# 4) ★ 对着一张**选定态**按钮也拍一张：战役页里「选中的那一关 / 那一方」是实心金底，
	#    它上面的字必须换成近黑 —— 这条只有看图才验得出（无头断言只能验颜色值）。
	var camp = main.campaign_screen
	if camp != null:
		var col = camp.get_node_or_null("CampaignRoot/CampaignCenter/CampaignColumn")
		if col != null:
			var fb = col.get_node_or_null("FactionBox/FactionButton0")
			if fb != null:
				print("[SHOT] faction0 font=", (fb as Button).get_theme_color("font_color"),
					" bg=", ((fb as Button).get_theme_stylebox("normal") as StyleBoxFlat).bg_color)
				# ★ 直接在**视口里**量那行字的像素：这是「看到的」而不是「设进去的」。
				await _wait(2)
				var li: Image = root.get_texture().get_image()
				var r: Rect2 = (fb as Control).get_global_rect()
				var darkest := Color(1, 1, 1)
				var brightest := Color(0, 0, 0)
				for dy in range(int(r.position.y), int(r.end.y), 2):
					for dx in range(int(r.position.x), int(r.end.x), 2):
						var p: Color = li.get_pixel(dx, dy)
						if p.get_luminance() < darkest.get_luminance():
							darkest = p
						if p.get_luminance() > brightest.get_luminance():
							brightest = p
				print("[SHOT] faction0 rect=", r, " darkest=", darkest, " brightest=", brightest)
			# ★★ 「金有没有把那行字糊掉」——**这张图最该看的一件事**（用户报过的那条 bug）。
			#    金上的字必须数得出「中性近黑」像素；只数暗像素是不够的
			#    （深色面板底也是暗的，见 pitfalls 5.59）。
			await _probe_text_on_fill(fb, "faction0_latched")
		await _shoot("04_campaign_selected")

	# 5) ★★ 回主界面，把鼠标「停」在 test 按钮上：那颗按钮会被金填满，
	#    而它上面那行字必须**还在**。⚠️ 这一步是无头测试**验不出来**的那一半
	#    （断言只能验「字色算得对不对」，验不了「谁盖谁」）—— 见 pitfalls 5.59。
	main._on_campaign_back()
	await _wait(SETTLE_FRAMES)
	var tb: Button = main.start_screen.find_child("TestButton", true, false)
	if tb != null:
		# 走引擎自己的信号（与玩家把鼠标停上去同一条路）
		tb.mouse_entered.emit()
		await _wait(40)                      # 填充 0.18s：40 帧足够走到满格
		await _probe_text_on_fill(tb, "menu_test_hover")
		await _shoot("05_menu_hover")
		tb.mouse_exited.emit()
		await _wait(10)

	print("[SHOT] done")
	quit(0)


## ★★ 数一颗按钮矩形里的三类像素：**金 / 中性近黑（= 金上的字）/ 深色面板底**。
##
## 判据：按钮被金填满时，`字` 这一栏**必须 > 0** —— 0 就是「金把字糊掉了」。
## ⚠️ 三类必须分开数：只按亮度分的话，深色面板底（偏蓝的 `bg_top`）与填充档的字
##   （中性暖黑）都会被算成「暗」，这条探针就什么都验不出来。
func _probe_text_on_fill(b: Button, tag: String) -> void:
	if b == null:
		print("[SHOT] %s: 没有这颗按钮" % tag)
		return
	await _wait(2)
	var img: Image = root.get_texture().get_image()
	if img == null:
		print("[SHOT] %s: 视口拿不到图像（是不是在用 --headless 跑？）" % tag)
		return
	var r: Rect2 = b.get_global_rect()
	var gold := 0
	var glyph := 0
	var panel := 0
	for dy in range(int(r.position.y), int(r.end.y)):
		for dx in range(int(r.position.x), int(r.end.x)):
			var p: Color = img.get_pixel(dx, dy)
			var lum := p.get_luminance()
			if p.r - p.b > 0.25 and p.r > 0.5:
				gold += 1
			elif lum < 0.3 and p.r >= p.b:
				glyph += 1
			elif lum < 0.3:
				panel += 1
	print("[SHOT] %s rect=%s 金=%d 字=%d 面板底=%d"
		% [tag, str(r), gold, glyph, panel])


func _wait(frames: int) -> void:
	for i in frames:
		await process_frame


func _shoot(shot_name: String) -> void:
	var img: Image = root.get_texture().get_image()
	if img == null:
		printerr("[SHOT] %s: 视口拿不到图像（是不是在用 --headless 跑？）" % shot_name)
		return
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	var err := img.save_png(path)
	print("[SHOT] %s -> %s (%dx%d) err=%d"
		% [shot_name, ProjectSettings.globalize_path(path),
			img.get_width(), img.get_height(), err])
