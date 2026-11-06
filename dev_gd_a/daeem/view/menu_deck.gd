## menu_deck.gd —— 新菜单的页面栈 / 横向滑动 / 面板显隐 / 输入闸。
##
## 六页：MAIN / CAMPAIGN / CAMPAIGN_DETAIL / COOP_START / COOP_ROOM / COOP_READY，
## 外加一个覆盖在准备页之上的 COOP_MAP（地图选择）。战役过渡仍由 main 的全屏页负责。
##
## 本文件只做「谁在左、谁在右、谁可见、谁能点」；不认识战役数据、也不认识联机规则。
extends Control

signal campaign_level_chosen(campaign_id: String, level_id: String, faction_id: String)
signal coop_host_started(campaign_id: String, level_id: String, transport)
signal coop_guest_started(payload: Dictionary, transport)
signal coop_solo_started(campaign_id: String, level_id: String, ai_setup: Dictionary)
signal ai_test_pressed
## ★★ 2026.10.29：ai_test 下面那颗「看海」按钮 —— 同一张 between_moutains 地图，
##    但双方都由 commander AI 操作，玩家只观战。
signal see_ai_pressed
## ★★ 新手教程测试入口（主菜单左上角，接在 see_ai 下面）。
signal ce_xs_1_pressed
signal ce_xs_2_pressed
signal quit_requested
signal page_changed(page: String)
signal map_open_changed(open: bool)
## ★★ 备战页开 / 关：给 start_screen 用（左侧雕版轮播要跟着渐隐 / 恢复）。
signal prepare_open_changed(open: bool)

const LayoutRes = preload("res://view/menu_deck_layout.gd")
const ThemeRes = preload("res://view/theme.gd")
const MainPanelRes = preload("res://view/main_menu_panel.gd")
const PreparePanelRes = preload("res://view/prepare_panel.gd")
const CampaignPanelRes = preload("res://view/campaign_map_panel.gd")
const CampaignDetailRes = preload("res://view/campaign_detail_panel.gd")
const CoopStartRes = preload("res://view/coop_start_panel.gd")
const CoopRoomRes = preload("res://view/coop_room_panel.gd")
const CoopReadyRes = preload("res://view/coop_ready_panel.gd")
const MapPickerRes = preload("res://view/coop_map_picker.gd")
const SessionRes = preload("res://view/coop_session.gd")
const TextButtonRes = preload("res://view/menu_text_button.gd")

const PAGE_MAIN := "main"
const PAGE_PREPARE := "prepare"
const PAGE_CAMPAIGN := "campaign"
const PAGE_DETAIL := "detail"
const PAGE_COOP_START := "coop_start"
const PAGE_COOP_ROOM := "coop_room"
const PAGE_COOP_READY := "coop_ready"

const FADE_SEC := 0.28
const DEFAULT_AI_TEST_BUTTON := "ai_test"
const DEFAULT_SEE_AI_BUTTON := "see_ai"
const DEFAULT_CE_XS_1_BUTTON := "ce_xs_1"
const DEFAULT_CE_XS_2_BUTTON := "ce_xs_2"

var cfg = null
var font: Font = null

var _main = null
var _prepare = null
var _campaign = null
var _detail = null
var _coop_start = null
var _coop_room = null
var _coop_ready = null
var _map_picker = null
var _session = null

var _page: String = PAGE_MAIN
var _busy: bool = false
## 屏幕左上角的 ai_test 测试入口：只在主菜单页显示，开场转场期间也隐藏。
var _ai_test_btn: Control = null
## ★★ 2026.10.29：ai_test 正下方那颗「看海」入口（同一张图，双方 commander AI）。
var _see_ai_btn: Control = null
## ★★ 新手教程测试入口：ce_xs_1 / ce_xs_2。
var _ce_xs_1_btn: Control = null
var _ce_xs_2_btn: Control = null
var _intro_pending: bool = true
var _map_open: bool = false
var _ready_source: String = "coop_start"
var _input_blocked: bool = false
var _tween: Tween = null
var _shield: Control = null


