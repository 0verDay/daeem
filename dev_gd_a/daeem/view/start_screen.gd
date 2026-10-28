## start_screen.gd —— 开场页 + 新菜单（MenuDeck）
##
## 入场页保留原来的徽记 / DAEEM / 金线 / 点击提示 / 启动黑幕 / 扫光。
## 点击任意处后：新主菜单面板在右侧渐显，入场徽记与标题缓动到面板的
## logo 方框 / 名称条；随后整块 MenuDeck 接管主菜单、战役、合作的所有页面。
##
## ★ 本文件只做「入场页 → 主菜单」的落位与页面显隐；页面栈、横向滑动、
##   侧栏灰层、合作会话都在 view/menu_deck.gd 里。
extends CanvasLayer

signal intro_dismissed
signal campaign_level_chosen(campaign_id: String, level_id: String, faction_id: String)
signal coop_host_started(campaign_id: String, level_id: String, transport)
signal coop_guest_started(payload: Dictionary, transport)
signal coop_solo_started(campaign_id: String, level_id: String, ai_setup: Dictionary)
signal ai_test_pressed
signal quit_requested
## 兼容旧测试 / 旧调试入口；新菜单本身不再发这条信号。
signal level_entry_pressed(campaign_id: String, level_id: String)

const ConfigRes = preload("res://logic/config.gd")
const ThemeRes = preload("res://view/theme.gd")
const MenuBackgroundRes = preload("res://view/menu_background.gd")
const MenuEmblemRes = preload("res://view/menu_emblem.gd")
const TextMarksRes = preload("res://view/text_marks.gd")
const MenuDeckRes = preload("res://view/menu_deck.gd")
const FillButtonRes = preload("res://view/fill_button.gd")
const LayoutRes = preload("res://view/menu_deck_layout.gd")
const EtchedPlateRes = preload("res://view/menu_art/etched_plate.gd")

const PAGE_INTRO := 0
const PAGE_MENU := 1

const BLINK_PHASE_SEC := 1.2
const BLINK_START_DELAY := 0.26
const SHINE_SEC := 1.15
const SHINE_DELAY_SEC := 0.55
const SHINE_SKEW := 0.34

var cfg: ConfigRes = null
var _page: int = PAGE_INTRO
var _font: Font = null

var _root: Control = null
var _bg: Control = null
var _art: Control = null
var _intro: Control = null
var _title: Control = null
var _emblem: Control = null
var _title_rule: Control = null
var _click_hint: Label = null
var _shine: Control = null
var _menu_deck = null

var _morph_tween: Tween = null
var _art_tween: Tween = null
var _intro_morphing: bool = false
var _menu_input_blocked: bool = false
var _blink_tween: Tween = null
var _shine_tween: Tween = null

var _boot_fade: ColorRect = null
var _boot_tween: Tween = null


func setup(p_cfg: ConfigRes, p_font: Font) -> void:
	cfg = p_cfg
	_font = p_font
	layer = 100

	_root = Control.new()
	_root.name = "StartRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_build_background()
	_build_art()
	_build_intro()
	_build_deck()
	_build_boot_fade()
	show_page(PAGE_INTRO)
	_play_boot_fade_in()


# ------------------------------------------------------------------
# 对外状态
# ------------------------------------------------------------------

func show_page(page: int) -> void:
	show()
	_page = page
	_intro.visible = (page == PAGE_INTRO)
	if _menu_deck != null:
		_menu_deck.visible = (page == PAGE_MENU)
	if page == PAGE_INTRO:
		start_click_blink()
		start_title_shine()
	else:
		_stop_click_blink()
		_stop_title_shine()
		if _click_hint != null:
			_click_hint.modulate.a = 1.0
		if _title != null:
			_title.modulate.a = 1.0
		if _shine != null:
			_shine.visible = false
			_shine.modulate.a = 0.0


func page() -> int:
	return _page


func close() -> void:
	_stop_click_blink()
	_stop_title_shine()
	_cancel_intro_morph()
	_finish_boot_fade()
	# 进游戏之后把左侧那幅画停掉：它每帧都在重建几何，没必要在战斗里空转。
	if _art != null:
		_art.set_running(false)
	hide()
	FillButtonRes.clear_hover_in(self)


