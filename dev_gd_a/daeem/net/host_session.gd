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
const FactionRes = preload("res://logic/faction.gd")

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
## ★★ 2026.10.27：默认从 1 MiB 降到 64 KiB —— 移动端链路（约 0.3~0.6 MB/s）下
##    1 MiB 的积压 = 客机落后 2~3 秒（实测），这是「移动端联机严重不同步」的根因。
var snap_buffer_limit: int = 64 * 1024
## 因背压跳过的快照数（诊断用；不参与玩法）。
var snapshots_skipped: int = 0
## 每隔多少条快照发一次**完整关键帧**（0 = 只发第一次）。
## 增量快照相对关键帧累积变化；关键帧是丢帧 / 版本边界时的自愈点（默认 10 秒 @30Hz）。
var snap_keyframe_every: int = 300
## ★★ 2026.10.27：**客机那一方**（`side_of(guest_seat)`）。快照按它的视野过滤单位，
##    空串 = 不过滤（单人 / 观战 / 还没分配席位）。见 snapshot.to_snapshot 的说明。
var viewer_side: String = ""

## ★★ 2026.10.27（本轮）：**每秒快照字节预算**（0 = 不限）。
##
## 为什么需要它（实测）：`snap_buffer_limit` 那条背压看的是
## `WebSocketPeer.get_current_outbound_buffered_amount()` —— 那是**本机 socket 的**
## 积压。字节一旦交给内核 / 中继，这一侧就归零了，而真正的队列在**中继和手机上**。
## 于是带宽不够时背压永远不触发，快照照旧按 30Hz 往外推，队列在中继里越堆越长，
## 实测就是「同步慢了几秒」。
##
## 这条预算不看任何人报的缓冲，只看**我们自己这一秒推了多少字节**：
## 超了就跳过这一帧快照（下一帧直接发最新状态，旧帧没有补发的意义）。
## ⇒ 吞吐被硬性夹在预算内，延迟有上界，与链路 / 中继 / 平台都无关。
##
## 实测（dscj，256 单位）：单条增量快照 **26.6 KB**。30Hz = 0.78 MB/s，
## 而移动端链路约 0.3~0.6 MB/s ⇒ 必然堆积。默认 256 KB/s 下实际约 9~10 快照/秒，
## 延迟从「几秒」回到「一百多毫秒」。
var snap_budget_bytes: int = 256 * 1024
## 滑动窗口（1 秒）：窗口起点 + 本窗口已发字节；`_last_snap_bytes` 用来预估下一条。
var _snap_win_start_ms: int = 0
var _snap_win_bytes: int = 0
var _last_snap_bytes: int = 0
## ★★ 自适应预算的反馈：本窗口是否撞到过积压 / 跳过了几条。
var _congested_seen: bool = false
var _skips_in_window: int = 0
## 预算的上下限（`net.snapshot_budget_min_kb` / `_max_kb`）。好链路会自己爬到上限。
var snap_budget_min_bytes: int = 128 * 1024
var snap_budget_max_bytes: int = 1024 * 1024
var snap_budget_adaptive: bool = true
## 「一点积压就算拥塞」的门槛：正常空链路是 0，几百字节都算异常。
const CONGEST_BYTES := 8 * 1024


## ★★ 每秒结算一次：按上一秒的反馈调预算。
##
## 为什么要有它（用户实测：384 KB/s 固定预算下「还是太跳跃」）：
##   固定预算对**最差链路**是安全的，对好链路却是浪费 —— 家里 WiFi 明明能跑 2 MB/s，
##   却只发 17 条/秒。而延迟几乎完全由「快照频率」决定。
## 反馈信号：`buffered_amount()`。它虽然看不到中继/手机侧的队列（见上），
##   但**链路真跟不上时本机 socket 会先积压**，所以它是个滞后但有效的拥塞信号。
##   加：窗口内一条没跳过（说明预算没成为瓶颈）也是「还能再快」的证据。
func _adapt_budget() -> void:
	if not snap_budget_adaptive or snap_budget_bytes <= 0:
		return
	if _congested_seen:
		# 拥塞：退 30%（快，别让队列堆起来）
		snap_budget_bytes = maxi(snap_budget_min_bytes, int(float(snap_budget_bytes) * 0.7))
		return
	# 没拥塞、又一直在跳帧 ⇒ 预算是瓶颈 ⇒ 涨 25%
	if _skips_in_window > 0:
		snap_budget_bytes = mini(snap_budget_max_bytes, int(float(snap_budget_bytes) * 1.25))