func setup(p_cfg, p_font: Font) -> void:
	cfg = p_cfg
	font = p_font
	name = "MenuDeck"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_session = SessionRes.new()
	_session.name = "CoopSession"
	add_child(_session)
	_session.setup(cfg)
	_session.host_started.connect(func(c, l, t): coop_host_started.emit(c, l, t))
	_session.guest_started.connect(func(p, t): coop_guest_started.emit(p, t))
	_session.solo_started.connect(func(c, l, a): coop_solo_started.emit(c, l, a))

	var sw := LayoutRes.side_w(size.x)
	var ww := LayoutRes.wide_w(size.x)
	var h := size.y

	# ★★ 备战页必须**先于**主面板加进树：主面板上滑之后，剩下的那条动作条
	#    要压在备战页之上；子节点顺序就是绘制顺序（后加的在上）。
	_prepare = PreparePanelRes.new()
	add_child(_prepare)
	_prepare.position = Vector2.ZERO
	_prepare.size = size
	_prepare.setup(cfg, font)
	_prepare.back_pressed.connect(close_prepare)

	_main = MainPanelRes.new()
	add_child(_main)
	_main.position = Vector2(size.x - sw, 0.0)
	_main.size = Vector2(sw, h)
	_main.setup(cfg, font)
	_main.campaign_pressed.connect(goto_campaign)
	_main.coop_pressed.connect(goto_coop_start)
	_main.quit_pressed.connect(func(): quit_requested.emit())
	_main.prepare_pressed.connect(goto_prepare)

	var test_label := String(cfg.str_val(
		"menu.deck.main.ai_test_button", DEFAULT_AI_TEST_BUTTON)).strip_edges()
	if test_label == "":
		test_label = DEFAULT_AI_TEST_BUTTON
	_ai_test_btn = TextButtonRes.new()
	_ai_test_btn.name = "AiTestBtn"
	_ai_test_btn.visible = false
	_ai_test_btn.setup(font, test_label, 32)
	_ai_test_btn.pressed.connect(func(): ai_test_pressed.emit())
	add_child(_ai_test_btn)

	var see_label := String(cfg.str_val(
		"menu.deck.main.see_ai_button", DEFAULT_SEE_AI_BUTTON)).strip_edges()
	if see_label == "":
		see_label = DEFAULT_SEE_AI_BUTTON
	_see_ai_btn = TextButtonRes.new()
	_see_ai_btn.name = "SeeAiBtn"
	_see_ai_btn.visible = false
	_see_ai_btn.setup(font, see_label, 32)
	_see_ai_btn.pressed.connect(func(): see_ai_pressed.emit())
	add_child(_see_ai_btn)

	var xs1_label := String(cfg.str_val(
		"menu.deck.main.ce_xs_1_button", DEFAULT_CE_XS_1_BUTTON)).strip_edges()
	if xs1_label == "":
		xs1_label = DEFAULT_CE_XS_1_BUTTON
	_ce_xs_1_btn = TextButtonRes.new()
	_ce_xs_1_btn.name = "CeXs1Btn"
	_ce_xs_1_btn.visible = false
	_ce_xs_1_btn.setup(font, xs1_label, 32)
	_ce_xs_1_btn.pressed.connect(func(): ce_xs_1_pressed.emit())
	add_child(_ce_xs_1_btn)

	var xs2_label := String(cfg.str_val(
		"menu.deck.main.ce_xs_2_button", DEFAULT_CE_XS_2_BUTTON)).strip_edges()
	if xs2_label == "":
		xs2_label = DEFAULT_CE_XS_2_BUTTON
	_ce_xs_2_btn = TextButtonRes.new()
	_ce_xs_2_btn.name = "CeXs2Btn"
	_ce_xs_2_btn.visible = false
	_ce_xs_2_btn.setup(font, xs2_label, 32)
	_ce_xs_2_btn.pressed.connect(func(): ce_xs_2_pressed.emit())
	add_child(_ce_xs_2_btn)

	_campaign = CampaignPanelRes.new()
	add_child(_campaign)
	_campaign.position = Vector2(sw, 0.0)
	_campaign.size = Vector2(ww, h)
	_campaign.setup(cfg, font)
	_campaign.back_pressed.connect(goto_main)
	_campaign.flag_pressed.connect(goto_campaign_detail)

	_detail = CampaignDetailRes.new()
	add_child(_detail)
	_detail.position = Vector2(size.x - sw, 0.0)
	_detail.size = Vector2(sw, h)
	_detail.setup(cfg, font)
	_detail.back_pressed.connect(back_to_campaign)
	_detail.faction_chosen.connect(func(c, l, f): campaign_level_chosen.emit(c, l, f))

	_coop_start = CoopStartRes.new()
	add_child(_coop_start)
	_coop_start.position = Vector2(sw, 0.0)
	_coop_start.size = Vector2(ww, h)
	_coop_start.setup(cfg, font)
	_coop_start.back_pressed.connect(_on_coop_start_back)
	_coop_start.ai_pressed.connect(_on_coop_ai)
	_coop_start.room_pressed.connect(goto_coop_room)

	_coop_room = CoopRoomRes.new()
	add_child(_coop_room)
	_coop_room.position = Vector2(size.x - sw, 0.0)
	_coop_room.size = Vector2(sw, h)
	_coop_room.setup(cfg, font, _session)
	_coop_room.back_pressed.connect(_on_coop_room_back)
	_coop_room.room_entered.connect(func(): goto_coop_ready("coop_room"))

	_coop_ready = CoopReadyRes.new()
	add_child(_coop_ready)
	_coop_ready.position = Vector2(size.x - sw, 0.0)
	_coop_ready.size = Vector2(sw, h)
	_coop_ready.setup(cfg, font, _session)
	_coop_ready.back_pressed.connect(_on_coop_ready_back)
	_coop_ready.map_requested.connect(open_map_picker)

	_map_picker = MapPickerRes.new()
	add_child(_map_picker)
	_map_picker.position = Vector2(size.x, 0.0)
	_map_picker.size = Vector2(sw, h)
	_map_picker.setup(cfg, font, _session)
	_map_picker.confirmed.connect(_on_map_confirmed)
	_map_picker.cancelled.connect(close_map_picker)

	_shield = Control.new()
	_shield.name = "TransitionShield"
	_shield.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_shield.mouse_filter = Control.MOUSE_FILTER_STOP
	_shield.z_index = 200
	_shield.visible = false
	add_child(_shield)

	resized.connect(_on_resized)
	_apply_layout(PAGE_MAIN, true)
	_hide_all_except([_main])
	_main.set_sidebar_dimmed(false, false)


