## overlay_view_3d.gd —— 3D 版的覆盖层：血条 / 网格 / 区划轮廓 / 粮车光环范围 /
##                       占领进度条 / 建造预览 / 拖框 / 头顶编队标识（键帽 / 名牌）
##
## ★★ 为什么这一层留在 **2D 屏幕空间**而不是做成 3D 物件（本版的重要取舍）：
##   · 它们是**界面反馈**，不是世界里的东西 —— 玩家要的是「我的部队在哪、点到哪」，
##     这些东西**不该跟着地面倾斜**（跟着歪会难读，也容易与地形混淆）；
##   · 画在 `CanvasLayer` 上的 `Control` 里，天然 1:1、不受透视影响、
##     也不需要为每个标记建 3D 节点（1000 个单位全选时那就是 1000 个节点）。
##   定位靠 `palette.to_px(格)` —— 与「点在哪」用的是同一条投影链路，
##   所以标记与鼠标**天然对齐**（这正是本项目最容易错位的地方）。
##
## ★ 只读逻辑状态 + 只读本地 UI 状态；不发命令、不改逻辑。
extends Control

const ConfigRes = preload("res://logic/config.gd")
const PaletteRes = preload("res://view/palette.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")
## ★★ 局内「敌 / 友 / 己」三色（本轮新增）：占领条 / 占领触发区 / 血条都走它
const SideColorRes = preload("res://view/side_color.gd")
## ★★ HUD 的皮肤（暗色面板 + 暗金细线 + 琥珀强调）：头顶标识与右栏数字块共用同一套色。
##   ★ 本文件只读它的静态取色函数，不持有主题实例（见 view/theme.gd 的说明）。
const ThemeRes = preload("res://view/theme.gd")
## ★★ 2026.10.27（性能）：覆盖层的**静态层**放在这个独立子节点里（见 view/overlay_layer.gd）。
##   原因：本节点为了画血条 / 拖框 / 编队标识必须每帧重画，而网格 / 区划轮廓 /
##   占领触发区只随相机与归属变化 —— 放在同一个 CanvasItem 里就等于每帧重录一遍。
const OverlayLayerRes = preload("res://view/overlay_layer.gd")

const HP_BACK_COLOR := Color(0, 0, 0, 0.55)

# ------------------------------------------------------------------
# ★★ 头顶编队标识（本轮改版）：**常驻键帽徽章 + 选中名牌**
#
# 口径（与右栏「部队 1~10」的数字块同一套视觉语言）：
#   · 未选中：只画一个**键帽**（深色底 + 暗金细线 + 底边阵营色），回答「这是第几支」；
#   · 选中：换成**名牌**（键帽 + 兵种字 + 名字 + 编制 + 士气条），回答「这是谁」；
#   · 倒地：整体压暗，名牌的编制位置改成「再起 / 倒地」；
#   · 编号口径不变：`world.units` 里「存活 + 同方 + 队长」数到第几个——
#     与左栏 / 数字键选中的是**同一支部队**（见 `_draw_team_markers`）。
#
# ★ 为什么选中时**换掉**键帽而不是叠在它上面：两个数字上下叠会互相打架；名牌本身带键帽，
#   「换」等于同一个位置从「按键提示」升级成「部队名片」。
# ★ 尺寸是**屏幕像素**（字永远正着、1:1）；键帽大小只跟着立牌的屏幕高度轻微浮动，
#   所以远看不会比兵还大、近看也不会缩成一个点。
# ------------------------------------------------------------------
## 键帽边长：`quad 屏幕高 × BADGE_SPRITE_RATIO`，再夹到 [MIN, MAX]。
const BADGE_SPRITE_RATIO := 0.62
const BADGE_MIN_PX := 16.0
const BADGE_MAX_PX := 26.0
## 键帽底边离「立牌头顶」多少像素（血条在 -4..-1，这里留出空隙）。
const BADGE_GAP := 7.0
const BADGE_RADIUS := 3
const BADGE_ALPHA := 0.94
## 键帽底边那条阵营色（与右栏数字块 / 血条同一个色源）。
const BADGE_STRIP_H := 2.5
## 名牌：固定高度，宽度按内容算（上限 NAMEPLATE_MAX_W）。
const NAMEPLATE_H := 27.0
const NAMEPLATE_GAP := 8.0
const NAMEPLATE_PAD := 5.0
const NAMEPLATE_KEY := 20.0
const NAMEPLATE_KEY_GAP := 5.0
const NAMEPLATE_KEY_FONT := 14
const NAMEPLATE_FONT := 13
const NAMEPLATE_FORM_FONT := 12
const NAMEPLATE_MAX_W := 200.0
const NAMEPLATE_RADIUS := 4
const NAMEPLATE_ALPHA := 0.94
## 多个名牌互相压住时，纵向让位的间隙（每次 `NAMEPLATE_H + 这个值`）。
const NAMEPLATE_STACK_PX := 8.0
## 倒地将领的键帽 / 名牌整体不透明度。
const DOWNED_MARKER_ALPHA := 0.45

var cfg: ConfigRes = null
var world = null
var palette = null
var units = null
## ★★ 稳定编队槽位（见 view/team_slots.gd）：己方键帽 / 名牌上的编号取它，
##   阵亡 / 复活后不变。为 null 时退回「存活顺序」。
var team_slots = null
## ★★ 头顶编队标识用的字体（`FontLoaderRes` 一次载入；null 时整组标识跳过）。
var font: Font = null
## ★ 地面层（`ground_view.gd`）：只用来问「这一格的哪几条边是区划边界」
##   与「这个区划的轮廓该是什么颜色」。它**只读**，不改任何东西。
var ground = null

## ★★ 头顶标识的六种 StyleBox（键帽普通 / 选中 / 倒地、名牌普通 / 倒地、键帽内块）。
##   在 `setup()` 里建一次：`_draw()` 每帧只做 `draw_style_box()`，不再临时 new。
var _style_badge: StyleBoxFlat = null
var _style_badge_sel: StyleBoxFlat = null
var _style_badge_downed: StyleBoxFlat = null
var _style_name: StyleBoxFlat = null
var _style_name_downed: StyleBoxFlat = null
var _style_key: StyleBoxFlat = null
var _style_key_downed: StyleBoxFlat = null

## 由 game_scene / input_controller 每帧塞进来的纯本地状态
var hover_tile: Vector2i = Vector2i(-1, -1)
var hover_valid: bool = false
var build_type: String = ""
var move_marks: Array[Vector2] = []
var attack_marks: Array[Vector2] = []
var drag_active: bool = false
var drag_rect: Rect2 = Rect2()
## ★★ 粮车光环范围（只在该粮车被选中时画）：屏幕像素细线宽 / 采样段数。
##   细分段数够多，透视下才会是一圈顺滑的**地面椭圆**，而不是多边形。
const AURA_RANGE_SEGMENTS := 96
const AURA_RANGE_WIDTH := 1.25
const AURA_RANGE_ALPHA := 0.85
## ★ 触摸设备的选框：两指的**屏幕矩形**（`drag_screen_valid` 为真时优先按它画）。
##   见 `_draw_drag_box()` 的说明 —— 这是「框跟手」那条口径的落点。
var drag_screen_box: Rect2 = Rect2()
var drag_screen_valid: bool = false
var mouse_world: Vector2 = Vector2.ZERO
var debug_aim: bool = false

## 诊断（只有测试读它）：最近一次 `_draw()` 发出的绘制命令数
var draw_count: int = 0
var unit_ui_seen: int = 0
var unit_ui_visible: int = 0
var unit_ui_bars: int = 0
## ★ 最近一次 `_draw()` 画了几个粮车光环圈（单位是「被选中的粮车数」；测试读它）
var aura_range_draw_count: int = 0
## ★★ 最近一次 `_draw()` 画了几个**键帽** / 几张**名牌**（测试 / 排查读它）。
##   选中且名牌成功放下的将领只算名牌、不算键帽（两者是互斥的两种状态）。
var badge_draw_count: int = 0
var nameplate_draw_count: int = 0


func setup(p_cfg: ConfigRes, p_world, p_palette, p_units, p_ground = null,
		p_team_slots = null) -> void:
	cfg = p_cfg
	world = p_world
	palette = p_palette
	units = p_units
	ground = p_ground
	team_slots = p_team_slots
	font = FontLoaderRes.load_font(cfg)
	_build_marker_styles()
	# 铺满屏幕、但不吃鼠标（输入走 input_controller 那条路）
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# ★ 新场景 / 新地图 ⇒ 静态投影缓存一律作废（相机对象也换了）
	_static_ready = false
	_grid_screen = PackedVector2Array()
	_zone_screen = []
	_capture_screen = []
	_build_static_layer()


## ★★ 建「静态层」子节点（见文件头与 view/overlay_layer.gd）。
##
## 为什么是**子节点 + show_behind_parent**，而不是把动态部分挪进子节点：
##   动态部分有 30+ 处 `draw_*` 调用（血条 / 拖框 / 名牌…），静态部分只有 4 处
##   （网格 1、区划轮廓 N、触发区 4N）。动静倒过来改，改动面小一个数量级，
##   而 z 序照样正确：`show_behind_parent = true` 让它画在宿主自己的绘制**之下**。
func _build_static_layer() -> void:
	if _static_layer != null:
		return
	_static_layer = OverlayLayerRes.new()
	_static_layer.name = "OverlayStatic"
	_static_layer.host = self
	_static_layer.which = 0
	_static_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_static_layer.show_behind_parent = true
	_static_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_static_layer)


## 静态层这一帧要不要重画？（相机 / 视口 / 区划归属任一变化）
##
## ★ 与 `_refresh_static_projection()` 共用同一个判据（`_static_key_changed`），
##   所以这里说「要重画」而实际 `_draw` 里发现没变的情况不会发生。
func poll_static_dirty() -> bool:
	if _static_layer == null:
		return false
	if _static_key_changed():
		_static_layer.queue_redraw()
		return true
	return false


func sync() -> void:
	# 动态层（本节点自己）：每帧都变（血条跟单位走、拖框跟手指走）
	queue_redraw()
	# 静态层：只在相机 / 视口 / 归属变化时重录 —— 相机静止时这一段是 0 成本
	poll_static_dirty()


## 静态层要重画了：**只算几何**，绘制由 `view/overlay_layer.gd` 的 `_draw_static()` 发。
##
## ⚠️ `draw_*` 只允许在**它自己**的 `_draw()` 里调用（实测：从宿主调
##    `layer.draw_polygon()` 会报 "Drawing is only allowed inside this node's `_draw()`"），
##    所以这里一律不碰绘制 API，只把「已经验过、可以直接画」的数据放进 `node`。
func build_static_layer_data(node) -> void:
	if node == null:
		return
	var t0: int = Time.get_ticks_usec() if (world != null and world.profile_on) else 0
	# 静态层的几何要在这里才保证是新的（相机刚动过的那一帧 `sync()` 已经排了重画）
	_refresh_static_projection()

	# ① 网格：只在建造模式下画（`build_type` 非空）
	if build_type == "":
		grid_draw_count = 0
		node.grid_pts = PackedVector2Array()
	else:
		grid_draw_count = _count_grid_lines()
		node.grid_pts = _grid_screen
	node.grid_color = GRID_COLOR
	node.grid_width = GRID_WIDTH

	# ② 区划轮廓：缓存的屏幕顶点（已按相机键失效、并做过屏幕外剔除）
	zone_outline_draw_count = _count_zone_outlines()
	node.zone_groups = _zone_screen
	node.zone_width = ZONE_OUTLINE_WIDTH

	# ③ 占领触发区：四条边的渐变梯形。**在这里**做面积 / 凸性判定并算好逐顶点颜色，
	#    子节点那边只发 `draw_polygon` —— 判据仍然只有一处（`_drawable_grad_quad`）。
	var items: Array = _visible_capture_areas()
	capture_area_count = items.size()
	var quads: Array = []
	for it in items:
		var o: PackedVector2Array = it["outer"]     # 顺序：左上, 右上, 右下, 左下
		var i: PackedVector2Array = it["inner"]     # 同上
		var oc: Color = it["outer_c"]
		var ic: Color = it["inner_c"]
		# 四条边各一个梯形：外沿 = 邻域边框，内沿 = 整体内缩 g 格（「画框」拼法）
		_push_grad_quad(quads, PackedVector2Array([o[0], o[1], i[1], i[0]]), oc, ic)   # 上
		_push_grad_quad(quads, PackedVector2Array([o[1], o[2], i[2], i[1]]), oc, ic)   # 右
		_push_grad_quad(quads, PackedVector2Array([o[2], o[3], i[3], i[2]]), oc, ic)   # 下
		_push_grad_quad(quads, PackedVector2Array([o[3], o[0], i[0], i[3]]), oc, ic)   # 左
	node.capture_quads = quads

	if t0 != 0:
		world.profile_us["draw/overlay_static"] = \
			int(world.profile_us.get("draw/overlay_static", 0)) + (Time.get_ticks_usec() - t0)


