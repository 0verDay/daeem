## test_room_directory.gd —— 房间列表的纯函数：ws→http、解析、状态映射、排序。
extends "res://tests/test_case.gd"

const RoomDirectoryRes = preload("res://net/room_directory.gd")


func _initialize() -> void:
	_case_name = "test_room_directory"
	run_all(_cases)


func _cases() -> void:
	eq(RoomDirectoryRes.http_url_from_ws("ws://127.0.0.1:8770/ws"),
		"http://127.0.0.1:8770/rooms", "ws://.../ws → http://.../rooms")
	eq(RoomDirectoryRes.http_url_from_ws("wss://example.test/ws"),
		"https://example.test/rooms", "wss → https")
	eq(RoomDirectoryRes.http_url_from_ws("ws://example.test"),
		"http://example.test/rooms", "没有 path → /rooms")
	eq(RoomDirectoryRes.http_url_from_ws("ws://example.test/relay/ws"),
		"http://example.test/relay/rooms", "保留路径前缀")
	eq(RoomDirectoryRes.http_url_from_ws("ws://example.test/ws?x=1"),
		"http://example.test/rooms", "丢掉 query")
	eq(RoomDirectoryRes.http_url_from_ws("http://example.test/ws"),
		"", "非 ws/wss → 空串（不硬转）")

	var text := JSON.stringify({"ok": true, "rooms": [
		{"code": "222222", "host": true, "guest": true, "status": "full"},
		{"code": "111111", "host": true, "guest": false, "status": "lobby"},
		{"code": "333333", "host": true, "guest": true, "status": "playing"},
		{"code": "444444", "host": true, "guest": true, "status": "ready"},
	]})
	var rooms := RoomDirectoryRes.parse_rooms(text)
	eq(rooms.size(), 4, "★ 解析出 4 个房间")
	eq(String(rooms[0]["code"]), "111111", "★ 按房间码排序")
	eq(String(rooms[0]["label"]), "等待中", "lobby → 等待中")
	eq(bool(rooms[0]["joinable"]), true, "等待中可加入")
	eq(bool(rooms[1]["joinable"]), false, "已满不可加入")
	eq(String(rooms[2]["label"]), "游戏中", "playing → 游戏中")
	eq(String(rooms[3]["label"]), "已满", "ready → 已满（有客机）")

	var found := RoomDirectoryRes.find_room(rooms, "333333")
	eq(String(found.get("status", "")), "playing", "find_room 按码找到")
	ok(RoomDirectoryRes.find_room(rooms, "999999").is_empty(), "找不到 → 空字典")

	eq(RoomDirectoryRes.parse_rooms("not json").size(), 0, "坏 JSON → 空数组")
	eq(RoomDirectoryRes.parse_rooms("{}").size(), 0, "没有 rooms → 空数组")
	eq(RoomDirectoryRes.parse_rooms(JSON.stringify({"rooms": [{"code": ""}]})).size(), 0,
		"空房间码被跳过")
