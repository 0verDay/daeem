## prepare_detail_view.gd —— 备战页左面板的详情卡。
##
## 右面板点开一枚磁贴后，由 prepare_panel 调 `show_item(kind, id)`：
##   · 将领：编号大字 / 阶 / 兵种 / 属性 / 造价 / 统兵 / 特性；
##   · 单位：金线蒙版 / 阶 / 兵种 / 说明 / 属性（组合单位显示编成）/ 造价 / 人口；
##   · 科技：金线蒙版 / 阶 / 说明 / 效果 / 金每秒。
##
## 没有选中时只显示一句「点击右侧…查看详情」的提示（用户口径：默认空白提示）。
## 详情内容走一个纵向 ScrollContainer：1080 下通常不用滚，窗口更矮时也不会被裁掉。
extends Control

const ThemeRes = preload("res://view/theme.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const IconRes = preload("res://view/unit_card_icon.gd")
const ConfigRes = preload("res://logic/config.gd")

const PAD := 30.0
const ICON_BOX := 186.0
const ICON_INNER := 164.0
const TITLE_FONT := 38
const SUBTITLE_FONT := 21
const SECTION_FONT := 18
const BODY_FONT := 20
const STAT_LABEL_FONT := 14
const STAT_VALUE_FONT := 24
const INFO_LABEL_FONT := 14
const INFO_VALUE_FONT := 20
const ROW_NAME_FONT := 20
const ROW_DETAIL_FONT := 17
## ★★ 2026.11：特性条目的**名字**用更大的字号 + 金色，详细信息用普通字（用户口径）。
const ENTRY_NAME_FONT := 26

var cfg = null
var font: Font = null
var _faction: String = ""

var _scroll: ScrollContainer = null
var _content: VBoxContainer = null
var _hint: Control = null
var _last: Dictionary = {}


func setup(p_cfg, p_font: Font) -> void:
	cfg = p_cfg
	font = p_font
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_scroll = ScrollContainer.new()
	_scroll.name = "DetailScroll"
	_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll.offset_left = PAD
	_scroll.offset_top = PAD
	_scroll.offset_right = -PAD
	_scroll.offset_bottom = -PAD
	add_child(_scroll)

	_content = VBoxContainer.new()
	_content.name = "DetailContent"
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 14)
	_scroll.add_child(_content)

	_hint = _make_hint()
	add_child(_hint)
	clear()


func set_faction(faction_id: String) -> void:
	_faction = faction_id


func clear() -> void:
	_last = {}
	_clear_content()
	_scroll.visible = false
	_hint.visible = true


func has_detail() -> bool:
	return not _last.is_empty()


func last_item() -> Dictionary:
	return _last


func hint_visible() -> bool:
	return _hint.visible if _hint != null else false


func title_text() -> String:
	return String(_last.get("title", ""))


func subtitle_text() -> String:
	return String(_last.get("subtitle", ""))


## 打开一项；数据缺失时退回提示态。
func show_item(kind: String, id: String) -> void:
	var data := _build(kind, id)
	if data.is_empty():
		clear()
		return
	_last = data
	_rebuild(data)
	_scroll.visible = true
	_hint.visible = false
	_scroll.scroll_vertical = 0


# ------------------------------------------------------------------
# 构建数据
# ------------------------------------------------------------------

func _build(kind: String, id: String) -> Dictionary:
	match kind:
		"general":
			return _build_general(id)
		"unit":
			return _build_unit(id)
		"tech":
			return _build_tech(id)
	return {}


