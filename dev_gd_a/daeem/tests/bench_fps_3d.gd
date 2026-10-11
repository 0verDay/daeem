## bench_fps_3d.gd —— **3D 栈**的实机帧率基准（不是无头！）
##
## ★★ 为什么必须另起一份（而不是改 bench_fps.gd）：
##   老的 `bench_fps.gd` 加载 `view/game_scene.gd`（**2D 遗留栈**）——
##   实测在 100×100 地图 + 1000 单位下打出 **20096 draw call / 2567 MB 显存**
##   （2D 地形逐格画 1 万次）。那是 2D 栈的真实成绩，不该被改动，
##   所以 3D 的量尺另起一份，两者可以对着看。
##
## 用法（**没有** --headless）：
##   <mono Godot>_console.exe --path <工程> --script res://tests/bench_fps_3d.gd
## 环境变量：
##   DAEEM_FPS_UNITS   单位数（默认 1000）
##   DAEEM_FPS_FRAMES  统计帧数（默认 180）
##   DAEEM_HIDE        逗号分隔的层名（ground / fog / units / buildings），藏掉再量
##   DAEEM_PROFILE     默认开；设 `0` 关闭逐节剖析（用来证明剖析本身不改结论）
##
## ⚠️ 读数字的顺序（pitfalls 1.6）：先看 machine drift（>1.3 就作废），
##    再看长帧占比，最后才看平均。
##
## ★★ 本版修掉的一处**测量假象**（dev_plan_9 6.2 第 2 条，这一版落实）：
##   旧版把 `game` 挂进树（引擎每帧会调一次 `_process`），**又在循环里手动**
##   调 `game._process(1/60)` ⇒ 同一次 `_process` 每帧被跑两遍，
##   于是「其中 _process = X ms」与墙钟 `avg` 互相污染，`avg` 也不可信。
##   现在**不再手动调** `_process`：让引擎驱动，墙钟只量真实帧间隔；
##   分项则改由**被测场景内部**累计（`GameScene3D.profile_us` + `World.profile_us`）。
##
## ---------------------------------------------------------------------------
## 实测（本机，1000 单位 / 真实 3D 场景 / AI 开 / 1920×1080 / vsync off）
##
##   `_process`（逻辑 + 视图同步）= **22.90 → 17.02 ms/帧**（本轮三轮优化后；−26%）。
##
##   ⚠️⚠️ 墙钟 `avg` ≈ 38 ms，其中约 18 ms 是**引擎/呈现的固定开销**，与游戏无关：
##      实测「藏掉全部世界图层」（`DAEEM_HIDE=ground,fog,units,buildings`）avg **完全不变**
##      （39.23），而 1 单位时也有 ~12 ms。⇒ **本机的墙钟不能用来判 60fps**，
##      可动指标是 `_process` 与它下面的分项表。
##
##   分项（优化前 → 后，ms/帧）：
##     view/units      4.446 → 2.778   （三遍遍历合并成一遍 + 键记忆 + 选中为空时短路）
##     view/buildings  1.997 → 0.248   （复用单位层算好的可见格，不再自己扫一遍 + 迷雾）
##     fog             2.90  → 2.232   （refresh_needed 采集后 update 复用，不再同帧采两遍）
##     units           7.92  → 6.141   （含 units/combat 4.45→2.82、units/step 1.34→1.27）
##     collision       1.55  → 1.55
##
##   未做的下一步：units 循环本体（~1.9 ms，逐单位 GDScript 分支）。见 docs/route.md 第四十三节。
## ---------------------------------------------------------------------------
extends SceneTree

const Game3DRes = preload("res://view/game_scene3d.gd")
const UnitRes = preload("res://logic/unit.gd")
const FactionRes = preload("res://logic/faction.gd")

