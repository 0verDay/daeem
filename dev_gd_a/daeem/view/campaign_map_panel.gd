## campaign_map_panel.gd —— 战役地图面板（1280×1080）。
##
## ★★ 一个「真实战役」一面旗：
##   · 遍历 `campaigns_menu.json` 的战役，取每份战役的**第一个真实章节**；
##   · 有真实章节（`campaign_id` + `level_id` 都填了）的才生成旗子，占位战役不画；
##   · 点任意一面旗 → 打开该战役的详情（选阵营 / 进关）。
##   · 战役键序 = 旗子从左到右的顺序；旗子位置见
##     `view/menu_deck_layout.gd` 的 `campaign_flags()`（一排居中，窄屏等比缩小）。
##
## ★ 这里不再有章节栏（I/II/III）：三个测试战役是**独立战役**，不是同一战役下的章节。
extends "res://view/menu_page.gd"

signal flag_pressed(chapter: Dictionary)

const CampaignMenuDbRes = preload("res://logic/campaign_menu_db.gd")
const BannerRes = preload("res://view/menu_banner.gd")

## 每面旗：{campaign: Dictionary, chapter: Dictionary}
var _entries: Array = []
var _flags: Array = []
var _chapter: Dictionary = {}


func setup(p_cfg, p_font: Font) -> void:
	name = "CampaignPanel"
	setup_page(p_cfg, p_font, String(p_cfg.str_val("menu.deck.titles.campaign", "战役")), true)
	_load_data()
	resized.connect(_layout)
	_layout()


func _load_data() -> void:
	_entries = []
	_flags = []
	for raw in CampaignMenuDbRes.load_campaigns():
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var campaign: Dictionary = raw
		var chapter := _first_real_chapter(campaign)
		if chapter.is_empty():
			continue
		_entries.append({"campaign": campaign, "chapter": chapter})
	if _entries.is_empty():
		# 兜底：一份真实战役都没有时，仍显示一面禁用旗（面板不空白）。
		_entries = [{
			"campaign": {"name": "战役#1"},
			"chapter": {"name": "关卡#1", "description": "", "campaign_id": "", "level_id": ""},
		}]
	_chapter = _entries[0]["chapter"]

	for i in _entries.size():
		var entry: Dictionary = _entries[i]
		var chapter2: Dictionary = entry["chapter"]
		var placeholder := CampaignMenuDbRes.is_placeholder_chapter(chapter2)
		var f := BannerRes.new()
		f.name = "CampaignFlag%d" % i
		f.z_index = 6
		add_child(f)
		f.setup(font, "level", String((entry["campaign"] as Dictionary).get("name", "")),
			String(chapter2.get("name", "")))
		f.set_clickable(not placeholder)
		f.pressed.connect(func(): _on_flag_pressed(chapter2))
		_flags.append(f)


## 这一份战役里第一个「指向真实关卡」的章（没有 → 空字典）。
func _first_real_chapter(campaign: Dictionary) -> Dictionary:
	var chapters: Variant = campaign.get("chapters", [])
	if typeof(chapters) != TYPE_ARRAY:
		return {}
	for item in (chapters as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var chapter: Dictionary = item
		if not CampaignMenuDbRes.is_placeholder_chapter(chapter):
			return chapter
	return {}


func _on_flag_pressed(chapter: Dictionary) -> void:
	_chapter = chapter
	flag_pressed.emit(chapter)


func current_chapter() -> Dictionary:
	return _chapter


## 所有旗子（测试与界面用；顺序 = 战役键序）。
func flag_buttons() -> Array:
	return _flags


func _layout() -> void:
	var rects: Array = LayoutRes.campaign_flags(size.x, size.y, _flags.size())
	for i in _flags.size():
		var r: Rect2 = rects[i]
		var f: Control = _flags[i]
		f.position = r.position
		f.size = r.size