func open_menu() -> void:
	show()
	show_page(PAGE_MENU)
	_finish_boot_fade()
	set_menu_input_blocked(false)
	if _menu_deck != null:
		_menu_deck.reset_to_main(true)
		_menu_deck.finish_intro(true)
	# 从战斗回菜单是「整页一下子出来」，雕版跟着同一拍淡入（不是立刻给满）。
	if _art != null:
		_art.restart_scan()
		_art.set_running(true)
		# 先把落位对好再淡入：否则会有一帧停在「上一次离开时」的那个 x 上。
		_sync_art_x()
		_fade_art(1.0, _art_fade_in_sec())
	FillButtonRes.clear_hover_in(self)
	FillButtonRes.clear_latched_in(self)


## 战役过渡期间：菜单还在它下面，但 Esc/返回不能被菜单偷走。
func set_menu_input_blocked(on: bool) -> void:
	_menu_input_blocked = on
	if _menu_deck != null:
		_menu_deck.set_input_blocked(on)


func menu_input_blocked() -> bool:
	return _menu_input_blocked


func reset_panels() -> void:
	if _menu_deck != null:
		_menu_deck.reset_to_main(true)


## 菜单内返回（Esc / 安卓返回）：子页面退一层；主菜单返回 false，交给 main 弹退出确认。
func handle_back() -> bool:
	if _menu_input_blocked:
		return false
	if _menu_deck == null or not _menu_deck.visible:
		return false
	return _menu_deck.back()


func menu_deck():
	return _menu_deck


func main_panel():
	return _menu_deck.menu_main() if _menu_deck != null else null


func campaign_panel():
	return _menu_deck.campaign_panel() if _menu_deck != null else null


func campaign_detail_panel():
	return _menu_deck.campaign_detail_panel() if _menu_deck != null else null


func coop_start_panel():
	return _menu_deck.coop_start_panel() if _menu_deck != null else null


func coop_room_panel():
	return _menu_deck.coop_room_panel() if _menu_deck != null else null


func coop_ready_panel():
	return _menu_deck.coop_ready_panel() if _menu_deck != null else null


# ------------------------------------------------------------------
# 输入
# ------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if not (event is InputEventScreenTouch):
		return
	if (event as InputEventScreenTouch).pressed:
		return
	call_deferred("_clear_menu_hover")


func _clear_menu_hover() -> void:
	FillButtonRes.clear_hover_in(self)


func _unhandled_input(event: InputEvent) -> void:
	if _menu_input_blocked:
		return
	if not visible or _page != PAGE_MENU:
		return
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if k.pressed and not k.echo and k.keycode == KEY_ESCAPE:
		if handle_back():
			get_viewport().set_input_as_handled()


func _on_page_gui_input(event: InputEvent) -> void:
	if _page != PAGE_INTRO:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		dismiss_intro()


# ------------------------------------------------------------------
# 入场页
# ------------------------------------------------------------------

func _build_background() -> void:
	_bg = MenuBackgroundRes.new()
	_bg.name = "Background"
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.gui_input.connect(_on_page_gui_input)
	_root.add_child(_bg)


## 主菜单左侧那张**雕版图**。
##
## ★ 位置是**背景之上、入场页之下**：它天然只出现在「没有任何面板盖住的」左半边，
##   而且**跟着主面板一起横移**（见 `_sync_art_x()`）—— 切到战役 / 合作时
##   不是原地淡出，是跟面板一起滑出屏幕左边；回来时同一段滑动滑回来。
## ★ 矩形止于右侧面板的左缘（`size.x - side_w`）：面板底色是 0.94 的 alpha，
##   密排的亮线是会透出来的，所以宁可裁掉也不让它渗进 UI。
func _build_art() -> void:
	_art = EtchedPlateRes.new()
	_art.name = "MenuArt"
	_art.setup(cfg)
	_art.modulate.a = 0.0
	_root.add_child(_art)
	_root.resized.connect(_layout_art)
	_layout_art()


func _layout_art() -> void:
	if _art == null or not is_instance_valid(_art):
		return
	var sw: float = LayoutRes.side_w(_root.size.x)
	_art.size = Vector2(maxf(0.0, _root.size.x - sw), _root.size.y)
	_sync_art_x()


