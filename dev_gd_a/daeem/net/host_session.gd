## host_session.gd —— 房主侧会话：校验客机命令、按配置频率发快照、转发事件。
##
## 房主**跑整个世界**（tick / AI / 目标都在 game_scene 那一侧）；本文件只做三件事：
##   1. 收客机的 `cmd`，按 `by` / `faction` / `seq` 校验后交给 `command_processor`；
##   2. 每 1/snapshot_hz 秒把 `snapshot.to_snapshot(world)` 发给客机（默认 30Hz）；
##   3. 把 `world.tick()` 的事件（经 event_codec 去掉对象引用）发给客机。
##
## ★ 它**不 tick**：tick 仍由 `view/game_scene3d.gd` 调；否则同一帧会跑两遍世界。
## ★ 它**不渲染、不读输入**：那是 view 的事。
## ★ 传输层是 `net/transport.gd` 接口：M12.2 用假连接，M12.3 换 WebSocket 中继。
extends Node

const ProtocolRes = preload("res://net/protocol.gd")
const SnapshotRes = preload("res://logic/snapshot.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const EventCodecRes = preload("res://net/event_codec.gd")

## 一条客机命令被接受 / 被规则拒绝（true/false 是 command_processor 的返回值）。
signal command_applied(ok: bool, cmd: Dictionary)
## 命令在**信封 / 席位 / 序号**这一层就被丢弃（不是游戏规则拒绝）。
signal command_rejected(reason: String)
## 客机主动 bye。
signal closed(reason: String)

var world = null
var cfg = null
var transport = null
var host_seat: String = ""
var guest_seat: String = ""
## 快照间隔（秒）。`setup()` 会按 `net.snapshot_hz` 覆盖；测试可以调大 / 调小。
var snap_interval: float = 1.0 / 30.0
## 出站缓冲超过这么多字节时跳过快照（0 = 不检查）。见 `send_snapshot()`。
var snap_buffer_limit: int = 1024 * 1024
## 因背压跳过的快照数（诊断用；不参与玩法）。
var snapshots_skipped: int = 0

var _seq: int = 0
var _last_cmd_seq: int = 0
var _snap_accum: float = 0.0


## 每帧由 game_scene 调：把 transport 里的消息收进来。
func poll() -> void:
	if transport != null:
		transport.poll()


func setup(p_world, p_cfg, p_transport, p_host_seat: String, p_guest_seat: String) -> void:
	world = p_world
	cfg = p_cfg
	transport = p_transport
	host_seat = p_host_seat
	guest_seat = p_guest_seat
	if cfg != null and cfg.has_method("num"):
		var hz: float = float(cfg.num("net.snapshot_hz", 30.0))
		snap_interval = 1.0 / clampf(hz, 10.0, 60.0)
		var limit_kb: float = float(cfg.num("net.snapshot_buffer_limit_kb", 1024.0))
		snap_buffer_limit = int(maxf(0.0, limit_kb) * 1024.0)
		snapshots_skipped = 0
	if transport != null and not transport.message.is_connected(_on_message):
		transport.message.connect(_on_message)


## 房主把「这一局从哪一关来 + 关卡数据」发给客机；客机据此建同一个世界。
## ★ 关卡数据由房主发（不是让客机去本地目录重新载入），避免「房主手改过关卡、客机还是旧数据」。
func start_game(campaign_id: String, level_id: String) -> void:
	var level_data: Dictionary = {}
	if world != null and world.level != null:
		var raw: Variant = world.level.raw
		if typeof(raw) == TYPE_DICTIONARY:
			level_data = (raw as Dictionary).duplicate(true)
	var seats: Array = []
	if world != null:
		seats = world.player_seats.duplicate()
	_send("start", {
		"campaign": campaign_id,
		"level_id": level_id,
		"level_data": level_data,
		"seats": seats,
		"host_seat": host_seat,
		"guest_seat": guest_seat,
		"build": ProtocolRes.BUILD,
	})


## 每帧调用一次（由 game_scene 在 world.tick 之后调；本函数只负责「该发快照了吗」）。
func tick(dt: float) -> void:
	if snap_interval <= 0.0:
		return
	_snap_accum += maxf(0.0, dt)
	if _snap_accum < snap_interval:
		return
	# 只追一帧：掉帧时不要一次补发一堆旧快照（快照只发结果，旧的结果没有意义）。
	_snap_accum = fmod(_snap_accum, snap_interval)
	send_snapshot()


func send_snapshot() -> void:
	if world == null or transport == null:
		return
	# ★ 背压：网络慢时旧快照已经在出站缓冲里排队，继续塞只会把延迟越拖越大。
	#   快照是**全量结果** ⇒ 跳过这一帧，下一帧直接发最新状态（不需要补发旧帧）。
	if snap_buffer_limit > 0 and transport.has_method("buffered_amount"):
		if int(transport.buffered_amount()) > snap_buffer_limit:
			snapshots_skipped += 1
			return
	_send("snap", {"snap": SnapshotRes.to_snapshot(world)}, true)


## 把 tick 产生的事件发给客机（对象引用由 event_codec 换成 id / 建筑 key）。
func send_events(events: Array) -> void:
	if world == null or transport == null or events.is_empty():
		return
	var items: Array = EventCodecRes.encode_items(world, events)
	if items.is_empty():
		return
	_send("event", {"items": items})


func send_bye(reason: String = "host_left") -> void:
	_send("bye", {"reason": reason})


func _send(t: String, body: Dictionary, unreliable: bool = false) -> void:
	if transport == null:
		return
	_seq += 1
	var text := ProtocolRes.encode(ProtocolRes.make(t, _seq, body))
	if unreliable:
		transport.send_unreliable(text)
	else:
		transport.send_text(text)


func _on_message(text: String) -> void:
	var res: Dictionary = ProtocolRes.decode(text)
	if not bool(res.get("ok", false)):
		command_rejected.emit(String(res.get("error", "protocol")))
		return
	var msg: Dictionary = res["msg"]
	var t := String(msg.get("t", ""))
	match t:
		"cmd":
			_handle_command(msg)
		"bye":
			closed.emit(String((msg.get("body", {}) as Dictionary).get("reason", "guest_left")))
		_:
			# 房主只处理客机上行的两种消息；其余静默丢弃（中继 / 大厅消息在别处）。
			pass


func _handle_command(msg: Dictionary) -> void:
	if world == null or cfg == null:
		command_rejected.emit("no_world")
		return
	var body: Dictionary = msg.get("body", {})
	var by := String(body.get("by", ""))
	if by == "" or by != guest_seat:
		command_rejected.emit("seat")
		return
	var seq := int(msg.get("seq", 0))
	if seq <= _last_cmd_seq:
		command_rejected.emit("seq")
		return
	_last_cmd_seq = seq

	var raw: Variant = body.get("cmd", null)
	if typeof(raw) != TYPE_DICTIONARY:
		command_rejected.emit("cmd")
		return
	var cmd: Dictionary = (raw as Dictionary).duplicate(true)
	# ★ 客机必须自己声明 faction；缺省时补 `by`（兼容早期客户端），写了别的就丢。
	if not cmd.has("faction"):
		cmd["faction"] = by
	elif String(cmd.get("faction", "")) != by:
		command_rejected.emit("faction")
		return

	var ok: bool = CommandRes.apply(world, cfg, cmd)
	command_applied.emit(ok, cmd)