# ------------------------------------------------------------------
# 对外
# ------------------------------------------------------------------

func current_page() -> String:
	return _page


func page() -> String:
	return _page


func is_busy() -> bool:
	return _busy


func is_map_open() -> bool:
	return _map_open


## 战役过渡页盖在菜单上时用：把菜单的 Esc 处理彻底关掉，避免返回键在背后翻页。
func set_input_blocked(on: bool) -> void:
	_input_blocked = on


func menu_main():
	return _main


func prepare_panel():
	return _prepare


func campaign_panel():
	return _campaign


func campaign_detail_panel():
	return _detail


func coop_start_panel():
	return _coop_start


func coop_room_panel():
	return _coop_room


func coop_ready_panel():
	return _coop_ready


func map_picker():
	return _map_picker


func session():
	return _session


## 入场页测量目标用：页面停在 MAIN、主面板在右，但背景与内容全透明。
func prepare_intro() -> void:
	_intro_pending = true
	_page = PAGE_MAIN
	_apply_layout(PAGE_MAIN, true)
	_hide_all_except([_main])
	_main.visible = true
	_main.set_logo_visible(false)
	_main.background().modulate.a = 0.0
	_main.set_content_alpha(0.0)
	# 入场时四角泛光从灭开始，由 start_screen 的入场补间渐显。
	_main.set_glows(false, false)
	_main.set_sidebar_dimmed(false, false)


## 入场落位结束：底板 / 内容 / logo 到位。
##
## @param with_glows true = 泛光**立刻**给满（从战斗回菜单那种「整页一下子就出来」的场合）；
##        false = 泛光先留在 0，由调用方（start_screen 的入场编排）随后和左侧雕版**一起**渐显
##        —— 用户口径：「logo 与游戏名右移 + 面板渐显，**随后**四角泛光和雕版同时渐显」。
func finish_intro(with_glows: bool = true) -> void:
	if _main == null:
		return
	_main.background().modulate.a = 1.0
	_main.set_content_alpha(1.0)
	if with_glows:
		_main.set_glows(true, false)
	_main.set_logo_visible(true)
	_intro_pending = false
	_refresh_ai_test_btn(_page)
	_refresh_see_ai_btn(_page)
	_refresh_ce_xs_1_btn(_page)
	_refresh_ce_xs_2_btn(_page)


func reset_to_main(instant: bool = true) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
	if _session != null:
		_session.leave_all()
	if _coop_start != null:
		_coop_start.set_ai_joined(false)
	var was_prepare: bool = _page == PAGE_PREPARE or (_prepare != null and _prepare.visible)
	if _prepare != null:
		_prepare.stop_breathing()
		_prepare.visible = false
		_prepare.set_glows(false, false)
	if _main != null:
		_main.set_prepare_latched(false)
	_map_open = false
	_map_picker.visible = false
	_map_picker.set_glows(false, false)
	_intro_pending = false
	_page = PAGE_MAIN
	_busy = false
	_shield.visible = false
	_apply_layout(PAGE_MAIN, instant)
	_hide_all_except([_main])
	_main.visible = true
	_main.background().modulate.a = 1.0
	_main.set_content_alpha(1.0)
	_main.set_logo_visible(true)
	_main.set_sidebar_dimmed(false, instant)
	if was_prepare:
		prepare_open_changed.emit(false)
	page_changed.emit(_page)


