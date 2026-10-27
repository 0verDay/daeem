## campaign_detail_panel.gd —— 战役详情面板（640×1080）。
##
## 缩略图 / 描述 / 动态阵营按钮；点阵营发 faction_chosen，由 main 打开战役过渡。
## 本轮唯一真实关 demo/mt 有两个可玩阵营；占位数据会得到一个禁用按钮。
extends "res://view/menu_page.gd"

signal faction_chosen(campaign_id: String, level_id: String, faction_id: String)

const BriefRes = preload("res://logic/campaign_menu_brief.gd")
const MapThumbRes = preload("res://view/map_thumb.gd")
const FactionButtonRes = preload("res://view/menu_faction_button.gd")

var _chapter: Dictionary = {}
var _brief: Dictionary = {}
var _thumb_frame: Panel = null
var _thumb = null
var _thumb_empty: Label = null
var _desc_panel: Panel = null
var _title: Label = null
var _body: RichTextLabel = null
var _faction_buttons: Array = []


func setup(p_cfg, p_font: Font) -> void:
	name = "CampaignDetailPanel"
	setup_page(p_cfg, p_font, String(p_cfg.str_val("menu.deck.titles.detail", "详情")), true)

	_thumb_frame = Panel.new()
	_thumb_frame.name = "ThumbFrame"
	_thumb_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_thumb_frame.add_theme_stylebox_override("panel", MenuThemeRes.deck_block())
	_thumb_frame.z_index = 5
	add_child(_thumb_frame)

	_thumb = MapThumbRes.new()
	_thumb.name = "Thumb"
	_thumb.z_index = 0
	_thumb_frame.add_child(_thumb)

	_thumb_empty = make_label("ThumbEmpty", "暂无地图", 24, ThemeRes.text_faint(),
		HORIZONTAL_ALIGNMENT_CENTER)
	_thumb_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_thumb_empty.z_index = 2
	_thumb_empty.visible = false
	_thumb_frame.add_child(_thumb_empty)

	_desc_panel = Panel.new()
	_desc_panel.name = "DescPanel"
	_desc_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_desc_panel.add_theme_stylebox_override("panel", MenuThemeRes.deck_block())
	_desc_panel.z_index = 5
	add_child(_desc_panel)

	_title = make_label("DetailTitle", "", 28, ThemeRes.text())
	_title.position = Vector2(18.0, 12.0)
	_title.size = Vector2(520.0, 36.0)
	_desc_panel.add_child(_title)

	_body = RichTextLabel.new()
	_body.name = "DetailBody"
	_body.bbcode_enabled = false
	_body.fit_content = false
	_body.scroll_active = false
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.clip_contents = true
	if font != null:
		_body.add_theme_font_override("normal_font", font)
	_body.add_theme_font_size_override("normal_font_size", 18)
	_body.add_theme_color_override("default_color", ThemeRes.text_dim())
	_body.position = Vector2(18.0, 52.0)
	_body.size = Vector2(524.0, 136.0)
	_desc_panel.add_child(_body)

	_thumb.setup(cfg, null)
	resized.connect(_layout)
	_layout()


func set_chapter(chapter: Dictionary) -> void:
	_chapter = chapter
	_brief = BriefRes.resolve(cfg, chapter)
	_refresh()


func brief() -> Dictionary:
	return _brief


func current_chapter() -> Dictionary:
	return _chapter


func faction_buttons() -> Array:
	return _faction_buttons


func thumb():
	return _thumb


func detail_title_text() -> String:
	return _title.text if _title != null else ""


func detail_body_text() -> String:
	return _body.text if _body != null else ""


func _refresh() -> void:
	if _brief.is_empty():
		return
	var map = _brief.get("map", null)
	if map != null:
		_thumb.visible = true
		_thumb.setup(cfg, map)
		_thumb.set_cover(true)
		_thumb_empty.visible = false
	else:
		_thumb.visible = false
		_thumb.setup(cfg, null)
		_thumb_empty.visible = true

	_title.text = String(_brief.get("title", ""))
	_body.text = String(_brief.get("description", ""))

	for b in _faction_buttons:
		if is_instance_valid(b):
			b.queue_free()
	_faction_buttons.clear()

	var entries: Array = _brief.get("entries", [])
	var cid := String(_chapter.get("campaign_id", ""))
	var lid := String(_chapter.get("level_id", ""))
	if entries.is_empty():
		var b := make_block_button("FactionDisabled", "暂不可用", 24)
		b.disabled = true
		b.add_theme_stylebox_override("normal", MenuThemeRes.button_disabled())
		b.add_theme_stylebox_override("hover", MenuThemeRes.button_disabled())
		b.add_theme_stylebox_override("pressed", MenuThemeRes.button_disabled())
		add_child(b)
		b.z_index = 5
		_faction_buttons.append(b)
	else:
		for raw in entries:
			var e: Dictionary = raw
			var b := FactionButtonRes.new()
			b.name = "Faction_%s" % String(e.get("id", ""))
			b.z_index = 5
			add_child(b)
			b.setup(font, e)
			var fid := String(e.get("id", ""))
			b.pressed.connect(func(): faction_chosen.emit(cid, lid, fid))
			_faction_buttons.append(b)
	_layout_factions()


func _layout() -> void:
	if _thumb_frame == null:
		return
	var tr := LayoutRes.detail_thumb(size.x)
	_thumb_frame.position = tr.position
	_thumb_frame.size = tr.size
	_thumb.position = Vector2(1.0, 1.0)
	_thumb.size = tr.size - Vector2(2.0, 2.0)
	_thumb_empty.position = Vector2.ZERO
	_thumb_empty.size = tr.size

	var dr := LayoutRes.detail_desc(size.x)
	_desc_panel.position = dr.position
	_desc_panel.size = dr.size
	_title.size = Vector2(dr.size.x - 36.0, 36.0)
	_body.size = Vector2(dr.size.x - 36.0, dr.size.y - 64.0)

	_layout_factions()


func _layout_factions() -> void:
	var n: int = _faction_buttons.size()
	for i in n:
		var b: Control = _faction_buttons[i]
		var r := LayoutRes.detail_faction_rect(size.x, i, n)
		b.position = r.position
		b.size = r.size
