## tech_grid.gd —— 右下「科技」页里的 3×3 九格（**盖在命令卡上**）
##
## ★★ 2026.11.18：
##   · 科技**一次性打出**：拖出 / 快捷键只做「启用」，没有「弃用」；
##   · 已启用的牌留在页面上（实心，不可再拖）；启用满 3 条后，其余未启用手牌销毁。
##   · 「最多 3 个」仍在 logic/tech.gd + world.set_tech_active；本控件只按 playable 拦截。
##
## 分工（与 command_card.gd 同一条边界）：
##   · 本控件只做三件事：摆九格、按权威状态画「已启用 / 没启用」、把拖牌/快捷键抛出去；
##   · 「最多 3 个」这条规则**不在这里**（在 logic/tech.gd + world.set_tech_active）；
##   · 「点一下到底是启用还是弃用」由 hud 按**权威状态**取反决定（`_on_card_entry`）。
##
## ★ 为什么单独一个控件、而不是把科技塞进 command_card 的九格里：
##   命令卡那九格是「页签的另一套内容」（操作 / 单位 / 建筑 / 招募），它只认 `entries`；
##   科技格需要**自己的三态样式**（已启用 / 未启用 / 悬停）与悬停详情。
##   塞进去会让命令卡同时认识三种数据形状。这里复用**它的几何**（card_cell_local），
##   于是两套内容在屏幕上完全重合 —— 换页时看不出是换了控件。
##
## ★★ 格子排版（2026.11）与命令卡统一：「**图标 + 一行名字**」。
##   · 图标 = `tech_<id>.png` 金线蒙版（按名字画的占位图形，见
##     tools/bake_unit_card_icon.py 的 TECH_SHAPES），**铺满整格**；
##   · 名字叠在最下面那条**略黑底条**上（金色填充扫上来时底条淡出）；
##   · **效果 / 造价 / 拒因**全部进悬停面板（`hud._hover_detail`）。
##   · 旧那版在格子里挤两行字（名字 + 效果）已经作废。
##   图标路径由 hud 塞在条目里（`icon_mask`）—— 本控件不认识「科技 id → 图片」这件事。
##
## ★ 上拖松手 / 快捷键走 `cell_activated(id)` → hud → input_controller 发 `tech_toggle` 命令，
##   本控件**从不改逻辑状态**（架构铁律：view 只读 + 发命令）。
extends Control

## 某一格被拖起并松手 / 快捷键激活：带上那一条科技的 id
signal cell_activated(id: String)
signal cell_drag_started(id: String, screen_pos: Vector2)
signal cell_drag_moved(id: String, screen_pos: Vector2)
signal cell_drag_finished(id: String, screen_pos: Vector2, index: int)

## ★★ 某一格被**鼠标悬停**（进入 / 离开）：带上格子序号。
##   hud 收到后弹「悬停详情面板」（与命令卡共用同一块，见 view/hover_tip.gd）——
##   两个控件的九格在屏幕上**逐像素重合**，所以悬停这件事也必须走同一块面板。
##   ★ 与命令卡同一条约定：只报序号，内容由 hud 按当前 entries 现取。
signal cell_hovered(index: int)
signal cell_unhovered(index: int)

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const ThemeRes = preload("res://view/theme.gd")
## ★★ 悬停「四边泛光」+「已启用 = 金色填充满格（切换时播动画）」的那套动效
##   （见 view/fill_button.gd）。
const FillButtonRes = preload("res://view/fill_button.gd")

## 格子里那两行小字的字号（80×80 的格子：名字一行 + 效果一行）
const FS_NAME := 13
const FS_LINE := 11
## 名字那条底条的高度（与命令卡 `NAME_BAR_H` 同口径：名字就压在这条上）
const NAME_BAR_H := 20.0
## 「打出一张牌」飞出那一段的时长（秒；飞回那段用 `_animate_card_back` 的 0.18）
const PLAYED_OUT_SEC := 0.16
## ★★ 2026.11.19（用户口径）：科技牌生效后，新卡也从**屏幕下方**以正常大小升入手牌位。
##   与命令卡 `CARD_RISE_SEC` 同一个手感。
const CARD_RISE_SEC := 0.26
## 拖起时把悬停的 1.5 倍缓动收回到 1.0（不再一帧硬缩）。
const DRAG_SCALE_SEC := 0.12
## 拖出后的卡面透明度（与 command_card 的 DRAG_CARD_ALPHA 同一档）。
## ★★ 2026.11.16（用户口径）：0.72 → 0.60 → 0.50 → 0.30。
const DRAG_CARD_ALPHA := 0.3
## ★★ 2026.11.16：悬停抬起 / 让开的缓动时长（与命令卡同一条手感）。
const HOVER_RAISE_SEC := 0.14
## ★★ 2026.11.16：悬停的那张牌放大多少（只放大悬停牌，邻居不动）。
const HOVER_SCALE := 1.6
## 图标层（画烘好的金线蒙版，与单位 / 建筑页同一套）
const UnitCardIconRes = preload("res://view/unit_card_icon.gd")

var _cells: Array[Button] = []
var _name_labels: Array[Label] = []
var _line_labels: Array[Label] = []
## 每格的图标层（画烘好的金线蒙版；见 `unit_card_icon.IconView`）
var _icon_views: Array = []
## 每格的**名字底条**（略黑半透明横条，名字压在它上面；空格子 / 没图标时隐藏）
var _name_bars: Array[ColorRect] = []
## ★★ 每格左上角的键位字母（与命令卡同一套 QWE / ASD / ZXC）。
var _key_labels: Array[Label] = []
## 上一次喂进来的条目（测试与调试读它；也是拖牌 / 快捷键回调的 id 来源）
var _entries: Array = []
## ★★ 2026.11.5：这一格**第一次拿到内容**时同步的「已启用」直接满格（不播动画）；
##   之后玩家点启用 / 弃用才播填充 / 退回。
var _primer_done: bool = false
var _deck_tween: Tween = null
var _drag_tween: Tween = null
## ★★ 2026.11.19：拖起时把悬停放大缓动收回到正常大小（与命令卡同一条）。
var _drag_scale_tween: Tween = null
var _drag_alpha_tween: Tween = null
## 拖拽透明度**目标值**（1.0 = 手里 / 0.3 = 地图上）。测试断言这个，
## 不直接等 0.12s 的渐变（无头测试里 40 帧可能还不到一帧的真实时间）。
var _drag_alpha_target: float = 1.0
## ★★ 2026.11.14：「打出一张牌」那一段单独一条 tween（见 `_animate_played_out()`）
var _played_tween: Tween = null
var _drag_index: int = -1
var _drag_start_pos := Vector2.ZERO
var _dragging: bool = false
## ★★ 2026.11.19：与命令卡一致的拖拽倾斜（按横向速度，最多约 5°）。
const DRAG_TILT_MAX := 0.09
const DRAG_TILT_PER_PX := 0.0022
var _drag_last_pointer := Vector2.ZERO
var _drag_tilt: float = 0.0
## ★★ 2026.11.16：当前被悬停的格子（条目下标，-1 = 没有）。
##   其余格按距离向左右散开，避免盖住这一格（与 view/command_card.gd 同一条口径）。
var _hover_index: int = -1
## ★★ 2026.11.16：每格「悬停抬起 / 让开」的 Tween（再次悬停 / 换页 / 拖牌前先杀掉）。
var _hover_tweens: Array = []
## ★★ 2026.11.17（用户口径）：**拖出手牌时其余手牌往屏幕下方沉 + 缩小**，松手反向浮回。
##   与命令卡（`command_card._tucked`）同一套数值 / 同一条换算（`UiLayoutRes.CARD_TUCK_*`）——
##   用户口径：「科技和手牌是一样的，所有的手牌都走一套逻辑」。
var _tucked: bool = false

