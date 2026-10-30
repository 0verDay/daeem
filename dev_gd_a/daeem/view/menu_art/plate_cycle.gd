## plate_cycle.gd —— 主菜单左侧的**雕版轮播**：一张一张扫，扫完渐隐、下一张渐显。
##
## 每张图自己是一个 `etched_plate.gd` 子控件（各自一份 shader 材质），本控件只负责
## **时间线**：按绝对时钟算出「现在谁可见、它的扫描头在哪、透明度多少」，推给各张。
##
## 一张图占一个 `cycle`：
##
##     ┌── fade ──┬───────── scan ─────────┬──── pause ────┬── fade ──┐
##     │ 渐显 0→1 │ 扫描头从画外左缘走到右缘 │ 停在画外（亮着）│ 渐隐 1→0 │
##     └──────────┴────────────────────────┴───────────────┴──────────┘
##
## ★ 首尾那两个 `fade` 是**跨张重叠**的：第 N 张渐隐的同时，第 N+1 张在同一段时间里
##   渐显（用户口径「扫描完一张后当前图渐隐、下一张渐显」）。做成溶解而不是「先空一段
##   再亮起来」，左边那块才不会闪一下空场。
## ★ 扫描时钟在渐显那一段是**停在 0**（画外左缘）的：所以新图是「先淡进来、再从最
##   左边开始扫」，而不是淡进来的时候已经扫了一半。
## ★ 时间线仍是绝对时钟（不是 Tween）：能拨到任意一秒截图；动效总开关关掉时钉在
##   「第 0 张、扫描头在画面中间」那一帧（不是空画面）。
extends Control

const ThemeRes = preload("res://view/theme.gd")
const PlateRes = preload("res://view/menu_art/etched_plate.gd")

## 关掉动效 / 停表时钉住的扫描头位置（uv.x，0.55 ≈ 画面中间）。
const FREEZE_X := 0.55

var cfg = null
var _p: Dictionary = {}
var _paths: Array = []
var _plates: Array = []
var _t: float = 0.0
var _running: bool = false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true


func _ready() -> void:
	set_process(false)


# ------------------------------------------------------------------
# 对外
# ------------------------------------------------------------------

func setup(p_cfg) -> void:
	cfg = p_cfg
	_p = PlateRes.params_from(cfg)
	_paths = PlateRes.paths_from(cfg)
	for path in _paths:
		var plate = PlateRes.new()
		plate.name = "Plate%d" % _plates.size()
		plate.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(plate)
		plate.setup(cfg, String(path))
		_plates.append(plate)
	_t = 0.0
	apply()


func set_running(on: bool) -> void:
	_running = on
	set_process(on)
	# 停表 / 动效总开关关着 → 钉在「扫描头在中间」那一帧
	if not on or not ThemeRes.animations_enabled():
		_t = freeze_time()
		apply()


func is_running() -> bool:
	return _running


## 回到第一张的起点（进菜单 / 从战斗回来时调用）。
func restart_scan() -> void:
	_t = 0.0
	apply()


## 把时钟拨到某一秒（截图 / 测试用）。
func set_time(t: float) -> void:
	_t = maxf(0.0, t)
	apply()


func scan_time() -> float:
	return _t


## 当前**最可见**那张的扫描头 uv.x。
func scan_x() -> float:
	return scan_x_of(active_index())


func active_index() -> int:
	var best := 0
	var best_a := -1.0
	for i in _plates.size():
		var a: float = plate_alpha(i)
		if a > best_a + 0.0001:
			best_a = a
			best = i
	return best


## 第 `i` 张的扫描头 uv.x。
func scan_x_of(i: int) -> float:
	if i < 0 or i >= _plates.size():
		return -0.06
	return float(_plates[i].scan_x())


## 第 `i` 张这一帧的透明度。
func plate_alpha(i: int) -> float:
	if i < 0 or i >= _plates.size():
		return 0.0
	return float(_plates[i].alpha())


## 一张图占多久（扫描 + 停留 + 跨张溶解）。
func cycle_sec() -> float:
	return float(_p.get("scan", PlateRes.DEF_SCAN_SEC)) \
		+ float(_p.get("pause", PlateRes.DEF_PAUSE_SEC)) \
		+ float(_p.get("fade", PlateRes.DEF_FADE_SEC))


