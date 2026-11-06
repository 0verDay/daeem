## detail_v2.gd —— D6 新版详细信息面板（落地版）
##
## 结构：
##   左：detail_list（185×256，贴面板内缘，金色描边，可滚动）
##   右：detail_info（394×220：图标 72 + 部队名/单位名 + 288.5 宽信息框）
##   底：红字提示（操作被拒的一句话，保留原 hud.show_notice 行为）
##
## ★ 旧 detail_panel 仍然存在（隐藏），继续喂数据给现有测试/兼容接口；
##   本控件只负责**显示与点击**，不判断选中规则。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const DetailListRes = preload("res://view/detail_list.gd")
const DetailInfoRes = preload("res://view/detail_info.gd")

signal unit_selected(unit)
signal entry_selected(entry)

## 面板几何：左缘 400（阵营占位删掉后整体左移）；右缘 1016.5，右侧留地图。
const PANEL_RECT := Rect2(400.0, 820.0, 616.5, 260.0)
const LIST_POS := Vector2(2.0, 2.0)
const LIST_SIZE := Vector2(185.0, 256.0)
const INFO_POS := Vector2(197.0, 18.0)
const INFO_SIZE := Vector2(394.0, 220.0)

var list: Control = null
var info: Control = null
var _notice: Label = null


func setup(world, p_font: Font = null) -> void:
	name = "DetailPanelV2"
	mouse_filter = Control.MOUSE_FILTER_STOP
	UiLayoutRes.apply_rect(self, PANEL_RECT, false, true)
	z_index = 5

	list = DetailListRes.new()
	list.setup(world, p_font)
	list.position = LIST_POS
	list.size = LIST_SIZE
	add_child(list)
	list.unit_selected.connect(_on_unit_selected)
	list.entry_selected.connect(_on_entry_selected)

	info = DetailInfoRes.new()
	info.setup(p_font)
	info.position = INFO_POS
	info.size = INFO_SIZE
	add_child(info)

	_notice = Label.new()
	_notice.name = "DetailNotice"
	_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 与信息框同左缘/同宽；贴在信息框下沿（框底 231，提示 232..256）。
	_notice.position = Vector2(302.5, 232.0)
	_notice.size = Vector2(288.5, 24.0)
	_notice.add_theme_font_size_override("font_size", UiStyleRes.FS_SMALL)
	_notice.add_theme_color_override("font_color", UiStyleRes.warn())
	if p_font != null:
		_notice.add_theme_font_override("font", p_font)
	add_child(_notice)
	_notice.visible = false
	visible = false


func set_roster(troops: Array, focused_number: int, selected_unit) -> void:
	if list != null:
		list.set_roster(troops, focused_number, selected_unit)


func set_small_entries(entries: Array, primary, kind: String) -> void:
	if list != null:
		list.set_small_entries(entries, primary, kind)


func set_header(icon_text: String, title: String, subtitle: String,
		hp_ratio: float = 1.0, show_hp: bool = false) -> void:
	if info != null:
		info.set_header(icon_text, title, subtitle, hp_ratio, show_hp)


func set_info_groups(groups: Array) -> void:
	if info != null:
		info.set_groups(groups)


func set_notice(text: String) -> void:
	if _notice != null:
		_notice.text = text
		_notice.visible = text != ""


func _on_unit_selected(u) -> void:
	unit_selected.emit(u)


func _on_entry_selected(e: Dictionary) -> void:
	entry_selected.emit(e)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.098, 0.133, 0.176, 1.0), true)
	draw_rect(Rect2(Vector2.ZERO, size), UiStyleRes.line(), false, 2.0)
