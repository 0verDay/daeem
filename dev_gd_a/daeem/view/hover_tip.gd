## hover_tip.gd —— **左下角悬停说明牌**：卡牌悬停时那块说明就写在这里
##
## ★★ 需求原话：「将所有的卡牌悬停文本放至左下角栏中（若在悬停卡牌时已有左下角栏，
##   则卡牌悬停文本覆盖原有栏位）……面板大小完全相同样式相同」（2026.11.16）
##   +「悬停文本的排版需要改成像当前选中建筑/单位时的那种**有分隔的排版**」（同日第二轮）。
##
## 落点：
##   · 矩形 = `ui_layout.HOVER_RECT`（就是 `DETAIL_V2_RECT`：左下角栏那一块 377×260），
##     ⇒ 尺寸与详情牌**逐像素相同**，不随文本长高；
##   · 牌面 = `detail_v2.draw_plate()`（同一份画法：投影 / 两层错位背牌 / 竖向渐变 /
##     2px 黄铜边 / 内圈金线）⇒ 样式**同一份代码**；
##   · `z_index` 压过详情牌（detail_v2 = 5，这里 = 6）⇒ 悬停时把原栏位**盖住**，
##     鼠标移开就收起，露出原来的详情内容。
##
## 版式（照详情牌的**分隔**语言，一行一块、块与块之间有线）：
##
##   ┌────────────────────────────────────────────┐
##   │ 乂字军披甲剑士                 近战步兵   │ ← 卡名（18）+ 副标题（11，兵种 / 卡种）
##   ├────────────────────────────────────────────┤ ← 金线（与详情牌头部同一条规矩）
##   │ ┌──────────┬──────────┐                    │
##   │ │ 粮 食    │ 黄 金    │                    │ ← 造价格（与详情牌「编制 / 血量」同款：
##   │ │ 70       │ 0        │                    │    深底 + 细描边 + 9 号带字距标签 + 18 号数值）
##   │ └──────────┴──────────┘                    │
##   │ 特 性                                      │ ← 小标题（9 号带字距）
##   │ [对骑兵伤害+] [近战伤害减免+]              │ ← 胶囊（与详情牌的将领特性胶囊同款）
##   │                             需 2 级大本营 │ ← 只有置灰格才有这一行（warn 色）
##   └────────────────────────────────────────────┘
##
## ⚠️ 全部是 `_draw()` 自绘（字距 / 裁剪都走 `ui_text.gd`），没有子 Label ——
##   分隔线、格子、胶囊必须画在同一张牌上，用控件拼反而对不齐。
## ⚠️ 本控件是 `MOUSE_FILTER_IGNORE`：它只是「画出来的一张说明」，
##   一旦吃鼠标会挡住底下的地图点击与详情牌的成员格。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const UiTextRes = preload("res://view/ui_text.gd")
const DetailV2Res = preload("res://view/detail_v2.gd")

## 卡名：与详情牌的名字（`detail_info.TITLE_FS`）同档
const TITLE_FS := 18
## 副标题（兵种 / 建筑 / 科技…）：与详情牌的副标题同档
const SUB_FS := 11
## 造价那一格：与详情牌的数值格**同款同尺寸**（46 高、9 号带字距标签 + 18 号数值）
const CELL_H := 46.0
const CELL_GAP := 6.0
const CELL_MAX_W := 120.0          # 只有 1~2 格时别拉满整块牌（详情牌也是这么窄）
const CELL_LABEL_FS := 9
const CELL_LABEL_TRACK := 1.4
const CELL_VALUE_FS := 18
## 小标题（「特 性」「效 果」）：与详情牌的特性小标题同款
const CAP_FS := 9
const CAP_TRACK := 1.6
## 特性胶囊：与详情牌的特性胶囊同款（18 高、金描边、accent_bright 字）
const CHIP_FS := 10
const CHIP_H := 18.0
const CHIP_GAP := 5.0
const CHIP_ROW_GAP := 4.0
const CHIP_MAX_ROWS := 2
## 置灰原因那一行（占一行高度，贴在牌底）
const NOTE_FS := 11
const NOTE_LINE_H := 20.0

var _font: Font = null
## 现在这块牌上写着什么（全部由 hud 喂进来，本控件不认识任何玩法概念）
var _title := ""
var _subtitle := ""
var _cells: Array = []             # [{ label, value }]
var _caption := ""
var _chips: Array = []             # [String]
var _note := ""
var _showing: bool = false


