## main_menu_panel.gd —— 主菜单右侧面板（640×1080）。
##
## 结构：退出 X / 方形 logo + 名称条 / 战役·合作·演义 / 底部自定义·备战，
## 外加四角的图标按钮：左上「载入」、左下「好友」、右下「设置」——
## 三颗都与右上角的退出 X 同款（程序化图标 + 各自的角泛光），点击逻辑暂不接。
## 入场时这块面板渐显，入场页的徽记与标题由 start_screen 缓动到 logo_rect / name_rect。
extends "res://view/menu_page.gd"

signal campaign_pressed
signal coop_pressed
signal quit_pressed
signal load_pressed
signal friends_pressed
signal settings_pressed

const MenuEmblemRes = preload("res://view/menu_emblem.gd")
const TextMarksRes = preload("res://view/text_marks.gd")
const TextButtonRes = preload("res://view/menu_text_button.gd")
const CornerButtonRes = preload("res://view/menu_corner_button.gd")

const DEFAULT_MAIN_BUTTONS := ["战役", "合作", "演义"]
const DEFAULT_BOTTOM_BUTTONS := ["自定义", "备战"]

## _corner_buttons / _corner_glows / _corner_ids 里的下标。
const CORNER_LOAD := 0
const CORNER_FRIENDS := 1
const CORNER_SETTINGS := 2

var _content: Control = null
var _exit: Button = null
var _logo_frame: Panel = null
var _emblem = null
var _name_bar: Panel = null
var _wordmark = null
var _rule = null
var _main_buttons: Array = []
var _bottom_bar: Control = null
var _bottom_buttons: Array = []
var _divider: ColorRect = null
var _corner_buttons: Array = []
var _corner_glows: Array = []
var _corner_ids: Array = []
var _active_index: int = -1
var _active_marker: Control = null


func setup(p_cfg, p_font: Font) -> void:
	name = "MainPanel"
	setup_page(p_cfg, p_font, "", false)

	_content = Control.new()
	_content.name = "Content"
	_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.z_index = 5
	add_child(_content)

	_exit = CornerButtonRes.new()
	_exit.z_index = 2
	_content.add_child(_exit)
	_exit.setup(CornerButtonRes.ICON_CLOSE, "退出游戏")
	_exit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_exit.pressed.connect(func(): quit_pressed.emit())
	corner_hit().pressed.connect(func(): quit_pressed.emit())

	_logo_frame = Panel.new()
	_logo_frame.name = "LogoFrame"
	_logo_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_logo_frame.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_content.add_child(_logo_frame)

	_emblem = MenuEmblemRes.new()
	_emblem.name = "Emblem"
	_emblem.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_logo_frame.add_child(_emblem)

	_name_bar = Panel.new()
	_name_bar.name = "NameBar"
	_name_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_bar.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_content.add_child(_name_bar)

	_wordmark = TextMarksRes.SpacedLabel.new()
	_wordmark.name = "Wordmark"
	_wordmark.text = String(cfg.str_val("menu.title", "DAE"))
	_wordmark.font = font
	_wordmark.font_size = int(cfg.num("menu.deck.main.name_size", 42.0))
	_wordmark.tracking = cfg.num("menu.deck.main.name_tracking", 8.0)
	_wordmark.color_from = ThemeRes.text()
	_wordmark.color_to = ThemeRes.accent_bright()
	_wordmark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_bar.add_child(_wordmark)

	_rule = TextMarksRes.Rule.new()
	_rule.name = "NameRule"
	_rule.line_color = ThemeRes.with_alpha(ThemeRes.line(), 0.9)
	_rule.line_width = 1.0
	_rule.fade = cfg.num("menu.deck.main.rule_fade", 40.0)
	_content.add_child(_rule)

	var labels := _string_list("menu.deck.main.buttons", DEFAULT_MAIN_BUTTONS)
	for i in labels.size():
		var b := TextButtonRes.new()
		b.name = "MainBtn%d" % i
		b.setup(font, String(labels[i]), 44)
		b.pressed.connect(_on_main_pressed.bind(i))
		_content.add_child(b)
		_main_buttons.append(b)

	_bottom_bar = Control.new()
	_bottom_bar.name = "BottomBar"
	_bottom_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(_bottom_bar)

	var bottoms := _string_list("menu.deck.main.bottom_buttons", DEFAULT_BOTTOM_BUTTONS)
	for i in bottoms.size():
		var b := make_block_button("BottomBtn%d" % i, String(bottoms[i]), 30,
			MenuThemeRes.bottom_button())
		b.pressed.connect(func(): pass)
		_bottom_bar.add_child(b)
		_bottom_buttons.append(b)

	_divider = ColorRect.new()
	_divider.name = "BottomDivider"
	_divider.color = ThemeRes.with_alpha(ThemeRes.line(), 0.85)
	_divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bottom_bar.add_child(_divider)

	# 四角的三颗图标按钮（退出 X 已在上面的 _exit 里）。
	_add_corner_button("LoadButton", CornerButtonRes.ICON_LOAD, "载入",
		LayoutRes.CORNER_TOP_LEFT)
	_add_corner_button("FriendsButton", CornerButtonRes.ICON_FRIENDS, "好友",
		LayoutRes.CORNER_BOTTOM_LEFT)
	_add_corner_button("SettingsButton", CornerButtonRes.ICON_SETTINGS, "设置",
		LayoutRes.CORNER_BOTTOM_RIGHT)

	resized.connect(_layout)
	_layout()


