## campaign_menu_db.gd —— ★ 战役菜单的数据源（读 `data/campaigns_menu.json`）
##
## ★★ 为什么与 `data/campaigns/` **分开**：
##   `data/campaigns/<id>/` 是**能真的进游戏的关卡数据**（`logic/campaign.gd` 读它，
##   `tests/test_campaign*.gd` 大量断言钉着那几份 json）。而菜单还需要「战役#2 / 关卡#3」
##   这种**占位项**——它们不应该为了摆个名字就造一份假关卡。
##   ⇒ 于是另开一份**只给菜单看**的数据：显示名 / 简介 / 关卡名 / 指向哪一关。
##     章节的 `campaign_id` + `level_id` 留空 = 占位关（长按不进入任何东西）。
##     以后接真关卡，只往这两个字段填值，界面一行都不用改。
##
## ★ 本文件是**纯数据**（RefCounted、不碰场景树），与 `logic/map_library.gd` /
##   `logic/campaign_library.gd` 同一层：读盘 + 校验 + 出统一形状，不建节点。
##
## ★ 形状（`view/campaign_map_panel.gd` / `view/campaign_detail_panel.gd` 直接用）：
##   Array[Dictionary]，每项：
##     { "key": String, "name": String, "description": String,
##       "chapters": Array[Dictionary] }
##   章节：
##     { "name": String, "description": String,
##       "campaign_id": String, "level_id": String }
##
## ⚠️ 跨文件引用只用**本文件里的 preload 常量**（`--script` 下全局 class_name 不可用）。
extends RefCounted

## 菜单数据文件（相对工程根）。
const MENU_PATH := "res://data/campaigns_menu.json"

## 读不出来时的兜底：一战役一占位关。
## ★ 宁可显示「战役#1 / 关卡#1」这种明显占位，也不要让整块面板空白 ——
##   空白面板看起来像「界面坏了」，而占位文案一眼就知道「数据没接上」。
const FALLBACK := [{
	"key": "c1",
	"name": "战役#1",
	"description": "占位战役。",
	"chapters": [{"name": "关卡#1", "description": "", "campaign_id": "", "level_id": ""}],
}]


## 读菜单数据。
##
## @param path 数据文件路径（测试可以指到临时文件上）
## @return Array[Dictionary]；**永远不返回空数组**（读不到 / 写坏都退回 FALLBACK）
static func load_campaigns(path: String = MENU_PATH) -> Array:
	var data: Variant = _read_json(path)
	if typeof(data) != TYPE_DICTIONARY:
		return _copy_fallback()
	var raw: Variant = (data as Dictionary).get("campaigns", null)
	if typeof(raw) != TYPE_DICTIONARY:
		return _copy_fallback()

	var out: Array = []
	for key in (raw as Dictionary).keys():
		var entry: Variant = (raw as Dictionary)[key]
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = entry
		out.append({
			"key": String(key),
			"name": _text_or(d.get("display_name", ""), String(key)),
			"description": String(d.get("description", "")),
			"chapters": _parse_chapters(d.get("chapters", [])),
		})
	return out if not out.is_empty() else _copy_fallback()


## 某一项是不是**占位关**（没有指向任何真实的战役 / 关卡）。
static func is_placeholder_chapter(chapter: Dictionary) -> bool:
	return String(chapter.get("campaign_id", "")).strip_edges() == "" \
		or String(chapter.get("level_id", "")).strip_edges() == ""


static func _parse_chapters(raw: Variant) -> Array:
	var out: Array = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for item in (raw as Array):
		if typeof(item) == TYPE_DICTIONARY:
			var d: Dictionary = item
			out.append({
				"name": String(d.get("name", "")),
				"description": String(d.get("description", "")),
				"campaign_id": String(d.get("campaign_id", "")).strip_edges(),
				"level_id": String(d.get("level_id", "")).strip_edges(),
			})
		else:
			# 写成纯字符串也认（`"关卡#1"`），与 nsoc 的宽松读法一致。
			out.append({
				"name": String(item),
				"description": "",
				"campaign_id": "",
				"level_id": "",
			})
	return out


## 显示名兜底：字段没写 / 写成空白 → 用 key 顶上。
static func _text_or(value: Variant, fallback: String) -> String:
	var s := String(value).strip_edges()
	return s if s != "" else fallback


static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	return parsed


## 深拷贝兜底（调用方会往数组 / 字典里塞东西，不能共享同一份常量）。
static func _copy_fallback() -> Array:
	return (FALLBACK as Array).duplicate(true)
