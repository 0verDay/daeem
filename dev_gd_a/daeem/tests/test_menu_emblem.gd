## test_menu_emblem.gd —— ★★ 进入界面那枚徽记的几何与旋转
##
## 它好不好看没法用断言证明（那要人眼看），但**几何**可以钉死，而几何错了图形一定不对：
##   · 外圈：就 4 段弧，各占一个象限（不重叠、不遗漏），端面是**竖直 / 水平直切**
##     （不是径向切 —— 这是从参考图量出来的结论），缺口真的开在正上/正下/正左/正右；
##   · 内圈：一个圆，四个正方向上各被啃掉一个**矩形凹口**（4 道底 + 8 道侧壁，其余都是弧），
##     凹口不越出圆外、方向与外圈四个缺口同向；
##   · 所有点都留得出描边余量（不会被控件裁掉）；
##   · 旋转：外圈顺时针、内圈逆时针、**同速**，转速来自 config，关掉动效就停住；
##   · 配置写坏时夹取仍然让它画得出完整的图形（而不是畸形 / 空白）。
##
## ★ 全部是**纯函数**断言（`core_outline()` / `arc_outlines()` / `ratios_from()`）
##   加一个 `_process()` 直接推进，不需要游戏场景、不需要跑帧。
extends "res://tests/test_case.gd"

const MenuEmblemRes = preload("res://view/menu_emblem.gd")
const ThemeRes = preload("res://view/theme.gd")

## 入场页那枚的尺寸（menu.emblem_size = 150），也是断言里用的基准短边。
const SHORT_SIDE := 150.0
## 判定「这一段是轴对齐的」的容差：真切面 / 侧壁是精确的 0（浮点误差 ~1e-14），
## 而弧上的每一段两个方向都差着 0.1 以上。
const AXIS_EPS := 0.001


func _initialize() -> void:
	_case_name = "menu_emblem"
	run_all(_cases)


func _cases() -> void:
	_test_config_values()
	_test_config_clamps()
	_test_defaults_without_config()
	_test_node_contract()
	_test_five_parts()
	_test_core_notches()
	_test_arc_radii()
	_test_gaps_are_open()
	_test_four_quadrants()
	_test_cut_faces_are_axis_aligned()
	_test_cut_planes_miss_the_center()
	_test_outlines_are_closed()
	_test_fits_inside_box()
	_test_too_small_draws_nothing()
	_test_spin()


# ------------------------------------------------------------------
# 参数（config.json 的 menu.emblem_*）
# ------------------------------------------------------------------

func _test_config_values() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	near(cfg.num("menu.emblem_core_ratio", -1.0), 0.57, 0.0001, "menu.emblem_core_ratio 读到了")
	near(cfg.num("menu.emblem_ring_ratio", -1.0), 0.77, 0.0001, "menu.emblem_ring_ratio 读到了")
	near(cfg.num("menu.emblem_gap_ratio", -1.0), 0.158, 0.0001, "menu.emblem_gap_ratio 读到了")
	near(cfg.num("menu.emblem_core_slot_ratio", -1.0), 0.09, 0.0001,
		"menu.emblem_core_slot_ratio 读到了")
	near(cfg.num("menu.emblem_core_slot_depth_ratio", -1.0), 0.08, 0.0001,
		"menu.emblem_core_slot_depth_ratio 读到了")
	near(cfg.num("menu.emblem_line_width", -1.0), 1.4, 0.0001, "menu.emblem_line_width 读到了")
	near(cfg.num("menu.emblem_spin_deg_per_sec", -1.0), 6.0, 0.0001,
		"menu.emblem_spin_deg_per_sec 读到了")

	var r: Dictionary = MenuEmblemRes.ratios_from(cfg)
	ok(r["core"] < r["ring"],
		"★★ 内圈在弧块内缘之内（%.2f < %.2f）—— 两圈不叠在一起" % [r["core"], r["ring"]])
	ok(r["gap"] < r["ring"],
		"★★ 缺口半宽小于弧块内缘半径（%.3f < %.2f）—— 否则内弧会被整个切没" % [r["gap"], r["ring"]])
	ok(r["core_slot"] < r["core"],
		"★★ 凹口半宽小于内圈半径（%.2f < %.2f）—— 否则凹口的两道侧壁碰不到圆" % [r["core_slot"], r["core"]])
	ok(r["core_slot_depth"] < r["core"],
		"★ 凹口深度小于内圈半径（%.2f < %.2f）" % [r["core_slot_depth"], r["core"]])
	ok(r["line_width"] > 0.0, "线宽是正的")
	ok(r["spin"] > 0.0, "转速是正的（%.1f 度/秒 = 一分钟 %.0f 圈）" % [r["spin"], 60.0 * r["spin"] / 360.0])