# ------------------------------------------------------------------
# 导航
# ------------------------------------------------------------------

func goto_main() -> void:
	if _busy:
		return
	if _coop_start != null:
		_coop_start.set_ai_joined(false)
	var moves: Array = []
	if _campaign != null and _campaign.visible:
		moves.append(_move(_campaign, _campaign.position.x, size.x, false))
	if _coop_start != null and _coop_start.visible:
		moves.append(_move(_coop_start, _coop_start.position.x, size.x, false))
	moves.append(_move(_main, _main.position.x, size.x - LayoutRes.side_w(size.x), false))
	_animate(moves, PAGE_MAIN)


## ★★ 主菜单 → 备战页。
##
## 三件事同时发生（用户口径）：
##   ① 主菜单整体**上滑**，只留下底部那条「自定义 / 备战」；
##   ② 备战页淡入（返回条 / 两块面板 / 右侧两枚按钮）；
##   ③ 左侧雕版轮播图渐隐（start_screen 收到 prepare_open_changed 后执行）。
## 备战按钮的金色填充在按下时就由 panel 锁成常驻，因此上滑全程保持金色。
func goto_prepare() -> void:
	if _busy or _page == PAGE_PREPARE or _prepare == null:
		return
	var sw := LayoutRes.side_w(size.x)
	var top_y: float = -(size.y - LayoutRes.PREP_HEADER_H)
	_prepare.visible = true
	_prepare.position = Vector2.ZERO
	_prepare.modulate.a = 0.0
	_prepare.start_breathing()
	_prepare.reset_scroll()
	_prepare.reset_selection()
	_main.set_prepare_latched(true)
	prepare_open_changed.emit(true)
	var moves: Array = [
		_move(_main, _main.position.x, size.x - sw, false, _main.position.y, top_y),
		_move(_prepare, 0.0, 0.0, true, 0.0, 0.0),
	]
	_animate(moves, PAGE_PREPARE)


## ★★ 备战页 → 主菜单：主菜单滑回原位、备战页淡出、轮播图重新渐显、
## 备战按钮解除常驻（金色在 0.08s 内反向渐出）。
func close_prepare() -> void:
	if _busy or _page != PAGE_PREPARE:
		return
	# ★ 不在这里停呼吸 / 不在这里解除「备战」的金色常驻：
	#   · 呼吸早停会把字瞬间拉回全亮，而页面正在淡出 —— 看着像闪一下；
	#   · 金色在返回途中继续保持，等主菜单落回原位的那一拍才反向渐出
	#     （见 `_finish_moves()`）。
	prepare_open_changed.emit(false)
	var out := _move(_prepare, 0.0, 0.0, false, 0.0, 0.0)
	out["fade_out"] = true
	var moves: Array = [
		_move(_main, _main.position.x, size.x - LayoutRes.side_w(size.x), false,
			_main.position.y, 0.0),
		out,
	]
	_animate(moves, PAGE_MAIN)


func goto_campaign() -> void:
	if _busy:
		return
	var sw := LayoutRes.side_w(size.x)
	_campaign.visible = true
	_campaign.position = Vector2(size.x, 0.0)
	var moves: Array = [
		_move(_main, _main.position.x, 0.0, false),
		_move(_campaign, size.x, sw, true),
	]
	_animate(moves, PAGE_CAMPAIGN)


func goto_campaign_detail(chapter: Dictionary) -> void:
	if _busy:
		return
	_detail.set_chapter(chapter)
	_detail.visible = true
	_detail.position = Vector2(size.x, 0.0)
	var sw := LayoutRes.side_w(size.x)
	_main.visible = true
	var moves: Array = [
		_move(_main, _main.position.x, -sw, false),
		_move(_campaign, sw, 0.0, false),
		_move(_detail, size.x, size.x - sw, true),
	]
	_animate(moves, PAGE_DETAIL)


func back_to_campaign() -> void:
	if _busy:
		return
	var sw := LayoutRes.side_w(size.x)
	_main.visible = true
	_main.position = Vector2(-sw, 0.0)
	_campaign.visible = true
	_campaign.position = Vector2(0.0, 0.0)
	var moves: Array = [
		_move(_main, -sw, 0.0, false),
		_move(_campaign, 0.0, sw, false),
		_move(_detail, _detail.position.x, size.x, false),
	]
	_animate(moves, PAGE_CAMPAIGN)


