## troop_grid.gd —— 详细信息**左栏下半**：3 行 × 3 列的可见窗口（可左右滑动）
##
## ★★ 本版按需求改了三件事：
##
##   ① **横向滑动**：下面 3×3 不是「一页 9 格」了，而是 3 行 × 3 列的**可见窗口**；
##      内容按**列**向右延伸（列优先，见 ui_layout.troop_cell_rect）。
##      · 手指拖动 / 鼠标按住拖动 = 自由滑（不吸附）；
##      · 鼠标滚轮 = **整页（9 格 = 3 列）**翻页；
##      · 内容不足 3 列时不能滑。
##
##   ② **部队图标 = 序号 + 士气背景**（view/icon_badge.gd）：
##      数字 1..9 / 第 10 支写 0，背景自下而上按士气填充、越低越矮、绿→红。
##      单个单位 / 建筑**没有纯色背景填充**，只有图标 + 底部血条。
##
##   ③ 多选部队与多选建筑**共用同一套逻辑**：
##      被聚焦的那一个画在左栏上半那一格（view/unit_roster.gd），其余画在这里。
##
## ★ 三种语义（mode）：
##
##   mode = LEADERS（**选中多支部队**）
##     画「其余选中部队」的**序号图标**（被聚焦的那支不在这里，它画在左栏上半）。
##     点一格 = 把聚焦换成它（`troop_activated(部队编号)`）。
##
##   mode = UNITS（**只选中一支**）
##     画这支部队的**单位**（含将领本人，将领排在第一个）。
##     点一格 = 右栏切到那个单位（`unit_activated(绝对下标)`）。
##     单位超过 9 个（编制上限 11）→ 横向滑动看剩下的。
##
##   mode = BUILDINGS（**选中了建筑**）
##     画「除聚焦（主选中）那一个之外的选中建筑」。
##     点一格 = 把右栏详情切到那个建筑（`building_activated(绝对下标)`）。
##
## ★ 纯表现：格子里的数据由外面算好递进来，这里只读；没得画时整块收起来。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const IconBadgeRes = preload("res://view/icon_badge.gd")
const ConfigRes = preload("res://logic/config.gd")

## 点了某一格里的**部队**（带部队编号，1 起；拿不到编号时是 0）
signal troop_activated(number: int)
## 点了某一格里的**单位**（带**绝对下标**：从这一批的第几个开始数）
signal unit_activated(index: int)
## 点了某一格里的**建筑**（带**绝对下标**）
signal building_activated(index: int)

## 三种语义（见文件头）
enum { MODE_LEADERS, MODE_UNITS, MODE_BUILDINGS }

## 拖动判定阈值（像素）。与 config 的 `ui.drag_scroll_min_px` 同一档：
## 低于它算「点一下」，高于它才算「在滑动」——否则手抖一下就会既滑又点。
const DEFAULT_DRAG_MIN_PX := 8.0

## 中文字体（Godot 默认字体没有 CJK 字形 —— 不传就会画成方框）
var font: Font = null

var mode: int = MODE_LEADERS

## 这一批**全部**格子：[{"kind": "troop"/"unit"/"building", "ref": 单位或建筑,
##   "icon": 方块里的字, "name": 显示名, "sub": 第二行（建筑才有）, "number": 部队编号}]
## ⚠️ 不再只装「本页 9 格」：滑动需要把整批都排出来（绘制时按 `_scroll_x` 偏移、屏幕外跳过）。
var _cells: Array = []
## 横向滚动偏移（像素，0 = 最左）
var _scroll_x: float = 0.0
## 鼠标停在第几格（-1 = 没停在任何格子上；滚动 / 拖动后清掉）
var _hover: int = -1
## 画过几帧（给测试用：无头下 `_draw` 里的错误不会让测试失败，所以盯一下它真的跑了）
var draw_count: int = 0
## 画过多少条**血量条**（同上：`_draw` 里的问题不会报错，只有留下一个可数的痕迹才钉得住）
var bar_draw_count: int = 0
## 因内容变化而真正 `queue_redraw()` 的次数（诊断：HUD 以 10Hz 喂同一批格子时不该增长）
var apply_redraws: int = 0
## 上一次真正应用时的**内容快照**（见 `_cells_signature`）。
## ⚠️ 不能直接比较 `ref.hp`：同一个对象被喂两次时两边读到的是同一个实时值，
##   掉血后仍然「相等」——必须存一份应用当时的快照。
var _cells_sig: String = "#none#"