func _test_config_clamps() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	# 在**自己这一份**配置实例上把七个数写坏（不动磁盘上的文件），再看 ratios_from 的反应。
	var menu: Dictionary = cfg.data["menu"]
	menu["emblem_core_ratio"] = 0.99              # 想跟弧块内缘挤在一起
	menu["emblem_ring_ratio"] = 0.10              # 比内圈还小
	menu["emblem_gap_ratio"] = 0.95               # 缺口比内缘半径还宽
	menu["emblem_core_slot_ratio"] = 5.0          # 凹口比整个圆还宽
	menu["emblem_core_slot_depth_ratio"] = 9.9    # 把圆啃穿
	menu["emblem_line_width"] = -3.0              # 负线宽
	menu["emblem_spin_deg_per_sec"] = -4.0        # 负转速
	var r: Dictionary = MenuEmblemRes.ratios_from(cfg)
	ok(r["ring"] > r["core"],
		"★★ 弧块内缘被抬到内圈之外（%.2f > %.2f）—— 写坏也不会两圈重叠" % [r["ring"], r["core"]])
	ok(r["gap"] < r["ring"],
		"★★ 缺口半宽被压到内缘半径之内（%.2f < %.2f）—— 写坏也不会把内弧切没" % [r["gap"], r["ring"]])
	ok(r["core_slot"] <= r["core"] * 0.5,
		"★★ 凹口半宽夹在 core 的一半以内（%.2f ≤ %.2f）" % [r["core_slot"], r["core"] * 0.5])
	ok(r["core_slot_depth"] <= r["core"] * 0.5,
		"★★ 凹口深度同理（%.2f ≤ %.2f）—— 不会把内圈啃穿" % [r["core_slot_depth"], r["core"] * 0.5])
	ok(r["core"] <= 0.90, "内圈比例夹在上限内（%.2f）" % r["core"])
	ok(r["line_width"] > 0.0, "★ 负线宽被夹成正数（否则整枚图形画不出来）")
	ok(r["spin"] >= 0.0, "★ 负转速夹成 0（倒转不是靠负号表示的，见 arc_angle 那段注释）")

	ok(not MenuEmblemRes.core_outline(SHORT_SIDE, r).is_empty(),
		"★★ 夹完之后内圈仍画得出来（不是空白）")
	eq(MenuEmblemRes.arc_outlines(SHORT_SIDE, r).size(), 4, "★★ 夹完之后外圈仍是 4 段弧")
	eq(MenuEmblemRes.part_outlines(SHORT_SIDE, r).size(), 5,
		"★★ 写坏的配置夹完之后仍然画出 5 个部分（既不畸形、也不空白）")