## 让左侧雕版**跟着主菜单面板一起右移**。
##
## ★★ 用户口径：切到战役 / 合作再切回来时，雕版不能是「突然又淡入一遍」，
##   而要**跟着右侧面板一起左移出去、再一起右移回来**。
##   ⇒ 于是它的 x 不是 0，而是「主面板当前位置 − 主菜单时主面板应在的位置」：
##     · 主菜单：主面板在 (w − side_w) ⇒ 偏移 0，雕版正对左区；
##     · 战役页：主面板滑到 0 ⇒ 偏移 −(w − side_w)，雕版整幅移出屏幕左边；
##     · 回来时偏移从 −(w − side_w) 回到 0，是**同一段滑动**，不是另一次淡入。
##   ★ 每帧读一次主面板的 x，而不是自己再补一条 tween：转场里主面板是被
##     `menu_deck` 的补间驱动的，跟着它走就永远不会和它脱拍（曲线、时长都不用管）。
##   ★ 只在值真的变了才赋值，避免每帧写 transform（会白白标脏 canvas item）。
func _sync_art_x() -> void:
	if _art == null or not is_instance_valid(_art) or _menu_deck == null:
		return
	var main = _menu_deck.menu_main()
	if main == null:
		return
	var base_x: float = _root.size.x - LayoutRes.side_w(_root.size.x)
	var dx: float = main.position.x - base_x
	if absf(_art.position.x - dx) > 0.01:
		_art.position.x = dx


func _process(_delta: float) -> void:
	# 只有菜单可见时才需要跟（进游戏之后 start_screen 是隐藏的）
	if not visible:
		return
	_sync_art_x()


## 左侧线稿控件（测试 / 截图用）。
func art():
	return _art


## 左侧雕版的淡入 / 淡出（唯一的入口：别的地方不要再直接改 `modulate.a`，
## 否则两条补间会互相打架）。
##
## @param sec 时长；动效关掉或 sec <= 0 时**瞬间到位**（状态照常切）。
##
## ★★ 曲线必须与 `menu_page.fade_glows()` **完全一致**（SINE / EASE_IN_OUT）：
##    入场那一下是「四角泛光与雕版同时渐显」，两条补间只要 easing 不同，
##    同一时刻两者的透明度就不一样 —— 用户看到的是「一个先亮」。
func _fade_art(to: float, sec: float) -> void:
	if _art == null or not is_instance_valid(_art):
		return
	if _art_tween != null and _art_tween.is_valid():
		_art_tween.kill()
	_art_tween = null
	to = clampf(to, 0.0, 1.0)
	if not ThemeRes.animations_enabled() or sec <= 0.0:
		_art.modulate.a = to
		return
	_art_tween = create_tween()
	_art_tween.tween_property(_art, "modulate:a", to, sec) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## 左侧雕版在「面板完全显现之后」淡入的时长。
func _art_fade_in_sec() -> float:
	return cfg.num("menu.plate.fade_in_sec", 0.6) if cfg != null else 0.6


func _build_intro() -> void:
	_intro = Control.new()
	_intro.name = "Intro"
	_intro.set_anchors_preset(Control.PRESET_FULL_RECT)
	_intro.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_intro)

	_emblem = MenuEmblemRes.new()
	_emblem.name = "Emblem"
	var e_size := cfg.num("menu.emblem_size", 150.0)
	_emblem.anchor_left = 0.5
	_emblem.anchor_right = 0.5
	_emblem.offset_left = -e_size * 0.5
	_emblem.offset_right = e_size * 0.5
	_emblem.offset_top = cfg.num("menu.emblem_top", 66.0)
	_emblem.offset_bottom = _emblem.offset_top + e_size
	_intro.add_child(_emblem)

	_title = TextMarksRes.SpacedLabel.new()
	_title.name = "Title"
	_title.text = cfg.str_val("menu.title", "DAE")
	_title.font = _font
	_title.font_size = int(cfg.num("menu.title_size", 128.0))
	_title.tracking = cfg.num("menu.title_tracking", 26.0)
	_title.color_from = _menu_color("menu.title_color", ThemeRes.text())
	_title.color_to = _menu_color("menu.title_gold_color", ThemeRes.accent())
	_title.anchor_left = 0.0
	_title.anchor_right = 1.0
	_title.offset_left = 0.0
	_title.offset_right = 0.0
	_title.offset_top = cfg.num("menu.title_top", 200.0)
	_title.offset_bottom = _title.offset_top + cfg.num("menu.title_height", 170.0)
	_intro.add_child(_title)

	_title_rule = _build_rule(_intro, "TitleRule",
		cfg.num("menu.title_top", 200.0) + cfg.num("menu.title_height", 170.0)
			+ cfg.num("menu.title_rule_gap", 44.0))

	_click_hint = _make_label(
		cfg.str_val("menu.click_text", "————点击任意处进入游戏————"),
		int(cfg.num("menu.click_size", 32.0)),
		_menu_color("menu.click_color", ThemeRes.text_dim())
	)
	_click_hint.name = "ClickHint"
	_click_hint.anchor_top = 1.0
	_click_hint.anchor_bottom = 1.0
	_click_hint.anchor_left = 0.0
	_click_hint.anchor_right = 1.0
	_click_hint.offset_left = 0.0
	_click_hint.offset_right = 0.0
	_click_hint.offset_top = -cfg.num("menu.click_bottom", 110.0)
	_click_hint.offset_bottom = _click_hint.offset_top + 44.0
	_intro.add_child(_click_hint)

	_shine = Control.new()
	_shine.name = "TitleShine"
	_shine.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shine.anchor_left = 0.0
	_shine.anchor_right = 1.0
	_shine.offset_left = 0.0
	_shine.offset_right = 0.0
	_shine.offset_top = _title.offset_top - 24.0
	_shine.offset_bottom = _title.offset_bottom + 24.0
	_shine.draw.connect(_on_shine_draw)
	_intro.add_child(_shine)


