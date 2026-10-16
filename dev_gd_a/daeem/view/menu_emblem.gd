## menu_emblem.gd —— 进入界面正中那枚**纯几何**徽记（可旋转）
##
## 造型（参考图）：
##   · **外圈**：四段**弧块**，缺口落在正上 / 正下 / 正左 / 正右，每段弧居中在一条对角线上；
##   · **内圈**：一个圆，四个正方向上各被**啃掉一个矩形凹口**（与外圈缺口同向）。
## 全部是**细线轮廓**（不填色），零贴图。
##
## ★★ 两圈共用同一套「切法」，这是造型的来源：
##   把图形用 `x = ±k`、`y = ±k` 两组**平行线**切开 —— 外圈留四个角上的弧块
##   （切掉的是正上/正下/正左/正右那四块），内圈则把四个正方向上的断口用**矩形凹口**接起来。
##   ⇒ 弧块的端面是**竖直 / 水平直切**，不是径向切（径向切端面会斜掉，与参考图不是一回事）；
##     凹口的两道侧壁也平行于坐标轴（见 `_core_quadrant()`）。
##
## ★★ 动画：外圈四段弧**顺时针**缓慢转，内圈那个带凹口的圆**逆时针**缓慢转，
##   两圈**同速**（同一个 `_angle`，内圈取负）。转速 = `menu.emblem_spin_deg_per_sec`（度/秒）。
##   · 用一个角度 + `draw_set_transform()` 的两层旋转实现 —— 几何一帧都不重建；
##   · 动效总开关（`view/theme.gd` 的 `animations_enabled()`）关掉时**停住不动**
##     （不是转到 0：那会让徽记在开关的瞬间「跳」一下）。
##   ★ 内圈之所以要那四个凹口，就是为了让「它在转」看得见 —— 正圆转起来是看不出来的。
##
## 尺寸口径：`R = min(size.x, size.y) / 2 − 线宽`（描边留在框内，尺寸由调用方给 —— 见
## `view/start_screen.gd` 的两处用法：入场页 150、菜单标题条 112）。其余尺寸都是 `R` 的比例，
## 全部来自 `data/config.json` 的 `menu.emblem_*`（见 `ratios_from()`）。
##
## ★★ 为什么用 `_draw()` 画而不是做一张 .svg / .png：
##   1. 这套风格要的就是**线**：贴图缩到别的窗口尺寸会糊，或者得切 9-patch；
##      画出来的线在任何缩放下都是清晰的矢量图形；
##   2. 颜色必须跟着主题走（现在是金，换主题要一起变）—— 画出来的图形**取色于 theme.gd**；
##   3. 它要**转**：一条贴图 + 旋转会在非整数角度下重采样发虚，矢量线不会。
##
## ★ 几何由 `core_outline()` / `arc_outlines()` 这两个**纯函数**算（不读配置、不碰节点），
##   `_draw()` 只负责摆比例与旋转。于是测试可以直接对着点集断言（见 tests/test_menu_emblem.gd）。
##
## ⚠️ 它不吃鼠标（IGNORE）：点击是**整页**收的（见 view/start_screen.gd 文件头）。
extends Control

const ThemeRes = preload("res://view/theme.gd")
const ConfigRes = preload("res://logic/config.gd")

## 短边小于它就不画（这枚徽记在这个尺寸下已经没有能看的内容了）。
const MIN_SHORT_SIDE := 8.0
## 弧 / 圆的分段粒度：每段弦长约这么多像素（越小越圆，点也越多）。
const SEGMENT_LEN_PX := 3.0

## 兜底值。与 `data/config.json` 的 `menu.emblem_*` **逐位一致** ——
## 配置读不出来时也画得出、转得动同一枚徽记，而不是一片空白。
const DEFAULT_CORE_RATIO := 0.57
const DEFAULT_RING_RATIO := 0.77
const DEFAULT_GAP_RATIO := 0.158
const DEFAULT_CORE_SLOT_RATIO := 0.09
const DEFAULT_CORE_SLOT_DEPTH_RATIO := 0.05
const DEFAULT_LINE_WIDTH := 1.4
const DEFAULT_SPIN_DEG_PER_SEC := 6.0

## 外圈当前转角（弧度）。**正 = 顺时针**（屏幕坐标 y 向下，正角度的视觉方向就是顺时针）。
## 内圈画的是 `-_angle`，所以两者方向相反而速率相同。
var _angle: float = 0.0

## 配置读一次就存下来。
## ⚠️ 必须缓存：徽记现在**每帧重画**，而 `ConfigRes.load_default()` 每次都重读并解析整份
##    config.json —— 每帧解析一次 JSON 是不可接受的。缓存之后每帧只做几何 → 绘制。
var _ratios_cache: Dictionary = {}


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


