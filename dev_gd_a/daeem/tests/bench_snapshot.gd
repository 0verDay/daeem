## bench_snapshot.gd —— 量合作快照的**体积 / 序列化 / 应用**耗时（量尺，不是断言测试）。
##
## 用法：
##   <mono Godot>_console.exe --headless --path <工程> --script res://tests/bench_snapshot.gd
##
## 可选环境变量：
##   DAEEM_SNAP_COUNTS  额外往世界里塞多少个兵，逗号分隔（默认 "0,100,300,500"）
##   DAEEM_SNAP_ROUNDS  每个采样点重复多少次（默认 10）
##
## 输出的是「当前这台机器 + 当前 02_twin_line」的数字：
##   · bytes = 一帧 `snap` 信封的 UTF-8 字节数（含 JSON 外层）
##   · to_snapshot / encode / apply+refresh = 单次平均耗时
##   · 20 / 30 / 60Hz = 按这一帧体积折算的带宽
##
## ⚠️ 它不进 tools/run-tests.ps1：数字随机器波动，写成断言只会变成随机红灯。
## ★ 真机 / 沙箱持续负载后会限频；一次只跑一个进程，别拿后半段数字当基准。
extends SceneTree

const ConfigRes = preload("res://logic/config.gd")
const CampaignRes = preload("res://logic/campaign.gd")
const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const SnapshotRes = preload("res://logic/snapshot.gd")
const ProtocolRes = preload("res://net/protocol.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const LEVEL_ID := "02_twin_line"
const EXTRA_COLS := 20
const EXTRA_SPACING := 0.5


func _initialize() -> void:
	var cfg = ConfigRes.load_default()
	if cfg == null:
		printerr("[SNAP] config 载入失败")
		quit(1)
		return
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID) if camp != null else null
	if lv == null:
		printerr("[SNAP] 合作关载入失败")
		quit(1)
		return

	# 房主：带 AI 的正常世界；客机：空壳（只被快照写）。
	var host = WorldRes.create_from_level(cfg, lv, "F1", lv.coop_roster(), true)
	var guest = WorldRes.create_from_level(cfg, lv, "F2", lv.coop_roster(), false)
	if host == null or guest == null:
		printerr("[SNAP] world 建不出来")
		quit(1)
		return

	var rounds := maxi(1, _env_int("DAEEM_SNAP_ROUNDS", 10))
	var counts := _parse_counts(OS.get_environment("DAEEM_SNAP_COUNTS"))
	print("[SNAP] level=%s base_units=%d rounds=%d" % [
		LEVEL_ID, host.units.size(), rounds,
	])
	print("[SNAP] columns: extra | units | buildings | zones | projectiles | bytes | "
		+ "to_snapshot ms | encode ms | apply ms | fog ms | ownership ms | tech ms | "
		+ "20Hz MB/s | 30Hz MB/s | 60Hz MB/s")

	var extra_added := 0
	for target in counts:
		if target > extra_added:
			_append_units(host, cfg, target - extra_added, extra_added)
			extra_added = target
		_measure(cfg, host, guest, extra_added, rounds)

	quit(0)


func _measure(cfg, host, guest, extra: int, rounds: int) -> void:
	# 第一遍当 warmup，不进平均（否则第一次的冷启动会污染数字）。
	var snap: Dictionary = SnapshotRes.to_snapshot(host)

	var seq := 1
	var text := ProtocolRes.encode(ProtocolRes.make("snap", seq, {"snap": snap}))
	var bytes := text.to_utf8_buffer().size()

	var snap_us := 0
	var encode_us := 0
	for i in rounds:
		var a := Time.get_ticks_usec()
		var s: Dictionary = SnapshotRes.to_snapshot(host)
		snap_us += Time.get_ticks_usec() - a
		var b := Time.get_ticks_usec()
		ProtocolRes.encode(ProtocolRes.make("snap", seq, {"snap": s}))
		encode_us += Time.get_ticks_usec() - b

	# refresh_after_snapshot() 拆成四段量：apply / fog / ownership / tech。
	var apply_us := 0
	var fog_us := 0
	var own_us := 0
	var tech_us := 0
	for i in rounds:
		var a := Time.get_ticks_usec()
		SnapshotRes.apply_snapshot(guest, cfg, snap)
		var b := Time.get_ticks_usec()
		if guest.fog != null:
			guest.fog.reset_cache()
			guest.fog.update(guest)
		var c := Time.get_ticks_usec()
		guest.refresh_ownership()
		var d := Time.get_ticks_usec()
		if guest.tech != null:
			guest._refresh_seat_tech_effects()
		var e := Time.get_ticks_usec()
		apply_us += b - a
		fog_us += c - b
		own_us += d - c
		tech_us += e - d

	var n := float(rounds)
	var mb_s := float(bytes) / (1024.0 * 1024.0)
	print("[SNAP] %5d | %5d | %5d | %5d | %5d | %7d | %8.2f | %8.2f | %8.2f | %8.2f | %8.2f | %8.2f | %8.2f | %8.2f | %8.2f"
		% [
			extra, host.units.size(), host.building_list.size(), host.zones.zones.size(),
			host.projectiles.size(), bytes,
			float(snap_us) / n / 1000.0,
			float(encode_us) / n / 1000.0,
			float(apply_us) / n / 1000.0,
			float(fog_us) / n / 1000.0,
			float(own_us) / n / 1000.0,
			float(tech_us) / n / 1000.0,
			mb_s * 20.0, mb_s * 30.0, mb_s * 60.0,
		])


func _append_units(world, cfg, n: int, start_index: int) -> void:
	for k in n:
		var i := start_index + k
		var col := i % EXTRA_COLS
		var row := i / EXTRA_COLS
		var x := 1.0 + float(col) * EXTRA_SPACING
		var y := 1.0 + float(row) * EXTRA_SPACING
		x = minf(x, float(world.map.cols) - 1.0)
		y = minf(y, float(world.map.rows) - 1.0)
		var faction := "F1" if (i % 2) == 0 else "F2"
		var u = UnitRes.create(
			cfg, "snap-bench-%d" % i, "snap-bench",
			Vector2i(0, 0), faction, UnitRes.UNIT_TYPE_SPEARMAN
		)
		u.pos = Vector2(x, y)
		u.sync_tile(world.map)
		world.units.append(u)


func _parse_counts(raw: String) -> Array:
	var out: Array = []
	if raw.strip_edges() != "":
		for part in raw.split(","):
			var s := part.strip_edges()
			if s != "":
				out.append(maxi(0, int(s)))
	if out.is_empty():
		out = [0, 100, 300, 500]
	out.sort()
	return out


func _env_int(name: String, fallback: int) -> int:
	var raw := OS.get_environment(name).strip_edges()
	if raw == "":
		return fallback
	return int(raw)
