## campaign_menu.gd —— ★ 战役菜单（样式移植自 nsoc 的 `scenes/CampaignPanel.tscn` +
## `scripts/ui/campaign_panel.gd`）
##
## 版式（与 nsoc 一致）：
##   · 左侧 1/4 全高：**战役竖向轮播**（`view/campaign_carousel.gd`）；
##   · 顶部一条**关卡圆点**（当前关 = 亮金、其余 = 暗金）；
##   · 右侧大面板：当前关卡的**标题 + 简介**；左右拖动切关卡；
##   · 描述面板底部一行「————长按进入关卡————」，**长按 3 秒**出现环形进度，
##     走满才进入 —— 防误触，也把「进入」这个动作与「翻看」分开。
##
## ★★ 与 nsoc 的三处刻意差异（都是本作的既有口径，不是没搬全）：
##   1. **配色**：nsoc 是白卡片 + 蓝点；这里全部走 `view/theme.gd` + `view/menu_theme.gd`
##      的暗金线框（不然会在暗金主界面里裂出一块白斑）；
##   2. **没有自己的「返回」**：本控件住在 `view/menu_secondary_panel.gd` 的内容区里，
##      那颗「返回」由面板统一提供（点击 → 面板反向转场 → 主界面）；
##   3. **不进场景，发信号**：nsoc 长按后 `change_scene_to_file`；本作由
##      `chapter_activated(campaign_id, level_id)` 往上传，谁建世界仍然只有 `view/main.gd` 知道。
##
## ★ 占位关卡（`campaign_id` / `level_id` 留空）：长按**什么都不发生**（不弹错、不发信号）。
##   这是需求原话「占位战役触发进入逻辑后没有任何逻辑」—— 以后接真关卡只改数据。
##
## ⚠️ 跨文件引用只用**本文件里的 preload 常量**（`--script` 下全局 class_name 不可用）。
extends Control

## 长按满了、且这一关真的指向一份战役关卡。
## ★ 参数是**数据**（战役 id + 关卡 id），本控件不认识 world / game_scene。
signal chapter_activated(campaign_id: String, level_id: String)