func goto_coop_start() -> void:
	if _busy:
		return
	_coop_start.set_ai_joined(false)
	_coop_start.visible = true
	_coop_start.position = Vector2(size.x, 0.0)
	var moves: Array = [
		_move(_main, _main.position.x, 0.0, false),
		_move(_coop_start, size.x, LayoutRes.side_w(size.x), true),
	]
	_animate(moves, PAGE_COOP_START)


func goto_coop_room() -> void:
	if _busy:
		return
	if _session != null:
		_session.enter_room_mode()
	if _coop_start != null:
		_coop_start.set_ai_joined(false)
	var sw := LayoutRes.side_w(size.x)
	_coop_start.visible = true
	_coop_start.position = Vector2(sw, 0.0)
	_coop_room.visible = true
	_coop_room.position = Vector2(size.x, 0.0)
	_main.visible = true
	_main.position = Vector2(0.0, 0.0)
	var moves: Array = [
		_move(_main, 0.0, -sw, false),
		_move(_coop_start, sw, 0.0, false),
		_move(_coop_room, size.x, size.x - sw, true),
	]
	_animate(moves, PAGE_COOP_ROOM)


func goto_coop_ready(source: String) -> void:
	if _busy:
		return
	_ready_source = source
	_coop_ready.set_source(source)
	_coop_ready.refresh()
	_coop_ready.visible = true
	_coop_ready.position = Vector2(size.x, 0.0)
	var sw := LayoutRes.side_w(size.x)
	var moves: Array = []
	if source == "coop_room" and _coop_room.visible:
		moves.append(_move(_coop_room, _coop_room.position.x, size.x, false))
	else:
		_main.visible = true
		moves.append(_move(_main, _main.position.x, -sw, false))
		_coop_start.visible = true
		moves.append(_move(_coop_start, _coop_start.position.x, 0.0, false))
	moves.append(_move(_coop_ready, size.x, size.x - sw, true))
	_animate(moves, PAGE_COOP_READY, 0.06 if source == "coop_room" else 0.0)


func _on_coop_ready_back() -> void:
	if _busy:
		return
	if _ready_source == "coop_room":
		_coop_room.visible = true
		_coop_room.position = Vector2(size.x, 0.0)
		var moves: Array = [
			_move(_coop_ready, _coop_ready.position.x, size.x, false),
			_move(_coop_room, size.x, size.x - LayoutRes.side_w(size.x), true),
		]
		_animate(moves, PAGE_COOP_ROOM)
	else:
		_session.leave_all()
		_coop_start.set_ai_joined(false)
		var sw := LayoutRes.side_w(size.x)
		_main.visible = true
		_main.position = Vector2(-sw, 0.0)
		_coop_start.visible = true
		_coop_start.position = Vector2(0.0, 0.0)
		var moves: Array = [
			_move(_main, -sw, 0.0, false),
			_move(_coop_ready, _coop_ready.position.x, size.x, false),
			_move(_coop_start, 0.0, sw, false),
		]
		_animate(moves, PAGE_COOP_START)


func _on_coop_start_back() -> void:
	if _busy:
		return
	_session.leave_all()
	_coop_start.set_ai_joined(false)
	goto_main()


func _on_coop_room_back() -> void:
	if _busy:
		return
	_session.leave_room()
	var sw := LayoutRes.side_w(size.x)
	_main.visible = true
	_main.position = Vector2(-sw, 0.0)
	_coop_start.visible = true
	_coop_start.position = Vector2(0.0, 0.0)
	var moves: Array = [
		_move(_main, -sw, 0.0, false),
		_move(_coop_room, _coop_room.position.x, size.x, false),
		_move(_coop_start, 0.0, sw, false),
	]
	_animate(moves, PAGE_COOP_START)


func _on_coop_ai() -> void:
	if _busy:
		return
	_session.enter_ai_mode()
	_coop_start.set_ai_joined(true)
	goto_coop_ready("coop_start")


func back() -> bool:
	if _busy:
		return true
	if _map_open:
		close_map_picker()
		return true
	match _page:
		PAGE_PREPARE:
			close_prepare()
		PAGE_CAMPAIGN:
			goto_main()
		PAGE_DETAIL:
			back_to_campaign()
		PAGE_COOP_START:
			_on_coop_start_back()
		PAGE_COOP_ROOM:
			_on_coop_room_back()
		PAGE_COOP_READY:
			_on_coop_ready_back()
		_:
			return false
	return true


# ------------------------------------------------------------------
# 地图选择
# ------------------------------------------------------------------

