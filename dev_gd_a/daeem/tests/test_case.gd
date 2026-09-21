## 无头测试脚手架（对应 docs/architecture.md 第六节）。
##
## 用法：一个测试文件 = 一个 `extends "res://tests/test_case.gd"` 的脚本，
##       `_initialize()` 里调 `run_all(自己的一组断言)`，靠**退出码**表达成败。
##       runner（tools/run-tests.ps1）只看退出码，不解析输出文本。
##
## ⚠️ 为什么退出码这么重要：一旦它永远返回 0，整套测试就变成「永远绿灯」的摆设 ——
##    那比没有测试更糟，因为它会让人相信测试通过。
##
## ⚠️ GDScript **没有** Python 那种 `a if cond else b` 三元表达式。
##    写成 `quit(1 if _fail > 0 else 0)` 不报错，但语义不对（见 docs/architecture.md 6.1）。别抄。
##
## ⚠️ 输出只用 ASCII 的 OK / FAIL，不用 ✔ ✘ —— 中文 Windows 的 GBK 控制台会因此整个崩掉
##    （HTML 版的 runner 真崩过，见 docs/pitfalls.md 4.2）。
##
## ★★ 已实测的引用约定（改了会满屏 Parse Error，先读 docs/pitfalls.md 第五节）：
##   命令行 `--script` 启动时**全局 class_name 表不可用**（没有编辑器生成缓存），所以：
##     1. 跨文件只用**自己文件里的 preload 常量**，绝不用别人文件的 class_name 作类型
##        （`func take(h: ProbeHelperA)` 会直接 Parse Error）
##     2. 子类不要重复声明父类已有的 const（会报 "already exists in parent class"）
##     3. 调用返回值是 Variant 时不要用 `:=`，用 `=`（否则 "Cannot infer the type"）
##     4. 本文件刻意不写 class_name，依赖一律用字符串路径在运行时 load()
extends SceneTree

const PATH_CONFIG := "res://logic/config.gd"
const PATH_MAP_DATA := "res://logic/map_data.gd"
const PATH_GRID := "res://logic/grid.gd"

var _pass: int = 0
var _fail: int = 0
var _case_name: String = "unnamed"
var _failed_names: Array[String] = []


## 这个文件是脚手架基类，不是测试用例。真被人直接跑时要说清楚，并给出失败退出码
## （返回 0 会被 runner 当成「通过」，那就变成假绿灯了）。
func _initialize() -> void:
	printerr("test_case.gd 是脚手架基类，不直接运行；请跑 tests/test_*.gd")
	quit(1)


## 子类在 _initialize() 里调它：跑完所有断言并退出，退出码反映成败
func run_all(cases: Callable) -> void:
	print("[CASE] %s" % _case_name)
	cases.call()
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


## ---- 帧预算换算 ----
## ★ config.json 顶部那次调整把格宽放大到 128px、单位速度降到**基线的 1/4**
##   （unit.speed 2.4 → 0.6，debug.enemy_speed 1.8 → 0.45）。
##   测试里那些「跑 N 帧等它走到」的上限，是按**基线速度**留的余量：
##   速度一变，同样的路程就要 4 倍的帧数 —— 不换算的话，挂掉的会是这些用例，
##   而它们真正想验的东西（到达 / 不抖 / 不吸附格心）根本没被验到。
##   所以统一走这个换算：以后谁再调速度，帧预算自动跟着走。
##   ⚠️ 只用它放大「等移动收敛」的循环；纯观察窗口（跑固定 N 帧看闪不闪、抖不抖）不要用，
##      那些量的本来就是秒数而不是路程。
const SPEED_BASELINE := 2.4


func frames_at_baseline(cfg, base_frames: int) -> int:
	var spd: float = maxf(0.01, float(cfg.unit_speed))
	return int(ceil(float(base_frames) * maxf(1.0, SPEED_BASELINE / spd)))


func ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_failed_names.append(what)
		printerr("  [FAIL] %s" % what)


func eq(actual: Variant, expected: Variant, what: String) -> void:
	if actual == expected:
		_pass += 1
	else:
		_fail += 1
		_failed_names.append(what)
		printerr("  [FAIL] %s（实际 %s，期望 %s）" % [what, str(actual), str(expected)])


func near(actual: float, expected: float, tol: float, what: String) -> void:
	if absf(actual - expected) <= tol:
		_pass += 1
	else:
		_fail += 1
		_failed_names.append(what)
		printerr("  [FAIL] %s（实际 %f，期望 %f ± %f）" % [what, actual, expected, tol])


func v2_near(actual: Vector2, expected: Vector2, tol: float, what: String) -> void:
	if actual.distance_to(expected) <= tol:
		_pass += 1
	else:
		_fail += 1
		_failed_names.append(what)
		printerr("  [FAIL] %s（实际 %s，期望 %s）" % [what, str(actual), str(expected)])


func v2i_eq(actual: Vector2i, expected: Vector2i, what: String) -> void:
	if actual == expected:
		_pass += 1
	else:
		_fail += 1
		_failed_names.append(what)
		printerr("  [FAIL] %s（实际 %s，期望 %s）" % [what, str(actual), str(expected)])


## 载入某脚本（运行时 load，绕开「全局 class_name 表不可用」这件事）
func script_at(path: String) -> GDScript:
	var s := load(path)
	if s == null:
		ok(false, "脚本能载入：%s" % path)
		return null
	return s


## 载入全局配置，失败即记一条失败断言（不静默用默认值 —— 静默默认值会让
## 「JSON 写错了」表现为「手感莫名不对」，那是最难查的一类问题）
func require_config() -> RefCounted:
	var cls := script_at(PATH_CONFIG)
	if cls == null:
		return null
	var cfg = cls.load_default()
	ok(cfg != null, "config.json 能载入（%s）" % cls.last_error)
	return cfg


func require_map(cfg, path: String = "res://data/test_map.json") -> RefCounted:
	var cls := script_at(PATH_MAP_DATA)
	if cls == null:
		return null
	var m = cls.load_from(path, cfg)
	ok(m != null, "map json 能载入：%s" % path)
	return m