func _test_defaults_without_config() -> void:
	var r: Dictionary = MenuEmblemRes.ratios_from(null)
	near(r["core"], MenuEmblemRes.DEFAULT_CORE_RATIO, 0.0001, "没有配置时用兜底的内圈比例")
	near(r["ring"], MenuEmblemRes.DEFAULT_RING_RATIO, 0.0001, "兜底的弧块内缘比例")
	near(r["gap"], MenuEmblemRes.DEFAULT_GAP_RATIO, 0.0001, "兜底的缺口比例")
	near(r["core_slot"], MenuEmblemRes.DEFAULT_CORE_SLOT_RATIO, 0.0001, "兜底的凹口半宽")
	near(r["core_slot_depth"], MenuEmblemRes.DEFAULT_CORE_SLOT_DEPTH_RATIO, 0.0001, "兜底的凹口深度")
	near(r["spin"], MenuEmblemRes.DEFAULT_SPIN_DEG_PER_SEC, 0.0001, "兜底的转速")
	eq(MenuEmblemRes.part_outlines(SHORT_SIDE, r).size(), 5,
		"★ 配置读不出来也照样画得出（不是一片空白）")


func _test_node_contract() -> void:
	var e = MenuEmblemRes.new()
	root.add_child(e)
	eq(e.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"★ 徽记不吃鼠标（点击是整页收的，见 view/start_screen.gd 文件头）")
	e.queue_free()


# ------------------------------------------------------------------
# 五个部分
# ------------------------------------------------------------------

func _test_five_parts() -> void:
	var parts: Array = _outlines()
	eq(parts.size(), 5, "★★ 就 5 个部分：一个内圈 + 四段弧块")
	if parts.size() != 5:
		return
	for i in parts.size():
		var pts: PackedVector2Array = parts[i]
		ok(pts.size() >= 3, "第 %d 个部分有足够的点（%d 个）" % [i, pts.size()])


## ★★ 内圈 = 一个圆 + 四个**矩形凹口**（开在正上/正下/正左/正右）。
##   判据：不越出圆外（凹口是往里啃）、真的啃进去了、且有且只有 4 道底 + 8 道侧壁。
func _test_core_notches() -> void:
	var r: Dictionary = MenuEmblemRes.ratios_from(require_config())
	var core: PackedVector2Array = MenuEmblemRes.core_outline(SHORT_SIDE, r)
	ok(not core.is_empty(), "内圈画得出来")
	if core.is_empty():
		return

	var r_core: float = _core_radius(r)
	var slot: float = _slot_px(r)
	var floor_d: float = _floor_px(r)

	var max_r := 0.0
	var min_r := 9999.0
	for p in core:
		max_r = maxf(max_r, p.length())
		min_r = minf(min_r, p.length())
	near(max_r, r_core, 0.01,
		"★★ 内圈最远处仍是半径 %.2f（凹口往里啃，不往外鼓）" % r_core)
	near(min_r, sqrt(floor_d * floor_d + slot * slot), 0.01,
		"★★ 最近处是凹口的两个内角 = √(底² + 半宽²)")
	ok(r_core - floor_d > 1.0,
		"★★ 凹口确实啃进了圆内（深 %.1f px）—— 不是画了个正圆" % (r_core - floor_d))

	var seg: Dictionary = _classify_axis_segments(core)
	var floors := 0
	var sides := 0
	var dirs: Dictionary = {}
	for e in (seg["vertical"] as Array) + (seg["horizontal"] as Array):
		var d: float = e["dist"]
		if absf(d - floor_d) < 0.01:
			floors += 1
			# 底的中点落在哪根轴上 ⇒ 这个凹口对着哪个正方向
			var mid: Vector2 = e["mid"]
			if absf(mid.x) < 0.01:
				dirs["+y" if mid.y > 0.0 else "-y"] = true
			elif absf(mid.y) < 0.01:
				dirs["+x" if mid.x > 0.0 else "-x"] = true
		elif absf(d - slot) < 0.01:
			sides += 1
	eq(floors, 4, "★★ 四个凹口各有一道「底」，离圆心 %.2f（= 半径 − 深度）" % floor_d)
	eq(sides, 8, "★★ 每个凹口两道侧壁，共 8 道，离圆心 %.2f（= 凹口半宽）" % slot)
	ok(int(seg["others"]) >= 40,
		"★ 其余 %d 段都是圆弧（四段象限弧）—— 内圈没有第三种笔画" % int(seg["others"]))
	eq(dirs.size(), 4, "★★ 四个凹口正对着正上 / 正下 / 正左 / 正右（与外圈四个缺口同向）")