const ConfigRes = preload("res://logic/config.gd")
const CampaignMenuDbRes = preload("res://logic/campaign_menu_db.gd")
const ThemeRes = preload("res://view/theme.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const CarouselRes = preload("res://view/campaign_carousel.gd")

## 版式常量（与 nsoc 的 CampaignPanel.tscn 同一套数字；★ 单位是像素 / 屏幕比例）
const LEFT_RATIO: float = 0.25
const CAROUSEL_INSET: float = 8.0
const CAROUSEL_RIGHT_INSET: float = 6.0
const CHAPTER_TOP: float = 20.0
const CHAPTER_HEIGHT: float = 80.0
## 右上角要留给面板的「返回」按钮（160 宽 + 24 边距 + 16 呼吸）。
const CHAPTER_RIGHT_RESERVE: float = 200.0
const DESC_TOP: float = 120.0
const DESC_RIGHT_INSET: float = 20.0
const DESC_BOTTOM_INSET: float = 20.0

const CHAPTER_DOT_SIZE: float = 16.0
const CHAPTER_DOT_GAP: int = 12
const CHAPTER_PAD_X: float = 16.0
const CHAPTER_PAD_Y: float = 12.0

const DESC_PAD: float = 32.0
const DESC_TITLE_HEIGHT: float = 72.0
const DESC_FOOTER_HEIGHT: float = 40.0
const DESC_FOOTER_BOTTOM_PAD: float = 16.0

const TITLE_FONT_SIZE: int = 34
const BODY_FONT_SIZE: int = 20
const FOOTER_FONT_SIZE: int = 18

const PLACEHOLDER_DESC: String = "暂无描述"

## 长按：前 `REVEAL` 秒是「决策窗口」（不显环、允许拖动取消），之后才显环并锁死意图。
const LONG_PRESS_SEC: float = 3.0
const LONG_PRESS_REVEAL_SEC: float = 1.0
const LONG_PRESS_FADE_SEC: float = 0.18
const RING_RADIUS: float = 56.0
const RING_THICKNESS: float = 8.0
const RING_SEGMENTS: int = 64

## 拖动切关卡的动画（与 nsoc 同一条：移出 + 渐隐 → 换字 + 从对侧移回 + 渐显）。
const SWIPE_THRESHOLD_PX: float = 80.0
const DESC_ANIM_OFFSET_PX: float = 60.0
const DESC_ANIM_SEC: float = 0.18
const CHAPTER_FADE_IN_SEC: float = 0.18


## 自绘环形进度条（progress ∈ [0, 1]，12 点起顺时针）。
class LongPressRing extends Control:
	var progress: float = 0.0:
		set(value):
			progress = clampf(value, 0.0, 1.0)
			queue_redraw()
	var radius: float = 56.0
	var thickness: float = 8.0
	var bg_color: Color = Color(0.0, 0.0, 0.0, 0.25)
	var fg_color: Color = Color(0.847, 0.698, 0.373, 1.0)
	var segments: int = 64

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2.ZERO

	func _draw() -> void:
		var bg_pts := PackedVector2Array()
		for i in segments + 1:
			var a: float = TAU * float(i) / float(segments) - PI * 0.5
			bg_pts.append(Vector2(cos(a), sin(a)) * radius)
		draw_polyline(bg_pts, bg_color, thickness, true)
		if progress <= 0.0:
			return
		var fg_segs: int = max(2, int(ceil(float(segments) * progress)))
		var fg_pts := PackedVector2Array()
		for i in fg_segs + 1:
			var t: float = minf(float(i) / float(segments), progress)
			var a: float = TAU * t - PI * 0.5
			fg_pts.append(Vector2(cos(a), sin(a)) * radius)
		draw_polyline(fg_pts, fg_color, thickness, true)


var cfg: ConfigRes = null
var _font: Font = null
var _campaigns: Array = []

var _campaign_pnl: Panel = null
var _chapter_pnl: Panel = null
var _desc_pnl: Panel = null
var _carousel = null

var _chapter_box: HBoxContainer = null
var _desc_group: Control = null
var _desc_title: Label = null
var _desc_body: Label = null

var _chapters: Array = []
var _chapter_index: int = 0

var _desc_pressing: bool = false
var _desc_press_x: float = 0.0
var _desc_press_y: float = 0.0
var _desc_swiped: bool = false
var _desc_tween: Tween = null

var _long_press_active: bool = false
var _long_press_elapsed: float = 0.0
var _long_press_pos: Vector2 = Vector2.ZERO
var _long_press_ring: LongPressRing = null

var _name_size: int = 30
var _desc_size: int = 17
var _title_size: int = TITLE_FONT_SIZE
var _body_size: int = BODY_FONT_SIZE
var _footer_size: int = FOOTER_FONT_SIZE
var _dot_size: float = CHAPTER_DOT_SIZE
var _long_press_sec: float = LONG_PRESS_SEC
var _long_press_reveal: float = LONG_PRESS_REVEAL_SEC
var _footer_text: String = "————长按进入关卡————"


## @param campaigns `logic/campaign_menu_db.gd` 的结果
## @param p_cfg     全局配置（文案与字号都在 `menu.campaign_menu.*`）
## @param p_font    中文字体
func setup(p_cfg: ConfigRes, p_font: Font, campaigns: Array) -> void:
	cfg = p_cfg
	_font = p_font
	_campaigns = campaigns
	name = "CampaignMenu"
	# ★ 根节点**不吃鼠标**：它铺满整块撑开面板，而「返回」是面板的兄弟节点、在本控件**下面**。
	#   根若 STOP，点「返回」会先被这里吃掉（见 view/menu_secondary_panel.gd 的挂载顺序）。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_read_config()
	_build_panels()
	_build_carousel()
	_build_chapter_box()
	_build_desc_box()
	_refresh_chapters()


func _read_config() -> void:
	if cfg == null:
		return
	_name_size = cfg.int_val("menu.campaign_menu.name_size", 30)
	_desc_size = cfg.int_val("menu.campaign_menu.card_desc_size", 17)
	_title_size = cfg.int_val("menu.campaign_menu.title_size", TITLE_FONT_SIZE)
	_body_size = cfg.int_val("menu.campaign_menu.body_size", BODY_FONT_SIZE)
	_footer_size = cfg.int_val("menu.campaign_menu.footer_size", FOOTER_FONT_SIZE)
	_dot_size = cfg.num("menu.campaign_menu.dot_size", CHAPTER_DOT_SIZE)
	_long_press_sec = cfg.num("menu.campaign_menu.long_press_sec", LONG_PRESS_SEC)
	_long_press_reveal = cfg.num("menu.campaign_menu.long_press_reveal_sec",
		LONG_PRESS_REVEAL_SEC)
	_footer_text = cfg.str_val("menu.campaign_menu.footer", "————长按进入关卡————")


# ------------------------------------------------------------------
# 对外状态（给测试与排查）
# ------------------------------------------------------------------

func carousel():
	return _carousel


func campaign_count() -> int:
	return _campaigns.size()


func current_campaign() -> Dictionary:
	if _campaigns.is_empty():
		return {}
	return _campaigns[posmod(current_campaign_index(), _campaigns.size())]


func current_campaign_index() -> int:
	return _carousel.current_index() if _carousel != null else 0


func current_campaign_name() -> String:
	return String(current_campaign().get("name", ""))


func chapter_count() -> int:
	return _chapters.size()


func current_chapter_index() -> int:
	return _chapter_index


func chapter_name(index: int) -> String:
	if index < 0 or index >= _chapters.size():
		return ""
	return String((_chapters[index] as Dictionary).get("name", ""))


func current_chapter_name() -> String:
	return chapter_name(_chapter_index)


func current_chapter() -> Dictionary:
	if _chapter_index < 0 or _chapter_index >= _chapters.size():
		return {}
	return _chapters[_chapter_index]


## 当前这一关是不是占位（没有指向任何真实关卡）。
func is_current_placeholder() -> bool:
	if _chapters.is_empty():
		return true
	return CampaignMenuDbRes.is_placeholder_chapter(_chapters[_chapter_index])


func chapter_dot_count() -> int:
	return _chapter_box.get_child_count() if _chapter_box != null else 0


func desc_title_text() -> String:
	return _desc_title.text if _desc_title != null else ""


func desc_body_text() -> String:
	return _desc_body.text if _desc_body != null else ""


func footer_text() -> String:
	return _footer_text


func long_press_duration() -> float:
	return _long_press_sec


## 直接选中第 index 关（不播切换动画；越界忽略）。
func select_chapter(index: int) -> void:
	if index < 0 or index >= _chapters.size():
		return
	_chapter_index = index
	_refresh_desc_text()
	_refresh_dots_active()


## 触发第 index 关的「进入」（等价于长按走满）。
##
## @return true = 真的发出去了（这一关指向一份战役关卡）；false = 占位 / 越界（什么都不发生）
func activate_chapter(index: int = -1) -> bool:
	if index >= 0:
		if index >= _chapters.size():
			return false
		select_chapter(index)
	if _chapters.is_empty():
		return false
	var ch: Dictionary = _chapters[_chapter_index]
	if CampaignMenuDbRes.is_placeholder_chapter(ch):
		return false
	chapter_activated.emit(String(ch.get("campaign_id", "")), String(ch.get("level_id", "")))
	return true


# ------------------------------------------------------------------
# 搭界面
# ------------------------------------------------------------------

func _build_panels() -> void:
	# 左侧那块只是轮播的**裁剪容器**，自己不要底（卡片自带金线底）；
	# 否则会在卡片外面多出一圈面板线。
	_campaign_pnl = Panel.new()
	_campaign_pnl.name = "CampaignPnl"
	_campaign_pnl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_campaign_pnl.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_campaign_pnl.anchor_right = LEFT_RATIO
	_campaign_pnl.anchor_bottom = 1.0
	_campaign_pnl.offset_left = CAROUSEL_INSET
	_campaign_pnl.offset_top = CAROUSEL_INSET
	_campaign_pnl.offset_right = -CAROUSEL_RIGHT_INSET
	_campaign_pnl.offset_bottom = -CAROUSEL_INSET
	add_child(_campaign_pnl)

	_chapter_pnl = Panel.new()
	_chapter_pnl.name = "ChapterPnl"
	_chapter_pnl.mouse_filter = Control.MOUSE_FILTER_STOP
	_chapter_pnl.add_theme_stylebox_override("panel", MenuThemeRes.campaign_panel())
	_chapter_pnl.anchor_left = LEFT_RATIO
	_chapter_pnl.anchor_right = 1.0
	_chapter_pnl.offset_left = 6.0
	_chapter_pnl.offset_top = CHAPTER_TOP
	_chapter_pnl.offset_right = -CHAPTER_RIGHT_RESERVE
	_chapter_pnl.offset_bottom = CHAPTER_TOP + CHAPTER_HEIGHT
	add_child(_chapter_pnl)

	_desc_pnl = Panel.new()
	_desc_pnl.name = "DescPnl"
	_desc_pnl.mouse_filter = Control.MOUSE_FILTER_STOP
	_desc_pnl.add_theme_stylebox_override("panel", MenuThemeRes.campaign_panel())
	_desc_pnl.anchor_left = LEFT_RATIO
	_desc_pnl.anchor_right = 1.0
	_desc_pnl.anchor_bottom = 1.0
	_desc_pnl.offset_left = 6.0
	_desc_pnl.offset_top = DESC_TOP
	_desc_pnl.offset_right = -DESC_RIGHT_INSET
	_desc_pnl.offset_bottom = -DESC_BOTTOM_INSET
	add_child(_desc_pnl)


func _build_carousel() -> void:
	_carousel = CarouselRes.new()
	_campaign_pnl.add_child(_carousel)
	_carousel.setup(_campaigns, _font, _name_size, _desc_size)
	_carousel.current_campaign_changed.connect(_on_campaign_changed)
	_carousel.drag_progress.connect(_on_drag_progress)


func _build_chapter_box() -> void:
	for c in _chapter_pnl.get_children():
		c.queue_free()
	var box := HBoxContainer.new()
	box.name = "ChapterBox"
	box.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	box.offset_left = CHAPTER_PAD_X
	box.offset_right = -CHAPTER_PAD_X
	box.offset_top = CHAPTER_PAD_Y
	box.offset_bottom = -CHAPTER_PAD_Y
	box.add_theme_constant_override("separation", CHAPTER_DOT_GAP)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	_chapter_pnl.add_child(box)
	_chapter_box = box


func _build_desc_box() -> void:
	for c in _desc_pnl.get_children():
		c.queue_free()
	if not _desc_pnl.gui_input.is_connected(_on_desc_gui_input):
		_desc_pnl.gui_input.connect(_on_desc_gui_input)

	# ★ clip 放在内层 group：直接设在 DescPnl 上会把它自己 stylebox 的金线边框一起裁掉。
	var group := Control.new()
	group.name = "DescGroup"
	group.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	group.clip_contents = true
	_desc_pnl.add_child(group)
	_desc_group = group

	var title := Label.new()
	title.name = "DescTitle"
	title.set_anchors_preset(Control.PRESET_TOP_WIDE, false)
	title.offset_left = DESC_PAD
	title.offset_right = -DESC_PAD
	title.offset_top = DESC_PAD
	title.offset_bottom = DESC_PAD + DESC_TITLE_HEIGHT
	title.add_theme_color_override("font_color", ThemeRes.text())
	title.add_theme_font_size_override("font_size", _title_size)
	if _font != null:
		title.add_theme_font_override("font", _font)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	group.add_child(title)
	_desc_title = title

	var body := Label.new()
	body.name = "DescBody"
	body.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	body.offset_left = DESC_PAD
	body.offset_right = -DESC_PAD
	body.offset_top = DESC_PAD * 2.0 + DESC_TITLE_HEIGHT
	body.offset_bottom = -(DESC_PAD + DESC_FOOTER_HEIGHT + DESC_FOOTER_BOTTOM_PAD)
	body.add_theme_color_override("font_color", ThemeRes.text_dim())
	body.add_theme_font_size_override("font_size", _body_size)
	if _font != null:
		body.add_theme_font_override("font", _font)
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	body.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.clip_text = true
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	group.add_child(body)
	_desc_body = body

	# 底部提示不进 _desc_group：切关卡时只平移正文，提示保持静止。
	var footer := Label.new()
	footer.name = "DescFooter"
	footer.text = _footer_text
	footer.set_anchors_preset(Control.PRESET_BOTTOM_WIDE, false)
	footer.offset_left = DESC_PAD
	footer.offset_right = -DESC_PAD
	footer.offset_top = -(DESC_FOOTER_HEIGHT + DESC_FOOTER_BOTTOM_PAD)
	footer.offset_bottom = -DESC_FOOTER_BOTTOM_PAD
	footer.add_theme_color_override("font_color", ThemeRes.text_faint())
	footer.add_theme_font_size_override("font_size", _footer_size)
	if _font != null:
		footer.add_theme_font_override("font", _font)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_desc_pnl.add_child(footer)


# ------------------------------------------------------------------
# 刷新（战役 / 关卡）
# ------------------------------------------------------------------

## 当前战役换了：重建关卡圆点 + 把选中的关卡复位到第 0 关。
func _on_campaign_changed(_index: int) -> void:
	_refresh_chapters()
	if _chapter_box == null:
		return
	_chapter_box.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_chapter_box, "modulate:a", 1.0, CHAPTER_FADE_IN_SEC) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _refresh_chapters() -> void:
	_chapters.clear()
	_chapter_index = 0
	var camp: Dictionary = current_campaign()
	var raw: Variant = camp.get("chapters", [])
	if typeof(raw) == TYPE_ARRAY:
		for ch in (raw as Array):
			if typeof(ch) == TYPE_DICTIONARY:
				_chapters.append(ch)
	if _chapter_box != null:
		for c in _chapter_box.get_children():
			c.queue_free()
			_chapter_box.remove_child(c)
		for i in _chapters.size():
			_chapter_box.add_child(_make_chapter_dot(i == _chapter_index))
	if _desc_tween != null and _desc_tween.is_valid():
		_desc_tween.kill()
	if _desc_group != null:
		_desc_group.position.x = 0.0
		_desc_group.modulate.a = 1.0
	_refresh_desc_text()