func _build_deck() -> void:
	_menu_deck = MenuDeckRes.new()
	_menu_deck.name = "MenuDeck"
	_root.add_child(_menu_deck)
	_menu_deck.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_menu_deck.setup(cfg, _font)
	_menu_deck.visible = false
	_menu_deck.campaign_level_chosen.connect(
		func(c, l, f): campaign_level_chosen.emit(c, l, f))
	_menu_deck.coop_host_started.connect(
		func(c, l, t): coop_host_started.emit(c, l, t))
	_menu_deck.coop_guest_started.connect(
		func(p, t): coop_guest_started.emit(p, t))
	_menu_deck.coop_solo_started.connect(
		func(c, l, a): coop_solo_started.emit(c, l, a))
	_menu_deck.ai_test_pressed.connect(func(): ai_test_pressed.emit())
	_menu_deck.quit_requested.connect(func(): quit_requested.emit())


func _build_rule(parent: Control, node_name: String, y: float) -> Control:
	var rule := TextMarksRes.Rule.new()
	rule.name = node_name
	rule.line_color = ThemeRes.with_alpha(ThemeRes.line(), 0.9)
	rule.line_width = cfg.num("menu.title_rule_height", 1.0)
	rule.fade = cfg.num("menu.title_rule_fade", 40.0)
	var w := cfg.num("menu.title_rule_width", 460.0)
	rule.anchor_left = 0.5
	rule.anchor_right = 0.5
	rule.offset_left = -w * 0.5
	rule.offset_right = w * 0.5
	rule.offset_top = y
	rule.offset_bottom = y + 1.0
	parent.add_child(rule)
	return rule


func _make_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	if _font != null:
		label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _menu_color(path: String, fallback: Color) -> Color:
	var v: Variant = cfg.get_path_value(path)
	if typeof(v) == TYPE_STRING:
		return ConfigRes.parse_color(String(v), fallback)
	return fallback


# ------------------------------------------------------------------
# 入场 → 主菜单
# ------------------------------------------------------------------

func dismiss_intro() -> bool:
	if _page != PAGE_INTRO or _intro_morphing:
		return false
	_stop_click_blink()
	_stop_title_shine()
	if not ThemeRes.animations_enabled() or _intro_morph_sec() <= 0.0:
		_finish_intro()
		return true
	_intro_morphing = true
	_play_intro_morph()
	return true