## 整轮（所有图各扫一遍）多久。
func total_sec() -> float:
	return maxf(0.1, cycle_sec() * float(maxi(1, _plates.size())))


## 让第 `i` 张的扫描头落在 uv.x = `x` 处所需的时钟值。
## ★ 「按位置冻结」而不是「按时间冻结」：改了时长 / 拖动参数之后，冻结帧仍然
##   落在画面中间，不会跑到边上去（实测踩过）。
func time_for_x(x: float, i: int = 0) -> float:
	var scan: float = maxf(0.05, float(_p.get("scan", PlateRes.DEF_SCAN_SEC)))
	var tt: float = clampf((x + 0.06) / 1.12, 0.0, 1.0) * scan
	return float(i) * cycle_sec() + tt


## 动效关掉 / 停表时停在哪一秒：第 0 张、扫描头在画面中间。
func freeze_time() -> float:
	return time_for_x(FREEZE_X, 0)


func plate_count() -> int:
	return _plates.size()


func plate_paths() -> Array:
	return _paths.duplicate()


func plate(i: int) -> Control:
	if i < 0 or i >= _plates.size():
		return null
	return _plates[i]


func plate_texture(i: int = 0):
	var p = plate(i)
	return p.plate_texture() if p != null else null


func scan_material(i: int = 0) -> ShaderMaterial:
	var p = plate(i)
	return p.scan_material() if p != null else null


# ------------------------------------------------------------------
# 时钟
# ------------------------------------------------------------------

func _process(delta: float) -> void:
	advance(delta)


func advance(delta: float) -> void:
	if not _running or delta <= 0.0:
		return
	if not ThemeRes.animations_enabled():
		var frozen: float = freeze_time()
		if absf(_t - frozen) > 0.001:
			_t = frozen
			apply()
		return
	_t = fposmod(_t + delta, total_sec())
	apply()


# ------------------------------------------------------------------
# 这一帧每张图该是什么样
# ------------------------------------------------------------------

func apply() -> void:
	if _plates.is_empty():
		return
	var cycle: float = maxf(0.05, cycle_sec())
	var total: float = total_sec()
	var scan: float = maxf(0.05, float(_p.get("scan", PlateRes.DEF_SCAN_SEC)))
	var pause: float = maxf(0.0, float(_p.get("pause", PlateRes.DEF_PAUSE_SEC)))
	var fade: float = clampf(float(_p.get("fade", PlateRes.DEF_FADE_SEC)), 0.0, cycle * 0.45)
	var start: float = float(_p.get("start", PlateRes.DEF_START))

	for i in _plates.size():
		var s: float = _slot_time(_t, i, cycle, total)
		var a: float = _alpha_in_slot(s, cycle, fade)
		# 扫描时钟：渐显那一段停在 0（画外左缘），扫完之后停在结束位置
		var local: float = clampf(s, 0.0, scan + pause)
		var x: float = PlateRes.scan_x_at(local, scan, pause, start)
		var plate = _plates[i]
		plate.set_scan_x(x)
		plate.set_alpha(a)


## 第 `i` 张相对自己那一档的时间（取最短环绕，落在 [-total/2, total/2)）。
static func _slot_time(t: float, i: int, cycle: float, total: float) -> float:
	var s: float = fposmod(t - float(i) * cycle + total * 0.5, total) - total * 0.5
	return s


## 这一档里的透明度：[-fade, 0) 渐显、[0, cycle-fade] 满、之后渐隐。
static func _alpha_in_slot(s: float, cycle: float, fade: float) -> float:
	if fade <= 0.001:
		return 1.0 if (s >= -0.0001 and s < cycle - 0.0001) else 0.0
	if s < 0.0:
		if s < -fade:
			return 0.0
		return _smooth01((s + fade) / fade)
	if s >= cycle:
		return 0.0
	if s > cycle - fade:
		return _smooth01((cycle - s) / fade)
	return 1.0


static func _smooth01(v: float) -> float:
	var x: float = clampf(v, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)