func setup(p_font: Font = null) -> void:
	name = "HoverTip"
	# ★ IGNORE：理由见文件头
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# ★ 压过详情牌：悬停文本要能盖住原栏目
	z_index = 6
	# 兜底：任何情况下都不许有字画到牌面之外
	clip_contents = true
	UiLayoutRes.apply_rect(self, UiLayoutRes.HOVER_RECT, false, true)
	# ★ 字体拿不到时退回引擎兜底字体：中文会变方框，但**版式不会散**
	_font = p_font if p_font != null else ThemeDB.fallback_font
	clear()


# ------------------------------------------------------------------
# 内容（由 hud 喂）
# ------------------------------------------------------------------

## 显示一张卡的精简说明。
##   @param cells   造价格 `[{label, value}]`（可以 0~3 格；空数组 = 不画那一排）
##   @param chips   特性胶囊文字（空数组 = 连小标题一起不画）
##   @param note    置灰原因（空串 = 不画）
func show_card(title: String, subtitle: String, cells: Array, caption: String,
		chips: Array, note: String = "") -> void:
	_title = title
	_subtitle = subtitle
	_cells = cells.duplicate()
	_caption = caption
	_chips = chips.duplicate()
	_note = note
	_showing = true
	visible = true
	queue_redraw()


## 收起来（换页 / 鼠标移开 / 换了一格时都由 hud 调它）
func clear() -> void:
	_title = ""
	_subtitle = ""
	_cells = []
	_caption = ""
	_chips = []
	_note = ""
	_showing = false
	visible = false


# ------------------------------------------------------------------
# 牌面
# ------------------------------------------------------------------

func _draw() -> void:
	# ★ 与左下详情牌同一份画法（需求：「面板大小完全相同样式相同」）
	DetailV2Res.draw_plate(self, size.x, size.y)
	var f := _font if _font != null else get_theme_default_font()
	if f == null:
		return
	var pad: float = UiLayoutRes.HOVER_PAD
	var w: float = size.x

	# ① 卡名 + 副标题（副标题右对齐；宽度按**卡名实际占宽**分配 ——
	#    卡名短的时候副标题就能多占，反之卡名优先、副标题裁
	var title_base: float = pad + 16.0
	var inner: float = w - 2.0 * pad
	var title_need: float = f.get_string_size(_title, HORIZONTAL_ALIGNMENT_LEFT, -1,
		TITLE_FS).x
	var title_w: float = minf(title_need, inner * 0.62)
	var sub_w := 0.0
	if _subtitle != "":
		var sub_max: float = inner - title_w - 12.0
		var sub := UiTextRes.fit(f, _subtitle, maxf(60.0, sub_max), SUB_FS)
		sub_w = f.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, SUB_FS).x
		draw_string(f, Vector2(w - pad - sub_w, title_base), sub,
			HORIZONTAL_ALIGNMENT_LEFT, -1, SUB_FS, UiStyleRes.text_dim())
	draw_string(f, Vector2(pad, title_base),
		UiTextRes.fit(f, _title, title_w, TITLE_FS),
		HORIZONTAL_ALIGNMENT_LEFT, title_w, TITLE_FS, UiStyleRes.text())

	# ② 金线：与详情牌头部下面那条同一条规矩（淡金 + 1px）
	var rule_y: float = pad + UiLayoutRes.HOVER_TITLE_H
	draw_line(Vector2(pad, rule_y), Vector2(w - pad, rule_y),
		Color(UiStyleRes.accent(), 0.22), 1.0)

	# ③ 造价格（与详情牌的数值格同款，紧贴金线下面）
	var cells_y: float = rule_y + 10.0
	_draw_cells(f, pad, cells_y, w - 2.0 * pad)

	# ④ 特性：**页脚钉在牌底**（与详情牌 `.traits{bottom:16px}` 同一条规矩）——
	#    先给「置灰原因」留一行，再把小标题 + 胶囊整体贴上去。
	var footer: float = size.y - pad
	if _note != "":
		footer -= NOTE_LINE_H
	if not _chips.is_empty():
		var rows: int = _chip_rows(f, pad, w - 2.0 * pad)
		var block_h: float = float(rows) * CHIP_H + float(rows - 1) * CHIP_ROW_GAP
		var chips_y: float = footer - block_h
		UiTextRes.tracked(self, f, Vector2(pad, chips_y - 7.0), _caption, CAP_FS,
			Color(UiStyleRes.text_faint(), 0.95), CAP_TRACK)
		_draw_chips(f, pad, chips_y, w - 2.0 * pad)

	# ⑤ 置灰原因（牌底，warn 色）
	if _note != "":
		draw_string(f, Vector2(pad, size.y - pad - 2.0),
			UiTextRes.fit(f, "· " + _note, w - 2.0 * pad, NOTE_FS),
			HORIZONTAL_ALIGNMENT_LEFT, w - 2.0 * pad, NOTE_FS, UiStyleRes.warn())


