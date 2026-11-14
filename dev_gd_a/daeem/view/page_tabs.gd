## page_tabs.gd —— 右下那一列纵向页签（**按当前选中对象动态显示**）
##
## ★★ 需求原话（这一版的核心）：页签**不再固定三颗**，而是看玩家选中了什么：
##   · 自己的部队 / 单位 → 两颗：**操作**（对部队下达指令）+ **单位**（招募单位的页）
##   · 自己的大本营 → 两颗：**操作**（升级大本营）+ **科技**
##   · 自己的区划中心 → 一颗：**招募**
##   · 自己的**无操作建筑**（木墙 / 哨塔 / 资源建筑…）→ **整块隐藏**
##   · **敌方 / 友方任何建筑 / 单位**（在输入层都走 `selected_enemy`）→ **整块隐藏**
##   · 什么都没选中 → 两颗：**建筑**（城墙 / 箭塔的建造入口）+ **科技**
##     ★ 需求原话：「当玩家什么都没选中时，原右下角只有一个建筑页签的地方
##       添加一个科技页签，同时该科技页签也会同步到选中大本营时的科技页签中」——
##       两处的科技是**同一个 PAGE_TECH**（同一页、同一套九格内容），不是两份实现。
##
## ★★ 「隐藏」是**页签 + 命令卡整块收起**（用户原话：「页签和命令卡都要隐藏」）：
##   不是立一颗空页签，也不是只把按钮设成不可见 —— 页签列（含 `TabsFrame` 外框）
##   与旁边的 3×3 命令卡一起 `visible = false`。实现在 `hud._sync_tabs()`：
##   页列表为空 ⇒ 两者一起关掉；改选自己的部队 / 大本营 / 区划 / 空手时一起恢复。
##
## ★ 页签只有**到这里为止**的职责：它不判断「现在该显示哪几页」（那是 hud.gd 按
##   选中对象算的，见 `hud._tab_plan()`），也不关心页里有什么（内容由 hud 组装，
##   科技那一页的九格由 view/tech_grid.gd 画）。
##   本控件只做三件事：摆按钮、记当前页、把点击抛出去（`page_changed`）。
##   ★★ 「整块隐藏」也由 hud 设 `visible` 完成；本控件只保证 `set_pages([])` 之后
##   没有残留的按钮 / 当前页。
## ★★ 键盘也能切页：`cycle_page(dir)` 按当前这屏的顺序循环（Tab / Shift+Tab 由
##   `hud.handle_tab_key()` 在 GUI 之前调过来；整块隐藏时那边会先看 `visible`）。
##
## 配色：参考图里几颗都是实心的，但那样看不出「当前在哪一页」——
## 所以当前页用**实心金**（theme.accent），其余只描边。这样仍然一看就是同一套色。
##
## ⚠️ 按钮个数**固定建 TABS_COUNT 颗**、多的**隐藏**（而不是随页数增删节点）：
##   节点树在测试与调试里是稳定的，几何也照旧走 ui_layout（按钮高度 = 240 / 当前页数）。
extends Control

signal page_changed(page: String)

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
## ★★ 悬停「四边泛光」+「选中页金色填充满格」（见 view/fill_button.gd）。
const FillButtonRes = preload("res://view/fill_button.gd")

## 页 id（也是给 hud 用的常量；中文标签在下面 LABELS 里）
const PAGE_ORDER := "order"       ## 操作：对部队下达的指令（移动 / 攻击 / 行军 / 停止）
const PAGE_UNIT := "unit"         ## 单位：招募单位的页（排进选中将领的队列）
const PAGE_BUILD := "build"       ## 建筑：城墙 / 箭塔（什么都没选中时的那一页）
const PAGE_RECRUIT := "recruit"   ## 招募：区划招将领（选中区划中心时）
const PAGE_TECH := "tech"         ## 科技：九条占位科技（选中大本营 / 什么都没选中时都有）

const LABELS := {
	PAGE_ORDER: "操作",
	PAGE_UNIT: "单位",
	PAGE_BUILD: "建筑",
	PAGE_RECRUIT: "招募",
	PAGE_TECH: "科技",
}

