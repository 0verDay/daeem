## troop_grid.gd —— 详细信息**左栏下半**：3×3 = 9 个格子的网格
##
## ★★ 第四轮改版（照新参考图逐像素重量的）：这一块**两种语义共用同一套格子**，
##    由外面（hud → detail_panel）决定画什么：
##
##   mode = LEADERS（**选中多支部队**）
##     画「其余选中部队的将领」——**被展开的那一支部队不在这里**（它画在左栏上半那一格）。
##     点一格 = 把展开的部队换成它（`troop_activated(部队编号)`）。
##
##   mode = UNITS（**只选中一支**）
##     画这支部队的**单位**（含将领本人，将领排在第一个）。
##     点一格 = 右栏切到那个单位（`unit_activated(格下标)`）。
##     单位超过 9 个（编制上限 11）→ 鼠标**滚轮翻页**，一次一页 9 格。
##
## ★ 每格的样子照参考图：**左边一个 40×40 方框（里面写短字）+ 右边两行字**
##   （第一行名字、第二行「x/y」或血量；两行作为一块与方框垂直居中，13 号字），
##   行优先排 3 列 × 3 行（参考图实测列 x 415/536/662、行 y 915/970/1025）。
##
## ★ 纯表现：格子里的数据由外面算好递进来，这里只读；没得画时整块收起来
##   （连空格子也不画 —— 手玩原话）。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")

## 点了某一格里的**将领**（带部队编号，1 起；拿不到编号时是 0）
signal troop_activated(number: int)
## 点了某一格里的**单位**（带格下标 0..8，= 当前页里的第几格）
signal unit_activated(index: int)

## 两种语义（见文件头）
enum { MODE_LEADERS, MODE_UNITS }

## 中文字体（Godot 默认字体没有 CJK 字形 —— 不传就会画成方框）
var font: Font = null

var mode: int = MODE_LEADERS

## 本页要画的格子：[{"kind": "leader"/"unit", "ref": 单位, "name": 显示名,
##                    "short": 方框里的短字, "number": 部队编号(将领格才有)}]
var _cells: Array = []
## 单选翻页：从第几个单位开始画（多选时恒为 0）
var _page_start: int = 0
## 单位总数（单选翻页用；<= 9 时不翻页）
var _unit_total: int = 0
## 单选时那批单位与它们的短字（翻页重排要用，见 _rebuild）
var _units: Array = []
var _shorts: Array = []
## 鼠标停在第几格（-1 = 没停在任何格子上）
var _hover: int = -1
## 画过几帧（给测试用：无头下 `_draw` 里的错误不会让测试失败，所以盯一下它真的跑了）
var draw_count: int = 0


func setup(p_font: Font = null) -> void:
	font = p_font
	name = "TroopGrid"
	# 要能点（换展开哪支部队 / 切右栏到某个单位），所以这里收鼠标；
	# 不可见时收不到事件，平时不挡别处。
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	custom_minimum_size = Vector2(UiLayoutRes.DETAIL_LEFT_W, UiLayoutRes.TROOP_GRID_H)
	visible = false


# ------------------------------------------------------------------
# 刷新（每帧由 detail_panel 喂）
# ------------------------------------------------------------------

## @param troops 要画的部队（= 选中部队**去掉正在展开的那一支**）。
##        每项：[{"leader": 队长单位, "number": 部队编号, "units": [...]}]
func set_troops(troops: Array) -> void:
	mode = MODE_LEADERS
	_unit_total = 0
	_page_start = 0
	var next: Array = []
	for t in troops:
		if next.size() >= UiLayoutRes.TROOP_GRID_SLOTS:
			break
		var leader = t.get("leader", null)
		next.append({
			"kind": "leader",
			"ref": leader,
			"name": "" if leader == null else String(leader.name),
			"short": _first_char(leader),
			"number": int(t.get("number", 0)),
			"units": t.get("units", []),
		})
	_apply(next)


