## test_menu_plate_cycle.gd —— 主菜单左侧**雕版轮播**的时间线
##
## 图好不好看没法断言（要人眼看），但下面这些错了画面一定不对：
##   · 两张都挂上了（配置里列了几张就有几张，顺序对得上）；
##   · 第 0 张从「画外左缘」开始扫，扫完停在画外；
##   · 一档走完时**渐隐 / 下一张渐显是同时发生的**（溶解），左边不会先空一段；
##   · 下一张淡进来的时候扫描头还停在左缘（不是已经扫了一半）；
##   · 整轮走完回到第 0 张；
##   · 动效关掉 / 停表时钉在「第 0 张、扫描头在中间」那一帧。
##
## ★ 全部是「拨时钟 → 读每张的透明度与扫描头」的纯数据断言，不跑帧、不真渲染。
extends "res://tests/test_case.gd"

const CycleRes = preload("res://view/menu_art/plate_cycle.gd")
const PlateRes = preload("res://view/menu_art/etched_plate.gd")
const ThemeRes = preload("res://view/theme.gd")

const VIEW := Vector2(1280.0, 1080.0)
const EPS := 0.0001

var _made: Array = []


func _initialize() -> void:
	_case_name = "menu_plate_cycle"
	run_all(_cases)


func _cases() -> void:
	var prev_anim: bool = ThemeRes.animations_enabled()
	ThemeRes.set_animations_enabled(true)
	_test_setup()
	_test_first_plate_scans()
	_test_hold()
	_test_crossfade()
	_test_next_plate_fresh()
	_test_wraps()
	_test_freeze()
	_test_restart()
	_test_pure_helpers()
	ThemeRes.set_animations_enabled(prev_anim)
	_free_all()


func _free_all() -> void:
	for n in _made:
		if is_instance_valid(n):
			n.free()
	_made.clear()


func _cycle():
	var cfg = require_config()
	var c = CycleRes.new()
	_made.append(c)
	c.setup(cfg)
	c.size = VIEW
	return c


func _nums() -> Dictionary:
	var cfg = require_config()
	return {
		"scan": cfg.num("menu.plate.scan_sec", 9.0),
		"pause": cfg.num("menu.plate.pause_sec", 3.0),
		"fade": cfg.num("menu.plate.fade_sec", 0.8),
	}


# ------------------------------------------------------------------

func _test_setup() -> void:
	var c = _cycle()
	eq(c.plate_count(), 2, "配置里两张图都挂上了")
	eq(c.plate(0) != null and c.plate(1) != null, true, "两张子控件都在")
	ok(c.plate_texture(1) != null, "第二张的蒙版也载进来了")
	var n := _nums()
	near(c.cycle_sec(), float(n["scan"]) + float(n["pause"]) + float(n["fade"]), EPS,
		"一档 = 扫描 + 停留 + 溶解")
	near(c.total_sec(), c.cycle_sec() * 2.0, EPS, "整轮 = 一档 × 张数")


func _test_first_plate_scans() -> void:
	var c = _cycle()
	var n := _nums()
	c.set_time(0.0)
	near(c.plate_alpha(0), 1.0, 0.001, "t=0：第一张已经在场（淡入发生在 0 之前）")
	near(c.plate_alpha(1), 0.0, 0.001, "t=0：第二张还没出场")
	near(c.scan_x_of(0), -0.06, 0.001, "t=0：扫描头在**画外左缘**（从最左边扫进来）")

	var prev := -INF
	var scan: float = float(n["scan"])
	for i in 10:
		var t: float = scan * float(i) / 9.0
		c.set_time(t)
		var x: float = c.scan_x_of(0)
		ok(x > prev, "第一张的扫描头单调向右（t=%.1f 时 x=%.3f）" % [t, x])
		prev = x
		near(c.plate_alpha(0), 1.0, 0.001, "扫描期间第一张是全亮的（t=%.1f）" % t)


func _test_hold() -> void:
	var c = _cycle()
	var n := _nums()
	c.set_time(float(n["scan"]) + float(n["pause"]) * 0.5)
	near(c.scan_x_of(0), 1.06, EPS, "扫完之后停在画外")
	near(c.plate_alpha(0), 1.0, 0.001, "停留期间还是全亮的（整幅画都被点亮）")