func _build_unit(id: String) -> Dictionary:
	var entry := _find_recruit(id)
	if entry.is_empty():
		return {}
	var label := String(entry.get("label", "")).strip_edges()
	var tier := int(entry.get("tier", 1))
	var spawn: Variant = entry.get("spawn", [])
	var is_combo := typeof(spawn) == TYPE_ARRAY and not (spawn as Array).is_empty()
	var unit_type := _primary_type(entry)
	var subtitle := "%s · %s" % [_tier_name(tier),
		"组合单位" if is_combo else (cfg.unit_class_name(unit_type) if cfg != null else "")]
	var sections: Array = []
	sections.append({"title": "说明", "text": _clean_desc(String(entry.get("desc", "")))})

	if is_combo:
		var rows: Array = []
		for s in (spawn as Array):
			if typeof(s) != TYPE_DICTIONARY:
				continue
			var t := String((s as Dictionary).get("type", ""))
			if t == "":
				continue
			rows.append({
				"name": "%s（%s）" % [cfg.unit_name_of(t), _unit_role(t)],
				"detail": _unit_stat_line(t),
			})
		sections.append({"title": "编成", "rows": rows})
	else:
		sections.append({"title": "属性", "grid": _unit_stats(unit_type)})

	var cost: Variant = entry.get("cost", {})
	var info: Array = [
		["粮", _fmt((cost as Dictionary).get("food", 0.0)) if typeof(cost) == TYPE_DICTIONARY else "0"],
		["金", _fmt((cost as Dictionary).get("gold", 0.0)) if typeof(cost) == TYPE_DICTIONARY else "0"],
		["人口", str(int(entry.get("population_cost", 0)))],
		["读条", "%s 秒" % _fmt(cfg.num("recruit.batch_sec", 10.0))],
	]
	sections.append({"title": "造价 / 招募", "grid": info, "columns": 4})

	var mask := IconRes.mask_for_combo(id)
	if mask == "":
		mask = IconRes.mask_for_unit(cfg, unit_type)
	return {
		"kind": "unit", "id": id, "title": label, "subtitle": subtitle,
		"icon_mask": mask, "icon_text": "", "tier": tier, "sections": sections,
	}


func _build_general(id: String) -> Dictionary:
	var idx := ConfigRes.general_index_of(id)
	if idx < 0:
		return {}
	var is_start: bool = idx == ConfigRes.GENERAL_START_INDEX
	var gname := String(cfg.general_name_at(idx)).strip_edges()
	if gname == "":
		gname = "将领 %s" % ("0" if is_start else str(idx + 1))
	var type: String = cfg.general_type_at(idx)
	var type_name: String = cfg.unit_name_of(type)
	var entry := _find_general(id)
	# ★★ 2026.11：新将领的招募条目在**合作专用表**里（对战 / 战役的招募页不列它们）——
	#   备战详情仍然要把造价 / 读条写清楚，否则玩家不知道自己要花多少。
	var coop_only := false
	if entry.is_empty():
		entry = cfg.coop_recruit_entry(id)
		coop_only = not entry.is_empty()
	# ★★ 2026.11.5：阶走 `unit.general.tiers`（编辑器可改；新加的将领也能是 0 阶）。
	var tier: int = cfg.general_tier_at(idx)
	var subtitle := "%s · %s" % [_tier_name(tier), type_name]
	if is_start:
		subtitle += " · 开局将领"

	var cap: int = cfg.general_cap_at(idx)
	var sec: float = cfg.general_recruit_sec(idx)
	var body := ""
	if is_start:
		body = "开局即拥有的%s型将领，不参与区划招募。统兵上限 %d。" % [type_name, cap]
	elif coop_only:
		body = "合作模式专用将领（%s型）。备战页把它设为出战后，它会出现在区划招募九宫格；" \
			% type_name \
			+ "统兵上限 %d；招募读条 %s 秒。对战 / 战役的招募页不列它。" % [cap, _fmt(sec)]
	elif entry.is_empty():
		# ★ 编辑器新加的将领**可以没有区划招募条目**（「只加数值档」那一种）——
		#   别在这里谎报「可招募」，否则玩家在区划里找不到它。
		body = "%s型将领。没有区划招募条目（不在招募九宫格里），由关卡摆放 / 开局获得。统兵上限 %d。" \
			% [type_name, cap]
	else:
		var cd := float(entry.get("recruit_cooldown_sec", 0.0))
		body = "可招募的%s型将领。统兵上限 %d；招募读条 %s 秒，冷却 %s 秒。" \
			% [type_name, cap, _fmt(sec), _fmt(cd)]

	var sections: Array = [{"title": "说明", "text": body}]
	# ★★ 2026.11.5：派系归属（一位将领可属多个派系；空 = 哪个派系都不显示）。
	var fac_names: Array = []
	for cid in cfg.general_factions_at(idx):
		var nm := String(cfg.clan_name_of(String(cid))).strip_edges()
		fac_names.append(nm if nm != "" else String(cid))
	if not fac_names.is_empty():
		sections.append({"title": "派系归属", "text": " / ".join(fac_names)})
	else:
		sections.append({"title": "派系归属",
			"text": "（无）—— 哪个派系的备战页都不会列出这位将领"})
	sections.append({"title": "属性", "grid": _general_stats(idx, type)})

	# ★★ 2026.11.5：0 阶将领随**局内大本营等级**成长（占位数在 config 的 unit.general.growth）。
	if tier == 0 and (cfg.general_growth_hp_per_level > 0.0
			or cfg.general_growth_damage_per_level > 0.0):
		sections.append({"title": "成长（0 阶）", "text":
			"大本营每升 1 级：血量 +%s、攻击 +%s（1 级就有；升级当场生效）。"
			% [_fmt(cfg.general_growth_hp_per_level),
			   _fmt(cfg.general_growth_damage_per_level)]})

	var cost: Variant = entry.get("cost", {})
	var has_cost := not entry.is_empty() and typeof(cost) == TYPE_DICTIONARY
	var info: Array = [
		["粮", _fmt((cost as Dictionary).get("food", 0.0)) if has_cost else "—"],
		["金", _fmt((cost as Dictionary).get("gold", 0.0)) if has_cost else "—"],
		["人口", str(int(entry.get("population_cost", 0))) if not entry.is_empty() else "—"],
		["读条", "%s 秒" % _fmt(sec) if not entry.is_empty() else "—"],
		["冷却", "%s 秒" % _fmt(float(entry.get("recruit_cooldown_sec", 0.0))) if not entry.is_empty() else "—"],
		["统兵", str(cap)],
	]
	sections.append({"title": "造价 / 招募", "grid": info, "columns": 4})

	# ★★ 2026.11：一位将领可以带多条特性 —— 每条「名字（大字金色）+ 说明（普通字）」。
	var tids: Array = cfg.general_traits_at(idx)
	if not tids.is_empty():
		var tentries: Array = []
		for tid_v in tids:
			var tid := String(tid_v)
			tentries.append({"name": cfg.general_trait_name(tid),
				"text": cfg.general_trait_desc(tid)})
		sections.append({"title": "特性", "entries": tentries})

	# ★★ 2026.11：将领也有图像素材了 —— 暂时用**所属兵种**的图标占位
	#   （与备战页磁贴同一个蒙版来源；以后换成将领专属素材时只改这里 + 磁贴）。
	var gmask := IconRes.mask_for_unit(cfg, type)
	return {
		"kind": "general", "id": id, "title": gname, "subtitle": subtitle,
		"icon_mask": gmask, "icon_text": "" if gmask != "" else _general_number(id),
		"tier": tier, "sections": sections,
	}