## 建一次头顶标识的 StyleBox：颜色全走 `view/theme.gd`（暗金细线 / 琥珀强调 / 深色面板），
## 形状与尺寸是本文件顶部的度量常量 —— 与 HUD 的分工完全一致（配色进 JSON、度量进代码）。
func _build_marker_styles() -> void:
	var bg: Color = ThemeRes.panel_alpha_color(BADGE_ALPHA, false)
	_style_badge = _plate_box(bg, ThemeRes.line(), 1, BADGE_RADIUS)
	_style_badge_sel = _plate_box(bg, ThemeRes.accent(), 2, BADGE_RADIUS)
	_style_badge_downed = _plate_box(
		ThemeRes.with_alpha(bg, DOWNED_MARKER_ALPHA),
		ThemeRes.with_alpha(ThemeRes.line(), 0.65), 1, BADGE_RADIUS)
	var nbg: Color = ThemeRes.panel_alpha_color(NAMEPLATE_ALPHA, false)
	_style_name = _plate_box(nbg, ThemeRes.accent(), 1, NAMEPLATE_RADIUS)
	_style_name_downed = _plate_box(
		ThemeRes.with_alpha(nbg, NAMEPLATE_ALPHA * 0.85),
		ThemeRes.with_alpha(ThemeRes.warning(), 0.85), 1, NAMEPLATE_RADIUS)
	_style_key = _plate_box(ThemeRes.panel_alpha_color(0.98, true),
		ThemeRes.line_soft(), 1, BADGE_RADIUS)
	_style_key_downed = _plate_box(
		ThemeRes.with_alpha(ThemeRes.panel_alpha_color(0.98, true), 0.55),
		ThemeRes.with_alpha(ThemeRes.warning(), 0.6), 1, BADGE_RADIUS)


