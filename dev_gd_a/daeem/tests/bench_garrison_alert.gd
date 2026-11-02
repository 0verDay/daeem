## bench_garrison_alert.gd —— ★★ 阵地性 AI「警戒唤醒」的 A/B 量尺（不是断言测试）。
##
## 用途：回答「这个优化到底降了多少设备负载 / 联机负载」。
##   · 同一张 dscj（合作关，34 位驻防守将、约 256 单位）跑两遍：
##       alert=on（新行为：默认静止，威胁逼近才巡逻）
##       alert=off（旧行为：一直巡逻）
##   · 两遍都用固定逻辑步长 1/60，同一 `rand_salt`（红点刷兵可复现）；
##   · 量三件事：
##       1) `world.tick` 的 CPU（ms/帧）与其中 `ai/garrison` 那一段；
##       2) 平均「正在移动」的单位数（移动 = 碰撞 / 区划扫描 / 快照增量都变贵）；
##       3) 合作增量快照的**平均字节数**（30 Hz，含每 300 条一次关键帧），
##          以及折算的 MB/s —— 这是联机负载的直接指标。
##
## 用法：
##   <mono Godot>_console.exe --headless --path <工程> --script res://tests/bench_garrison_alert.gd
##
## 可选环境变量：
##   DAEEM_GA_SECONDS   每个模式跑多少秒（默认 20）
##   DAEEM_GA_LEVEL     关卡 id（默认 dscj）
##
## ⚠️ 它不进 tools/run-tests.ps1：数字随机器波动，写成断言只会变成随机红灯。
## ⚠️ 一次只跑一个进程，别拿后半段数字当基准（真机持续负载后会限频）。
extends SceneTree