var _buttons: Array[Button] = []
## 当前这一屏有哪几页（顺序 = 从上到下）。空 = 没有页签（hud 会把整列 visible 关掉，
## 用于选中无操作的建筑；见 `hud._sync_tabs()`）。
var _page_ids: Array[String] = []
var _page: String = ""

## ★★ 每颗页签的**文案真值**（⚠️ `Button.text` 已被逐字 Label 接管、恒为空串）。
var _chars: Array[String] = []
## 每颗页签当前的逐字 Label（重建时先清掉这一批）。
var _char_labels: Array = []
## ★★ 每颗页签的逐字 Label 是**按哪个按钮高度**建出来的（0 = 还没建）。
##
## 为什么必须单独记它：逐字 Label 的高度是 `attach_char_text()` 建的**那一刻**从按钮的
##   `size.y` 取的，建完就再没人动它 —— 而**页数一变，按钮高度就变**（240 ÷ 页数）。
##   ⇒ 重建判据只看「文案变没变」的话，文案没变的那一颗会跳过重建、留着上一次的高度，
##     字按旧高度竖直居中，就沉到按钮底边去。
##   ★ 实测（手玩报的「刚进游戏时右下角『建筑』按钮错位」）：进游戏那一刻 hud 建的是
##     **1 颗**页签（铺满整列 240 高，「建筑」这两个字就是按 240 建的），第一帧 refresh
##     才换成「建筑 + 科技」**两颗**（各 120 高）—— 文案一个字没变，变的只是按钮高度，
##     于是「建筑」的字留在 240 的高度里居中，正好压在按钮下缘 / 与「科技」的交界处。
var _char_h: Array[float] = []
## 上一轮「是不是当前页」：变了要重排逐字标签的颜色（当前页用近黑底字）。
var _was_active: Array[bool] = []
## ★★ 2026.11.5：第一轮 `_apply_styles()` 是「建出来时的初始状态」——
##   当前页那一下要**直接满格**（不播填充动画），之后切页才播。
var _primer_done: bool = false

## ★★ 教程引导：让某一页签「呼吸高亮」（不改变当前页）。
##   每颗按钮各带一层描边 + 一层向外扩散的方形波纹；只有 `_attention_page` 那颗显示。
var _attention_page: String = ""
var _attention_t: float = 0.0
var _attention_borders: Array[Panel] = []
var _attention_ripples: Array[Panel] = []