func _refresh_desc_text() -> void:
	if _desc_title == null or _desc_body == null:
		return
	if _chapters.is_empty():
		_desc_title.text = ""
		_desc_body.text = ""
		return
	var ch: Dictionary = _chapters[clampi(_chapter_index, 0, _chapters.size() - 1)]
	_desc_title.text = String(ch.get("name", ""))
	var body := String(ch.get("description", ""))
	_desc_body.text = body if body.strip_edges() != "" else PLACEHOLDER_DESC


func _make_chapter_dot(active: bool) -> Control:
	var wrapper := Control.new()
	wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var dot := Panel.new()
	dot.name = "Dot"
	dot.custom_minimum_size = Vector2(_dot_size, _dot_size)
	dot.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.add_theme_stylebox_override("panel", MenuThemeRes.campaign_dot(active))
	wrapper.add_child(dot)
	return wrapper


## 拖动中的圆点渐隐：|progress| = 0 全显、≥ 1 全隐。
func _on_drag_progress(progress: float) -> void:
	if _chapter_box == null:
		return
	_chapter_box.modulate.a = clampf(1.0 - absf(progress), 0.0, 1.0)


func _refresh_dots_active() -> void:
	if _chapter_box == null:
		return
	var children := _chapter_box.get_children()
	for i in children.size():
		var wrapper := children[i] as Control
		if wrapper == null:
			continue
		var dot := wrapper.get_node_or_null("Dot") as Panel
		if dot == null:
			continue
		dot.add_theme_stylebox_override("panel",
			MenuThemeRes.campaign_dot(i == _chapter_index))


