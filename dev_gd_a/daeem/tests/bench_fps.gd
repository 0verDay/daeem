## bench_fps.gd —— **实机帧率**基准（不是无头！）
##
## ★★ 为什么必须有它：前面所有优化都是在 `--headless` 下量的「逻辑耗时」，
##    而用户要的是「实机 60fps」—— 那还包含渲染与提交，无头模式量不到。
##    docs/pitfalls.md 里记过一条环境事实：**不带 `--headless`** 的 Godot 在本机沙箱里
##    能正常初始化渲染并跑满帧。所以这个脚本按「真实开窗跑」来写。
##
## 用法（注意：**没有** `--headless`）：
##   <mono Godot>_console.exe --path <工程> --script res://tests/bench_fps.gd
## 环境变量：
##   DAEEM_FPS_UNITS   单位数（默认 1000）
##   DAEEM_FPS_FRAMES  统计帧数（默认 240）
##   DAEEM_FPS_MODE    `am` = 行军攻击（路线上摆 60 个敌人），留空 = 普通群编移动
##   DAEEM_FPS_PROFILE `0` = 关剖析，量**真实**帧时间（默认 1，量分项）
##   DAEEM_HIDE        隐藏某个图层名（UnitView / ZoneView / …），用来定位固定渲染开销
##
## 它会：进游戏场景 → 摆 N 个单位 → 下一个群编移动命令 → 关掉垂直同步 → 跑帧 →
##       打印每帧耗时分布（avg/p50/p95/max）、帧分布直方图、逐项峰值、draw call 数，
##       以及**机器漂移倍率**（沙箱限频会让同一份代码越跑越慢，见 pitfalls 1.6 / 1.8）。
##
## ★★ 看数字的顺序（实测踩过：「avg 85 ms 而 p50 30 ms」这种形状下，平均分项会骗人）：
##   1. 先看 `machine drift`：>1.3 就作废，别下结论；
##   2. 再看 `frame buckets`：>120 ms 的帧占多少 —— 卡顿感来自这些帧，不是平均；
##   3. 再看 `per-frame PEAK by phase`：尖峰帧里**哪一项**爆了；
##   4. 最后才看 `logic phases` 的平均值。
##
## ⚠️ 关掉垂直同步是**故意的**：开着的话帧时间会被显示器刷新率钉在 16.7ms，
##    那样「有没有余量」根本看不出来。
extends SceneTree

const UnitRes = preload("res://logic/unit.gd")
const CombatRes = preload("res://logic/combat.gd")
const CommandRes = preload("res://logic/command_processor.gd")

const BLOCK_COLS := 32
const BLOCK_SPACING := 0.35
const BLOCK_ORIGIN := Vector2(14.0, 36.0)


func _initialize() -> void:
	await _run()
	quit(0)


