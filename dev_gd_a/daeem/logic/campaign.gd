## campaign.gd —— **战役**：`data/campaigns/<id>/campaign.json` + 它下面那一串关卡。
##
## ★★ 数据契约（与 `dev_gd_a/dev_plan_7.md` 第二节同一份，编辑器与运行时**共同的**口径）：
##
##     data/campaigns/<campaign_id>/           ← 目录名 = 战役 id（与「一个地图一个目录」同构）
##     ├── campaign.json                       ← 战役元信息 + 关卡顺序
##     └── levels/
##         ├── 01_xxx.json                     ← 文件名的**字典序**只是「levels[] 没写时的兜底顺序」
##         └── 02_yyy.json
##
##   campaign.json 的字段（缺字段都有明确默认值）：
##     name          显示名；缺省 = 目录名
##     description   一句话简介；缺省 ""
##     default_mode  "solo" / "coop"；缺省 "solo"（编辑器「新建关卡」时的默认值）
##     factions[]    这一战的**参展阵营**追加 / 覆盖表（id / name / color / playable）
##     levels[]      **有序**关卡表：{id, file, name}；file 相对战役目录
##     unlock        "in_order"；第一版只有这一种
##
## ★ 本文件**只读**：把数据读进来、把缺字段补齐、把坏数据变成「一条说明」而不是崩，
##   校验（那 16 条）在 `Level.check()` + `Level.merge_over_map()` 里 —— 一个文件管一件事。
##
## ★★ 为什么战役是「有序关卡列表」而不是「一张大地图 + 阶段推进」：
##   一关一份文件才好 diff、才能单关重玩、才能用无头断言一关一关验；
##   而「大地图战役」要求关卡之间持久化（带兵 / 带资源进下一关），与「目前不做存档」直接冲突。
##
## ⚠️ 跨文件引用只用**本文件里的 preload 常量**，不写全局 `class_name`
##    （`--script` 无头跑时全局类名表不可用，见 docs/pitfalls.md 第五节）。
##
## ⚠️ 与 `logic/map_library.gd` 的分工：那个管「地图目录扫描」，这个管「战役目录里的东西」。
##    两个都是 RefCounted、都只读文件 —— 不要互相 import。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")
const LevelRes = preload("res://logic/level.gd")

## 战役根目录：一个战役一个子目录（目录名 = 战役 id）。
const CAMPAIGNS_DIR := "res://data/campaigns"

## 每个战役目录里首选的文件名（其次 `<目录名>.json`，最后任一 *.json —— 与 map_library 同规）。
const CAMPAIGN_FILE_NAME := "campaign.json"

## 关卡文件的默认目录（`levels[]` 里写了 file 就以它为准）。
const LEVELS_SUBDIR := "levels"

## `unlock` 目前只有这一种取值。
const UNLOCK_IN_ORDER := "in_order"

## `default_mode` 的两种取值。
const MODE_SOLO := "solo"
const MODE_COOP := "coop"