var _seq: int = 0
var _last_cmd_seq: int = 0
var _snap_accum: float = 0.0
## ★★ 增量快照的基准：单位 id → 上一次关键帧时的完整字段字典。
##    只在**真的发出去**的快照上推进（背压跳过时不调用 `to_snapshot`）。
var _snap_delta: Dictionary = {}
var _snap_count: int = 0


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
		var limit_kb: float = float(cfg.num("net.snapshot_buffer_limit_kb", 64.0))
		snap_buffer_limit = int(maxf(0.0, limit_kb) * 1024.0)
		snap_keyframe_every = maxi(0, int(cfg.num("net.snapshot_keyframe_every", 300.0)))
		snap_budget_bytes = int(maxf(0.0,
			float(cfg.num("net.snapshot_budget_kb_per_sec", 256.0)) * 1024.0))
		snap_budget_adaptive = bool(cfg.num("net.snapshot_budget_adaptive", 1.0) != 0.0)
		snap_budget_min_bytes = int(maxf(16.0,
			float(cfg.num("net.snapshot_budget_min_kb", 128.0)) * 1024.0))
		snap_budget_max_bytes = int(maxf(64.0,
			float(cfg.num("net.snapshot_budget_max_kb", 1024.0)) * 1024.0))
		if snap_budget_max_bytes < snap_budget_min_bytes:
			snap_budget_max_bytes = snap_budget_min_bytes
		_snap_win_start_ms = Time.get_ticks_msec()
		_snap_win_bytes = 0
		_last_snap_bytes = 0
		snapshots_skipped = 0
		viewer_side = String(FactionRes.side_of(p_guest_seat)) if p_guest_seat != "" else ""
		_snap_delta.clear()
		_snap_count = 0
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


func send_snapshot(force: bool = false) -> void:
	if world == null or transport == null:
		return
	# ★ 背压：网络慢时旧快照已经在出站缓冲里排队，继续塞只会把延迟越拖越大。
	#   快照是**全量结果** ⇒ 跳过这一帧，下一帧直接发最新状态（不需要补发旧帧）。
	#   ⚠️ 这一条只看得到**本机 socket** 的积压（见 `snap_budget_bytes` 的说明），
	#      真正起作用的是下面的每秒字节预算。
	var buffered: int = 0
	if transport.has_method("buffered_amount"):
		buffered = int(transport.buffered_amount())
	# ★★ 窗口结算 / 自适应**必须排在任何 return 之前**。
	#    踩过的坑：原来它排在背压 `return` 之后，于是「一直拥塞 ⇒ 每条都提前返回 ⇒
	#    结算永远不跑 ⇒ 预算永远不降」，正好是要它降的那种情况失效。
	#    （实测：拥塞 6 秒预算纹丝不动，恢复后才莫名其妙掉一档。）
	var now_ms: int = Time.get_ticks_msec()
	if now_ms - _snap_win_start_ms >= 1000:
		if buffered > CONGEST_BYTES:
			_congested_seen = true
		_adapt_budget()
		_snap_win_start_ms = now_ms
		_snap_win_bytes = 0
		_skips_in_window = 0
		_congested_seen = false
	if snap_buffer_limit > 0 and buffered > snap_buffer_limit:
		snapshots_skipped += 1
		_congested_seen = true
		_skips_in_window += 1
		return
	# ★★ 拥塞信号：socket 里开始积压 = 链路跟不上（正常应该接近 0）。
	#    这是自适应预算唯一可信的反馈 —— 它比 `snap_buffer_limit` 灵敏得多，
	#    因为门槛设在「一点积压就算」而不是「塞满 64KB 才拦」。
	if buffered > CONGEST_BYTES:
		_congested_seen = true
	# 第一条（关键帧）总是发：否则客机永远起不来。
	var first: bool = _snap_count <= 0
	if not first and not force and snap_budget_bytes > 0 \
			and _snap_win_bytes + _last_snap_bytes > snap_budget_bytes:
		snapshots_skipped += 1
		_skips_in_window += 1
		return
	# ★★ 增量快照：首次与每隔 `snap_keyframe_every` 条发完整关键帧，其余只发变化字段。
	#    跳过的帧**不推进** `_snap_count` / `_snap_delta` —— 下一次发出去的仍相对同一个基准。
	_snap_count += 1
	var keyframe: bool = _snap_count <= 1 \
		or (snap_keyframe_every > 0 and _snap_count % snap_keyframe_every == 0)
	var snap: Dictionary = SnapshotRes.to_snapshot(world, _snap_delta, keyframe, viewer_side)
	var sent: int = _send("snap", {"snap": snap}, true)
	if sent > 0:
		_last_snap_bytes = sent
		_snap_win_bytes += sent


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


## @return 这条消息的**字节数**（会话层用它算每秒预算；发送失败返回 0）。
func _send(t: String, body: Dictionary, unreliable: bool = false) -> int:
	if transport == null:
		return 0
	_seq += 1
	var text := ProtocolRes.encode(ProtocolRes.make(t, _seq, body))
	if unreliable:
		transport.send_unreliable(text)
	else:
		transport.send_text(text)
	return text.length()


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
	# ★★ 2026.10.27（手感）：**执行完客机的命令就立刻补发一条快照**。
	#
	# 用户实测：「主机端下命令立刻响应，客机端延迟很高」—— 也就是**指令往返**慢，不是带宽。
	# 原因是原来要等下一条快照（`snap_interval`，预算低时最多 ~110ms）才把结果送回去。
	# 命令本身就是「结果变了」的确定信号，没理由再等一个节拍。
	# ★ `force = true`：绕过**每秒字节预算**（这是一次性的一条，不会持续超发），
	#   但仍然走 socket 背压 —— 真的拥塞时宁可不发，也别往队列里塞。
	if ok:
		send_snapshot(true)
	command_applied.emit(ok, cmd)