const ConfigRes = preload("res://logic/config.gd")
const CampaignRes = preload("res://logic/campaign.gd")
const WorldRes = preload("res://logic/world.gd")
const SnapshotRes = preload("res://logic/snapshot.gd")
const ProtocolRes = preload("res://net/protocol.gd")
const GarrisonAiRes = preload("res://logic/garrison_ai.gd")
const FactionRes = preload("res://logic/faction.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const DT := 1.0 / 60.0
## 与 `net.snapshot_hz` / `snapshot_keyframe_every` 默认值一致（host_session 的 setup）。
const SNAP_HZ := 30
const KEYFRAME_EVERY := 300


func _initialize() -> void:
	var cfg = ConfigRes.load_default()
	if cfg == null:
		printerr("[GA] config 载入失败")
		quit(1)
		return
	var level_id := _env_str("DAEEM_GA_LEVEL", "dscj")
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(level_id) if camp != null else null
	if lv == null:
		printerr("[GA] 关卡载入失败：%s" % level_id)
		quit(1)
		return
	var seconds: float = maxf(2.0, _env_float("DAEEM_GA_SECONDS", 20.0))
	print("[GA] level=%s  seconds=%.0f  dt=1/60  snap=%dHz  keyframe_every=%d"
		% [level_id, seconds, SNAP_HZ, KEYFRAME_EVERY])
	print("[GA] mode | units | tick ms/帧 | ai/garrison ms/帧 | 移动单位(均) | 守军移动(均) | 已建巡逻路线 | snap全图 字节 | MB/s@30 | snap视野 字节 | MB/s@30")

	# 顺序固定：先新行为、后旧行为。两遍各造一个**全新的世界**（互不影响）。
	_run(cfg, lv, true, seconds)
	_run(cfg, lv, false, seconds)
	quit(0)


func _run(cfg, lv, alert_on: bool, seconds: float) -> void:
	cfg.ai_garrison_cfg()["alert_enabled"] = alert_on
	var host = WorldRes.create_from_level(cfg, lv, "F1", lv.coop_roster(), true)
	if host == null:
		printerr("[GA] 世界建不出来（alert=%s）" % str(alert_on))
		return
	host.set_rand_salt(1234)
	host.profile_on = true
	host.profile_reset()

	# 首帧当预热：把 AI 控制器的第一次决策 / 缓存建起来，不计入统计。
	host.tick(DT)
	_report_initial_threat(host, alert_on)

	var frames: int = maxi(1, int(round(seconds / DT)))
	var snap_every: int = maxi(1, int(round(60.0 / float(SNAP_HZ))))
	# ★ 两条口径都量：
	#   · 全图（viewer_side = ""）—— 分析「单位总数」带来的上限；
	#   · 客机视野（F2 的 side）—— **真实合作局**走的就是这一条（snapshot 会滤掉看不见的敌人）。
	#     守将的休眠省的是「正在移动」那几个字段，所以真实收益取决于
	#     「醒着的守军里有多少是客机看得见的」。
	var viewer_side: String = String(FactionRes.side_of("F2"))
	var cache_all: Dictionary = {}
	var cache_view: Dictionary = {}
	var snap_seq: int = 0
	var bytes_all: int = 0
	var bytes_view: int = 0
	var snap_count: int = 0
	var total_us: int = 0
	var moving_sum: int = 0
	var garrison_moving_sum: int = 0
	var samples: int = 0

	for i in frames:
		var t0: int = Time.get_ticks_usec()
		host.tick(DT)
		total_us += Time.get_ticks_usec() - t0
		# 模拟房主的 30 Hz 快照（与 host_session.send_snapshot 同一套增量 / 关键帧规则）。
		if i % snap_every == 0:
			snap_seq += 1
			var keyframe: bool = snap_seq <= 1 \
				or (KEYFRAME_EVERY > 0 and snap_seq % KEYFRAME_EVERY == 0)
			var sa: Dictionary = SnapshotRes.to_snapshot(host, cache_all, keyframe)
			bytes_all += _encode_bytes(sa, snap_seq)
			var sv: Dictionary = SnapshotRes.to_snapshot(host, cache_view, keyframe, viewer_side)
			bytes_view += _encode_bytes(sv, snap_seq)
			snap_count += 1
		# 每 60 帧采一次「正在移动的单位数」。
		if i % 60 == 0:
			var mov := 0
			var gmov := 0
			for u in host.units:
				if not u.alive:
					continue
				if u.moving:
					mov += 1
					if int(u.garrison_zone_id) >= 0:
						gmov += 1
			moving_sum += mov
			garrison_moving_sum += gmov
			samples += 1

	var n: float = float(frames)
	var tick_ms: float = float(total_us) / 1000.0 / n
	var ai_us: int = int(host.profile_us.get("ai/garrison", 0))
	var ai_ms: float = float(ai_us) / 1000.0 / n
	var routes: int = 0
	var awake: int = 0
	for u in host.units:
		if u.alive and int(u.garrison_zone_id) >= 0:
			if not u.patrol_points.is_empty():
				routes += 1
			if bool(u.garrison_alert_active):
				awake += 1
	var avg_all: float = float(bytes_all) / float(maxi(1, snap_count))
	var avg_view: float = float(bytes_view) / float(maxi(1, snap_count))
	var mb_all: float = avg_all * float(SNAP_HZ) / (1024.0 * 1024.0)
	var mb_view: float = avg_view * float(SNAP_HZ) / (1024.0 * 1024.0)
	print("[GA] %-4s | %5d | %10.3f | %17.3f | %12.2f | %12.2f | %12d | %12.0f | %10.2f | %12.0f | %10.2f"
		% ["on" if alert_on else "off", host.units.size(), tick_ms, ai_ms,
			float(moving_sum) / float(maxi(1, samples)),
			float(garrison_moving_sum) / float(maxi(1, samples)),
			routes, avg_all, mb_all, avg_view, mb_view])
	print("[GA]      └ 结束时警戒中的守将 %d / 有巡逻路线的守将 %d" % [awake, routes])
	# ⚠️ world 是 RefCounted（纯逻辑），没有 queue_free；直接丢引用即可。
	host = null


## 一条 `snap` 信封的 UTF-8 字节数（与 host_session 实际发送一致）。
func _encode_bytes(snap: Dictionary, seq: int) -> int:
	var text: String = ProtocolRes.encode(ProtocolRes.make("snap", seq, {"snap": snap}))
	return text.to_utf8_buffer().size()


## 开局那一刻「谁已经被唤醒了、因为哪一条判据」——用来解释第一行数字。
func _report_initial_threat(host, alert_on: bool) -> void:
	var n_zoned := 0
	var n_leader := 0
	var zone1 := 0
	var zone2 := 0
	var troop := 0
	var troop_r: float = 10.0
	var troop_sq: float = troop_r * troop_r
	for u in host.units:
		if not u.alive or int(u.garrison_zone_id) < 0:
			continue
		n_zoned += 1
		if not GarrisonAiRes.is_patrol_leader(host, u):
			continue
		n_leader += 1
		var z: Variant = host.zone_by_id(int(u.garrison_zone_id))
		if z == null:
			continue
		if GarrisonAiRes._hostile_zone_within(host, u, z, 1):
			zone1 += 1
		if GarrisonAiRes._hostile_zone_within(host, u, z, 2):
			zone2 += 1
		if GarrisonAiRes._hostile_unit_within(host, u, troop_sq):
			troop += 1
	print("[GA]      开局威胁判据（alert=%s）：有归属区划的单位 %d（其中带队守将 %d）；相邻敌对区划 %d；2 步内 %d；10 格内敌军 %d"
		% ["on" if alert_on else "off", n_zoned, n_leader, zone1, zone2, troop])


func _env_str(name: String, fallback: String) -> String:
	var raw := OS.get_environment(name).strip_edges()
	return fallback if raw == "" else raw


func _env_float(name: String, fallback: float) -> float:
	var raw := OS.get_environment(name).strip_edges()
	return fallback if raw == "" else float(raw)
