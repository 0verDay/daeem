## client_session.gd —— 客机侧会话：上行命令、下行快照 / 事件。
##
## 客机**不 tick、不跑 AI、不判胜负**（房主权威）：
##   · 本机输入 → `send_command()` → 房主执行；
##   · 收到 `snap` → `snapshot.apply_snapshot()` → `world.refresh_after_snapshot()`；
##   · 收到 `event` → 解回对象引用，交给 view 的同一套事件消费。
##
## ★ 这里的 world 是「用同一份地图 + 关卡数据建出来的空壳」：只被快照写，
##   目的只是让现有 `view/` 原样读它（见 dev_plan_12 3.1）。
extends Node

const ProtocolRes = preload("res://net/protocol.gd")
const SnapshotRes = preload("res://logic/snapshot.gd")
const EventCodecRes = preload("res://net/event_codec.gd")

## 收到房主的 `start`（body 里有 campaign / level_id / level_data / seats / host_seat / guest_seat）。
signal started(payload: Dictionary)
## 一帧快照已应用（view 可以重画 / 清掉死亡选中）。
signal snapshot_applied
## 事件已解回本地对象（交给 game_scene 的 _consume_events）。
signal events_received(events: Array)
## 房主 bye / 协议错误 / 连接断开。
signal closed(reason: String)
signal protocol_error(error: String)

var world = null
var cfg = null
var transport = null
var my_seat: String = ""

var _seq: int = 0
## ★ 快照合并：一帧里可能收到多条（网络抖动 / 客机掉帧）。
##   全量快照只保留**最后一条**——中间帧跳过去，不浪费 apply + 迷雾 / 归属重算。
var _pending_snap: Variant = null
var _has_pending_snap: bool = false
## 诊断计数（不进玩法）。
var snapshots_applied: int = 0
var snapshots_coalesced: int = 0


## 每帧由 game_scene 调：握手推进 / 收消息 / 应用**最新**快照。
func poll() -> void:
	if transport != null:
		transport.poll()
	if not _has_pending_snap:
		return
	var snap: Variant = _pending_snap
	_pending_snap = null
	_has_pending_snap = false
	snapshots_applied += 1
	_apply_snapshot_data(snap)


func setup(p_world, p_cfg, p_transport, p_my_seat: String) -> void:
	world = p_world
	cfg = p_cfg
	transport = p_transport
	my_seat = p_my_seat
	if transport != null and not transport.message.is_connected(_on_message):
		transport.message.connect(_on_message)


## 上行一条命令。@return 这条命令的信封序号（测试 / 排查用）。
func send_command(cmd: Dictionary) -> int:
	if transport == null:
		return 0
	_seq += 1
	var text := ProtocolRes.encode(ProtocolRes.make("cmd", _seq, {
		"by": my_seat,
		"cmd": cmd.duplicate(true),
	}))
	transport.send_text(text)
	return _seq


func send_bye(reason: String = "guest_left") -> void:
	if transport == null:
		return
	_seq += 1
	transport.send_text(ProtocolRes.encode(ProtocolRes.make("bye", _seq, {"reason": reason})))


func _on_message(text: String) -> void:
	var res: Dictionary = ProtocolRes.decode(text)
	if not bool(res.get("ok", false)):
		protocol_error.emit(String(res.get("error", "protocol")))
		return
	var msg: Dictionary = res["msg"]
	var body: Dictionary = msg.get("body", {})
	match String(msg.get("t", "")):
		"start":
			started.emit(body)
		"snap":
			# ★★ 增量快照：同一轮 poll 里可能有多条，**不能只留最后一条** ——
			#    前面的增量里可能有后面不再重复的字段变化（见 `merge_delta`）。
			var new_snap: Variant = body.get("snap", null)
			if typeof(new_snap) != TYPE_DICTIONARY:
				protocol_error.emit("snapshot")
				return
			if _has_pending_snap and typeof(_pending_snap) == TYPE_DICTIONARY:
				_pending_snap = SnapshotRes.merge_delta(_pending_snap, new_snap)
				snapshots_coalesced += 1
			else:
				_pending_snap = new_snap
			_has_pending_snap = true
		"event":
			_apply_events(body)
		"bye":
			# bye = 这一局结束，别再应用一条迟到的快照。
			_pending_snap = null
			_has_pending_snap = false
			closed.emit(String(body.get("reason", "host_left")))
		_:
			pass


func _apply_snapshot_data(snap: Variant) -> void:
	if world == null or cfg == null:
		return
	if typeof(snap) != TYPE_DICTIONARY:
		protocol_error.emit("snapshot")
		return
	SnapshotRes.apply_snapshot(world, cfg, snap)
	# ★ 客机不 tick：迷雾 / 归属 / 科技加成这些派生数据必须在这里补一遍。
	world.refresh_after_snapshot()
	snapshot_applied.emit()


func _apply_events(body: Dictionary) -> void:
	if world == null:
		return
	var items: Variant = body.get("items", [])
	if typeof(items) != TYPE_ARRAY:
		protocol_error.emit("events")
		return
	events_received.emit(EventCodecRes.decode_items(world, items))