## ★★ 手机端：按住某一格期间由 hud 置 true —— 忽略「按下」带来的模拟 mouse_entered，
##    悬停详情只在长按够久之后由 hud 调 `hover()` 弹出（与 view/command_card.gd 同一条）。
var touch_suppress_hover: bool = false


func setup() -> void:
	name = "TechGrid"
	# ★ 科技页才显示；其余页签整块藏起来（见 `set_visible_page`）。
	#   ⚠️ 隐藏时**必须**是 IGNORE：Godot 里隐藏的 Control 不吃事件，
	#      但万一哪天改成「半透明可见」，STOP 会把下面命令卡的点击全吞掉。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# ★★ 2026.11.14：与命令卡**逐像素重合** ⇒ 手牌改成底部居中后这里也要一起改，
	#   否则科技九格会留在原来的位置（换页时整块跳走）。
	UiLayoutRes.apply_bottom_center(self, UiLayoutRes.CARD_RECT)

	for i in UiLayoutRes.CARD_SLOTS:
		var cell := Button.new()
		cell.name = "TechCell%d" % (i + 1)
		cell.focus_mode = Control.FOCUS_NONE
		cell.clip_text = true
		# ★★ 2026.11.14：**不要**裁剪子节点 —— 投影现在由填充层（show_behind_parent 的子节点）
#   画在卡身下面（见 view/fill_button.gd 的 _ensure_shadow()），clip_contents = true
#   会把它裁在卡框里，于是卡看起来「没有投影」（用户报的科技卡那条）。
#   卡里的图标 / 名字条本来就都摆在框内，解除裁剪不会溢出。
		cell.visible = false
		_style_cell(cell, false, false)
		UiLayoutRes.apply_rect(cell, UiLayoutRes.card_cell_local(i))
		cell.pressed.connect(_on_cell_pressed.bind(i))
		cell.gui_input.connect(_on_cell_gui_input.bind(i))
		# ★ 悬停信号（与命令卡同一套，见文件头那个信号块）。
		#   ⚠️ 空格子（`disabled = true`）也照样发 mouse_entered —— hud 那一侧取不到
		#      entry，自然什么都不弹（`entry_at` 越界返回 {}）。
		cell.mouse_entered.connect(_on_cell_mouse_entered.bind(i))
		cell.mouse_exited.connect(_on_cell_mouse_exited.bind(i))
		# ★★ 2026.11.14：悬停泛光 + 启用填充（一行挂上，见 view/fill_button.gd）
		FillButtonRes.attach_text(cell)
		# ★★ 2026.11.14（用户口径）：「手牌不需要有悬停时的四个角显示了」——
		#   科技牌同样在扇形手牌里，也不画四角括号。
		FillButtonRes.set_reticle(cell, false)
		# ★★ 科技格有自己的点击反馈（启用 = 填满、弃用 = 退回）——
		#   关掉「点击闪光」，否则两边会抢同一份 `_fill`。
		FillButtonRes.set_click_flash(cell, false)
		# ★★ 常驻灰底：底纹（`tech_fill*`）是全透明的，灰底画在填充层里、
		#   金的下层 —— 悬停 / 启用时灰底不消失，金只是盖上去。
		#   ★★ 2026.11.14（用户口径）：「科技卡牌的底色与其他卡牌不同」——
		#     原来这里是 `bg_empty()`（0.55 半透明）⇒ 科技牌比命令卡暗一大截。
		#     现在与命令卡**同一个底**（`bg()`），两边的卡身逐像素一致。
		FillButtonRes.set_base_bg(cell, UiStyleRes.bg())
		# ★ 与命令卡同一口径：字色走「跟着金色前沿由白变黑」那条统一规则
		#   （`set_prefer_light` 是历史遗留的作废开关，见 fill_button 里的说明）。
		FillButtonRes.set_prefer_light(cell, true)
		add_child(cell)

		# ★★ 图标：和单位 / 建筑页同一套（`unit_card_icon.IconView` 画烘好的金线蒙版）。
		#    **铺满整格**、不考虑文字位置；名字叠在最下面那条底条上（与命令卡同口径）。
		var cell_size: Vector2 = UiLayoutRes.card_cell_local(i).size
		var icon_view := UnitCardIconRes.IconView.new()
		icon_view.name = "TechIcon%d" % (i + 1)
		cell.add_child(icon_view)
		icon_view.bind(cell)

		# ★ 名字底条（略黑半透明横条）：压在图标上，保证名字读得清。
		var name_bar := ColorRect.new()
		name_bar.name = "TechNameBar%d" % (i + 1)
		name_bar.color = UiStyleRes.name_bar()
		name_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_bar.position = Vector2(0.0, cell_size.y - NAME_BAR_H)
		name_bar.size = Vector2(cell_size.x, NAME_BAR_H)
		name_bar.visible = false
		cell.add_child(name_bar)

		# 第一行：科技名（压在最下面那条底条上，字号小一档）
		var name_label := Label.new()
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.clip_text = true
		name_label.add_theme_font_size_override("font_size", FS_LINE)
		name_label.size = Vector2(cell_size.x - 2.0, NAME_BAR_H)
		name_label.position = Vector2(1.0, cell_size.y - NAME_BAR_H)
		cell.add_child(name_label)

		# 第二行：效果小字 —— **不再显示**（描述进悬停面板）。控件保留：
		#   填充层的文字登记按对象走，删掉的话 `on_fill_text` 那张表要另记一份。
		var line_label := Label.new()
		line_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		line_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		line_label.add_theme_font_size_override("font_size", FS_LINE)
		line_label.size = Vector2(cell_size.x, cell_size.y * 0.34)
		line_label.position = Vector2(0.0, cell_size.y * 0.58)
		line_label.visible = false
		cell.add_child(line_label)

		# ★★ 键位字母（与命令卡 / 页签同一套）：画在左上角。
		var key_label := Label.new()
		key_label.text = String(UiLayoutRes.CARD_KEYS[i])
		key_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		key_label.add_theme_font_size_override("font_size", UiStyleRes.FS_TINY)
		key_label.add_theme_color_override("font_color", UiStyleRes.text_faint())
		key_label.position = Vector2(4.0, 1.0)
		cell.add_child(key_label)

		# ★ 三条子 Label 登记到填充上：填满时它们会一起被压成暖黑（否则暖白压金读不出来）
		FillButtonRes.on_fill_text(cell, name_label, UiStyleRes.text())
		FillButtonRes.on_fill_text(cell, line_label, UiStyleRes.text_dim())
		FillButtonRes.on_fill_text(cell, key_label, UiStyleRes.text_faint())

		_cells.append(cell)
		_name_labels.append(name_label)
		_line_labels.append(line_label)
		_key_labels.append(key_label)
		_name_bars.append(name_bar)
		_icon_views.append(icon_view)

	set_entries([])


# ------------------------------------------------------------------
# 每帧喂内容（由 hud 按权威状态算好）
# ------------------------------------------------------------------

