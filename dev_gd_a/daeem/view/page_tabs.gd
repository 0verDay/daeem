## page_tabs.gd —— 右下「单位 / 建筑 / 科技」三颗纵向按钮
##
## 需求确认：单位 / 建筑 用来切命令卡的内容；**科技点不动**（本轮不做）。
##
## 配色：参考图里三颗都是实心蓝，但那样看不出「当前在哪一页」——
## 所以当前页用实心蓝（就是参考图那个 #1E98D7），其余描边。这样仍然一看就是同一套色。
##
## ★ 只发 page_changed 信号，不关心页里有什么（内容由 hud.gd 组装）。
extends Control

signal page_changed(page: String)

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")

const PAGE_UNIT := "unit"
const PAGE_BUILD := "build"
const PAGE_TECH := "tech"
const PAGE_ORDER := [PAGE_UNIT, PAGE_BUILD, PAGE_TECH]
const PAGE_LABELS := ["单位", "建筑", "科技"]

var _buttons: Array[Button] = []
var _page: String = PAGE_UNIT


func setup() -> void:
	name = "PageTabs"
	mouse_filter = Control.MOUSE_FILTER_STOP
	UiLayoutRes.apply_rect(self, UiLayoutRes.TABS_RECT, true, true)

	for i in PAGE_LABELS.size():
		var b := Button.new()
		b.name = "TabButton%d" % (i + 1)
		b.text = String(PAGE_LABELS[i])
		b.focus_mode = Control.FOCUS_NONE              # 别让空格 / 回车又触发一次
		b.add_theme_font_size_override("font_size", UiStyleRes.FS_TITLE)
		b.add_theme_color_override("font_color", UiStyleRes.TEXT)
		b.add_theme_color_override("font_hover_color", UiStyleRes.TEXT)
		b.add_theme_color_override("font_pressed_color", UiStyleRes.TEXT)
		UiLayoutRes.apply_rect(b, UiLayoutRes.tab_button_local(i))
		b.pressed.connect(_on_tab_pressed.bind(i))
		add_child(b)
		_buttons.append(b)

	_apply_styles()


func _on_tab_pressed(i: int) -> void:
	var id := String(PAGE_ORDER[i])
	if id == PAGE_TECH:
		return                                          # ★ 科技点不动（需求）
	select_page(id)


## 切页（hud.gd 与测试都走这里；tech 会被拒掉）
func select_page(page: String) -> void:
	if page == PAGE_TECH or not PAGE_ORDER.has(page):
		return
	_page = page
	_apply_styles()
	page_changed.emit(_page)


func _apply_styles() -> void:
	for i in _buttons.size():
		var b := _buttons[i]
		var id := String(PAGE_ORDER[i])
		var active: bool = (id == _page)
		if active:
			b.add_theme_stylebox_override("normal", UiStyleRes.tab_active())
			b.add_theme_stylebox_override("hover", UiStyleRes.tab_active())
			b.add_theme_stylebox_override("pressed", UiStyleRes.tab_active())
			b.add_theme_color_override("font_color", UiStyleRes.TEXT_ON_ACCENT)
			b.add_theme_color_override("font_hover_color", UiStyleRes.TEXT_ON_ACCENT)
			b.add_theme_color_override("font_pressed_color", UiStyleRes.TEXT_ON_ACCENT)
		else:
			b.add_theme_stylebox_override("normal", UiStyleRes.tab_normal())
			b.add_theme_stylebox_override("hover", UiStyleRes.tab_hover())
			b.add_theme_stylebox_override("pressed", UiStyleRes.tab_hover())
			b.add_theme_color_override("font_color", UiStyleRes.TEXT)
			b.add_theme_color_override("font_hover_color", UiStyleRes.TEXT)
			b.add_theme_color_override("font_pressed_color", UiStyleRes.TEXT)
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


# ------------------------------------------------------------------
# 给测试 / hud 用的小接口
# ------------------------------------------------------------------

func page() -> String:
	return _page


func button_at(i: int) -> Button:
	if i < 0 or i >= _buttons.size():
		return null
	return _buttons[i]


func button_count() -> int:
	return _buttons.size()


func is_active(i: int) -> bool:
	if i < 0 or i >= _buttons.size():
		return false
	return String(PAGE_ORDER[i]) == _page