func _test_arc_radii() -> void:
	var r: Dictionary = MenuEmblemRes.ratios_from(require_config())
	var parts: Array = _outlines()
	if parts.size() != 5:
		return
	var r_out: float = _outer_radius(r)
	var r_in: float = r_out * float(r["ring"])
	for i in range(1, 5):
		var lo := 9999.0
		var hi := 0.0
		for p in (parts[i] as PackedVector2Array):
			lo = minf(lo, p.length())
			hi = maxf(hi, p.length())
		near(hi, r_out, 0.05, "第 %d 块弧真的到外缘（最远 %.2f ≈ %.2f）" % [i, hi, r_out])
		near(lo, r_in, 0.05, "第 %d 块弧真的到内缘（最近 %.2f ≈ %.2f）" % [i, lo, r_in])
		ok(lo >= r_in - 0.01 and hi <= r_out + 0.01,
			"第 %d 块弧完全落在内缘与外缘之间 —— 它是「弧块」而不是扇形" % i)


func _test_gaps_are_open() -> void:
	var r: Dictionary = MenuEmblemRes.ratios_from(require_config())
	var parts: Array = _outlines()
	if parts.size() != 5:
		return
	var d: float = _gap_px(r)
	ok(d > 0.0, "缺口宽度是正的（%.2f px）" % d)
	for i in range(1, 5):
		var min_x := 9999.0
		var min_y := 9999.0
		for p in (parts[i] as PackedVector2Array):
			min_x = minf(min_x, absf(p.x))
			min_y = minf(min_y, absf(p.y))
		ok(min_x >= d - 0.01,
			"★★ 第 %d 块弧不碰竖直中轴（|x| 最小 %.2f ≥ 缺口半宽 %.2f）" % [i, min_x, d])
		ok(min_y >= d - 0.01,
			"★★ 第 %d 块弧不碰水平中轴（|y| 最小 %.2f ≥ %.2f）" % [i, min_y, d])


func _test_four_quadrants() -> void:
	var parts: Array = _outlines()
	if parts.size() != 5:
		return
	var seen: Dictionary = {}
	for i in range(1, 5):
		var pts: PackedVector2Array = parts[i]
		var sum := Vector2.ZERO
		for p in pts:
			sum += p
		var mean: Vector2 = sum / float(pts.size())
		var key := "%s,%s" % [_sign_key(mean.x), _sign_key(mean.y)]
		ok(not seen.has(key), "第 %d 块弧独占一个象限（%s），与前面的不重叠" % [i, key])
		seen[key] = i
	eq(seen.size(), 4, "★★ 四块弧正好铺满四个象限（不重叠、也不遗漏）")


## ★★ 每块弧的两道端面必须是**轴对齐的直线**（一道竖直、一道水平），
##   其余各段都是真弧（两个方向都差着）—— 这就是「用平行线切」而不是「径向切」。
func _test_cut_faces_are_axis_aligned() -> void:
	var parts: Array = _outlines()
	if parts.size() != 5:
		return
	for i in range(1, 5):
		var seg: Dictionary = _classify_axis_segments(parts[i])
		eq((seg["vertical"] as Array).size(), 1,
			"第 %d 块弧有一道**竖直**切面（正上 / 正下缺口那一侧）" % i)
		eq((seg["horizontal"] as Array).size(), 1,
			"第 %d 块弧有一道**水平**切面（正左 / 正右缺口那一侧）" % i)
		ok(int(seg["others"]) >= 8,
			"★ 第 %d 块弧其余 %d 段都是真弧 —— 端面是直切，不是径向切"
			% [i, int(seg["others"])])


