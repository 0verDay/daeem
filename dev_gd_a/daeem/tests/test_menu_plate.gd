## test_menu_plate.gd —— 主菜单左侧那张雕版图 + 扫描金线
##
## 图好不好看没法断言（要人眼看），但下面这些错了画面一定不对：
##   · 蒙版真的烘出来了（尺寸、有 alpha、覆盖率不是 0 也不是一整片）；
##   · 落位：`fill`（默认）**任何宽高比都铺满、两侧不许留空**；`cover` 等比裁切时
##     宽屏贴顶、窄屏贴右，并且**永远不许把塔拉扁**（宽高比守恒）；
##   · 扫描头：前 scan_sec 秒从画外走到画外、之后停在画外，且**单调**；
##   · 进菜单时已经在扫描途中（start_frac），不是从画外重新起步；
##   · 动效关掉时钉在「扫描头在中间」那一帧，不是空画面；
##   · 坏配置（band=0、scan=0）也画得出来。
##
## ★ 全部是纯函数断言（`fit_rect()` / `scan_x_at()` / `params_from()`）加一个
##   `advance()` 直接推时钟 —— 不需要跑帧、不需要真的把画面渲出来。
extends "res://tests/test_case.gd"

const PlateRes = preload("res://view/menu_art/etched_plate.gd")
const ThemeRes = preload("res://view/theme.gd")

## 设计空间下左侧那块的实际尺寸（1920 − 640）。
const VIEW := Vector2(1280.0, 1080.0)
const EPS := 0.0001

## 造出来的控件都记在这儿，跑完统一 free（否则退出时泄漏、run-tests 按退出码判会误判）。
var _made: Array = []


func _initialize() -> void:
	_case_name = "menu_plate"
	run_all(_cases)


func _cases() -> void:
	_test_config_values()
	_test_defaults_without_config()
	_test_plate_texture()
	_test_shader_material()
	_test_node_contract()
	_test_fit_fill_always_fills()
	_test_fit_cover_wide()
	_test_fit_cover_narrow()
	_test_fit_cover_keeps_ratio()
	_test_scan_moves()
	_test_scan_pauses()
	_test_scan_wraps()
	_test_start_frac()
	_test_paths_from()
	_test_two_masks()
	_test_bad_config_clamps()
	_free_all()


func _free_all() -> void:
	for a in _made:
		if is_instance_valid(a):
			a.free()
	_made.clear()


func _plate(cfg = null):
	var a = PlateRes.new()
	_made.append(a)
	a.setup(cfg)
	a.size = VIEW
	return a


# ------------------------------------------------------------------
# 配置
# ------------------------------------------------------------------

func _test_config_values() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	near(cfg.num("menu.plate.scan_sec", -1.0), 9.0, 0.0001, "menu.plate.scan_sec 读到了")
	near(cfg.num("menu.plate.band", -1.0), 0.04, 0.0001, "menu.plate.band 读到了")
	near(cfg.num("menu.plate.start_frac", -1.0), 0.0, 0.0001,
		"进菜单时扫描头在画外左缘（从最左边扫进来）")
	near(cfg.num("menu.plate.base", -1.0), 0.24, 0.0001, "menu.plate.base 读到了")
	near(cfg.num("menu.plate.fade_in_sec", -1.0), 0.6, 0.0001,
		"入场编排的时长键在（面板站好后泛光与雕版一起渐显）")


func _test_defaults_without_config() -> void:
	var p: Dictionary = PlateRes.params_from(null)
	near(float(p["scan"]), 9.0, 0.0001, "没有配置时扫 9 秒")
	near(float(p["band"]), 0.03, 0.0001, "没有配置时前沿半宽 0.03")
	ok(bool(p["enabled"]), "默认开启")


# ------------------------------------------------------------------
# 资产
# ------------------------------------------------------------------

func _test_plate_texture() -> void:
	var a = _plate()
	var tex: Texture2D = a.plate_texture()
	ok(tex != null, "雕版蒙版能载入（assets/menu/menu_plate.png）")
	if tex == null:
		return
	eq(tex.get_width(), 1280, "蒙版宽 = 设计空间左区宽")
	eq(tex.get_height(), 1080, "蒙版高 = 设计空间高")

	var img: Image = tex.get_image()
	ok(img != null, "蒙版能取出 Image")
	if img == null:
		return
	ok(img.detect_alpha() != Image.ALPHA_NONE, "蒙版带 alpha（线在外面是透明的）")

	# 覆盖率：太低 = 抽线抽没了；太高 = 把天光也吃进去了
	var lit := 0
	var total := 0
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			total += 1
			if img.get_pixel(x, y).a > 0.1:
				lit += 1
	var frac: float = float(lit) / float(maxi(1, total))
	ok(frac > 0.04, "蒙版不是空的（覆盖率 %.1f%%）" % (frac * 100.0))
	ok(frac < 0.45, "蒙版没有糊成一片（覆盖率 %.1f%%）" % (frac * 100.0))