func open_map_picker() -> void:
	if _busy or _page != PAGE_COOP_READY or _session == null:
		return
	if _session.is_guest() or not (_session.is_ai() or _session.is_host()):
		return
	_map_open = true
	_map_picker.set_current(_session.current_entry())
	_map_picker.visible = true
	_map_picker.position = Vector2(size.x, 0.0)
	# 这一层是整块面板自己在渐显（modulate 0→1），泛光直接给满跟着面板走。
	_map_picker.set_glows(true, false)
	if not ThemeRes.animations_enabled():
		_map_picker.position.x = size.x - LayoutRes.side_w(size.x)
		_map_picker.modulate.a = 1.0
		map_open_changed.emit(true)
		return
	_busy = true
	_shield.visible = true
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_map_picker, "position:x", size.x - LayoutRes.side_w(size.x), 0.32) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(_map_picker, "modulate:a", 1.0, 0.22)
	_tween = tw
	tw.chain().tween_callback(func():
		_busy = false
		_shield.visible = false
		map_open_changed.emit(true))


func close_map_picker() -> void:
	if _busy or not _map_open:
		return
	_map_open = false
	if not ThemeRes.animations_enabled():
		_map_picker.visible = false
		_map_picker.position = Vector2(size.x, 0.0)
		_map_picker.set_glows(false, false)
		map_open_changed.emit(false)
		return
	_busy = true
	_shield.visible = true
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_map_picker, "position:x", size.x, 0.28) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.tween_property(_map_picker, "modulate:a", 0.0, 0.20)
	_tween = tw
	tw.chain().tween_callback(func():
		_map_picker.visible = false
		_map_picker.set_glows(false, false)
		_busy = false
		_shield.visible = false
		map_open_changed.emit(false))


func _on_map_confirmed(entry: Dictionary) -> void:
	_session.select_map(entry)
	_coop_ready.refresh()
	close_map_picker()


# ------------------------------------------------------------------
# 转场 / 布局
# ------------------------------------------------------------------

func _move(panel: Control, from_x: float, to_x: float, fade: bool,
		from_y: float = 0.0, to_y: float = 0.0) -> Dictionary:
	return {"panel": panel, "from": from_x, "to": to_x, "fade": fade,
		"from_y": from_y, "to_y": to_y}


func _animate(moves: Array, page: String, delay: float = 0.0) -> void:
	if _ai_test_btn != null and page != PAGE_MAIN:
		_ai_test_btn.visible = false
	if _see_ai_btn != null and page != PAGE_MAIN:
		_see_ai_btn.visible = false
	if _ce_xs_1_btn != null and page != PAGE_MAIN:
		_ce_xs_1_btn.visible = false
	if _ce_xs_2_btn != null and page != PAGE_MAIN:
		_ce_xs_2_btn.visible = false
	var sec: float = 0.46
	if cfg != null:
		sec = maxf(0.0, cfg.num("menu.deck.transition_sec", 0.46))
	if not ThemeRes.animations_enabled() or sec <= 0.0:
		_apply_layout(page, true)
		_finish_moves(moves, page)
		return
	_busy = true
	_shield.visible = true
	for m in moves:
		var p: Control = m["panel"]
		p.visible = true
		p.position = Vector2(float(m["from"]), float(m.get("from_y", 0.0)))
		# fade = 整块从 0 渐显；fade_out = 从 1 渐隐；两者都从 0/1 起。
		p.modulate.a = 0.0 if bool(m["fade"]) else 1.0
	_apply_dims(page)
	_sync_glows(page, true, moves)
	if _main != null:
		_main.set_active(_active_for(page))
	var tw := create_tween()
	tw.set_parallel(true)
	for m in moves:
		var p: Control = m["panel"]
		tw.tween_property(p, "position:x", float(m["to"]), sec) \
			.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_IN_OUT)
		if not is_equal_approx(float(m.get("from_y", 0.0)), float(m.get("to_y", 0.0))):
			tw.tween_property(p, "position:y", float(m["to_y"]), sec) \
				.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_IN_OUT)
		if bool(m["fade"]):
			tw.tween_property(p, "modulate:a", 1.0, FADE_SEC)
		elif bool(m.get("fade_out", false)):
			tw.tween_property(p, "modulate:a", 0.0, FADE_SEC)
	_tween = tw
	tw.chain().tween_callback(func():
		_tween = null
		_busy = false
		_shield.visible = false
		_apply_layout(page, true)
		_finish_moves(moves, page)
		page_changed.emit(page))


