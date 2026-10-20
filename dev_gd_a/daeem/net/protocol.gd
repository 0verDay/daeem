## protocol.gd —— 联机消息的**信封**与校验（纯 RefCounted，无头可测）。
##
## 一条消息 = JSON 对象：
##   {"v":1, "t":"cmd", "seq":7, "ts":<毫秒>, "body":{...}}
##
## ★ 为什么信封单独一层：
##   · 版本 / 类型 / 序号 / 时间戳是**每条消息都有的东西**，不该混进 body；
##   · 中继只看信封就能转发（不 import 游戏逻辑，见 dev_plan_12 3.1）；
##   · `seq` 留给会话层做「同一连接内必须递增」的校验（见 host_session）。
##
## ⚠️ 本文件**只做编解码与格式校验**：不认「谁是房主」、不认快照字段、不碰 socket。
##    那些在 host_session / client_session / snapshot 里。
extends RefCounted

## 协议版本。字段形状一变就要 +1（两端版本不一致时中继会拒绝）。
const VERSION := 1
## 客户端构建标识：协议一改就升（两端不一致时中继会拒绝）。
const BUILD := "coop-m13.1"
const GAME := "daeem"

## 常用消息类型（只是常量，session 仍然按字符串 match）。
const T_HELLO := "hello"
const T_CREATE_ROOM := "create_room"
const T_JOIN_ROOM := "join_room"
const T_ROOM_STATE := "room_state"
const T_READY := "ready"
const T_ROOM_CFG := "room_cfg"
const T_START := "start"
const T_CMD := "cmd"
const T_SNAP := "snap"
const T_EVENT := "event"
const T_PING := "ping"
const T_PONG := "pong"
const T_BYE := "bye"
const T_ERR := "err"


## 造一条带信封的消息。
static func make(t: String, seq: int, body: Dictionary = {}) -> Dictionary:
	return {
		"v": VERSION,
		"t": t,
		"seq": int(seq),
		"ts": Time.get_ticks_msec(),
		"body": body.duplicate(true),
	}


## 编码成一行 JSON（WebSocket 文本帧 / 假连接都发这个）。
static func encode(msg: Dictionary) -> String:
	return JSON.stringify(msg)


## 解码并校验信封。
## @return {"ok": true, "msg": Dictionary} 或 {"ok": false, "error": String}
##
## ⚠️ 错误只给**码**（json / version / type / body），中文提示在界面 / 日志一处翻译。
static func decode(text: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(text) != OK:
		return {"ok": false, "error": "json"}
	var parsed: Variant = json.data
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "error": "json"}
	var msg: Dictionary = parsed
	if int(msg.get("v", 0)) != VERSION:
		return {"ok": false, "error": "version"}
	if String(msg.get("t", "")) == "":
		return {"ok": false, "error": "type"}
	if int(msg.get("seq", -1)) < 0:
		return {"ok": false, "error": "seq"}
	if typeof(msg.get("body", null)) != TYPE_DICTIONARY:
		return {"ok": false, "error": "body"}
	return {"ok": true, "msg": msg}


## 房间码：**6 位数字 0-9**（2026.10.20 大厅键盘只有 1~0 十个数字键）。
## ★ 与 `server/daeem_relay.py` 的 ROOM_ALPHABET 必须一致；旧字母码不再有效。
static func valid_room_code(code: String) -> bool:
	var s := code.strip_edges().to_upper()
	if s.length() != 6:
		return false
	for i in s.length():
		var c := s.substr(i, 1)
		if c < "0" or c > "9":
			return false
	return true


## 把房间码规范化（去空白、转大写）；非法时返回空串。
static func normalize_room_code(code: String) -> String:
	var s := code.strip_edges().to_upper()
	return s if valid_room_code(s) else ""