static func _plate_box(bg: Color, border: Color, border_w: int, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(radius)
	return sb


# ------------------------------------------------------------------
# 静态投影缓存（网格 / 区划轮廓 / 占领触发区）
# ------------------------------------------------------------------

## 相机 / 视口 / 区划归属变了吗？（只读，不改缓存）
##
## ★ 判据用**值比较**（Transform3D / Projection / Vector2），不是哈希：
##   每帧只比 12 + 16 + 2 个浮点数，比「拼一个字符串当键」便宜得多。
## ★ 相机只平移不旋转（见 architecture.md 4.3），但这里不假设这一点：
##   整个变换都参与比较，将来加旋转也不会漏失效。
## ★ 区划签名每帧都算一次（几十个区块、纯字符串拼接），但它是**唯一**能发现
##   「归属变了、轮廓颜色要换」的判据；相机静止时这点开销可以忽略。
func _static_key_changed() -> bool:
	if not _static_ready or palette == null or palette.cam == null:
		static_last_reason = "init"
		return true
	var cam: Camera3D = palette.cam
	var xf: bool = cam.global_transform != _static_key_xform
	var pj: bool = cam.get_camera_projection() != _static_key_proj
	var vp: bool = get_viewport_rect().size != _static_key_vp
	var sg: bool = _zone_edge_signature() != _static_key_zone_sig
	if xf or pj or vp or sg:
		static_last_reason = "%s%s%s%s" % [
			"x" if xf else "", "p" if pj else "", "v" if vp else "", "s" if sg else ""]
		return true
	return false


func _remember_static_key() -> void:
	var cam: Camera3D = palette.cam
	_static_key_xform = cam.global_transform
	_static_key_proj = cam.get_camera_projection()
	_static_key_vp = get_viewport_rect().size
	_static_key_zone_sig = _zone_edge_signature()
	_static_ready = true


## 重建静态层缓存。只有 `_static_key_changed()` 为真时才真的干活。
##
## ★ 顺序：先更新**格坐标**几何（`_count_zone_outlines()` 按签名重建 `_zone_segs`），
##   再逐组投影 —— 反过来会拿到上一版几何。
func _refresh_static_projection() -> void:
	if not _static_key_changed():
		return
	_remember_static_key()
	static_rebuild_count += 1
	if world == null or world.map == null:
		_grid_screen = PackedVector2Array()
		_zone_screen = []
		_capture_screen = []
		return

	_grid_screen = _project_segments(
		_grid_segs_for(int(world.map.cols), int(world.map.rows)))

	# 区划轮廓：按组投影一次，之后每帧只重新 `draw_multiline`。
	# ★ 屏幕外接框与视口不相交的整组丢掉 —— 拉近视角时地图上大部分轮廓都在屏幕外，
	#   丢掉之后既省 draw 调用，也省 GPU 的裁剪工作（判据只在相机变化时算一次）。
	_count_zone_outlines()
	_zone_screen = []
	var vp: Rect2 = Rect2(Vector2.ZERO, get_viewport_rect().size).grow(64.0)
	for entry in _zone_segs:
		var segs: PackedVector2Array = _project_segments(entry["segs"])
		if segs.is_empty() or not _pts_bbox_intersects(segs, vp):
			continue
		_zone_screen.append({"segs": segs, "color": entry["color"]})

	_capture_screen = _compute_visible_capture_areas()


## 一串屏幕顶点（成对存放）的轴对齐包围盒与 `rect` 相交吗？
static func _pts_bbox_intersects(pts: PackedVector2Array, rect: Rect2) -> bool:
	if pts.is_empty():
		return false
	var mn := pts[0]
	var mx := pts[0]
	for p in pts:
		mn = mn.min(p)
		mx = mx.max(p)
	return rect.intersects(Rect2(mn, mx - mn))


func _draw() -> void:
	# ★★ 只统计**真正的 `_draw` 命令录制**（手机读数开 `profile_on` 时才付两次时钟调用）。
	#    它不在 `game_scene3d._process` 的分段里，是 `rest` 的主要候选之一。
	var t0: int = Time.get_ticks_usec() if (world != null and world.profile_on) else 0
	_draw_impl()
	if t0 != 0:
		world.profile_us["draw/overlay"] = int(world.profile_us.get("draw/overlay", 0)) \
			+ (Time.get_ticks_usec() - t0)


func _draw_impl() -> void:
	draw_count = 0
	if cfg == null or world == null or palette == null:
		return
	# ★★ 2026.10.27（性能）：**静态三件套（网格 / 区划轮廓 / 占领触发区）不在这里画** ——
	#    它们搬到了独立子节点 `OverlayStatic`（见 `_build_static_layer()` 与
	#    `view/overlay_layer.gd`），只随相机 / 视口 / 归属变化重录。
	#    本节点现在每帧只重录**动态**部分：粮车光环 / 占领进度条 / AI 目标环 /
	#    血条 / 建造预览 / 拖框 / 编队标识。
	# ★ 顺序即层次（后画的在上面）：地面上的东西 → 单位头上的 UI → 最顶上的编队标识。
	var _d0 := _pt()
	_draw_aura_ranges()
	_pd("ov/aura", _d0)
	var _d1b := _pt()
	_draw_zone_capture()
	_pd("ov/capture_bar", _d1b)
	var _d2 := _pt()
	_draw_ai_marks()
	_pd("ov/ai_marks", _d2)
	var _d3 := _pt()
	_draw_units_ui()
	_pd("ov/units_ui", _d3)
	# ★ 移动 / 行军目标点不再在这里画圈 —— 改成 3D 旗子（view/order_flag_view_3d.gd）
	_draw_build_preview()
	_draw_drag_box()
	# ★★ 编队标识最后画：它在**所有世界物件与其它覆盖层之上**（不会被建筑 / 地形 / 单位
	#    遮挡）；同时它在拖框之上，框选时编号 / 名牌仍然读得清。
	var _d4 := _pt()
	_draw_team_markers()
	_pd("ov/team_markers", _d4)


## 剖析辅助（只在 `world.profile_on` 时计时）。
func _pt() -> int:
	return Time.get_ticks_usec() if (world != null and world.profile_on) else 0


func _pd(key: String, t0: int) -> void:
	if t0 != 0:
		world.profile_us[key] = int(world.profile_us.get(key, 0)) \
			+ (Time.get_ticks_usec() - t0)


# ------------------------------------------------------------------
# 地面上的"线"：网格 / 区划轮廓 / 占领进度条（本轮从贴图搬到这里）
# ------------------------------------------------------------------
##
## ★★ 为什么必须是**屏幕空间**（用户报「占领的进度条还是太糊了」的正面回答）：
##   这图形里的「线」原来烘在地面贴图里，而贴图是「每格 16 像素」再被放大到
##   一格约 30 屏幕像素 ⇒ 1 像素的线变成 2 像素的**软边**、1 像素 = 1 格的进度贴图
##   更糟（一个纹素铺满整格，LINEAR 的插值就在整格宽度上摊开成 30 px 的渐变）。
##   **烘到低分辨率贴图上再放大，永远不可能像 2D 那样清晰。**
##   2D 版是 `draw_rect` / `draw_multiline` 直接画在画布上 ⇒ 天然逐像素清晰、
##   斜线还有引擎的抗锯齿。这里改成同一套画法之后，
##   ① 线宽是**屏幕像素**（不随缩放变糊）；② 斜线由引擎抗锯齿；
##   ③ 与地块的关系仍然正确 —— 因为**格角是逐个投影出来的**（`palette.to_px`），
##      与 `input_controller` 判"鼠标点在哪一格"用的是同一条链路。

## 网格线的颜色与宽度（屏幕像素）
##
## ★★ 为什么是 **2 px**（实测定的，不是拍脑袋）：
##   屏幕空间的 1 px 线落在**像素边界**上时，引擎的抗锯齿会把它摊到相邻两个像素
##   各一半 ⇒ 亮度只有理论值的一半，实测对比度 **6.8~7.4%**（看起来是"一条软线"）。
##   2 px 之后线的墨量翻倍、不再受半像素落点的影响，实测对比度回到 **~18%**
##   （与「烘进贴图、再放大」那版 18.83% 同一档，但那条路在缩放时会糊）。
## ★ 颜色用 16% 白：与 2D 版 `colors.grid`（5.5% 白）相比更亮 ——
##   因为 2D 是**轴对齐**的实心矩形，而这里是抗锯齿的 2 px 线。
##   ⚠️ 不要再加粗到 3 px 以上：用户当年报过「地图上的格子中有很多奇怪的线条」，
##     那是同一类反感（线抢戏）。
const GRID_COLOR := Color(1.0, 1.0, 1.0, 0.16)
const GRID_WIDTH := 2.0
## 区划轮廓的宽度（屏幕像素）
##
## ★ 与 2D 版 `zone_view` 的 `zone_stroke_width_owned = 2.5` 同一档。
##   ⚠️ 别指望 config 里那个值直接能用：那个是**2D 世界像素**口径，
##     而这里是屏幕像素（缩放时不该跟着变粗/变细）。
const ZONE_OUTLINE_WIDTH := 2.5
## 占领进度条：填充的 alpha，以及前沿那条亮线的宽度与 alpha
##
## ★★ 与 2D 版 `zone_view` 的进度条同一套语义（那里是 `zone_progress` 色的矩形 + 顶边亮线）。
##   用户口径：「由下往上升起一个进度条，进度条填满区划时，区划易主」。
const CAPTURE_FILL_ALPHA := 0.45
const CAPTURE_FRONT_WIDTH := 2.0
const CAPTURE_FRONT_ALPHA := 0.95

## ★★ **占领触发区**（区划中心邻域，默认 3×3）的**内向渐变描边**（本轮新增）。
##   · `CAPTURE_AREA_GRAD_TILES` = 渐变长度（**格**）——需求「向内有渐变，长度不超过半格」；
##   · `CAPTURE_AREA_ALPHA` = 最外圈的强度，往里线性降到 0；
##   · 颜色见 `_capture_area_color()`：**中立 = 白灰**、有主 = 该阵营主色。
## ⚠️ 这几个是**屏幕空间画法**的参数（与 GRID_* / ZONE_* 同一条口径）：
##    渐变长度按「格」量，但每个角都逐个投影 ⇒ 透视下它贴着地面、宽度也对。
const CAPTURE_AREA_GRAD_TILES := 0.5
const CAPTURE_AREA_ALPHA := 0.6
const CAPTURE_AREA_NEUTRAL := Color(0.85, 0.85, 0.88)
## 可见性剔除的**宽松量**（屏幕像素）：外框外接框往外放这么多再判「在不在屏内」，
## 免得「刚好压在屏幕边缘」的那一块在滑动时忽隐忽现。
const CAPTURE_AREA_CULL_MARGIN_PX := 16.0

## 网格线顶点缓存（只在地图尺寸变化时重建；相机移动不影响它 —— 顶点是**格坐标**）
var _grid_segs: Array = []
var _grid_cols: int = -1
var _grid_rows: int = -1
## 区划轮廓缓存：`{signature, segs}` —— 只有归属 / 地块划分变了才重算
var _zone_segs: Array = []
var _zone_seg_sig: String = ""

## ★★ **屏幕坐标缓存**（本轮手机端帧率优化）。
##
## 网格 / 区划轮廓 / 占领触发区只依赖「相机 + 视口 + 区划几何与归属」，
## 而相机在绝大多数帧里是**静止**的（玩家没平移、没缩放）。原来 `_draw()` 每帧都把
## 它们重新投影一遍：29×22 的图约 1000+ 次 `Camera3D.unproject_position` + 逐点吸附，
## 手机上是几毫秒到十几毫秒的量级。
## 现在把投影结果存下来，键没变就直接复用（只重新提交 `draw_*`，不再算投影）：
##   · `_static_key_xform` —— 相机变换（平移 / 缩放都会改它）；
##   · `_static_key_proj`  —— 相机投影矩阵（改 fov / near 时才会变）；
##   · `_static_key_vp`    —— 视口尺寸（unproject 依赖它）；
##   · `_static_key_zone_sig` —— 区划几何 / 归属签名（轮廓与触发区颜色靠它）。
## ★ 动态部分（单位血条、占领进度条、建造预览、拖框）**不缓存**，仍然每帧更新。
var _static_ready: bool = false
var _static_key_xform: Transform3D = Transform3D.IDENTITY
var _static_key_proj: Projection = Projection()
var _static_key_vp: Vector2 = Vector2.ZERO
var _static_key_zone_sig: String = ""
## 网格线的屏幕顶点（成对存放：起点、终点）
var _grid_screen: PackedVector2Array = PackedVector2Array()
## 区划轮廓的屏幕顶点：每项 `{segs: PackedVector2Array, color: Color}`
var _zone_screen: Array = []
## 占领触发区的屏幕几何（= `_compute_visible_capture_areas()` 的结果）
var _capture_screen: Array = []
## 缓存重建次数（纯诊断：测试 / 排查用）
var static_rebuild_count: int = 0
var static_last_reason: String = ""
## ★★ 静态层的子节点（见 `_build_static_layer()`）；`self` 只画动态部分。
var _static_layer = null
## 诊断（测试读它）：最近一次 `_draw()` 里网格线 / 区划轮廓 / 占领填充各画了几条
var grid_draw_count: int = 0
var zone_outline_draw_count: int = 0
var capture_draw_count: int = 0
## ★ 最近一次 `_draw()` 里画了几个「占领触发区」描边（= 有中心的区块数；测试读它）
var capture_area_count: int = 0


## 网格线：**整张图**的横竖格线（顶点是格坐标，缓存一次即可）。
##
## ★ 只在**建造模式**下画（`build_type` 非空）：
##   平时地面保持干净，进入建造（Q / W 或右下建筑页）时网格才出现，帮玩家对齐地块。
##   退出建造（再按一次 / Esc / 右键）后网格立刻消失。
##
## ★★ 2026.10.27：绘制本身搬到了静态层子节点（`view/overlay_layer.gd`）——
##    这里只负责「要不要画 / 画几条」并准备顶点（见 `build_static_layer_data()`）。
##
## ★ 计数与绘制**分开**（下一段说明为什么）。


## 网格线这一帧**画几条**（纯计数，不碰绘制 API）。
##
## ★★ 为什么「数」与「画」要拆开（本轮实测踩到）：
##   在 `_draw()` **之外**调 `draw_multiline()` / `draw_colored_polygon()` 会报
##   `ERROR: Drawing is only allowed inside this node's _draw()` ——
##   而测试要在无头下量这些计数（引擎在无头下不渲染 `Control`，所以没有真的 `_draw()` 可等）。
##   拆开之后：测试调 `_count_*()`（**纯计算、零报错**），
##   真渲染时 `_count_*()` 的结果被记进计数器供诊断。
##   ⇒ 好处不只是「没有噪音」：**日志里出现 ERROR 就说明有真问题**，
##     不会被这几条预期的报错淹掉（本项目已经为「红字里的真错误被淹没」付过学费）。
func _count_grid_lines() -> int:
	if world == null or world.map == null:
		return 0
	return int(world.map.cols) + 1 + int(world.map.rows) + 1


## 网格线顶点（格坐标，成对存放：起点、终点）——**只在格子数变化时重建**。
##
## ★ 为什么缓存：顶点是**格坐标**（世界不变），与相机无关 ——
##   每帧重建一遍 94 条线段是白费（27×22 的图 = 28 + 23 条）。
## ★ 为什么整张图都发出去、不自己裁剪：线段只有 50~200 条，
##   而 `draw_multiline` 是**一次** GPU 调用；自己算可见范围反而多一份容易错的逻辑。
##   （100×100 的图是 202 条 —— 仍然可以忽略。）
func _grid_segs_for(cols: int, rows: int) -> Array:
	if _grid_cols == cols and _grid_rows == rows and not _grid_segs.is_empty():
		return _grid_segs
	var segs: Array = []
	# 竖线：x = 0..cols，从 y=0 到 y=rows
	for x in range(0, cols + 1):
		segs.append(Vector2(float(x), 0.0))
		segs.append(Vector2(float(x), float(rows)))
	# 横线：y = 0..rows
	for y in range(0, rows + 1):
		segs.append(Vector2(0.0, float(y)))
		segs.append(Vector2(float(cols), float(y)))
	_grid_segs = segs
	_grid_cols = cols
	_grid_rows = rows
	return _grid_segs


## 把一串「格坐标线段」投影成屏幕顶点（**纯计算**：近平面裁剪 + 像素中心吸附）。
##
## @return 成对存放的屏幕顶点（起点、终点）；整段在相机后方的不出现，
##         跨过相机平面的只留可见的那一段。空数组 = 一条都画不了。
##
## ★★ **必须把端点吸附到像素中心**（这一步不是锦上添花，是清晰度的关键）：
##   格线在世界里落在格边界上，投影之后往往正好落在**屏幕像素的边界**（x.0）上 ⇒
##   1 px 宽的线被抗锯齿**摊到相邻两个像素各一半**，实测对比度只有 7.4%
##   （不吸的话，一条「1 像素实线」看起来是「2 像素的半透明软线」）。
##   吸附到 `.5` 之后线落在像素中心，1 px 就是 1 px —— 与 2D 版 `draw_line`
##   在整数坐标上的观感一致。
##   ⚠️ 吸附的代价是线**偏离真实格边最多半个像素**（肉眼不可辨）；
##      换来的是「像 2D 一样清晰」。用户的口径就是这个，所以这个取舍是明确的。
##
## ★★ **近平面裁剪**（修「近视角下地图顶端拉出很多竖线」的 bug）：
##   相机拉得越近，地图靠近相机的那半张就越会落到**相机平面之后**；
##   而 `unproject_position()` 对相机后方的点**不裁剪**，除以负的 w ⇒ 坐标镜像/炸开
##   （实测：某竖线的近端本该投到屏幕 y=+3695，`zoom=0.1` 时变成 **y=−17191**）。
##   不裁的话，一条格线会从地图顶端的可见端点一路划到天外 ——
##   56 个端点里 28 个在相机后 ⇒ 屏幕上就是「**很多根竖直线从地图上端拉出去**」。
##
## ★ 判据在**相机空间**里做：`z ≤ -near` 才算在近平面之前（Godot 相机朝 −Z 看）。
## ★ 参数 `t` 在**逻辑坐标**里插值就够 —— `logic → world` 是线性缩放，
##   所以交点不必再回世界空间转一次，投影仍只经 `palette.to_px` 一处。
## ★ 结果由 `_refresh_static_projection()` 缓存，`_draw` 里只重新提交 `draw_multiline`。
## ★ 与 `_count_*()` 同一个理由拆成纯函数：测试能在无头下量它，
##   而不触发 `Drawing is only allowed inside this node's _draw()`。
func _project_segments(segs: Array) -> PackedVector2Array:
	var pts := PackedVector2Array()
	if palette == null or segs.size() < 2:
		return pts
	var cam: Camera3D = palette.cam
	if cam == null:
		return pts
	var inv: Transform3D = cam.global_transform.affine_inverse()
	var zn: float = -cam.near
	var i := 0
	var last: int = segs.size() - 1
	while i < last:
		var la: Vector2 = segs[i]
		var lb: Vector2 = segs[i + 1]
		i += 2
		var za: float = (inv * palette.to_world(la)).z
		var zb: float = (inv * palette.to_world(lb)).z
		var a_front: bool = za <= zn
		var b_front: bool = zb <= zn
		if a_front and b_front:
			pts.append(_proj_snap(la))
			pts.append(_proj_snap(lb))
		elif a_front or b_front:
			# 一端在近平面之后：求交点，只投可见的那一段
			var t: float = (zn - za) / (zb - za)
			var lc: Vector2 = la.lerp(lb, t)
			if a_front:
				pts.append(_proj_snap(la))
				pts.append(_proj_snap(lc))
			else:
				pts.append(_proj_snap(lc))
				pts.append(_proj_snap(lb))
	return pts


## 把一个**格坐标**投到屏幕像素并吸附到像素中心。
## ★ 吸附到 `.5` 不是锦上添花：见 `_project_segments` 上面那段说明。
func _proj_snap(logic_pos: Vector2) -> Vector2:
	var sp: Vector2 = palette.to_px(logic_pos)
	return Vector2(roundf(sp.x - 0.5) + 0.5, roundf(sp.y - 0.5) + 0.5)


## 网格线（整张图）
## 区划轮廓：沿着**地块的边界**画（非矩形区划的轮廓才是它的真实形状）。
##
## ★★ 按**区划 id** 分组、每组一次 `draw_multiline`：
##   一条边两侧的颜色可能不同（两侧属于不同区划），所以不能全图合并成一条。
##   分组之后每块地一次 draw 调用（24 块 ⇒ 24 次），与 2D 版同一取舍。
## ★★ 缓存：边界是**格坐标**的几何，只在归属 / 地块划分变化时才会变
##   —— 相机每帧移动不该让它重算（`palette.to_px` 才是每帧要做的投影）。
## ★★ 2026.10.27：绘制搬到静态层（见 `build_static_layer_data()`），这里不再有 `draw_*`。


## 区划轮廓这一帧**画几组**（纯计数，不碰绘制 API）——同时保证几何缓存是新的。
##
## ★ 与 `_count_grid_lines()` 同一个理由：把「数」与「画」拆开，
##   测试才能在无头下量到计数而不触发 `Drawing is only allowed inside _draw()`。
func _count_zone_outlines() -> int:
	if world == null or world.zones == null:
		return 0
	var sig := _zone_edge_signature()
	if sig != _zone_seg_sig:
		_zone_seg_sig = sig
		_zone_segs = _build_zone_segments()
	var n := 0
	for entry in _zone_segs:
		if not (entry["segs"] as Array).is_empty():
			n += 1
	return n


## 边界几何的签名：地块划分（每块的 id + 地块数 + 归属）变了就要重算几何
func _zone_edge_signature() -> String:
	if world == null or world.zones == null:
		return ""
	var parts: Array = []
	for z in world.zones.zones:
		parts.append("%d:%d:%s" % [
			int((z as Dictionary).get("id", -1)),
			int((z as Dictionary).get("tile_count", 0)),
			String((z as Dictionary).get("owner", ""))])
	return "|".join(parts)


## 算出每个区划的边界线段（格坐标，成对存放：起点、终点）。
##
## ★ 每条边**只由拥有它的那一格**产生（不重复发两次）：同一条边两侧的格子各查一次
##   邻接，只有「我在区划 A、邻居不在 A」时我才画 ⇒ 每条边恰好被一侧画一次，
##   不会叠成双倍粗细。
## ★ 四条边取哪两个角：格 (tx,ty) 的四角是
##   `(tx,ty)` `(tx+1,ty)` `(tx+1,ty+1)` `(tx,ty+1)` ⇒
##     上边 = 角0→角1、右边 = 角1→角2、下边 = 角2→角3、左边 = 角3→角0。
##   ⚠️ 这里**不**用「按掩码取内缩像素」那套（那是给贴图用的）：屏幕空间直接画格边。
func _build_zone_segments() -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for z in world.zones.zones:
		var zid := int((z as Dictionary).get("id", -1))
		var cells: Array = (z as Dictionary).get("tiles", [])
		if cells.is_empty():
			continue
		var segs: Array = []
		for t in cells:
			var tile: Vector2i = t
			# 去重：同一格只处理一次（不同区划的地块列表理论上不重叠，但这是免费的保险）
			var key: int = tile.y * 100000 + tile.x
			if seen.has(key):
				continue
			seen[key] = true
			var mask: int = ground.zone_edge_mask(tile.x, tile.y)
			if mask == 0:
				continue
			var x0 := float(tile.x)
			var y0 := float(tile.y)
			var x1 := x0 + 1.0
			var y1 := y0 + 1.0
			if (mask & 1) != 0:      # 上
				segs.append(Vector2(x0, y0))
				segs.append(Vector2(x1, y0))
			if (mask & 2) != 0:      # 右
				segs.append(Vector2(x1, y0))
				segs.append(Vector2(x1, y1))
			if (mask & 4) != 0:      # 下
				segs.append(Vector2(x1, y1))
				segs.append(Vector2(x0, y1))
			if (mask & 8) != 0:      # 左
				segs.append(Vector2(x0, y1))
				segs.append(Vector2(x0, y0))
		if segs.is_empty():
			continue
		out.append({"id": zid, "segs": segs, "color": ground.zone_outline_color(z)})
	return out


# ------------------------------------------------------------------
# ★★ 粮车光环范围（只在**被选中**时显示）
# ------------------------------------------------------------------
##
## 需求：为粮车的生效范围加底部范围显示；只有粮车被选中时才显示；
##      范围紧贴地面、用细线标识。
##
## 做法：
##   · 范围 = `unit.morale_aura_radius`（逻辑层同一个字段，见 config.unit.types.grain_cart）；
##   · 沿圆周采样 `AURA_RANGE_SEGMENTS` 个点，**逐点**走 `palette.to_px()` 投到 y=0 地面
##     —— 所以透视下它是一圈贴地的椭圆，而不是飘在单位周围的屏幕圆；
##   · 只画 `_selection` 里的单位：没选中 / 选中别的兵都不画；
##   · 细线：1.25 屏幕像素（与区划轮廓 2.5 / 网格 2.0 同一套屏幕空间线宽）。
##
## ★ 为什么把「算几何」和「画」拆开（`_aura_range_loops()` / `_draw_aura_ranges()`）：
##   与网格 / 区划轮廓 / 占领触发区同一个理由 —— 测试在无头下不能调 `draw_*`，
##   但可以调纯函数量点数、验投影。
func _aura_range_loops() -> Array:
	var out: Array = []
	if cfg == null or world == null or palette == null or _selection.is_empty():
		return out
	for u in world.units:
		if u == null or not u.alive:
			continue
		if not _selection.has(String(u.id)):
			continue
		var radius: float = float(u.morale_aura_radius)
		if radius <= 0.0:
			continue
		var pts := PackedVector2Array()
		for i in AURA_RANGE_SEGMENTS + 1:     # +1：闭合（最后一点回到起点）
			var ang: float = TAU * float(i) / float(AURA_RANGE_SEGMENTS)
			var world_pos: Vector2 = u.pos + Vector2(cos(ang), sin(ang)) * radius
			pts.append(palette.to_px(world_pos))
		var c: Color = SideColorRes.color(cfg, world, String(u.faction), "main")
		c.a = AURA_RANGE_ALPHA
		out.append({
			"unit_id": String(u.id),
			"radius": radius,
			"points": pts,
			"color": c,
		})
	return out


func _draw_aura_ranges() -> void:
	aura_range_draw_count = 0
	for entry in _aura_range_loops():
		draw_polyline(entry["points"], entry["color"], AURA_RANGE_WIDTH, true)
		aura_range_draw_count += 1
		draw_count += 1


# ------------------------------------------------------------------
# ★★ 占领触发区（区划中心邻域）的**内向渐变描边**（本轮新增）
# ------------------------------------------------------------------
##
## 需求原话：「为区划中心的占领触发区域添加提示，在这个 3x3 范围内的格子设置一个整体描边，
##   该描边需要向内有渐变色效果，渐变长度不超过一个格子长度的一半，
##   该描边需要根据其所属势力颜色发生改变，中立时显白灰色，被占领后显示其所属势力的颜色」。
##
## 做法：把邻域外框与「内缩 `CAPTURE_AREA_GRAD_TILES` 格」的内框之间那一圈画成
##   **4 个梯形**（画框那样拼，角上不重不漏），每个梯形给**逐顶点颜色**：
##   外圈 = 势力色、内圈 = 全透明 ⇒ 引擎插值出来就是「向内渐隐」。
## ★ 四角逐个投影（`palette.to_px`）⇒ 透视正确，与区划轮廓 / 进度条同一条链路。
## ★ 颜色判据是**区块归属**（`owner`），不是「谁正在读条」：中立白灰、有主用主人色。
## ★★ **可见性剔除**（本轮补）：只画**屏幕内**的触发区（见 `_visible_capture_areas()`）——
##    屏幕外的一律不投影、不绘制，于是开销随「屏幕里有几块」走，而不是随全图区块数走。
## ★★ 2026.10.27：绘制搬到静态层（见 `build_static_layer_data()`）——
##    这里只剩「算出 4 个梯形、验过能画、算好逐顶点颜色」，把结果交给子节点。
func _push_grad_quad(quads: Array, pts: PackedVector2Array,
		outer: Color, inner: Color) -> void:
	if pts.size() != 4:
		return
	# ★ 退化 / 自交的四边形直接跳过：`draw_polygon` 内部三角化会报
	#   "Invalid polygon data, triangulation failed"（实测在区划触发区跨相机近平面时出现）。
	#
	# ★★ 判据用**面积 + 凸性**，不用 `Geometry2D.triangulate_polygon()`：
	#    这一句每帧、每个可见区划、每个梯形各跑一次 —— 27×22 的图上
	#    `ov/capture_area` 就吃掉 0.675 ms/帧。能画 ⟺ 面积不为 0 且不自交，
	#    而四边形的「不自交 + 凸」只需 4 次叉积（`_is_convex_screen_poly`），
	#    比走一遍原生耳切便宜一个数量级；`draw_polygon()` 对**已验过的凸四边形**
	#    三角化是常数时间，且不会再失败。
	if absf(_screen_polygon_area(pts)) <= 0.01:
		return
	if not _is_convex_screen_poly(pts):
		return
	quads.append({"pts": pts, "colors": PackedColorArray([outer, outer, inner, inner])})


## ★★ 这一帧**真正要画**的占领触发区（**纯计算**，不做绘制调用）——剔除两件事：
##   ① 外框四角**有任一在相机近平面之后** ⇒ 整块不画
##      （半块在相机后方的四边形投影会炸开、拉出乱线 —— 与网格线那条同一个坑，
##       见 `_project_segments` 的说明）；
##   ② 外框的屏幕外接框**与视口不相交** ⇒ 整块不画（这就是可见性剔除：
##      屏幕外的区块不再投 8 个点、也不再发 4 次 `draw_polygon`）。
##
## ★ 与 `_count_grid_lines()` / `_count_zone_captures()` 同一个理由拆成纯函数：
##   在 `_draw()` 之外调 `draw_*` 会报 `Drawing is only allowed inside this node's _draw()`，
##   拆开之后测试也能直接量「这一帧画了几块」。
##
## @return Array，每项 `{outer, inner, outer_c, inner_c}`；`outer` / `inner` 都是
##         **屏幕像素**的四点数组（顺序：左上 → 右上 → 右下 → 左下）。
func _visible_capture_areas() -> Array:
	# ★★ 这一层同样**只依赖相机 + 区划归属**（不依赖单位位置 / 占领进度），
	#    所以跟着静态层一起缓存：相机不动时不投影、不重建。
	#    `_draw()` 里已经先调过 `_refresh_static_projection()`，这里是给
	#    测试（以及别的直接调用点）兜底 —— 键变了就当场重建。
	if _static_key_changed():
		_refresh_static_projection()
	return _capture_screen


## `_visible_capture_areas()` 的**纯计算**实现（每次调用都真算，不读缓存）。
## @return 见 `_visible_capture_areas()` 的契约。
func _compute_visible_capture_areas() -> Array:
	var out: Array = []
	if cfg == null or world == null or world.zones == null or palette == null:
		return out
	var cam: Camera3D = palette.cam
	if cam == null:
		return out
	var inv: Transform3D = cam.global_transform.affine_inverse()
	var zn: float = -cam.near
	var vp: Rect2 = Rect2(Vector2.ZERO, get_viewport_rect().size) \
		.grow(CAPTURE_AREA_CULL_MARGIN_PX)
	var r: int = maxi(0, int(cfg.zone_capture_radius_tiles))
	var g: float = CAPTURE_AREA_GRAD_TILES
	for z in world.zones.zones:
		var c: Variant = (z as Dictionary).get("center", null)
		if c == null:
			continue
		var center: Vector2i = c
		var x0 := float(center.x - r)
		var y0 := float(center.y - r)
		var x1 := float(center.x + r + 1)
		var y1 := float(center.y + r + 1)
		var outer: PackedVector2Array = _project_culled(inv, zn, vp, [
			Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(x0, y1)])
		if outer.is_empty():
			continue
		var inner := PackedVector2Array()
		for p in [Vector2(x0 + g, y0 + g), Vector2(x1 - g, y0 + g),
				Vector2(x1 - g, y1 - g), Vector2(x0 + g, y1 - g)]:
			inner.append(palette.to_px(p))
		var base: Color = _capture_area_color(String((z as Dictionary).get("owner", "")))
		out.append({
			"outer": outer, "inner": inner,
			"outer_c": Color(base.r, base.g, base.b, CAPTURE_AREA_ALPHA),
			"inner_c": Color(base.r, base.g, base.b, 0.0),
		})
	return out


## 把 4 个**格角**投到屏幕，并做「可见性剔除」（判据见 `_visible_capture_areas()`）。
## @return 屏幕四点（顺序同入参）；被剔除时返回**空数组**。
func _project_culled(inv: Transform3D, zn: float, vp: Rect2, logic: Array) -> PackedVector2Array:
	# ① 近平面：任一角在相机后方 → 投影会镜像 / 炸开，整块不画
	for p in logic:
		if (inv * palette.to_world(p)).z > zn:
			return PackedVector2Array()
	# ② 屏幕外接框与视口不相交 → 整块在屏幕外
	var sps := PackedVector2Array()
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for p2 in logic:
		var sp: Vector2 = palette.to_px(p2)
		sps.append(sp)
		mn = mn.min(sp)
		mx = mx.max(sp)
	if not Rect2(mn, mx - mn).intersects(vp):
		return PackedVector2Array()
	return sps


## 占领触发区描边的颜色：**中立 = 白灰**、有主 = 该阵营主色（需求原话见上）。
func _capture_area_color(owner: String) -> Color:
	if owner == "":
		return CAPTURE_AREA_NEUTRAL
	return SideColorRes.color(cfg, world, owner, "main")


## 占领进度条：**由下往上升起**的一块填充 + 前沿一条亮线（全部屏幕空间矢量）。
##
## ★★ 口径（用户原话）：「当开始占领时，区划由下往上升起一个进度条，
##   进度条填满区划时，区划易主」。
##   ⇒ 填充的顶边（水面）随进度**上升**，读满时 `zone.update()` 改 owner、这一层变空。
##
## ★★ 进度只有一处权威：`world.zones.capture_bar(z)`（读条 / 冻结 / 回落三条规则都在逻辑层）。
##   视图**不许**自己去比各方的进度 —— 2D 版为此记过一条坑。
##
## ★★ 几何怎么算（这是这个函数唯一需要理解的东西）：
##   · 高度基准 = **这个区划自己**的地块外接框 `y0..y1`（整个区划共用，
##     所以前沿是一条**水平的连续线**，不是每格各自升到顶的锯齿）；
##   · 水面 `water = (y1+1) - (y1-y0+1) * v`  ⇒ v 越大 water 越小 ⇒ **往上长**；
##   · 逐格：整格在水面之下 ⇒ 整格填；水面穿过这一格 ⇒ 只填**水面以下那一块**
##     （所以一格之内是**连续**的填充，不是一个整格的跳变）；
##   · 每格画成一个四边形（`draw_colored_polygon`），格角逐个投影 ⇒ 透视正确、
##     边缘逐像素清晰（这正是「像 2D 一样清晰」的来源）。
##   ⚠️ 方向写反过一次（`y0 + span*v` = 从上往下淌），症状是「越占越像退潮」。
##     判据：`water` 必须随 `v` **单调下降**。
func _draw_zone_capture() -> void:
	var items: Array = _capture_items()
	capture_draw_count = 0
	for it in items:
		var fill: Color = it["fill"]
		# ★★ 2026.10.27（性能）：三角在这里**已经拆好**（`_capture_items` 里做一次），
		#    这里只负责发绘制调用 —— 原来 `_capture_items` 验一遍、这里再拆一遍，
		#    同一格每帧要走两次三角化（桌面实测 `ov/capture_bar` 0.245 ms/帧）。
		for tris in (it["tris"] as Array):
			for tri in (tris as Array):
				draw_colored_polygon(tri, fill)
			capture_draw_count += 1
		var front_pts: PackedVector2Array = it["front"]
		if front_pts.size() >= 2:
			draw_multiline(front_pts, (it["front_color"] as Color), CAPTURE_FRONT_WIDTH)


## 占领进度条这一帧**画几块**（纯计数，不碰绘制 API）。
##
## ★ 与 `_count_grid_lines()` / `_count_zone_outlines()` 同一个理由（见那里的说明）。
func _count_zone_captures() -> int:
	var n := 0
	for it in _capture_items():
		n += (it["tris"] as Array).size()
	return n


## 算出「这一帧要画的占领进度条几何」（**纯计算**，不做任何绘制调用）。
##
## ★★ 几何怎么算（这是这个函数唯一需要理解的东西）：
##   · 高度基准 = **这个区划自己**的地块外接框 `y0..y1`（整个区划共用，
##     所以前沿是一条**水平的连续线**，不是每格各自升到顶的锯齿）；
##   · 水面 `water = (y1+1) - (y1-y0+1) * v`  ⇒ v 越大 water 越小 ⇒ **往上长**；
##   · 逐格：整格在水面之下 ⇒ 整格填；水面穿过这一格 ⇒ 只填**水面以下那一块**
##     （所以一格之内是**连续**的填充，不是一个整格的跳变）；
##   · 每格一个四边形，格角逐个投影 ⇒ 透视正确、边缘逐像素清晰。
##
## ★★ 判据是 `capture_state`，**不是** `value`：已经归属某方的区划 `progress` 是 **1.0**
##   （`refresh_building_ownership` / 开局归属都这么填），只按「value > 0」判会给自己
##   的地也画一条满进度条（实测：开局那一帧 a1 + c2 共 74 块）。`capture_bar()` 的契约
##   写明 `state == ""` = 不用画（只有 reading / frozen / decaying 三种才画）。
##
## ★★ 填充四边形同样要**近平面裁剪**（见 `_project_segments` 那段说明）：相机后方的
##   角会投影炸开、拉出乱线。裁剪在**格坐标**里做（见 `_clip_poly_near`）。
##
## @return `[{quads: Array[PackedVector2Array], front: PackedVector2Array,
##           fill: Color, front_color: Color}, ...]`（每个正在读条的区划一项）
func _capture_items() -> Array:
	var out: Array = []
	if world == null or world.zones == null or palette == null or cfg == null:
		return out
	var cam: Camera3D = palette.cam
	if cam == null:
		return out
	var inv: Transform3D = cam.global_transform.affine_inverse()
	var zn: float = -cam.near
	for z in world.zones.zones:
		var bar: Dictionary = world.zones.capture_bar(z)
		var v := clampf(float(bar.get("value", 0.0)), 0.0, 1.0)
		if String(bar.get("state", "")) == "" or v <= 0.001:
			continue
		var cells: Array = (z as Dictionary).get("tiles", [])
		if cells.is_empty():
			continue
		# ① 高度基准（整个区划共用）—— ★ 从缓存读，不再每帧重扫 tiles
		var yb: Vector2i = _zone_y_range(z as Dictionary, cells)
		var y0: int = yb.x
		var y1: int = yb.y
		if y1 < y0:
			continue
		var span: float = float(y1 - y0 + 1)
		var water: float = float(y1 + 1) - span * v
		# ② 颜色：填充 = 本机视角的己 / 友 / 敌色半透明；前沿 = 同色提亮一档
		var bar_faction := String(bar.get("faction", ""))
		var fc: Color = cfg.color("zone_player")
		if bar_faction != "":
			fc = SideColorRes.color(cfg, world, bar_faction, "main")
		var fill := Color(fc.r, fc.g, fc.b, CAPTURE_FILL_ALPHA)
		var front := Color(
			lerpf(fc.r, 1.0, 0.35), lerpf(fc.g, 1.0, 0.35), lerpf(fc.b, 1.0, 0.35),
			CAPTURE_FRONT_ALPHA)
		# ③ 逐格：整格在水面下就整格填；水面穿过就只填水面以下那一块
		var tris_groups: Array = []
		var front_logic: Array = []
		for t2 in cells:
			var tile2: Vector2i = t2
			var top: float = float(tile2.y)
			var bottom: float = float(tile2.y) + 1.0
			if bottom <= water:
				continue                       # 整格还在水面之上：什么都不填
			var cut: float = maxf(top, water)   # 这一格被水面切到哪
			var x0 := float(tile2.x)
			var x1 := x0 + 1.0
			# ★ 先在**格坐标**里对近平面裁一刀（相机后方的角投影会炸开），再逐个投影。
			var poly: PackedVector2Array = _clip_poly_near(
				[Vector2(x0, cut), Vector2(x1, cut), Vector2(x1, bottom), Vector2(x0, bottom)],
				inv, zn)
			if poly.size() >= 3:
				var screen := PackedVector2Array()
				for lp in poly:
					screen.append(palette.to_px(lp))
				# ★★ 近平面裁剪会在边界上产生**重合点**；投影后也可能整块退化成一条线。
				#    `draw_colored_polygon()` 的三角化对这两种情况都会失败（实测报
				#    "Invalid polygon data, triangulation failed"），所以这里先清掉重合点、
				#    再按面积把退化四边形丢掉。
				screen = _clean_screen_polygon(screen)
				if screen.size() >= 3 and absf(_screen_polygon_area(screen)) > 0.01:
					# ★★ 2026.10.27（性能）：三角化**只做这一次**，结果直接带出去给
					#    `_draw_zone_capture` 用 —— 原来这里验一遍、绘制时再拆一遍。
					var tris := _screen_triangles(screen)
					if not tris.is_empty():
						tris_groups.append(tris)
			# ④ 水面正好穿过这一格 ⇒ 它的顶边是「前沿」的一段（同样要裁，交给 _project_segments）
			if top < water and water < bottom:
				front_logic.append(Vector2(x0, water))
				front_logic.append(Vector2(x1, water))
		out.append({"tris": tris_groups, "front": _project_segments(front_logic),
			"fill": fill, "front_color": front})
	return out


## 区划地块的 `y` 范围（`Vector2i(y0, y1)`；空区划返回 `y1 < y0` 的哨兵）。
##
## ★★ 为什么缓存：地块在一局之内**不会变**，而 `_capture_items()` 每帧都会对每个
##    正在读条的区划重扫一遍 tiles 求 min/max —— 27×22 的图上这是每帧几百次
##    `mini/maxi`，纯浪费。缓存键 = `world.zones` 的实例 id + 区划 id：
##    换关卡 / 换世界时 `zones` 是**另一个对象**，整表自然作废（不需要额外失效点）。
var _zone_y_cache: Dictionary = {}
var _zone_y_cache_owner: int = 0


func _zone_y_range(z: Dictionary, cells: Array) -> Vector2i:
	var zs = world.zones if world != null else null
	var owner_id: int = int(zs.get_instance_id()) if zs != null else 0
	if owner_id != _zone_y_cache_owner:
		_zone_y_cache.clear()
		_zone_y_cache_owner = owner_id
	var zid: int = int(z.get("id", -1))
	var hit: Variant = _zone_y_cache.get(zid, null)
	if hit != null:
		return hit
	var y0 := 1 << 20
	var y1 := -(1 << 20)
	for t in cells:
		var tile: Vector2i = t
		y0 = mini(y0, tile.y)
		y1 = maxi(y1, tile.y)
	var r := Vector2i(y0, y1)
	_zone_y_cache[zid] = r
	return r


## 把一个**凸多边形**（格坐标）对相机近平面裁一刀（Sutherland–Hodgman，单平面）。
##
## ★ 与 `_project_segments` 同一个理由：相机后方的点投影会镜像/炸开，
##   占领进度条的填充四边形同样会因此拉出乱线。
## ★ `inv` / `zn` 由调用方每帧算一次（避免每条边都求一次逆矩阵）。
##
## @return 裁剪后的多边形（格坐标）；整块都在近平面之后 → 空数组。
func _clip_poly_near(poly: Array, inv: Transform3D, zn: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n: int = poly.size()
	if n < 3:
		return out
	for i in n:
		var a: Vector2 = poly[i]
		var b: Vector2 = poly[(i + 1) % n]
		var za: float = (inv * palette.to_world(a)).z
		var zb: float = (inv * palette.to_world(b)).z
		var a_in: bool = za <= zn
		var b_in: bool = zb <= zn
		if a_in:
			out.append(a)
		if a_in != b_in:
			out.append(a.lerp(b, (zn - za) / (zb - za)))
	return out


## 去掉屏幕上相邻的重合点（近平面裁剪经常在一个角上留下 `a == b`）。
## 三角化要求多边形至少 3 个**不同**的点，否则 `draw_colored_polygon()` 会报
## "Invalid polygon data, triangulation failed"。
func _clean_screen_polygon(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts:
		if out.is_empty() or out[out.size() - 1].distance_squared_to(p) > 1e-8:
			out.append(p)
	while out.size() >= 2 and out[0].distance_squared_to(out[out.size() - 1]) <= 1e-8:
		out.remove_at(out.size() - 1)
	return out


## 屏幕多边形的有向面积（鞋带公式）。返回 0 表示共线/退化，不能交给三角化。
func _screen_polygon_area(pts: PackedVector2Array) -> float:
	var n: int = pts.size()
	if n < 3:
		return 0.0
	var area2 := 0.0
	for i in n:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % n]
		area2 += a.x * b.y - b.x * a.y
	return area2 * 0.5


## 把一个屏幕多边形拆成三角形（三角化失败 → 空数组，调用方直接跳过）。
## 三角形逐个交给 `draw_colored_polygon()`，避免它再对凹/退化多边形做一次三角化。
##
## ★★ 2026.10.27（性能）：**凸多边形走扇形快路径**，不再调 `Geometry2D.triangulate_polygon()`
##    —— 那时候每帧每条占领进度带的每一格都要走一遍原生耳切，桌面实测 `ov/capture_bar`
##    0.245 ms/帧。近平面裁出来的多边形（凸四边形 / 五边形）占绝大多数，扇形三角化对它们
##    是**同一组**三角形（凸多边形从任一顶点扇形划分必然合法），只是不再过一遍耳切。
##    凹 / 自交 / 退化的少数情况仍走原路径，语义一字未改。
func _screen_triangles(pts: PackedVector2Array) -> Array:
	var out: Array = []
	if pts.size() < 3:
		return out
	# ── 快路径：凸 ⇒ 扇形三角化 ──
	if _is_convex_screen_poly(pts):
		var n: int = pts.size()
		var a0: Vector2 = pts[0]
		for k in range(1, n - 1):
			var b0: Vector2 = pts[k]
			var c0: Vector2 = pts[k + 1]
			var ar := _screen_polygon_area(PackedVector2Array([a0, b0, c0]))
			if absf(ar) <= 0.001:
				continue
			# 与 `_draw_build_preview()` 的四边形同一绕向（屏幕 y 向下，面积为正）。
			if ar < 0.0:
				var t2 := b0
				b0 = c0
				c0 = t2
			out.append(PackedVector2Array([a0, b0, c0]))
		return out
	# ── 慢路径（凹 / 自交 / 退化）：原实现，逐字保留 ──
	var poly := pts
	var idx: PackedInt32Array = Geometry2D.triangulate_polygon(poly)
	if idx.is_empty():
		# 不同版本的三角化对绕向要求不一致：正向失败就反向再试一次。
		var rev := PackedVector2Array()
		for i in range(pts.size() - 1, -1, -1):
			rev.append(pts[i])
		idx = Geometry2D.triangulate_polygon(rev)
		if not idx.is_empty():
			poly = rev
	var i := 0
	while i + 2 < idx.size():
		var a: Vector2 = poly[idx[i]]
		var b: Vector2 = poly[idx[i + 1]]
		var c: Vector2 = poly[idx[i + 2]]
		var area := _screen_polygon_area(PackedVector2Array([a, b, c]))
		if absf(area) > 0.001:
			# 与 `_draw_build_preview()` 的四边形同一绕向（屏幕 y 向下，面积为正）。
			if area < 0.0:
				var tmp := b
				b = c
				c = tmp
			out.append(PackedVector2Array([a, b, c]))
		i += 3
	return out


## 屏幕多边形是不是**凸**的（且绕向一致、面积非零）。
##
## ★ 判据：每个顶点处相邻两边的叉积同号（允许 0 = 共线）。屏幕 y 向下，所以正向凸多边形
##   的叉积全为负或全为正都算（调用方自己按面积定绕向）。
## ★ 只用于**屏幕空间**的小多边形（4~6 点），O(n) 且没有任何分配。
func _is_convex_screen_poly(pts: PackedVector2Array) -> bool:
	var n: int = pts.size()
	if n < 3:
		return false
	if n == 3:
		return absf(_screen_polygon_area(pts)) > 0.001
	var sign_seen := 0
	for i in n:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % n]
		var c: Vector2 = pts[(i + 2) % n]
		var cross: float = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
		if absf(cross) <= 1e-6:
			continue                       # 共线：不影响凸性
		var s: int = 1 if cross > 0.0 else -1
		if sign_seen == 0:
			sign_seen = s
		elif s != sign_seen:
			return false                   # 反向拐弯 ⇒ 凹或自交
	if sign_seen == 0:
		return false                       # 全共线：退化
	return absf(_screen_polygon_area(pts)) > 0.001


## 合作 AI 队友的目标环（行军 / 屯兵）。
##
## ★ 只画「与玩家同方的 commander」且当前指令有目标点的那些；develop / expand 没有点。
## ★ 这只是显示：命令本身走 `command_processor`，覆盖层不读输入、不改世界。
func _draw_ai_marks() -> void:
	if world == null or palette == null or not world.has_method("ai_teammates_for"):
		return
	var mates: Array = world.ai_teammates_for(world.my_faction)
	if mates.is_empty():
		return
	var seg := 40
	for f in mates:
		var pt: Variant = world.ai_directive_target(String(f))
		if pt == null:
			continue
		var center: Vector2 = pt
		var col: Color = SideColorRes.color(cfg, world, String(f), "main")
		col.a = 0.9
		var pts := PackedVector2Array()
		for i in seg + 1:
			var a := TAU * float(i) / float(seg)
			pts.append(palette.to_px(center + Vector2(cos(a), sin(a)) * 1.3))
		draw_polyline(pts, col, 2.0, true)
		var c2: Vector2 = palette.to_px(center)
		var d: float = 7.0
		draw_line(c2 - Vector2(d, 0.0), c2 + Vector2(d, 0.0), col, 1.5, true)
		draw_line(c2 - Vector2(0.0, d), c2 + Vector2(0.0, d), col, 1.5, true)


## 单位头上的东西（血条）——屏幕空间的条
##
## ★★ 两处优化（每帧都跑，单位越多越贵）：
##   ① **屏幕外剔除**：投影不落在视口附近（留 64px）的单位直接跳过 —— 血条都画在屏幕外了，
##      白算一次投影 + 两次血条投影；
##   ② 宽/高**一次算完**（`units.quad_screen_size`）：原来 width + height 各调一次，
##      height 会把 width 的那 2 次 `to_px` 再投一遍（每单位多 2 次）。
func _draw_units_ui() -> void:
	if units == null:
		return
	var vp_size: Vector2 = get_viewport_rect().size
	if vp_size.x <= 0.0 or vp_size.y <= 0.0:
		vp_size = size
	var keep: Rect2 = Rect2(Vector2.ZERO, vp_size).grow(64.0)
	# ★★ 2026.10.27：单位层这一帧已经算过迷雾可见性（`units.sync`），直接复用。
	#    旧实现对 256 个单位各查一次 `fog.unit_visible`（桌面上 ov/units_ui 1.7ms 的主因）；
	#    只在「单位层也跑过同一帧」时启用，测试 / 无头直接调 `_draw` 时退回原判据。
	var use_vis_cache: bool = units != null and world != null \
		and int(units.visibility_frame) == int(world.frame_serial)
	unit_ui_seen = 0
	unit_ui_visible = 0
	unit_ui_bars = 0
	for u in world.units:
		unit_ui_seen += 1
		if not u.alive:
			continue
		if use_vis_cache:
			if not units.is_visible_this_frame(u):
				continue
		elif not _unit_visible(u):
			continue
		unit_ui_visible += 1
		# ★★ 2026.10.27（插值）：血条必须与立牌用同一个位置（客机上 `u.pos` 是
		#    「上一条快照的位置」，立牌画的是插值后的位置 —— 直接用 u.pos 会错开半格）。
		var p: Vector2 = palette.to_px(units.render_pos_of(u))
		if not keep.has_point(p):
			continue
		# ★★ 2026.10.27：满血单位不画血条 ⇒ **不要**再算一次立牌尺寸（两次投影）。
		#    旧顺序是「先 quad_screen_size 再判满血」，256 个单位里绝大多数满血，
		#    等于每帧白投 500+ 次（桌面实测 ov/units_ui 1.7ms 的主因）。
		if u.hp >= u.hp_max - 1e-6:
			continue
		var us: Vector2 = units.quad_screen_size(u)
		var r: float = us.x * 0.5
		if r <= 0.0:
			continue
		# ★ 选中下标不再在这里画圈 —— 改成单位层脚下的「绿色空心圆」贴花
		#   （view/unit_view_3d.gd 的 `_sync_selection_rings`：150%→100% 缩放 + 淡入动效）。
		# 血条：不满血才画（满血不画，避免刷屏）
		var w: float = maxf(r * 2.2, 10.0)
		var top: Vector2 = p - Vector2(0.0, us.y * 0.5 + 4.0)
		draw_rect(Rect2(Vector2(top.x - w * 0.5, top.y), Vector2(w, 3.0)), HP_BACK_COLOR, true)
		draw_rect(Rect2(Vector2(top.x - w * 0.5, top.y), Vector2(w * u.hp_ratio(), 3.0)),
			SideColorRes.color(cfg, world, String(u.faction), "bar"), true)
		draw_count += 1
		unit_ui_bars += 1


## ★★ 头顶编队标识：**常驻键帽 + 选中名牌**（本轮扩展）。
##
## 键帽文字：
##   · 己方（本机操作）→ 固定槽位编号（1..9、第 10 支写 0）；
##   · 合作队友 → 「友」；敌人 → 「敌」；观战 → 以被观战方为「友」，另一方「敌」。
## 名牌：
##   · 只有**己方**选中的将领出名牌（敌 / 友按需求只出键帽，不泄露编制 / 士气）；
##   · 多个名牌互相压住时**不再退回键帽**，而是围绕各自的头顶找空位（上下为主，
##     必要时左右让），保证展开的标签栏彼此不重叠；被让开的标签画一条细引线。
##
## ★ 编号口径：己方用 `view/team_slots.gd` 的**稳定槽位**（阵亡 / 复活不改号），
##   与右栏 / 数字键同源。观察者模式不分配槽位，所有将只写敌 / 友。
## ★ 只画**当前可见**的将（迷雾判据仍在 `_unit_visible`）；阵亡将已移出 world.units，
##   地图上不画灰标（灰行由右栏 `squad_panel` 表达）。
func _draw_team_markers() -> void:
	badge_draw_count = 0
	nameplate_draw_count = 0
	if font == null or world == null or palette == null or units == null:
		return
	if palette.cam == null:
		return
	var vp_size: Vector2 = get_viewport_rect().size
	if vp_size.x <= 0.0 or vp_size.y <= 0.0:
		vp_size = size
	if vp_size.x <= 0.0 or vp_size.y <= 0.0:
		return
	var keep: Rect2 = Rect2(Vector2.ZERO, vp_size).grow(64.0)
	var observer: bool = bool(world.observer_mode)
	if team_slots != null:
		team_slots.sync(world)

	# ① 收集**所有可见的将**（不分阵营）；敌 / 友只出键帽，己方才可能出名牌。
	var entries: Array = []
	var fallback_n := 0
	for u in world.units:
		if not u.alive:
			continue
		if not u.is_general():
			continue
		if bool(u.neutralized):
			continue
		# ★ 观战：用户要「所有将」都标，因此不过滤迷雾；正常局仍只标可见单位。
		if not observer and not _unit_visible(u):
			continue
		var rel := SideColorRes.relation(world, String(u.faction))
		if rel == SideColorRes.NEUTRAL:
			continue
		var is_self: bool = (rel == SideColorRes.SELF) and not observer
		var label := ""
		var slot := 0
		if is_self:
			fallback_n += 1
			if team_slots != null:
				slot = int(team_slots.slot_of(u))
				if slot <= 0:
					continue                 # >10 个槽 / 尚未登记：不画，免得编号重复
			else:
				slot = fallback_n
			label = badge_text(slot)
			if label == "":
				continue
		else:
			label = "友" if (rel == SideColorRes.SELF or rel == SideColorRes.ALLY) else "敌"
		var head: Vector2 = units.head_screen_pos(u)
		if not keep.has_point(head):
			continue
		var quad: Vector2 = units.quad_screen_size(u)
		if quad.y <= 0.0:
			continue
		entries.append({
			"u": u,
			"rel": rel,
			"self": is_self,
			"slot": slot,
			"label": label,
			"head": head,
			"quad_h": quad.y,
			"selected": _selection.has(String(u.id)),
		})
	if entries.is_empty():
		return

	# ② 己方选中的先排名牌：围绕各自头顶找**不重叠**的位置。
	#    不再「挤不下就退回键帽」——用户口径：展开的标签栏彼此不压即可。
	var plates: Array = []
	var plate_rects: Array[Rect2] = []
	var plate_ids: Dictionary = {}
	for e in entries:
		if not bool(e["self"]) or not bool(e["selected"]):
			continue
		var base: Rect2 = _nameplate_rect(e, vp_size)
		var plate: Rect2 = _place_nameplate(base, vp_size, plate_rects)
		e["plate"] = plate
		e["base_plate"] = base
		plates.append(e)
		plate_rects.append(plate)
		var uu = e["u"]
		plate_ids[String(uu.id)] = true

	# ③ 键帽：避让已放下的名牌 + 其它键帽；己方选中且已有名牌的不再画键帽。
	var badge_rects: Array[Rect2] = []
	for pr in plate_rects:
		badge_rects.append(pr)
	for pass_self in [true, false]:
		for e in entries:
			if bool(e["self"]) != bool(pass_self):
				continue
			if bool(e["self"]) and plate_ids.has(String(e["u"].id)):
				continue
			_draw_badge(e, badge_rects)

	# ④ 名牌最后画（压在键帽之上）；被让开较远的先画一条细引线回头顶。
	for e in plates:
		var plate: Rect2 = e["plate"]
		var base: Rect2 = e.get("base_plate", plate)
		if absf(plate.position.y - base.position.y) > NAMEPLATE_H \
				or absf(plate.position.x - base.position.x) > 8.0:
			var head: Vector2 = e["head"]
			var from := Vector2(plate.get_center().x, plate.end.y)
			var c: Color = ThemeRes.line()
			c.a = 0.35
			draw_line(from, head, c, 1.0, true)
	for e in plates:
		_draw_nameplate(e)


## 给一张名牌找不重叠的位置：
##   · 先竖直向上 / 向下让（每次 `NAMEPLATE_H + 6`），再左右各让一列；
##   · 必须完全落在视口内；
##   · 找不到时退回锚点（极端情况，正常 10 个以内一定能找到）。
func _place_nameplate(anchor: Rect2, vp_size: Vector2, placed: Array[Rect2]) -> Rect2:
	var step_y: float = NAMEPLATE_H + NAMEPLATE_STACK_PX
	var step_x: float = anchor.size.x + 8.0
	var candidates: Array[Vector2] = [Vector2.ZERO]
	for i in range(1, 17):
		candidates.append(Vector2(0.0, -step_y * float(i)))
		candidates.append(Vector2(0.0, step_y * float(i)))
	for col in range(1, 4):
		for i in range(0, 17):
			var dx: float = step_x * float(col)
			candidates.append(Vector2(dx, -step_y * float(i)))
			candidates.append(Vector2(-dx, -step_y * float(i)))
			candidates.append(Vector2(dx, step_y * float(i)))
			candidates.append(Vector2(-dx, step_y * float(i)))
	for off in candidates:
		var r := Rect2(anchor.position + off, anchor.size)
		if r.position.x < 4.0 or r.end.x > vp_size.x - 4.0:
			continue
		if r.position.y < 4.0 or r.end.y > vp_size.y - 4.0:
			continue
		if not _rect_hits(r, placed):
			return r
	return anchor


## 一个键帽。`rects` = 已经放下的矩形（名牌 + 键帽；密集时逐级向上让 3px）。
func _draw_badge(e: Dictionary, rects: Array[Rect2]) -> void:
	var u = e["u"]
	var selected: bool = bool(e["selected"])
	var s: float = badge_size_for(float(e["quad_h"]))
	var head: Vector2 = e["head"]
	var r := Rect2(head.x - s * 0.5, head.y - BADGE_GAP - s, s, s)
	for attempt in 4:
		var rr := r
		rr.position.y -= 3.0 * float(attempt)
		if not _rect_hits(rr, rects):
			r = rr
			break
	if r.position.y < 2.0:
		r.position.y = 2.0
	rects.append(r)

	var downed: bool = u.has_method("is_downed") and bool(u.is_downed())
	var alpha: float = DOWNED_MARKER_ALPHA if downed else 1.0
	var style: StyleBoxFlat = _style_badge
	if downed:
		style = _style_badge_downed
	elif selected:
		style = _style_badge_sel
	draw_style_box(style, r)

	# 底边阵营色（与右栏数字块 / 血条同一个色源）：己蓝 / 友金 / 敌红。
	# ★ 观战里被观战方也写「友」——按「友」的字面用盟友金，而不是自机蓝，
	#   否则同一个「友」字在观战 / 合作两种局里会是两种颜色。
	var side: Color = SideColorRes.color(cfg, world, String(u.faction), "main")
	if not bool(e["self"]):
		side = cfg.side_color_ally if String(e["label"]) == "友" else cfg.side_color_enemy
	side.a *= alpha
	var strip_w: float = maxf(0.0, r.size.x - 6.0)
	if strip_w > 0.5:
		draw_rect(Rect2(r.position.x + 3.0, r.end.y - BADGE_STRIP_H - 1.5,
			strip_w, BADGE_STRIP_H), side, true)

	# 数字 / 敌 / 友：己方走暖白，敌友直接走阵营色（蓝 / 金 / 红）。
	var text: String = String(e["label"])
	var fs: int = int(round(r.size.y * 0.66))
	var tw: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var base := r.position.y + r.size.y * 0.5 + font.get_ascent(fs) * 0.5 - 1.0
	var tcol: Color = ThemeRes.text() if bool(e["self"]) else side
	tcol.a *= alpha
	draw_string(font, Vector2(r.position.x + (r.size.x - tw) * 0.5, base), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, tcol)

	# 倒地：右上角一个小十字（与旧 2D 版「头顶小十字」同一个意思）。
	if downed:
		var cw := 3.0
		var c := Vector2(r.end.x - 5.0, r.position.y + 5.0)
		var wc: Color = ThemeRes.warning()
		wc.a *= 0.9
		draw_line(c - Vector2(cw, cw), c + Vector2(cw, cw), wc, 1.2, true)
		draw_line(c - Vector2(cw, -cw), c + Vector2(cw, -cw), wc, 1.2, true)

	badge_draw_count += 1
	draw_count += 1


## 选中名牌的矩形：宽度按「键帽 + 兵种字 + 名字 + 编制」现算，夹在屏幕内。
## 同时把排版用的文本 / 宽度写回 `e`，`_draw_nameplate` 不再重复量字。
func _nameplate_rect(e: Dictionary, vp_size: Vector2) -> Rect2:
	var u = e["u"]
	var type_txt: String = _marker_type_text(u)
	var name_txt: String = _marker_name(u)
	var form_txt: String = _marker_formation(u)
	var type_w: float = font.get_string_size(
		type_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, NAMEPLATE_FONT).x
	var form_w: float = font.get_string_size(
		form_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, NAMEPLATE_FORM_FONT).x
	var fixed: float = NAMEPLATE_PAD * 2.0 + NAMEPLATE_KEY + NAMEPLATE_KEY_GAP
	var type_part: float = type_w + (NAMEPLATE_KEY_GAP if type_w > 0.0 else 0.0)
	var name_avail: float = NAMEPLATE_MAX_W - fixed - type_part - 8.0 - form_w
	if name_txt != "":
		name_txt = _fit_text(name_txt, maxf(20.0, name_avail), NAMEPLATE_FONT)
	var name_w: float = 0.0
	if name_txt != "":
		name_w = font.get_string_size(
			name_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, NAMEPLATE_FONT).x
	var w: float = fixed + type_part + name_w + (8.0 if name_w > 0.0 else 0.0) + form_w
	w = clampf(w, 70.0, NAMEPLATE_MAX_W)

	e["type_txt"] = type_txt
	e["name_txt"] = name_txt
	e["form_txt"] = form_txt
	e["type_w"] = type_w
	e["name_w"] = name_w
	e["form_w"] = form_w

	var head: Vector2 = e["head"]
	var x: float = head.x - w * 0.5
	if x < 4.0:
		x = 4.0
	elif x + w > vp_size.x - 4.0:
		x = maxf(4.0, vp_size.x - 4.0 - w)
	var y: float = head.y - NAMEPLATE_GAP - NAMEPLATE_H
	if y < 2.0:
		y = 2.0
	return Rect2(Vector2(x, y), Vector2(w, NAMEPLATE_H))


## 选中名牌：`[键帽] 兵种字 名字        编制`，底边一条士气条。
func _draw_nameplate(e: Dictionary) -> void:
	var u = e["u"]
	var r: Rect2 = e["plate"]
	var downed: bool = u.has_method("is_downed") and bool(u.is_downed())
	var alpha: float = 0.78 if downed else 1.0
	draw_style_box(_style_name_downed if downed else _style_name, r)

	# 键帽（名牌里也保留编号：按键提示不因「升级成名片」而丢）
	var key := Rect2(r.position.x + NAMEPLATE_PAD,
		r.position.y + (r.size.y - NAMEPLATE_KEY) * 0.5, NAMEPLATE_KEY, NAMEPLATE_KEY)
	draw_style_box(_style_key_downed if downed else _style_key, key)
	var side: Color = SideColorRes.color(cfg, world, String(u.faction), "main")
	side.a *= alpha
	draw_rect(Rect2(key.position.x + 3.0, key.end.y - 3.5, key.size.x - 6.0, 2.0),
		side, true)
	var ktxt: String = String(e["label"])
	var kf: int = NAMEPLATE_KEY_FONT
	var kw: float = font.get_string_size(ktxt, HORIZONTAL_ALIGNMENT_LEFT, -1, kf).x
	var kb := key.position.y + key.size.y * 0.5 + font.get_ascent(kf) * 0.5 - 1.0
	var kcol: Color = ThemeRes.text()
	kcol.a *= alpha
	draw_string(font, Vector2(key.position.x + (key.size.x - kw) * 0.5, kb), ktxt,
		HORIZONTAL_ALIGNMENT_LEFT, -1, kf, kcol)

	# 文本行：整体略偏上，给底部 2px 士气条留位置。
	var baseline: float = (r.position.y + r.size.y * 0.5
		+ font.get_ascent(NAMEPLATE_FONT) * 0.5 - 2.5)
	var x: float = key.end.x + NAMEPLATE_KEY_GAP
	var type_txt: String = String(e.get("type_txt", ""))
	if type_txt != "":
		var tcol: Color = side
		draw_string(font, Vector2(x, baseline), type_txt, HORIZONTAL_ALIGNMENT_LEFT, -1,
			NAMEPLATE_FONT, tcol)
		x += float(e.get("type_w", 0.0)) + NAMEPLATE_KEY_GAP
	var name_txt: String = String(e.get("name_txt", ""))
	if name_txt != "":
		var ncol: Color = ThemeRes.text()
		ncol.a *= alpha
		draw_string(font, Vector2(x, baseline), name_txt, HORIZONTAL_ALIGNMENT_LEFT, -1,
			NAMEPLATE_FONT, ncol)

	# 编制 / 状态右对齐（倒地时是「再起 / 倒地」，颜色走 warning）。
	var form_txt: String = String(e.get("form_txt", ""))
	var form_w: float = float(e.get("form_w", 0.0))
	var fcol: Color = ThemeRes.warning() if downed else ThemeRes.text_dim()
	fcol.a *= alpha
	draw_string(font, Vector2(r.end.x - NAMEPLATE_PAD - form_w, baseline), form_txt,
		HORIZONTAL_ALIGNMENT_LEFT, -1, NAMEPLATE_FORM_FONT, fcol)

	# 士气条：绿 → 红，与图标里的士气填充同一套端点色。
	var bar := Rect2(r.position.x + NAMEPLATE_PAD, r.end.y - 3.5,
		r.size.x - NAMEPLATE_PAD * 2.0, 2.0)
	var bg: Color = ThemeRes.line_soft()
	bg.a *= 0.55 * alpha
	draw_rect(bar, bg, true)
	var ratio := 0.0
	if u.has_method("morale_ratio"):
		ratio = clampf(float(u.morale_ratio()), 0.0, 1.0)
	var fill: Color = ThemeRes.morale_low().lerp(ThemeRes.morale_high(), ratio)
	fill.a *= alpha
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * ratio, bar.size.y)), fill, true)

	nameplate_draw_count += 1
	draw_count += 1