## 拖动状态（鼠标与触摸共用：emulate_mouse_from_touch 会把手指变成鼠标事件）
var _pressing: bool = false
var _dragging: bool = false
var _press_x: float = 0.0
var _press_scroll: float = 0.0
var _press_cell: int = -1
var _drag_min_px: float = DEFAULT_DRAG_MIN_PX


func setup(p_font: Font = null) -> void:
	font = p_font
	name = "TroopGrid"
	# 要能点（换聚焦 / 切右栏到某个单位）与拖动，所以这里收鼠标；
	# 不可见时收不到事件，平时不挡别处。
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	custom_minimum_size = Vector2(UiLayoutRes.DETAIL_LEFT_W, UiLayoutRes.TROOP_GRID_H)
	visible = false
	# 拖动阈值跟 config 走（读不到就用同一个默认值）
	var cfg = ConfigRes.load_default()
	if cfg != null:
		_drag_min_px = maxf(1.0, float(cfg.drag_scroll_min_px))


# ------------------------------------------------------------------
# 刷新（每帧由 detail_panel 喂）
# ------------------------------------------------------------------

## @param troops 要画的部队（= 选中部队**去掉正在聚焦的那一支**）。
##        每项：[{"leader": 队长单位, "number": 部队编号, "units": [...]}]
func set_troops(troops: Array) -> void:
	mode = MODE_LEADERS
	var next: Array = []
	for t in troops:
		var leader = t.get("leader", null)
		var units: Array = t.get("units", [])
		next.append({
			"kind": "troop",
			"ref": leader,
			"icon": IconBadgeRes.troop_number_text(int(t.get("number", 0))),
			"name": "" if leader == null else String(leader.name),
			"sub": "",
			"number": int(t.get("number", 0)),
			"units": units,
		})
	_apply(next)


## @param units 唯一选中那支部队的**全部单位**（第一个是队长）。
##        `short_names` 与它一一对应（方框里的短字，由 detail_panel 用 world 算好）。
##        超过 9 个 → 横向滑动（滚轮按页 9 格、拖动自由滑）。
func set_units(units: Array, short_names: Array = []) -> void:
	mode = MODE_UNITS
	var next: Array = []
	for idx in units.size():
		var u = units[idx]
		var s := ""
		if idx < short_names.size():
			s = String(short_names[idx])
		if s == "":
			s = _first_char(u)
		next.append({
			"kind": "unit",
			"ref": u,
			"icon": s,
			"name": "" if u == null else String(u.name),
			"sub": "",
			"number": 0,
		})
	_apply(next)


## @param entries 要画的建筑（= 选中的建筑**去掉正在聚焦（主选中）的那一个**），每项：
##        {"ref": 建筑, "name": 显示名, "short": 方框里的短字, "sub": 第二行（血量 x/y）}
##        超过 9 个 → 与「单选部队的单位」同一条横滑规则。
func set_buildings(entries: Array) -> void:
	mode = MODE_BUILDINGS
	var next: Array = []
	for e in entries:
		next.append({
			"kind": "building",
			"ref": e.get("ref", null),
			"icon": String(e.get("short", "")),
			"name": String(e.get("name", "")),
			"sub": String(e.get("sub", "")),
			"number": 0,
		})
	_apply(next)


## 清空（没选中任何部队 / 选中的是区划）
func clear() -> void:
	_scroll_x = 0.0
	_apply([])