## 换一份内容。每条 = {id, name, line, desc, active}
##   · 最多 9 条（顺序 = 左上 → 右下）；
##   · 缺的格子画成空（置灰、点了不做事）；
##   · `active` 决定这一格画「已启用」的那套样式（实心金 + 亮描边）。
##
## ★ 每帧都会被调（hud.refresh 里）——所以这里只在**内容真的变了**时才写控件，
##   否则每帧 add_theme_*_override 会白白重建 StyleBox（与 page_tabs 同一条讲究）。
func set_entries(list: Array) -> void:
	# ★★ 2026.11.17：拖牌途中被重建（典型：松手生效 → HUD 立刻刷新）时必须**保住下沉状态**，
	#   否则 `_layout_fan()` 会把其余牌瞬间弹回原位，紧接着的反向动画就没东西可动。
	var was_dragging := _dragging
	var clean: Array = []
	for item in list:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		if clean.size() >= UiLayoutRes.CARD_SLOTS:
			break
		clean.append(item)
	if _same_entries(clean):
		return
	if _deck_tween != null and _deck_tween.is_running():
		_deck_tween.kill()
	if _drag_tween != null and _drag_tween.is_running():
		_drag_tween.kill()
	if _drag_scale_tween != null and _drag_scale_tween.is_running():
		_drag_scale_tween.kill()
	if _drag_alpha_tween != null and _drag_alpha_tween.is_running():
		_drag_alpha_tween.kill()
	for cell in _cells:
		cell.modulate.a = 1.0
	_drag_alpha_target = 1.0
	_entries = clean
	# ★★ 2026.11.17：只有「拖牌途中被重建」才保住下沉状态（松手那条路紧接着会反向播回来）；
	#   其余情况（换页 / 选别的东西）一律回原位，免得上一次拖牌的下沉状态漏到这里。
	_tucked = _tucked and was_dragging
	_apply()
	# ★★ 2026.11.17 保险：拖牌途中被重建时，`_finish_touch_drag()` 可能永远不来 ——
	#   下一帧查一次（见 `_tuck_fallback`），否则科技牌会永远缩在下面。
	if was_dragging:
		call_deferred("_tuck_fallback")


func _same_entries(clean: Array) -> bool:
	if clean.size() != _entries.size():
		return false
	for i in clean.size():
		var a: Dictionary = clean[i]
		var b: Dictionary = _entries[i]
		if String(a.get("id", "")) != String(b.get("id", "")):
			return false
		if String(a.get("name", "")) != String(b.get("name", "")):
			return false
		if String(a.get("line", "")) != String(b.get("line", "")):
			return false
		if String(a.get("desc", "")) != String(b.get("desc", "")):
			return false
		if bool(a.get("active", false)) != bool(b.get("active", false)):
			return false
		if bool(a.get("available", true)) != bool(b.get("available", true)):
			return false
		if bool(a.get("playable", true)) != bool(b.get("playable", true)):
			return false
		if bool(a.get("destroyed", false)) != bool(b.get("destroyed", false)):
			return false
		if String(a.get("reason", "")) != String(b.get("reason", "")):
			return false
	return true


## ★★ 2026.11.19：科技页现在和手牌一样是**一排扇形卡牌**（`_layout_fan`），不再是九宫格。
##   但「第几个格子」这套坐标还在用（动效 / 拖牌 / 悬停都按格子序号走），所以仍然需要
##   把一个**槽位下标**翻成一个**格子序号**：
##     · `clan.list[].tech` 的 9 个槽位按 **3 个一组**写，一组 = 一个阶；
##     · 扇形里从左到右依次是一阶组 → 二阶组 → 三阶组，组内按槽位序号（第 1 → 第 4 → 第 7）；
##     · ⇒ 槽位 i 落在格子 `(i % 3) * 3 + i / 3`（转置），反过来就是下面的逆变换。
##   ⚠️ 说人话：**斜着数**。第 1/4/7 槽 = 一阶、第 2/5/8 = 二阶、第 3/6/9 = 三阶。
##   编辑器的同一套口径见 `tools/tech_editor/model.py::_tech_slot_position`。
func _entry_index_for_cell(cell: int) -> int:
	return (cell % UiLayoutRes.CARD_COLS) * UiLayoutRes.CARD_ROWS \
		+ int(cell / UiLayoutRes.CARD_COLS)


## 第 i 格的图标层换图（空串 = 没图、只剩名字）。
## `locked` = 这一格现在不能启用（阶数不够 / 名额满）⇒ 图标画暗一档，与命令卡同口径。
func _set_icon(i: int, path: String, locked: bool) -> void:
	if i < 0 or i >= _icon_views.size():
		return
	var v = _icon_views[i]
	if v == null or not is_instance_valid(v):
		return
	v.set_mask(path)
	v.set_ready(not locked)


## 第 i 格现在画的是哪张图标蒙版（空串 = 没图）。测试用。
func cell_icon_path(i: int) -> String:
	if i < 0 or i >= _icon_views.size():
		return ""
	var v = _icon_views[i]
	if v == null or not is_instance_valid(v):
		return ""
	return String(v.mask_path())


## 第 i 格的名字底条显示 / 隐藏（有科技的格子才垫这条）。
func _set_bar(i: int, on: bool) -> void:
	if i < 0 or i >= _name_bars.size():
		return
	var b := _name_bars[i]
	if b != null and is_instance_valid(b):
		b.visible = on


## ★ 底条跟着金色填充淡出（理由同命令卡：填充从下往上，底条在最下面，
##   金色盖上来之后字会翻成压金暗色，深底 + 深字就读不出来了）。每帧 9 格，开销可忽略。
func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	for i in _name_bars.size():
		var bar: ColorRect = _name_bars[i]
		if bar == null or not is_instance_valid(bar) or not bar.visible:
			continue
		if i >= _cells.size():
			continue
		var p: float = clampf(FillButtonRes.fill_progress(_cells[i]), 0.0, 1.0)
		var c := UiStyleRes.name_bar()
		bar.color = Color(c.r, c.g, c.b, c.a * (1.0 - p))


func _apply() -> void:
	# ★★ 第一次拿到内容（含「全是未启用」）时，已启用的格子**直接满格**；
	#   不可见时（科技页没开）也直接到位 —— 没人看着的时候不该「攒」一段动画，
	#   否则下次打开科技页会先看到一格从空填上来。
	#   之后玩家点启用 / 弃用才播填充 / 退回（见 view/fill_button.gd）。
	var instant: bool = not _primer_done or not is_visible_in_tree()
	for i in _cells.size():
		var cell := _cells[i]
		# ★★ 2026.11.16 修 bug：重建 / 换牌后清掉旧的悬停填充（理由同 command_card.set_entries）。
		FillButtonRes.clear_hover_in(cell)
		var ei := _entry_index_for_cell(i)
		# ★★ 2026.11：**空槽位**（派系科技不满 9 条时那张表里的占位，`id == ""`）与
		#   「根本没有条目」走同一条路：不显示名字、不可点、不参与填充动效
		#   （用户口径：空位画灰框不可点）。
		var filled: bool = ei >= 0 and ei < _entries.size() \
			and String((_entries[ei] as Dictionary).get("id", "")) != ""
		var active := false
		var locked := false
		if filled:
			var e: Dictionary = _entries[ei]
			active = bool(e.get("active", false))
			# ★★ 2026.11.18：已启用的科技保留在页面上（实心），但不可再打出 / 不可取消；
			#   未启用且不可用的格子仍走灰色。
			locked = not active and not bool(e.get("available", true))
			_name_labels[i].text = String(e.get("name", ""))
			_line_labels[i].text = String(e.get("line", ""))
			# ★★ 图标：蒙版路径由 hud 塞在条目里（`tech_<id>.png`，缺图时为空串，
			#   这一格就只剩名字 —— 不会画错、也不会崩）。
			_set_icon(i, String(e.get("icon_mask", "")), locked)
			_set_bar(i, true)
			cell.disabled = false             # 保持可悬停（悬停要能解释原因）
			# ★★ 走「登记原色」的接口，而不是直接写 font_color override：
			#   填充动效每帧都按「原色 + 当前填充进度」重算（见 fill_button._sync_text）。
			#   ★★ 2026.11.5：已启用的格子**也登记亮色**（不再用近黑的 text_on_accent）——
			#     选中要播填充动画，若一上来就把字设成近黑，动画头 0.1 秒里
			#     「黑字压黑底」读不出来。亮色会在金扫到它时由翻面自动变黑。
			FillButtonRes.set_base_font_color(cell, UiStyleRes.text())
			FillButtonRes.on_fill_text(cell, _line_labels[i],
				Color(1.0, 1.0, 1.0, 0.85) if active else UiStyleRes.text_dim())
			FillButtonRes.on_fill_text(cell, _key_labels[i],
				UiStyleRes.text_faint() if locked else UiStyleRes.text())
			# ★★ 已启用 = 金色填充满格（切换时播动画；建出来那一下直接满格）
			FillButtonRes.set_latched(cell, active, instant)
			# ★★ 这一格「有科技」⇒ 参与悬停泛光。
			#   不能启用的格子**也参与**，只是把泛光换成灰色（用户口径：
			#   「灰色代替金色 + 点击后无效果」，不是实心灰按钮）。
			FillButtonRes.set_available(cell, true)
			FillButtonRes.set_grey(cell, locked)
		else:
			_name_labels[i].text = ""
			_line_labels[i].text = ""
			_set_icon(i, "", false)
			_set_bar(i, false)
			cell.disabled = true              # 空格子点了不做事（也不吃键盘）
			FillButtonRes.set_base_font_color(cell, UiStyleRes.text_faint())
			FillButtonRes.on_fill_text(cell, _line_labels[i], UiStyleRes.text_faint())
			FillButtonRes.on_fill_text(cell, _key_labels[i], UiStyleRes.text_faint())
			FillButtonRes.set_latched(cell, false)
			FillButtonRes.set_grey(cell, false)
			# ★ 空格子**不参与任何动效**：它连「科技」都没有，亮起来会让人以为这一格能点。
			FillButtonRes.set_available(cell, false)
		_style_cell(cell, filled, active, locked)
		cell.visible = filled
	_layout_fan()
	if not _entries.is_empty():
		_primer_done = true


