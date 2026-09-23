## unit_roster.gd —— 详细信息左栏**上半**：左上那一格（当前展开 / 唯一选中的部队的将领）
##
## ★★ 第四轮改版（照新参考图逐像素重量的）：这一段**只剩一个格子**了 ——
##   参考图实测：x 415..454 一个 40×40 方框，它右边是「将领名称 1/11」那一行字。
##   面板左栏总共 1 + 3×3 = 10 格，下面那 9 格由 view/troop_grid.gd 画：
##     · 选中多支部队时 = 其余部队的将领（点一格换展开哪一支）；
##     · 只选中一支部队时 = 这支部队的单位（点一格切右栏到那个单位）；
##     · **选中建筑时 = 主选中（右栏正在显示）的那一个建筑**（其余建筑在下面 9 格里）。
##   ⇒ 所以这里**不再有那排单位小方块、也没有滚轮**（方块搬进下面的网格里了，
##     见 view/troop_grid.gd 的 MODE_UNITS / MODE_BUILDINGS）。
##
## ★ 纯表现：只读 `world.units` 与单位上的渲染标志（selected / target / hp），
##   从不写任何逻辑状态。分组与「展开哪一支」由 hud/detail_panel 决定。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")

var world = null
## 中文字体（Godot 默认字体没有 CJK 字形 —— 不传就会画成方框）。
var font: Font = null

## 当前展开的那支部队：{"leader": 队长单位或 null, "number": 部队编号(0=没编号), "units": [...]}
var _troop: Dictionary = {}
## 这一格现在画的内容（**通用**：部队 / 建筑都由外面组装成这个字典递进来）：
##   {"short": 方框里的短字, "name": 第一行, "sub": 第二行, "highlight": 要不要点亮描边}
## 空字典 = 这一格收起来。
var _entry: Dictionary = {}
## 格子里右边那行小字（「将领名称」——参考图上写的就是这个，不是将领真名）
var _label_text: String = ""
## 画过几帧（给测试用：无头下 `_draw` 里的错误不会让测试失败，所以盯一下它真的跑了）
var draw_count: int = 0


func setup(p_world, p_font: Font = null) -> void:
	world = p_world
	font = p_font
	name = "UnitRoster"
	# ★ 这一格**不接点击**（它只是显示）：单位格 / 将领格都在下面那个网格里，
	#   所以这里放行鼠标，别把事件吃掉。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(UiLayoutRes.DETAIL_LEFT_W, UiLayoutRes.ROSTER_DETAIL_H)
	visible = false


# ------------------------------------------------------------------
# 刷新（每帧由 detail_panel 喂）
# ------------------------------------------------------------------

## @param troop null = 没有展开任何部队（整块收起来）
## @param leader_name_text 格子右边那行小字（手玩原话：参考图上写的就是「将领名称」，
##        所以 hud 传的是这个固定文案，而不是将领的真名）
func set_troop(troop, leader_name_text: String = "") -> void:
	_troop = {} if troop == null else troop
	_label_text = leader_name_text
	var l = _troop.get("leader", null)
	if l == null:
		set_entry(null)
		return
	set_entry({
		"short": short_name(l),
		"name": label_text(),
		"sub": _troop_count_text(),
		"highlight": bool(l.selected),
	})


## 部队那一格的第二行：「x/y」（x = 现有单位数，y = 编制上限）。
## ⚠️ 必须直接读 `_troop`，**不能**读 `count_text()` —— 那一个读的是 `_entry`，
##    而它正是在 `set_troop()` 里被这次调用写掉的（先算后写，读到的会是上一格的内容）。
func _troop_count_text() -> String:
	return "%d/%d" % [unit_count(), UiLayoutRes.UNIT_CAP]


## 直接喂「这一格画什么」——建筑选中时走这条路（hud 组装好短字 / 名字 / 血量递进来）。
## ★ 与 `set_troop()` 是同一个落点：两条路都只写 `_entry`，画的时候只认 `_entry`。
## @param entry null / 空字典 = 这一格收起来
func set_entry(entry) -> void:
	_entry = {} if entry == null else (entry as Dictionary).duplicate()
	if _entry.is_empty():
		_troop = {}
	visible = not _entry.is_empty()
	queue_redraw()


# ------------------------------------------------------------------
# 状态（给渲染与测试读）
# ------------------------------------------------------------------

func leader():
	return _troop.get("leader", null)


## 这支部队的编号（1 起；不在左侧列表里 → 0）
func troop_number() -> int:
	return int(_troop.get("number", 0))


## 这支部队有几个单位（含将领）
func unit_count() -> int:
	var units: Array = _troop.get("units", [])
	return units.size()


## 格子第一行写的字（= 将领真名 / 建筑名；拿不到名字时退回外面递进来的占位文案）
func leader_name() -> String:
	return String(_entry.get("name", ""))