# ------------------------------------------------------------------
# 动画
# ------------------------------------------------------------------

func _process(delta: float) -> void:
	if not ThemeRes.animations_enabled():
		return
	var spin: float = spin_deg_per_sec()
	if spin <= 0.0:
		return
	_angle = fmod(_angle + deg_to_rad(spin) * delta, TAU)
	queue_redraw()


## 外圈（四段弧块）的当前转角（弧度，正 = 顺时针）。
func arc_angle() -> float:
	return _angle


## 内圈（带凹口的圆）的当前转角（弧度，负 = 逆时针）—— 与外圈**反向、同速**。
func core_angle() -> float:
	return -_angle


## 把外圈角度直接设成某个值（弧度）。
## ★ 给「两枚徽记交接」用：入场页那枚从入场起就一直在转，而主界面那枚是另一个实例、
##   角度还停在 0 —— 切页那一刻把角度接过来，图形才不会**跳**一个角度
##   （见 view/start_screen.gd 的 `_play_intro_morph()`）。
func set_spin_angle(a: float) -> void:
	_angle = fmod(a, TAU)
	queue_redraw()


## 当前转速（度/秒）。0 = 不转。
func spin_deg_per_sec() -> float:
	return float(_ratios()["spin"])


func _draw() -> void:
	var s: float = minf(size.x, size.y)
	if s <= MIN_SHORT_SIDE:
		return
	var ratios: Dictionary = _ratios()
	var gold: Color = ThemeRes.accent()
	var line_w: float = float(ratios["line_width"])
	var center := Vector2(size.x * 0.5, size.y * 0.5)

	# 内圈：逆时针转
	draw_set_transform(center, core_angle(), Vector2.ONE)
	var core: PackedVector2Array = core_outline(s, ratios)
	if core.size() >= 2:
		draw_polyline(core, gold, line_w, true)

	# 外圈：顺时针转
	draw_set_transform(center, arc_angle(), Vector2.ONE)
	for pts in arc_outlines(s, ratios):
		draw_polyline(pts, gold, line_w, true)

	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# ------------------------------------------------------------------
# 参数（config.json 的 menu.emblem_*）
# ------------------------------------------------------------------

func _ratios() -> Dictionary:
	if _ratios_cache.is_empty():
		_ratios_cache = ratios_from(ConfigRes.load_default())
	return _ratios_cache


## 生效的参数。
##
## @param cfg 配置实例；传 null（或键写坏）时逐个退回 DEFAULT_*。
## @return `{"core","ring","gap","core_slot","core_slot_depth","line_width","spin"}` ——
##         前五个是**外半径的比例**，`line_width` 是像素，`spin` 是度/秒。
##
## ★★ 夹取**互相有依赖**，顺序不能换（这是它们唯一的约束来源）：
##   · `core` 先夹进 (0, 0.90]：它是内圈的半径比例；
##   · `ring`（弧块内缘）必须**明显大于** `core`，否则两圈会叠在一起 —— 看起来像画糊了；
##   · `gap`（外圈缺口半宽）必须**小于** `ring`，否则内弧会被整个切没，四段弧退化成四个扇形块；
##   · `core_slot`（凹口半宽）夹在 `core` 的一半以内、`core_slot_depth`（凹口深度）同理 ——
##     这两个上界保证「凹口的两道侧壁一定与圆相交、底一定落在圆内」，
##     于是无论配置被写成什么，画出来都是「圆被啃掉四个小口」，而不是畸形。
static func ratios_from(cfg) -> Dictionary:
	var core: float = DEFAULT_CORE_RATIO
	var ring: float = DEFAULT_RING_RATIO
	var gap: float = DEFAULT_GAP_RATIO
	var slot: float = DEFAULT_CORE_SLOT_RATIO
	var depth: float = DEFAULT_CORE_SLOT_DEPTH_RATIO
	var line_w: float = DEFAULT_LINE_WIDTH
	var spin: float = DEFAULT_SPIN_DEG_PER_SEC
	if cfg != null:
		core = clampf(cfg.num("menu.emblem_core_ratio", DEFAULT_CORE_RATIO), 0.05, 0.90)
		ring = clampf(cfg.num("menu.emblem_ring_ratio", DEFAULT_RING_RATIO), core + 0.03, 0.98)
		gap = clampf(cfg.num("menu.emblem_gap_ratio", DEFAULT_GAP_RATIO), 0.01, ring - 0.02)
		slot = clampf(cfg.num("menu.emblem_core_slot_ratio", DEFAULT_CORE_SLOT_RATIO),
			0.02, core * 0.5)
		depth = clampf(cfg.num("menu.emblem_core_slot_depth_ratio", DEFAULT_CORE_SLOT_DEPTH_RATIO),
			0.005, core * 0.5)
		line_w = clampf(cfg.num("menu.emblem_line_width", DEFAULT_LINE_WIDTH), 0.5, 4.0)
		spin = clampf(cfg.num("menu.emblem_spin_deg_per_sec", DEFAULT_SPIN_DEG_PER_SEC), 0.0, 90.0)
	return {
		"core": core, "ring": ring, "gap": gap,
		"core_slot": slot, "core_slot_depth": depth,
		"line_width": line_w, "spin": spin,
	}


