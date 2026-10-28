## bench_dscj.gd —— **真机问题复现用**：dscj 合作关 + AI 队友（= 主界面 ai_test_hz 那条入口）
##
## 为什么另起一份（不改 `bench_fps_3d.gd`）：
##   · `bench_fps_3d` 用的是 fallback 默认图 + 手动摆的一坨单位，**没有 commander AI**；
##   · 用户报的「手机 30 帧」出现在 **dscj（256 单位）+ command ai** 这一局，
##     而那一局的成本结构与默认图完全不同（AI 决策 / 256 个单位的单位循环 / 组建索敌）。
##
## ★★ 与墙钟基准的区别（这是这份能用的关键）：
##   `bench_fps_3d` 让引擎驱动帧、量「两帧之间」——在没有窗口的机器上那里面
##   有 ~18 ms 的呈现固定开销，会把游戏本身的成本淹掉。
##   这里改成 **手动驱动 `game._process(1/60)` 并逐次计时**：
##     · 量到的是**纯 CPU 帧成本**（逻辑 + 视图同步），与 GPU / 窗口无关；
##     · dt 固定 1/60 ⇒ 每帧要做的活与实机 60 Hz 一致（不是 headless 那种 0.2 ms 的假 dt）；
##     · 每次调用之间 `await process_frame`，让 `_draw`（overlay / 小地图）也照常跑一遍。
##
## ★ 用法（**必须带窗口**才准；`--headless` 也能跑，但只反映 CPU + 命令录制）：
##   <mono Godot>_console.exe --path <工程> --script res://tests/bench_dscj.gd
## 环境变量：
##   DAEEM_DSCJ_FRAMES  统计帧数（默认 180）
##   DAEEM_DSCJ_WARM    预热帧数（默认 60：让 AI 出兵、着色器就绪）
##   DAEEM_DSCJ_STEP    逻辑步长（毫秒；33 = 30 Hz，0 = 每帧一步）
##   DAEEM_FOG_GATE     A/B：fog 版本号闸门 1/0（默认按 config.json）
##   DAEEM_GARRISON_INTERVAL  A/B：驻防 AI 决策周期（秒；0 = 每帧，旧行为）
##
## ⚠️ 读法：`CPU` 那一行是「这一局一帧要多少毫秒 CPU」。60 fps 的预算是 16.7 ms；
##    手机（约 2~3 倍慢）按 `×2.5` 估。分项表告诉你钱花在哪一段。
extends SceneTree

const ConfigRes = preload("res://logic/config.gd")
const CampaignLibRes = preload("res://logic/campaign_library.gd")
const GameSceneRes = preload("res://view/game_scene3d.gd")
const UnitRes = preload("res://logic/unit.gd")
const CombatRes = preload("res://logic/combat.gd")

const CAMPAIGN_ID := "demo"
const LEVEL_ID := "dscj"


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	_run()