## ★★ 两道切面的**延长线到圆心的距离 = 缺口半宽**，而不是 0。
##   径向切（端面沿半径方向）的延长线一定**过圆心** ⇒ 那个距离会是 0；
##   而我们从参考图量出来的是「用 x = ±d、y = ±d 这组**平行线**切」，距离必须正好是 d。
##   ⇒ 这一条是「平行线切 / 径向切」最直接的判据。
func _test_cut_planes_miss_the_center() -> void:
	var r: Dictionary = MenuEmblemRes.ratios_from(require_config())
	var parts: Array = _outlines()
	if parts.size() != 5:
		return
	var d: float = _gap_px(r)
	for i in range(1, 5):
		var seg: Dictionary = _classify_axis_segments(parts[i])
		for e in (seg["vertical"] as Array):
			near(e["dist"], d, 0.01,
				"第 %d 块弧的**竖直**切面离圆心 = 缺口半宽（径向切会是 0）" % i)
		for e in (seg["horizontal"] as Array):
			near(e["dist"], d, 0.01,
				"第 %d 块弧的**水平**切面离圆心 = 缺口半宽（径向切会是 0）" % i)


func _test_outlines_are_closed() -> void:
	var parts: Array = _outlines()
	for i in parts.size():
		var pts: PackedVector2Array = parts[i]
		v2_near(pts[0], pts[pts.size() - 1], 0.001, "第 %d 个部分是闭合的（首尾点重合）" % i)


func _test_fits_inside_box() -> void:
	var r: Dictionary = MenuEmblemRes.ratios_from(require_config())
	var parts: Array = _outlines()
	var half: float = SHORT_SIDE * 0.5
	var worst := 0.0
	for pts in parts:
		for p in (pts as PackedVector2Array):
			worst = maxf(worst, maxf(absf(p.x), absf(p.y)))
	ok(worst <= half,
		"★★ 整枚图形都留在控件里（最远 %.2f ≤ %.2f）—— 描边不会被裁掉" % [worst, half])
	# ★★ 最宽的那一点**不在**外半径上：缺口正好开在正上/正下/正左/正右，
	#    所以外弧到不了 3/6/9/12 点那四个位置，图形外接方框的半宽 = √(R² − 缺口²)。
	#    （这正是「画得下」的原因：控件给的是短边一半，而图形实占比它小。）
	var expect: float = sqrt(maxf(0.0, pow(_outer_radius(r), 2.0) - pow(_gap_px(r), 2.0)))
	near(worst, expect, 0.05,
		"★★ 最宽处 = √(外半径² − 缺口²) = %.2f（缺口开在正方向的必然结果）" % expect)


func _test_too_small_draws_nothing() -> void:
	var r: Dictionary = MenuEmblemRes.ratios_from(require_config())
	eq(MenuEmblemRes.part_outlines(MenuEmblemRes.MIN_SHORT_SIDE, r).size(), 0,
		"★ 短边太小（= 下限 %d）→ 什么都不画" % int(MenuEmblemRes.MIN_SHORT_SIDE))
	eq(MenuEmblemRes.part_outlines(MenuEmblemRes.MIN_SHORT_SIDE * 3.0, r).size(), 5,
		"稍大一点（下限的 3 倍）就正常画出来")


# ------------------------------------------------------------------
# 旋转（外圈顺时针 / 内圈逆时针 / 同速）
# ------------------------------------------------------------------