## 科技页沿用同一扇形牌区；空配置槽隐藏，locked 仍是实际科技项，保留灰化状态。
func _layout_fan() -> void:
	_kill_hover_tweens()
	_hover_index = -1
	# ★★ 2026.11.18：与 `_visible_cell_indices()` 共用同一条判据，避免「摆牌」和
	#   「悬停让开 / 下沉」数出不同的张数（序号一错，牌就落到别人的槽位）。
	var visible_cells: Array[int] = _visible_cell_indices()
	var count := visible_cells.size()
	# ★★ 2026.11.17：重建时若正处在「拖牌 → 其余牌下沉」状态，直接摆成下沉位
	#   （否则这一帧弹回原位、下一帧再沉下去，看得见抽动）。见 `_set_deck_tucked()`。
	var tuck := 1.0 if _tucked else 0.0
	var tuck_scale := UiLayoutRes.card_tuck_scale(tuck)
	var tuck_sv := Vector2(tuck_scale, tuck_scale)
	for ordinal in count:
		var i := visible_cells[ordinal]
		var cell := _cells[i]
		var r := UiLayoutRes.card_fan_local(ordinal, count)
		var pose: Vector2 = r.position + UiLayoutRes.card_tuck_offset(r.size, tuck)
		# ★★ 2026.11.18：支点统一为牌底中点（见 `UiLayoutRes.card_pivot`）。
		cell.pivot_offset = UiLayoutRes.card_pivot(r.size)
		cell.position = pose
		cell.size = r.size
		cell.rotation = UiLayoutRes.card_fan_rotation(ordinal, count)
		cell.scale = tuck_sv
		cell.z_index = ordinal
		_key_labels[i].position = Vector2(8.0, 6.0)
		_name_bars[i].position = Vector2(0.0, r.size.y - NAME_BAR_H)
		_name_bars[i].size = Vector2(r.size.x, NAME_BAR_H)
		_name_labels[i].position = Vector2(1.0, r.size.y - NAME_BAR_H)
		_name_labels[i].size = Vector2(r.size.x - 2.0, NAME_BAR_H)
		_line_labels[i].size = Vector2(r.size.x, r.size.y * 0.34)
		_line_labels[i].position = Vector2(0.0, r.size.y * 0.58)


## 三个状态各自一套样式。
##
## ★★ 本版把「未启用」与「已启用」的底色**交给填充层**（`tech_fill()` / `tech_latched()`：
##    底透明、只留描边）—— 旧那版是不透明实底（`tech_normal()` / `tech_active()`），
##    它会把画在底纹**下面**的填充金整个盖住，于是「选中的金色填充」根本看不见。
##   ⇒ 现在：未启用 = 空框；悬停 = 四边泛光；已启用 = 金色填充满格（切换时播动画）。
##   ⚠️ 空格子（`filled = false`）仍用 `tech_disabled()` 的实底 —— 它不是按钮，
##      它是「这里没有科技」的一块底板，本来就该是死的。
func _style_cell(cell: Button, filled: bool, active: bool, locked: bool = false) -> void:
	if not filled:
		cell.add_theme_stylebox_override("normal", UiStyleRes.tech_disabled())
		cell.add_theme_stylebox_override("hover", UiStyleRes.tech_disabled())
		cell.add_theme_stylebox_override("pressed", UiStyleRes.tech_disabled())
		cell.add_theme_stylebox_override("disabled", UiStyleRes.tech_disabled())
	elif locked:
		# ★★ 不可启用 = **与普通格同一套透明底纹**，靠填充层画**灰色**填充；
		#   不铺实底（否则灰填充会被压在底纹下面，又变成一坨灰按钮）。
		cell.add_theme_stylebox_override("normal", UiStyleRes.tech_fill())
		cell.add_theme_stylebox_override("hover", UiStyleRes.tech_fill())
		cell.add_theme_stylebox_override("pressed", UiStyleRes.tech_fill())
		cell.add_theme_stylebox_override("disabled", UiStyleRes.tech_fill())
	elif active:
		cell.add_theme_stylebox_override("normal", UiStyleRes.tech_latched())
		cell.add_theme_stylebox_override("hover", UiStyleRes.tech_latched())
		cell.add_theme_stylebox_override("pressed", UiStyleRes.tech_latched())
		cell.add_theme_stylebox_override("disabled", UiStyleRes.tech_latched())
	else:
		cell.add_theme_stylebox_override("normal", UiStyleRes.tech_fill())
		cell.add_theme_stylebox_override("hover", UiStyleRes.tech_fill_hover())
		# ★ 按下统一成 2px 亮边（与菜单 / 命令卡同一档）；松手后再切到启用态
		cell.add_theme_stylebox_override("pressed", UiStyleRes.tech_latched())
		cell.add_theme_stylebox_override("disabled", UiStyleRes.tech_fill())
	cell.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


func _on_cell_pressed(i: int) -> void:
	# 鼠标点按不打出科技牌；鼠标牌统一向上拖起并松手，键盘走 handle_key。
	return


func _activate_cell(i: int) -> void:
	var ei := _entry_index_for_cell(i)
	if ei < 0 or ei >= _entries.size():
		return
	var e: Dictionary = _entries[ei]
	# ★★ 2026.11.18：科技打出后不可再次打出 / 不可取消；已启用与已被销毁的格子都不响应。
	if not bool(e.get("playable", true)):
		return
	cell_activated.emit(String(e.get("id", "")))