func _run() -> void:
	var cfg = ConfigRes.load_default()
	if cfg == null:
		printerr("[DSCJ] config 载入失败")
		quit(1)
		return
	cfg.set_viewport_size(1920.0, 1080.0)

	# ---- 与 main.gd 的 `_on_coop_solo_started()` 同一条路：按 option 找战役 → 取关卡 ----
	var option: Dictionary = {}
	for item in CampaignLibRes.list_campaigns(cfg):
		if String((item as Dictionary).get("id", "")) == CAMPAIGN_ID:
			option = item
			break
	if option.is_empty():
		printerr("[DSCJ] 找不到战役 %s" % CAMPAIGN_ID)
		quit(1)
		return
	var campaign = CampaignLibRes.load_campaign_by_option(option, cfg)
	var level = campaign.level(LEVEL_ID) if campaign != null and campaign.has_method("level") else null
	if level == null:
		printerr("[DSCJ] 找不到关卡 %s" % LEVEL_ID)
		quit(1)
		return

	var game = GameSceneRes.new()
	game.name = "BenchGame"
	root.add_child(game)
	# ★ 必须先让引擎跑一帧：`_assemble()` 里的相机 / 视口在 `add_child` 的**同一帧**还没挂好，
	#   直接调 `_process` 会报 `get_viewport() is null` / `Camera is not inside scene`。
	await process_frame
	# ★ `start_coop_solo` 自己会再载一份 cfg；这里传的 cfg 只用于找关卡。
	if not game.start_coop_solo(level, {"difficulty": "normal"}):
		printerr("[DSCJ] 场景起不来（关卡不是 coop？）")
		quit(1)
		return
	await process_frame
	await process_frame
	# ★★ 关键：**关掉引擎对本节点的驱动**，改成手动调 —— 否则同一帧会跑两遍，
	#   而且量到的是引擎的 dt（headless 下只有零点几毫秒），不是实机 1/60。
	game.set_process(false)
	_apply_env_overrides(game.world.cfg)

	var frames: int = _env_int("DAEEM_DSCJ_FRAMES", 180)
	var warm: int = _env_int("DAEEM_DSCJ_WARM", 60)
	# ★ 复现手机的「固定逻辑步长」：DAEEM_DSCJ_STEP=33（毫秒）⇒ 30 Hz 逻辑 + 手动 1/60 渲染。
	#   不设 = 0 = 旧行为（每帧一步），用来做 A/B。
	var step_ms: int = _env_int("DAEEM_DSCJ_STEP", 0)
	game.logic_step_sec = float(step_ms) / 1000.0

	# 预热：AI 要几十帧才会出兵 / 建东西；着色器、批次也在前几帧建好。
	for i in warm:
		game._process(1.0 / 60.0)
		await process_frame

	game.profile_on = true
	game.profile_reset()
	game.world.profile_on = true
	game.world.profile_reset()
	# 诊断计数器：只统计**测量窗口内**的次数（预热阶段的不算）。
	UnitRes.path_pops = 0
	UnitRes.move_to_calls = 0
	CombatRes.repath_calls = 0
	game.world.fog.stat_gate_hits = 0
	game.world.fog.stat_collects = 0

	var total_us: int = 0
	var peak_us: int = 0
	var samples: Array = []
	# ★★ 2026.10.28：**整帧 process 成本**（`Performance.TIME_PROCESS`）。
	#   上面那个 `total_us` 只量了 `game._process` 自己；HUD / 地形道具 / 小地图 /
	#   新加的播报横幅都是**别的节点**，它们每帧的开销只有这个监视器看得见。
	var proc_sum: float = 0.0
	var proc_max: float = 0.0
	# `DAEEM_DSCJ_BANNER=<每多少帧播一条>`：压力测试播报横幅（0 = 不播）。
	var banner_every: int = _env_int("DAEEM_DSCJ_BANNER", 0)
	# ★★ 2026.10.28（长跑）：`DAEEM_DSCJ_TRACE=<每多少帧打一行>` 打点。
	#   为什么需要：短测只覆盖开局（256 单位）。而**打久了单位会涨**（AI 满编 / 玩家造兵），
	#   真正的掉帧往往出现在 2~5 分钟之后 —— 那一帧的成本与开局根本不是一回事。
	var trace: int = _env_int("DAEEM_DSCJ_TRACE", 0)
	var win_start_us: int = 0
	var win_frames: int = 0
	# ★ 播报横幅在屏幕上出现的帧数（占比 = 它对平均帧成本的实际影响面）。
	var banner_frames: int = 0
	# ★ 播报「从无到有」的次数（= 真正弹了几次横幅；用来判断它是不是常态开销）。
	var banner_bursts: int = 0
	var banner_was_on: bool = false
	for i in frames:
		var t0: int = Time.get_ticks_usec()
		game._process(1.0 / 60.0)
		var used: int = Time.get_ticks_usec() - t0
		total_us += used
		if used > peak_us:
			peak_us = used
		samples.append(float(used) / 1000.0)
		if banner_every > 0 and i % banner_every == 0 and game.hud != null \
				and game.hud.broadcast_banner != null:
			game.hud.show_broadcast(String(game.world.my_faction), 2)
		win_start_us += used
		win_frames += 1
		if game.hud != null and game.hud.broadcast_banner != null \
				and game.hud.broadcast_banner.visible:
			banner_frames += 1
			if not banner_was_on:
				banner_bursts += 1
			banner_was_on = true
		else:
			banner_was_on = false
		if trace > 0 and (i + 1) % trace == 0:
			# ★ 只数「commander AI 那一方」的单位（没有 `unit_count_of` 这种 API，自己数）。
			var ai_sides: Array = game.world.commander_factions()
			var ai_n: int = 0
			for u0 in game.world.units:
				if ai_sides.has(String(u0.faction)):
					ai_n += 1
			print("[DSCJ] t=%5.1fs  units=%d  ｜ commander_ai_units=%d  buildings=%d  ｜ 本段 CPU %.2f ms/帧"
				% [float(i + 1) / 60.0, game.world.units.size(), ai_n,
					game.world.building_list.size(),
					float(win_start_us) / 1000.0 / float(maxi(1, win_frames))])
			win_start_us = 0
			win_frames = 0
		# 让这一帧真的被画一次（`_draw` 里的 overlay / 小地图不会被 `_process` 覆盖到）
		await process_frame
		# ★ 采样「上一帧的整帧 process 耗时」（含 HUD / props / 小地图 / 播报横幅）。
		var proc: float = Performance.get_monitor(Performance.TIME_PROCESS)
		proc_sum += proc
		proc_max = maxf(proc_max, proc)

	samples.sort()
	var n: int = maxi(1, frames)
	print("[DSCJ] level=%s  units=%d  buildings=%d  map=%dx%d  ai=%d  frames=%d"
		% [LEVEL_ID, game.world.units.size(), game.world.building_list.size(),
			int(game.world.map.cols), int(game.world.map.rows),
			game.world.commander_factions().size(), frames])
	print("[DSCJ] CPU %.2f ms/帧（p50 %.2f / p95 %.2f / max %.2f）  => %.1f fps (CPU only)"
		% [float(total_us) / 1000.0 / float(n), samples[n / 2],
			samples[int(float(n) * 0.95)], float(peak_us) / 1000.0,
			1000.0 / maxf(0.01, float(total_us) / 1000.0 / float(n))])
	print("[DSCJ] 手机估算（×2.5）：%.1f ms/帧 => %.1f fps"
		% [float(total_us) / 1000.0 / float(n) * 2.5,
			1000.0 / (float(total_us) / 1000.0 / float(n) * 2.5)])
	print("[DSCJ] 整帧 process（含 HUD/props/小地图/播报）：平均 %.2f ms，峰值 %.2f ms"
		% [proc_sum * 1000.0 / float(n), proc_max * 1000.0])
	print("[DSCJ] 播报横幅在屏帧占比 %.1f%%（%d / %d 帧），弹出 %d 次"
		% [100.0 * float(banner_frames) / float(n), banner_frames, n, banner_bursts])

	_print_profile("game_scene._process 分段（视图侧）", game.profile_us, n)
	var world_sum: float = _print_profile("world.tick 分段（逻辑侧）", game.world.profile_us, n)
	print("[DSCJ] 逻辑分段合计 %.2f ms/帧（含 props/* 与 ov/*：它们不属于 tick）" % world_sum)
	print("[DSCJ] 实例：units=%d batches=%d   buildings=%d batches=%d   DC=%d"
		% [game.units.instance_count, game.units.mesh_batch_count,
			game.buildings.instance_count, game.buildings.mesh_batch_count,
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)])
	# ★ 诊断（2026.10.28）：路点消费次数直接回答「Array.remove_at(0) 到底是不是病根」。
	print("[DSCJ] 诊断/帧：path_pops %.2f  move_to(寻路) %.2f  repath %.2f   开关：fog_gate=%d  garrison=%.3fs"
		% [float(UnitRes.path_pops) / float(n), float(UnitRes.move_to_calls) / float(n),
			float(CombatRes.repath_calls) / float(n),
			1 if bool(game.world.cfg.fog_revision_gate) else 0,
			float(game.world.cfg.ai_garrison_cfg().get("decision_interval_sec", 0.0))])
	var fhits: int = int(game.world.fog.stat_gate_hits)
	var fcols: int = int(game.world.fog.stat_collects)
	print("[DSCJ] fog 闸门：命中 %d / 采集 %d ⇒ 命中率 %.1f%%（闸门只挡「没人换格」的帧）"
		% [fhits, fcols, 100.0 * float(fhits) / float(maxi(1, fhits + fcols))])
	game.queue_free()
	quit(0)


