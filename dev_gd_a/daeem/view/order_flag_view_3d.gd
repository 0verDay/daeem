## order_flag_view_3d.gd —— 右键指令在目标点插的 **3D 旗子**（**无碰撞**，纯表现）
##
## ★★ 插旗动效（本版）：
##   1. 移动命令 `plant()` 在**落点上方一点点**（`render.order_flag_fall_height`，默认 0.15 格）
##      生成旗帜，快速落向落点；
##   2. 落地瞬间在旗下贴地扩散**一道旗色波纹**（`order_flag_ripple_*`）；
##   3. 整面旗（旗杆 + 旗面，以落点为轴）先压缩再回弹（`order_flag_impact_sec`）；
##      ★ 下落 + 回弹合计 ≈ 0.2s（用户口径：插旗动画要快），渐隐仍是下面那个独立时长。
##   4. 落地后 `order_flag_fade_sec` 内渐隐并消失 —— **不再**按「部队是否到达」决定收旗。
##   ★ 行军命令（`attack_move`）**不重播插下动画**：旗帜直接出现在落点，只做三件事 ——
##     旗色由绿渐变到黄（`order_flag_attack_color_sec`）、杆顶上方渐入**程序化红色交叉图标**、
##     立刻出现**黄色波纹**。旗帜的渐隐会**推迟到图标完全出现后**才开始。
##     图标是 SDF 矢量线段（见 `icon_texture()`），不是图片素材。
##
## ★ 生命周期（谁插、谁收）：
##   · **插**：`game_scene3d._on_command()` 收到本机的 `move` / `attack_move` 命令时调 `plant()`；
##     每道新命令**替换**当前唯一那面旗（只留最新）。
##   · **收**：动画自己走完（渐隐结束）；`attack` / `stop` 命令 → `game_scene3d` 直接 `clear()`。
##
## ★ 只读 `cfg` / `palette`（位置与配色），不读 `world`、不改任何逻辑状态；
##   节点上没有 CollisionObject ⇒ 天然无碰撞。
##
## ★ 动画由 `sync(dt)` 推进（`game_scene3d._process` 每帧调；暂停时传 0 ⇒ 动效冻结），
##   不用 Tween：这样测试可以逐帧推进并断言每个阶段。
extends Node3D

const ConfigRes = preload("res://logic/config.gd")

## 图标与波纹贴图的像素边长（正方形；SDF 光栅化，边缘自带抗锯齿）
const TEX_SIZE := 128
## 波纹贴图里圆环的半径（占贴图边长的比例）
const RIPPLE_RADIUS_RATIO := 0.42
## 波纹环的半厚（占贴图边长的比例）
const RIPPLE_HALF_RATIO := 0.028
## 波纹的软边（像素）
const RIPPLE_SOFT_PX := 2.0
## 波纹贴地高度（世界单位；抬高一点避免与地面共面）
const RIPPLE_Y := 1.0
## 旗杆颜色（渐隐时只改 alpha）
const POLE_COLOR := Color(0.92, 0.92, 0.95, 1.0)

## 红色交叉图标的**矢量线段**（归一化坐标：x 向右、y 向下，与贴图行方向一致）。
## 两条长对角线 + 下方两端各一条平行短斜线（程序化画出来，不依赖图片素材）。
const ICON_SEGMENTS := [
	[Vector2(0.02, 0.02), Vector2(0.98, 0.98)],
	[Vector2(0.98, 0.02), Vector2(0.02, 0.98)],
	[Vector2(0.04, 0.72), Vector2(0.23, 0.91)],
	[Vector2(0.96, 0.72), Vector2(0.77, 0.91)],
]

## 生成图贴的缓存（线宽 → ImageTexture；圆环只一张）
static var _icon_cache: Dictionary = {}
static var _ripple_cache: ImageTexture = null

var cfg: ConfigRes = null
var palette = null