# ------------------------------------------------------------------
# 拖动切关卡 + 长按进入
# ------------------------------------------------------------------

func _on_desc_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_desc_pressing = true
			_desc_swiped = false
			_desc_press_x = event.global_position.x
			_desc_press_y = event.global_position.y
			_start_long_press(event.position)
		else:
			_desc_pressing = false
			_desc_swiped = false
			_cancel_long_press()
	elif event is InputEventMouseMotion and _desc_pressing:
		# 环已现身 = 已锁定长按意图，不再响应拖动。
		if _long_press_ring != null:
			return
		var dx: float = event.global_position.x - _desc_press_x
		var dy: float = event.global_position.y - _desc_press_y
		if absf(dx) >= SWIPE_THRESHOLD_PX * 0.5 or absf(dy) >= SWIPE_THRESHOLD_PX * 0.5:
			_cancel_long_press()
		if _desc_swiped:
			return
		if dx <= -SWIPE_THRESHOLD_PX:
			_swipe_chapter(+1)
			_desc_swiped = true
		elif dx >= SWIPE_THRESHOLD_PX:
			_swipe_chapter(-1)
			_desc_swiped = true


func _start_long_press(local_pos: Vector2) -> void:
	_cancel_long_press()
	_long_press_active = true
	_long_press_elapsed = 0.0
	_long_press_pos = local_pos