## 载入一个战役（`campaign.json` + **全部关卡**）。
##
## ⚠️ 关卡是**立即全部载入**的：一个战役几关而已，而「关卡列表要显示每关的目标一句话 /
##    模式」——懒载入会让界面为了列个表把每一关都读一遍，反而更绕。
##    真正的「选哪一关开打」是另一件事（`world.create_from_level`）。
##
## @param dir_path 战役目录的 res:// 路径（或任意绝对路径）
## @param cfg      全局配置（`logic/config.gd` 的 Config）。★ 建议显式传：
##                 关卡里要载入地图，而地图需要 config（网格尺寸 / 阵营表 / 地形代价）。
##                 省略时本函数自己按 `res://data/config.json` 载一份
##                 （与 `logic/campaign_library.gd` / `logic/map_data.gd` 同一条兜底：
##                  少传一个参数不该表现为「地图载入时对着 null 取 cols」——
##                  那个错看起来像「战役数据坏了」，排查方向完全错）。
## @return Campaign 或 **null**（目录 / campaign.json 读不出来，或 levels[] 一项都没有）
static func load_campaign(dir_path: String, cfg: ConfigRes = null) -> RefCounted:
	var dir := dir_path.strip_edges()
	while dir.ends_with("/"):
		dir = dir.substr(0, dir.length() - 1)
	if dir == "":
		push_error("Campaign.load_campaign：目录为空")
		return null

	# ★ cfg 的兜底（见 docstring 最后一段）：**只在这一处**判定，关卡那边一路传下去。
	var use_cfg := cfg
	if use_cfg == null:
		use_cfg = ConfigRes.load_default()

	var file := _find_campaign_file(dir)
	if file == "":
		push_error("战役目录里找不到 campaign.json：%s" % dir)
		return null
	var data: Variant = _read_json(file)
	if typeof(data) != TYPE_DICTIONARY:
		push_error("campaign.json 不是合法 JSON 对象：%s" % file)
		return null

	var c = new()
	c.dir_path = dir
	c.path = file
	c.id = dir.get_file()
	c.raw = data
	c.load_error = ""
	c.name = _text((data as Dictionary).get("name", ""), c.id)
	c.description = _text((data as Dictionary).get("description", ""), "")
	c.default_mode = _mode((data as Dictionary).get("default_mode", ""), MODE_SOLO)
	c.unlock = _text((data as Dictionary).get("unlock", ""), UNLOCK_IN_ORDER)
	if c.unlock != UNLOCK_IN_ORDER:
		# 第一版只有顺序解锁。写别的值不是「错误」，但要留一条痕迹（界面按顺序解锁）。
		c.load_error = "unlock 只支持 %s（读到的是「%s」），已按顺序解锁处理" % [UNLOCK_IN_ORDER, c.unlock]
		c.unlock = UNLOCK_IN_ORDER
	c.faction_meta = _read_faction_meta((data as Dictionary).get("factions", null))
	c.levels = _read_levels(c, (data as Dictionary).get("levels", null), use_cfg)
	if c.levels.is_empty():
		push_error("战役「%s」一关都没有（levels[] 空，或每一关都读不出来）" % c.id)
		return null
	return c


# ------------------------------------------------------------------
# 实例：一份战役的只读视图
# ------------------------------------------------------------------

## 战役 id = **目录名**（与地图同一条约定：目录名才是 id，JSON 里写的 id 只是写给人看的）
var id: String = ""
## 显示名：campaign.json 的 `name` → 空 / 缺字段 → 目录名
var name: String = ""
## 一句话简介（可空）
var description: String = ""
## "solo" / "coop"：编辑器「新建关卡」时的默认值
var default_mode: String = MODE_SOLO
## 战役目录（res:// 形式，结尾不带斜杠）
var dir_path: String = ""
## campaign.json 自身的路径
var path: String = ""
## `unlock`（第一版恒为 "in_order"）
var unlock: String = UNLOCK_IN_ORDER
## 参展阵营元信息（**追加 / 覆盖**地图的 `factions`；`playable` 决定「玩家能选谁」）：
## 每项 {id: String, name: String, color: String, playable: bool}
var faction_meta: Array = []
## 有序关卡表（**以 campaign.json 的 levels[] 为准**，不是文件名字典序）：每项 Level
var levels: Array = []
## 载入时的说明（不是错误：正常载入是 ""）
var load_error: String = ""
## campaign.json 的原始字典（编辑器 / 往返测试要它）
var raw: Dictionary = {}


## 按 id 取一关（没有返回 null）。
func level(level_id: String) -> Variant:
	for lv in levels:
		if String((lv as RefCounted).id) == level_id:
			return lv
	return null


## 第 n 关（0 起；越界返回 null）。深链 / 「下一关」按钮用。
func level_at(index: int) -> Variant:
	if index < 0 or index >= levels.size():
		return null
	return levels[index]


## 这一战里**可玩**的阵营 id（campaign.json 的 `playable: true` 那些，按声明顺序）。
func playable_ids() -> Array:
	var out: Array = []
	for e in faction_meta:
		if bool((e as Dictionary).get("playable", false)):
			out.append(String((e as Dictionary)["id"]))
	return out


func level_count() -> int:
	return levels.size()


func mode_label() -> String:
	return "双人合作" if default_mode == MODE_COOP else "单人"


# ------------------------------------------------------------------
# 读（宽容：坏数据 → 一条说明，不冒泡）
# ------------------------------------------------------------------