## @param units 唯一选中那支部队的**全部单位**（第一个是队长）。
##        `short_names` 与它一一对应（方框里的短字，由 detail_panel 用 world 算好）。
##        超过 9 个 → 滚轮翻页（一次一页）。
func set_units(units: Array, short_names: Array = []) -> void:
	mode = MODE_UNITS
	_unit_total = units.size()
	# 换了一批单位 → 页号夹回有效范围（原来在第 2 页、新部队只有一页时别停在空白页）
	_page_start = clampi(_page_start, 0, maxi(0, _page_count() - 1) * UiLayoutRes.GRID_PAGE)
	_units = units
	_shorts = short_names
	_rebuild()


## 清空（没选中任何部队 / 选中的是区划或建筑）
func clear() -> void:
	_unit_total = 0
	_page_start = 0
	_units = []
	_shorts = []
	_apply([])


## 按当前页重排这一页的格子（单位模式：从 `_page_start` 起最多 9 个）。
## ⚠️ **翻页之后必须重排** —— `set_page()` 只改页号的话，屏幕上还是上一页的那 9 格
##    （这条是实测撞出来的：页号对了、格子没变）。
func _rebuild() -> void:
	var next: Array = []
	for k in UiLayoutRes.TROOP_GRID_SLOTS:
		var idx := _page_start + k
		if idx >= _units.size():
			break
		var u = _units[idx]
		var s := ""
		if idx < _shorts.size():
			s = String(_shorts[idx])
		if s == "":
			s = _first_char(u)
		next.append({
			"kind": "unit",
			"ref": u,
			"name": "" if u == null else String(u.name),
			"short": s,
			"number": 0,
		})
	_apply(next)


func _apply(next: Array) -> void:
	_cells = next
	visible = not next.is_empty()
	if _hover >= _cells.size():
		_hover = -1
	queue_redraw()


# ------------------------------------------------------------------
# 状态（给渲染与测试读）
# ------------------------------------------------------------------

## 画了几格（本页实际有数据的格子）
func cell_count() -> int:
	return _cells.size()


## 第 i 格是不是「有东西」的格子
func cell_filled(i: int) -> bool:
	return i >= 0 and i < _cells.size()


## 第 i 格里那个单位 / 将领对象
func unit_at(i: int):
	if not cell_filled(i):
		return null
	return _cells[i].get("ref", null)


## 第 i 格画出来的名字（「将领名称」那种两行字的第一行）
func cell_name(i: int) -> String:
	return "" if not cell_filled(i) else String(_cells[i].get("name", ""))


## 第 i 格方框里的短字
func cell_short(i: int) -> String:
	return "" if not cell_filled(i) else String(_cells[i].get("short", ""))


## 第 i 格是不是将领格
func cell_is_leader(i: int) -> bool:
	return cell_filled(i) and String(_cells[i].get("kind", "")) == "leader"


## 第 i 格的「x/y」文字（x = 该部队现有单位数含将领；y = 编制上限）。
## ⚠️ 第四轮改版后格子里**不再画**这一行（参考图上只有「将领名称」一行），
##    这里保留成接口只是怕别处还在读它 —— 它现在恒为空串。
func count_text(_i: int) -> String:
	return ""


## 第 i 格里的将领（单位格 → null）
func leader_at(i: int):
	if not cell_filled(i) or not cell_is_leader(i):
		return null
	return _cells[i].get("ref", null)


## 第 i 格的将领名字（兼容老接口；单位格 / 空格子 → ""）
func leader_name(i: int) -> String:
	return cell_name(i) if cell_is_leader(i) else ""


## 多选时列出几支部队（= 非展开的那些，最多 9 格）
func troop_count() -> int:
	return _cells.size() if mode == MODE_LEADERS else 0


## 单选时这支部队一共有几个单位
func unit_total() -> int:
	return _unit_total


## 一格画不下的那些单位一共几页（≤ 9 个时是 1 页）
func _page_count() -> int:
	if _unit_total <= 0:
		return 0
	return int(ceil(float(_unit_total) / float(UiLayoutRes.GRID_PAGE)))


func page_count() -> int:
	return _page_count()


## 现在停在第几页（0 起）
func page() -> int:
	return int(_page_start / UiLayoutRes.GRID_PAGE)


## 还有没有下一页 / 上一页（滚轮翻页的边界，测试与箭头提示都读它）
func has_more_pages() -> bool:
	return page() + 1 < _page_count()


func has_prev_pages() -> bool:
	return page() > 0