# ------------------------------------------------------------------
# 几何（纯函数）
# ------------------------------------------------------------------

## 五个部分：下标 0 = 内圈（带凹口的圆），1~4 = 外圈四个象限的弧块。
## ★ 保留它是为了让「就 5 个部分」这类断言有一个入口；分层旋转用下面那两个函数。
static func part_outlines(short_side: float, ratios: Dictionary) -> Array:
	var out: Array = []
	var core: PackedVector2Array = core_outline(short_side, ratios)
	if core.is_empty():
		return out
	out.append(core)
	for pts in arc_outlines(short_side, ratios):
		out.append(pts)
	return out


## 内圈：一个**带四个矩形凹口**的圆，凹口开在正上 / 正下 / 正左 / 正右。
##
## 构造：圆被 `x = ±w`、`y = ±w` 两组平行线切成四个象限弧，断口之间用凹口接起来
## （弧 → 往里 → 沿轴向走一段叫「底」→ 再出来）。所以它不是一个正圆：
## 半径只在四个象限的弧上，四个正方向被啃掉一小块。
##
## ★ 实现是「推一个象限 + 它后面那道凹口」，再**旋转 90° 四次**拼成一整圈。
##   用旋转（而不是镜像）：遍历要绕着圆心一路走，镜像会把绕向翻掉。
static func core_outline(short_side: float, ratios: Dictionary) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var g: Dictionary = _geometry(short_side, ratios)
	if g.is_empty():
		return pts
	var base: PackedVector2Array = _core_quadrant(g["r_core"], g["slot"], g["floor"])
	for k in 4:
		var a: float = PI * 0.5 * float(k)
		for i in base.size():
			if k > 0 and i == 0:
				continue                      # 与上一块的末点重合，跳过
			pts.append(_rot(base[i], a))
	pts.append(pts[0])
	return pts


## 外圈：四个象限各一块弧（端面 = 竖直 / 水平直切，见 `_arc_piece()`）。
static func arc_outlines(short_side: float, ratios: Dictionary) -> Array:
	var out: Array = []
	var g: Dictionary = _geometry(short_side, ratios)
	if g.is_empty():
		return out
	# ★ 用镜像而不是四份角度公式：竖直 / 水平镜像会把「竖切面 / 横切面」照旧映射成竖 / 横切面，
	#   于是四条边界公式只需要推一次。
	for sx in [1.0, -1.0]:
		for sy in [1.0, -1.0]:
			out.append(_arc_piece(sx, sy, g))
	return out


## 一次把两圈都用到的长度算出来；尺寸 / 比例退化时返回空字典（调用方据此不画）。
##
## 量纲：`r_outer` / `r_core` / `r_inner` / `gap` / `slot` / `floor` 都是**像素**，
## `floor` 是凹口底到圆心的距离（= `r_core` 往里退 `core_slot_depth`）。
static func _geometry(short_side: float, ratios: Dictionary) -> Dictionary:
	if short_side <= MIN_SHORT_SIDE:
		return {}
	var line_w: float = float(ratios.get("line_width", DEFAULT_LINE_WIDTH))
	var r_outer: float = short_side * 0.5 - line_w
	if r_outer <= 0.0:
		return {}
	var r_core: float = r_outer * float(ratios.get("core", DEFAULT_CORE_RATIO))
	var r_inner: float = r_outer * float(ratios.get("ring", DEFAULT_RING_RATIO))
	var gap: float = r_outer * float(ratios.get("gap", DEFAULT_GAP_RATIO))
	var slot: float = r_outer * float(ratios.get("core_slot", DEFAULT_CORE_SLOT_RATIO))
	var depth: float = r_outer * float(ratios.get("core_slot_depth", DEFAULT_CORE_SLOT_DEPTH_RATIO))
	var floor := r_core - depth
	# 退化保护：比例写坏时宁可不画，也不要画出叠在一起 / 自交的线
	if r_core <= 0.0 or r_inner <= r_core or gap >= r_inner:
		return {}
	if slot <= 0.0 or slot >= r_core or floor <= 0.0 or floor >= sqrt(maxf(0.0, r_core * r_core - slot * slot)):
		return {}
	return {
		"r_outer": r_outer, "r_core": r_core, "r_inner": r_inner,
		"gap": gap, "slot": slot, "floor": floor,
	}


