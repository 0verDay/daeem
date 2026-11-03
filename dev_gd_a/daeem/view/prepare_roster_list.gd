## prepare_roster_list.gd —— 备战页右面板里的「将领 / 单位 / 科技」弹性磁贴列表。
##
## 直接继承 `view/elastic_scroll_list.gd`：面板里那块就是一个可上下拖、拉过头会回弹的
## 长列表（`_input` 走全局，磁贴是 Button 也不会吞掉拖拽；拖动确认后会挂一层遮罩，
## 防止松手顺手点掉一个磁贴）。
##
## 版式（用户口径）：
##   · 每个分节 = 金色标题 + **一排三个的长方形磁贴**（约 146×110，随面板宽度均分）；
##   · 磁贴内「图标在上、名字一行在下」；
##   · 单位 / 科技用现成的金线蒙版（`unit_card_icon.gd` 的 mask_for_unit / mask_for_combo /
##     mask_for_tech）；将领没有图标，用**将领编号**当占位图标（用户指定）。
##
## 内容按当前派系重建（王朝 / 帝国）：
##   · 将领 —— 全局 9 名可招募将领（将领 1..9）+ 开局将领 0，共 10 个；
##     ★ 配置里将领不分派系（`docs/route.md` 77.x 也写着），所以两派看到的是同一份。
##   · 单位 —— `cfg.clan_recruit_list(派系)`；组合条目优先 `combo_<kind>`，没有就取
##     第一个生成兵种的蒙版。
##   · 科技 —— `cfg.tech_list_for(派系)` 里**非空槽**，按阶 1→2→3 排列。
##
## 磁贴可点：悬停金色自下而上填、按下回弹、点击音；**不保持选中、不接任何跳转**。
extends "res://view/elastic_scroll_list.gd"

const MenuThemeRes = preload("res://view/menu_theme.gd")
const FillButtonRes = preload("res://view/fill_button.gd")
const PressFxRes = preload("res://view/press_fx.gd")
const IconRes = preload("res://view/unit_card_icon.gd")

## 三个分节的标题（用户指定的字面文案；config 可覆盖）。
const DEFAULT_SECTIONS := ["将领——", "单位——", "科技——"]

## 磁贴版式（尺寸只服务于本面板，不进 config）。
const COLUMNS := 3
const TILE_H := 110.0
const TILE_GAP := 8
const NAME_BAR_H := 24.0
const TILE_FONT := 16
const NUMBER_FONT := 44
const PLACEHOLDER_FONT := 34

## 分节排版。
const HEADER_H := 36.0
const SECTION_GAP := 18.0
const HEADER_FONT := 26
const ITEM_GAP := 6

## 当前派系（"" = 还没建）。
var _faction_id: String = ""
var cfg = null
var font: Font = null

var _headers: Array = []
var _generals: Array = []
var _units: Array = []
var _techs: Array = []
## 三节所有磁贴的扁平列表（`_process` 淡名字底条 / 拖动清按下态用）。
var _all_tiles: Array = []


func setup(p_cfg, p_font: Font) -> void:
	cfg = p_cfg
	font = p_font
	set_item_separation(ITEM_GAP)
	set_allow_empty_drag(false)
	drag_started.connect(_on_drag_started)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	# 名字底条跟着金色填充淡出：填充从下往上，底条在最下面，金色盖上来之后
	# 字会翻成压金暗色，深底 + 深字会读不出来（与 tech_grid 同一条口径）。
	for b in _all_tiles:
		if b == null or not is_instance_valid(b) or not b.has_meta("name_bar"):
			continue
		var bar: ColorRect = b.get_meta("name_bar")
		if bar == null or not is_instance_valid(bar):
			continue
		var p: float = clampf(FillButtonRes.fill_progress(b), 0.0, 1.0)
		var c: Color = ThemeRes.with_alpha(ThemeRes.bg_bottom(), 0.78)
		bar.color = Color(c.r, c.g, c.b, c.a * (1.0 - p))


## 拖动一开始就清掉磁贴上被「按下→抬起被遮罩吃掉」留下的残留：
## 否则那枚磁贴会一直停在 pressed（实机上就是 2px 亮边 + 按下缩放不回来）。
func _on_drag_started() -> void:
	for b in _all_tiles:
		if b == null or not is_instance_valid(b):
			continue
		FillButtonRes.clear_hover_in(b)
		PressFxRes.cancel(b)
		if b.is_pressed():
			# BaseButton 没有「取消按住」的公开接口；同一帧内禁用再启用会把
			# status.pressed 清掉，而中间没有绘制帧，不会闪出禁用样式。
			b.disabled = true
			b.disabled = false