func _apply(next: Array) -> void:
	# ★★ 内容没变就不重画：HUD 的详细信息槽位每 100ms 会把同一批格子重新喂进来，
	#    无条件 `queue_redraw()` 会让这 9 格每 100ms 重排/重画一次（手机上就是尖峰）。
	#    ⚠️ 血量 / 士气不在字典里（绘制时从 `ref` 现读），所以也必须参与比较，
	#       否则掉血后血条会停在旧值上。
	var sig := _cells_signature(next)
	if sig == _cells_sig:
		# ⚠️ 可见性仍要纠正：首次 `clear()` 时 `_cells` 本来就是空的，
		#    若直接 return，`visible` 会停在默认的 true（一个看不见内容的控件抢鼠标）。
		visible = not next.is_empty()
		if _hover >= _cells.size():
			_hover = -1
		return
	# ★ 换了一批东西（另一支部队 / 另一批建筑）→ 回到最左；
	#   同一批只是血量在变 → 保留玩家当前滑到的位置。
	var old_first = _cells[0].get("ref", null) if not _cells.is_empty() else null
	var new_first = next[0].get("ref", null) if not next.is_empty() else null
	if old_first != new_first:
		_scroll_x = 0.0
	_cells_sig = sig
	_cells = next
	_scroll_x = clampf(_scroll_x, 0.0, _max_scroll_x())
	visible = not next.is_empty()
	if _hover >= _cells.size():
		_hover = -1
	apply_redraws += 1
	queue_redraw()


## 这一批格子「画出来会是什么样」的快照。
##
## ★ 必须把**实时读出来的血量 / 士气 / 编制数**也拼进去：它们不在字典里，
##   而是绘制时从 `ref` 现读。只比字典字段的话，掉血后同一个 `ref` 前后「相等」，
##   血条就会停在旧值上（实测被 test_ui 抓到）。
func _cells_signature(next: Array) -> String:
	var parts: PackedStringArray = []
	parts.resize(next.size())
	for i in next.size():
		var a: Dictionary = next[i]
		var ref = a.get("ref", null)
		var hp := -1.0
		var hp_max := -1.0
		var morale := -1.0
		if ref != null:
			var v = ref.get("hp")
			if v != null:
				hp = float(v)
			var vm = ref.get("hp_max")
			if vm != null:
				hp_max = float(vm)
			if ref.has_method("morale_ratio"):
				morale = float(ref.morale_ratio())
		parts[i] = "%s|%d|%s|%s|%s|%d|%d|%.4f|%.4f|%.4f" % [
			String(a.get("kind", "")),
			ref.get_instance_id() if ref != null else 0,
			String(a.get("icon", "")), String(a.get("name", "")),
			String(a.get("sub", "")), int(a.get("number", 0)),
			(a.get("units", []) as Array).size(),
			hp, hp_max, morale]
	return "\n".join(parts)


# ------------------------------------------------------------------
# 状态（给渲染与测试读）
# ------------------------------------------------------------------

## 这一批一共有几格（**不只是本屏**：滑动时全部都在 `_cells` 里）
func cell_count() -> int:
	return _cells.size()


## 第 i 格是不是「有东西」的格子
func cell_filled(i: int) -> bool:
	return i >= 0 and i < _cells.size()


## 第 i 格里那个单位 / 将领 / 建筑对象
func unit_at(i: int):
	if not cell_filled(i):
		return null
	return _cells[i].get("ref", null)


## 第 i 格画出来的名字（「将领名称」那种两行字的第一行）
func cell_name(i: int) -> String:
	return "" if not cell_filled(i) else String(_cells[i].get("name", ""))


## 第 i 格方框里的字（部队 = 序号；单位 / 建筑 = 名字首字）
func cell_short(i: int) -> String:
	return "" if not cell_filled(i) else String(_cells[i].get("icon", ""))


## 第 i 格的类型（"troop" / "unit" / "building"；空格 → ""）
func cell_kind(i: int) -> String:
	return "" if not cell_filled(i) else String(_cells[i].get("kind", ""))


## 第 i 格是不是**部队**格（多选部队时，其余部队都画成部队图标）
func cell_is_leader(i: int) -> bool:
	return cell_filled(i) and cell_kind(i) == "troop"


## 第 i 格是不是建筑格
func cell_is_building(i: int) -> bool:
	return cell_filled(i) and cell_kind(i) == "building"


## 第 i 格里的建筑（不是建筑格 → null）
func building_at(i: int):
	if not cell_is_building(i):
		return null
	return _cells[i].get("ref", null)


## 兼容老接口：第四轮之后格子里不再画「x/y」这一行（现在统一走 `cell_sub_text()`）。
func count_text(_i: int) -> String:
	return ""


## 第 i 格里的部队队长（不是部队格 → null）
func leader_at(i: int):
	if not cell_filled(i) or not cell_is_leader(i):
		return null
	return _cells[i].get("ref", null)