func setup() -> void:
	name = "PageTabs"
	mouse_filter = Control.MOUSE_FILTER_IGNORE # 只由实际牌签按钮吃输入，周围空隙让地图透过
	UiLayoutRes.apply_rect(self, UiLayoutRes.TABS_RECT, true, true)

	for i in UiLayoutRes.TABS_COUNT:
		var b := Button.new()
		b.name = "TabButton%d" % (i + 1)
		b.text = ""
		b.focus_mode = Control.FOCUS_NONE              # 别让空格 / 回车又触发一次
		b.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)
		# ★★ 悬停泛光 + 选中填充（一行挂上，见 view/fill_button.gd）。
		#   ⚠️ 在这之后**不要**再直接写 `add_theme_color_override("font_color", …)`：
		#      填充动效每帧按「原色 + 进度」重算字色，直接写会被盖掉。
		FillButtonRes.attach_text(b)
		# ★★ 2026.11.14（用户口径）：「页签栏也不需要（四角显示了），页签栏的鼠标悬停
		#   效果改为金色填充」—— 所以这一颗：不画四角括号 + 悬停直接填金。
		#   ⚠️ 两个都要在 `attach_text()` **之后**调（那时动画器才在），
		#      `set_reticle` 会直接把已建好的那一层拆掉。
		FillButtonRes.set_reticle(b, false)
		FillButtonRes.set_hover_fill(b, true)
		# ★★ 页签有自己的点击反馈（切页时金色填充 / 反向退回）——
		#   关掉「点击闪光」，否则闪光的填满→退回会和选中填充抢同一份进度。
		FillButtonRes.set_click_flash(b, false)
		# ★★ 常驻灰底：底纹（`tab_plain*`）必须保持全透明，否则会把填充金盖住；
		#   所以灰底交给填充动画器画在**金的下层** —— 悬停时灰底不消失，金只是往上盖。
		#   ★★ 2026.11.14：从 `bg_empty()`（0.55 半透明）改成 `bg()` ——
		#     投影已经搬到金的下层（见 fill_button `_ensure_shadow`），卡身不能再靠
		#     「投影压在上面」那层黑来撑，否则页签会比其它面板浅一档。
		FillButtonRes.set_base_bg(b, UiStyleRes.bg())
		b.visible = false
		UiLayoutRes.apply_rect(b, UiLayoutRes.tab_button_local(i))
		b.pressed.connect(_on_tab_pressed.bind(i))
		add_child(b)
		_buttons.append(b)
		_chars.append("")
		_char_labels.append([])
		_char_h.append(0.0)
		_was_active.append(false)

		# 引导描边 + 向外扩散的方形波纹（默认隐藏，只有 `set_attention()` 指定的页显示）。
		var ab := Panel.new()
		ab.name = "AttentionBorder"
		ab.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ab.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var absb := StyleBoxFlat.new()
		absb.bg_color = Color(0, 0, 0, 0)
		absb.border_color = UiStyleRes.accent()
		absb.set_border_width_all(2)
		ab.add_theme_stylebox_override("panel", absb)
		ab.visible = false
		b.add_child(ab)
		_attention_borders.append(ab)

		var ar := Panel.new()
		ar.name = "AttentionRipple"
		ar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var arsb := StyleBoxFlat.new()
		arsb.bg_color = Color(0, 0, 0, 0)
		arsb.border_color = UiStyleRes.accent()
		arsb.set_border_width_all(2)
		ar.add_theme_stylebox_override("panel", arsb)
		ar.visible = false
		b.add_child(ar)
		_attention_ripples.append(ar)

	# 牌签独立成组，不再给整列套矩形外框；保留透明覆盖节点供旧的节点查询兼容。
	var frame := Panel.new()
	frame.name = "TabsFrame"
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	var frame_style := StyleBoxFlat.new()
	frame_style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	frame_style.set_border_width_all(0)
	frame.add_theme_stylebox_override("panel", frame_style)
	add_child(frame)

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


## ★★ 按页数摆按钮（高度 = 240 / 页数），多余的隐藏；并**把文字拆成逐字 Label**。
##
## ★ 为什么要拆成逐字（需求）：「填充特效开始时，里面的白字要由下往上由白变黑，
##   与金色填充线同步」—— `Button.text` 是引擎**一次性**画的一整块，脚本没法只改
##   其中一个字的颜色；拆成一字一颗 Label 之后，金的前沿扫到哪个字、那个字才变色
##   （见 fill_button 的 `_char_t` / `attach_char_text`）。
##
## ⚠️⚠️ `attach_char_text()` 会把 `b.text` **置空**（否则引擎会在逐字 Label 底下
##   把整行原文再画一遍，出重影）。所以：
##   · 文案真值存在 `_chars[i]`，`_text_of(i)` 从它取 —— 别再依赖 `b.text`；
##   · 只在**文案真的变了**时才重建 Label（`_layout` 每帧都会被调，每帧重建会漏内存）。
func _layout(clean: Array[String]) -> void:
	for i in _buttons.size():
		var b := _buttons[i]
		if i >= clean.size():
			b.visible = false
			continue
		b.visible = true
		var want := String(LABELS.get(clean[i], clean[i]))
		UiLayoutRes.apply_rect(b, UiLayoutRes.tab_button_local(i, clean.size()))
		# ★★ 判据是「文案变了 **或** 按钮高度变了」——
		#   `apply_rect` 在上面刚把高度改成 240 / 页数，而逐字 Label 的高度是**建它那一刻**
		#   从按钮取的（见 `_char_h` 那段说明）。只比文案的话，文案没变的那一颗会留着
		#   上一次的高度，字就沉到按钮底边（手玩报的「刚进游戏时『建筑』按钮错位」）。
		if _chars[i] != want or _char_h[i] != b.size.y:
			_chars[i] = want
			_rebuild_chars(i, want)