## 换派系 → 重建三节；同一个派系重复调用是空操作（避免每次重排都重建磁贴）。
func set_faction(faction_id: String, force: bool = false) -> void:
	if not force and faction_id == _faction_id and not _headers.is_empty():
		return
	_faction_id = faction_id
	_rebuild()


func faction_id() -> String:
	return _faction_id


# ------------------------------------------------------------------
# 重建
# ------------------------------------------------------------------

func _rebuild() -> void:
	var box := get_content_box()
	# 先摘再 free：queue_free 是延迟的，直接清空数组会留下“这一帧旧项还在”的重影。
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
	_headers.clear()
	_generals.clear()
	_units.clear()
	_techs.clear()
	_all_tiles.clear()

	var titles := _section_titles()
	_add_section(box, String(titles[0]), _general_entries(), "Gen", _generals)
	_add_section(box, String(titles[1]), _unit_entries(), "Unit", _units)
	# 最后一节也留一段底部空白：滚到底时最后一行不贴死面板下沿。
	_add_section(box, String(titles[2]), _tech_entries(), "Tech", _techs, true)

	# 换派系 / 首次建：回到顶部（内容高度由延迟重排更新，偏移先归零）。
	scroll_to(0.0)


## 一节 = 金色标题 + 三列磁贴网格；节与节之间留一段空白。
func _add_section(box: VBoxContainer, title: String, entries: Array,
		name_prefix: String, out_tiles: Array, tail_gap: bool = true) -> void:
	var section := VBoxContainer.new()
	section.name = "Section_%s" % name_prefix
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section.add_theme_constant_override("separation", ITEM_GAP)
	box.add_child(section)

	var header_wrap := MarginContainer.new()
	header_wrap.name = "HeaderWrap_%s" % name_prefix
	header_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_wrap.custom_minimum_size = Vector2(0.0, HEADER_H)
	header_wrap.add_theme_constant_override("margin_left", 4)
	header_wrap.add_theme_constant_override("margin_right", 12)
	section.add_child(header_wrap)

	var header := Label.new()
	header.name = "Header_%s" % name_prefix
	header.text = title
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.size_flags_vertical = Control.SIZE_EXPAND_FILL
	if font != null:
		header.add_theme_font_override("font", font)
	header.add_theme_font_size_override("font_size", HEADER_FONT)
	header.add_theme_color_override("font_color", ThemeRes.accent())
	header_wrap.add_child(header)
	_headers.append(header)

	var grid := GridContainer.new()
	grid.name = "Grid_%s" % name_prefix
	grid.columns = COLUMNS
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", TILE_GAP)
	grid.add_theme_constant_override("v_separation", TILE_GAP)
	section.add_child(grid)

	for i in entries.size():
		var e: Dictionary = entries[i]
		var label := String(e.get("label", "")).strip_edges()
		if label == "":
			continue
		var tile := _make_tile("%s_%d" % [name_prefix, i], label,
			String(e.get("mask", "")), String(e.get("number", "")))
		grid.add_child(tile)
		out_tiles.append(tile)
		_all_tiles.append(tile)

	if tail_gap:
		var spacer := Control.new()
		spacer.name = "Spacer_%s" % name_prefix
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		spacer.custom_minimum_size = Vector2(0.0, SECTION_GAP)
		box.add_child(spacer)