## 格子第二行小字：部队 = 「x/y」（现有单位数 / 编制上限）；建筑 = 「血量/上限」
func count_text() -> String:
	return String(_entry.get("sub", ""))


## 方框里的短字（与网格里的格子同一套口径：名字首字）
func leader_short() -> String:
	return String(_entry.get("short", ""))


## 任意一个单位在这套 UI 里的短字（网格画单位格时也从这里取，只此一处口径）：
##   将领 = 名字首字（「将」）；可招募兵种 = 招募表里的 short（「兵」）；其余 = 名字首字。
func short_name(u) -> String:
	if u == null:
		return ""
	if world != null and world.is_team_leader(u):
		return _first_char(u, "将")
	if world != null and world.is_recruitable(String(u.kind)):
		return world.recruit_short_of(String(u.kind))
	return _first_char(u, "?")


# ------------------------------------------------------------------
# 画
# ------------------------------------------------------------------

func _draw() -> void:
	draw_count += 1
	if not visible:
		return
	var f: Font = font
	if f == null:
		f = get_theme_default_font()
	_draw_leader_cell(f)


## 左边那一格：40×40 方框 + 右边**两行**字（将领真名 / x÷y）。
##
## ★ 参考图实测：方框 x 415..454、y 860..899；右边第一行 y 885..899、第二行 y 902..911。
## ⇒ 本工程把两行作为一块、与 40 高的方框**垂直居中**（手玩原话：「对齐其对应左侧头像居中」）。
func _draw_leader_cell(f: Font) -> void:
	if _entry.is_empty():
		return
	var av := UiLayoutRes.roster_cell_avatar_rect()
	draw_rect(av, UiStyleRes.BG_PRESSED, true)
	draw_rect(av, UiStyleRes.ACCENT if bool(_entry.get("highlight", false)) else UiStyleRes.LINE,
		false, 1.0)
	_draw_centered(f, leader_short(), av, UiStyleRes.TEXT, UiStyleRes.FS_BODY)
	# 两行都用 FS_SMALL（13 号字、汉字约 15px 高）—— 与下面 9 个格子同一套字号。
	draw_string(f, Vector2(UiLayoutRes.ROSTER_CELL_TEXT_X, UiLayoutRes.ROSTER_ID_Y),
		_clip_text(f, leader_name(), UiLayoutRes.ROSTER_ID_W, UiStyleRes.FS_SMALL),
		HORIZONTAL_ALIGNMENT_LEFT, UiLayoutRes.ROSTER_ID_W, UiStyleRes.FS_SMALL,
		UiStyleRes.TEXT)
	draw_string(f, Vector2(UiLayoutRes.ROSTER_COUNT_X, UiLayoutRes.ROSTER_COUNT_Y),
		_clip_text(f, count_text(), UiLayoutRes.ROSTER_COUNT_W, UiStyleRes.FS_SMALL),
		HORIZONTAL_ALIGNMENT_LEFT, UiLayoutRes.ROSTER_COUNT_W, UiStyleRes.FS_SMALL,
		UiStyleRes.TEXT_DIM)


## 第一行写的字：**将领的真名**（参考图上这一行就是部队 / 将领的名字）。
## ⚠️ 曾经写死成「将领名称」四个字（照抄参考图的占位文案），手玩指出「左栏的字太小」之后
##   改成写真名 —— 真名才是玩家要读的信息。
func label_text() -> String:
	var l = leader()
	if l != null and String(l.name) != "":
		return String(l.name)
	return _label_text


## 把一行字截到 `max_w` 以内（装不下就砍尾巴并加省略号）。
## ⚠️ 左栏本来就是窄栏（350px），两行字的右边就是网格那一列的方框 ——
##    不自己量、不自己砍的话会盖到隔壁去（`draw_string` 的宽度参数不保证裁剪）。
func _clip_text(f: Font, text: String, max_w: float, size: int) -> String:
	if f == null or text == "":
		return text
	if f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= max_w:
		return text
	var ell := "…"
	var out := text
	while out.length() > 0:
		out = out.substr(0, out.length() - 1)
		var probe := out + ell
		if f.get_string_size(probe, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= max_w:
			return probe
	return ell


func _first_char(u, fallback: String) -> String:
	if u == null:
		return ""
	var n := String(u.name)
	return n.substr(0, 1) if n.length() > 0 else fallback


## 在一个矩形里居中画一行字（draw_string 的 pos 是**基线**）
func _draw_centered(f: Font, text: String, r: Rect2, color: Color, size: int) -> void:
	if text == "":
		return
	var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var baseline := r.position.y + r.size.y * 0.5 + float(size) * 0.5 - 2.0
	draw_string(f, Vector2(r.position.x + (r.size.x - w) * 0.5, baseline), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