func _test_crossfade() -> void:
	var c = _cycle()
	var n := _nums()
	var cyc: float = c.cycle_sec()
	var fade: float = float(n["fade"])
	c.set_time(cyc - fade * 0.5)
	var a0: float = c.plate_alpha(0)
	var a1: float = c.plate_alpha(1)
	ok(a0 > 0.01 and a0 < 0.99, "溶解中段：上一张正在渐隐（%.2f）" % a0)
	ok(a1 > 0.01 and a1 < 0.99, "溶解中段：下一张正在渐显（%.2f）" % a1)
	near(a0 + a1, 1.0, 0.02, "两张加起来 ≈ 1（溶解，不是先空一段再亮）")
	# 溶解全程左边都不空：任意时刻至少有一张是看得见的
	for k in 7:
		var t: float = cyc - fade + fade * float(k) / 6.0
		c.set_time(t)
		ok(c.plate_alpha(0) + c.plate_alpha(1) > 0.99,
			"溶解全程不空场（t=%.2f，合计 %.2f）" % [t, c.plate_alpha(0) + c.plate_alpha(1)])


func _test_next_plate_fresh() -> void:
	var c = _cycle()
	var n := _nums()
	var cyc: float = c.cycle_sec()
	var fade: float = float(n["fade"])
	# 溶解刚开始：下一张已经露头，但扫描头还停在左缘（还没开始扫）
	c.set_time(cyc - fade * 0.9)
	near(c.scan_x_of(1), -0.06, 0.001, "下一张刚淡进来时，扫描头还停在画外左缘")
	# 过了交界：上一张没了、下一张全亮并且刚开始扫
	c.set_time(cyc + 0.1)
	near(c.plate_alpha(0), 0.0, 0.001, "过了交界：上一张已经退场")
	near(c.plate_alpha(1), 1.0, 0.001, "过了交界：下一张全亮")
	eq(c.active_index(), 1, "此刻的「当前张」是第二张")
	ok(c.scan_x_of(1) > -0.06 and c.scan_x_of(1) < 0.02, "下一张从最左边开始扫（x=%.3f）"
		% c.scan_x_of(1))


func _test_wraps() -> void:
	var c = _cycle()
	var total: float = c.total_sec()
	var probe := 0.35
	c.set_time(probe)
	var a0: float = c.plate_alpha(0)
	var x0: float = c.scan_x_of(0)
	c.set_time(total + probe)
	near(c.plate_alpha(0), a0, 0.001, "整轮走完回到第一张")
	near(c.scan_x_of(0), x0, 0.001, "整轮走完，第一张的扫描头也回到同一处")


func _test_freeze() -> void:
	var c = _cycle()
	c.set_running(true)
	ThemeRes.set_animations_enabled(false)
	c.advance(1.0)
	near(c.scan_x_of(0), CycleRes.FREEZE_X, 0.02, "动效关掉时钉在「扫描头在中间」那一帧")
	near(c.plate_alpha(0), 1.0, 0.001, "冻结时第一张是全亮的（不是空画面）")
	near(c.plate_alpha(1), 0.0, 0.001, "冻结时只显示一张")
	var x_frozen: float = c.scan_x_of(0)
	c.advance(5.0)
	near(c.scan_x_of(0), x_frozen, EPS, "冻结期间扫描头不动")
	ThemeRes.set_animations_enabled(true)
	c.advance(0.5)
	ok(c.scan_x_of(0) > x_frozen, "动效打开后继续往右走")

	# 主动停表（进战斗）也钉在同一帧
	var c2 = _cycle()
	c2.set_time(3.0)
	c2.set_running(false)
	near(c2.scan_x_of(0), CycleRes.FREEZE_X, 0.02, "停表时同样钉在中间那一帧")


func _test_restart() -> void:
	var c = _cycle()
	c.set_time(20.0)
	c.restart_scan()
	near(c.scan_time(), 0.0, 0.01, "restart_scan 把时钟清回起点")
	near(c.scan_x_of(0), -0.06, 0.001, "重开那一刻扫描头在**画外左缘**")
	near(c.plate_alpha(0), 1.0, 0.001, "重开时第一张是全亮的")


func _test_pure_helpers() -> void:
	# 没有溶解（fade=0）时不能出现「两边都半透明」或者除零
	near(CycleRes._alpha_in_slot(1.0, 10.0, 0.0), 1.0, EPS, "fade=0：这一档内全亮")
	near(CycleRes._alpha_in_slot(10.5, 10.0, 0.0), 0.0, EPS, "fade=0：这一档外全灭")
	near(CycleRes._alpha_in_slot(-0.01, 10.0, 1.0), 1.0, 0.001, "刚进场就是亮的")
	near(CycleRes._alpha_in_slot(-2.0, 10.0, 1.0), 0.0, EPS, "离得太远就是全灭")
	# 档内取时间要取最短环绕（跨过整整一轮不能算成「很远」）
	near(CycleRes._slot_time(0.0, 0, 12.0, 24.0), 0.0, EPS, "第 0 张在 t=0 时偏移 0")
	near(CycleRes._slot_time(24.0, 0, 12.0, 24.0), 0.0, EPS, "跨一轮之后仍回到 0")
