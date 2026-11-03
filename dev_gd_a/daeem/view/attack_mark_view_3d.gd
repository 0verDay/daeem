## attack_mark_view_3d.gd —— 「指定攻击」的目标标记（**纯表现**，无碰撞）
##
## ★★ 触发：玩家**右键单击任意敌方建筑 / 单位**（或操作页「攻击」格左键点目标）时，
##   `game_scene3d._on_command` 收到本机的 `attack` 命令后调 `mark()`。一个标记 = 两样东西：
##     1. 目标**头顶**浮起「行军图标」—— 贴图与插旗杆顶那个红色交叉图标**共用**
##        （`view/command_mark_fx.gd` 的 `march_icon_texture()`，用户口径「共用素材」）；
##     2. 目标**脚底**泛出一圈**红环** —— 与移动 / 行军的插旗波纹**同一套**动效：
##        从很小的一圈**向外扩散**并淡出（不是一直贴着单位呼吸），颜色走三色表
##        （移动 = 绿 / 行军 = 黄 / 指定攻击 = 红，见 `CommandFxRes.ring_color()`）。
##
## ★★ 为什么不用插旗（`order_flag_view_3d.gd`）：旗子是插在**目标点**地面上的；
##   而指定攻击的对象是**会走的单位**或**有高度的建筑** —— 标记必须每帧跟着目标，
##   所以位置每帧从 world 重新解析（单位用视图的插值位置，建筑读模型顶边）。
##
## ★★ 生命周期：
##   · 只保留**最新**一个标记（与插旗同一个手感：新命令替换旧的）；
##   · 总时长 `render.attack_mark_sec`（渐入 → 停住 → 渐出），播完自己消失；
##   · 目标**阵亡**，或单位**走出视野**（迷雾）⇒ 立刻进入渐出 —— 不能把迷雾里的敌人点亮；
##   · `stop` / 新的移动 / 行军命令 ⇒ `clear()`。
##
## ★ 动画由 `sync(dt)` 推进（`game_scene3d._process` 每帧调；暂停传 0 ⇒ 冻结），
##   不用 Tween：测试可以逐帧推进并断言每个阶段。
## ★ 只读 cfg / palette / world（**只读**）：不写任何逻辑状态、不进快照、无碰撞。
extends Node3D

## ★ 指令标记的共用素材（行军图标 / 圆环贴图 + 三色环色表）
const CommandFxRes = preload("res://view/command_mark_fx.gd")

## 圆环贴地高度（世界单位）：比选中圈（1.0）略低一点点，避免与它共面闪烁；
## 与插旗波纹同高，换指令时画面不会「跳一下」。
const RING_Y := 0.96
## 波纹的**起始缩放**（相对最终半径）：与插旗波纹一致（从很小的一圈泛开）
const RING_SCALE_FROM := 0.12

var cfg = null
var palette = null
var world = null
## 单位层 / 建筑层：要问它们「目标现在画在哪、还看不看得见」
var unit_view = null
var building_view = null

var _root: Node3D = null
var _ring: MeshInstance3D = null
var _ring_mesh: QuadMesh = null
var _ring_mat: StandardMaterial3D = null
var _icon: MeshInstance3D = null
var _icon_mesh: QuadMesh = null
var _icon_mat: StandardMaterial3D = null

## 当前标记（对外可读；测试与诊断都看这几个）
var active: bool = false
## "attack"（本轮入口）；"move" / "attack_move" 也能标（环色不同，见三色表）
var kind: String = ""
## "unit" / "building"
var target_kind: String = ""
var target_id: String = ""
var target_tile: Vector2i = Vector2i(-1, -1)
## 动画阶段：idle / in / hold / out / done（诊断 + 测试读）
var phase: String = "idle"