## 第 i 格的部队名字（兼容老接口；非部队格 → ""）
func leader_name(i: int) -> String:
	return cell_name(i) if cell_is_leader(i) else ""


## 多选时列出几支部队（= 非聚焦的那些）
func troop_count() -> int:
	return _cells.size() if mode == MODE_LEADERS else 0


## 这一批里有几个建筑格（建筑模式）
func building_count() -> int:
	if mode != MODE_BUILDINGS:
		return 0
	return _cells.size()


## 这一批一共有几个（翻页 / 滑动用）
func unit_total() -> int:
	return _cells.size()


## 内容一共占几列（一列 3 格）
func content_columns() -> int:
	if _cells.is_empty():
		return 0
	return int(ceil(float(_cells.size()) / float(UiLayoutRes.TROOP_GRID_ROWS)))


## 一页 = 3 列 × 3 行 = 9 格（滚轮翻页的步长）
func _page_stride() -> float:
	return float(UiLayoutRes.TROOP_GRID_COLS * UiLayoutRes.TROOP_CELL_W)


## 最多能滚多远（像素；内容装得下时是 0）
func _max_scroll_x() -> float:
	return UiLayoutRes.troop_grid_max_scroll(_cells.size())


## 一共几页（≤ 3 列时是 1 页；没内容时是 0）
func _page_count() -> int:
	if _cells.is_empty():
		return 0
	return int(ceil(float(content_columns()) / float(UiLayoutRes.TROOP_GRID_COLS)))


func page_count() -> int:
	return _page_count()


## 现在停在第几页（0 起）。
## ★ 拖动是自由滑的，页码按「离哪一页的停靠位置最近」算 —— 这样滚轮翻页之后
##   `page()` 一定等于目标页，而随手拖到半路也不会在页码上乱跳。
func page() -> int:
	if _page_count() <= 0:
		return 0
	var best := 0
	var best_d := INF
	for p in _page_count():
		var target: float = minf(float(p) * _page_stride(), _max_scroll_x())
		var d: float = absf(_scroll_x - target)
		if d < best_d:
			best_d = d
			best = p
	return best


## 还有没有下一页 / 上一页（滚轮翻页的边界，箭头提示也读它）
func has_more_pages() -> bool:
	return page() + 1 < _page_count()


func has_prev_pages() -> bool:
	return page() > 0


## 当前横向滚动偏移（像素，0 = 最左；测试读它）
func scroll_x() -> float:
	return _scroll_x


## 当前最多能滚多远（像素；0 = 内容装得下）
func max_scroll_x() -> float:
	return _max_scroll_x()


## 某个点落在哪一格上（只有**有东西**的格子才算命中；外面 → -1）。
## ★ 这里要**加上滚动偏移**再算：滚动之后格子已经不在原来的固定坐标上了。
func cell_at_position(p: Vector2) -> int:
	if _cells.is_empty():
		return -1
	var local := p + Vector2(_scroll_x, 0.0)
	if local.y < 0.0 or local.y >= UiLayoutRes.TROOP_GRID_H:
		return -1
	var row: int = int(floor(local.y / UiLayoutRes.TROOP_CELL_H))
	var col: int = int(floor(local.x / UiLayoutRes.TROOP_CELL_W))
	if row < 0 or row >= UiLayoutRes.TROOP_GRID_ROWS or col < 0:
		return -1
	var idx: int = col * UiLayoutRes.TROOP_GRID_ROWS + row
	if idx >= _cells.size():
		return -1
	var cell := UiLayoutRes.troop_cell_rect(idx)
	# 每列右边留了 4px 的缝（`TROOP_CELL_W - 4`）：落在缝上不算点到格子
	if local.x >= cell.position.x + cell.size.x:
		return -1
	return idx


## 第 i 格右边那两行字画在哪（相对网格控件自身、**不含滚动偏移**）。
## ★ `_draw_cell()` 取的就是它 —— 单独开一个读口是为了让测试能钉住这个坐标：
##   手玩报的「第二、三列的文字挤到第一列」就是这个 x 少了**这一格自己的偏移**，
##   而那种错**画一帧不会报错**，只有把坐标写成断言才抓得住（见 docs/pitfalls.md 5.41）。
func cell_text_origin(i: int) -> Vector2:
	return UiLayoutRes.troop_name_rect(i).position