func _test_spin() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	var e = MenuEmblemRes.new()
	root.add_child(e)

	ThemeRes.set_animations_enabled(true)
	eq(e.arc_angle(), 0.0, "起手角度 0（没跑帧就不会自己转）")
	near(e.spin_deg_per_sec(), cfg.num("menu.emblem_spin_deg_per_sec", -1.0), 0.0001,
		"★★ 转速来自 config.json（度/秒）")

	e._process(1.0)
	var deg: float = rad_to_deg(e.arc_angle())
	near(deg, e.spin_deg_per_sec(), 0.001, "★ 跑 1 秒转过 %.2f°（= 配置里的转速）" % deg)
	e._process(1.0)
	near(rad_to_deg(e.arc_angle()), 2.0 * e.spin_deg_per_sec(), 0.001,
		"★ 跑 2 秒就是两倍（匀速，不是先快后慢）")

	ok(e.arc_angle() > 0.0, "★★ 外圈顺时针（屏幕坐标 y 向下时，正角度看起来就是顺时针）")
	ok(e.core_angle() < 0.0, "★★ 内圈逆时针（它画的是 −角度）")
	near(e.core_angle(), -e.arc_angle(), 0.0001,
		"★★ 两圈**同速**：内圈转角 = −外圈转角（快慢完全一致，只是方向相反）")

	# 关掉动效总开关：停住不动（而不是归零 —— 那会让徽记在开关的瞬间「跳」一下）
	var held: float = e.arc_angle()
	ThemeRes.set_animations_enabled(false)
	e._process(1.0)
	eq(e.arc_angle(), held, "★★ 关掉动效就停在当前角度（不是转回 0）")
	e._process(1.0)
	eq(e.arc_angle(), held, "★ 之后也不动")
	ThemeRes.set_animations_enabled(true)
	e._process(1.0)
	ok(e.arc_angle() > held, "★ 再打开就接着往下转")

	near(MenuEmblemRes.ratios_from(null)["spin"], MenuEmblemRes.DEFAULT_SPIN_DEG_PER_SEC, 0.0001,
		"配置读不出来时用兜底转速")
	e.queue_free()


# ------------------------------------------------------------------
# 脚手架
# ------------------------------------------------------------------

func _outlines() -> Array:
	return MenuEmblemRes.part_outlines(SHORT_SIDE, MenuEmblemRes.ratios_from(require_config()))


## 实现里的外半径口径（短边的一半 − 线宽）—— 断言按同一个口径算，避免两处各写一份。
func _outer_radius(r: Dictionary) -> float:
	return SHORT_SIDE * 0.5 - float(r["line_width"])


func _core_radius(r: Dictionary) -> float:
	return _outer_radius(r) * float(r["core"])


## 内圈凹口的半宽（像素）。
func _slot_px(r: Dictionary) -> float:
	return _outer_radius(r) * float(r["core_slot"])


## 内圈凹口底到圆心的距离（像素）= 半径 − 深度。
func _floor_px(r: Dictionary) -> float:
	return _core_radius(r) - _outer_radius(r) * float(r["core_slot_depth"])


## 外圈缺口的半宽（像素）。
func _gap_px(r: Dictionary) -> float:
	return _outer_radius(r) * float(r["gap"])


## 把一条闭合折线拆成「轴对齐的直线段」与「其余（弧）」。
## 每段轴对齐的线段报出它到圆心的距离（`dist`）与中点（`mid`）——
## 于是「有几道底 / 几道侧壁」「底对着哪个正方向」都能直接数出来。
func _classify_axis_segments(pts: PackedVector2Array) -> Dictionary:
	var out: Dictionary = {"vertical": [], "horizontal": [], "others": 0}
	for j in pts.size() - 1:
		var a: Vector2 = pts[j]
		var b: Vector2 = pts[j + 1]
		var dx: float = absf(b.x - a.x)
		var dy: float = absf(b.y - a.y)
		if dx < AXIS_EPS and dy > AXIS_EPS:
			(out["vertical"] as Array).append({"dist": absf(a.x), "mid": (a + b) * 0.5})
		elif dy < AXIS_EPS and dx > AXIS_EPS:
			(out["horizontal"] as Array).append({"dist": absf(a.y), "mid": (a + b) * 0.5})
		elif dx > AXIS_EPS and dy > AXIS_EPS:
			out["others"] = int(out["others"]) + 1
	return out


func _sign_key(v: float) -> String:
	return "+" if v > 0.0 else "-"
