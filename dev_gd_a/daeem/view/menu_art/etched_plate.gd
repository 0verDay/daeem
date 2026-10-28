## etched_plate.gd —— 主菜单左侧那张**雕版图**（用户的参考图）+ 一道从左往右扫的金线
##
## 画面分两层：
##   · `assets/menu/menu_plate.png` —— 从参考图抽出来的**线蒙版**（白线 + alpha，
##     由 tools/bake_menu_plate.py 烘，不烤颜色），运行时按 `theme.palette.accent` 上色；
##   · `plate_scan.gdshader` —— 底色 + 一道窄亮前沿 + 扫过之后的余晖。
##
## ★★ 为什么这次用贴图（和 menu_emblem / outcome_art 那条「零贴图」口径不冲突）：
##   那条口径管的是**UI 零件**（按钮图标、徽记、边框）：它们要跟着主题变色、要在任意
##   尺寸下锐利，所以必须现画。而这幅是**一整张插画**——它的价值就在于那张具体的画，
##   程序化重画只会得到「有点像」的东西（上一版那座塔已经被用户否掉了）。
##   于是这里的做法是：**形状用贴图，颜色和光用代码** —— 贴图只存线条的蒙版，
##   线色、亮度、扫描全在 shader 里，换主题不用重烘图。
##
## ★★ 蒙版而不是彩色图：彩色 JPEG 的暗蓝底会跟游戏的渐变底打架，而且颜色就烤死了。
##   只存 alpha 之后，这张图天然「浮」在渐变底上，和整套 UI 是同一层纸。
##
## ★ 时间线仍是**绝对时钟**（不是 Tween）：能拨到任意一秒截图；动效总开关关掉时
##   钉在「扫描头在画面中间」的那一帧（不是空画面，也不是刚进画的第一帧）。
extends Control

const ThemeRes = preload("res://view/theme.gd")
const ScanShader = preload("res://view/menu_art/plate_scan.gdshader")

const PLATE_PATH := "res://assets/menu/menu_plate.png"

const DEF_ENABLED := true
const DEF_OPACITY := 0.95
const DEF_SCAN_SEC := 9.0
const DEF_PAUSE_SEC := 3.0
const DEF_BAND := 0.030
const DEF_DECAY := 0.22
const DEF_BASE := 0.26
const DEF_GLOW := 1.0
## 进菜单时扫描头的位置（0 = 还在画外左缘，从最左边扫进来）。
## ★ 用户口径：点进主菜单时扫描线必须**从最左边起步**，不能一进来就已经在中间。
const DEF_START := 0.0
## 关掉动效时钉住的位置（扫描头正好在画面中间，x 是 uv）。
const FREEZE_X := 0.55

## 铺满方式：`fill` = 横竖各自拉满（不留空、允许非等比）；`cover` = 等比裁切。
const DEF_FIT := "fill"

var cfg = null
var _p: Dictionary = {}
var _tex: Texture2D = null
var _mat: ShaderMaterial = null
var _t: float = 0.0
var _running: bool = false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true


func _ready() -> void:
	resized.connect(queue_redraw)
	set_process(false)


# ------------------------------------------------------------------
# 对外
# ------------------------------------------------------------------

func setup(p_cfg) -> void:
	cfg = p_cfg
	_p = params_from(cfg)
	_tex = load(PLATE_PATH) if ResourceLoader.exists(PLATE_PATH) else null
	if _tex == null:
		push_warning("etched_plate：读不到 %s（跑一次 tools/bake_menu_plate.py）" % PLATE_PATH)
	_mat = ShaderMaterial.new()
	_mat.shader = ScanShader
	# ★ 金色（用户口径：贴合主题色）：底子用 accent（琥珀金），扫描头用 accent_bright。
	#   底色那层是 0.32 的 alpha，压出来是「暗金铜版」；只有扫描头那一小段是亮金。
	#   ⚠️ 这条与 theme.gd 里「accent 只给主行动」的预算有冲突，是用户明确要求的例外：
	#     它只出现在主菜单左侧、且 90% 的时间是暗的。
	_mat.set_shader_parameter("line_color", ThemeRes.accent())
	_mat.set_shader_parameter("head_color", ThemeRes.accent_bright())
	_mat.set_shader_parameter("band", float(_p["band"]))
	_mat.set_shader_parameter("decay", float(_p["decay"]))
	_mat.set_shader_parameter("base", float(_p["base"]))
	_mat.set_shader_parameter("glow", float(_p["glow"]))
	_mat.set_shader_parameter("opacity", float(_p["opacity"]))
	material = _mat
	_t = 0.0
	_apply()
	queue_redraw()