var _root: Node3D = null
var _flag: Node3D = null
var _pole_mat: StandardMaterial3D = null
var _cloth_mat: StandardMaterial3D = null
var _icon_mat: StandardMaterial3D = null
var _ripple_mat: StandardMaterial3D = null
var _icon: MeshInstance3D = null
var _ripple: MeshInstance3D = null

## 当前命令
var kind: String = ""
var active: bool = false
## 动画阶段：idle / fall / settle / done（诊断 + 测试读）
var phase: String = "idle"

## 诊断（只有测试读）
var flags_planted: int = 0
var elapsed_last: float = 0.0
var fall_offset_last: float = 0.0
var scale_y_last: float = 1.0
var alpha_last: float = 1.0
var icon_alpha_last: float = 0.0
var icon_visible_last: bool = false
var icon_y_last: float = 0.0
var ripple_alpha_last: float = 0.0
var ripple_radius_last: float = 0.0
var ripple_color_last: Color = Color.WHITE
var cloth_color_last: Color = Color.WHITE

## 时间轴（秒）
var _fall_sec: float = 0.12
var _impact_sec: float = 0.08
var _fade_sec: float = 1.0
var _icon_fade_in_sec: float = 0.6
var _attack_color_sec: float = 0.6
var _ripple_sec: float = 0.5

## 形状 / 配色
var _fall_height: float = 0.0
var _squash_scale: float = 0.72
var _rebound_scale: float = 1.08
var _squash_width: float = 0.3
var _ripple_radius: float = 0.0
var _ripple_alpha: float = 0.85
var _icon_size: float = 0.0
var _icon_base_y: float = 0.0
var _move_color: Color = Color(0.30, 0.85, 0.39, 1.0)
var _attack_color: Color = Color(0.90, 0.76, 0.0, 1.0)
var _icon_color: Color = Color(0.90, 0.22, 0.23, 1.0)

## 运行时
var _elapsed: float = 0.0
var _fall_end: float = 0.0
var _fade_start: float = 0.0
var _fade_end: float = 0.0
var _landed: bool = false