func _print_profile(title: String, us: Dictionary, frames: int) -> float:
	if us.is_empty():
		print("[DSCJ] %s：（无数据）" % title)
		return 0.0
	var keys: Array = us.keys()
	keys.sort_custom(func(a, b): return int(us[a]) > int(us[b]))
	var sum_ms: float = 0.0
	print("[DSCJ] %s：ms/帧（降序）" % title)
	for k in keys:
		var ms: float = float(int(us[k])) / 1000.0 / float(maxi(1, frames))
		sum_ms += ms
		print("[DSCJ]   %-18s %8.3f" % [String(k), ms])
	return sum_ms


func _env_int(name: String, fallback: int) -> int:
	var raw: String = OS.get_environment(name)
	if raw == "":
		return fallback
	return int(raw)


## 不改 config.json 的 A/B 开关（同一台机器、同一份代码，只切这两个数）。
func _apply_env_overrides(cfg) -> void:
	var gate: String = OS.get_environment("DAEEM_FOG_GATE")
	if gate != "":
		cfg.fog_revision_gate = int(gate) != 0
	var interval: String = OS.get_environment("DAEEM_GARRISON_INTERVAL")
	if interval != "":
		cfg.ai_garrison_cfg()["decision_interval_sec"] = maxf(0.0, float(interval))