func set_running(on: bool) -> void:
	_running = on
	set_process(on)
	# 动效总开关关着 / 主动停表 → 钉在「扫描头在中间」那一帧
	if not on or not ThemeRes.animations_enabled():
		_t = time_for_x(FREEZE_X)
		_apply()


func is_running() -> bool:
	return _running


## 回到本轮起点。进菜单 / 从战斗回来时调用。
## ★ 回到的是 `_t = 0`：相位里的 start_frac 会让扫描头直接落在「已扫过三成」处。
func restart_scan() -> void:
	_t = 0.0
	_apply()


## 把时钟拨到某一秒（截图 / 测试用）。
func set_time(t: float) -> void:
	_t = maxf(0.0, t)
	_apply()


func scan_time() -> float:
	return _t


## 当前扫描头的 uv.x（-0.06 = 还在画外，1.06 = 已经出画）。
func scan_x() -> float:
	return scan_x_at(_t, float(_p.get("scan", DEF_SCAN_SEC)),
		float(_p.get("pause", DEF_PAUSE_SEC)), float(_p.get("start", DEF_START)))


func cycle_sec() -> float:
	return float(_p.get("scan", DEF_SCAN_SEC)) + float(_p.get("pause", DEF_PAUSE_SEC))


## 让扫描头落在 uv.x = `x` 处所需的时钟值（相位里的 start_frac 已经扣掉）。
## ★ 这是「按位置冻结」而不是「按时间冻结」：改了 start_frac 或时长之后，
##   冻结帧仍然落在画面中间，不会跑到边上去（实测踩过）。
func time_for_x(x: float) -> float:
	var scan: float = maxf(0.05, float(_p.get("scan", DEF_SCAN_SEC)))
	var start: float = float(_p.get("start", DEF_START))
	var tt: float = clampf((x + 0.06) / 1.12, 0.0, 1.0) * scan
	return fposmod(tt - start * scan, maxf(0.1, cycle_sec()))


func plate_texture() -> Texture2D:
	return _tex


func scan_material() -> ShaderMaterial:
	return _mat


# ------------------------------------------------------------------
# 时钟
# ------------------------------------------------------------------

func _process(delta: float) -> void:
	advance(delta)


func advance(delta: float) -> void:
	if not _running or delta <= 0.0:
		return
	if not ThemeRes.animations_enabled():
		var frozen: float = time_for_x(FREEZE_X)
		if absf(_t - frozen) > 0.001:
			_t = frozen
			_apply()
		return
	var total: float = maxf(0.1, cycle_sec())
	_t += delta
	if _t >= total:
		_t = fmod(_t, total)
	_apply()


func _apply() -> void:
	if _mat == null:
		return
	# ★ 只改 uniform，不 queue_redraw：贴图命令没有变，重画是白费。
	#   改 uniform 本身就会让这一项重新提交。
	_mat.set_shader_parameter("scan_x", scan_x())
	_mat.set_shader_parameter("opacity",
		clampf(float(_p.get("opacity", DEF_OPACITY)), 0.0, 1.0))


# ------------------------------------------------------------------
# 绘制
# ------------------------------------------------------------------

func _draw() -> void:
	if _tex == null or not bool(_p.get("enabled", DEF_ENABLED)):
		return
	if size.x < 8.0 or size.y < 8.0:
		return
	var r: Rect2 = fit_rect(size, Vector2(float(_tex.get_width()), float(_tex.get_height())),
		String(_p.get("fit", DEF_FIT)))
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	draw_texture_rect(_tex, r, false)