func _run() -> void:
	var n_units := _env_int("DAEEM_FPS_UNITS", 1000)
	var n_frames := _env_int("DAEEM_FPS_FRAMES", 240)

	# 关垂直同步：否则帧时间被刷新率钉住，看不出余量
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	var packed = load("res://view/main.tscn")
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	# 走真实入口，但**用方案里的 100×100 地图**（默认那张 27×22 塞 1000 单位会密度失真）
	var map_path := _write_bench_map()
	main.game = null
	var game_scene = load("res://view/game_scene.gd").new()
	game_scene.name = "GameScene"
	main.add_child(game_scene)
	if not game_scene.start(map_path):
		printerr("[FPS] 游戏场景启动失败（地图 %s）" % map_path)
		return
	main.game = game_scene
	main.start_screen.close()
	await process_frame
	var game = main.game
	if game == null:
		printerr("[FPS] 进游戏失败：拿不到 GameScene")
		return

	var w = game.world
	var cfg = game.cfg
	# 【A/B 用】按环境变量隐藏某个图层，用来定位「固定渲染开销到底是谁的」
	var hide := OS.get_environment("DAEEM_HIDE")
	if hide != "":
		var node = game.get_node_or_null(hide)
		if node != null:
			node.visible = false
			print("[FPS]   隐藏图层：%s" % hide)
		else:
			print("[FPS]   找不到要隐藏的图层：%s" % hide)
	_place_units(w, cfg, n_units)
	# 摆完之后让视图重建一次
	await process_frame

	print("[FPS] DAEEM real-frame benchmark")
	print("[FPS]   units=%d frames=%d  window=%s  vsync=off"
		% [w.units.size(), n_frames, str(DisplayServer.window_get_size())])

	# 群编：所有单位走到一个远点（就是用户报卡顿的那个操作）
	# DAEEM_FPS_MODE=am 时改成「行军攻击」：路线上先摆一片敌人，再整队 A 过去。
	# ★ 为什么必须能测这个模式：行军攻击下每个单位在赶路时都要索敌、锁到目标之后
	#   每 repath_sec 秒还要重新寻路 —— 那是「普通移动」量不到的额外开销。
	var goal := Vector2(float(w.map.cols) * 0.72, float(w.map.rows) * 0.5)
	var mode := OS.get_environment("DAEEM_FPS_MODE")
	var kind := "move"
	if mode == "am":
		kind = "attack_move"
		# 敌人摆在方阵与目标之间（bench_fps 的方阵是**居中**的，所以 x 取 0.60 处）
		for i in 60:
			var col := i % 20
			var row := i / 20
			var e = UnitRes.create(cfg, "fps-foe-%d" % i, "foe %d" % i,
				Vector2i(0, 0), "enemy", UnitRes.KIND_ENEMY)
			e.pos = Vector2(float(w.map.cols) * 0.60 + float(col) * 0.35,
				float(w.map.rows) * 0.5 - 2.0 + float(row) * 0.35)
			e.sync_tile(w.map)
			w.units.append(e)
		print("[FPS]   mode=attack_move, foes=60")

	var ids: Array = []
	for u in w.units:
		if u.faction == w.my_faction:
			ids.append(u.id)
	var t_cmd := Time.get_ticks_usec()
	CommandRes.apply(w, cfg, {"kind": kind, "ids": ids, "faction": w.my_faction, "x": goal.x, "y": goal.y})
	var cmd_ms := float(Time.get_ticks_usec() - t_cmd) / 1000.0
	print("[FPS]   group order (%s, command frame): %.1f ms" % [kind, cmd_ms])

	# 先跑几帧热身（建表 / 节点重建 / 着色器编译都在这几帧里）
	for _i in 30:
		await process_frame

	# ★ 让 game_scene **照常**推进逻辑（不动控制流），
	#   逻辑耗时用 world 自带的剖析器取 —— 手动 tick 会改变帧内次序，数字就不可比了。
	#
	# ⚠️⚠️ 但剖析器本身**会改变被测对象**：profile_on = true 时逻辑走的是「插桩路径」
	#   （每单位多几次 Time.get_ticks_usec + profile_sub），而实机跑的是没插桩那条。
	#   实测踩过：行军攻击插桩下 combat 段 42 ms，把剖析关掉总帧时间反而大幅下降 ——
	#   也就是说那 42 ms 有一大块是**量具本身**。所以两个数必须都对：
	#   DAEEM_FPS_PROFILE=0 → 量真实帧时间（这个才是玩家感受到的）；
	#   =1（默认）→ 量分项，用来看「贵在哪」，但不能当成实机耗时。
	var want_profile := _env_flag("DAEEM_FPS_PROFILE", true)
	w.profile_on = want_profile
	w.profile_reset()
	CombatRes.repath_calls = 0
	UnitRes.move_to_calls = 0

	# 正式统计
	var ref0 := _calibrate()
	var samples: Array[float] = []
	var prev := Time.get_ticks_usec()
	# ★★ 逐帧增量：把「最慢那一帧」抓下来。
	#    实机行军攻击 avg 85 ms 而 p50 只有 30 ms —— 说明是**少数帧**极贵（同步爆发），
	#    光看平均值永远找不到它们。
	var worst_ms := -1.0
	# ★★ 每个分项的**逐帧最大增量**：平均分项会把尖峰摊平，
	#    只有「哪一项在尖峰帧里爆掉」才能定位问题（这一条直接找出了 mv/slot = 222 ms）。
	var peak: Dictionary = {}
	var prev_us: Dictionary = {}
	for _i in n_frames:
		await process_frame
		var now := Time.get_ticks_usec()
		var fms := float(now - prev) / 1000.0
		samples.append(fms)
		prev = now
		for k in w.profile_us.keys():
			var cur := int(w.profile_us[k])
			var d := cur - int(prev_us.get(k, 0))
			prev_us[k] = cur
			if d > int(peak.get(k, 0)):
				peak[k] = d
		if fms > worst_ms:
			worst_ms = fms
	var ref1 := _calibrate()

	samples.sort()
	var total := 0.0
	for s in samples:
		total += s
	var avg := total / float(samples.size())
	var logic_avg := 0.0
	for key in ["zones", "economy", "recruit", "units", "towers", "enemy_ai", "collect", "collision"]:
		logic_avg += float(int(w.profile_us.get(key, 0))) / 1000.0 / float(n_frames)
	var p50: float = samples[int(float(samples.size()) * 0.50)]
	var p95: float = samples[int(float(samples.size()) * 0.95)]
	var worst: float = samples[samples.size() - 1]

	print("[FPS] -- frame time (ms) over %d frames --" % samples.size())
	print("[FPS]   avg %7.2f   p50 %7.2f   p95 %7.2f   max %7.2f" % [avg, p50, p95, worst])
	print("[FPS]   其中逻辑（world.tick 各阶段和）%7.2f ms" % logic_avg)
	print("[FPS]   其余（视图同步+提交+渲染）    %7.2f ms   <-- 渲染瓶颈就看这一项" % (avg - logic_avg))
	print("[FPS]   => %.1f fps (avg)   %.1f fps (p95)" % [1000.0 / maxf(0.01, avg), 1000.0 / maxf(0.01, p95)])
	print("[FPS]   draw calls/frame: %d   objects: %d   video mem: %.1f MB"
		% [int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			int(Performance.get_monitor(Performance.OBJECT_COUNT)),
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0])
	# ★ 追击寻路的分量：次数 vs 单次成本。实机 20 fps 时只有这两个数能说明该优化哪边。
	var engaged := 0
	for u in w.units:
		if u.target != null or u.target_building != null:
			engaged += 1
	print("[FPS]   交战单位 %d/%d   repath calls/frame %.1f   move_to calls/frame %.1f   us/move_to %.1f"
		% [engaged, w.units.size(),
			float(CombatRes.repath_calls) / float(n_frames),
			float(UnitRes.move_to_calls) / float(n_frames),
			(logic_avg * 1000.0) / maxf(1.0, float(UnitRes.move_to_calls))])
	# ★★ 全部分项按耗时排序打印。只打印固定那几个 key 会漏掉真正的瓶颈 ——
	#    实测实机行军攻击 42 ms 逻辑里寻路只占极小一块（move_to 才 23 次/帧），
	#    必须让每个非零分项都露出来，否则优化就是瞎猜。
	print("[FPS]   -- logic phases (ms/frame, all non-zero) --")
	var keys: Array = []
	for k in w.profile_us.keys():
		keys.append(str(k))
	var lines: Array = []
	for k in keys:
		var ms := float(int(w.profile_us[k])) / 1000.0 / float(n_frames)
		if ms >= 0.05:
			lines.append([ms, k])
	lines.sort_custom(func(a, b): return a[0] > b[0])
	for e in lines:
		print("[FPS]     %-24s %8.3f" % [e[1], e[0]])
	# ★★ 机器漂移参照（与 tests/bench_crowd.gd 的 _calibrate 同一手法）。
	#    沙箱/笔记本持续跑十几秒后会限频，同一份代码的帧时间能从 20 ms 爬到 90 ms ——
	#    看起来像「优化把游戏弄卡了」，其实是环境在变慢（实测踩过，见 docs/pitfalls.md 1.6）。
	#    ref1/ref0 > 1.3 时，上面的 avg/p95 一律不可当真，只能跟同一次进程内的数字比。
	print("[FPS]   -- machine drift --  reference %.0f us -> %.0f us  (x%.2f)"
		% [ref0, ref1, ref1 / maxf(1.0, ref0)])
	if ref1 > ref0 * 1.3:
		print("[FPS]      WARN: this machine got %.0f%% slower during the run; avg/p95 are pessimistic."
			% ((ref1 / maxf(1.0, ref0) - 1.0) * 100.0))
	# ★ 最慢帧 + 分布直方图：avg 与 p50 差得远时，答案都在这里。
	#   （实测踩过：行军攻击 avg 85 ms 而 p50 只有 30 ms —— 是少数帧极贵，
	#    只看平均值永远找不到它们，必须把最慢帧和分桶一起打出来。）
	print("[FPS]   worst frame %.1f ms" % worst_ms)
	var b1 := 0
	var b2 := 0
	var b3 := 0
	var b4 := 0
	for s in samples:
		if s < 20.0:
			b1 += 1
		elif s < 50.0:
			b2 += 1
		elif s < 120.0:
			b3 += 1
		else:
			b4 += 1
	print("[FPS]   frame buckets: <20ms %d  20-50ms %d  50-120ms %d  >120ms %d"
		% [b1, b2, b3, b4])
	# ★ 尖峰帧里到底哪一项爆了（逐帧最大增量）
	var peaks: Array = []
	for k in peak.keys():
		if int(peak[k]) >= 1000:
			peaks.append([int(peak[k]), k])
	peaks.sort_custom(func(a, b): return a[0] > b[0])
	var ptxt := ""
	for e in peaks:
		ptxt += "%s=%.1fms  " % [e[1], float(e[0]) / 1000.0]
	print("[FPS]   per-frame PEAK by phase: %s" % ptxt)
	# ★★ 距离场建场次数：追击时每个敌人所在格都要一张新场，而 LRU 只有 4 张 ——
	#    这是「行军攻击 20 fps」的头号嫌疑，必须直接量出来。
	var fb := 0
	var fb_us := 0
	if w.crowd != null:
		fb = int(w.crowd.field_builds)
		fb_us = int(w.crowd.field_build_us)
	print("[FPS]   distance-field builds: %d total (%.1f/frame), %.1f ms/frame building"
		% [fb, float(fb) / float(n_frames), float(fb_us) / 1000.0 / float(n_frames)])
	print("[FPS]   60fps 预算 16.67 ms：avg 余量 %+.2f ms" % (16.67 - avg))