## 把第 i 颗页签的文字重建成逐字 Label。
func _rebuild_chars(i: int, text: String) -> void:
	var b := _buttons[i]
	# ★ 记下「这次是按**哪个按钮高度**建的」：`_layout` 靠它判断高度变了要不要重建
	#   （高度一变，旧 Label 的竖直居中就不对了）。
	_char_h[i] = b.size.y
	# 先清掉上一轮的逐字 Label（换页时文案会变长变短）
	for l in _char_labels[i]:
		var n := l as Node
		if n != null and is_instance_valid(n):
			n.queue_free()
	_char_labels[i] = []
	if text == "":
		b.text = ""
		return
	# V2 牌签：短标签纵向排字（「操 / 作」），每个字仍由填充动画独立翻色。
	var fs: int = b.get_theme_font_size("font_size")
	var f: Font = b.get_theme_font("font")
	var line_h := 24.0
	var top := (b.size.y - float(text.length()) * line_h) * 0.5
	for ci in text.length():
		var l := Label.new()
		l.name = "Char%d" % ci
		l.text = text.substr(ci, 1)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.position = Vector2(0.0, top + float(ci) * line_h)
		l.size = Vector2(b.size.x, line_h)
		l.add_theme_font_size_override("font_size", fs)
		l.add_theme_color_override("font_color", UiStyleRes.text())
		if f != null:
			l.add_theme_font_override("font", f)
		b.add_child(l)
		_char_labels[i].append(l)
		FillButtonRes.on_fill_text(b, l, UiStyleRes.text())
	# ★ 记下「这次是按哪一档建的」：`_apply_styles` 靠它判断要不要重建。
	_was_active[i] = is_active(i)


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


## ★★ Tab 键切页：按当前这屏的顺序循环到下一页（dir = +1）/ 上一页（dir = -1）。
##
## @return true = 真的切了（按键该被消费）；只有一页 / 没有页签 / 目标就是当前页 → false。
## ★ 当前页不在列表里（刚换了一类选中）时，从第一页开始。
func cycle_page(dir: int = 1) -> bool:
	var n := _page_ids.size()
	if n <= 1:
		return false
	var idx := _page_ids.find(_page)
	var next: int = 0 if idx < 0 else (idx + dir) % n
	if next < 0:
		next += n
	var target := _page_ids[next]
	if target == _page:
		return false
	select_page(target)
	return true


## 普通态的底色（`tab_normal` / `tab_hover` 那一档）**留给没挂填充的场合**；
## 页签自己走下面这一对：底透明、只留描边 —— 底色交给填充层。
##   · 没悬停：一条金线（+ 这一列自己的底板）；
##   · **悬停 / 按住：四边向中心泛光**（2026.11.5 起，不再是从下往上填金）；
##   · **当前页：金色填充满格**（点击切换时才播填充动画；第一页直接满格）。
##
## ★★ 字色口径（别再各改一半）：
##   · **所有**页签的字都从**暖白**起步（用户：「页签按钮文字要白色」）；
##   · 金色填充往上扫时，字**跟着那条前沿**由白变黑（用户：
##     「白字也需要添加由下往上的由白变黑特效，需要和金色填充线同步」）
##     —— 这条由 `fill_button` 的**逐字翻面**实现（金扫到哪个字，那个字才变色）。
##   · 所以当前页**不用**单独把字设成近黑：它整块金是满的，翻面自然把
##     每个字都推到黑（填充到 1 时覆盖率 = 1）。
##   ⚠️ 这条口径**就是全项目的口径**（用户后来要求「所有被金压住的字一律照页签栏这么做」）：
##     白字压金是读不出来的，不许有任何一处例外 —— 包括那个已经作废的
##     `prefer_light` 开关（它现在只是个记录用的字段，见 view/fill_button.gd）。
func _apply_styles() -> void:
	var instant := not _primer_done
	for i in _buttons.size():
		var b := _buttons[i]
		var on := is_active(i)
		FillButtonRes.set_prefer_light(b, true)
		FillButtonRes.set_latched(b, on, instant)
		FillButtonRes.set_base_font_color(b, UiStyleRes.text())
		if on:
			b.add_theme_stylebox_override("normal", UiStyleRes.tab_latched())
			b.add_theme_stylebox_override("hover", UiStyleRes.tab_latched())
			b.add_theme_stylebox_override("pressed", UiStyleRes.tab_latched())
		else:
			b.add_theme_stylebox_override("normal", UiStyleRes.tab_plain())
			b.add_theme_stylebox_override("hover", UiStyleRes.tab_plain_hover())
			# ★ 按下统一成 2px 亮边（与菜单 / 命令卡同一档）；松手后再切到当前页的 latched
			b.add_theme_stylebox_override("pressed", UiStyleRes.tab_latched())
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		# ★ 当前页 ⇄ 非当前页切换时，逐字 Label 要按新的档重新登记
		#   （`set_base_font_color` 只认宿主按钮那一块；逐字是各自登记的）。
		if i < _was_active.size() and _was_active[i] != on:
			_was_active[i] = on
			if _chars[i] != "":
				_rebuild_chars(i, _chars[i])
	_primer_done = true


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


