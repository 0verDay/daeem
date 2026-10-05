## bench_fps_3d.gd —— **3D 栈**的实机帧率基准（不是无头！）
##
## ★★ 为什么必须另起一份（而不是改 bench_fps.gd）：
##   老的 `bench_fps.gd` 加载 `view/game_scene.gd`（**2D 遗留栈**）——
##   实测在 100×100 地图 + 1000 单位下打出 **20096 draw call / 2567 MB 显存**
##   （2D 地形逐格画 1 万次）。那是 2D 栈的真实成绩，不该被改动，
##   所以 3D 的量尺另起一份，两者可以对照着看。
##
## 用法（**没有** --headless）：
##   <mono Godot>_console.exe --path <工程> --script res://tests/bench_fps_3d.gd
## 环境变量：
##   DAEEM_FPS_UNITS   单位数（默认 1000）
##   DAEEM_FPS_FRAMES  统计帧数（默认 180）
##   DAEEM_FPS_MAP     地图边长（默认 100，方格 —— 与 2D 基准同一张图，便于对照）
##
## ⚠️ 读数字的顺序（pitfalls 1.6）：先看 machine drift（>1.3 就作废），
##    再看长帧占比，最后才看平均。
extends SceneTree

const Game3DRes = preload("res://view/game_scene3d.gd")
const UnitRes = preload("res://logic/unit.gd")
const FactionRes = preload("res://logic/faction.gd")


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	_run()


func _run() -> void:
	var game = Game3DRes.new()
	root.add_child(game)
	await _wait(2)
	if not game.start():
		printerr("[3D] 场景起不来")
		quit(1)
		return
	var world = game.world
	var units: int = int(OS.get_environment("DAEEM_FPS_UNITS")) if \
		OS.get_environment("DAEEM_FPS_UNITS") != "" else 1000
	var frames: int = int(OS.get_environment("DAEEM_FPS_FRAMES")) if \
		OS.get_environment("DAEEM_FPS_FRAMES") != "" else 180

	# 把单位摊到地图中部（像真实交战那样聚成一团，而不是散在整张图上）
	var placed := 0
	var f: String = world.my_faction
	# ⚠️ 显式标类型：`world` 是无类型引用 ⇒ `world.home_base_of()` 推不出类型，
	#    写 `var base := ...` 会直接 Parse Error（本轮第 6 次踩同类坑）。
	var base: Vector2i = world.home_base_of(f)
	var cx: float = float(base.x) + 6.0
	var cy: float = float(base.y) + 6.0
	while placed < units:
		var gx: float = cx + float(placed % 20) * 0.6
		var gy: float = cy + float(placed / 20) * 0.6
		var u = UnitRes.create(game.cfg, "bench-%d" % placed, "长枪兵",
			Vector2i(int(gx), int(gy)), f, "spearman")
		u.pos = Vector2(gx, gy)
		world.units.append(u)
		placed += 1
	game.units.sync()

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	# ★★ `DAEEM_HIDE`：逗号分隔的层名，把那一层藏掉再量 —— **定位固定渲染开销的唯一手段**。
	#    可用的层名：`ground`（地形平面）、`fog`（迷雾平面）、`units`、`buildings`。
	#    读法：把某一层藏掉之后 `其余（渲染提交+呈现）` 掉下来的量 = 那一层的真实成本。
	#    （老基准 `bench_fps.gd` 早就有了这个能力，本版补上。）
	var hidden: String = OS.get_environment("DAEEM_HIDE")
	if hidden != "":
		for nm in hidden.split(","):
			match nm.strip_edges():
				"ground":
					game.ground._mesh.visible = false
				"fog":
					game.ground._fog_mesh.visible = false
				"units":
					game.units.visible = false
				"buildings":
					game.buildings.visible = false
		print("[3D] 隐藏图层：%s" % hidden)
	# 预热（前几帧要建批次、烘第一张贴图 —— 那是**一次性**成本，不该算进平均值）
	for i in 30:
		await process_frame

	# ★★ 分项计时（本版新增）：光有「avg 42.9 ms」定位不了瓶颈。
	#    按「逻辑 / 单位同步 / 建筑同步 / 地面重烘 / 覆盖层 / 剩余（= 渲染提交）」
	#    各记一次，看谁是大头。用的是 `Time.get_ticks_usec()`（墙钟），
	#    与 2D 基准的读法一致（pitfalls 1.6）。
	var acc := {"logic": 0.0, "units": 0.0, "buildings": 0.0, "ground": 0.0, "rest": 0.0}
	var t0: int = Time.get_ticks_usec()
	var samples: Array = []
	for i in frames:
		var s: int = Time.get_ticks_usec()
		var a: int = Time.get_ticks_usec()
		game._process(1.0 / 60.0)          # 整帧主循环（与实机同一条路径）
		var b: int = Time.get_ticks_usec()
		acc["logic"] += float(b - a) / 1000.0
		await process_frame
		var e: int = Time.get_ticks_usec()
		samples.append(float(e - s) / 1000.0)
	var total: float = float(Time.get_ticks_usec() - t0) / 1000.0
	samples.sort()
	var avg: float = total / float(frames)
	var p50: float = samples[frames / 2]
	var p95: float = samples[int(float(frames) * 0.95)]
	print("[3D] units=%d frames=%d  window=%s  vsync=off"
		% [units, frames, str(DisplayServer.window_get_size())])
	print("[3D] avg %.2f ms  p50 %.2f  p95 %.2f  max %.2f"
		% [avg, p50, p95, samples[frames - 1]])
	print("[3D] => %.1f fps (avg)   %.1f fps (p95)" % [1000.0 / maxf(0.01, avg),
		1000.0 / maxf(0.01, p95)])
	# ★ 关键分项：`_process` 覆盖了逻辑 + 全部视图同步；剩下的就是渲染提交
	var tick_ms: float = acc["logic"] / float(frames)
	print("[3D] 其中：GameScene3D._process（逻辑+视图同步）= %.2f ms/帧" % tick_ms)
	print("[3D]     → 其余（渲染提交 + 呈现 + 等待）= %.2f ms/帧" % (avg - tick_ms))
	# ★★ 优化是否真的生效，靠这几个计数器判断（而不是靠推理）：
	#    · `instance_writes_last_frame` 远小于实例数 ⇒ 脏检查生效了；
	#    · `hidden_layers` 起作用时下面那行会打印出来的层名。
	print("[3D] 单位实例写入/帧 = %d（实例 %d；差得多 = 脏检查生效）"
		% [game.units.instance_writes_last_frame, game.units.instance_count])
	print("[3D] 地面重烘次数=%d  迷雾重烘次数=%d（节流生效时这两个数应当很小）"
		% [game.ground.bake_count, game.ground.fog_bake_count])
	print("[3D] draw calls/frame=%d  objects=%d  video mem=%.1f MB"
		% [Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0])
	# ★★ 合批证据：draw call 应当≈「地面 1 + 迷雾 1 + 单位批次数 + 建筑批次数」。
	#    超出很多就说明有东西在偷偷逐实例绘制（合批失效）。
	print("[3D] units instance=%d batches=%d   buildings instance=%d batches=%d"
		% [game.units.instance_count, game.units.mesh_batch_count,
			game.buildings.instance_count, game.buildings.mesh_batch_count])
	print("[3D] ground bakes=%d   fog bakes=%d" % [game.ground.bake_count, game.ground.fog_bake_count])
	quit(0)


func _wait(frames: int) -> void:
	for i in frames:
		await process_frame