func _place_units(w, cfg, n: int) -> void:
	# ★ 方阵必须摆在地图**里面**：真实地图是 27×22，按固定的 (14,36) 摆的话
	#   绝大多数单位会被 sync_tile 钳到地图边缘上挤成一坨（碰撞成本就不是真实值了）。
	var rows_of_block: int = int(ceil(float(n) / float(BLOCK_COLS)))
	var block_w: float = float(BLOCK_COLS) * BLOCK_SPACING
	var block_h: float = float(rows_of_block) * BLOCK_SPACING
	var origin := Vector2(
		maxf(1.0, float(w.map.cols) * 0.5 - block_w * 0.5),
		maxf(1.0, float(w.map.rows) * 0.5 - block_h * 0.5)
	)
	var fresh: Array = []
	for i in n:
		var col := i % BLOCK_COLS
		var row := i / BLOCK_COLS
		var u = UnitRes.create(cfg, "fps-%d" % i, "fps %d" % i,
			Vector2i(0, 0), w.my_faction, UnitRes.KIND_SUBORDINATE)
		u.pos = origin + Vector2(float(col) * BLOCK_SPACING, float(row) * BLOCK_SPACING)
		u.sync_tile(w.map)
		fresh.append(u)
	w.units = fresh
	print("[FPS]   block origin=%s (map %dx%d)" % [str(origin), w.map.cols, w.map.rows])


