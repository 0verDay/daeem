## room_directory.gd —— 合作大厅的**房间列表**（读中继现有的 `GET /rooms`）。
##
## 为什么走 HTTP 而不是新加 WS 消息：
##   `server/daeem_relay.py` 已经提供 `GET /rooms`，客户端用 Godot 自带 `HTTPRequest`
##   就能拿列表；不需要给中继加协议、也不需要长连接推送。进大厅 / 点刷新 / 建房 /
##   加入 / 退出后各拉一次，LOBBY 状态每 2 秒再拉一次即可。
##
## ★ 本文件只做**纯函数**（URL 转换 + JSON 解析），不建 Node、不碰网络，
##   所以可以无头测试。真正的请求在 `view/coop_lobby.gd`。
extends RefCounted


## 把 `ws://host:port/ws` 转成 `http://host:port/rooms`；`wss://` 同理转 `https://`。
## 认不出的 URL 返回空串（调用方跳过房间列表，不影响建房 / 加入）。
static func http_url_from_ws(ws_url: String) -> String:
	var s := ws_url.strip_edges()
	var scheme := ""
	var rest := ""
	if s.begins_with("wss://"):
		scheme = "https://"
		rest = s.substr(6)
	elif s.begins_with("ws://"):
		scheme = "http://"
		rest = s.substr(5)
	else:
		return ""
	if rest == "":
		return ""
	# 去掉 query / fragment（/rooms 不需要它们）
	var cut := rest.find("?")
	if cut < 0:
		cut = rest.find("#")
	if cut >= 0:
		rest = rest.substr(0, cut)
	if rest == "":
		return ""
	var slash := rest.find("/")
	var authority := rest if slash < 0 else rest.substr(0, slash)
	var path := "" if slash < 0 else rest.substr(slash)
	if authority == "":
		return ""
	if path == "" or path == "/":
		path = "/rooms"
	elif path.ends_with("/ws"):
		path = path.substr(0, path.length() - 3) + "/rooms"
	elif path.ends_with("/ws/"):
		path = path.substr(0, path.length() - 4) + "/rooms"
	else:
		path = path.rstrip("/") + "/rooms"
	return scheme + authority + path


## 中继 `/rooms` 的 JSON → 房间数组（稳定按房间码排序）。
##
## 每项：`{code, status, label, joinable}`
##   · `lobby`   → 等待中，可加入
##   · `full` / `ready` → 已满（有客机 / 双方已准备），不可加入
##   · `playing` → 游戏中
##   · 未知状态  → 原样显示，不可加入
## 解析失败 / 不是对象 → 空数组（不冒泡）。
static func parse_rooms(text: String) -> Array:
	var out: Array = []
	var data: Variant = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return out
	var raw: Variant = (data as Dictionary).get("rooms", null)
	if typeof(raw) != TYPE_ARRAY:
		return out
	for item in (raw as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		var code := String(d.get("code", "")).strip_edges()
		if code == "":
			continue
		var status := String(d.get("status", "")).strip_edges().to_lower()
		out.append({
			"code": code,
			"status": status,
			"label": status_label(status),
			"joinable": status == "lobby",
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["code"]) < String(b["code"]))
	return out


static func status_label(status: String) -> String:
	match status:
		"lobby":
			return "等待中"
		"full", "ready":
			return "已满"
		"playing":
			return "游戏中"
		_:
			return "未知"


## 从列表里按房间码找一项（找不到返回空字典）。
static func find_room(rooms: Array, code: String) -> Dictionary:
	for item in rooms:
		if typeof(item) == TYPE_DICTIONARY and String((item as Dictionary).get("code", "")) == code:
			return item
	return {}
