## page_tabs.gd —— 右下那一列纵向页签（**按当前选中对象动态显示**）
##
## ★★ 需求原话（这一版的核心）：页签**不再固定三颗**，而是看玩家选中了什么：
##   · 选中部队 / 单位 → 两颗：**操作**（对部队下达指令）+ **单位**（招募单位的页）
##   · **所有建筑** → 一颗：**操作**（第二十四节的需求：「为所有单位/建筑都添加上
##     『操作』页签」）—— 大本营 / 城墙 / 箭塔的操作页里是「升级」，区划中心是三个特化；
##     大本营另有一颗**科技**、区划中心另有一颗**招募**
##   · 什么都没选中 → 两颗：**建筑**（城墙 / 箭塔的建造入口）+ **科技**
##     ★ 需求原话：「当玩家什么都没选中时，原右下角只有一个建筑页签的地方
##       添加一个科技页签，同时该科技页签也会同步到选中大本营时的科技页签中」——
##       两处的科技是**同一个 PAGE_TECH**（同一页、同一套九格内容），不是两份实现。
##
## ⚠️ 第二十二节那版「选中普通建筑 = 一颗**空页签**（`PAGE_NONE`）」已被第二十四节取代；
##    `PAGE_NONE` 常量与那条 `LABELS` 项**保留**（历史 + 以后可能再要占位页签），
##    但 `hud._tab_plan()` 现在不会再给任何一类选中发它。
##
## ★ 页签只有**到这里为止**的职责：它不判断「现在该显示哪几页」（那是 hud.gd 按
##   选中对象算的，见 `hud._tab_plan()`），也不关心页里有什么（内容由 hud 组装，
##   科技那一页的九格由 view/tech_grid.gd 画）。
##   本控件只做三件事：摆按钮、记当前页、把点击抛出去（`page_changed`）。
##
## 配色：参考图里几颗都是实心蓝，但那样看不出「当前在哪一页」——
## 所以当前页用实心蓝（就是参考图那个 #1E98D7），其余描边。这样仍然一看就是同一套色。
##
## ⚠️ 按钮个数**固定建 TABS_COUNT 颗**、多的**隐藏**（而不是随页数增删节点）：
##   节点树在测试与调试里是稳定的，几何也照旧走 ui_layout（按钮高度 = 240 / 当前页数）。
extends Control

signal page_changed(page: String)

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")

## 页 id（也是给 hud 用的常量；中文标签在下面 LABELS 里）
const PAGE_ORDER := "order"       ## 操作：对部队下达的指令（移动 / 攻击 / 行军 / 停止）
const PAGE_UNIT := "unit"         ## 单位：招募单位的页（排进选中将领的队列）
const PAGE_BUILD := "build"       ## 建筑：城墙 / 箭塔（什么都没选中时的那一页）
const PAGE_RECRUIT := "recruit"   ## 招募：区划招将领（选中区划中心时）
const PAGE_TECH := "tech"         ## 科技：九条占位科技（选中大本营 / 什么都没选中时都有）
## ★ **空页签**：选中普通建筑（城墙 / 箭塔）时的那一颗。
##
## 需求原话（手玩补的）：「当玩家点击选中建筑时，应当保留一个空页签，而不是空一块」
##   —— 选中建筑时那一列**不是什么都不画**（那样看着像界面缺了一块），而是照常立着
##   一颗页签，只是它没有标签、对应的命令卡也是空的。
## ★ 它**不参与高亮**（`is_active` 对它恒为 false）：它是一颗占位页签，不是「当前在哪一页」。
const PAGE_NONE := "none"

const LABELS := {
	PAGE_ORDER: "操作",
	PAGE_UNIT: "单位",
	PAGE_BUILD: "建筑",
	PAGE_RECRUIT: "招募",
	PAGE_TECH: "科技",
	PAGE_NONE: "",                 # ★ 空页签：没有字
}

var _buttons: Array[Button] = []
## 当前这一屏有哪几页（顺序 = 从上到下）。空 = 没有页签（选中普通建筑时）。
var _page_ids: Array[String] = []
var _page: String = ""


func setup() -> void:
	name = "PageTabs"
	mouse_filter = Control.MOUSE_FILTER_STOP
	UiLayoutRes.apply_rect(self, UiLayoutRes.TABS_RECT, true, true)

	for i in UiLayoutRes.TABS_COUNT:
		var b := Button.new()
		b.name = "TabButton%d" % (i + 1)
		b.text = ""
		b.focus_mode = Control.FOCUS_NONE              # 别让空格 / 回车又触发一次
		b.add_theme_font_size_override("font_size", UiStyleRes.FS_TITLE)
		b.add_theme_color_override("font_color", UiStyleRes.TEXT)
		b.add_theme_color_override("font_hover_color", UiStyleRes.TEXT)
		b.add_theme_color_override("font_pressed_color", UiStyleRes.TEXT)
		b.visible = false
		UiLayoutRes.apply_rect(b, UiLayoutRes.tab_button_local(i))
		b.pressed.connect(_on_tab_pressed.bind(i))
		add_child(b)
		_buttons.append(b)

	set_pages([PAGE_BUILD])