## 诊断（只有测试读）—— 世界单位 / 世界坐标
var marks_shown: int = 0
var elapsed_last: float = 0.0
var ring_color_last: Color = Color.WHITE
var ring_alpha_last: float = 0.0
## 波纹**当前**半径与**最终**半径（世界单位；当前 < 最终 = 正在向外扩）
var ring_radius_last: float = 0.0
var ring_radius_final_last: float = 0.0
var ring_world_last: Vector3 = Vector3.ZERO
var ring_scale_last: float = 1.0
var icon_alpha_last: float = 0.0
var icon_visible_last: bool = false
var icon_world_last: Vector3 = Vector3.ZERO
var icon_size_last: float = 0.0

## setup 缓存的 config（不在每帧 cfg.num）
var _sec: float = 1.4
var _fade_in: float = 0.12
var _fade_out: float = 0.35
## ★ 脚下红圈是**一次性外泛波纹**（与移动 / 行军的插旗波纹同一套动效）：
##   从很小扩到最终半径、同时淡出；**不跟随单位**（泛出的位置 = 下令那一刻的脚下）。
var _ring_sec: float = 0.5
var _ring_alpha: float = 0.85
var _ring_radius: float = 0.55        ## 圆环最小半径（世界单位）
var _ring_pad: float = 0.35           ## 环半径比目标脚印再大出多少（世界单位）
var _icon_size: float = 0.42          ## 图标基准边长（世界单位；再乘目标占地）
var _icon_stroke: float = 0.05        ## 线宽 ÷ 图标边长（与插旗图标默认一致 ⇒ 共用同一张贴图）
var _icon_gap: float = 0.18           ## 图标底边离头顶多少（世界单位）

## 运行时
var _elapsed: float = 0.0
var _lost: bool = false
var _lost_at: float = 0.0
## 目标这一帧的锚点（解析失败时**保留上一帧**：渐出期间不会乱跳）
var _feet: Vector3 = Vector3.ZERO
var _head: Vector3 = Vector3.ZERO
var _half: float = 0.5
var _anchor_ok: bool = false
## 波纹的落点（下令那一刻的脚下，之后**不再跟随**）与最终半径（世界单位）
var _ripple_origin: Vector3 = Vector3.ZERO
var _ring_radius_final: float = 0.0


func setup(p_cfg, p_palette, p_world, p_unit_view, p_building_view) -> void:
	cfg = p_cfg
	palette = p_palette
	world = p_world
	unit_view = p_unit_view
	building_view = p_building_view
	var cell: float = palette.cell_size() if palette != null else 128.0
	_sec = maxf(0.05, cfg.num("render.attack_mark_sec", 1.4))
	_fade_in = clampf(cfg.num("render.attack_mark_fade_in_sec", 0.12), 0.001, _sec)
	_fade_out = clampf(cfg.num("render.attack_mark_fade_out_sec", 0.35), 0.001, _sec)
	_ring_sec = maxf(0.05, cfg.num("render.attack_mark_ring_sec", 0.5))
	_ring_alpha = clampf(cfg.num("render.attack_mark_ring_alpha", 0.85), 0.0, 1.0)
	_ring_radius = maxf(cell * 0.05, cell * cfg.num("render.attack_mark_ring_radius", 0.55))
	_ring_pad = maxf(0.0, cell * cfg.num("render.attack_mark_ring_pad", 0.35))
	_icon_size = maxf(cell * 0.1, cell * cfg.num("render.attack_mark_icon_size", 0.42))
	_icon_stroke = clampf(cfg.num("render.attack_mark_icon_stroke", 0.05), 0.01, 0.2)
	_icon_gap = maxf(0.0, cell * cfg.num("render.attack_mark_icon_gap", 0.18))
	_build_nodes()