func _finish_moves(_moves: Array, page: String) -> void:
	_page = page
	if page != PAGE_PREPARE:
		if _prepare != null:
			_prepare.stop_breathing()
		# 离开备战页的落点才解除「备战」的常驻金：返回途中它仍是当前页签。
		if _main != null:
			_main.set_prepare_latched(false)
	_refresh_ai_test_btn(page)
	_refresh_see_ai_btn(page)
	_refresh_ce_xs_1_btn(page)
	_refresh_ce_xs_2_btn(page)
	var keep: Array = _visible_for(page)
	_hide_all_except(keep)
	for p in keep:
		p.visible = true
		p.modulate.a = 1.0


func _visible_for(page: String) -> Array:
	match page:
		PAGE_MAIN:
			return [_main]
		PAGE_PREPARE:
			return [_prepare, _main]
		PAGE_CAMPAIGN:
			return [_main, _campaign]
		PAGE_DETAIL:
			return [_campaign, _detail]
		PAGE_COOP_START:
			return [_main, _coop_start]
		PAGE_COOP_ROOM:
			return [_coop_start, _coop_room]
		PAGE_COOP_READY:
			return [_coop_start, _coop_ready]
		_:
			return [_main]


func _hide_all_except(keep: Array) -> void:
	for p in [_prepare, _main, _campaign, _detail, _coop_start, _coop_room, _coop_ready]:
		if p != null and not keep.has(p):
			p.visible = false


func _apply_layout(page: String, instant: bool) -> void:
	var sw := LayoutRes.side_w(size.x)
	var ww := LayoutRes.wide_w(size.x)
	var h := size.y
	_main.size = Vector2(sw, h)
	_prepare.size = size
	_campaign.size = Vector2(ww, h)
	_detail.size = Vector2(sw, h)
	_coop_start.size = Vector2(ww, h)
	_coop_room.size = Vector2(sw, h)
	_coop_ready.size = Vector2(sw, h)
	_map_picker.size = Vector2(sw, h)

	match page:
		PAGE_MAIN:
			_main.position = Vector2(size.x - sw, 0.0)
			_main.visible = true
		PAGE_PREPARE:
			# 主菜单整体上滑，只留下最后 MAIN_BOTTOM_H 高的底部动作条。
			_main.position = Vector2(size.x - sw, -(h - LayoutRes.PREP_HEADER_H))
			_main.visible = true
			_prepare.position = Vector2.ZERO
			_prepare.visible = true
		PAGE_CAMPAIGN:
			_main.position = Vector2(0.0, 0.0)
			_main.visible = true
			_campaign.position = Vector2(sw, 0.0)
			_campaign.visible = true
		PAGE_DETAIL:
			_main.position = Vector2(-sw, 0.0)
			_campaign.position = Vector2(0.0, 0.0)
			_detail.position = Vector2(size.x - sw, 0.0)
			_campaign.visible = true
			_detail.visible = true
		PAGE_COOP_START:
			_main.position = Vector2(0.0, 0.0)
			_main.visible = true
			_coop_start.position = Vector2(sw, 0.0)
			_coop_start.visible = true
		PAGE_COOP_ROOM:
			_main.position = Vector2(-sw, 0.0)
			_coop_start.position = Vector2(0.0, 0.0)
			_coop_room.position = Vector2(size.x - sw, 0.0)
			_coop_start.visible = true
			_coop_room.visible = true
		PAGE_COOP_READY:
			_main.position = Vector2(-sw, 0.0)
			_coop_start.position = Vector2(0.0, 0.0)
			_coop_ready.position = Vector2(size.x - sw, 0.0)
			_coop_start.visible = true
			_coop_ready.visible = true
	_apply_dims(page)
	if _main != null:
		_main.set_active(_active_for(page))
	_layout_ai_test_btn()
	_layout_see_ai_btn()
	_layout_ce_xs_1_btn()
	_layout_ce_xs_2_btn()
	_refresh_ai_test_btn(page)
	_refresh_see_ai_btn(page)
	_refresh_ce_xs_1_btn(page)
	_refresh_ce_xs_2_btn(page)
	if instant:
		_main.background().modulate.a = 1.0
		_main.set_content_alpha(1.0)
	# 布局落定时把泛光对到目标值（转场中途 _busy，不会走到这里，补间不被打断）。
	if not _busy:
		_sync_glows(page, false)


func _active_for(page: String) -> int:
	match page:
		PAGE_CAMPAIGN, PAGE_DETAIL:
			return 0
		PAGE_COOP_START, PAGE_COOP_ROOM, PAGE_COOP_READY:
			return 1
		_:
			return -1