func _play_intro_morph() -> void:
	if _menu_deck == null:
		_finish_intro()
		return
	_menu_deck.visible = true
	_menu_deck.prepare_intro()
	_intro.z_index = 20
	if _title_rule != null:
		_title_rule.modulate.a = 1.0
	if _click_hint != null:
		_click_hint.modulate.a = 1.0

	var ready: bool = await _wait_targets_ready()
	if not is_instance_valid(self) or not _intro_morphing:
		return
	if not ready:
		push_warning("入场落位：主菜单目标没在若干帧内排好，直接切页。")
		_finish_intro()
		return

	var main = _menu_deck.menu_main()
	var target_logo: Rect2 = main.emblem_rect()
	var target_name: Rect2 = main.name_rect()
	var target_word = main.wordmark()
	var sec: float = _intro_morph_sec()
	_morph_tween = create_tween()
	_morph_tween.set_parallel(true)
	_morph_tween.set_trans(Tween.TRANS_CUBIC)
	_morph_tween.set_ease(Tween.EASE_IN_OUT)
	_morph_slide(_morph_tween, _emblem, target_logo, sec)
	_morph_slide(_morph_tween, _title, target_name, sec)
	_morph_tween.tween_method(_set_title_font_size, float(_title.font_size),
		float(target_word.font_size), sec)
	_morph_tween.tween_method(_set_title_tracking, float(_title.tracking),
		float(target_word.tracking), sec)
	_morph_tween.tween_property(main.background(), "modulate:a", 1.0, sec * 0.7)
	# ★ 四角泛光**不在这段里亮**：用户口径是「logo 与游戏名右移 + 面板渐显，
	#   随后四角泛光和左侧雕版**同时**渐显」。于是这里把它按在 0，
	#   真正的渐显由 `_finish_intro()` 同时发起（同一个时长）。
	if main != null:
		main.apply_glow_alpha(0.0)
	# 左侧雕版同样一点不露，等面板完全立好再淡入。
	if _art != null:
		_art.modulate.a = 0.0
	_morph_tween.tween_method(main.set_content_alpha, 0.0, 1.0, sec * 0.55) \
		.set_delay(sec * 0.45)
	if _title_rule != null:
		_morph_tween.tween_property(_title_rule, "modulate:a", 0.0, sec * 0.45)
	if _click_hint != null:
		_morph_tween.tween_property(_click_hint, "modulate:a", 0.0, sec * 0.45)
	_morph_tween.tween_callback(_on_morph_done).set_delay(sec)


func _wait_targets_ready(max_frames: int = 10) -> bool:
	for i in max_frames:
		var main = _menu_deck.menu_main() if _menu_deck != null else null
		if main != null:
			var lr: Rect2 = main.logo_rect()
			var nr: Rect2 = main.name_rect()
			if lr.position != Vector2.ZERO and lr.size.x > 1.0 \
					and nr.position != Vector2.ZERO and nr.size.x > 1.0:
				return true
		await get_tree().process_frame
	return false


func _on_morph_done() -> void:
	_morph_tween = null
	if not _intro_morphing:
		return
	_finish_intro()


func _finish_intro() -> void:
	if _page != PAGE_INTRO:
		return
	_intro_morphing = false
	_intro.z_index = 0
	# 「面板已经站好」这一刻：
	#   ① 面板收起底板 / 内容 / logo（泛光先留在 0）；
	#   ② 四角泛光 与 左侧雕版 **同时**开始渐显，同一个时长、同一条曲线。
	# ★ 用户口径的编排：logo/游戏名右移 + 面板渐显 → **随后**这两样一起亮。
	var sec: float = _art_fade_in_sec()
	if _menu_deck != null:
		_menu_deck.visible = true
		_menu_deck.finish_intro(false)
		var panel = _menu_deck.menu_main()
		if panel != null:
			panel.fade_glows(1.0, true, sec)
	if _art != null:
		# 扫描也在这时候重新起步：于是「画面淡进来」和「扫描从最左边进来」是同一拍。
		_art.restart_scan()
		_art.set_running(true)
		_fade_art(1.0, sec)
	show_page(PAGE_MENU)
	intro_dismissed.emit()


func _morph_slide(tw: Tween, src: Control, to_rect: Rect2, sec: float) -> void:
	if src == null:
		return
	var from: Rect2 = src.get_global_rect()
	var origin: Vector2 = _intro.global_position if _intro != null else Vector2.ZERO
	src.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	src.position = from.position - origin
	src.size = from.size
	tw.tween_property(src, "position", to_rect.position - origin, sec)
	tw.tween_property(src, "size", to_rect.size, sec)


func _cancel_intro_morph() -> void:
	if _morph_tween != null and _morph_tween.is_valid():
		_morph_tween.kill()
	_morph_tween = null
	_intro_morphing = false


func _intro_morph_sec() -> float:
	return cfg.num("menu.intro_morph_sec", 0.5) if cfg != null else 0.5


func _set_title_font_size(v: float) -> void:
	if _title != null:
		_title.font_size = int(round(v))


func _set_title_tracking(v: float) -> void:
	if _title != null:
		_title.tracking = v


# ------------------------------------------------------------------
# 呼吸 / 扫光
# ------------------------------------------------------------------