func setup(p_cfg: ConfigRes, p_palette) -> void:
	cfg = p_cfg
	palette = p_palette
	var cell: float = palette.cell_size()
	var h: float = maxf(cell * 0.05, cell * cfg.num("render.flag_height", 0.5))
	var pole_r: float = maxf(0.5, cell * 0.015)
	var cloth_w: float = cell * 0.22
	var cloth_h: float = cell * 0.14

	# ---- 动效参数（全部来自 config，读一次缓存下来）----
	_move_color = ConfigRes.parse_color(cfg.str_val("render.flag_move_color", "#4cd964"))
	_attack_color = ConfigRes.parse_color(cfg.str_val("render.flag_attack_color", "#e6c200"))
	_icon_color = ConfigRes.parse_color(cfg.str_val("render.order_flag_icon_color", "#e5383b"))
	_fall_height = maxf(0.0, cell * cfg.num("render.order_flag_fall_height", 0.15))
	_fall_sec = maxf(0.001, cfg.num("render.order_flag_fall_sec", 0.12))
	_impact_sec = maxf(0.001, cfg.num("render.order_flag_impact_sec", 0.08))
	_fade_sec = maxf(0.001, cfg.num("render.order_flag_fade_sec", 1.0))
	_attack_color_sec = maxf(0.001, cfg.num("render.order_flag_attack_color_sec", 0.6))
	_icon_fade_in_sec = maxf(0.001, cfg.num("render.order_flag_icon_fade_in_sec", 0.6))
	_ripple_sec = maxf(0.001, cfg.num("render.order_flag_ripple_sec", 0.5))
	_ripple_radius = maxf(cell * 0.05, cell * cfg.num("render.order_flag_ripple_radius", 0.9))
	_ripple_alpha = clampf(cfg.num("render.order_flag_ripple_alpha", 0.85), 0.0, 1.0)
	_squash_scale = clampf(cfg.num("render.order_flag_squash_scale", 0.72), 0.3, 1.0)
	_rebound_scale = maxf(1.0, cfg.num("render.order_flag_rebound_scale", 1.08))
	_squash_width = clampf(cfg.num("render.order_flag_squash_width", 0.3), 0.0, 1.0)
	_icon_size = maxf(cell * 0.1, cell * cfg.num("render.order_flag_icon_size", 0.5))
	var icon_stroke: float = cfg.num("render.order_flag_icon_stroke", 0.05)
	var icon_gap: float = maxf(cell * 0.04, 2.0)

	# ---- 旗杆 ----
	var pole := CylinderMesh.new()
	pole.top_radius = pole_r
	pole.bottom_radius = pole_r
	pole.height = h
	pole.radial_segments = 6
	pole.rings = 1
	_pole_mat = _make_mat(POLE_COLOR)
	var pole_mi := MeshInstance3D.new()
	pole_mi.mesh = pole
	pole_mi.material_override = _pole_mat
	pole_mi.position = Vector3(0.0, h * 0.5, 0.0)     # 底边贴地

	# ---- 旗面：一块小方片，挂在杆顶、向 +X 伸出（cull_disabled ⇒ 两面都看得见）----
	var cloth := QuadMesh.new()
	cloth.size = Vector2(cloth_w, cloth_h)
	_cloth_mat = _make_mat(_move_color)
	var cloth_mi := MeshInstance3D.new()
	cloth_mi.mesh = cloth
	cloth_mi.material_override = _cloth_mat
	cloth_mi.position = Vector3(cloth_w * 0.5, h - cloth_h * 0.5, 0.0)

	# ---- 旗子本体（缩放以落点为轴：杆底贴地 ⇒ 压缩时往下压、不会浮空）----
	_flag = Node3D.new()
	_flag.name = "Flag"
	_flag.add_child(pole_mi)
	_flag.add_child(cloth_mi)

	# ---- 行军图标：杆顶正上方，竖立面向镜头（相机固定不旋转，+Z 面片正对镜头）----
	var icon_mesh := QuadMesh.new()
	icon_mesh.size = Vector2(_icon_size, _icon_size)
	_icon_base_y = h + icon_gap + _icon_size * 0.5
	var icon_c := _icon_color
	icon_c.a = 0.0
	_icon_mat = _make_mat(icon_c, icon_texture(icon_stroke))
	_icon = MeshInstance3D.new()
	_icon.name = "MarchIcon"
	_icon.mesh = icon_mesh
	_icon.material_override = _icon_mat
	_icon.position = Vector3(0.0, _icon_base_y, 0.0)
	_icon.visible = false

	# ---- 落地波纹：贴地圆形面片；缩放 = 向外扩散，alpha = 渐隐 ----
	var ripple_mesh := QuadMesh.new()
	ripple_mesh.size = Vector2(
		_ripple_radius / RIPPLE_RADIUS_RATIO,
		_ripple_radius / RIPPLE_RADIUS_RATIO)
	_ripple_mat = _make_mat(Color(_move_color.r, _move_color.g, _move_color.b, _ripple_alpha),
		ripple_texture())
	_ripple = MeshInstance3D.new()
	_ripple.name = "Ripple"
	_ripple.mesh = ripple_mesh
	_ripple.material_override = _ripple_mat
	_ripple.rotation = Vector3(-PI * 0.5, 0.0, 0.0)   # QuadMesh 默认在 XY 面 ⇒ 放平
	_ripple.position = Vector3(0.0, RIPPLE_Y, 0.0)
	_ripple.visible = false

	_root = Node3D.new()
	_root.name = "OrderFlag"
	_root.add_child(_flag)
	_root.add_child(_icon)
	_root.add_child(_ripple)
	_root.visible = false
	add_child(_root)