## 一枚长方形磁贴：图标区（金线蒙版 / 编号占位）+ 底部名字条。
func _make_tile(node_name: String, label: String, mask: String, number: String) -> Button:
	var b := Button.new()
	b.name = node_name
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.custom_minimum_size = Vector2(0.0, TILE_H)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.set_meta("label", label)
	b.set_meta("mask", mask)
	b.set_meta("number", number)

	# ★ 与其它菜单按钮同一条接法：填充层 + 字色翻面 + 点击音 + 按下回弹都在 attach_text 里。
	FillButtonRes.attach_text(b)
	FillButtonRes.set_base_font_color(b, MenuThemeRes.text_normal())
	FillButtonRes.set_panel_color(b, ThemeRes.bg_bottom())
	FillButtonRes.set_base_bg(b, ThemeRes.with_alpha(ThemeRes.bg_bottom(), 0.55))
	b.add_theme_stylebox_override("normal", MenuThemeRes.button_normal())
	b.add_theme_stylebox_override("hover", MenuThemeRes.button_hover_clear())
	b.add_theme_stylebox_override("pressed", MenuThemeRes.button_fill_latched())
	b.add_theme_stylebox_override("focus", MenuThemeRes.button_normal())
	b.add_theme_stylebox_override("disabled", MenuThemeRes.button_disabled())
	b.add_theme_color_override("font_disabled_color", MenuThemeRes.text_disabled())

	# ① 图标区：有蒙版就画金线图；没有（将领）就用编号文字占位。
	if mask != "":
		var icon := IconRes.IconView.new()
		icon.name = "Icon"
		b.add_child(icon)
		icon.set_mask(mask)
		icon.bind(b, Rect2(0.0, 0.0, 1.0, 1.0))
		b.set_meta("icon_view", icon)
	else:
		var num_text := number
		if num_text == "":
			num_text = label.substr(0, 1)
		var num := Label.new()
		num.name = "PlaceholderIcon"
		num.text = num_text
		num.mouse_filter = Control.MOUSE_FILTER_IGNORE
		num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		if font != null:
			num.add_theme_font_override("font", font)
		num.add_theme_font_size_override("font_size",
			NUMBER_FONT if number != "" else PLACEHOLDER_FONT)
		num.add_theme_color_override("font_color", ThemeRes.accent())
		b.add_child(num)
		FillButtonRes.on_fill_text(b, num, ThemeRes.accent())
		b.set_meta("number_label", num)

	# ② 底部名字条：略暗底 + 一行名字（长名字裁省略号）。
	var bar := ColorRect.new()
	bar.name = "NameBar"
	bar.color = ThemeRes.with_alpha(ThemeRes.bg_bottom(), 0.78)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(bar)

	var name_label := Label.new()
	name_label.name = "NameText"
	name_label.text = label
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if font != null:
		name_label.add_theme_font_override("font", font)
	name_label.add_theme_font_size_override("font_size", TILE_FONT)
	name_label.add_theme_color_override("font_color", MenuThemeRes.text_normal())
	b.add_child(name_label)
	FillButtonRes.on_fill_text(b, name_label, MenuThemeRes.text_normal())

	b.set_meta("name_bar", bar)
	b.set_meta("name_label", name_label)
	b.resized.connect(_layout_tile.bind(b))
	_layout_tile(b)
	return b


## 磁贴尺寸由 GridContainer 给出，这里把三块子控件贴到对应位置。
func _layout_tile(tile: Button) -> void:
	if tile == null or not is_instance_valid(tile):
		return
	var w: float = tile.size.x
	var h: float = tile.size.y
	if w <= 1.0 or h <= 1.0:
		return
	var icon_h: float = maxf(1.0, h - NAME_BAR_H)
	if tile.has_meta("icon_view"):
		var icon = tile.get_meta("icon_view")
		if icon != null and is_instance_valid(icon):
			icon.bind(tile, Rect2(0.0, 0.0, w, icon_h))
	if tile.has_meta("number_label"):
		var num: Label = tile.get_meta("number_label")
		if num != null and is_instance_valid(num):
			num.position = Vector2.ZERO
			num.size = Vector2(w, icon_h)
	if tile.has_meta("name_bar"):
		var bar: ColorRect = tile.get_meta("name_bar")
		if bar != null and is_instance_valid(bar):
			bar.position = Vector2(0.0, h - NAME_BAR_H)
			bar.size = Vector2(w, NAME_BAR_H)
	if tile.has_meta("name_label"):
		var nl: Label = tile.get_meta("name_label")
		if nl != null and is_instance_valid(nl):
			nl.position = Vector2(1.0, h - NAME_BAR_H)
			nl.size = Vector2(maxf(1.0, w - 2.0), NAME_BAR_H)


# ------------------------------------------------------------------
# 数据 → 磁贴条目（label / mask / number）
# ------------------------------------------------------------------