## 胶囊要排几行（只量不画）：与 `_draw_chips` 的换行规则必须**同一套**，
## 否则「页脚贴底」会算错高度。
func _chip_rows(f: Font, x0: float, max_w: float) -> int:
	var cx := x0
	var rows := 1
	for c in _chips:
		var text := String(c)
		if text == "":
			continue
		var w := minf(max_w, UiTextRes.tracked_width(f, text, CHIP_FS, 0.4) + 12.0)
		if cx + w > x0 + max_w + 0.5:
			cx = x0
			rows += 1
		cx += w + CHIP_GAP
	return mini(rows, CHIP_MAX_ROWS)


## 一排造价 / 数值格：**逐像素照抄 detail_info 的数值格**（同一套卡片语言）。
func _draw_cells(f: Font, x0: float, y0: float, max_w: float) -> void:
	var n: int = _cells.size()
	if n <= 0:
		return
	var bw: float = minf(CELL_MAX_W,
		(max_w - CELL_GAP * float(n - 1)) / float(n))
	for i in n:
		var cell: Dictionary = _cells[i]
		var r := Rect2(x0 + float(i) * (bw + CELL_GAP), y0, bw, CELL_H)
		draw_rect(r, Color(0.043, 0.058, 0.078, 1.0), true)
		draw_rect(r, UiStyleRes.line_soft(), false, 1.0)
		# 格子底部压一条更暗的厚度边（与编队牌同一种「卡片」语言）
		draw_rect(Rect2(r.position.x + 1.0, r.end.y - 3.0, r.size.x - 2.0, 2.0),
			Color(0.016, 0.024, 0.033, 0.9), true)
		UiTextRes.tracked(self, f, Vector2(r.position.x + 9.0, r.position.y + 17.0),
			String(cell.get("label", "")), CELL_LABEL_FS,
			Color(UiStyleRes.text_faint(), 0.95), CELL_LABEL_TRACK)
		var value := UiTextRes.fit(f, String(cell.get("value", "")),
			r.size.x - 18.0, CELL_VALUE_FS)
		draw_string(f, Vector2(r.position.x + 9.0, r.position.y + 39.0), value,
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 18.0, CELL_VALUE_FS, UiStyleRes.text())


## 特性胶囊：一行一个框，超出列宽就换行（最多 CHIP_MAX_ROWS 行，再多就裁）。
func _draw_chips(f: Font, x0: float, y0: float, max_w: float) -> void:
	var cx := x0
	var cy := y0
	var row := 0
	for c in _chips:
		var text := String(c)
		if text == "":
			continue
		var tw := UiTextRes.tracked_width(f, text, CHIP_FS, 0.4)
		var w := minf(max_w, tw + 12.0)
		if cx + w > x0 + max_w + 0.5:
			cx = x0
			cy += CHIP_H + CHIP_ROW_GAP
			row += 1
		if row >= CHIP_MAX_ROWS:
			return
		var r := Rect2(cx, cy, w, CHIP_H)
		draw_rect(r, Color(0.20, 0.16, 0.09, 0.95), true)
		draw_rect(r, Color(UiStyleRes.accent(), 0.55), false, 1.0)
		draw_string(f, Vector2(r.position.x + 6.0, r.position.y + 13.0),
			UiTextRes.fit(f, text, w - 12.0, CHIP_FS), HORIZONTAL_ALIGNMENT_LEFT,
			w - 12.0, CHIP_FS, UiStyleRes.accent_bright())
		cx += w + CHIP_GAP


# ------------------------------------------------------------------
# 给测试 / hud 用的小接口
# ------------------------------------------------------------------

## 现在显示着没有
func showing() -> bool:
	return _showing


func title_text() -> String:
	return _title


func subtitle_text() -> String:
	return _subtitle


func caption_text() -> String:
	return _caption


func note_text() -> String:
	return _note


func cell_count() -> int:
	return _cells.size()


func cell_label(i: int) -> String:
	return "" if i < 0 or i >= _cells.size() else String((_cells[i] as Dictionary).get("label", ""))


func cell_value(i: int) -> String:
	return "" if i < 0 or i >= _cells.size() else String((_cells[i] as Dictionary).get("value", ""))


func chips() -> Array:
	return _chips.duplicate()


## 整块牌上的**全部文字**（结构化的那几段按顺序拼起来）——
## 给「这一行里到底写了什么」这类断言用，不用关心它是格子还是胶囊。
func body_text() -> String:
	var parts: Array[String] = []
	if _subtitle != "":
		parts.append(_subtitle)
	for cell in _cells:
		parts.append(String((cell as Dictionary).get("value", "")))
	for c in _chips:
		parts.append(String(c))
	if _note != "":
		parts.append(_note)
	return " ".join(parts)