## 某个点落在哪一格上（只有**有东西**的格子才算命中；外面 → -1）
func cell_at_position(p: Vector2) -> int:
	for i in cell_count():
		if UiLayoutRes.troop_cell_rect(i).has_point(p):
			return i
	return -1


## 第 i 格右边那两行字画在哪（相对网格控件自身）。
## ★ `_draw_cell()` 取的就是它 —— 单独开一个读口是为了让测试能钉住这个坐标：
##   手玩报的「第二、三列的文字挤到第一列」就是这个 x 少了**这一格自己的偏移**，
##   而那种错**画一帧不会报错**，只有把坐标写成断言才抓得住（见 docs/pitfalls.md 5.41）。
func cell_text_origin(i: int) -> Vector2:
	return UiLayoutRes.troop_name_rect(i).position


# ------------------------------------------------------------------
# 鼠标：点格子 + 滚轮翻页
# ------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	var mb := event as InputEventMouseButton
	# 滚轮：只在一支部队、单位超过 9 个时翻页（一次一页）
	if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN or mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		if mode != MODE_UNITS or _page_count() <= 1:
			return
		var step := 1 if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1
		var before: int = page()
		set_page(before + step)
		if page() != before:
			accept_event()
		return
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var hit := cell_at_position(mb.position)
	if hit < 0:
		return
	# ★ 只抛「点了第几格」；换展开 / 切右栏由 hud.gd 决定（视图不碰选中状态）
	if cell_is_leader(hit):
		troop_activated.emit(int(_cells[hit].get("number", 0)))
	else:
		unit_activated.emit(_page_start + hit)
	accept_event()


## 翻到第 p 页（夹在 [0, 页数-1]；越界不动）
func set_page(p: int) -> void:
	var last := maxi(0, _page_count() - 1)
	_page_start = clampi(p, 0, last) * UiLayoutRes.GRID_PAGE
	_hover = -1
	if mode == MODE_UNITS:
		_rebuild()          # ★ 翻页要重排格子，不然屏幕上还是上一页那 9 格
	else:
		queue_redraw()


# ------------------------------------------------------------------
# 画
# ------------------------------------------------------------------

func _draw() -> void:
	draw_count += 1
	if _cells.is_empty():
		return
	var f: Font = font
	if f == null:
		f = get_theme_default_font()
	for i in cell_count():
		_draw_cell(i, f)
	_draw_page_hint(f)


## 一格：左边 40×40 方框（里面写短字）+ 右边**两行**字（与方框垂直居中）
##
## ★ 参考图就是这么排的（实测像素段）：
##   方框 x 415..454、y 915..954；第一行「将领名称」x 467..512、y 920..931；
##   第二行「1/11」x 467..481、y 942..948 —— 两行合起来正好在方框的竖直范围里。
func _draw_cell(i: int, f: Font) -> void:
	var av := UiLayoutRes.troop_avatar_rect(i)
	var leader_cell := cell_is_leader(i)
	draw_rect(av, UiStyleRes.BG_PRESSED if leader_cell else UiStyleRes.BG_EMPTY, true)
	# 描边：交战中的点亮成红，鼠标悬停的点亮成强调色，其余普通线色
	var edge: Color = UiStyleRes.LINE
	if _in_combat(unit_at(i)):
		edge = UiStyleRes.WARN
	elif i == _hover:
		edge = UiStyleRes.ACCENT_DIM
	draw_rect(av, edge, false, 2.0 if edge != UiStyleRes.LINE else 1.0)
	_draw_centered(f, cell_short(i), av, UiStyleRes.TEXT, UiStyleRes.FS_BODY)
	# 右边两行：名字 / x÷y（都用 FS_SMALL = 13 号字，与参考图的字号一致）
	# ★★ 位置必须带**这一格自己的偏移**：取 `cell_text_origin(i)`（= 这一格的左上 + 格内偏移）。
	#    ⛔ 这里踩过（手玩报的「选中多个单位或将领时，第二、三列的字挤到第一列」）：
	#       原先是 `Vector2(TROOP_NAME_X, av.position.y + TROOP_NAME_Y)` —— y 加了格子偏移、
	#       x 没加（TROOP_NAME_X 是**格子内**的量）⇒ 三列的名字全画在第 1 列的位置上。
	#       （只有 1 格时看着是对的，所以「只选一个单位」看不出来，多选才暴露。）
	var tp := cell_text_origin(i)
	var tw := UiLayoutRes.TROOP_NAME_W
	draw_string(f, Vector2(tp.x, tp.y + UiLayoutRes.TROOP_NAME_Y),
		_clip_text(f, cell_name(i), tw, UiStyleRes.FS_SMALL),
		HORIZONTAL_ALIGNMENT_LEFT, tw, UiStyleRes.FS_SMALL, UiStyleRes.TEXT)
	var line2 := cell_sub_text(i)
	if line2 != "":
		draw_string(f, Vector2(tp.x, tp.y + UiLayoutRes.TROOP_NAME2_Y),
			_clip_text(f, line2, tw, UiStyleRes.FS_SMALL),
			HORIZONTAL_ALIGNMENT_LEFT, tw, UiStyleRes.FS_SMALL, UiStyleRes.TEXT_DIM)