func _build_tech(id: String) -> Dictionary:
	if cfg == null:
		return {}
	var entry: Dictionary = cfg.tech_entry(id)
	if entry.is_empty():
		return {}
	var tier := int(entry.get("tier", 1))
	var sections: Array = [
		{"title": "说明", "text": _clean_desc(String(entry.get("desc", "")))},
		{"title": "效果", "text": String(entry.get("line", "")), "accent": true},
	]
	var gold: float = cfg.tech_gold_per_sec_of(id)
	var info: Array = [["阶", _tier_name(tier)], ["金/秒", _fmt(gold)]]
	sections.append({"title": "科技", "grid": info, "columns": 2})
	return {
		"kind": "tech", "id": id,
		"title": String(entry.get("name", "")),
		"subtitle": "%s · 科技" % _tier_name(tier),
		"icon_mask": IconRes.mask_for_tech(id), "icon_text": "",
		"tier": tier, "sections": sections,
	}


# ------------------------------------------------------------------
# 数据小工具
# ------------------------------------------------------------------

func _find_recruit(id: String) -> Dictionary:
	if cfg == null:
		return {}
	var factions: Array = [_faction, "dynasty", "empire"]
	for f in factions:
		if String(f) == "":
			continue
		for item in cfg.clan_recruit_list(String(f)):
			if typeof(item) == TYPE_DICTIONARY and String((item as Dictionary).get("kind", "")) == id:
				return item
	return {}


func _find_general(id: String) -> Dictionary:
	if cfg == null:
		return {}
	var zone: Variant = cfg.get_path_value("recruit.zone.list")
	if typeof(zone) != TYPE_ARRAY:
		return {}
	for item in (zone as Array):
		if typeof(item) == TYPE_DICTIONARY and String((item as Dictionary).get("kind", "")) == id:
			return item
	return {}


func _primary_type(entry: Dictionary) -> String:
	var spawn: Variant = entry.get("spawn", [])
	if typeof(spawn) == TYPE_ARRAY and not (spawn as Array).is_empty():
		var first: Variant = (spawn as Array)[0]
		if typeof(first) == TYPE_DICTIONARY:
			return String((first as Dictionary).get("type", ""))
	return String(entry.get("kind", ""))


