## unit_roster.gd —— 详细信息左栏**上半**：当前展开的那支部队的详情
##
## 参考图这一段（横着一条线，左边第一个小方块、右边一串附属单位方块）：
##   第 1 格 ：**本段自己的那一格** —— 将领头像 24×24 方块 + 右边两行小字
##             「将领名称」/「x﹨y」（x = 该部队**现有单位数**（含将领）；y = **编制上限**，
##             手玩定为 11）
##   后面     ：该部队每个单位一个方块 —— **队长 40×40（大方块）、亲兵 20×20（小方块）**，
##             方块挨着排、**一行 10 个**（手玩点名），放不下的用**滚轮**横向滚动看
##             （需求原话：「可以鼠标滚轮滚动以显示更多单位」）。
##
## ★★ **本段不再单独画一个「将」大方块**（手玩原话：「在展开的部队那一行不需要额外显示
##    一个『将』，1333 的结构已经把『将』显示了」）：
##    最左边那一格就是下方网格里的同一种格子（小方块 + 名字首字，由 `_draw_leader_cell`
##    画），所以这里不重复画头像。
##
## ★ 纯表现：只读 `world.units` 与单位上的渲染标志（selected / target / hp），
##   从不写任何逻辑状态。分组与「展开哪一支」由 hud/detail_panel 决定。
## ★ 部队是**算出来的**（`world.team_leader` / `is_team_leader`），没有 Squad 对象 ——
##   与 view/squad_panel.gd 走的是同一套判据，两边不会漂开。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const FactionRes = preload("res://logic/faction.gd")

var world = null
## 中文字体（Godot 默认字体没有 CJK 字形 —— 不传就会画成方框）。
## 与 view/zone_view.gd 一样由外面塞进来（hud 建它的时候给）。
var font: Font = null

## 点了方块行里的第 k 个方块（k 从 0 起；0 = 队长）。
## ★ 手玩规则：「玩家点击了左栏中展开部队的单位，则切换详情至这个单位」——
##   所以这一层只报「点了第几个」，由 hud.gd 决定右栏换成谁（视图不碰选中状态）。
signal block_activated(k: int)

## 当前展开的那支部队：{"leader": 队长单位或 null, "number": 部队编号(0=没编号), "units": [...]}
var _troop: Dictionary = {}
## 第一格右边那行小字（「将领名称」——参考图上写的就是这个，不是将领真名）
var _label_text: String = ""
## 方块行的横向滚动偏移（0 = 从头开始）。滚轮往下 = 往右看（露出后面的单位）
var _scroll: float = 0.0
## 画过几帧（给测试用：无头下 `_draw` 里的错误不会让测试失败，所以盯一下它真的跑了）
var draw_count: int = 0


func setup(p_world, p_font: Font = null) -> void:
	world = p_world
	font = p_font
	name = "UnitRoster"
	# ★ 要收鼠标：滚轮看更多单位 + **点某个方块 = 右栏切到那个单位**（手玩规则）。
	#   但它**不吃**没落在方块上的左键（照样穿给地图，见 _gui_input）。
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	custom_minimum_size = Vector2(UiLayoutRes.DETAIL_LEFT_W, UiLayoutRes.ROSTER_DETAIL_H)
	visible = false


# ------------------------------------------------------------------
# 刷新（每帧由 detail_panel 喂）
# ------------------------------------------------------------------

## @param troop null = 没有展开任何部队（整块收起来）
## @param leader_name_text 第一格右边那行小字（手玩原话：参考图上写的就是「将领名称」，
##        所以 hud 传的是这个固定文案，而不是将领的真名）
func set_troop(troop, leader_name_text: String = "") -> void:
	var next: Dictionary = {} if troop == null else troop
	# 换了一支部队 → 方块行回到最左边
	# ⚠️ `leader` 是个**单位对象**（不是 Dictionary），所以不能对它调 `.get()` ——
	#    这里直接比对象本身（同一个 world 里的单位对象是稳定的）。
	if next.get("leader", null) != _troop.get("leader", null):
		_scroll = 0.0
	_troop = next
	_label_text = leader_name_text
	var leader = _troop.get("leader", null)
	visible = leader != null
	_scroll = clampf(_scroll, 0.0, _max_scroll())
	queue_redraw()


## 方块行最远能滚多少（内容宽度 - 可见宽度；装得下就是 0）
func _max_scroll() -> float:
	return maxf(0.0, _blocks_width() - UiLayoutRes.ROSTER_BLOCKS_MAX_W)