# ------------------------------------------------------------------
# 鼠标：点格子 + 拖动横滚 + 滚轮翻页
# ------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		# 滚轮：整页（9 格 = 3 列）翻页
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN or mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			if _page_count() <= 1:
				return
			var step := 1 if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1
			var before: int = page()
			set_page(before + step)
			if page() != before:
				accept_event()
			return
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_pressing = true
			_dragging = false
			_press_x = mb.position.x
			_press_scroll = _scroll_x
			_press_cell = cell_at_position(mb.position)
			return
		# ---- 抬起 ----
		var was_drag: bool = _dragging
		_pressing = false
		_dragging = false
		var pressed_cell: int = _press_cell
		_press_cell = -1
		if was_drag:
			# 拖动结束：吃掉这次释放，免得「滑一下」被当成「点一下」
			accept_event()
			return
		var hit: int = cell_at_position(mb.position)
		if hit >= 0 and hit == pressed_cell:
			_emit_cell(hit)
			accept_event()
		return

	if event is InputEventMouseMotion and _pressing:
		var motion := event as InputEventMouseMotion
		var dx: float = motion.position.x - _press_x
		if not _dragging and absf(dx) >= _drag_min_px and _max_scroll_x() > 0.0:
			_dragging = true
		if _dragging:
			var next: float = clampf(_press_scroll - dx, 0.0, _max_scroll_x())
			if not is_equal_approx(next, _scroll_x):
				_scroll_x = next
				_hover = -1
				queue_redraw()
			accept_event()


## 点了第 i 格：按类型抛对应的信号（视图不认识「聚焦 / 选中」这些概念）
func _emit_cell(i: int) -> void:
	if not cell_filled(i):
		return
	match cell_kind(i):
		"troop":
			troop_activated.emit(int(_cells[i].get("number", 0)))
		"building":
			building_activated.emit(i)
		_:
			unit_activated.emit(i)


## 翻到第 p 页（夹在 [0, 页数-1]；越界不动）。
## ★ 滚动是像素量的：页码 × 一页宽 = 目标偏移，再夹到「内容能滚到的最远处」。
func set_page(p: int) -> void:
	if _page_count() <= 0:
		_scroll_x = 0.0
		return
	var last := maxi(0, _page_count() - 1)
	var target: float = float(clampi(p, 0, last)) * _page_stride()
	_scroll_x = clampf(target, 0.0, _max_scroll_x())
	_hover = -1
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
		var c := UiLayoutRes.troop_cell_rect(i)
		# 整列都在屏幕左边之外 → 跳过；已经在可见区右边之外 → 后面更远，直接停
		if c.position.x + c.size.x - _scroll_x < 0.0:
			continue
		if c.position.x - _scroll_x >= UiLayoutRes.TROOP_GRID_VIEW_W:
			break
		_draw_cell(i, f)
	_draw_page_hint(f)