## 名牌里的兵种字：枪 / 弓 / 骑……（`cfg.unit_icon_of` 与 HUD 图标同一个口径）。
func _marker_type_text(u) -> String:
	if cfg == null:
		return ""
	var tid := String(u.unit_type)
	var icon := ""
	if tid != "":
		icon = cfg.unit_icon_of(tid)
	else:
		icon = cfg.unit_icon_of(String(u.kind))
	return "" if icon == "?" else icon


## 名牌里的名字：单位名 → 兵种名 → 「将领」。
func _marker_name(u) -> String:
	var s := String(u.name).strip_edges()
	if s != "":
		return s
	if cfg != null:
		var nm := cfg.unit_name_of(String(u.unit_type))
		if nm != "":
			return nm
	return "将领"


## 名牌右端：编制 `当前/上限`；倒地时改成状态字（再起 / 倒地）。
func _marker_formation(u) -> String:
	if u.has_method("is_downed") and bool(u.is_downed()):
		if u.has_method("is_reviving") and bool(u.is_reviving()):
			return "再起"
		return "倒地"
	var count := 1
	if world != null and world.has_method("group_of"):
		count = (world.group_of(u) as Array).size()
	var cap := 0
	if world != null and world.has_method("effective_retinue_cap"):
		cap = int(world.effective_retinue_cap(u))
	elif cfg != null and cfg.has_method("general_cap_at"):
		cap = int(cfg.general_cap_at(int(u.general_index)))
	if cap > 0:
		return "%d/%d" % [count, cap]
	return str(count)