func _build_nodes() -> void:
	for c in [_ring, _icon, _root]:
		if is_instance_valid(c):
			c.queue_free()
	# ---- 脚底圆环：贴地面片；缩放 = 向外扩散，alpha = 淡出（与插旗波纹同一套）----
	_ring_mesh = QuadMesh.new()
	_ring_mesh.size = Vector2.ONE
	_ring_mat = _make_mat(Color(1.0, 1.0, 1.0, 0.0), CommandFxRes.ring_texture())
	_ring = MeshInstance3D.new()
	_ring.name = "AttackMarkRing"
	_ring.mesh = _ring_mesh
	_ring.material_override = _ring_mat
	_ring.rotation = Vector3(-PI * 0.5, 0.0, 0.0)   # QuadMesh 默认在 XY 面 ⇒ 放平
	_ring.position = Vector3(0.0, RING_Y, 0.0)
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.visible = false
	# ---- 头顶图标：竖立面向镜头（相机固定不旋转，+Z 面片正对镜头）----
	_icon_mesh = QuadMesh.new()
	_icon_mesh.size = Vector2.ONE
	_icon_mat = _make_mat(Color(1.0, 1.0, 1.0, 0.0), CommandFxRes.march_icon_texture(_icon_stroke))
	_icon = MeshInstance3D.new()
	_icon.name = "AttackMarkIcon"
	_icon.mesh = _icon_mesh
	_icon.material_override = _icon_mat
	_icon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_icon.visible = false

	_root = Node3D.new()
	_root.name = "AttackMark"
	_root.add_child(_ring)
	_root.add_child(_icon)
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
		# ★ 128² 小图会被明显缩放 ⇒ 开 mipmap 防闪烁（与插旗同一口径）
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return m


## 在 `target`（敌方单位 / 建筑）身上打一个标记；只保留**最新**的那个。
## @param p_kind 环色键："attack"（红）/ "attack_move"（黄）/ "move"（绿）
## @return true = 真的标上了（目标已死 / 视野外 / 类型不认识 ⇒ false）
func mark(p_kind: String, target) -> bool:
	if _root == null or target == null:
		return false
	# ★ 单位有 `unit_type`、建筑有 `type`（`Object.get()` 对不存在的属性返回 null，不报错）
	var ut: Variant = target.get("unit_type")
	var bt: Variant = target.get("type")
	if ut != null:
		target_kind = "unit"
		target_id = String(target.id)
		target_tile = Vector2i(-1, -1)
	elif bt != null:
		target_kind = "building"
		target_id = ""
		target_tile = Vector2i(int(target.tx), int(target.ty))
	else:
		return false

	kind = p_kind if String(p_kind) != "" else "attack"
	active = true
	marks_shown += 1
	_elapsed = 0.0
	elapsed_last = 0.0
	_lost = false
	_lost_at = 0.0
	phase = "in"
	_resolve_anchor()
	if not _anchor_ok:
		# ★ 目标已经没了 / 看不见：把**上一个**标记也收掉，别留一个过期标记在屏幕上
		clear()
		return false

	# ---- 脚底圆环（一次性外泛波纹）：颜色 = 三色表；半径按目标**脚印**
	#      （建筑按本体、单位按立牌宽）。★ 落点 = **下令那一刻**的脚下，之后不再跟随单位。
	var c: Color = CommandFxRes.ring_color(cfg, kind)
	ring_color_last = c
	var r: float = maxf(_ring_radius, _half + _ring_pad)
	ring_radius_final_last = r
	_ring_radius_final = r
	var span: float = r / CommandFxRes.RING_RADIUS_RATIO
	_ring_mesh.size = Vector2(span, span)
	_ring_mat.albedo_texture = CommandFxRes.ring_texture()
	_ring_mat.albedo_color = Color(c.r, c.g, c.b, 0.0)
	_ripple_origin = Vector3(_feet.x, RING_Y, _feet.z)
	_ring.position = _ripple_origin
	_ring.scale = Vector3.ONE * RING_SCALE_FROM
	ring_scale_last = RING_SCALE_FROM
	ring_radius_last = r * RING_SCALE_FROM
	_ring.visible = true

	# ---- 头顶图标：共用「行军图标」贴图；边长随目标占地放大（建筑比单位大一号）----
	# ⚠️ `_half` 是**世界单位**，这里要换回格再当倍数（否则会乘出一个几千单位大的面片）。
	var cell_px: float = palette.cell_size() if palette != null else 128.0
	var span_cells: float = maxf(1.0, (_half * 2.0) / maxf(1.0, cell_px))
	var isz: float = _icon_size * span_cells
	icon_size_last = isz
	_icon_mesh.size = Vector2(isz, isz)
	_icon_mat.albedo_texture = CommandFxRes.march_icon_texture(_icon_stroke)
	var ic: Color = CommandFxRes.icon_color(cfg)
	_icon_mat.albedo_color = Color(ic.r, ic.g, ic.b, 0.0)
	_icon.scale = Vector3.ONE
	_icon.visible = false

	_root.visible = true
	_update()
	return true