func _make_mat(c: Color, tex: Texture2D = null) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = c
	if tex != null:
		m.albedo_texture = tex
		# ★ 图标/波纹是 128² 的小图，会在缩放时被明显缩小 ⇒ 开 mipmap 防止闪烁
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return m


## 在 `pos`（格）插一面旗；每道新命令**替换**当前那面旗（只留最新）。
## ★ 行军命令不播放下落 / 压缩：旗帜直接出现在落点，只做变黄 + 图标 + 黄色波纹。
func plant(p_kind: String, pos: Vector2) -> void:
	if _root == null or palette == null:
		return
	kind = p_kind
	active = true
	flags_planted += 1
	var is_march: bool = kind == "attack_move"
	phase = "settle" if is_march else "fall"

	_elapsed = 0.0
	elapsed_last = 0.0
	_landed = false
	_fall_end = 0.0 if is_march else _fall_sec
	_fade_start = _fall_end
	if is_march:
		# ★ 行军：渐变图标完全出现后才开始渐隐（见文件头）
		_fade_start = maxf(_fade_start, _icon_fade_in_sec)
	_fade_end = _fade_start + _fade_sec

	# 行军直接落在落点；移动从「离地一点点」的高度落下
	var start_y: float = 0.0 if is_march else _fall_height
	_root.position = palette.to_world(pos)
	_root.visible = true
	_flag.position = Vector3(0.0, start_y, 0.0)
	_flag.scale = Vector3.ONE
	fall_offset_last = start_y
	scale_y_last = 1.0
	alpha_last = 1.0
	cloth_color_last = _move_color
	_apply_flag_color(_move_color, 1.0)

	_icon.visible = is_march
	_icon.position = Vector3(0.0, _icon_base_y + start_y, 0.0)
	icon_y_last = _icon.position.y
	icon_visible_last = false
	icon_alpha_last = 0.0
	var ic := _icon_color
	ic.a = 0.0
	_icon_mat.albedo_color = ic

	_ripple.visible = false
	_ripple_t_reset()

	# 行军：立刻进入 settle（生成黄色波纹、更新颜色/图标起点），不再等下落
	if is_march:
		_update()


## 收旗（attack / stop，或场景重建）。
func clear() -> void:
	active = false
	phase = "idle"
	kind = ""
	_elapsed = 0.0
	elapsed_last = 0.0
	_landed = false
	if _root != null:
		_root.visible = false
	if _icon != null:
		_icon.visible = false
	if _ripple != null:
		_ripple.visible = false
	ripple_alpha_last = 0.0
	icon_alpha_last = 0.0
	icon_visible_last = false


## 每帧推进动画。`dt` = 0（暂停 / 测试里只想看当前状态）时**不推进**。
func sync(dt: float = 0.0) -> void:
	if _root == null:
		return
	if not active:
		_root.visible = false
		return
	if dt > 0.0:
		_elapsed += dt
		elapsed_last = _elapsed
	_update()