## 第二行小字：将领格写「x/y」（现有单位数/编制上限，手玩定的 y=11）；
## 单位格写「血量/上限」——参考图上那一行写的是该单位的数值。
func cell_sub_text(i: int) -> String:
	if not cell_filled(i):
		return ""
	if cell_is_leader(i):
		var units: Array = _cells[i].get("units", [])
		return "%d/%d" % [units.size(), UiLayoutRes.UNIT_CAP]
	var u = unit_at(i)
	if u == null:
		return ""
	return "%d/%d" % [int(round(float(u.hp))), int(round(float(u.hp_max)))]


## 把一行字截到 `max_w` 以内（装不下就砍尾巴并加省略号）。
##
## ★ 为什么不用 `draw_string(..., width, ...)` 顶掉：那个宽度参数**不保证裁剪**
##   （实测会照画出去），所以这里自己量、自己砍 —— 这样「装不装得下」是可控的。
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


## 翻页提示：左下角一支「还有上一页 / 下一页」的淡色箭头（只有真能翻时才画）
func _draw_page_hint(f: Font) -> void:
	if mode != MODE_UNITS or _page_count() <= 1:
		return
	var text := "%d/%d" % [page() + 1, _page_count()]
	draw_string(f, Vector2(0.0, UiLayoutRes.TROOP_GRID_H - 4.0), text,
		HORIZONTAL_ALIGNMENT_LEFT, 40.0, UiStyleRes.FS_TINY, UiStyleRes.TEXT_FAINT)
	var cx := 44.0
	var cy := UiLayoutRes.TROOP_GRID_H - 9.0
	if has_prev_pages():
		_draw_arrow(cx, cy, true)
	if has_more_pages():
		_draw_arrow(cx + 12.0, cy, false)


func _draw_arrow(x: float, cy: float, left: bool) -> void:
	var h := 4.0
	var w := 4.0
	var pts := PackedVector2Array()
	if left:
		pts.append(Vector2(x, cy))
		pts.append(Vector2(x + w, cy - h))
		pts.append(Vector2(x + w, cy + h))
	else:
		pts.append(Vector2(x + w, cy))
		pts.append(Vector2(x, cy - h))
		pts.append(Vector2(x, cy + h))
	draw_colored_polygon(pts, UiStyleRes.TEXT_FAINT)


## 首字（没有名字就写「?」；将领格由外面给短字，这里是兜底）
func _first_char(u) -> String:
	if u == null:
		return ""
	var n := String(u.name)
	return n.substr(0, 1) if n.length() > 0 else "?"


## 一个单位现在在不在交战（打人 / 拆建筑都算）—— 只读，不改
func _in_combat(u) -> bool:
	if u == null:
		return false
	if u.target != null and u.target.alive:
		return true
	if u.target_building != null and u.target_building.alive:
		return true
	return false


## 在一个矩形里居中画一行字（draw_string 的 pos 是**基线**）
func _draw_centered(f: Font, text: String, r: Rect2, color: Color, size: int) -> void:
	if text == "":
		return
	var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var baseline := r.position.y + r.size.y * 0.5 + float(size) * 0.5 - 2.0
	draw_string(f, Vector2(r.position.x + (r.size.x - w) * 0.5, baseline), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