## 一颗角按钮 + 它自己那面角的泛光。
##
## 按钮放进 _content（跟退出 X 同层，z=2）；泛光放在面板层（z=4）——和
## menu_page 那只右上角泛光同层，压在底板之上、内容和按钮之下，
## 于是四团角光能被 `glow_nodes()` 一起收进泛光组，跟着转场渐显/渐隐。
func _add_corner_button(node_name: String, icon: int, tip: String, corner: int) -> void:
	var glow: Control = CornerGlowRes.new()
	glow.name = "%sGlow" % node_name
	glow.set_corner(corner)
	glow.z_index = 4
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(glow)

	var b: Button = CornerButtonRes.new()
	b.name = node_name
	b.z_index = 2
	_content.add_child(b)
	b.setup(icon, tip, corner)
	# ★ 桌面：悬停点亮自己那面角泛光。移动端：没有悬停（手指按下的模拟 enter
	#   等不到 exit，光会一直亮着），改成按住才亮、松手就灭。
	if ThemeRes.hover_enabled():
		b.mouse_entered.connect(func(): glow.set_hover(true))
		b.mouse_exited.connect(func(): glow.set_hover(false))
	else:
		b.button_down.connect(func(): glow.set_lit(true))
		b.button_up.connect(func(): glow.set_lit(false))
	b.pressed.connect(_on_corner_pressed.bind(_corner_buttons.size()))

	_corner_buttons.append(b)
	_corner_glows.append(glow)
	_corner_ids.append(corner)


## 三颗角按钮目前只发信号，不接任何跳转（载入/设置/好友的流程还没做）。
func _on_corner_pressed(index: int) -> void:
	match index:
		CORNER_LOAD:
			load_pressed.emit()
		CORNER_FRIENDS:
			friends_pressed.emit()
		CORNER_SETTINGS:
			settings_pressed.emit()


func _on_main_pressed(index: int) -> void:
	match index:
		0:
			campaign_pressed.emit()
		1:
			coop_pressed.emit()
		_:
			pass


func _layout() -> void:
	if _content == null:
		return
	var w: float = size.x
	var h: float = size.y
	var er := LayoutRes.main_exit(w)
	_exit.position = er.position
	_exit.size = er.size

	var lr := LayoutRes.main_logo(w)
	_logo_frame.position = lr.position
	_logo_frame.size = lr.size
	_emblem.position = Vector2(8.0, 8.0)
	_emblem.size = lr.size - Vector2(16.0, 16.0)

	var nr := LayoutRes.main_name(w)
	_name_bar.position = nr.position
	_name_bar.size = nr.size
	_wordmark.position = Vector2.ZERO
	_wordmark.size = nr.size

	var rr := LayoutRes.main_rule(w)
	_rule.position = rr.position
	_rule.size = rr.size

	for i in _main_buttons.size():
		var r := LayoutRes.main_button(w, i)
		_main_buttons[i].position = r.position
		_main_buttons[i].size = r.size

	var br := LayoutRes.main_bottom(w, h)
	_bottom_bar.position = br.position
	_bottom_bar.size = br.size
	for i in _bottom_buttons.size():
		var r := LayoutRes.main_bottom_half(w, h, i)
		var b: Button = _bottom_buttons[i]
		b.position = Vector2(r.position.x, 0.0)
		b.size = Vector2(r.size.x, br.size.y)
	_divider.position = Vector2(w * 0.5 - 0.5, 0.0)
	_divider.size = Vector2(1.0, br.size.y)

	for i in _corner_buttons.size():
		var corner: int = _corner_ids[i]
		# 控件占的是贴角的 180×180 方框（三角命中），图标只画在里面的 56×56。
		var hr := LayoutRes.main_corner_hit(w, h, corner)
		var ir := LayoutRes.main_corner_button(w, h, corner)
		_corner_buttons[i].position = hr.position
		_corner_buttons[i].size = hr.size
		_corner_buttons[i].set_icon_rect(Rect2(ir.position - hr.position, ir.size))
		var gr := LayoutRes.main_corner_glow(w, h, corner)
		_corner_glows[i].position = gr.position
		_corner_glows[i].size = gr.size

	_layout_active_marker()