func _section_titles() -> Array:
	var out := DEFAULT_SECTIONS.duplicate()
	if cfg == null:
		return out
	var keys := ["section_generals", "section_units", "section_techs"]
	for i in keys.size():
		var v := String(cfg.str_val("menu.deck.prepare.%s" % keys[i], String(out[i]))).strip_edges()
		if v != "":
			out[i] = v
	return out


## 9 名可招募将领 + 开局将领 0。名字优先取区划招将表的 label（将领 1..9），
## 再取 `unit.general.stats[].name`，都没有才兜底「将领 N」；编号取 kind 的后缀。
func _general_entries() -> Array:
	var out: Array = []
	var has_zero := false
	if cfg != null:
		var zone: Variant = cfg.get_path_value("recruit.zone.list")
		if typeof(zone) == TYPE_ARRAY:
			for item in (zone as Array):
				if typeof(item) != TYPE_DICTIONARY:
					continue
				var d: Dictionary = item
				var kind := String(d.get("kind", ""))
				if not kind.begins_with("general_"):
					continue
				var num := kind.substr(8)
				var label := String(d.get("label", "")).strip_edges()
				if num == "0":
					has_zero = true
					continue
				if label != "":
					out.append({"label": label, "mask": "", "number": num})
	# 数据被裁掉 / 读坏时仍列出 9 位，别让分节空白。
	if out.is_empty():
		for i in 9:
			out.append({"label": _general_name(i, "将领 %d" % (i + 1)),
				"mask": "", "number": str(i + 1)})
	# 开局将领 #0 在 general 名册下标 9（不在区划招将表里）。
	if not has_zero or out.size() < 10:
		out.append({"label": _general_name(9, "将领 0"), "mask": "", "number": "0"})
	return out


func _general_name(index: int, fallback: String) -> String:
	if cfg == null:
		return fallback
	var nm := String(cfg.general_name_at(index)).strip_edges()
	return nm if nm != "" else fallback


func _unit_entries() -> Array:
	var out: Array = []
	if cfg == null:
		return out
	for item in cfg.clan_recruit_list(_faction_id):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		var label := String(d.get("label", "")).strip_edges()
		if label == "":
			continue
		var kind := String(d.get("kind", ""))
		var mask := IconRes.mask_for_combo(kind)
		if mask == "":
			var unit_type := kind
			var spawn: Variant = d.get("spawn", [])
			if typeof(spawn) == TYPE_ARRAY and not (spawn as Array).is_empty():
				var first: Variant = (spawn as Array)[0]
				if typeof(first) == TYPE_DICTIONARY:
					unit_type = String((first as Dictionary).get("type", kind))
			mask = IconRes.mask_for_unit(cfg, unit_type)
		out.append({"label": label, "mask": mask, "number": ""})
	return out


## 非空科技槽；按阶 1→2→3（同阶保持原槽位顺序）。
func _tech_entries() -> Array:
	var out: Array = []
	if cfg == null:
		return out
	var slots: Array = cfg.tech_list_for(_faction_id)
	var by_tier: Dictionary = {}
	for e in slots:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = e
		var id := String(d.get("id", ""))
		if id == "":
			continue
		var nm := String(d.get("name", "")).strip_edges()
		if nm == "":
			continue
		var tier := int(d.get("tier", 0))
		if not by_tier.has(tier):
			by_tier[tier] = []
		(by_tier[tier] as Array).append({
			"label": nm,
			"mask": IconRes.mask_for_tech(id),
			"number": "",
		})
	var tiers: Array = by_tier.keys()
	tiers.sort()
	for t in tiers:
		out.append_array(by_tier[t])
	return out


# ------------------------------------------------------------------
# 访问器（测试 / 截图用）
# ------------------------------------------------------------------

func section_headers() -> Array:
	return _headers


func general_buttons() -> Array:
	return _generals


func unit_buttons() -> Array:
	return _units


func tech_buttons() -> Array:
	return _techs


func item_buttons() -> Array:
	return _all_tiles


func tile_columns() -> int:
	return COLUMNS


func tile_height() -> float:
	return TILE_H


func tile_label(tile: Button) -> String:
	return String(tile.get_meta("label", "")) if tile != null else ""


func tile_icon_mask(tile: Button) -> String:
	return String(tile.get_meta("mask", "")) if tile != null else ""


func tile_placeholder(tile: Button) -> String:
	return String(tile.get_meta("number", "")) if tile != null else ""