func _env_int(name: String, fallback: int) -> int:
	var v := OS.get_environment(name)
	if v.is_valid_int():
		return maxi(1, int(v))
	return fallback


## ⚠️ 开关必须单独一个 helper：`_env_int` 里有 `maxi(1, ...)`（那是给「单位数/帧数」用的，
##    0 没有意义），所以 `DAEEM_FPS_PROFILE=0` 走 `_env_int` 会被抬成 1、永远关不掉 ——
##    实测踩过：以为关了剖析，其实一直在量插桩路径，差点得出错误结论。
func _env_flag(name: String, fallback: bool) -> bool:
	var v := OS.get_environment(name)
	if v == "":
		return fallback
	return v != "0"


## 一段固定的纯计算，用来探测「这台机器在本次运行里有没有变慢」。
## ★★ 与 tests/bench_crowd.gd 的同名函数是同一手法、同一工作量级：没有它，
##    限频造成的「越跑越慢」会被当成游戏的性能问题（实测踩过：待命 6→40 ms）。
func _calibrate() -> float:
	var t0 := Time.get_ticks_usec()
	var acc := 0.0
	for i in 300000:
		acc += sqrt(float(i))
	if acc < 0.0:
		printerr("impossible")          # 防止编译器把整个循环优化掉
	return float(Time.get_ticks_usec() - t0)


# ------------------------------------------------------------------
# 基准地图：与 tests/bench_crowd.gd 用**同一张** 100×100 合成图，
# 这样「实机帧率」和「无头逻辑耗时」两个数字才可比。
# ------------------------------------------------------------------

const MAP_COLS := 100
const MAP_ROWS := 100
const BENCH_SEED := 20240920
const LANE_Y0 := 34
const LANE_Y1 := 66


func _write_bench_map() -> String:
	var path := OS.get_temp_dir().path_join("daeem_fps_map.json")
	var lines: Array = []
	for y in MAP_ROWS:
		var line := ""
		for x in MAP_COLS:
			if y >= LANE_Y0 and y <= LANE_Y1:
				line += "." if _hash01(x, y) > 0.18 else "^"
			elif _hash01(int(x / 3) + 101, int(y / 3) + 101) < 0.10:
				line += "#"
			elif _hash01(int(x / 2) + 977, int(y / 2) + 977) < 0.28:
				line += "^"
			else:
				line += "."
		lines.append(line)
	var data := {
		"cols": MAP_COLS, "rows": MAP_ROWS, "layout": lines,
		"faction_bases": {"p1": [8, MAP_ROWS - 10], "enemy": [MAP_COLS - 9, 9]},
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "res://data/test_map.json"
	f.store_string(JSON.stringify(data))
	f.close()
	return path


func _hash01(x: int, y: int) -> float:
	var h: int = (x * 73856093 + BENCH_SEED) ^ (y * 19349663 + BENCH_SEED)
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(absi(h) % 100000) / 100000.0
