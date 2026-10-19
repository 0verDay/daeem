## test_protocol.gd —— M12.2：消息信封编解码 / 校验 / 房间码。
extends "res://tests/test_case.gd"

const ProtocolRes = preload("res://net/protocol.gd")


func _initialize() -> void:
	_case_name = "test_protocol"
	run_all(Callable(self, "_run"))


func _run() -> void:
	eq(ProtocolRes.VERSION, 1, "协议版本 1")
	ok(ProtocolRes.BUILD != "", "有构建标识（握手用）")

	var msg := ProtocolRes.make("cmd", 7, {"by": "F2", "cmd": {"kind": "stop"}})
	eq(int(msg["v"]), 1, "信封 v=1")
	eq(String(msg["t"]), "cmd", "信封 t")
	eq(int(msg["seq"]), 7, "信封 seq")
	ok(int(msg["ts"]) > 0, "信封带时间戳")

	var text := ProtocolRes.encode(msg)
	var back := ProtocolRes.decode(text)
	ok(bool(back.get("ok", false)), "★ 编码 → 解码成功")
	if bool(back.get("ok", false)):
		var m: Dictionary = back["msg"]
		eq(String(m["t"]), "cmd", "往返后类型不变")
		eq(int(m["seq"]), 7, "往返后序号不变")
		eq(String((m["body"] as Dictionary)["by"]), "F2", "往返后 body 不变")

	ok(not bool(ProtocolRes.decode("not json").get("ok", true)), "坏 JSON → 拒")
	var bad_ver := ProtocolRes.make("cmd", 1, {})
	bad_ver["v"] = 999
	ok(not bool(ProtocolRes.decode(JSON.stringify(bad_ver)).get("ok", true)), "版本不符 → 拒")
	var no_type := ProtocolRes.make("", 1, {})
	ok(not bool(ProtocolRes.decode(JSON.stringify(no_type)).get("ok", true)), "缺类型 → 拒")
	var no_body := {"v": 1, "t": "cmd", "seq": 1, "ts": 0}
	ok(not bool(ProtocolRes.decode(JSON.stringify(no_body)).get("ok", true)), "缺 body → 拒")

	ok(ProtocolRes.valid_room_code("ABC234"), "★ 合法房间码 ABC234")
	ok(ProtocolRes.valid_room_code("abc234"), "允许小写（规范化后合法）")
	eq(ProtocolRes.normalize_room_code(" abc234 "), "ABC234", "房间码去空白 / 转大写")
	ok(not ProtocolRes.valid_room_code("ABC01O"), "★ 去掉易混的 0/O/1/I")
	ok(not ProtocolRes.valid_room_code("ABC23"), "长度不对 → 拒")