func _cancel_long_press() -> void:
	_long_press_active = false
	_long_press_elapsed = 0.0
	if _long_press_ring != null and is_instance_valid(_long_press_ring):
		_long_press_ring.queue_free()
	_long_press_ring = null


func _process(delta: float) -> void:
	if not _long_press_active:
		return
	_long_press_elapsed += delta

	if _long_press_ring == null and _long_press_elapsed >= _long_press_reveal:
		var ring := LongPressRing.new()
		ring.radius = RING_RADIUS
		ring.thickness = RING_THICKNESS
		ring.bg_color = ThemeRes.with_alpha(ThemeRes.bg_bottom(), 0.45)
		ring.fg_color = ThemeRes.accent()
		ring.segments = RING_SEGMENTS
		ring.position = _long_press_pos
		ring.modulate.a = 0.0
		_desc_pnl.add_child(ring)
		_long_press_ring = ring
		var tw := create_tween()
		tw.tween_property(ring, "modulate:a", 1.0, LONG_PRESS_FADE_SEC) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	if _long_press_ring != null and is_instance_valid(_long_press_ring):
		var denom: float = maxf(0.001, _long_press_sec)
		_long_press_ring.progress = clampf(_long_press_elapsed / denom, 0.0, 1.0)

	if _long_press_elapsed >= _long_press_sec:
		var idx := _chapter_index
		_cancel_long_press()
		# ★ 占位关也走这里：activate_chapter() 自己判「有没有真关卡」，没有就什么都不做。
		activate_chapter(idx)


