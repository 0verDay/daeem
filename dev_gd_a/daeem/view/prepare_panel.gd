## prepare_panel.gd —— 「备战」页（主菜单底部的备战进入的整页）。
##
## 版式（见 view/menu_deck_layout.gd 的 PREP_*）：
##   · 最左上一条 = **返回主菜单的点击区**，内部居中呼吸显隐「——点此返回主菜单——」；
##   · 右侧两枚竖排按钮 = 王朝 / 帝国（右→左泛光、左边无框、互斥选中）；
##   · 左面板 = 详情卡（点右侧磁贴后显示说明/属性/造价）；
##   · 右面板 = 按阶分组的「将领 / 单位 / 科技」磁贴列表（可上下拖拽 / 过拉回弹）。
##
## ★ 顶部那两颗「自定义 / 备战」**不在这里建**：它们是主菜单自己的底部动作条，
##   进入备战时由 menu_deck 把主菜单整体上滑，露出这一条 —— 所以备战按钮的金色
##   填充、点击音、按下反馈都还是原来那一套，不会做出第二份。
##
## ★ 本页**不铺整屏底**：左侧轮播图要在进入时渐隐，透出来的应是菜单背景本身，
##   而不是一块新的深色面板。只画那三块（返回条 + 两块面板）与两枚按钮。
extends Control

signal back_pressed
signal faction_selected(faction_id: String)