## 参考负载的落点（防被优化掉）
var _sink: float = 0.0


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
	var profile: bool = OS.get_environment("DAEEM_PROFILE") != "0"

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
	#    读法：把某一层藏掉之后墙钟 avg 掉下来的量 = 那一层的真实成本。
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
	# 打开剖析（默认开；`DAEEM_PROFILE=0` 关掉）。★ 关闭态用来验证「剖析本身不改结论」。
	if profile:
		game.profile_on = true
		game.profile_reset()
		game.world.profile_on = true
		game.world.profile_reset()
	# 预热（前几帧要建批次、烘第一张贴图 —— 那是**一次性**成本，不该算进平均值）
	for i in 30:
		await process_frame

	# ★★ 机器漂移校准（沙箱持续负载后会限频，同一进程里后跑的场景会偏悲观；
	#    见 pitfalls 1.6 / bench_crowd 的读法）。首尾各跑一次参考负载比对。
	var ref0: int = _calibrate()
	if profile:
		game.profile_reset()
		game.world.profile_reset()

	# ★★ 墙钟采样：**不手动调 `_process`**（引擎自己会调）。每帧只量「两帧之间」。
	var samples: Array = []
	var prev: int = Time.get_ticks_usec()
	for i in frames:
		await process_frame
		var now: int = Time.get_ticks_usec()
		samples.append(float(now - prev) / 1000.0)
		prev = now
	var total: float = 0.0
	for s in samples:
		total += s
	var ref1: int = _calibrate()
	samples.sort()
	var avg: float = total / float(frames)
	var p50: float = samples[frames / 2]
	var p95: float = samples[int(float(frames) * 0.95)]
	print("[3D] units=%d frames=%d  window=%s  vsync=off"
		% [units, frames, str(DisplayServer.window_get_size())])
	print("[3D] machine drift: ref %d us -> %d us (x%.2f)%s"
		% [ref0, ref1, float(ref1) / maxf(1.0, float(ref0)),
			"  WARN: >1.3，本次测量作废" if float(ref1) > float(ref0) * 1.3 else ""])
	print("[3D] avg %.2f ms  p50 %.2f  p95 %.2f  max %.2f"
		% [avg, p50, p95, samples[frames - 1]])
	print("[3D] => %.1f fps (avg)   %.1f fps (p95)" % [1000.0 / maxf(0.01, avg),
		1000.0 / maxf(0.01, p95)])

	# ★★ 分项（剖析开时才有）：逻辑各段来自 world.profile_us，视图各段来自 game.profile_us。
	if profile:
		var game_sum: float = _print_profile("GameScene3D._process 分段（视图侧）", game.profile_us, frames)
		_print_profile("world.tick 分段（逻辑侧）", game.world.profile_us, frames)
		print("[3D] _process 分段合计 %.2f ms/帧（墙钟 avg %.2f；差 = 渲染提交 + 呈现 + 等待）"
			% [game_sum, avg])
	# ★★ 优化是否真的生效，靠这几个计数器判断（而不是靠推理）：
	print("[3D] 单位实例写入/帧 = %d（实例 %d；差得多 = 脏检查生效）"
		% [game.units.instance_writes_last_frame, game.units.instance_count])
	print("[3D] draw calls/frame=%d  objects=%d  video mem=%.1f MB"
		% [Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0])
	# ★★ 合批证据：draw call 应当≈「地面 1 + 迷雾 1 + 单位批次数 + 建筑批次数」。
	print("[3D] units instance=%d batches=%d   buildings instance=%d batches=%d"
		% [game.units.instance_count, game.units.mesh_batch_count,
			game.buildings.instance_count, game.buildings.mesh_batch_count])
	print("[3D] ground bakes=%d   fog bakes=%d" % [game.ground.bake_count, game.ground.fog_bake_count])
	quit(0)


## 打印一张「节 → ms/帧」表（按占比降序），返回合计 ms/帧
func _print_profile(title: String, us: Dictionary, frames: int) -> float:
	if us.is_empty():
		print("[3D] %s：（无数据）" % title)
		return 0.0
	var keys: Array = us.keys()
	keys.sort_custom(func(a, b): return int(us[a]) > int(us[b]))
	var sum_ms: float = 0.0
	print("[3D] %s：ms/帧（降序）" % title)
	for k in keys:
		var ms: float = float(int(us[k])) / 1000.0 / float(frames)
		sum_ms += ms
		print("[3D]   %-16s %8.3f" % [String(k), ms])
	return sum_ms


## 固定参考负载：返回耗时微秒。用来判「同一进程里机器有没有被限频」。
func _calibrate() -> int:
	var t0: int = Time.get_ticks_usec()
	var acc: float = 0.0
	for i in 300000:
		acc += sqrt(float(i))
	_sink = acc
	return Time.get_ticks_usec() - t0


func _wait(frames: int) -> void:
	for i in frames:
		await process_frame