## 这一屏里有没有这一页（教程引导用：没有「单位」页时不该硬亮一个不存在的按钮）。
func has_page(page_id: String) -> bool:
	return _page_ids.has(String(page_id))


## ★★ 教程引导：让某一页签呼吸高亮；空串 = 关掉。
##   不改变当前页，也不触发 `page_changed`。
func set_attention(page_id: String) -> void:
	var p := String(page_id).strip_edges()
	if p == _attention_page:
		return
	_attention_page = p
	_attention_t = 0.0
	_update_attention()


func _update_attention() -> void:
	var pulse := 0.2 + 0.8 * (0.5 - 0.5 * cos(_attention_t * TAU / 1.4))
	var rip_t := fmod(_attention_t, 1.4) / 1.4
	var rip_e := 1.0 - (1.0 - rip_t) * (1.0 - rip_t)
	for i in _buttons.size():
		var hit: bool = _attention_page != "" and i < _page_ids.size() \
			and _page_ids[i] == _attention_page
		if i < _attention_borders.size():
			var ab: Panel = _attention_borders[i]
			if ab != null and is_instance_valid(ab):
				ab.visible = hit
				if hit:
					var sb: StyleBoxFlat = ab.get_theme_stylebox("panel") as StyleBoxFlat
					if sb != null:
						var c := UiStyleRes.accent()
						sb.border_color = Color(c.r, c.g, c.b, 0.35 + 0.65 * pulse)
						sb.bg_color = Color(c.r, c.g, c.b, 0.05 + 0.10 * pulse)
		if i < _attention_ripples.size():
			var ar: Panel = _attention_ripples[i]
			if ar == null or not is_instance_valid(ar):
				continue
			ar.visible = hit
			if hit:
				var sz: Vector2 = _buttons[i].size
				var s := lerpf(sz.x * 0.28, sz.x * 1.12, rip_e)
				ar.position = (sz - Vector2(s, s)) * 0.5
				ar.size = Vector2(s, s)
				var rsb: StyleBoxFlat = ar.get_theme_stylebox("panel") as StyleBoxFlat
				if rsb != null:
					var rc := UiStyleRes.accent()
					rsb.border_color = Color(rc.r, rc.g, rc.b, (1.0 - rip_t) * 0.9)


func _process(dt: float) -> void:
	if _attention_page != "":
		_attention_t += maxf(0.0, dt)
		_update_attention()


## 第 i 颗按钮（越界 = null）
func button_at(i: int) -> Button:
	if i < 0 or i >= _buttons.size():
		return null
	return _buttons[i]


## ★★ 第 i 颗页签上的**文案**（越界 = ""）。
##
## ⚠️ 不能用 `button_at(i).text`：那颗按钮的 `text` 已经被**逐字 Label** 接管
##   （`attach_char_text` 会把它置空，否则引擎会在逐字 Label 底下重画一遍原文）。
##   文案真值存在 `_chars` 里，这个函数是唯一该用的读法。
func label_at(i: int) -> String:
	if i < 0 or i >= _chars.size():
		return ""
	return _chars[i]


## 第 i 颗页签当前的**逐字 Label**（给测试看逐字渐变用）。
func char_labels_at(i: int) -> Array:
	if i < 0 or i >= _char_labels.size():
		return []
	return _char_labels[i]


## 建出来的按钮总数（= TABS_COUNT，固定；**当前显示几颗**看 page_count()）
func button_count() -> int:
	return _buttons.size()


## 第 i 颗按钮是不是**画成「当前页」的样子**（实心金高亮）。
func is_active(i: int) -> bool:
	if i < 0 or i >= _page_ids.size():
		return false
	return _page_ids[i] == _page
