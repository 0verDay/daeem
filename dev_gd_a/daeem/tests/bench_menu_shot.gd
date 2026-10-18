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
	# ★ 现在「点一下」与「切到主界面」之间还有两段动画（logo 落位 → 面板滑入，
	#   见 view/start_screen.gd），所以要等它们跑完再拍，否则拍到的是动画中途。
	main.start_screen.dismiss_intro()
	await _wait_menu(main.start_screen)
	await _wait(SETTLE_FRAMES)
	await _shoot("02_menu")

	# 3) 战役菜单（左侧轮播 / 顶部关卡圆点 / 右侧描述 / 底部「长按进入关卡」）
	var chrome = main.start_screen.menu_chrome()
	var engine = chrome.expand_engine()
	# ★ 入场那一下的「面板滑入」也走这个引擎：它忙的时候 expand() 会被直接忽略 ——
	#   先等它闲下来，再按「战役」。
	var deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline and engine.is_busy():
		await process_frame
	(chrome.side_buttons()[0] as Button).pressed.emit()
	deadline = Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline and not engine.is_expanded():
		await process_frame
	# ★ 展开完成之后**二级面板还要淡入**（`menu_secondary_panel.attach()`，0.45s）——
	#   `--script` 下帧率不锁 60，按帧数等会拍到「刚开始淡入」的黑画面。
	await _wait_sec(0.7)
	await _shoot("03_campaign")

	# 4) ★ 翻到占位战役（战役#2）：关卡圆点变 4 个、描述换成「关卡#1」——
	#    这张图用来看「占位战役在界面上长什么样」。
	var cm = main.start_screen.campaign_menu()
	if cm != null:
		cm.carousel().select_campaign(1)
		await _wait_sec(0.3)
		await _shoot("04_campaign_placeholder")
	else:
		print("[SHOT] 战役菜单拿不到（面板没撑开？）—— 04 跳过")

	# 5) ★★ 回主界面，把鼠标「停」在 test_1 按钮上：那颗按钮会被金填满，
	#    而它上面那行字必须**还在**。⚠️ 这一步是无头测试**验不出来**的那一半
	#    （断言只能验「字色算得对不对」，验不了「谁盖谁」）—— 见 pitfalls 5.59。
	if engine.secondary_panel() != null:
		engine.secondary_panel().back_button().pressed.emit()
	# ★ 收回也是时间驱动的 Tween（`--script` 下帧率不锁 60，按帧数等会等不够）
	var close_deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < close_deadline and engine.is_busy():
		await process_frame
	await _wait(3)
	var buttons: Array = main.start_screen.test_buttons()
	var tb: Button = buttons[0] if not buttons.is_empty() else null
	if tb != null:
		# 走引擎自己的信号（与玩家把鼠标停上去同一条路）
		tb.mouse_entered.emit()
		# 填充 0.18s —— 同样按**时间**等，不按帧数
		var fill_deadline := Time.get_ticks_msec() + 600
		while Time.get_ticks_msec() < fill_deadline:
			await process_frame
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


## 按**时间**等（秒）：`--script` 下帧率不锁 60，Tween 是时间驱动的，按帧数等不够。
func _wait_sec(seconds: float) -> void:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


## 等入场那两段动画跑完：① logo 落位 → 切页 ② 外壳各面板滑入。
func _wait_menu(menu) -> void:
	var deadline: int = Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline and int(menu.page()) != 1:
		await process_frame
	var settle: int = Time.get_ticks_msec() \
		+ int((menu.cfg.num("menu.chrome.intro_sec", 0.55) + 0.3) * 1000.0)
	while Time.get_ticks_msec() < settle:
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