## 收掉标记（stop / 新移动 / 新行军命令 / 场景重建）。
func clear() -> void:
	active = false
	kind = ""
	target_kind = ""
	target_id = ""
	target_tile = Vector2i(-1, -1)
	phase = "idle"
	_elapsed = 0.0
	elapsed_last = 0.0
	_lost = false
	_lost_at = 0.0
	_anchor_ok = false
	ring_alpha_last = 0.0
	icon_alpha_last = 0.0
	icon_visible_last = false
	if _root != null:
		_root.visible = false
	if _ring != null:
		_ring.visible = false
	if _icon != null:
		_icon.visible = false


## 每帧推进。`dt` = 0（暂停 / 刚下令只想看当前状态）时**不推进**，只重算位置与透明度。
func sync(dt: float = 0.0) -> void:
	if _root == null:
		return
	if not active:
		_root.visible = false
		return
	if dt > 0.0:
		_elapsed += dt
		elapsed_last = _elapsed
	# ★ 目标会动（单位）或会死 / 会进迷雾 ⇒ 每帧重解析锚点；失败就进入渐出
	_resolve_anchor()
	if not _anchor_ok and not _lost:
		_lost = true
		_lost_at = _elapsed
	_update()


func _update() -> void:
	# ---- 时间轴：渐入 / 停住 / 渐出（目标丢失时渐出**提前**开始）----
	var t_in: float = clampf(_elapsed / _fade_in, 0.0, 1.0)
	var out_start: float = _sec - _fade_out
	if _lost:
		out_start = minf(out_start, _lost_at)
	var t_out: float = clampf((_elapsed - out_start) / _fade_out, 0.0, 1.0)
	if _lost:
		# ★ 目标没了 ⇒ 从丢失那一刻就开始渐出（哪怕这一帧 t_out 还是 0）
		phase = "out"
	elif t_out > 0.0:
		phase = "out"
	elif t_in >= 1.0:
		phase = "hold"
	else:
		phase = "in"
	# ★ 渐入用 ease-out（一下就亮起来），渐出用 smooth（收得柔和）—— 只作用于**头顶图标**
	var vis: float = _ease_out(t_in) * (1.0 - _smooth(t_out))

	# ---- 脚底红圈：一次性**向外扩散**的波纹（位置固定在下令那一刻的脚下，不跟随单位）----
	_update_ripple()

	# ---- 头顶图标：只做「出现 / 消失」的淡入淡出，不持续浮动 ----
	var ic: Color = CommandFxRes.icon_color(cfg)
	var iy: float = _head.y + _icon_gap + icon_size_last * 0.5
	_icon.position = Vector3(_head.x, iy, _head.z)
	icon_world_last = _icon.position
	var pop: float = lerpf(0.72, 1.0, _ease_out(t_in))
	_icon.scale = Vector3(pop, pop, pop)
	icon_alpha_last = vis
	icon_visible_last = vis > 0.001
	_icon.visible = icon_visible_last
	_icon_mat.albedo_color = Color(ic.r, ic.g, ic.b, icon_alpha_last)

	# ★ 结束时刻 = 渐出起点 + 渐出时长：正常到期时它正好 = `_sec`；
	#   目标提前丢失时会更早结束 —— 但**不能早于波纹泛完**（波纹是独立的一次性动效）。
	if _elapsed >= maxf(out_start + _fade_out, _ring_sec):
		_finish()