func _update() -> void:
	if _elapsed < _fall_end:
		# ---- 下落：重力加速（1 - p²），位置从上方回到落点 ----
		phase = "fall"
		var p: float = clampf(_elapsed / _fall_end, 0.0, 1.0)
		var off: float = _fall_height * (1.0 - p * p)
		_flag.position = Vector3(0.0, off, 0.0)
		_flag.scale = Vector3.ONE
		# ★ 图标始终在旗杆正上方：下落时跟着旗子一起降（避免旗子从图标里穿过去）
		_icon.position = Vector3(0.0, _icon_base_y + off, 0.0)
		icon_y_last = _icon.position.y
		fall_offset_last = off
		scale_y_last = 1.0
		alpha_last = 1.0
		_set_flag_alpha(1.0)
		_update_icon(1.0)
		_ripple.visible = false
		return

	# ---- 落地：波纹只生成一次 ----
	if not _landed:
		_landed = true
		_spawn_ripple()
	phase = "settle"
	_flag.position = Vector3.ZERO
	_icon.position = Vector3(0.0, _icon_base_y, 0.0)
	icon_y_last = _icon.position.y
	fall_offset_last = 0.0

	# ---- 压缩 → 回弹 → 复位（整面旗，纵向缩放；横向略微鼓出）----
	# ★ 行军命令不重播插下动画 ⇒ 不做压缩/回弹，始终 100%。
	var sy: float = 1.0
	var sxz: float = 1.0
	if kind != "attack_move":
		var ts: float = clampf((_elapsed - _fall_end) / _impact_sec, 0.0, 1.0)
		sy = _squash_curve(ts)
		sxz = 1.0 + (1.0 - sy) * _squash_width
	_flag.scale = Vector3(sxz, sy, sxz)
	scale_y_last = sy

	# ---- 渐隐（移动：落地后；行军：图标完全出现后）----
	var fade: float = clampf((_elapsed - _fade_start) / _fade_sec, 0.0, 1.0)
	var a: float = 1.0 - fade
	alpha_last = a
	_set_flag_alpha(a)
	_update_icon(a)
	_update_ripple()

	if _elapsed >= _fade_end:
		_finish()


func _finish() -> void:
	active = false
	phase = "done"
	alpha_last = 0.0
	icon_alpha_last = 0.0
	icon_visible_last = false
	ripple_alpha_last = 0.0
	_root.visible = false


## 当前旗色：移动 = 绿；行军 = 从绿按时间渐变到黄。
func _current_color() -> Color:
	if kind != "attack_move":
		return _move_color
	var t: float = clampf(_elapsed / _attack_color_sec, 0.0, 1.0)
	return _move_color.lerp(_attack_color, t)


## 旗杆 + 旗面一起改色 / 改透明度（旗杆只有 alpha 变化）。
func _apply_flag_color(c: Color, a: float) -> void:
	_cloth_mat.albedo_color = Color(c.r, c.g, c.b, a)
	_pole_mat.albedo_color = Color(POLE_COLOR.r, POLE_COLOR.g, POLE_COLOR.b, a)


func _set_flag_alpha(a: float) -> void:
	var c: Color = _current_color()
	cloth_color_last = c
	_apply_flag_color(c, a)


## 图标：移动命令不显示；行军命令随 `elapsed` 渐入，渐隐时与旗同 alpha 一起降。
func _update_icon(flag_alpha: float) -> void:
	if kind != "attack_move":
		_icon.visible = false
		icon_visible_last = false
		icon_alpha_last = 0.0
		return
	var fade_in: float = clampf(_elapsed / _icon_fade_in_sec, 0.0, 1.0)
	var a: float = fade_in * flag_alpha
	icon_alpha_last = a
	icon_visible_last = a > 0.001
	_icon.visible = icon_visible_last
	_icon_mat.albedo_color = Color(_icon_color.r, _icon_color.g, _icon_color.b, a)


func _ripple_t_reset() -> void:
	ripple_alpha_last = 0.0
	ripple_radius_last = 0.0
	ripple_color_last = Color.WHITE


## 落地波纹。移动 = 当前旗色（绿）；行军 = **黄色**（用户口径：行军只做黄旗 + 红图标 + 黄波纹）。
func _spawn_ripple() -> void:
	var c: Color = _attack_color if kind == "attack_move" else _current_color()
	ripple_color_last = c
	_ripple_mat.albedo_color = Color(c.r, c.g, c.b, _ripple_alpha)
	_ripple.scale = Vector3.ONE * 0.12
	_ripple.visible = true
	ripple_alpha_last = _ripple_alpha
	ripple_radius_last = _ripple_radius * 0.12
	_update_ripple()