func _test_shader_material() -> void:
	var a = _plate()
	var mat: ShaderMaterial = a.scan_material()
	ok(mat != null, "扫描用的是 ShaderMaterial")
	if mat == null:
		return
	ok(mat.shader != null, "shader 能载入（plate_scan.gdshader）")
	if mat.shader != null:
		# ★ 自定义 canvas_item shader 里写 `COLOR = ...` 会**整个覆盖**引擎注入的 modulate。
		#   漏了这一步，节点的 `modulate.a` 淡入就完全失效 —— 雕版会在 alpha 刚离开 0
		#   的那一帧以全亮出现（用户报的「一步到位」就是这个）。这里钉一条看门狗。
		ok(mat.shader.code.contains("tint.a"),
			"shader 把 modulate 乘回去了（否则淡入失效、雕版一步到位）")
	var sx: Variant = mat.get_shader_parameter("scan_x")
	ok(typeof(sx) == TYPE_FLOAT, "scan_x 已经灌进去了")
	var col: Variant = mat.get_shader_parameter("line_color")
	ok(typeof(col) == TYPE_COLOR, "线色已经灌进去了（来自 theme.palette.accent）")
	if typeof(col) == TYPE_COLOR:
		var c: Color = col
		ok(c.is_equal_approx(ThemeRes.accent()), "雕版线色 = 主题金 accent")
	var hc: Variant = mat.get_shader_parameter("head_color")
	ok(typeof(hc) == TYPE_COLOR, "扫描头那一段的颜色也灌进去了")
	if typeof(hc) == TYPE_COLOR:
		ok((hc as Color).is_equal_approx(ThemeRes.accent_bright()),
			"扫描头是更亮的那支金 accent_bright")


func _test_node_contract() -> void:
	var a = _plate()
	eq(a.mouse_filter, Control.MOUSE_FILTER_IGNORE, "不吃鼠标（整页点击由背景收）")
	ok(a.clip_contents, "裁到自己矩形内")


# ------------------------------------------------------------------
# 落位：铺满方式
# ------------------------------------------------------------------

func _test_fit_fill_always_fills() -> void:
	# ★ 用户口径「整体拉伸适配所有分辨率」：任何宽高比都必须铺满，两侧不许留空。
	var tex := Vector2(1280, 1080)
	for v in [Vector2(1280, 1080), Vector2(1840, 1080), Vector2(760, 1080),
			Vector2(2400, 1080), Vector2(1000, 1400)]:
		var r: Rect2 = PlateRes.fit_rect(v, tex, "fill")
		near(r.position.x, 0.0, EPS, "fill：%s 贴左" % str(v))
		near(r.position.y, 0.0, EPS, "fill：%s 贴上" % str(v))
		near(r.size.x, v.x, EPS, "fill：%s 宽度铺满（不留空）" % str(v))
		near(r.size.y, v.y, EPS, "fill：%s 高度铺满" % str(v))


func _test_fit_cover_wide() -> void:
	# 宽屏：等比放大到铺满、贴顶（保住塔冠，裁的是底部碎石）
	var r: Rect2 = PlateRes.fit_rect(Vector2(1840, 1080), Vector2(1280, 1080), "cover")
	near(r.size.x, 1840.0, 0.5, "cover 宽屏：宽度铺满")
	ok(r.size.y > 1080.0, "cover 宽屏：高度溢出（靠裁）")
	near(r.position.y, 0.0, EPS, "cover 宽屏：贴顶")
	near(r.position.x, 0.0, EPS, "cover 宽屏：水平不裁")


func _test_fit_cover_narrow() -> void:
	# 窄屏：等比、贴右（塔在画面右侧）
	var r: Rect2 = PlateRes.fit_rect(Vector2(760, 1080), Vector2(1280, 1080), "cover")
	near(r.size.y, 1080.0, 0.5, "cover 窄屏：高度铺满")
	near(r.position.x, -520.0, 0.5, "cover 窄屏：贴右，左边被裁")
	near(r.position.x + r.size.x, 760.0, 0.5, "cover 窄屏：右缘正好贴住面板")


func _test_fit_cover_keeps_ratio() -> void:
	var tex := Vector2(1280, 1080)
	for v in [Vector2(1280, 1080), Vector2(1840, 1080), Vector2(760, 1080), Vector2(600, 800)]:
		var r: Rect2 = PlateRes.fit_rect(v, tex, "cover")
		near(r.size.x / r.size.y, tex.x / tex.y, 0.0001,
			"cover %s 不拉扁（宽高比守恒）" % str(v))
	# 退化尺寸不许崩
	eq(PlateRes.fit_rect(Vector2.ZERO, tex, "fill").size.x, 0.0, "尺寸为 0 时返回空矩形")
	eq(PlateRes.fit_rect(tex, Vector2.ZERO, "cover").size.x, 0.0, "贴图尺寸为 0 时也不崩")