func _general_number(id: String) -> String:
	if id == "general_0":
		return "0"
	if id.begins_with("general_"):
		return id.substr(8)
	return ""


func _tier_name(tier: int) -> String:
	if cfg != null:
		var names: Variant = cfg.get_path_value("menu.deck.prepare.tier_names")
		if typeof(names) == TYPE_ARRAY and tier >= 0 and tier < (names as Array).size():
			var s := String((names as Array)[tier]).strip_edges()
			if s != "":
				return s
	const FALLBACK := ["零阶", "一阶", "二阶", "三阶"]
	return FALLBACK[tier] if tier >= 0 and tier < FALLBACK.size() else ""


func _unit_role(type: String) -> String:
	if cfg == null:
		return ""
	var cls: String = cfg.unit_class_name(type)
	var ranged: bool = cfg.unit_is_ranged(type)
	if cls == "":
		return "远程" if ranged else "近战"
	return "%s · %s" % [cls, "远程" if ranged else "近战"]


func _unit_stats(type: String) -> Array:
	if cfg == null:
		return []
	var combat: Dictionary = cfg.unit_combat_of(type)
	var can_attack: bool = cfg.unit_can_attack(type)
	return [
		["生命", _fmt(cfg.unit_hp_of(type))],
		["攻击", _fmt(combat.get("damage", 0.0)) if can_attack else "—"],
		["护甲", _fmt(cfg.unit_armor_of(type))],
		["射程", "%s 格" % _fmt(combat.get("range", 0.0)) if can_attack else "—"],
		["移速", "%s 格/秒" % _fmt(cfg.unit_speed_of(type))],
		["视野", "%s 格" % _fmt(cfg.unit_vision_of(type))],
	]


func _general_stats(idx: int, _type: String) -> Array:
	if cfg == null:
		return []
	var combat: Dictionary = cfg.general_combat_at(idx)
	# ★★ 2026.11：护甲走 `general_armor_at()`（覆盖 ⊕ 兵种）—— 全局 +1 加成已删除，
	#   这里若还按「兵种 + 加成」算，就会和单位身上真实的护甲对不上。
	var armor: float = cfg.general_armor_at(idx)
	return [
		["生命", _fmt(cfg.general_hp_at(idx))],
		["攻击", _fmt(combat.get("damage", 0.0))],
		["护甲", _fmt(armor)],
		["射程", "%s 格" % _fmt(combat.get("range", 0.0))],
		["移速", "%s 格/秒" % _fmt(cfg.general_speed_at(idx))],
		["视野", "%s 格" % _fmt(cfg.general_vision_at(idx))],
	]


func _unit_stat_line(type: String) -> String:
	if cfg == null:
		return ""
	var combat: Dictionary = cfg.unit_combat_of(type)
	var can_attack: bool = cfg.unit_can_attack(type)
	var parts: Array = [
		"生命 %s" % _fmt(cfg.unit_hp_of(type)),
		"护甲 %s" % _fmt(cfg.unit_armor_of(type)),
	]
	if can_attack:
		parts.append("攻击 %s" % _fmt(combat.get("damage", 0.0)))
		parts.append("射程 %s" % _fmt(combat.get("range", 0.0)))
	parts.append("移速 %s" % _fmt(cfg.unit_speed_of(type)))
	parts.append("视野 %s" % _fmt(cfg.unit_vision_of(type)))
	return " · ".join(parts)


func _clean_desc(s: String) -> String:
	var out := String(s).replace("**", "")
	out = out.replace("★ ", "\n")
	return out.strip_edges()


func _fmt(v: Variant) -> String:
	var f := float(v)
	if is_equal_approx(f, roundf(f)):
		return str(int(roundf(f)))
	return String.num(f, 2).rstrip("0").rstrip(".")


# ------------------------------------------------------------------
# 渲染
# ------------------------------------------------------------------

func _clear_content() -> void:
	if _content == null:
		return
	for c in _content.get_children():
		_content.remove_child(c)
		c.queue_free()


func _rebuild(data: Dictionary) -> void:
	_clear_content()
	_content.add_child(_make_header(data))
	_content.add_child(_make_line())

	var sections: Array = data.get("sections", [])
	for s in sections:
		if typeof(s) != TYPE_DICTIONARY:
			continue
		_content.add_child(_make_section(s as Dictionary))


