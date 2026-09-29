extends RefCounted
##
## map_library.gd —— ★ 开场主界面的**地图选择条**：扫描 `data/maps/` 列出所有地图。
##
## 需求原文：「在其上方加一个选择条，可以在其中选择地图，目前仅有一个地图，
##           但后续如果有新的地图，游戏会根据地图目录下的文件自动给出新的选项」。
##
## ★★ 目录约定（一个地图一个目录，见 docs/architecture.md）：
##
##     data/maps/<id>/map.json        ← id = 目录名
##
##   扫描规则（`list_maps()`）：
##     1. 只认 `MAPS_DIR`（`res://data/maps`）下的**一级子目录**，目录名就是地图的 id；
##     2. 每个目录里找一张地图 JSON，候选顺序：`map.json` → `<目录名>.json` → 目录里
##        任一 `*.json`（按文件名排序取第一个）。三个都没有 → 这个目录被跳过；
##     3. 解析失败（不是合法 JSON / 不是对象）→ 同样跳过，**不冒泡**：
##        一张图写坏了不该让整条选择条都空掉，更不该让主界面开不出来；
##     4. 显示名优先读地图 JSON 里的 `name` 字段，没有 / 是空串 → 退回目录名。
##        所以「加一张新图」= 往 data/maps/ 下放一个新目录，**不改任何代码、不改配置**。
##
## ★ 选项顺序按**目录名**（不区分大小写）排，稳定可预期 ——
##   目录的枚举顺序在不同文件系统上不一样，直接用会让「第一项」飘。
##
## ★★ `placeholder: true` 的图是**占位图**（只为验证「选项是扫出来的」而存在）：
##    它在选择条上照样是一个选项，但 `default_map_path()`（= 不选就按 test 时进的那张）
##    会**跳过**它。理由见那个函数的注释：加一张测试图不该把默认局换掉。
##
## ★ 每项的形状（view/start_screen.gd 直接拿去建选项）：
##     { "id": String, "name": String, "path": String, "placeholder": bool }
##
## ⚠️ 跨文件引用只用**自己文件里的 preload 常量**：命令行 `--script` 下全局 class_name
##    表不可用，写 `GridRes` / `Config` 作类型会直接 Parse Error（见 docs/pitfalls.md 第五节）。
##
## ⚠️ 本文件**只读文件、不建 world**：地图是不是真的能开局由 `logic/map_data.gd` 说了算
##    （选项列表不该因为一张图有毛病就少一项 —— 玩家选中它时再报错更好查）。
##

## 地图根目录：一个地图一个子目录（目录名 = 地图 id）。
const MAPS_DIR := "res://data/maps"

## 每个地图目录里首选的文件名（其次 `<目录名>.json`，最后任一 *.json）。
const MAP_FILE_NAME := "map.json"

## 兜底路径：`data/maps/` 下一个目录都没有时（或者被谁删了）用它。
## ★ 与 `logic/config.gd` 的 `DEFAULT_MAP_PATH`、`view/game_scene.gd` 的 `MAP_PATH`
##   是同一个值：正常路径永远是扫描结果，这个常量只在「地图目录空了」时兜底。
const FALLBACK_MAP_PATH := "res://data/maps/frontier/map.json"

## 地图 JSON 里那几个字段（`id` 只是写给人看的；`name` / `placeholder` 有实际用途）。
const KEY_ID := "id"
const KEY_NAME := "name"
## `placeholder: true` = 这张图只为测试「选项生成」而存在，`default_map_path()` 会跳过它。
const KEY_PLACEHOLDER := "placeholder"


## 扫描地图目录，返回按目录名排序的选项表。
##
## @return Array[Dictionary] 每项 `{"id": String, "name": String, "path": String}`；
##         一个都没有时返回**空数组**（调用方自己决定怎么兜底）。
static func list_maps() -> Array:
	var out: Array = []
	var dir := DirAccess.open(MAPS_DIR)
	if dir == null:
		# 目录不存在 / 打不开：不是错误路径（比如还没建任何地图），安静返回空表。
		return out

	var names: Array = []
	for sub in dir.get_directories():
		names.append(String(sub))
	names.sort_custom(func(a: String, b: String) -> bool:
		return a.to_lower() < b.to_lower())

	for sub in names:
		var folder := "%s/%s" % [MAPS_DIR, sub]
		var path := find_map_file(folder, sub)
		if path == "":
			continue
		out.append({
			"id": sub,
			"name": display_name(path, sub),
			"path": path,
			# ★ 占位图标记（见 default_map_path）：选择条上它照样是一个选项，
			#   只是「没人选时默认进哪张」会跳过它。
			"placeholder": is_placeholder(path),
		})
	return out