## 在战役目录里找那份元信息 JSON。找不到返回 ""。
##
## 候选顺序（与 `map_library.find_map_file` 同规）：campaign.json → <目录名>.json → 任一 *.json。
static func _find_campaign_file(dir: String) -> String:
	var prefer := "%s/%s" % [dir, CAMPAIGN_FILE_NAME]
	if FileAccess.file_exists(prefer):
		return prefer
	var named := "%s/%s.json" % [dir, dir.get_file()]
	if FileAccess.file_exists(named):
		return named
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	var files: Array = []
	for f in d.get_files():
		var n := String(f)
		# ⚠️ 导出资源旁边会有 `xxx.json.import` 这类伴随文件：只认 .json 结尾。
		if n.to_lower().ends_with(".json"):
			files.append(n)
	files.sort()
	if files.is_empty():
		return ""
	return "%s/%s" % [dir, String(files[0])]


## `factions[]`：每项至少要有一个 id；其余字段缺就补默认值。
static func _read_faction_meta(v: Variant) -> Array:
	var out: Array = []
	if typeof(v) != TYPE_ARRAY:
		return out
	for item in (v as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		var fid := String(d.get("id", "")).strip_edges()
		if fid == "":
			continue
		out.append({
			"id": fid,
			"name": _text(d.get("name", ""), fid),
			"color": _text(d.get("color", ""), ""),
			"playable": bool(d.get("playable", false)),
		})
	return out


## `levels[]`：**顺序就是这一串**。读不出来的那一关**跳过**（但它会被记进 load_error）。
##
## ★ 顺序为什么以 levels[] 为准：文件名排序是「编辑器没写顺序时」的兜底，
##   而真到了「第一章 · 第一关」这种地方，顺序是设计出来的，不该由文件名决定。
## ★ levels[] 缺省（老 / 手写战役）→ 退化成「levels/ 目录下所有 *.json 按文件名排序」。
static func _read_levels(c, v: Variant, cfg: ConfigRes) -> Array:
	var out: Array = []
	var entries: Array = []
	if typeof(v) == TYPE_ARRAY and not (v as Array).is_empty():
		for item in (v as Array):
			if typeof(item) != TYPE_DICTIONARY:
				continue
			var d: Dictionary = item
			var file := String(d.get("file", "")).strip_edges()
			var lid := String(d.get("id", "")).strip_edges()
			if lid == "" and file != "":
				lid = file.get_file().get_basename()
			if file == "" and lid != "":
				file = "%s/%s.json" % [LEVELS_SUBDIR, lid]
			if file == "":
				continue
			entries.append({"id": lid, "file": file, "name": String(d.get("name", "")).strip_edges()})
	else:
		entries = _scan_level_files(c.dir_path)

	var skipped: Array = []
	for e in entries:
		var entry: Dictionary = e
		var lv = LevelRes.load_level(c, String(entry["file"]), cfg)
		if lv == null:
			skipped.append(String(entry["id"]))
			continue
		# levels[] 里写了的 id / name 覆盖关卡文件里的（它就是「列表上显示的那一行」）
		if String(entry["id"]) != "":
			lv.id = String(entry["id"])
		if String(entry["name"]) != "":
			lv.name = String(entry["name"])
		out.append(lv)
	if not skipped.is_empty():
		c.load_error = "有 %d 关读不出来，已跳过：%s" % [skipped.size(), ", ".join(skipped)]
	return out


## `levels[]` 没写时的兜底：扫 `levels/` 目录下所有 *.json，按**文件名排序**。
static func _scan_level_files(dir: String) -> Array:
	var out: Array = []
	var d := DirAccess.open("%s/%s" % [dir, LEVELS_SUBDIR])
	if d == null:
		return out
	var files: Array = []
	for f in d.get_files():
		var n := String(f)
		if n.to_lower().ends_with(".json"):
			files.append(n)
	files.sort()
	for n in files:
		out.append({
			"id": String(n).get_basename(),
			"file": "%s/%s" % [LEVELS_SUBDIR, String(n)],
			"name": "",
		})
	return out


## 字符串字段：缺 / 不是字符串 / 只有空白 → 用兜底值。
static func _text(v: Variant, fallback: String) -> String:
	if typeof(v) == TYPE_STRING:
		var s := String(v).strip_edges()
		if s != "":
			return s
	return fallback


## 模式字段：只认 "solo" / "coop"，别的（含缺字段）→ 兜底。
static func _mode(v: Variant, fallback: String) -> String:
	var s := _text(v, "").to_lower()
	if s == MODE_SOLO or s == MODE_COOP:
		return s
	return fallback


## 把 JSON 文件读成 Variant（读不到 / 解析不了都返回 null，由调用方兜底）。
static func _read_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	return JSON.parse_string(text)