func _update_ripple() -> void:
	var tr: float = clampf((_elapsed - _fall_end) / _ripple_sec, 0.0, 1.0)
	if tr >= 1.0:
		_ripple.visible = false
		ripple_alpha_last = 0.0
		return
	# 由小到大、先快后慢；alpha 一直降到 0
	var e: float = 1.0 - (1.0 - tr) * (1.0 - tr)
	var s: float = lerpf(0.12, 1.0, e)
	_ripple.scale = Vector3(s, s, s)
	var a: float = _ripple_alpha * (1.0 - tr)
	_ripple_mat.albedo_color = Color(_ripple_mat.albedo_color.r, _ripple_mat.albedo_color.g,
		_ripple_mat.albedo_color.b, a)
	ripple_alpha_last = a
	ripple_radius_last = _ripple_radius * s


## 纵向缩放曲线：0 → 1（压缩）→ 过冲（回弹）→ 1（舒张）。
## ★ 压缩段 22%、回弹段 36%、复位段 42%（比例写死，总时长走 config）。
func _squash_curve(t: float) -> float:
	if t < 0.22:
		return lerpf(1.0, _squash_scale, _ease_out(t / 0.22))
	if t < 0.58:
		return lerpf(_squash_scale, _rebound_scale, _smooth((t - 0.22) / 0.36))
	return lerpf(_rebound_scale, 1.0, _smooth((t - 0.58) / 0.42))


static func _ease_out(k: float) -> float:
	return 1.0 - (1.0 - k) * (1.0 - k)


static func _smooth(k: float) -> float:
	return k * k * (3.0 - 2.0 * k)


# ------------------------------------------------------------------
# 程序化贴图（矢量线段 / 圆环 → SDF 光栅化）
# ------------------------------------------------------------------

## 行军图标的贴图：白剪影 + alpha（红色由材质 albedo 乘上去）。
## ★ 四条线段写在 `ICON_SEGMENTS` 里；`stroke_ratio` = 线宽 ÷ 图标边长。
static func icon_texture(stroke_ratio: float = 0.05) -> ImageTexture:
	var stroke: float = clampf(stroke_ratio, 0.01, 0.2)
	var key: String = "%.4f" % stroke
	var hit: Variant = _icon_cache.get(key, null)
	if hit != null:
		return hit
	var n := TEX_SIZE
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var half_px: float = maxf(1.0, stroke * float(n) * 0.5)
	for y in n:
		for x in n:
			var pp := Vector2(float(x) + 0.5, float(y) + 0.5)
			var best := 1.0e9
			for seg in ICON_SEGMENTS:
				var sa: Vector2 = seg[0] * float(n)
				var sb: Vector2 = seg[1] * float(n)
				best = minf(best, _segment_dist(pp, sa, sb))
			var a: float = clampf(half_px + 0.5 - best, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_icon_cache[key] = tex
	return tex


## 落地波纹的贴图：白圆环 + alpha（颜色由材质 albedo 乘上去）。
static func ripple_texture() -> ImageTexture:
	if _ripple_cache != null:
		return _ripple_cache
	var n := TEX_SIZE
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := Vector2(float(n) * 0.5, float(n) * 0.5)
	var r: float = float(n) * RIPPLE_RADIUS_RATIO
	var half_px: float = maxf(1.0, float(n) * RIPPLE_HALF_RATIO)
	for y in n:
		for x in n:
			var d: float = (Vector2(float(x) + 0.5, float(y) + 0.5) - c).length()
			var a: float = clampf(
				(half_px + RIPPLE_SOFT_PX - absf(d - r)) / RIPPLE_SOFT_PX,
				0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	img.generate_mipmaps()
	_ripple_cache = ImageTexture.create_from_image(img)
	return _ripple_cache


## 点到线段的距离（像素空间；带圆头端点的胶囊距离）。
static func _segment_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var denom: float = ab.length_squared()
	if denom <= 0.0:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / denom, 0.0, 1.0)
	return p.distance_to(a + ab * t)