func _on_cell_gui_input(event: InputEvent, i: int) -> void:
	if OS.has_feature("mobile") or touch_suppress_hover:
		return # 触屏由 HUD 的长按 / 拖牌识别统一路由。
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			_drag_index = i
			_drag_start_pos = get_viewport().get_mouse_position()
			_dragging = false
		elif _drag_index == i:
			_finish_touch_drag(i, get_viewport().get_mouse_position())
		return
	if event is InputEventMouseMotion and _drag_index == i:
		var mm := event as InputEventMouseMotion
		if (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
			return
		_update_drag(i, get_viewport().get_mouse_position())
		if _dragging:
			accept_event()


func _update_drag(i: int, viewport_pos: Vector2) -> bool:
	if i < 0 or i >= _cells.size():
		return false
	var ei := _entry_index_for_cell(i)
	if ei < 0 or ei >= _entries.size():
		return false
	var entry: Dictionary = _entries[ei]
	# ★★ 2026.11.18：已启用 / 已销毁的科技牌不能再拖出。
	if not bool(entry.get("playable", true)):
		return false
	if not _dragging and viewport_pos.y - _drag_start_pos.y <= -10.0:
		_dragging = true
		# ★★ 2026.11.16：拖牌前先撤掉悬停 Tween（否则它会继续写被拖那张牌的 position），
		#   再把刚才让开的邻居收回原位。
		_kill_hover_tweens()
		if _hover_index >= 0:
			_settle_spread(i)
		_hover_index = -1
		# ★★ 2026.11.17（用户口径）：拖起来 ⇒ 其余科技牌往屏幕下方沉 + 缩小。
		_set_deck_tucked(true, i, true)
		# 被悬停的牌是放大态；拖起来缓动回到 1.0（不再一帧硬缩）。
		if _drag_scale_tween != null and _drag_scale_tween.is_running():
			_drag_scale_tween.kill()
		if absf(_cells[i].scale.x - 1.0) > 0.001:
			_drag_scale_tween = create_tween()
			_drag_scale_tween.tween_property(_cells[i], "scale", Vector2.ONE,
				DRAG_SCALE_SEC).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		# ★★ 2026.11.18：入场 / 淡出途中被抓起来时，先把手里的牌恢复成不透明
		#   （与命令卡同一句），再交给 `_set_drag_alpha()` 按位置渐变。
		_cells[i].modulate.a = 1.0
		_drag_last_pointer = viewport_pos
		_drag_tilt = 0.0
		if _deck_tween != null and _deck_tween.is_running():
			_deck_tween.kill()
		if _drag_tween != null and _drag_tween.is_running():
			_drag_tween.kill()
		_cells[i].z_index = UiLayoutRes.CARD_SLOTS + 4
		cell_drag_started.emit(String(entry.get("id", "")), viewport_pos)
	if not _dragging:
		return false
	var local: Vector2 = get_global_transform_with_canvas().affine_inverse() * viewport_pos
	# ★★ 2026.11.19：横向速度 → 轻微倾斜（与命令卡同一条手感）。
	var dx := viewport_pos.x - _drag_last_pointer.x
	_drag_last_pointer = viewport_pos
	var want_tilt := clampf(dx * DRAG_TILT_PER_PX, -DRAG_TILT_MAX, DRAG_TILT_MAX)
	_drag_tilt = lerpf(_drag_tilt, want_tilt, 0.35)
	_cells[i].rotation = _drag_tilt
	_cells[i].position = local - _cells[i].size * 0.5
	# ★ 与命令卡同一套：拖到地图上半透明，拖回手牌范围淡回来（不再硬切 0.3）。
	_set_drag_alpha(i, true)
	cell_drag_moved.emit(String(entry.get("id", "")), viewport_pos)
	return true


## 科技牌拖出后的透明度：手牌范围内 1.0，拖到地图上 `DRAG_CARD_ALPHA`。
## ★★ 2026.11.18：旧版在 `_update_drag` 里直接写 0.3（一帧硬切），与命令卡的
##   0.12s 渐变不一致，拖起的瞬间会「啪」一下变淡。
func _set_drag_alpha(i: int, follow_pointer: bool) -> void:
	if i < 0 or i >= _cells.size():
		return
	var target := 1.0
	if follow_pointer:
		var rect := Rect2(Vector2.ZERO, UiLayoutRes.CARD_RECT.size).grow(40.0)
		var center: Vector2 = _cells[i].position + _cells[i].size * 0.5
		if not rect.has_point(center):
			target = DRAG_CARD_ALPHA
	_drag_alpha_target = target
	if absf(_cells[i].modulate.a - target) < 0.001:
		if _drag_alpha_tween != null and _drag_alpha_tween.is_running():
			_drag_alpha_tween.kill()
		return
	if _drag_alpha_tween != null and _drag_alpha_tween.is_running():
		_drag_alpha_tween.kill()
	_drag_alpha_tween = create_tween()
	_drag_alpha_tween.tween_property(_cells[i], "modulate:a", target, 0.12)


func _finish_touch_drag(i: int, viewport_pos: Vector2) -> void:
	if i >= 0 and i < _cells.size() and _dragging:
		# ★★ 2026.11.16 修 bug：拖出后按钮不再收 mouse_exited，显式清掉悬停填充。
		FillButtonRes.clear_hover_in(_cells[i])
		# ★★ 2026.11.14（用户口径）：「被拖拽往上生效后，该卡牌将以金色填充形态放回手牌中，
		#   取消启用科技则是将启用的科技牌**打出**」。
		#   ⇒ 松手前先记下「这张牌本来是不是启用着」，用来决定回手的动画：
		#     · 刚才未启用 → 现在启用：飞回手牌（填充金由 `set_latched` 现场播）
		#     · 刚才启用着 → 现在取消：先「打出去」，再飞回手牌
		var was_active := false
		var ei := _entry_index_for_cell(i)
		if ei >= 0 and ei < _entries.size():
			was_active = bool((_entries[ei] as Dictionary).get("active", false))
		var from_pos: Vector2 = _cells[i].position
		var from_rot: float = _cells[i].rotation
		cell_drag_finished.emit(entry_id_at(i), viewport_pos, i)
		# ★★ 2026.11.19（用户口径）：**生效成功 = 新卡从屏幕下方升起**；
		#   被拒 / 拖回 UI 才算「回手」，走 `_animate_card_back()`。
		#   判据是松手后权威状态是否把这一格变成「已启用」——与 HUD 的发命令路径同一条。
		var used := false
		if not was_active:
			var ei2 := _entry_index_for_cell(i)
			if ei2 >= 0 and ei2 < _entries.size():
				used = bool((_entries[ei2] as Dictionary).get("active", false))
		if used:
			_animate_used_card_in(i)
		else:
			# ⚠️ 上面那一句会让 hud `refresh()` → `_refresh_tech_grid()` → `_layout_fan()`，
			#   把这张牌**直接摆回扇位**（于是后面的「飞回去」变成原地淡入，看不出动作）。
			#   所以这里把位置还原成松手那一刻，动画才是从手上飞回去的。
			if i < _cells.size() and is_instance_valid(_cells[i]):
				_cells[i].position = from_pos
				_cells[i].rotation = from_rot
			if was_active:
				_animate_played_out(i)
			else:
				_animate_card_back(i)
	_dragging = false
	_drag_index = -1
	_drag_alpha_target = 1.0
	# ★★ 2026.11.17（用户口径）：松手即反向 —— 其余科技牌浮回原位。
	#   ⚠️ 必须放在 `cell_drag_finished` 之后：那一句会让 HUD 重建（`_layout_fan`），
	#   重建时 `_tucked` 还保着（见 `set_entries`），这里才开始浮回。
	if i >= 0:
		_set_deck_tucked(false, i, true)


## 「打出」一张牌：向上飞 + 淡出，然后从上方飞回手牌、淡入（= 取消启用时的过场）。
##
## ★ 为什么是「飞出去再飞回来」而不是直接退填：用户口径要的就是「打出一张牌」的动作感，
##   同时这张科技仍然是手牌里的一张（不能真删），所以出去之后必须回来。
## ★ 飞出用 ease-out（起步快），飞回用 `_animate_card_back()`（它已经是 0.18s 的
##   TRANS_BACK，落位时有一点回弹，和命令卡那边同一套手感）。
func _animate_played_out(i: int) -> void:
	if i < 0 or i >= _cells.size():
		return
	var cell := _cells[i]
	if not is_instance_valid(cell):
		return
	if _played_tween != null and _played_tween.is_running():
		_played_tween.kill()
	if _drag_tween != null and _drag_tween.is_running():
		_drag_tween.kill()
	if _drag_scale_tween != null and _drag_scale_tween.is_running():
		_drag_scale_tween.kill()
	if _drag_alpha_tween != null and _drag_alpha_tween.is_running():
		_drag_alpha_tween.kill()
	# ★ 用**单独一条** tween：它跑完要回调 `_animate_card_back()`，而那一条会 kill
	#   `_drag_tween`——如果共用一条，会把自己 kill 掉、飞回那一段永远不播（实测过）。
	_played_tween = create_tween().set_parallel(true)
	_played_tween.tween_property(cell, "position", cell.position + Vector2(0.0, -170.0),
		PLAYED_OUT_SEC).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_played_tween.tween_property(cell, "rotation", 0.0, PLAYED_OUT_SEC) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_played_tween.tween_property(cell, "modulate:a", 0.0, PLAYED_OUT_SEC)
	_played_tween.finished.connect(func() -> void:
		if not is_instance_valid(cell) or not is_instance_valid(self):
			return
		# 淡到 0 之后立刻从扇位淡回来（`_animate_card_back` 里带了 modulate → 1）
		cell.modulate.a = 0.0
		_animate_card_back(i)
	)


## ★★ 2026.11.19（用户口径）：牌生效后，**在屏幕下方生成一张正常大小的新牌**，
##   再把它上移到自己的手牌槽位（与命令卡 `_restore_card_at_slot()` 同一套口径）。
##
## 起点 y = `CARD_RECT.size.y + 8`：科技牌区就贴在屏幕底边，超过这个高度就是屏幕外，
## 整张牌从底下升上来；起点就是 1.0 倍，不会出现「由小变大」的突变。
func _animate_used_card_in(i: int) -> void:
	if i < 0 or i >= _cells.size():
		return
	var slot := _fan_slot_of(i)
	if slot.is_empty():
		return
	var cell := _cells[i]
	if not is_instance_valid(cell):
		return
	if _drag_tween != null and _drag_tween.is_running():
		_drag_tween.kill()
	if _drag_scale_tween != null and _drag_scale_tween.is_running():
		_drag_scale_tween.kill()
	if _drag_alpha_tween != null and _drag_alpha_tween.is_running():
		_drag_alpha_tween.kill()
	if _played_tween != null and _played_tween.is_running():
		_played_tween.kill()
	var r: Rect2 = slot["rect"]
	var rot: float = slot["rot"]
	var ordinal: int = slot["ordinal"]
	var start := Vector2(r.position.x, UiLayoutRes.CARD_RECT.size.y + 8.0)
	cell.position = start
	cell.rotation = 0.0
	cell.size = r.size
	cell.scale = Vector2.ONE
	cell.pivot_offset = UiLayoutRes.card_pivot(r.size)
	cell.modulate.a = 1.0
	cell.z_index = ordinal
	_drag_tween = create_tween().set_parallel(true)
	_drag_tween.tween_property(cell, "position", r.position, CARD_RISE_SEC) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_drag_tween.tween_property(cell, "rotation", rot, CARD_RISE_SEC) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_drag_tween.finished.connect(func() -> void:
		if not is_instance_valid(self) or i < 0 or i >= _cells.size() or _dragging:
			return
		var now := _fan_slot_of(i)
		if now.is_empty():
			return
		var nr: Rect2 = now["rect"]
		_cells[i].position = nr.position
		_cells[i].rotation = float(now["rot"])
		_cells[i].size = nr.size
		_cells[i].scale = Vector2.ONE
		_cells[i].pivot_offset = UiLayoutRes.card_pivot(nr.size)
	, CONNECT_ONE_SHOT)


func begin_touch_drag(i: int, viewport_pos: Vector2) -> void:
	_drag_index = i
	_drag_start_pos = viewport_pos
	_dragging = false


func move_touch_drag(i: int, viewport_pos: Vector2) -> bool:
	if i != _drag_index:
		return false
	return _update_drag(i, viewport_pos)


func finish_touch_drag(i: int, pos: Vector2 = Vector2.INF) -> void:
	var at: Vector2 = pos
	if not at.is_finite() or at == Vector2.INF:
		at = get_viewport().get_mouse_position() if get_viewport() != null else Vector2.ZERO
	_finish_touch_drag(i, at)


func entry_id_at(i: int) -> String:
	var ei := _entry_index_for_cell(i)
	if ei < 0 or ei >= _entries.size():
		return ""
	return String((_entries[ei] as Dictionary).get("id", ""))


## 科技牌飞回它的扇形槽位。
##
## ★★ 2026.11.18：与命令卡 `_animate_card_back()` 统一：
##   · CUBIC（不再用 BACK —— BACK 会先冲过槽位再弹回来，看着像「回到手牌后又移了一下」）；
##   · **每帧重算槽位**：回手这 0.2s 里手牌可能因为启用 / 销毁 / 换页而重排，
##     按松手那一刻的序号硬落位会和别的牌重叠；
##   · 缩放随返程进度收回 1.0，末帧对齐支点与尺寸。
func _animate_card_back(i: int) -> void:
	if i < 0 or i >= _cells.size():
		return
	if _fan_slot_of(i).is_empty():
		return
	var start_pos: Vector2 = _cells[i].position
	var start_rot: float = _cells[i].rotation
	if _drag_tween != null and _drag_tween.is_running():
		_drag_tween.kill()
	if _drag_scale_tween != null and _drag_scale_tween.is_running():
		_drag_scale_tween.kill()
	if _drag_alpha_tween != null and _drag_alpha_tween.is_running():
		_drag_alpha_tween.kill()
	_drag_tween = create_tween().set_parallel(true)
	_drag_tween.tween_method(func(t: float) -> void:
		if _dragging or i >= _cells.size():
			return
		var now := _fan_slot_of(i)
		if now.is_empty():
			return
		var r: Rect2 = now["rect"]
		var no: int = now["ordinal"]
		_cells[i].pivot_offset = UiLayoutRes.card_pivot(r.size)
		_cells[i].size = r.size
		_cells[i].position = start_pos.lerp(r.position, t)
		_cells[i].rotation = lerp_angle(start_rot, float(now["rot"]), t)
		_cells[i].z_index = no
	, 0.0, 1.0, 0.2).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	# ★★ 2026.11.19（用户口径）：被拒回手时，缩放与位置分开 —— 位置照旧缓动，
	#   尺寸在同样的 0.2s 里**线性**收到 1.0（不再跟着 ease-out 先猛缩、后拖尾）。
	_drag_tween.tween_property(_cells[i], "scale", Vector2.ONE, 0.2) \
		.set_trans(Tween.TRANS_LINEAR)
	# 「打出」那一段会把牌淡到 0，这里必须淡回来。
	_drag_tween.tween_property(_cells[i], "modulate:a", 1.0, 0.12)
	_drag_tween.finished.connect(func() -> void:
		if not is_instance_valid(self) or i < 0 or i >= _cells.size() or _dragging:
			return
		var now := _fan_slot_of(i)
		if now.is_empty():
			return
		var r: Rect2 = now["rect"]
		_cells[i].pivot_offset = UiLayoutRes.card_pivot(r.size)
		_cells[i].size = r.size
		_cells[i].position = r.position
		_cells[i].rotation = float(now["rot"])
		if _hover_index != i:
			_cells[i].scale = Vector2.ONE
	, CONNECT_ONE_SHOT)


## 第 i 格在当前扇形里的位置 / 旋转 / 序号（空格返回 {}）。
func _fan_slot_of(i: int) -> Dictionary:
	var visible_cells := _visible_cell_indices()
	var ordinal := visible_cells.find(i)
	if ordinal < 0:
		return {}
	var r := UiLayoutRes.card_fan_local(ordinal, visible_cells.size())
	return {
		"rect": r,
		"rot": UiLayoutRes.card_fan_rotation(ordinal, visible_cells.size()),
		"ordinal": ordinal,
	}


## ★★ 键盘：科技页的九格快捷键（Q/W/E/A/S/D/Z/X/C）。
##
## ★ 与上拖松手**完全同一条路**：键位映射到视觉格 → `_activate_cell()` →
##   `cell_activated` → hud → `tech_toggle` 命令。这里不自己改任何逻辑状态。
## ★ 空格 / 置灰格**不吃按键**（与 `command_card.handle_key()` 同一条约定），
##   让这几个字母继续走别的绑定。
## ★ 带 Ctrl / Alt / Meta 的组合键一律放行（Ctrl+Q 全屏等）。
func handle_key(event: InputEventKey) -> bool:
	if not event.pressed or event.echo:
		return false
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return false
	var slot: int = int(UiLayoutRes.CARD_KEY_TO_SLOT.get(event.keycode, -1))
	if slot < 0 or slot >= _cells.size():
		return false
	var ei := _entry_index_for_cell(slot)
	if ei < 0 or ei >= _entries.size():
		return false
	var e: Dictionary = _entries[ei]
	if not bool(e.get("active", false)) and not bool(e.get("available", true)):
		return false
	_activate_cell(slot)
	return true


## 鼠标进入 / 离开第 i 格 —— 只转发序号（内容由 hud 现取，与命令卡同一条约定）
func _on_cell_mouse_entered(i: int) -> void:
	if _dragging:
		return
	if touch_suppress_hover:
		return                       # 手机端按住期间不弹（长按到点后由 hud 调 hover()）
	# ★★ 2026.11.18：入场动画还在播时不起悬停抬起（两条 Tween 会抢同一张牌的
	#   position / rotation，看起来像牌在抖）。悬停说明照常弹。
	if _deck_tween != null and _deck_tween.is_running():
		cell_hovered.emit(i)
		return
	_raise_card(i, true)
	cell_hovered.emit(i)


func _on_cell_mouse_exited(i: int) -> void:
	if _dragging:
		return
	_raise_card(i, false)
	cell_unhovered.emit(i)


## ★★ 2026.11.17（用户口径）：拖牌开始 / 结束时，把**其余手牌**沉下去 / 浮回来。
##
## 与 `command_card._set_deck_tucked()` 同一个行为、同一套数值（`UiLayoutRes.CARD_TUCK_*`），
## 只是科技格没有「卡面」子控件，只有格子自己。
##
## @param on      true = 下沉，false = 浮回原位
## @param except  正在被拖（或刚松手、正由返程 / 打出动画接管）的那一张：跳过它
## @param animate false = 直接到位（重建 / 无动画模式）
func _set_deck_tucked(on: bool, except_index: int, animate: bool = true) -> void:
	_tucked = on
	var visible_cells := _visible_cell_indices()
	var count := visible_cells.size()
	if count <= 0:
		return
	var tuck := 1.0 if on else 0.0
	var tuck_scale := UiLayoutRes.card_tuck_scale(tuck)
	for ordinal in count:
		var i := visible_cells[ordinal]
		if i == except_index:
			continue
		var base := UiLayoutRes.card_fan_local(ordinal, count)
		var pose: Vector2 = base.position + UiLayoutRes.card_tuck_offset(base.size, tuck)
		_ease_cell_pose(i, pose, UiLayoutRes.card_fan_rotation(ordinal, count),
			tuck_scale, true, UiLayoutRes.CARD_TUCK_SEC if animate else 0.0)


## 当前「有内容的格子」下标，按扇形序号排列（下沉 / 散开 / 落位共用一条判据）。
func _visible_cell_indices() -> Array[int]:
	var out: Array[int] = []
	for ci in _cells.size():
		var ei := _entry_index_for_cell(ci)
		if ei >= 0 and ei < _entries.size() \
				and String((_entries[ei] as Dictionary).get("id", "")) != "":
			out.append(ci)
	return out


## ★★ 2026.11.17 兜底：拖牌途中被重建时，`_finish_touch_drag()` 可能永远不来。
##   只有「还沉着的且已经不在拖」才浮回；正常松手那条路已经先放平了 ⇒ 这里是空操作。
func _tuck_fallback() -> void:
	if _dragging or not _tucked:
		return
	_set_deck_tucked(false, -1, true)


func _raise_card(i: int, raised: bool) -> void:
	if i < 0 or i >= _cells.size() or not _cells[i].visible:
		return
	var visible_cells: Array[int] = []
	for ci in _cells.size():
		var ei := _entry_index_for_cell(ci)
		if ei >= 0 and ei < _entries.size() \
				and String((_entries[ei] as Dictionary).get("id", "")) != "":
			visible_cells.append(ci)
	var ordinal := visible_cells.find(i)
	if ordinal < 0:
		return
	if raised:
		_hover_index = i
	elif _hover_index == i:
		_hover_index = -1
	var hover_ordinal := visible_cells.find(_hover_index)
	var count := visible_cells.size()
	for ci_ordinal in count:
		var ci := visible_cells[ci_ordinal]
		var r := UiLayoutRes.card_fan_local(ci_ordinal, count)
		var target_pos := r.position
		var target_rot := UiLayoutRes.card_fan_rotation(ci_ordinal, count)
		var target_scale := 1.0
		var delay := 0.0
		if ci == _hover_index:
			target_rot = 0.0
			target_pos.y -= UiLayoutRes.CARD_HOVER_RAISE_PX
			# ★★ 2026.11.18：支点是牌底中点 ⇒ 放大从手里往上长，不再补位置。
			target_scale = HOVER_SCALE
			_cells[ci].z_index = UiLayoutRes.CARD_SLOTS + 2
		else:
			# ★ 同侧所有牌统一让开同一段距离（与命令卡共用 `card_hover_push`）。
			if hover_ordinal >= 0:
				target_pos.x += UiLayoutRes.card_hover_push(ci_ordinal, hover_ordinal)
				delay = minf(0.025, 0.012 * absf(float(ci_ordinal - hover_ordinal)))
			_cells[ci].z_index = ci_ordinal
		# ★★ 2026.11.16：科技页原来是一帧到位（没有缓动）——
		#   鼠标从一张牌扫到下一张时整手牌会「跳」一下。现在与命令卡同一条 0.14s ease-out。
		_ease_cell_pose(ci, target_pos, target_rot, target_scale, false,
			HOVER_RAISE_SEC, delay)


## 把第 i 格缓动到目标姿势（悬停抬起 / 放大 / 让开 / 收回 / 下沉都走这里）。
## ★ `sec` = 这一段的时长（默认悬停那档 0.14s；「下沉 / 浮回」传 `CARD_TUCK_SEC`）。
## ★★ 2026.11.19：与命令卡一致 —— 邻居延迟让开；放大回弹走 `TRANS_BACK`。
func _ease_cell_pose(i: int, target_pos: Vector2, target_rot: float,
		target_scale: float = 1.0, allow_while_dragging: bool = false,
		sec: float = HOVER_RAISE_SEC, delay_sec: float = 0.0) -> void:
	while _hover_tweens.size() <= i:
		_hover_tweens.append(null)
	var old = _hover_tweens[i]
	if old != null and is_instance_valid(old) and (old as Tween).is_running():
		(old as Tween).kill()
	_hover_tweens[i] = null
	var cell := _cells[i]
	var target_sv := Vector2(target_scale, target_scale)
	# ★★ 2026.11.18：支点跟随 size，统一钉成「牌底中点」（理由同命令卡）。
	cell.pivot_offset = UiLayoutRes.card_pivot(cell.size)
	# 已经到位：不起 Tween（换到相邻牌时，同侧的牌目标位置不变，理应一动不动）。
	if cell.position.distance_to(target_pos) < 0.25 \
			and absf(angle_difference(cell.rotation, target_rot)) < 0.001 \
			and cell.scale.distance_to(target_sv) < 0.001:
		cell.position = target_pos
		cell.rotation = target_rot
		cell.scale = target_sv
		return
	if (_dragging and not allow_while_dragging) \
			or not ThemeRes.animations_enabled() or sec <= 0.0:
		cell.position = target_pos
		cell.rotation = target_rot
		cell.scale = target_sv
		return
	var tw := create_tween().set_parallel(true)
	var scale_trans: Tween.TransitionType = Tween.TRANS_BACK \
		if target_scale > 1.001 else Tween.TRANS_CUBIC
	tw.tween_property(cell, "position", target_pos, sec) \
		.set_delay(delay_sec).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(cell, "rotation", target_rot, sec) \
		.set_delay(delay_sec).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(cell, "scale", target_sv, sec) \
		.set_delay(delay_sec).set_trans(scale_trans).set_ease(Tween.EASE_OUT)
	_hover_tweens[i] = tw


## 杀掉所有悬停 Tween（重新摆牌 / 入场 / 开始拖牌之前必须调）。
func _kill_hover_tweens() -> void:
	for tw in _hover_tweens:
		if tw != null and is_instance_valid(tw) and (tw as Tween).is_running():
			(tw as Tween).kill()
	_hover_tweens.clear()


## 拖牌前把「悬停让开的邻居」收回原位（跳过正在拖的那一格）。
## 同侧整体平移时，邻居位置本来就不依赖悬停牌的具体序号；这条只在收手 / 换页时兜底。
func _settle_spread(except_index: int) -> void:
	var visible_cells := _visible_cell_indices()
	var count := visible_cells.size()
	# ★★ 2026.11.17：「原位」要把**下沉状态**算进去（理由同命令卡的同名函数）。
	var tuck := 1.0 if _tucked else 0.0
	var tuck_scale := UiLayoutRes.card_tuck_scale(tuck)
	for ordinal in count:
		var ci := visible_cells[ordinal]
		if ci == except_index:
			continue
		var r := UiLayoutRes.card_fan_local(ordinal, count)
		var pose: Vector2 = r.position + UiLayoutRes.card_tuck_offset(r.size, tuck)
		_cells[ci].z_index = ordinal
		_ease_cell_pose(ci, pose, UiLayoutRes.card_fan_rotation(ordinal, count),
			tuck_scale, true)


## 模拟悬停第 i 格 / 离开它（测试用；与 `press()` 一样走引擎同一条信号）。
## ★★ 手机端的长按也走这里 —— 所以它**绕开** `touch_suppress_hover` 直接发信号。
func hover(i: int) -> void:
	cell_hovered.emit(i)


func unhover(i: int) -> void:
	cell_unhovered.emit(i)


# ------------------------------------------------------------------
# 显隐：只有「科技」页才盖在命令卡上
# ------------------------------------------------------------------

## hud 每帧按当前页调它。★ 换页时**什么都不改**（内容照旧留着，只是不画）——
## 重新可见时不需要重建控件，也就不存在「切回来慢一帧」。
func set_visible_page(on: bool) -> void:
	visible = on
	mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE
	# ⚠️ 挡住鼠标的**只在显示时**：隐藏时若还是 STOP，底栏那一片会变成点击黑洞
	#    （鼠标滚轮缩放的判据只看底栏几何、不看控件，所以这条只影响点击）。
	for c in _cells:
		c.mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE


## 翻到科技页时，实际科技牌从牌手下缘错落升起；空配置槽不参与动效。
func animate_deck_in() -> void:
	if _deck_tween != null and _deck_tween.is_running():
		_deck_tween.kill()
	_kill_hover_tweens()
	_hover_index = -1
	var visible_cells: Array[int] = []
	for i in _cells.size():
		if _cells[i].visible:
			visible_cells.append(i)
	var count := visible_cells.size()
	if count == 0 or not visible:
		return
	for ordinal in count:
		var i := visible_cells[ordinal]
		_cells[i].modulate.a = 1.0
		var target := UiLayoutRes.card_fan_local(ordinal, count)
		var rot := UiLayoutRes.card_fan_rotation(ordinal, count)
		_cells[i].modulate.a = 0.0
		_cells[i].scale = Vector2.ONE
		# ★★ 2026.11.18：与命令卡同一套入口（起点下移 26px、旋转 ×0.5）。
		_cells[i].pivot_offset = UiLayoutRes.card_pivot(target.size)
		_cells[i].position = target.position + Vector2(0.0, 26.0)
		_cells[i].rotation = rot * 0.5
		_cells[i].z_index = ordinal
	_deck_tween = create_tween().set_parallel(true)
	for ordinal in count:
		var i := visible_cells[ordinal]
		var target := UiLayoutRes.card_fan_local(ordinal, count)
		var rot := UiLayoutRes.card_fan_rotation(ordinal, count)
		var delay := float(ordinal) * 0.018
		_deck_tween.tween_property(_cells[i], "position", target.position, 0.18) \
			.set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_deck_tween.tween_property(_cells[i], "rotation", rot, 0.18) \
			.set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_deck_tween.tween_property(_cells[i], "modulate:a", 1.0, 0.14).set_delay(delay)


# ------------------------------------------------------------------
# 给测试 / hud 用的小接口
# ------------------------------------------------------------------

func entries() -> Array:
	return _entries


## 第 i **格**显示的条目（注意：格 ≠ config 下标 —— 九格是列优先转置过的）
## ★ 空槽位返回 {}（与「没有这一格」同形）：hud 的悬停 / 点击都自带「空字典什么都不做」。
func entry_at(i: int) -> Dictionary:
	var ei := _entry_index_for_cell(i)
	if ei < 0 or ei >= _entries.size():
		return {}
	var e: Dictionary = _entries[ei]
	if String(e.get("id", "")) == "":
		return {}
	return e


func cell_at(i: int) -> Button:
	if i < 0 or i >= _cells.size():
		return null
	return _cells[i]


## 第 i 格显示的名字（空格子为空串）
func cell_name(i: int) -> String:
	if i < 0 or i >= _name_labels.size():
		return ""
	return _name_labels[i].text


## 第 i 格的第二行小字
func cell_line(i: int) -> String:
	if i < 0 or i >= _line_labels.size():
		return ""
	return _line_labels[i].text


## 第 i 格左上角显示的键位字母
func cell_key(i: int) -> String:
	if i < 0 or i >= _key_labels.size():
		return ""
	return _key_labels[i].text


## 第 i 格是不是画成「已启用」（实心强调色）。空格子恒为 false。
func cell_active(i: int) -> bool:
	var ei := _entry_index_for_cell(i)
	if ei < 0 or ei >= _entries.size():
		return false
	return bool((_entries[ei] as Dictionary).get("active", false))


## 测试辅助：直接触发有效科技牌（真实鼠标操作需上拖松手）。
func press(i: int) -> void:
	_activate_cell(i)