## 贴图在控件里的落位。两种模式：
##
## `fill`（默认，用户口径「整体拉伸适配所有分辨率」）：**横竖各自拉满**。
##   代价是画面会被非等比拉伸 —— 左区宽高比会随设备在 0.7~1.7 之间变，
##   等比不变形就一定会有一边留白。实测把这幅线稿拉到 1.3 倍宽，
##   建筑窗格只是「胖了一点」，比两侧空出一条黑边可接受得多。
##
## `cover`（可选）：等比放大到铺满，多出来的那一边裁掉 ——
##   · 宽屏：贴**顶**（保住塔冠，裁的是底部碎石）；
##   · 窄屏：贴**右**（塔在画面右侧，宁可裁掉左边碎片）。
##   不变形，但会真的切掉一部分画。
static func fit_rect(view: Vector2, tex: Vector2, mode: String = "fill") -> Rect2:
	if view.x <= 0.0 or view.y <= 0.0 or tex.x <= 0.0 or tex.y <= 0.0:
		return Rect2()
	if mode != "cover":
		return Rect2(Vector2.ZERO, view)
	var k: float = maxf(view.x / tex.x, view.y / tex.y)
	var dw: float = tex.x * k
	var dh: float = tex.y * k
	var x: float = (view.x - dw) * 0.5
	if dw > view.x:
		x = view.x - dw            # 窄屏：贴右
	var y: float = (view.y - dh) * 0.5
	if dh > view.y:
		y = 0.0                    # 宽屏：贴顶
	return Rect2(x, y, dw, dh)


## 扫描头位置：前 `scan_sec` 秒从画外走到画外，之后 `pause_sec` 秒停在画外。
##
## `start_frac` 让「进菜单的那一刻」就已经在扫描途中（见 DEF_START）。
static func scan_x_at(t: float, scan_sec: float, pause_sec: float,
		start_frac: float = DEF_START) -> float:
	var ss: float = maxf(0.05, scan_sec)
	var total: float = ss + maxf(0.0, pause_sec)
	var tt: float = fposmod(t + clampf(start_frac, 0.0, 1.0) * ss, total)
	if tt >= ss:
		return 1.06
	return lerpf(-0.06, 1.06, tt / ss)


# ------------------------------------------------------------------
# 参数
# ------------------------------------------------------------------

static func params_from(p_cfg) -> Dictionary:
	var enabled: bool = DEF_ENABLED
	var opacity: float = DEF_OPACITY
	var scan: float = DEF_SCAN_SEC
	var pause: float = DEF_PAUSE_SEC
	var band: float = DEF_BAND
	var decay: float = DEF_DECAY
	var base: float = DEF_BASE
	var glow: float = DEF_GLOW
	var start: float = DEF_START
	var fit: String = DEF_FIT
	if p_cfg != null:
		var raw: Variant = p_cfg.get_path_value("menu.plate.enabled")
		if typeof(raw) == TYPE_BOOL:
			enabled = bool(raw)
		opacity = clampf(p_cfg.num("menu.plate.opacity", opacity), 0.0, 1.0)
		scan = clampf(p_cfg.num("menu.plate.scan_sec", scan), 0.5, 60.0)
		pause = clampf(p_cfg.num("menu.plate.pause_sec", pause), 0.0, 60.0)
		band = clampf(p_cfg.num("menu.plate.band", band), 0.004, 0.2)
		decay = clampf(p_cfg.num("menu.plate.decay", decay), 0.02, 0.8)
		base = clampf(p_cfg.num("menu.plate.base", base), 0.0, 1.0)
		glow = clampf(p_cfg.num("menu.plate.glow", glow), 0.0, 3.0)
		start = clampf(p_cfg.num("menu.plate.start_frac", start), 0.0, 1.0)
		var raw_fit: Variant = p_cfg.get_path_value("menu.plate.fit")
		if typeof(raw_fit) == TYPE_STRING:
			var f := String(raw_fit).strip_edges().to_lower()
			if f == "cover" or f == "fill":
				fit = f
	return {
		"enabled": enabled, "opacity": opacity, "scan": scan, "pause": pause,
		"band": band, "decay": decay, "base": base, "glow": glow, "start": start,
		"fit": fit,
	}