## 「右上象限的那段圆 + 它后面那道凹口」——内圈的四分之一，其余靠旋转拼出来。
##
## 右上象限的弧跨 `x ≥ slot`、`y ≤ −slot`（屏幕坐标 y 向下 ⇒ 极角从 `−acos(slot/r)` 到 `−asin(slot/r)`）。
## 弧在上方那端停住的点正是 `y = −slot` 与圆的交点，从那里接**右边那道凹口**：
##   (√(r²−slot²), −slot) → (floor, −slot) → (floor, +slot) → (√(r²−slot²), +slot)
## 前两步是凹口的两道**水平侧壁**与**竖直的底**（都平行于坐标轴），最后一步出来接到
## 下一个象限（它旋转 90° 之后的起点正好是这一点）。
static func _core_quadrant(r: float, slot: float, floor_x: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	_append_arc(pts, r, -_acos01(slot / r), -_asin01(slot / r))
	var edge: float = sqrt(maxf(0.0, r * r - slot * slot))
	pts.append(Vector2(floor_x, -slot))
	pts.append(Vector2(floor_x, slot))
	pts.append(Vector2(edge, slot))
	return pts


## 一块弧的闭合轮廓（先在「右上方」那块上推，再按 (sx, sy) 镜像）。
##
## 右上那块的两条约束是 `x ≥ gap`、`y ≤ −gap`：
##   · 外弧跨的极角从 `−acos(gap/R)`（与竖切面相交那一端）到 `−asin(gap/R)`（与横切面相交那一端）；
##   · 内弧同两端的极角把 `R` 换成 `r`，并且**反向**走 —— 这样内弧的起点正好接在横切面上、
##     终点与起点之间的那条弦正好是竖切面，闭合轮廓就自洽了（不需要额外塞角点）。
static func _arc_piece(sx: float, sy: float, g: Dictionary) -> PackedVector2Array:
	var r_outer: float = g["r_outer"]
	var r_inner: float = g["r_inner"]
	var gap: float = g["gap"]
	var pts := PackedVector2Array()
	# 1) 外弧：x = gap 那一端 → y = -gap 那一端
	_append_arc(pts, r_outer, -_acos01(gap / r_outer), -_asin01(gap / r_outer))
	# 2)（横切面 y = -gap：由下面内弧的起点自动接上）
	# 3) 内弧：y = -gap 那一端 → x = gap 那一端（方向与外弧相反）
	_append_arc(pts, r_inner, -_asin01(gap / r_inner), -_acos01(gap / r_inner))
	# 4) 竖切面 x = gap：内缘 → 外缘 = 回到起点（闭合）
	pts.append(pts[0])
	# 5) 镜像到目标象限（顺带把遍历方向翻过来 —— 轮廓线不关心绕向）
	if sx < 0.0 or sy < 0.0:
		for i in pts.size():
			pts[i] = Vector2(pts[i].x * sx, pts[i].y * sy)
	return pts


## 往 `pts` 追加一段弧（从极角 from 到 to，允许 from > to ⇒ 反向走）。
static func _append_arc(pts: PackedVector2Array, radius: float, from: float, to: float) -> void:
	var span: float = absf(to - from)
	var seg: int = _segments(radius, span)
	for i in seg + 1:
		var a: float = lerpf(from, to, float(i) / float(seg))
		pts.append(Vector2(radius * cos(a), radius * sin(a)))


## 分段数：按弧长估，夹在 [2, 512]。
static func _segments(radius: float, span: float) -> int:
	return clampi(int(ceil(radius * span / SEGMENT_LEN_PX)), 2, 512)


## 把点绕原点转 `a` 弧度。
static func _rot(p: Vector2, a: float) -> Vector2:
	var c: float = cos(a)
	var s: float = sin(a)
	return Vector2(p.x * c - p.y * s, p.x * s + p.y * c)


## acos / asin 的**安全版**：先把参数夹进 [0, 1]。
## ★ 配置被人改坏（比如 gap 大于半径）时，asin 的参数会跑出定义域并得到 NaN，
##   而 NaN 会让整条折线消失得莫名其妙 —— 宁可画出一个不精确的角，也不要画不出来。
static func _acos01(v: float) -> float:
	return acos(clampf(v, 0.0, 1.0))


static func _asin01(v: float) -> float:
	return asin(clampf(v, 0.0, 1.0))