## delta = +1 看下一关；-1 看上一关（clamp 边界，不循环）。
func _swipe_chapter(delta: int) -> void:
	if _chapters.is_empty():
		return
	var next_idx := _chapter_index + delta
	if next_idx < 0 or next_idx >= _chapters.size():
		return
	_chapter_index = next_idx
	_animate_desc_change(delta)
	_refresh_dots_active()


func _animate_desc_change(direction: int) -> void:
	if _desc_group == null:
		_refresh_desc_text()
		return
	if _desc_tween != null and _desc_tween.is_valid():
		_desc_tween.kill()

	var out_x: float = -DESC_ANIM_OFFSET_PX * float(direction)
	var in_x: float = DESC_ANIM_OFFSET_PX * float(direction)
	var half: float = DESC_ANIM_SEC * 0.5

	_desc_group.position.x = 0.0
	_desc_group.modulate.a = 1.0

	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_desc_group, "position:x", out_x, half) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.tween_property(_desc_group, "modulate:a", 0.0, half).set_trans(Tween.TRANS_LINEAR)
	_desc_tween = tw
	await tw.finished
	if _desc_tween != tw:
		return

	_refresh_desc_text()
	_desc_group.position.x = in_x
	var tw2 := create_tween()
	tw2.set_parallel(true)
	tw2.tween_property(_desc_group, "position:x", 0.0, half) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw2.tween_property(_desc_group, "modulate:a", 1.0, half).set_trans(Tween.TRANS_LINEAR)
	_desc_tween = tw2