## 当前左侧大类：0=战役，1=合作，-1=无。选中态是在灰层之上放一块
## 透明的“文字 + 左右横线”标记层；没有方框，也不会被灰层压暗。
func set_active(index: int) -> void:
	if index == _active_index:
		if index < 0 or (_active_marker != null and is_instance_valid(_active_marker)):
			return
	_active_index = index
	if _active_marker != null and is_instance_valid(_active_marker):
		_active_marker.visible = false
		_active_marker.queue_free()
	_active_marker = null
	if index < 0 or index >= _main_buttons.size():
		return
	var b = _main_buttons[index]
	_active_marker = TextButtonRes.new()
	_active_marker.name = "ActiveMarker"
	_active_marker.z_index = 101
	_active_marker.setup(font, String(b.text()), 44)
	_active_marker.set_passive()
	_active_marker.set_selected_immediate(true)
	add_child(_active_marker)
	_layout_active_marker()


func _layout_active_marker() -> void:
	if _active_marker == null or not is_instance_valid(_active_marker):
		return
	if _active_index < 0 or _active_index >= _main_buttons.size():
		return
	var b: Control = _main_buttons[_active_index]
	_active_marker.position = b.position
	_active_marker.size = b.size


func active_index() -> int:
	return _active_index


func active_marker() -> Control:
	return _active_marker


func set_content_alpha(a: float) -> void:
	if _content != null:
		_content.modulate.a = clampf(a, 0.0, 1.0)


func content_alpha() -> float:
	return _content.modulate.a if _content != null else 1.0


func logo_rect() -> Rect2:
	return _logo_frame.get_global_rect() if _logo_frame != null else Rect2()


func name_rect() -> Rect2:
	return _name_bar.get_global_rect() if _name_bar != null else Rect2()


## 主菜单里实际徽记（logo 框内缩 8px 后）的矩形：入场页转场以它为目标，
## 尺寸与落位后的主菜单徽记完全一致。
func emblem_rect() -> Rect2:
	return _emblem.get_global_rect() if _emblem != null else Rect2()


## 入场转场期间隐藏主菜单自己的 logo / 名字，避免和滑过来的入场页元素叠出重影。
func set_logo_visible(on: bool) -> void:
	if _logo_frame != null:
		_logo_frame.visible = on
	if _name_bar != null:
		_name_bar.visible = on


func wordmark():
	return _wordmark


func name_rule():
	return _rule


func exit_button() -> Button:
	return _exit


func main_buttons() -> Array:
	return _main_buttons


func bottom_buttons() -> Array:
	return _bottom_buttons


func corner_buttons() -> Array:
	return _corner_buttons


func corner_glows() -> Array:
	return _corner_glows


## 本页泛光组 = 基类的右上角那只 + 三颗角按钮各自的角泛光（进场 / 转场一起渐显渐隐）。
func glow_nodes() -> Array:
	var out: Array = super.glow_nodes()
	out.append_array(_corner_glows)
	return out


func corner_button(index: int) -> Button:
	if index < 0 or index >= _corner_buttons.size():
		return null
	return _corner_buttons[index]


## 第 index 颗角按钮自己的泛光（右上角那只仍然是基类的 corner_glow()）。
func corner_glow_at(index: int) -> Control:
	if index < 0 or index >= _corner_glows.size():
		return null
	return _corner_glows[index]


func content() -> Control:
	return _content


## 变成左侧栏时：主面板的灰层会盖住四角按钮，那几面泛光也要跟着熄掉
## （触屏没有 mouse_exited，光靠悬停状态会一直亮着）。
func set_sidebar_dimmed(on: bool, animate: bool = true) -> void:
	super(on, animate)
	if not on:
		return
	for g in _corner_glows:
		if g != null and is_instance_valid(g):
			# ★ 用 set_lit（强制熄灭）而不是 set_hover：移动端 hover 事件是被忽略的，
			#   走 set_hover 熄不掉（手指按下的那道光会一直亮着）。
			g.set_lit(false)


func _string_list(path: String, fallback: Array) -> Array:
	var v: Variant = cfg.get_path_value(path) if cfg != null else null
	var out: Array = []
	if typeof(v) == TYPE_ARRAY:
		for item in (v as Array):
			var s := String(item).strip_edges()
			if s != "":
				out.append(s)
	return out if not out.is_empty() else fallback