func start_click_blink() -> void:
	if _click_hint == null:
		return
	_stop_click_blink()
	var lo := clampf(cfg.num("menu.click_alpha_min", 0.15), 0.0, 1.0)
	var hi := clampf(cfg.num("menu.click_alpha_max", 1.0), 0.0, 1.0)
	if hi < lo:
		var tmp := lo
		lo = hi
		hi = tmp
	_click_hint.modulate.a = lo
	_blink_tween = create_tween()
	_blink_tween.tween_property(_click_hint, "modulate:a", hi,
		cfg.num("menu.intro_fade_sec", 0.9)).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_blink_tween.tween_interval(BLINK_START_DELAY)
	_blink_tween.set_loops()
	_blink_tween.tween_property(_click_hint, "modulate:a", lo, BLINK_PHASE_SEC) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_blink_tween.tween_property(_click_hint, "modulate:a", hi, BLINK_PHASE_SEC) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _stop_click_blink() -> void:
	if _blink_tween != null and _blink_tween.is_valid():
		_blink_tween.kill()
	_blink_tween = null


func start_title_shine() -> void:
	if _shine == null or _title == null:
		return
	_stop_title_shine()
	_shine.visible = true
	_shine.modulate.a = 0.0
	_shine.set_meta("shine_t", 0.0)
	_shine.queue_redraw()
	_shine_tween = create_tween()
	_shine_tween.tween_interval(SHINE_DELAY_SEC)
	_shine_tween.tween_method(_set_shine_t, 0.0, 1.0, SHINE_SEC) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_shine_tween.tween_callback(_stop_title_shine)


func _stop_title_shine() -> void:
	if _shine_tween != null and _shine_tween.is_valid():
		_shine_tween.kill()
	_shine_tween = null
	if _shine != null:
		_shine.visible = false
		_shine.modulate.a = 0.0


func _set_shine_t(t: float) -> void:
	if _shine == null:
		return
	_shine.set_meta("shine_t", t)
	_shine.modulate.a = sin(clampf(t, 0.0, 1.0) * PI)
	_shine.queue_redraw()


func _on_shine_draw() -> void:
	if _shine == null:
		return
	var w: float = _shine.size.x
	var h: float = _shine.size.y
	if w <= 1.0 or h <= 1.0:
		return
	var t: float = float(_shine.get_meta("shine_t", 0.0))
	var band_w: float = maxf(48.0, w * 0.06)
	var cx: float = -band_w + (w + band_w * 2.0) * t
	_shine.draw_set_transform(Vector2(cx, h * 0.5), SHINE_SKEW, Vector2.ONE)
	var gold := ThemeRes.accent_bright()
	var seg := band_w / 3.0
	var alphas := [0.04, 0.10, 0.04]
	for i in 3:
		var a: float = alphas[i]
		_shine.draw_rect(Rect2(-band_w * 0.5 + seg * float(i), -h, seg, h * 2.0),
			ThemeRes.with_alpha(gold, a), true)
	_shine.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# ------------------------------------------------------------------
# 启动黑幕
# ------------------------------------------------------------------

func _build_boot_fade() -> void:
	if not ThemeRes.animations_enabled():
		return
	if cfg.num("menu.intro_fade_in_sec", 0.8) <= 0.0:
		return
	_boot_fade = ColorRect.new()
	_boot_fade.name = "BootFade"
	var c: Color = _menu_color("menu.intro_fade_in_color", Color(0.0, 0.0, 0.0))
	c.a = 1.0
	_boot_fade.color = c
	_boot_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_boot_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_boot_fade)


func _play_boot_fade_in() -> void:
	if _boot_fade == null:
		return
	var sec: float = cfg.num("menu.intro_fade_in_sec", 0.8)
	if not ThemeRes.animations_enabled() or sec <= 0.0:
		_finish_boot_fade()
		return
	_boot_fade.modulate.a = 1.0
	_boot_tween = create_tween()
	_boot_tween.tween_property(_boot_fade, "modulate:a", 0.0, sec) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_boot_tween.tween_callback(_finish_boot_fade)


func _finish_boot_fade() -> void:
	if _boot_tween != null and _boot_tween.is_valid():
		_boot_tween.kill()
	_boot_tween = null
	if _boot_fade != null and is_instance_valid(_boot_fade):
		_boot_fade.queue_free()
	_boot_fade = null


func boot_fade() -> ColorRect:
	return _boot_fade if _boot_fade != null and is_instance_valid(_boot_fade) else null


func boot_fade_sec() -> float:
	return cfg.num("menu.intro_fade_in_sec", 0.8) if cfg != null else 0.0


func intro_title() -> Control:
	return _title