## 换一整屏页签（由 hud 按当前选中对象调用）。
##
## @param ids        页 id 数组，顺序 = 从上到下（最多 TABS_COUNT 颗）
## @param preferred  **希望选中的那一页**（hud 传的是「这一类选中上次停在哪一页」）；
##                   它不在 ids 里 / 没传时：能留住当前页就留，否则选第一页。
##
## ★ 只在**页真的变了**的时候发 page_changed（hud 每帧都会调它，
##   每帧都发一次信号会让命令卡每帧重建一遍）。
func set_pages(ids: Array, preferred: String = "") -> void:
	var clean: Array[String] = []
	for id in ids:
		var s := String(id)
		if s != "" and not clean.has(s):
			clean.append(s)

	var same := _same_pages(clean)
	if same and clean.has(_page):
		# ★ 页签组合没变、当前页也还在这一屏里 → 只重摆一次按钮，**不发信号**。
		#   ⚠️ 但仍要先把 `_page_ids` 落下来：`_layout` 与 `is_active` 都读它。
		_page_ids = clean
		_layout(clean)
		_apply_styles()
		return

	var want := preferred
	if want == "" or not clean.has(want):
		want = _page if clean.has(_page) else (clean[0] if not clean.is_empty() else "")
	_page_ids = clean
	# ★★ 顺序要紧：**先写 `_page`，再发 `page_changed`**。
	#   监听者（hud._on_page_changed → _rebuild_card）会**同步**回头读
	#   `page_tabs.page()` 来决定命令卡里放哪几格内容 ——
	#   先发信号再赋值的话，它读到的是**上一页**，命令卡就会画错内容
	#   （实测症状：切到科技页，命令卡却按上一页填了格子；切到建筑页，科技九格又立着）。
	_page = want
	_layout(clean)
	_apply_styles()
	page_changed.emit(_page)


func _same_pages(clean: Array[String]) -> bool:
	if clean.size() != _page_ids.size():
		return false
	for i in clean.size():
		if clean[i] != _page_ids[i]:
			return false
	return true


## 按页数摆按钮（高度 = 240 / 页数），多余的隐藏
func _layout(clean: Array[String]) -> void:
	for i in _buttons.size():
		var b := _buttons[i]
		if i >= clean.size():
			b.visible = false
			continue
		b.visible = true
		b.text = String(LABELS.get(clean[i], clean[i]))
		UiLayoutRes.apply_rect(b, UiLayoutRes.tab_button_local(i, clean.size()))


func _on_tab_pressed(i: int) -> void:
	if i < 0 or i >= _page_ids.size():
		return
	select_page(_page_ids[i])


## 切页。★ 不在当前这一屏里的页**一律拒掉**（选中建筑时没有任何页签，
## 这时候谁来 select_page 都不该把命令卡点亮）。
func select_page(page: String) -> void:
	if not _page_ids.has(page) or page == _page:
		return
	_page = page
	_apply_styles()
	page_changed.emit(_page)


func _apply_styles() -> void:
	for i in _buttons.size():
		var b := _buttons[i]
		if is_active(i):
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

## 当前页 id（"" = 这一屏里没有页签）
func page() -> String:
	return _page


## 当前这一屏的页签个数
func page_count() -> int:
	return _page_ids.size()


## 第 i 颗按钮的页 id（越界 = ""）
func page_id_at(i: int) -> String:
	if i < 0 or i >= _page_ids.size():
		return ""
	return _page_ids[i]


## 第 i 颗按钮（越界 = null）
func button_at(i: int) -> Button:
	if i < 0 or i >= _buttons.size():
		return null
	return _buttons[i]


## 建出来的按钮总数（= TABS_COUNT，固定；**当前显示几颗**看 page_count()）
func button_count() -> int:
	return _buttons.size()


## 第 i 颗按钮是不是**画成「当前页」的样子**（实心蓝高亮）。
## ★ 空页签（PAGE_NONE）恒为 false：它只是一颗占位页签，不是「玩家停在这一页」。
func is_active(i: int) -> bool:
	if i < 0 or i >= _page_ids.size():
		return false
	if _page_ids[i] == PAGE_NONE:
		return false
	return _page_ids[i] == _page