## 这一行的方块总共占多宽
func _blocks_width() -> float:
	var n := unit_count()
	if n <= 0:
		return 0.0
	return UiLayoutRes.roster_block_right(n - 1) - _blocks_left()


## 方块行的左边缘（常量在 ui_layout 里）
func _blocks_left() -> float:
	return UiLayoutRes.ROSTER_BLOCKS_LEFT


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


## 本段第一格里写的名字（参考图上写的就是「将领名称」这个固定文案）
func leader_name() -> String:
	return _label_text


## 第一格里第二行小字：「x/y」（x = 现有单位数，y = 编制上限）
func count_text() -> String:
	return "%d/%d" % [unit_count(), UiLayoutRes.UNIT_CAP]


## 本段第一格的短字（与网格里的格子同一套口径：名字首字）
func leader_short() -> String:
	return _short_of(leader())


## 第 k 个方块里写的字（测试用；与画出来的一模一样）
func block_text(k: int) -> String:
	var u = unit_at(k)
	return "" if u == null else _short_of(u)


func unit_at(k: int):
	var units: Array = _troop.get("units", [])
	if k < 0 or k >= units.size():
		return null
	return units[k]


## 现在滚到哪了（方块行的横向偏移）
func scroll_offset() -> float:
	return _scroll


# ------------------------------------------------------------------
# 鼠标：滚轮横向看更多单位 + 左键点方块（右栏切到那个单位）
# ------------------------------------------------------------------

## 某个点落在第几个方块上（-1 = 没点到任何方块）。
##
## ⚠️ 从后往前找：方块有可能**叠着**（滚到一半时），后画的那个在上层。
## ⚠️ 只认**当前可见**的方块 —— 滚出去的那些不该被点到（它们画都没画）。
func block_at_position(p: Vector2) -> int:
	var n := unit_count()
	for k in range(n - 1, -1, -1):
		var r := UiLayoutRes.roster_block_rect(k)
		r.position.x -= _scroll
		if r.position.x + r.size.x < _blocks_left():
			continue
		if r.position.x > UiLayoutRes.DETAIL_LEFT_W:
			continue
		if r.has_point(p):
			return k
	return -1


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	# 滚轮：横向滚（露出后面的单位）
	var step := 0.0
	if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		step = UiLayoutRes.ROSTER_BLOCK_SMALL + UiLayoutRes.ROSTER_BLOCK_GAP
	elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
		step = -(UiLayoutRes.ROSTER_BLOCK_SMALL + UiLayoutRes.ROSTER_BLOCK_GAP)
	if step != 0.0:
		var before := _scroll
		_scroll = clampf(_scroll + step, 0.0, _max_scroll())
		if not is_equal_approx(before, _scroll):
			queue_redraw()
		accept_event()
		return
	# 左键：落在某个方块上才算「点了那个单位」；落在别处一律放行（穿给地图）
	if event.button_index == MOUSE_BUTTON_LEFT:
		var hit := block_at_position(event.position)
		if hit >= 0:
			block_activated.emit(hit)
			accept_event()


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
	var units: Array = _troop.get("units", [])
	for k in units.size():
		_draw_block(k, units[k], f)
	_draw_scroll_hint()


## 行尾的淡色箭头：还有方块在可视范围外时提示「可以滚」（手玩要求）。
##
## ★ 左右各一支：左边那支只在**已经往右滚过**时出现（提示能滚回去），
##   右边那支只在**后面还有方块**时出现。没越界就什么都不画。
## ★ 箭头的垂直中线跟着方块行（它在名字那一行**下面**），不是整段的中线。
func _draw_scroll_hint() -> void:
	if _max_scroll() <= 0.0:
		return
	var visible_right := _blocks_left() + UiLayoutRes.ROSTER_BLOCKS_MAX_W
	if _scroll > 0.0:
		_draw_arrow(_blocks_left() + 1.0, true)
	if _blocks_left() + _blocks_width() - _scroll > visible_right:
		_draw_arrow(visible_right - 5.0, false)


## 一个小三角形（朝右 / 朝左），画在方块行的垂直中线上
func _draw_arrow(x: float, left: bool) -> void:
	var cy := UiLayoutRes.ROSTER_BLOCKS_TOP + UiLayoutRes.ROSTER_BLOCK_SMALL * 0.5
	var h := 5.0
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