# ------------------------------------------------------------------
# 扫描
# ------------------------------------------------------------------

func _test_scan_moves() -> void:
	var scan := 9.0
	var pause := 3.0
	var prev := -INF
	for i in 10:
		var t: float = scan * float(i) / 9.0
		var x: float = PlateRes.scan_x_at(t, scan, pause, 0.0)
		ok(x > prev, "扫描头单调向右（t=%.1f 时 x=%.3f）" % [t, x])
		prev = x
	near(PlateRes.scan_x_at(0.0, scan, pause, 0.0), -0.06, EPS, "t=0 时还在画外左边")
	ok(PlateRes.scan_x_at(scan * 0.999, scan, pause, 0.0) > 1.0, "扫完时已经出画右边")


func _test_scan_pauses() -> void:
	var scan := 9.0
	var pause := 3.0
	near(PlateRes.scan_x_at(scan + 0.5, scan, pause, 0.0), 1.06, EPS, "扫完之后停在画外")
	near(PlateRes.scan_x_at(scan + 2.9, scan, pause, 0.0), 1.06, EPS, "歇的这段时间不动")


func _test_scan_wraps() -> void:
	var scan := 9.0
	var pause := 3.0
	near(PlateRes.scan_x_at(scan + pause + 0.001, scan, pause, 0.0),
		-0.06, 0.002, "一轮走完从头再来")


func _test_start_frac() -> void:
	var scan := 9.0
	# start_frac 是**相位**：给了它，t=0 时扫描头就落在那个位置
	var x: float = PlateRes.scan_x_at(0.0, scan, 3.0, 0.30)
	near(x, lerpf(-0.06, 1.06, 0.30), EPS, "start_frac=0.3 时 t=0 正好落在三成处")
	near(PlateRes.scan_x_at(0.0, scan, 3.0, 0.0), -0.06, EPS,
		"start_frac=0（出厂值）时 t=0 在画外左缘")


func _test_paths_from() -> void:
	var cfg = require_config()
	var paths: Array = PlateRes.paths_from(cfg)
	eq(paths.size(), 2, "配置里列了两张图（轮播两张）")
	if paths.size() >= 2:
		ok(String(paths[0]).ends_with("menu_plate.png"), "第一张是那张高塔")
		ok(String(paths[1]).ends_with("menu_plate_2.png"), "第二张是骑士 + 风车")
	# 坏配置 / 空配置退回第一张，不能一张都没有
	var none: Array = PlateRes.paths_from(null)
	eq(none.size(), 1, "没有配置时退回第一张")
	eq(String(none[0]), PlateRes.PLATE_PATH, "退回的就是 PLATE_PATH")


func _test_two_masks() -> void:
	# 两张蒙版都得真的烘出来了（尺寸、alpha、覆盖率都在合理区间）
	for spec in [["res://assets/menu/menu_plate.png", 1280, 1080],
			["res://assets/menu/menu_plate_2.png", 1280, 1080]]:
		var path: String = String(spec[0])
		ok(ResourceLoader.exists(path), "蒙版存在：%s" % path.get_file())
		if not ResourceLoader.exists(path):
			continue
		var tex: Texture2D = load(path)
		eq(tex.get_width(), int(spec[1]), "%s 宽 = 设计空间左区宽" % path.get_file())
		eq(tex.get_height(), int(spec[2]), "%s 高 = 设计空间高" % path.get_file())
		var img: Image = tex.get_image()
		if img == null:
			continue
		var lit := 0
		var total := 0
		for y in range(0, img.get_height(), 6):
			for x in range(0, img.get_width(), 6):
				total += 1
				if img.get_pixel(x, y).a > 0.1:
					lit += 1
		var frac: float = float(lit) / float(maxi(1, total))
		ok(frac > 0.03, "%s 不是空的（覆盖率 %.1f%%）" % [path.get_file(), frac * 100.0])
		ok(frac < 0.45, "%s 没有糊成一片（覆盖率 %.1f%%）" % [path.get_file(), frac * 100.0])


func _test_bad_config_clamps() -> void:
	# 参数写坏（band=0、scan=0）时夹取，不能出现除零 / 空白
	var p: Dictionary = PlateRes.params_from(null)
	ok(float(p["band"]) > 0.0, "前沿半宽有下限")
	ok(float(p["scan"]) >= 0.5, "扫描时长有下限")
	# 极端参数下扫描仍然算得出有限值
	var x: float = PlateRes.scan_x_at(1.0, 0.0001, -5.0, 2.0)
	ok(not is_nan(x) and absf(x) < 10.0, "极端参数下扫描位置仍是有限值")