func _make_header(data: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.name = "DetailHeader"
	row.add_theme_constant_override("separation", 24)

	var frame := Panel.new()
	frame.name = "IconFrame"
	frame.custom_minimum_size = Vector2(ICON_BOX, ICON_BOX)
	frame.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	frame.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_theme_stylebox_override("panel", MenuThemeRes.deck_block())
	row.add_child(frame)

	var mask := String(data.get("icon_mask", ""))
	var text := String(data.get("icon_text", ""))
	if mask != "" and ResourceLoader.exists(mask):
		var tr := TextureRect.new()
		tr.name = "DetailIcon"
		tr.texture = load(mask)
		tr.self_modulate = ThemeRes.accent()
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tr.position = Vector2((ICON_BOX - ICON_INNER) * 0.5, (ICON_BOX - ICON_INNER) * 0.5)
		tr.size = Vector2(ICON_INNER, ICON_INNER)
		frame.add_child(tr)
	else:
		var big := Label.new()
		big.name = "DetailIconText"
		big.text = text if text != "" else String(data.get("title", "")).substr(0, 1)
		big.mouse_filter = Control.MOUSE_FILTER_IGNORE
		big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		big.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		big.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		if font != null:
			big.add_theme_font_override("font", font)
		big.add_theme_font_size_override("font_size", 104 if text != "" else 72)
		big.add_theme_color_override("font_color", ThemeRes.accent())
		frame.add_child(big)

	var texts := VBoxContainer.new()
	texts.name = "HeaderTexts"
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.size_flags_vertical = Control.SIZE_EXPAND_FILL
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	texts.add_theme_constant_override("separation", 8)
	row.add_child(texts)

	var title := Label.new()
	title.name = "DetailTitle"
	title.text = String(data.get("title", ""))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if font != null:
		title.add_theme_font_override("font", font)
	title.add_theme_font_size_override("font_size", TITLE_FONT)
	title.add_theme_color_override("font_color", ThemeRes.text())
	texts.add_child(title)

	var subtitle := Label.new()
	subtitle.name = "DetailSubtitle"
	subtitle.text = String(data.get("subtitle", ""))
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	subtitle.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if font != null:
		subtitle.add_theme_font_override("font", font)
	subtitle.add_theme_font_size_override("font_size", SUBTITLE_FONT)
	subtitle.add_theme_color_override("font_color", ThemeRes.text_dim())
	texts.add_child(subtitle)

	return row


func _make_section(s: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.name = "DetailSection"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 6)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(head)

	var label := Label.new()
	label.text = String(s.get("title", ""))
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if font != null:
		label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", SECTION_FONT)
	label.add_theme_color_override("font_color", ThemeRes.accent())
	head.add_child(label)

	var line := ColorRect.new()
	line.color = ThemeRes.line_soft()
	line.custom_minimum_size = Vector2(0.0, 1.0)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(line)

	if s.has("text"):
		var body := RichTextLabel.new()
		body.name = "SectionText"
		body.bbcode_enabled = false
		body.fit_content = true
		body.scroll_active = false
		body.mouse_filter = Control.MOUSE_FILTER_IGNORE
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.text = String(s.get("text", ""))
		if font != null:
			body.add_theme_font_override("normal_font", font)
		body.add_theme_font_size_override("normal_font_size",
			BODY_FONT if not bool(s.get("accent", false)) else 22)
		body.add_theme_color_override("default_color",
			ThemeRes.accent() if bool(s.get("accent", false)) else ThemeRes.text_dim())
		box.add_child(body)

	if s.has("entries"):
		var entries := VBoxContainer.new()
		entries.name = "SectionEntries"
		entries.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		entries.add_theme_constant_override("separation", 12)
		box.add_child(entries)
		for e in (s.get("entries", []) as Array):
			if typeof(e) != TYPE_DICTIONARY:
				continue
			entries.add_child(_make_entry(e as Dictionary))

	if s.has("grid"):
		var cols := int(s.get("columns", 3))
		var grid := GridContainer.new()
		grid.columns = maxi(1, cols)
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_theme_constant_override("h_separation", 12)
		grid.add_theme_constant_override("v_separation", 10)
		box.add_child(grid)
		for cell in (s.get("grid", []) as Array):
			if typeof(cell) != TYPE_ARRAY or (cell as Array).size() < 2:
				continue
			grid.add_child(_make_stat_cell(String(cell[0]), String(cell[1]),
				true if cols <= 2 else false))

	if s.has("rows"):
		var rows := VBoxContainer.new()
		rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rows.add_theme_constant_override("separation", 6)
		box.add_child(rows)
		for r in (s.get("rows", []) as Array):
			if typeof(r) != TYPE_DICTIONARY:
				continue
			rows.add_child(_make_row(r as Dictionary))

	return box


## ★★ 2026.11：一条「大号金字标题 + 普通灰字说明」——将领特性用。
##   · 名字：`ENTRY_NAME_FONT`（比正文大）+ 金色（与节标题同一套强调色）；
##   · 说明：`BODY_FONT` 普通字 + 正文灰（与「说明」那一段同档）。
func _make_entry(e: Dictionary) -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 2)

	var name := Label.new()
	name.name = "EntryName"
	name.text = String(e.get("name", ""))
	name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font != null:
		name.add_theme_font_override("font", font)
	name.add_theme_font_size_override("font_size", ENTRY_NAME_FONT)
	name.add_theme_color_override("font_color", ThemeRes.accent())
	col.add_child(name)

	var body := RichTextLabel.new()
	body.name = "EntryText"
	body.bbcode_enabled = false
	body.fit_content = true
	body.scroll_active = false
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.text = String(e.get("text", ""))
	if font != null:
		body.add_theme_font_override("normal_font", font)
	body.add_theme_font_size_override("normal_font_size", BODY_FONT)
	body.add_theme_color_override("default_color", ThemeRes.text_dim())
	col.add_child(body)
	return col


