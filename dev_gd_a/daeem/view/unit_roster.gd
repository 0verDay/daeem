## unit_roster.gd —— 详细信息左栏**上半**：左上那一格（当前聚焦 / 唯一选中的部队或建筑）
##
## ★★ 本版按需求改成「**部队图标 = 序号 + 士气背景**」：
##   · 选中部队时，这一格不再画将领名字的首字，而是写**部队序号**
##     （1..9、第 10 支写 0，与右侧部队列表同一口径），背后是士气填充
##     （view/morale_fill.gd：自下而上、越低越矮、绿→红）；
##   · 选中建筑时，这一格仍画建筑名的首字，**没有纯色背景填充**（只有图标 + 血条）；
##   · 右边那两行字（名字 / 编制）保留。
##
## ★ 纯表现：只读 `world.units` 与单位上的渲染标志（selected / target / hp），
##   从不写任何逻辑状态。分组与「聚焦哪一支」由 hud/detail_panel 决定。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const IconBadgeRes = preload("res://view/icon_badge.gd")

var world = null
## 中文字体（Godot 默认字体没有 CJK 字形 —— 不传就会画成方框）。
var font: Font = null

## 当前聚焦的那支部队：{"leader": 队长单位或 null, "number": 部队编号(0=没编号), "units": [...]}
var _troop: Dictionary = {}
## 这一格现在画的内容（**通用**：部队 / 建筑都由外面组装成这个字典递进来）：
##   {"kind": "troop"/"building", "icon": 方块里的字, "name": 第一行, "sub": 第二行,
##    "morale": 士气比例(只有部队用), "hp": 血量比例, "show_hp": 画不画血条,
##    "highlight": 要不要点亮描边}
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

## @param troop null = 没有聚焦任何部队（整块收起来）
## @param leader_name_text 拿不到将领真名时的兜底文案（参考图上写的就是「将领名称」）。
func set_troop(troop, leader_name_text: String = "") -> void:
	_troop = {} if troop == null else troop
	_label_text = leader_name_text
	var l = _troop.get("leader", null)
	if l == null:
		set_entry(null)
		return
	# ★★ 部队图标 = **序号**（1..9、第 10 支写 0）；拿不到编号时才退回将领首字。
	var icon := IconBadgeRes.troop_number_text(int(_troop.get("number", 0)))
	if icon == "":
		icon = short_name(l)
	set_entry({
		"kind": "troop",
		"icon": icon,
		"name": label_text(),
		"sub": _troop_count_text(),
		"morale": _leader_morale_ratio(l),
		"hp": _leader_hp_ratio(l),
		"show_hp": true,
		"highlight": bool(l.selected),
	})


## 队长当前士气比例（没有 morale_ratio 的老对象 → 满士气）。
func _leader_morale_ratio(l) -> float:
	if l != null and l.has_method("morale_ratio"):
		return float(l.morale_ratio())
	return 1.0


## 队长当前血量比例（没有 hp_ratio 的老对象 → 满血）。
func _leader_hp_ratio(l) -> float:
	if l != null and l.has_method("hp_ratio"):
		return float(l.hp_ratio())
	return 1.0


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
	# ★ 建筑那一路不带着「上一支部队」的 leader / units（否则 leader() 会返回旧对象）
	if _entry.is_empty() or String(_entry.get("kind", "")) != "troop":
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


## 方框里那个字：部队 = **序号**（1..9 / 0）；建筑 = 名字首字。
func icon_text() -> String:
	return String(_entry.get("icon", ""))


## 这一格现在是部队还是建筑（""= 空）
func kind() -> String:
	return String(_entry.get("kind", ""))


## 部队图标的士气比例（建筑 / 空 → 1.0）
func morale_ratio() -> float:
	return float(_entry.get("morale", 1.0))


## 图标底部血条的填充比例（没有血条时也返回 1.0）
func hp_ratio() -> float:
	return float(_entry.get("hp", 1.0))


## 要不要画血条
func shows_hp() -> bool:
	return bool(_entry.get("show_hp", false))


## 已废弃的旧名：保留成 `icon_text()` 的别名，免得外部调用点突然炸掉。
## ⚠️ 语义已经变了：部队现在给的是**序号**，不再是将领名字首字。
func leader_short() -> String:
	return icon_text()


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


## 左边那一格：40×40 图标 + 右边**两行**字（名字 / x÷y）。
##
## ★ 图标本身交给 view/icon_badge.gd 统一画：
##   部队 = 序号 + 士气填充；建筑 = 首字、无填充。两者都带底部血条。
func _draw_leader_cell(f: Font) -> void:
	if _entry.is_empty():
		return
	var av := UiLayoutRes.roster_cell_avatar_rect()
	var border: Color = UiStyleRes.accent() if bool(_entry.get("highlight", false)) \
		else UiStyleRes.line()
	IconBadgeRes.draw(self, f, av, kind(), icon_text(),
		morale_ratio(), hp_ratio(), shows_hp(),
		UiStyleRes.FS_TITLE, border, 1.0)
	# 两行都用 FS_SMALL（13 号字、汉字约 15px 高）—— 与下面 9 个格子同一套字号。
	draw_string(f, Vector2(UiLayoutRes.ROSTER_CELL_TEXT_X, UiLayoutRes.ROSTER_ID_Y),
		_clip_text(f, leader_name(), UiLayoutRes.ROSTER_ID_W, UiStyleRes.FS_SMALL),
		HORIZONTAL_ALIGNMENT_LEFT, UiLayoutRes.ROSTER_ID_W, UiStyleRes.FS_SMALL,
		UiStyleRes.text())
	draw_string(f, Vector2(UiLayoutRes.ROSTER_COUNT_X, UiLayoutRes.ROSTER_COUNT_Y),
		_clip_text(f, count_text(), UiLayoutRes.ROSTER_COUNT_W, UiStyleRes.FS_SMALL),
		HORIZONTAL_ALIGNMENT_LEFT, UiLayoutRes.ROSTER_COUNT_W, UiStyleRes.FS_SMALL,
		UiStyleRes.text_dim())


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