const ThemeRes = preload("res://view/theme.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const LayoutRes = preload("res://view/menu_deck_layout.gd")
const SfxRes = preload("res://view/sfx.gd")
const FactionBtnRes = preload("res://view/prepare_faction_button.gd")
const RosterListRes = preload("res://view/prepare_roster_list.gd")
const DetailViewRes = preload("res://view/prepare_detail_view.gd")

## 与设计稿一致：上 = 王朝，下 = 帝国。
const FACTIONS := ["dynasty", "empire"]
const DEFAULT_BACK_TEXT := "——点此返回主菜单——"

## 右面板里列表相对面板边缘的留白（左 / 右 / 上 / 下）。
const ROSTER_PAD_X := 16.0
const ROSTER_PAD_Y := 14.0

var cfg = null
var font: Font = null

var _back: Button = null
var _back_label: Label = null
var _panels: Array = []
var _factions: Array = []
var _roster = null
var _detail = null
var _selected: String = ""
var _breath_tween: Tween = null
var _glow_alpha: float = 1.0
var _glow_tween: Tween = null


func setup(p_cfg, p_font: Font) -> void:
	cfg = p_cfg
	font = p_font
	name = "PreparePanel"
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# ① 左上返回区：整条都能点，文字是它的子 Label（这样呼吸只动字、不动底板）。
	_back = Button.new()
	_back.name = "BackArea"
	_back.focus_mode = Control.FOCUS_NONE
	_back.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_back.add_theme_stylebox_override("normal", MenuThemeRes.prepare_back())
	_back.add_theme_stylebox_override("hover", MenuThemeRes.prepare_back_hover())
	_back.add_theme_stylebox_override("pressed", MenuThemeRes.prepare_back_hover())
	_back.add_theme_stylebox_override("focus", MenuThemeRes.prepare_back())
	_back.add_theme_stylebox_override("disabled", MenuThemeRes.prepare_back())
	_back.pressed.connect(func(): back_pressed.emit())
	# ★ 返回区是一整条 1280×120 的横幅：不挂 PressFx（0.975 的按下缩放会把整条
	#   抽掉三十多像素，看着像页面在抖），只保留点击音与悬停描边。
	SfxRes.attach(_back)
	add_child(_back)

	var text := String(cfg.str_val("menu.deck.prepare.back_text", DEFAULT_BACK_TEXT)) \
		if cfg != null else DEFAULT_BACK_TEXT
	_back_label = Label.new()
	_back_label.name = "BackText"
	_back_label.text = text
	_back_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_back_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_back_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if font != null:
		_back_label.add_theme_font_override("font", font)
	_back_label.add_theme_font_size_override("font_size",
		int(cfg.num("menu.deck.prepare.back_text_size", 30.0)) if cfg != null else 30)
	_back_label.add_theme_color_override("font_color", ThemeRes.text())
	_back.add_child(_back_label)

	# ② 两块面板：左面板 = 详情卡，右面板 = 「将领 / 单位 / 科技」弹性列表。
	for i in 2:
		var p := Panel.new()
		p.name = "Panel%d" % i
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.add_theme_stylebox_override("panel", MenuThemeRes.prepare_panel())
		add_child(p)
		_panels.append(p)

	_roster = RosterListRes.new()
	_roster.name = "RosterList"
	_panels[1].add_child(_roster)
	_roster.setup(cfg, font)
	_roster.item_selected.connect(_on_roster_item_selected)

	_detail = DetailViewRes.new()
	_detail.name = "DetailView"
	_panels[0].add_child(_detail)
	_detail.setup(cfg, font)

	# ③ 右侧两枚竖排按钮：上王朝、下帝国。
	var fs: int = int(cfg.num("menu.deck.prepare.faction_text_size", 40.0)) \
		if cfg != null else 40
	var gap: int = int(cfg.num("menu.deck.prepare.faction_line_gap", 8.0)) \
		if cfg != null else 8
	for i in FACTIONS.size():
		var id: String = FACTIONS[i]
		var display: String = cfg.clan_name_of(id) if cfg != null else ""
		if display == "" or display == id:
			display = "王朝" if id == "dynasty" else "帝国"
		var b := FactionBtnRes.new()
		b.setup(font, display, id, fs, gap)
		b.pressed.connect(_on_faction_pressed.bind(i))
		add_child(b)
		_factions.append(b)

	resized.connect(_layout)
	_layout()

	var default_id := String(cfg.str_val("menu.deck.prepare.default_faction", "empire")) \
		if cfg != null else "empire"
	set_faction(default_id, true)


# ------------------------------------------------------------------
# 布局
# ------------------------------------------------------------------

func _layout() -> void:
	if _back == null:
		return
	var w: float = size.x
	var h: float = size.y
	var br := LayoutRes.prepare_back(w, h)
	_back.position = br.position
	_back.size = br.size
	_back_label.position = Vector2.ZERO
	_back_label.size = br.size

	for i in _panels.size():
		var r := LayoutRes.prepare_panel(w, h, i)
		_panels[i].position = r.position
		_panels[i].size = r.size

	if _roster != null:
		var pr: Vector2 = _panels[1].size
		_roster.position = Vector2(ROSTER_PAD_X, ROSTER_PAD_Y)
		_roster.size = Vector2(
			maxf(1.0, pr.x - ROSTER_PAD_X * 2.0),
			maxf(1.0, pr.y - ROSTER_PAD_Y * 2.0))

	if _detail != null:
		_detail.position = Vector2.ZERO
		_detail.size = _panels[0].size

	for i in _factions.size():
		var r := LayoutRes.prepare_faction(w, h, i)
		_factions[i].position = r.position
		_factions[i].size = r.size


# ------------------------------------------------------------------
# 派系选择
# ------------------------------------------------------------------

func set_faction(faction_id: String, instant: bool = false) -> void:
	var idx := FACTIONS.find(faction_id)
	if idx < 0:
		# 配置写坏 / 拼错时不要留下「两枚都不选」的空态：回落到帝国。
		faction_id = "empire"
		idx = FACTIONS.find(faction_id)
	_selected = faction_id
	for i in _factions.size():
		_factions[i].set_selected(i == idx, instant)
	# 右面板的三节内容跟着派系走（王朝 / 帝国各自的单位与科技；将领两派相同）。
	# 换派系后旧的单位/科技详情可能已不存在 —— 清掉选中与左面板，回到提示态。
	if _roster != null:
		_roster.clear_selection()
		_roster.set_faction(_selected)
	if _detail != null:
		_detail.set_faction(_selected)
		_detail.clear()


## 重新进入备战页时让列表回到顶部（不改变当前派系）。
func reset_scroll() -> void:
	if _roster != null:
		_roster.scroll_to(0.0)


## 重新进入备战页时清掉选中项与左侧详情（用户口径：默认空白提示）。
func reset_selection() -> void:
	if _roster != null:
		_roster.clear_selection()
	if _detail != null:
		_detail.clear()


## 右面板点开一项 → 左面板显示对应详情。
func _on_roster_item_selected(kind: String, id: String) -> void:
	if _detail != null:
		_detail.show_item(kind, id)


func selected_faction() -> String:
	return _selected


func _on_faction_pressed(index: int) -> void:
	if index < 0 or index >= FACTIONS.size():
		return
	var id: String = FACTIONS[index]
	if id == _selected:
		return
	set_faction(id)
	faction_selected.emit(id)


# ------------------------------------------------------------------
# 返回区呼吸
# ------------------------------------------------------------------

func start_breathing() -> void:
	stop_breathing()
	if _back_label == null:
		return
	_back_label.modulate.a = 1.0
	if not ThemeRes.animations_enabled():
		return
	var lo: float = clampf(cfg.num("menu.deck.prepare.breath_min_alpha", 0.12) \
		if cfg != null else 0.12, 0.0, 1.0)
	var hi: float = clampf(cfg.num("menu.deck.prepare.breath_max_alpha", 1.0) \
		if cfg != null else 1.0, 0.0, 1.0)
	if hi < lo:
		var tmp := lo
		lo = hi
		hi = tmp
	var sec: float = maxf(0.3, cfg.num("menu.deck.prepare.breath_sec", 2.4) \
		if cfg != null else 2.4)
	_back_label.modulate.a = hi
	_breath_tween = create_tween()
	_breath_tween.set_loops()
	_breath_tween.tween_property(_back_label, "modulate:a", lo, sec * 0.5) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_breath_tween.tween_property(_back_label, "modulate:a", hi, sec * 0.5) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func stop_breathing() -> void:
	if _breath_tween != null and _breath_tween.is_valid():
		_breath_tween.kill()
	_breath_tween = null
	if _back_label != null:
		_back_label.modulate.a = 1.0


# ------------------------------------------------------------------
# 泛光（与 menu_page 同名接口，供 menu_deck 的聚焦页切换统一驱动）
# ------------------------------------------------------------------

func set_glows(on: bool, animate: bool = true) -> void:
	fade_glows(1.0 if on else 0.0, animate)


func fade_glows(to: float, animate: bool = true, sec: float = -1.0) -> void:
	to = clampf(to, 0.0, 1.0)
	if _glow_tween != null and _glow_tween.is_valid():
		_glow_tween.kill()
	_glow_tween = null
	var dur: float = maxf(0.0, cfg.num("menu.deck.glow_fade_sec", 0.26)) \
		if cfg != null else 0.26
	if sec > 0.0:
		dur = sec
	if not animate or not ThemeRes.animations_enabled() or dur <= 0.0 \
			or is_equal_approx(to, _glow_alpha) or not is_inside_tree():
		apply_glow_alpha(to)
		return
	_glow_tween = create_tween()
	_glow_tween.tween_method(apply_glow_alpha, _glow_alpha, to, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func apply_glow_alpha(a: float) -> void:
	_glow_alpha = clampf(a, 0.0, 1.0)
	for b in _factions:
		if b != null and is_instance_valid(b):
			b.set_glow_alpha(_glow_alpha)


func glow_alpha() -> float:
	return _glow_alpha


## menu_deck 的 `_apply_dims` 会对每页调一次；本页没有侧栏灰层，留空接口。
func set_sidebar_dimmed(_on: bool, _animate: bool = true) -> void:
	pass


# ------------------------------------------------------------------
# 访问器（测试 / 截图用）
# ------------------------------------------------------------------

func back_area() -> Button:
	return _back


func back_label() -> Label:
	return _back_label


func panels() -> Array:
	return _panels


func faction_buttons() -> Array:
	return _factions


## 右面板里的弹性列表（测试 / 截图用）。
func roster():
	return _roster


## 左面板里的详情卡（测试 / 截图用）。
func detail():
	return _detail
