## campaign_map_panel.gd —— 战役地图面板（1280×1080）。
##
## 本轮只显示 `c1` 的唯一真实关 `main_test → demo/mt`：
##   · 中央一面小型关卡旗帜；
##   · 右侧 I/II/III 章节栏只切换选中高亮，不切地图、不换旗帜；
##   · 点旗帜进入战役详情。
extends "res://view/menu_page.gd"

signal flag_pressed(chapter: Dictionary)
signal chapter_selected(index: int)

const CampaignMenuDbRes = preload("res://logic/campaign_menu_db.gd")
const BannerRes = preload("res://view/menu_banner.gd")

const DEFAULT_ROMANS := ["I", "II", "III"]

var _flag = null
var _rail: Panel = null
var _rail_buttons: Array = []
var _campaigns: Array = []
var _chapters: Array = []
var _chapter: Dictionary = {}
var _selected: int = 0


func setup(p_cfg, p_font: Font) -> void:
	name = "CampaignPanel"
	setup_page(p_cfg, p_font, String(p_cfg.str_val("menu.deck.titles.campaign", "战役")), true)

	_rail = Panel.new()
	_rail.name = "ChapterRail"
	_rail.z_index = 5
	_rail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rail.add_theme_stylebox_override("panel", MenuThemeRes.deck_block())
	add_child(_rail)

	var romans: Array = _string_list("menu.deck.campaign.chapters", DEFAULT_ROMANS)
	for i in romans.size():
		var b := Button.new()
		b.name = "ChapterBtn%d" % i
		b.text = String(romans[i])
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_filter = Control.MOUSE_FILTER_STOP
		if font != null:
			b.add_theme_font_override("font", font)
		b.add_theme_font_size_override("font_size", 34)
		b.pressed.connect(select_chapter.bind(i))
		_rail.add_child(b)
		_rail_buttons.append(b)

	_flag = BannerRes.new()
	_flag.name = "LevelFlag"
	_flag.z_index = 6
	add_child(_flag)

	_load_data()
	resized.connect(_layout)
	_layout()


func _string_list(path: String, fallback: Array) -> Array:
	var v: Variant = cfg.get_path_value(path) if cfg != null else null
	var out: Array = []
	if typeof(v) == TYPE_ARRAY:
		for item in (v as Array):
			var s := String(item).strip_edges()
			if s != "":
				out.append(s)
	return out if not out.is_empty() else fallback


func _load_data() -> void:
	_campaigns = CampaignMenuDbRes.load_campaigns()
	_chapters = []
	if not _campaigns.is_empty():
		var raw: Variant = (_campaigns[0] as Dictionary).get("chapters", [])
		if typeof(raw) == TYPE_ARRAY:
			for item in (raw as Array):
				if typeof(item) == TYPE_DICTIONARY:
					_chapters.append(item)
	if _chapters.is_empty():
		_chapters = [{"name": "关卡#1", "description": "", "campaign_id": "", "level_id": ""}]
	_chapter = _chapters[0]
	_selected = 0

	_flag.setup(font, "level", String(_chapter.get("name", "")),
		String(cfg.str_val("menu.deck.campaign.flag_sub", "关卡")))
	_flag.pressed.connect(func(): flag_pressed.emit(_chapter))
	_refresh_rail()


func select_chapter(index: int) -> void:
	if index < 0 or index >= _rail_buttons.size():
		return
	_selected = index
	_refresh_rail()
	chapter_selected.emit(index)


func selected_chapter() -> int:
	return _selected


func current_chapter() -> Dictionary:
	return _chapter


func chapters() -> Array:
	return _chapters


func chapter_buttons() -> Array:
	return _rail_buttons


func flag_button():
	return _flag


func _refresh_rail() -> void:
	for i in _rail_buttons.size():
		var b: Button = _rail_buttons[i]
		var on: bool = (i == _selected)
		b.add_theme_stylebox_override("normal",
			MenuThemeRes.button_selected() if on else MenuThemeRes.button_normal())
		b.add_theme_stylebox_override("hover",
			MenuThemeRes.button_selected_hover() if on else MenuThemeRes.button_hover_clear())
		b.add_theme_stylebox_override("pressed", MenuThemeRes.button_fill_latched())
		b.add_theme_stylebox_override("focus", MenuThemeRes.button_normal())
		b.add_theme_color_override("font_color",
			MenuThemeRes.text_on_fill() if on else MenuThemeRes.text_normal())
		b.add_theme_color_override("font_hover_color",
			MenuThemeRes.text_on_fill() if on else MenuThemeRes.text_normal())


func _layout() -> void:
	var rail := LayoutRes.campaign_rail(size.x, size.y)
	_rail.position = rail.position
	_rail.size = rail.size
	for i in _rail_buttons.size():
		var r := LayoutRes.campaign_rail_button(rail, i)
		var b: Button = _rail_buttons[i]
		b.position = r.position - rail.position
		b.size = r.size

	var fr := LayoutRes.campaign_flag(size.x, size.y)
	_flag.position = fr.position
	_flag.size = fr.size
