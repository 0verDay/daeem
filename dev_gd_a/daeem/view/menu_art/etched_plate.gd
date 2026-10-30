## etched_plate.gd —— 主菜单左侧那张**雕版图**：一张蒙版 + 一道从左往右扫的金线。
##
## 这一层只负责「画一张」：把扫描头位置和透明度推给 shader。**时间线不在这里** ——
## 轮播（第 N 张扫完渐隐、下一张渐显）由 `plate_cycle.gd` 统一驱动，
## 它会给每张图各建一个本控件，然后逐帧调 `set_scan_x()` / `set_alpha()`。
##
## 画面分两层：
##   · `assets/menu/menu_plate*.png` —— 从参考图抽出来的**线蒙版**（白线 + alpha，
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
extends Control

const ThemeRes = preload("res://view/theme.gd")
const ScanShader = preload("res://view/menu_art/plate_scan.gdshader")

## 第一张（高塔）的蒙版；第二张及以后由 menu.plate.images 在 config 里列。
const PLATE_PATH := "res://assets/menu/menu_plate.png"

const DEF_ENABLED := true
const DEF_OPACITY := 0.95
const DEF_SCAN_SEC := 9.0
const DEF_PAUSE_SEC := 3.0
const DEF_FADE_SEC := 0.8
const DEF_BAND := 0.030
const DEF_DECAY := 0.22
const DEF_BASE := 0.26
const DEF_GLOW := 1.0
## 进菜单时扫描头的位置（0 = 还在画外左缘，从最左边扫进来）。
## ★ 用户口径：点进主菜单时扫描线必须**从最左边起步**，不能一进来就已经在中间。
const DEF_START := 0.0

## 铺满方式：`fill` = 横竖各自拉满（不留空、允许非等比）；`cover` = 等比裁切。
const DEF_FIT := "fill"

var cfg = null
var _p: Dictionary = {}
var _tex: Texture2D = null
var _mat: ShaderMaterial = null


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true


func _ready() -> void:
	resized.connect(queue_redraw)
	set_process(false)


# ------------------------------------------------------------------
# 对外
# ------------------------------------------------------------------

## @param p_path 蒙版路径（默认第一张）。
func setup(p_cfg, p_path: String = PLATE_PATH) -> void:
	cfg = p_cfg
	_p = params_from(cfg)
	_tex = load(p_path) if ResourceLoader.exists(p_path) else null
	if _tex == null:
		push_warning("etched_plate：读不到 %s（跑一次 tools/bake_menu_plate.py）" % p_path)
	_mat = ShaderMaterial.new()
	_mat.shader = ScanShader
	# ★ 金色（用户口径：贴合主题色）：底子用 accent（琥珀金），扫描头用 accent_bright。
	#   底色那层是低 alpha，压出来是「暗金铜版」；只有扫描头那一小段是亮金。
	#   ⚠️ 这条与 theme.gd 里「accent 只给主行动」的预算有冲突，是用户明确要求的例外：
	#     它只出现在主菜单左侧、且九成时间是暗的。
	_mat.set_shader_parameter("line_color", ThemeRes.accent())
	_mat.set_shader_parameter("head_color", ThemeRes.accent_bright())
	_mat.set_shader_parameter("band", float(_p["band"]))
	_mat.set_shader_parameter("decay", float(_p["decay"]))
	_mat.set_shader_parameter("base", float(_p["base"]))
	_mat.set_shader_parameter("glow", float(_p["glow"]))
	_mat.set_shader_parameter("opacity", float(_p["opacity"]))
	material = _mat
	set_scan_x(scan_x_at(0.0, float(_p["scan"]), float(_p["pause"]), float(_p["start"])))
	queue_redraw()


## 扫描头的 uv.x（-0.06 = 画外左缘，1.06 = 已经出画）。只改 uniform，不重画。
func set_scan_x(x: float) -> void:
	if _mat == null:
		return
	# ★ 只改 uniform，不 queue_redraw：贴图命令没有变，重画是白费。
	_mat.set_shader_parameter("scan_x", x)


## 整张的透明度（轮播的渐隐 / 渐显 + 入场编排都走这里）。
func set_alpha(a: float) -> void:
	modulate.a = clampf(a, 0.0, 1.0)


func alpha() -> float:
	return modulate.a


func scan_x() -> float:
	if _mat == null:
		return -0.06
	return float(_mat.get_shader_parameter("scan_x"))


func plate_texture() -> Texture2D:
	return _tex


func scan_material() -> ShaderMaterial:
	return _mat


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
##   · 宽屏：贴**顶**（保住上半部分，裁底部）；
##   · 窄屏：贴**右**（主体在画面右侧，宁可裁掉左边）。
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
	var fade: float = DEF_FADE_SEC
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
		fade = clampf(p_cfg.num("menu.plate.fade_sec", fade), 0.0, 5.0)
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
		"fade": fade, "band": band, "decay": decay, "base": base, "glow": glow,
		"start": start, "fit": fit,
	}


## 蒙版路径表（`menu.plate.images`）。留空 / 读不到时退回第一张。
static func paths_from(p_cfg) -> Array:
	var out: Array = []
	if p_cfg != null:
		var raw: Variant = p_cfg.get_path_value("menu.plate.images")
		if typeof(raw) == TYPE_ARRAY:
			for item in (raw as Array):
				if typeof(item) == TYPE_STRING and String(item).strip_edges() != "":
					var p := String(item).strip_edges()
					if ResourceLoader.exists(p):
						out.append(p)
	if out.is_empty():
		out.append(PLATE_PATH)
	return out