## 脚下红圈：与移动 / 行军的插旗波纹**同一套**动效 ——
## 从 `RING_SCALE_FROM`（很小的一圈）扩到最终半径（先快后慢），alpha 一路降到 0；
## 落点 `_ripple_origin` 是下令那一刻的脚下，之后**不再跟随单位**。
func _update_ripple() -> void:
	var tr: float = clampf(_elapsed / _ring_sec, 0.0, 1.0)
	ring_world_last = _ripple_origin
	if tr >= 1.0:
		_ring.visible = false
		ring_alpha_last = 0.0
		return
	# 由小到大、先快后慢（与插旗波纹 `_update_ripple` 同一条曲线）
	var e: float = 1.0 - (1.0 - tr) * (1.0 - tr)
	var s: float = lerpf(RING_SCALE_FROM, 1.0, e)
	_ring.scale = Vector3(s, s, s)
	ring_scale_last = s
	ring_radius_last = _ring_radius_final * s
	ring_alpha_last = _ring_alpha * (1.0 - tr)
	var c: Color = ring_color_last
	_ring_mat.albedo_color = Color(c.r, c.g, c.b, ring_alpha_last)
	_ring.visible = ring_alpha_last > 0.001


func _finish() -> void:
	active = false
	phase = "done"
	ring_alpha_last = 0.0
	icon_alpha_last = 0.0
	icon_visible_last = false
	if _root != null:
		_root.visible = false
	if _ring != null:
		_ring.visible = false
	if _icon != null:
		_icon.visible = false


## ---------------- 目标锚点（这一帧的脚底 / 头顶 / 脚印） ----------------

## 解析目标当前位置。失败（死了 / 看不见了 / 找不到）时**不动** `_feet` / `_head`，
## 让渐出停在最后已知位置，而不是「啪」地跳回原点。
func _resolve_anchor() -> void:
	_anchor_ok = false
	if world == null or palette == null:
		return
	var cell: float = palette.cell_size()
	if target_kind == "unit":
		var u: Variant = world.unit_by_id(target_id)
		if u == null or not u.alive:
			return
		# ★ 迷雾：单位只有**当前视野内**才画（敌人走出视野就不该继续看到标记）
		if unit_view != null and unit_view.has_method("visible_to_me") \
				and not unit_view.visible_to_me(u):
			return
		var rp: Vector2 = u.pos
		if unit_view != null:
			rp = unit_view.render_pos_of(u)
		_feet = palette.to_world(rp)
		_feet.y = RING_Y
		_head = unit_view.head_world_of(u) if unit_view != null else _feet
		var footprint: float = 1.0
		if unit_view != null:
			footprint = unit_view.footprint_of(u)
		_half = maxf(0.1, footprint * 0.5) * cell
		_anchor_ok = true
		return
	if target_kind == "building":
		var b: Variant = world.building_at(target_tile.x, target_tile.y)
		if b == null or not b.alive:
			return
		if cfg != null and bool(cfg.fog_enabled) and world.fog != null \
				and not world.fog.building_visible(world.my_faction, b):
			return
		_feet = palette.to_world(b.center())
		_feet.y = RING_Y
		_head = building_view.head_world_of(b) if building_view != null else _feet
		_half = maxf(0.1, b.body_half(cfg)) * cell
		_anchor_ok = true


static func _ease_out(k: float) -> float:
	return 1.0 - (1.0 - k) * (1.0 - k)


static func _smooth(k: float) -> float:
	return k * k * (3.0 - 2.0 * k)
