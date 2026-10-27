## test_session.gd —— M12.2：房主 / 客机会话（假连接，不碰真实网络）。
##
## 盯四件事：
##   1. start 带关卡数据 / 席位；snap 按 20Hz 发；event 能到客机；
##   2. 客机命令被房主执行；
##   3. 席位 / faction / seq 不对的命令在信封层就被丢；
##   4. 房主 bye 让客机收摊。
extends "res://tests/test_case.gd"

const CampaignRes = preload("res://logic/campaign.gd")
const WorldRes = preload("res://logic/world.gd")
const ProtocolRes = preload("res://net/protocol.gd")
const HostSessionRes = preload("res://net/host_session.gd")
const ClientSessionRes = preload("res://net/client_session.gd")
const FakeTransportRes = preload("res://tests/fake_transport.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const LEVEL_ID := "02_twin_line"

var _started: Array = []
var _snaps: int = 0
var _events: Array = []
var _closed: Array = []
var _applied: Array = []
var _rejected: Array = []

func _initialize() -> void:
	_case_name = "test_session"
	run_all(Callable(self, "_run"))


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID) if camp != null else null
	if lv == null:
		ok(false, "（前提）合作关能载入")
		return
	var host_w = WorldRes.create_from_level(cfg, lv, "F1", lv.coop_roster(), true)
	var guest_w = WorldRes.create_from_level(cfg, lv, "F2", lv.coop_roster(), true)
	if host_w == null or guest_w == null:
		ok(false, "（前提）两个世界能建出来")
		return

	var ht = FakeTransportRes.new()
	var gt = FakeTransportRes.new()
	ht.attach(gt)
	gt.attach(ht)

	# ★ 会话只需要信号，不需要进场景树：不 add_child 就不会在退出时留 Node 泄漏。
	var host = HostSessionRes.new()
	var client = ClientSessionRes.new()
	host.setup(host_w, cfg, ht, "F1", "F2")
	client.setup(guest_w, cfg, gt, "F2")
	# ★ 断言的是「按 config 里的 net.snapshot_hz 装配（并夹在 10~60）」，不是「必须是 30」——
	#   把具体数值写死会让「调频率的手感实验」变成改测试。
	var want_hz: float = clampf(float(cfg.num("net.snapshot_hz", 30.0)), 10.0, 60.0)
	near(host.snap_interval, 1.0 / want_hz, 1e-6,
		"★ 按 net.snapshot_hz=%.0f 装配（夹在 10~60）" % want_hz)
	host.snap_interval = 0.05
	client.started.connect(_on_started)
	client.snapshot_applied.connect(_on_snapshot)
	client.events_received.connect(_on_events)
	client.closed.connect(_on_closed)
	host.command_applied.connect(_on_applied)
	host.command_rejected.connect(_on_rejected)

	# ---- start ----
	host.start_game("demo", LEVEL_ID)
	client.poll()
	eq(_started.size(), 1, "★ 客机收到 start")
	if _started.size() > 0:
		var p: Dictionary = _started[0]
		eq(String(p.get("campaign", "")), "demo", "start 带 campaign")
		eq(String(p.get("level_id", "")), LEVEL_ID, "start 带 level_id")
		eq(p.get("seats", []), ["F1", "F2"], "start 带两个席位（原序）")
		ok(typeof(p.get("level_data", null)) == TYPE_DICTIONARY
			and not (p["level_data"] as Dictionary).is_empty(),
			"★ start 带完整关卡数据（客机不必重新读本地战役目录）")

	# ---- snap ----
	host.send_snapshot()
	client.poll()
	eq(_snaps, 1, "★ 客机收到快照并应用")
	eq(float(guest_w.resources["food"]), float(host_w.player_resources["F2"]["food"]),
		"★★ 快照把客机自己的钱写回（不是房主的）")
	host.tick(0.01)
	client.poll()
	eq(_snaps, 1, "不到 0.05s 间隔不发快照")
	host.tick(0.05)
	client.poll()
	eq(_snaps, 2, "★ 过了 0.05s 间隔发第二帧")

	# ---- 一帧多条快照：只应用最后一条 ----
	host_w.player_resources["F2"]["food"] = 111.0
	host.send_snapshot()
	host_w.player_resources["F2"]["food"] = 222.0
	host.send_snapshot()
	var applied_before: int = client.snapshots_applied
	client.poll()
	eq(client.snapshots_applied, applied_before + 1,
		"★★ 同一帧多条快照只 apply 最后一条")
	eq(client.snapshots_coalesced, 1, "★ 中间那条被合并掉")
	eq(float(guest_w.resources["food"]), 222.0, "★ 客机应用的是最后一条")

	# ---- 背压：出站缓冲过高时跳过这一帧 ----
	var sent_before: int = ht.sent.size()
	ht.buffered = host.snap_buffer_limit + 1
	host.send_snapshot()
	eq(ht.sent.size(), sent_before, "★★ 出站缓冲过高时不发快照")
	eq(host.snapshots_skipped, 1, "★ 记一次背压跳过")
	ht.buffered = 0
	host.send_snapshot()
	eq(ht.sent.size(), sent_before + 1, "★ 缓冲恢复后继续发")
	client.poll()
	eq(client.snapshots_applied, applied_before + 2, "★ 恢复后的快照能到客机")

	# ---- 合法命令 ----
	var f2 = _first_unit(host_w, "F2")
	ok(f2 != null, "（前提）房主世界里有 F2 单位")
	if f2 != null:
		client.send_command({"kind": "stop", "ids": [f2.id], "faction": "F2"})
		ht.poll()
		eq(_applied.size(), 1, "★ 客机命令到房主并被处理")
		if _applied.size() > 0:
			ok(bool((_applied[0] as Dictionary).get("ok", false)), "★ 合法命令被接受")

		# ---- faction 冒充 ----
		client.send_command({"kind": "stop", "ids": [f2.id], "faction": "F1"})
		ht.poll()
		eq(_applied.size(), 1, "★ faction 不对的命令没有进 command_processor")
		eq(_rejected.size(), 1, "★ 记了一次拒绝")
		if _rejected.size() > 0:
			eq(String(_rejected[0]), "faction", "拒因 = faction")

	# ---- by 冒充（绕过 client_session 直接塞一条） ----
	var f1 = _first_unit(host_w, "F1")
	if f1 != null:
		gt.send_text(ProtocolRes.encode(ProtocolRes.make("cmd", 99, {
			"by": "F1",
			"cmd": {"kind": "stop", "ids": [f1.id], "faction": "F1"},
		})))
		ht.poll()
		eq(String(_rejected[-1]), "seat", "★ by 不是客机席位 → seat")

	# ---- 重放旧 seq ----
	gt.send_text(ProtocolRes.encode(ProtocolRes.make("cmd", 1, {
		"by": "F2",
		"cmd": {"kind": "stop", "ids": [f2.id] if f2 != null else [], "faction": "F2"},
	})))
	ht.poll()
	eq(String(_rejected[-1]), "seq", "★ 旧 seq 重放 → seq")

	# ---- 事件 ----
	host.send_events([{"type": "notice", "text": "hello"}])
	client.poll()
	eq(_events.size(), 1, "★ 客机收到事件")
	if _events.size() > 0:
		eq(String((_events[0][0] as Dictionary).get("text", "")), "hello",
			"事件字段原样到达")

	# 带对象引用的事件：event_codec 应换成 id，客机再查回本地对象。
	if f2 != null:
		host.send_events([{"type": "unit_recruited", "unit": f2, "leader": f2}])
		client.poll()
		eq(_events.size(), 2, "★ 带对象引用的事件也能发")
		if _events.size() > 1:
			var e: Dictionary = _events[1][0]
			var eu = e.get("unit", null)
			ok(eu != null, "★ 事件里的 unit 被查回本地对象")
			if eu != null:
				eq(String(eu.id), String(f2.id), "★ 查回来的就是同一个单位 id")

	# ---- 房主 bye ----
	host.send_bye("host_left")
	client.poll()
	eq(_closed.size(), 1, "★ 客机收到 bye")
	if _closed.size() > 0:
		eq(String(_closed[0]), "host_left", "bye 原因到达")

	host.free()
	client.free()


func _on_started(payload: Dictionary) -> void:
	_started.append(payload)


func _on_snapshot() -> void:
	_snaps += 1


func _on_events(items: Array) -> void:
	_events.append(items)


func _on_closed(reason: String) -> void:
	_closed.append(reason)


func _on_applied(ok: bool, cmd: Dictionary) -> void:
	_applied.append({"ok": ok, "cmd": cmd})


func _on_rejected(reason: String) -> void:
	_rejected.append(reason)


func _first_unit(w, fid: String):
	for u in w.units:
		if u.alive and String(u.faction) == fid:
			return u
	return null