func _make_stat_cell(caption: String, value: String, wide: bool) -> Control:
	var cell := VBoxContainer.new()
	cell.custom_minimum_size = Vector2(0.0, 58.0 if not wide else 62.0)
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.add_theme_constant_override("separation", 2)
	var cap := Label.new()
	cap.text = caption
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font != null:
		cap.add_theme_font_override("font", font)
	cap.add_theme_font_size_override("font_size", STAT_LABEL_FONT)
	cap.add_theme_color_override("font_color", ThemeRes.text_faint())
	cell.add_child(cap)
	var val := Label.new()
	val.text = value
	val.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font != null:
		val.add_theme_font_override("font", font)
	val.add_theme_font_size_override("font_size",
		STAT_VALUE_FONT if not wide else INFO_VALUE_FONT)
	val.add_theme_color_override("font_color", ThemeRes.text())
	cell.add_child(val)
	return cell


func _make_row(r: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 14)
	var name := Label.new()
	name.text = String(r.get("name", ""))
	name.custom_minimum_size = Vector2(210.0, 0.0)
	name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if font != null:
		name.add_theme_font_override("font", font)
	name.add_theme_font_size_override("font_size", ROW_NAME_FONT)
	name.add_theme_color_override("font_color", ThemeRes.text())
	row.add_child(name)
	var detail := Label.new()
	detail.text = String(r.get("detail", ""))
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	detail.clip_text = true
	detail.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if font != null:
		detail.add_theme_font_override("font", font)
	detail.add_theme_font_size_override("font_size", ROW_DETAIL_FONT)
	detail.add_theme_color_override("font_color", ThemeRes.text_dim())
	row.add_child(detail)
	return row


func _make_line() -> Control:
	var line := ColorRect.new()
	line.color = ThemeRes.line_soft()
	line.custom_minimum_size = Vector2(0.0, 1.0)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


func _make_hint() -> Control:
	var box := VBoxContainer.new()
	box.name = "DetailHint"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 10)

	var line := ColorRect.new()
	line.color = ThemeRes.with_alpha(ThemeRes.accent(), 0.55)
	line.custom_minimum_size = Vector2(44.0, 2.0)
	line.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(line)

	var main := Label.new()
	main.text = "点击右侧将领 / 单位 / 科技查看详情"
	main.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	main.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	main.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font != null:
		main.add_theme_font_override("font", font)
	main.add_theme_font_size_override("font_size", 22)
	main.add_theme_color_override("font_color", ThemeRes.text_dim())
	box.add_child(main)

	var sub := Label.new()
	sub.text = "属性 / 说明 / 造价会显示在这里"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font != null:
		sub.add_theme_font_override("font", font)
	sub.add_theme_font_size_override("font_size", 16)
	sub.add_theme_color_override("font_color", ThemeRes.text_faint())
	box.add_child(sub)
	return box