## 左栏上半的**第 1 个方块**（展开那支部队的将领格）+ 它右边那一行文字。
##
## ★ 参考图的结构就是这样（放大 4 倍逐像素看过）：
##   方块 40×40 在左上角 → 它右边是「将领名称 1/11」那一行 → 文字下面才是单位小方块。
## ★ 这个方块**不是**「额外画的『将』大方块」：整段就它一个方块，它就是那支部队的将领格
##   （手玩原话：「1333 的结构已经把『将』显示了」—— 即它和网格里的格子是同一种东西）。
func _draw_leader_cell(f: Font) -> void:
	var l = leader()
	if l == null:
		return
	var av := UiLayoutRes.roster_cell_avatar_rect()
	draw_rect(av, UiStyleRes.BG_PRESSED, true)
	draw_rect(av, UiStyleRes.ACCENT if bool(l.selected) else UiStyleRes.LINE, false, 1.0)
	_draw_centered(f, _short_of(l), av, UiStyleRes.TEXT, UiStyleRes.FS_BODY)
	var tx := UiLayoutRes.ROSTER_CELL_TEXT_X
	# 「将领名称」与「1/11」是**同一行**（参考图里就是「将领名称 1/11」一行写在方块右边，
	# 与方块的中线齐平）。
	var baseline := UiLayoutRes.ROSTER_CELL_AVATAR * 0.5 + 5.0
	if _label_text != "":
		draw_string(f, Vector2(tx, baseline), _label_text,
			HORIZONTAL_ALIGNMENT_LEFT, UiLayoutRes.ROSTER_ID_W, UiStyleRes.FS_SMALL,
			UiStyleRes.TEXT)
	draw_string(f, Vector2(UiLayoutRes.ROSTER_COUNT_X, baseline), count_text(),
		HORIZONTAL_ALIGNMENT_LEFT, 40.0, UiStyleRes.FS_SMALL, UiStyleRes.TEXT_DIM)


## 后面那些方块（该部队的每一个单位，含队长）：底 + 血量 + 边框 + 短字
func _draw_block(k: int, u, f: Font) -> void:
	var r := UiLayoutRes.roster_block_rect(k)
	r.position.x -= _scroll
	# 滚出去 / 还没滚进来的方块直接跳过（不然会画到第一格那两行字上面）
	if r.position.x + r.size.x < _blocks_left() or r.position.x > UiLayoutRes.DETAIL_LEFT_W:
		return
	var hp_max := maxf(1.0, float(u.hp_max))
	var ratio := clampf(float(u.hp) / hp_max, 0.0, 1.0)
	draw_rect(r, UiStyleRes.BG_EMPTY, true)
	if ratio > 0.0:
		# 血量从**底边**往上填（与招募读条、区块占领条同一个方向，看着一致）
		var h := r.size.y * ratio
		draw_rect(Rect2(r.position.x, r.position.y + r.size.y - h, r.size.x, h),
			_hp_color(ratio), true)
	# 描边：交战中的点亮成红，选中的点亮成强调色，其余普通线色
	var edge: Color = UiStyleRes.LINE
	if _in_combat(u):
		edge = UiStyleRes.WARN
	elif bool(u.selected):
		edge = UiStyleRes.ACCENT
	draw_rect(r, edge, false, 1.0)
	# 短字（没有头像时期的占位）：居中画在方块里
	_draw_centered(f, _short_of(u), r, UiStyleRes.TEXT, UiStyleRes.FS_TINY)


## 三档血量色（见 ui_style.gd 的 HP_* 注释）
func _hp_color(ratio: float) -> Color:
	if ratio > 0.6:
		return UiStyleRes.HP_HIGH
	if ratio > 0.3:
		return UiStyleRes.HP_MID
	return UiStyleRes.HP_LOW


## 这个单位现在在交战吗（打人 / 拆建筑都算）—— 只读，不改。
func _in_combat(u) -> bool:
	if u == null:
		return false
	if u.target != null and u.target.alive:
		return true
	if u.target_building != null and u.target_building.alive:
		return true
	return false


## 方块里写的短字：将领 = 名字首字（「将」），其它兵种 = 招募表里的 short（「兵」）。
func _short_of(u) -> String:
	if u == null:
		return ""
	if world != null and world.is_team_leader(u):
		var n := String(u.name)
		return n.substr(0, 1) if n.length() > 0 else "将"
	if world != null and world.is_recruitable(String(u.kind)):
		return world.recruit_short_of(String(u.kind))
	var n2 := String(u.name)
	return n2.substr(0, 1) if n2.length() > 0 else "?"


## 在一个矩形里居中画一行字（draw_string 的 pos 是**基线**）
func _draw_centered(f: Font, text: String, r: Rect2, color: Color, size: int) -> void:
	if text == "":
		return
	var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var baseline := r.position.y + r.size.y * 0.5 + float(size) * 0.5 - 2.0
	draw_string(f, Vector2(r.position.x + (r.size.x - w) * 0.5, baseline), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