## 一格：左边 40×40 图标 + 右边**两行**字（与图标垂直居中）
##
## ★ 图标本身交给 view/icon_badge.gd：
##   部队 = 序号 + 士气填充；单位 / 建筑 = 首字、**无背景填充**。两者都带底部血条。
func _draw_cell(i: int, f: Font) -> void:
	var origin := UiLayoutRes.troop_cell_rect(i).position - Vector2(_scroll_x, 0.0)
	var av := Rect2(origin, Vector2(UiLayoutRes.TROOP_AVATAR, UiLayoutRes.TROOP_AVATAR))
	var kind := cell_kind(i)
	# 描边：交战中的点亮成红，鼠标悬停的点亮成强调色，其余普通线色
	var edge: Color = UiStyleRes.line()
	if _in_combat(unit_at(i)):
		edge = UiStyleRes.warn()
	elif i == _hover:
		edge = UiStyleRes.accent_dim()
	# 部队序号比单位首字稍大一号（数字要一眼认出是哪一支）
	var font_size: int = UiStyleRes.FS_TITLE if kind == "troop" else UiStyleRes.FS_BODY
	IconBadgeRes.draw(self, f, av, kind, cell_short(i), _morale_ratio_at(i),
		_hp_ratio_at(i), true, font_size, edge,
		2.0 if edge != UiStyleRes.line() else 1.0)
	bar_draw_count += 1
	# 右边两行：名字 / x÷y（都用 FS_SMALL = 13 号字，与参考图的字号一致）
	# ★★ 位置必须带**这一格自己的偏移**：取 `cell_text_origin(i)`（= 这一格的左上 + 格内偏移）。
	#    ⛔ 这里踩过（手玩报的「选中多个单位或将领时，第二、三列的字挤到第一列」）：
	#       原先是 `Vector2(TROOP_NAME_X, av.position.y + TROOP_NAME_Y)` —— y 加了格子偏移、
	#       x 没加（TROOP_NAME_X 是**格子内**的量）⇒ 三列的名字全画在第 1 列的位置上。
	#       （只有 1 格时看着是对的，所以「只选一个单位」看不出来，多选才暴露。）
	var tp := Vector2(origin.x + UiLayoutRes.TROOP_NAME_X,
		origin.y + UiLayoutRes.TROOP_NAME_Y)
	var tw := UiLayoutRes.TROOP_NAME_W
	draw_string(f, tp,
		_clip_text(f, cell_name(i), tw, UiStyleRes.FS_SMALL),
		HORIZONTAL_ALIGNMENT_LEFT, tw, UiStyleRes.FS_SMALL, UiStyleRes.text())
	var line2 := cell_sub_text(i)
	if line2 != "":
		draw_string(f, Vector2(tp.x, origin.y + UiLayoutRes.TROOP_NAME2_Y),
			_clip_text(f, line2, tw, UiStyleRes.FS_SMALL),
			HORIZONTAL_ALIGNMENT_LEFT, tw, UiStyleRes.FS_SMALL, UiStyleRes.text_dim())


## 第 i 格图标的血量比例（0..1）——血条按它填充。
## ref 是单位或建筑（两者都有 `hp_ratio()`）；空格子 / 拿不到对象 → 1.0（不画成空条）。
func _hp_ratio_at(i: int) -> float:
	if not cell_filled(i):
		return 1.0
	var r = _cells[i].get("ref", null)
	if r == null:
		return 1.0
	return float(r.hp_ratio())


## 第 i 格图标的**士气**比例（0..1）——只有部队格会用（单位 / 建筑不画背景）。
## 部队的士气是整支部队共享的，取队长身上的值；拿不到对象 → 1.0。
func _morale_ratio_at(i: int) -> float:
	if not cell_filled(i) or cell_kind(i) != "troop":
		return 1.0
	var r = _cells[i].get("ref", null)
	if r == null or not r.has_method("morale_ratio"):
		return 1.0
	return float(r.morale_ratio())


## 第二行小字：部队格写「x/y」（现有单位数/编制上限）；
## 单位格写「血量/上限」；建筑格由 hud 算好递进来（同样是「血量/上限」）。
func cell_sub_text(i: int) -> String:
	if not cell_filled(i):
		return ""
	if cell_is_building(i):
		return String(_cells[i].get("sub", ""))
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
	if _page_count() <= 1:
		return
	var text := "%d/%d" % [page() + 1, _page_count()]
	draw_string(f, Vector2(0.0, UiLayoutRes.TROOP_GRID_H - 4.0), text,
		HORIZONTAL_ALIGNMENT_LEFT, 40.0, UiStyleRes.FS_TINY, UiStyleRes.text_faint())
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
	draw_colored_polygon(pts, UiStyleRes.text_faint())


## 首字（没有名字就写「?」；部队格由外面给序号，这里是兜底）
func _first_char(u) -> String:
	if u == null:
		return ""
	var n := String(u.name)
	return n.substr(0, 1) if n.length() > 0 else "?"


## 一个单位现在在不在交战（打人 / 拆建筑都算）—— 只读，不改。
## ⚠️ 用 `get()` 读属性：这一格现在也可能是**建筑**（建筑没有 `target` / `target_building`
##    这两个字段，直接点出来会报「Invalid get index」），`get()` 读不到就给 null。
func _in_combat(u) -> bool:
	if u == null:
		return false
	var t = u.get("target")
	if t != null and t.alive:
		return true
	var tb = u.get("target_building")
	if tb != null and tb.alive:
		return true
	return false