## 在某个地图目录里找那张地图 JSON。找不到返回 ""。
##
## 候选顺序（先后有别，别改成「随便挑一个」）：map.json → <目录名>.json → 任一 *.json。
static func find_map_file(folder: String, folder_name: String) -> String:
	var prefer := "%s/%s" % [folder, MAP_FILE_NAME]
	if FileAccess.file_exists(prefer):
		return prefer
	var named := "%s/%s.json" % [folder, folder_name]
	if FileAccess.file_exists(named):
		return named

	var dir := DirAccess.open(folder)
	if dir == null:
		return ""
	var files: Array = []
	for f in dir.get_files():
		var name := String(f)
		# ⚠️ Godot 导出的资源旁边会有 `xxx.json.import` 这类伴随文件；只认 .json 结尾。
		if name.to_lower().ends_with(".json"):
			files.append(name)
	files.sort()
	if files.is_empty():
		return ""
	return "%s/%s" % [folder, String(files[0])]


## 一张地图的显示名：地图 JSON 里的 `name` → 空串则退回目录名。
##
## ⚠️ 文件不存在 / 不是合法 JSON / `name` 不是字符串，一律**退回目录名**而不是报错：
##    显示名只影响下拉框上的一行字，不值得为它挡住整局游戏。
static func display_name(path: String, fallback: String) -> String:
	var data: Variant = read_json(path)
	if typeof(data) != TYPE_DICTIONARY:
		return fallback
	var value: Variant = (data as Dictionary).get(KEY_NAME, null)
	if typeof(value) == TYPE_STRING:
		var text := String(value).strip_edges()
		if text != "":
			return text
	return fallback


## 一张地图在文件里写的 id（写错 / 没写都返回空串）。
##
## ★ 目前**不用**它做任何判定（目录名才是 id，见文件头）：留着给「以后有地图列表 /
##   存档记录玩了哪张图」这类用途 —— 那时不该让「目录改名」把存档里的记录全打断。
static func declared_id(path: String) -> String:
	var data: Variant = read_json(path)
	if typeof(data) != TYPE_DICTIONARY:
		return ""
	var value: Variant = (data as Dictionary).get(KEY_ID, null)
	if typeof(value) == TYPE_STRING:
		return String(value).strip_edges()
	return ""


## 进游戏时用哪张图（`game_scene.start()` 的默认值 / 主界面下拉框的初始选中项）。
##
## ★ 规则：扫描结果里**第一张不是占位图的**（= 目录名最小的正式图，稳定）；
##   全是占位图 → 第一张；一张都没有 → `FALLBACK_MAP_PATH`。
##
## ★★ 为什么要把占位图排除掉：`data/maps/arena/` 那种图是**为测试选项生成逻辑**而存在的
##    （它的地形 / 区划根本没调过平衡）。选择条上它当然该出现（那正是要验的东西），
##    但「不选就按 test」默认进的**不该**是它 —— 否则加一张测试图就把默认局换掉了。
##    判据写在图自己身上（`placeholder: true`），不是在这里列白名单：
##    地图目录一变，这个函数不需要跟着改。
##
## ⚠️ 这里**不读 config**：启动路径上多一次 JSON 解析不值得，而且「默认地图是哪张」
##    本来就该由目录内容决定（与选择条同一个来源）。
static func default_map_path() -> String:
	var maps := list_maps()
	if maps.is_empty():
		return FALLBACK_MAP_PATH
	for item in maps:
		if not bool((item as Dictionary).get("placeholder", false)):
			return String((item as Dictionary)["path"])
	return String((maps[0] as Dictionary)["path"])


## 这张图是不是**占位图**（`placeholder: true`）。
##
## 用途只有一处：`default_map_path()` 跳过它（见那里）。缺字段 / 不是 true → 不是占位图。
static func is_placeholder(path: String) -> bool:
	var data: Variant = read_json(path)
	if typeof(data) != TYPE_DICTIONARY:
		return false
	return bool((data as Dictionary).get(KEY_PLACEHOLDER, false))


## 把 JSON 文件读成 Variant（读不到 / 解析不了都返回 null，由调用方兜底）。
static func read_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	return JSON.parse_string(text)


##
## 地图的 `name` / `id` 字段只是**给选择条读的**：`logic/map_data.gd` 不认识它们，
## 也不会因为多这两个字段而报错（它只挑自己认识的键）。
##