func _apply_dims(page: String) -> void:
	if _main != null:
		# ★ 备战页的主菜单虽然左移/上滑了，但它露出来的那条动作条必须是**亮**的：
		#   既不加灰层，也不许清掉「备战」的常驻金（见 main_menu_panel.set_prepare_latched）。
		_main.set_sidebar_dimmed(page != PAGE_MAIN and page != PAGE_PREPARE, false)
	if _campaign != null:
		_campaign.set_sidebar_dimmed(page == PAGE_DETAIL, false)
	if _coop_start != null:
		_coop_start.set_sidebar_dimmed(page == PAGE_COOP_ROOM or page == PAGE_COOP_READY, false)
	if _detail != null:
		_detail.set_sidebar_dimmed(false, false)
	if _coop_room != null:
		_coop_room.set_sidebar_dimmed(false, false)
	if _coop_ready != null:
		_coop_ready.set_sidebar_dimmed(false, false)


# ------------------------------------------------------------------
# 泛光：跟着「聚焦页」渐显 / 渐隐
# ------------------------------------------------------------------

## 转场一开始就调用：聚焦的那一页泛光渐显，其余页（侧栏、正要滑走的页）渐隐。
##
## ★ `moves` 里 fade=true 的那一页是整块面板自己在渐显（0→1），它的泛光直接
##   给满即可 —— 再单独补一次 0→1 会叠成两段渐显，看着比别的角慢半拍。
func _sync_glows(page: String, animate: bool, moves: Array = []) -> void:
	var focus: Control = _focused_panel_for(page)
	for p in _all_panels():
		if p == null:
			continue
		var whole_fade := false
		for m in moves:
			if m["panel"] == p and bool(m["fade"]):
				whole_fade = true
		if p == focus:
			p.set_glows(true, animate and not whole_fade)
		else:
			p.set_glows(false, animate)


## 这一页是「前景页」：其余可见面板都退成侧栏。
func _focused_panel_for(page: String) -> Control:
	match page:
		PAGE_PREPARE:
			return _prepare
		PAGE_CAMPAIGN:
			return _campaign
		PAGE_DETAIL:
			return _detail
		PAGE_COOP_START:
			return _coop_start
		PAGE_COOP_ROOM:
			return _coop_room
		PAGE_COOP_READY:
			return _coop_ready
		_:
			return _main


func _all_panels() -> Array:
	return [_main, _prepare, _campaign, _detail, _coop_start, _coop_room, _coop_ready]


func _on_resized() -> void:
	_layout_ai_test_btn()
	_layout_see_ai_btn()
	_layout_ce_xs_1_btn()
	_layout_ce_xs_2_btn()
	if _busy:
		return
	_apply_layout(_page, true)
	if _map_open:
		_map_picker.position.x = size.x - LayoutRes.side_w(size.x)


func _layout_ai_test_btn() -> void:
	if _ai_test_btn == null:
		return
	var r := LayoutRes.screen_test_button(size.x, size.y)
	_ai_test_btn.position = r.position
	_ai_test_btn.size = r.size


func _layout_see_ai_btn() -> void:
	if _see_ai_btn == null:
		return
	var r := LayoutRes.screen_see_ai_button(size.x, size.y)
	_see_ai_btn.position = r.position
	_see_ai_btn.size = r.size


func _layout_ce_xs_1_btn() -> void:
	if _ce_xs_1_btn == null:
		return
	var r := LayoutRes.screen_ce_xs_1_button(size.x, size.y)
	_ce_xs_1_btn.position = r.position
	_ce_xs_1_btn.size = r.size


func _layout_ce_xs_2_btn() -> void:
	if _ce_xs_2_btn == null:
		return
	var r := LayoutRes.screen_ce_xs_2_button(size.x, size.y)
	_ce_xs_2_btn.position = r.position
	_ce_xs_2_btn.size = r.size


## 测试入口只在主菜单页出现；开场转场期间也隐藏，避免干扰正常 UI。
func _refresh_ai_test_btn(page: String) -> void:
	if _ai_test_btn == null:
		return
	_ai_test_btn.visible = (page == PAGE_MAIN) and not _intro_pending


func _refresh_see_ai_btn(page: String) -> void:
	if _see_ai_btn == null:
		return
	_see_ai_btn.visible = (page == PAGE_MAIN) and not _intro_pending


func _refresh_ce_xs_1_btn(page: String) -> void:
	if _ce_xs_1_btn == null:
		return
	_ce_xs_1_btn.visible = (page == PAGE_MAIN) and not _intro_pending


func _refresh_ce_xs_2_btn(page: String) -> void:
	if _ce_xs_2_btn == null:
		return
	_ce_xs_2_btn.visible = (page == PAGE_MAIN) and not _intro_pending


func _unhandled_input(event: InputEvent) -> void:
	if not visible or _input_blocked:
		return
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and k.keycode == KEY_ESCAPE:
			if back():
				get_viewport().set_input_as_handled()