## 第几支 → 键帽上的字：现在槽位是 1..6，原样写；`% 10` 只是兜底（与数字键同一口径）。
static func badge_text(slot: int) -> String:
	if slot <= 0:
		return ""
	return str(slot % 10)


## 键帽边长：跟着立牌的**屏幕高度**轻微浮动，再夹到 [BADGE_MIN_PX, BADGE_MAX_PX]。
## ★ 为什么不是固定字号：默认视角下立牌只有 30 多像素高，固定 18px 字会显得比兵还大；
##   拉近之后又显得小。跟着立牌高度走，远近都像「长在单位头顶」。
static func badge_size_for(quad_h: float) -> float:
	return clampf(quad_h * BADGE_SPRITE_RATIO, BADGE_MIN_PX, BADGE_MAX_PX)


## 两矩形是否相压（只算真正重叠；贴边不算）。
static func _rect_hits(r: Rect2, rects: Array[Rect2]) -> bool:
	for o in rects:
		if r.intersects(o, false):
			return true
	return false


## 单行裁剪：宽度不够时截断并补「…」（与 troop_row 的 `_fit` 同一个目的）。
func _fit_text(text: String, max_w: float, fs: int) -> String:
	if font == null or max_w <= 0.0:
		return ""
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= max_w:
		return text
	var s := text
	while s.length() > 1:
		s = s.substr(0, s.length() - 1)
		if font.get_string_size(s + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= max_w:
			return s + "…"
	return "…"


var _selection: Dictionary = {}


## 由 game_scene 每帧喂「哪些单位被选中」
func set_selection(ids: Array) -> void:
	_selection = {}
	for id in ids:
		_selection[String(id)] = true


func _unit_visible(u) -> bool:
	if world == null or world.fog == null or cfg == null:
		return true
	if not cfg.fog_enabled:
		return true
	return world.fog.unit_visible(world.my_faction, u)


## 移动目标点（绿圈 + 十字）与行军攻击目标点（红圈 + 叉）
##
## ★★ 本版**不再画**：右键指令的提示改成了 3D 旗子（`view/order_flag_view_3d.gd`）。
##   `move_marks` / `attack_marks` 两个字段**保留**（input_controller 还在写、2D 遗留栈
##   与既有测试还在读），只是 3D 这条路不再把它们画成屏幕空间的圈。
func _draw_move_marks() -> void:
	for m in move_marks:
		var p: Vector2 = palette.to_px(m)
		var c := Color(0.6, 1.0, 0.7, 0.85)
		draw_arc(p, 14.0, 0.0, TAU, 24, c, 2.0)
		draw_line(p + Vector2(-6, 0), p + Vector2(6, 0), c, 1.5)
		draw_line(p + Vector2(0, -6), p + Vector2(0, 6), c, 1.5)
		draw_count += 1
	for m2 in attack_marks:
		var q: Vector2 = palette.to_px(m2)
		var c2 := Color(1.0, 0.45, 0.4, 0.9)
		draw_arc(q, 16.0, 0.0, TAU, 28, c2, 2.0)
		draw_line(q + Vector2(-7, -7), q + Vector2(7, 7), c2, 2.0)
		draw_line(q + Vector2(-7, 7), q + Vector2(7, -7), c2, 2.0)
		draw_count += 1


## 建造预览：**沿地块的四个角投出来的四边形**（透视下是梯形，不是矩形）
func _draw_build_preview() -> void:
	if build_type == "" or hover_tile.x < 0:
		return
	var ok: bool = world.can_build_at(hover_tile.x, hover_tile.y, world.my_faction)
	var c := Color(0.45, 1.0, 0.5, 0.55) if ok else Color(1.0, 0.4, 0.4, 0.55)
	var quad := _tile_screen_quad(hover_tile)
	if quad.size() < 4:
		return
	draw_colored_polygon(quad, Color(c.r, c.g, c.b, 0.18))
	var closed := quad.duplicate()
	closed.append(quad[0])
	draw_polyline(closed, c, 2.5)
	draw_count += 1


## 一个格在屏幕上的四个角（顺序：左上 → 右上 → 右下 → 左下）
##
## ★ 用 `palette.to_px` 逐个角投 —— 透视下**不能**只投中心再套一个矩形：
##   那样四角会是错的（地块在屏幕上是梯形）。
func _tile_screen_quad(tile: Vector2i) -> PackedVector2Array:
	return PackedVector2Array([
		palette.to_px(Vector2(float(tile.x), float(tile.y))),
		palette.to_px(Vector2(float(tile.x + 1), float(tile.y))),
		palette.to_px(Vector2(float(tile.x + 1), float(tile.y + 1))),
		palette.to_px(Vector2(float(tile.x), float(tile.y + 1))),
	])


## 框选矩形：世界坐标（格）→ 屏幕多边形（透视下也是一个四边形）
##
## ★★ 触摸设备另有一条路（`drag_screen_valid`）：直接按**两指的屏幕矩形**画。
##   原因（用户报的「右手在上、左手在下时，右上 / 左下不跟手」）：世界轴对齐的矩形在
##   透视下投影回来是四边形，远端那条边会缩进 —— 越远的角离手指越远。屏幕矩形没有这个问题，
##   两个角逐像素落在手指上。判定仍然用世界矩形（`box_select`），两根手指的**画面**与
##   **选中结果**只在透视的远端有一点点差，这是这套相机本身的取舍（PC 那条路同源）。
func _draw_drag_box() -> void:
	if not drag_active:
		return
	if drag_screen_valid:
		var r := drag_screen_box
		# 退化（两根手指几乎在同一点）时不画：一个 0×0 的框没有意义
		if r.size.x <= 0.5 and r.size.y <= 0.5:
			return
		var sq := PackedVector2Array([
			r.position,
			Vector2(r.end.x, r.position.y),
			r.end,
			Vector2(r.position.x, r.end.y),
		])
		var sc := Color(0.75, 0.95, 1.0, 0.9)
		draw_colored_polygon(sq, Color(sc.r, sc.g, sc.b, 0.12))
		var sclosed := sq.duplicate()
		sclosed.append(sq[0])
		draw_polyline(sclosed, sc, 2.0)
		draw_count += 1
		return
	if drag_rect.size.x <= 0.0 and drag_rect.size.y <= 0.0:
		return
	var quad := PackedVector2Array([
		palette.to_px(drag_rect.position),
		palette.to_px(drag_rect.position + Vector2(drag_rect.size.x, 0.0)),
		palette.to_px(drag_rect.position + drag_rect.size),
		palette.to_px(drag_rect.position + Vector2(0.0, drag_rect.size.y)),
	])
	var c := Color(0.75, 0.95, 1.0, 0.9)
	draw_colored_polygon(quad, Color(c.r, c.g, c.b, 0.12))
	var closed := quad.duplicate()
	closed.append(quad[0])
	draw_polyline(closed, c, 2.0)
	draw_count += 1
