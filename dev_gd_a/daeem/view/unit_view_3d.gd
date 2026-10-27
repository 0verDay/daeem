## unit_view_3d.gd —— 3D 单位：**按「阵营 × 将领 × 兵种 × 选中 × 濒死」分组的多批次 MultiMesh**
##                   + 将领脚下的**占位贴花**层
##
## ★★ 为什么是「多批次」而不是「一个 MultiMesh 画全部」（本版最重要的性能取舍）：
##   `MultiMesh` 的所有实例**共用同一个 mesh ⇒ 同一张贴图**，因此它**不支持逐实例贴图**。
##   而兵人立牌要做到「阵营色描边 + 选中时的金描边 + 将领更粗的描边 + 每个兵种一张素材
##   + 濒死半透明」，就必须有多张图 / 多个材质。
##   ⇒ 做法是：**每种变体一个 `MultiMeshInstance3D`**（各自一张贴图），
##     变体数 = 阵营数 × 2 × 兵种数 × 2（选中），本项目每一项都是个位数
##     ⇒ 场上真正有实例的批次仍然只有十来个，1000 个单位全部塞在这些 MultiMesh 里。
##   ★ 与 2D 那版「按贴图分桶再合批」是**同一个意图换了工具**：
##     那次踩过的坑是「桶用值语义的打包数组 ⇒ 永远是空的 ⇒ 什么都不画」，
##     这里同样留了计数器（`instance_count` / `mesh_batch_count`）给测试钉。
##
## ★ 立起来 + 面向相机 = 材质的 `billboard_mode = BILLBOARD_ENABLED`
##   （引擎自带，**不需要自己写 shader**：绕 Y 轴转向相机、保持直立）。
##
## ★ 那个「字」不在这层：它放在**屏幕空间的覆盖层**里（`overlay_view_3d.gd`），
##   好处是天然 1:1、永远正着朝玩家。
##
## ★ 只读 `world`，不改任何逻辑状态。
extends Node3D

const ConfigRes = preload("res://logic/config.gd")
const PaletteRes = preload("res://view/palette.gd")
const SpriteRes = preload("res://view/unit_sprite_3d.gd")
const HitFxRes = preload("res://view/hit_fx.gd")
## ★★ 局内「敌 / 友 / 己」三色（本轮新增；判据与配色只在那一处，见文件头）
const SideColorRes = preload("res://view/side_color.gd")
## ★ 立牌材质：billboard + 逐像素受击闪白（自定义 shader，见文件头）
const UNIT_FLASH_SHADER = preload("res://view/unit_flash.gdshader")
## ★ 濒死将领的立牌材质：billboard + **整体半透明**（走透明管线；见 unit_downed.gdshader）
const UNIT_DOWNED_SHADER = preload("res://view/unit_downed.gdshader")
## ★ 选中下标：脚下「绿色空心圆」贴花（逐实例透明度动画；见 selection_ring.gdshader）
const SELECTION_RING_SHADER = preload("res://view/selection_ring.gdshader")

## 立牌的世界宽度（一格的比例）
const QUAD_W := 0.42
## 立牌高宽比（贴图是 64×96 ⇒ 1.5）
const QUAD_H_RATIO := 1.5

var cfg: ConfigRes = null
var world = null
var palette = null

var _quad: QuadMesh = null
## 变体键（"阵营|是否将领|兵种|是否濒死"）→ {node, mm, capacity}
var _batches: Dictionary = {}
## 变体键 → 颜色缓存
var _color_cache: Dictionary = {}

## ★★ 将领脚下的**占位贴花**：一个 MultiMesh 画所有将领（逐实例色 = 阵营色）。
var _decal_quad: PlaneMesh = null
var _decal_mm: MultiMesh = null
var _decal_node: MultiMeshInstance3D = null

## ★★ 选中下标：被选中单位脚下的**空心圆**贴花（逐实例透明度动画）。
## ★ 本轮起按「己 / 友 / 敌」分三层：每层一个 MultiMesh + 自己的圈色
##   （蓝 / 黄 / 红），于是「选中的敌人」也能一眼看出是敌人。
var _sel_quad: PlaneMesh = null
## 三档 → {mm, node}（见 view/side_color.gd 的 SELF / ALLY / ENEMY）
var _sel_layers: Dictionary = {}
## id → 出现进度（0 = 完全收起，1 = 完全出现）；`sync(dt)` 每帧朝目标推进
var _sel_anim: Dictionary = {}
## 当前选中的 id 集合（由 `set_selection(ids)` 喂进来）
var _selection_set: Dictionary = {}
## 动画参数（setup 缓存）
var _sel_sec: float = 0.18
var _sel_alpha: float = 0.8
var _sel_scale_from: float = 1.5

## ★★ 悬停填充（见 config.json 的 `render._hover_fill_comment`）：
##   · `_hover_set`   = 本帧要填色的单位 id（由 `set_hover(ids)` 喂进来）；
##   · `_hover_anim`  = id → 0..1 的淡入淡出进度（与选中圈同一套「反向播放」思路）；
##   · 填充走**逐实例自定义数据** `INSTANCE_CUSTOM.g`（`.r` 已经是受击闪白），
##     填充色是**每批次一个 uniform** —— 单位批次 = 一个阵营 ⇒ 同批必然同色。
var _hover_set: Dictionary = {}
var _hover_anim: Dictionary = {}
var _hover_fill_alpha: float = 0.7
var _hover_sec: float = 0.1

## 诊断（只有测试读它）
var instance_count: int = 0
var visible_count: int = 0
## 当前**有实例**的批次数（正常 = 场上出现过的变体数）
var mesh_batch_count: int = 0
## 累计创建过的批次数
var batches_created: int = 0
## ★★ 最近一帧真的**写了几次**实例变换（优化的证据：位置没变的单位不算）
var instance_writes_last_frame: int = 0
## ★ 本帧有多少实例被施加了「受击左右振动」（诊断，测试读它）
var shake_applied_last_frame: int = 0
## ★ 本帧有多少实例真的**写了**受击闪白（诊断，测试读它）
var flash_written_last_frame: int = 0
## ★ 本帧有多少单位是「濒死将领」（走半透明材质；诊断，测试读它）
var downed_count: int = 0
## ★ 本帧画了几张将领脚下贴花（诊断，测试读它）
var decal_count: int = 0
## ★ 本帧画了几个「选中下标」（诊断，测试读它）
var selection_ring_count: int = 0
## ★ 本帧有几个实例带着悬停填充（诊断，测试读它）
var hover_instance_count: int = 0
## ★ 本帧**第一个**选中下标的缩放 / 不透明度（诊断，测试读它）。
##   ⚠️ 为什么不直接读 MultiMesh 的实例数据：实测（Godot 4.7 + 无头）
##   `MultiMesh.get_instance_transform()` **读不回**刚写进去的值（单位批次也读回单位阵），
##   所以把动画的两个关键值留成普通字段给测试钉。
var selection_scale_last: float = 0.0
var selection_alpha_last: float = 0.0
## 受击振动参数（setup 缓存）
var _cell: float = 128.0
var _hit_amp: float = 0.06
var _hit_freq: float = 26.0

## ★★ 本帧「可见单位的 3×3 邻格」集合 —— 在 sync() 的**单次遍历**里顺带标出，
##    供 `building_view_3d` 算「哪些建筑该淡出」（它原先自己再扫一遍全部单位 + 迷雾）。
var _fade_marked: Dictionary = {}
## ★★ 单次遍历时顺带收集的两张小表（都很少），避免 decal / 选中圈各再扫一遍 `world.units`。
var _vis_generals: Array = []      # 本帧可见的将领（贴花用）
var _vis_sel: Array = []           # 本帧可见且「被选中 / 正在做选中动效」的单位（脚圈用）


## 本帧可见单位的 3×3 邻格（`building_view_3d` / `game_scene3d` 取用；见 `_fade_marked`）。
func fade_marked() -> Dictionary:
	return _fade_marked


func setup(p_cfg: ConfigRes, p_world, p_palette) -> void:
	cfg = p_cfg
	world = p_world
	palette = p_palette
	_quad = QuadMesh.new()
	var w: float = palette.cell_size() * QUAD_W
	_quad.size = Vector2(w, w * QUAD_H_RATIO)
	# ★ 受击振动参数：setup 时缓存一次（受击是「每单位每帧」的路径，别在里面 cfg.num）
	_cell = palette.cell_size()
	_hit_amp = cfg.num("render.hit_shake_cells", 0.06)
	_hit_freq = cfg.num("render.hit_shake_freq", 26.0)
	_build_decal_layer()
	# 选中下标动画参数（每帧要用 ⇒ setup 缓存）
	_sel_sec = maxf(0.01, cfg.num("render.selection_ring_sec", 0.18))
	_sel_alpha = clampf(cfg.num("render.selection_ring_alpha", 0.8), 0.0, 1.0)
	_sel_scale_from = maxf(0.1, cfg.num("render.selection_ring_scale_from", 1.5))
	_build_selection_layer()
	# ★★ 悬停填充参数（每帧要用 ⇒ setup 缓存；0 = 立即切换）
	_hover_fill_alpha = clampf(cfg.num("render.hover_fill_alpha", 0.7), 0.0, 1.0)
	_hover_sec = maxf(0.0, cfg.num("render.hover_fill_sec", 0.1))
	_hover_set = {}
	_hover_anim = {}


## ★★ 将领脚下的占位贴花层：一块**平放**的 PlaneMesh + 一张程序化占位贴花，
##   逐实例色 = 阵营色（所以一张图复用到任意将领）。只画将领、只读 world。
func _build_decal_layer() -> void:
	var dcell: float = palette.cell_size() * maxf(0.05, cfg.num("render.general_decal_size", 0.6))
	_decal_quad = PlaneMesh.new()
	_decal_quad.size = Vector2(dcell, dcell)
	# ⚠️ PlaneMesh 默认 `FACE_Y`（躺在 XZ 平面、法线朝 +Y）⇒ 它本来就是**平放**的。
	#    显式写出来免得以后有人"顺手"给它加个绕 X 轴的旋转（那会把它立起来、几乎看不见）。
	_decal_quad.orientation = PlaneMesh.FACE_Y
	var dmat := StandardMaterial3D.new()
	dmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dmat.vertex_color_use_as_albedo = true          # 逐实例色（阵营色）乘进贴图
	dmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	dmat.albedo_texture = SpriteRes.decal_texture()
	# ★ 半透明：整张贴花淡一点，别把地面 / 单位压住（config: render.general_decal_alpha）
	dmat.albedo_color = Color(1.0, 1.0, 1.0,
		clampf(cfg.num("render.general_decal_alpha", 0.5), 0.0, 1.0))
	_decal_mm = MultiMesh.new()
	_decal_mm.transform_format = MultiMesh.TRANSFORM_3D
	# ⚠️ `use_colors` 必须在 `instance_count` **之前**设（同 use_custom_data 那条约束）
	_decal_mm.use_colors = true
	_decal_mm.mesh = _decal_quad
	_decal_mm.instance_count = 64
	_decal_node = MultiMeshInstance3D.new()
	_decal_node.name = "GeneralDecals"
	_decal_node.multimesh = _decal_mm
	_decal_node.material_override = dmat
	add_child(_decal_node)


## ★★ 选中下标层：一块平放的小面片 + 「绿色空心圆」贴图；逐实例透明度走 INSTANCE_CUSTOM.r。
##   尺寸**与将领贴花一致**（用户口径：动效收到跟黄色底面贴花一样大）。
func _build_selection_layer() -> void:
	var cell: float = palette.cell_size() * maxf(0.05, cfg.num("render.general_decal_size", 0.6))
	_sel_quad = PlaneMesh.new()
	_sel_quad.size = Vector2(cell, cell)
	_sel_quad.orientation = PlaneMesh.FACE_Y
	_sel_layers = {}
	# ★ 三档各一层：圈色 = 本机视角下的己 / 友 / 敌（见 view/side_color.gd）。
	for rel in [SideColorRes.SELF, SideColorRes.ALLY, SideColorRes.ENEMY, SideColorRes.NEUTRAL]:
		var smat := ShaderMaterial.new()
		smat.shader = SELECTION_RING_SHADER
		smat.set_shader_parameter("albedo_tex", SpriteRes.selection_ring_texture())
		smat.set_shader_parameter("ring_color", _selection_ring_color(String(rel)))
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		# ⚠️ `use_custom_data` 必须在 `instance_count` **之前**设（同 unit_flash 那条约束）
		mm.use_custom_data = true
		mm.mesh = _sel_quad
		mm.instance_count = 256
		var node := MultiMeshInstance3D.new()
		node.name = "SelectionRings_" + String(rel)
		node.multimesh = mm
		node.material_override = smat
		add_child(node)
		_sel_layers[String(rel)] = {"mm": mm, "node": node}


## 选中圈的颜色：己方 / 友军 / 敌人三档。
## ★ 配置写坏 / 没配时退回旧的单色（`render.selection_ring_color`），不会画出品红。
func _selection_ring_color(rel: String) -> Color:
	if cfg == null:
		return Color(0.24, 0.86, 0.35)
	match rel:
		SideColorRes.SELF:
			return cfg.side_color_self
		SideColorRes.ALLY:
			return cfg.side_color_ally
		SideColorRes.ENEMY:
			return cfg.side_color_enemy
		SideColorRes.NEUTRAL:
			return cfg.side_color_neutral
	return ConfigRes.parse_color(cfg.str_val("render.selection_ring_color", "#3ddc5a"))


## 取（或创建）一个变体的批次。
##
## ★ 变体键 = `阵营|是否将领|兵种|是否选中|是否濒死`（见 `sync` 的拼法）；贴图按变体烘一张。
func _batch_for(key: String, faction: String, leader: bool, unit_type: String,
		selected: bool, downed: bool) -> Dictionary:
	var hit: Variant = _batches.get(key, null)
	if hit != null:
		return hit
	var col: Color = SideColorRes.color(cfg, world, faction, "main")
	# ★★ 描边色按上色口径分两档（见 config.gd 的 unit_sprite_tint_of）：
	#   · "art"     → 描边 = **阵营色**（保留原画，靠描边区分敌我）；
	#   · "faction" → 描边 = 深色（字本身已经填了阵营色，深描边才压得住地形）。
	var tint: String = cfg.unit_sprite_tint_of(unit_type)
	var outline: Color = col if tint == "art" else Color(0.05, 0.05, 0.07, 1.0)
	# ★★ 选中：**整圈描边换成金色**（用户口径：是替换，不是「阵营色外面再包一圈」）。
	var sel_col: Color = ConfigRes.parse_color(
		cfg.str_val("render.unit_select_outline_color", "#fff2b0"))
	# ★ 兵种素材（`unit.types.<id>.sprite`）；将领的描边更粗。
	#   素材缺失 / 没配 → `bake_asset` 内部退回程序化剪影（见 unit_sprite_3d.gd 的说明）。
	var tex: ImageTexture = SpriteRes.bake_asset(cfg.unit_sprite_of(unit_type), col, leader,
		outline, tint, selected, sel_col)

	# ★★ 材质按「是否濒死」二选一：
	#   · 正常：flash shader（写 ALPHA + scissor ⇒ **不透明管线**、深度正确）；
	#   · 濒死：downed shader（写 ALPHA、不写 scissor ⇒ **透明管线**、整体半透明）。
	#   两者的 billboard 代码逐字一致，所以同一位将领站起来/倒下的朝向不会变。
	var mat := ShaderMaterial.new()
	mat.set_shader_parameter("albedo_tex", tex)
	if downed:
		mat.shader = UNIT_DOWNED_SHADER
		mat.set_shader_parameter("downed_alpha", cfg.num("render.downed_alpha", 0.4))
	else:
		mat.shader = UNIT_FLASH_SHADER
		mat.set_shader_parameter("scissor_threshold", 0.35)
		mat.set_shader_parameter("flash_strength", cfg.num("render.hit_flash_alpha", 0.8))
	# ★★ 悬停填充：颜色 = **本批的阵营色**（`col` 已经是 SideColorRes 的口径；
	#   中立化单位走空阵营键 ⇒ 中性灰，与贴图 / 圈色自动一致）。
	#   ★ 两个 shader（正常 / 濒死）都要设，否则濒死将领在自己部队里悬停时不亮。
	mat.set_shader_parameter("hover_fill_color", col)
	mat.set_shader_parameter("hover_fill_alpha", _hover_fill_alpha)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _quad
	# ★⚠️ `use_custom_data` 必须在 `instance_count` **之前**设：
	#   实测（真渲染器）在 instance_count > 0 之后再打开它会报
	#   「Instance count must be 0 to toggle whether custom data is used」，
	#   于是自定义数据整批失效、闪白永远读不到。
	mm.use_custom_data = true
	mm.instance_count = 256

	var node := MultiMeshInstance3D.new()
	node.name = "Units_" + key
	node.multimesh = mm
	node.material_override = mat
	add_child(node)
	batches_created += 1
	# ★ `last_flash` / `last_uid` / `last_hover` 必须**逐批次、逐槽位**存：
	#   每个批次的 MultiMesh 各自一份自定义数据缓冲；共用一份全局缓存会在两个批次的
	#   同一个下标上互相覆盖，把闪白 / 填充**卡住**。`last_uid` 是「这一槽位现在是谁」，
	#   下标换人时必须整条重写（否则新单位继承上一任的填充）。
	var rec := {"node": node, "mm": mm, "faction": faction, "leader": leader,
		"last_flash": [], "last_uid": [], "last_hover": []}
	_batches[key] = rec
	return rec


## 每帧同步：把可见单位按变体分桶，逐桶写实例
##
## ★★ 两处**实测出来的**性能优化（1000 单位时 `_process` 占 36.6 ms）：
##   ① **位置没变就不重写 MultiMesh 实例**：待命单位占多数时（1000 个单位里
##      真正在动的可能只有几十个），省掉的是「每帧每单位一次
##      `set_instance_transform` + 一次 `to_world`」；
##   ② 分桶键用**预拼好的字符串**（`阵营|是否将领|兵种`）：每帧拼 1000 次
##      `"%s|%d" % [...]` 是纯浪费，改成按单位缓存（阵营不会变）。
##   ⚠️ 缓存必须**逐槽位**跟着实例下标走：实例下标每帧都可能变
##      （单位死亡 / 被迷雾挡住 → 桶里的顺序变了），所以缓存键要带下标。
##   ★ 判据：`bench_fps_3d.gd` 的 `_process` 分项 —— 优化前后对比。
var _last_pos: Array = []          # 下标 → 上一次写的世界位置（Vector3）
var _last_slot_key: Array = []     # 下标 → 上一次写的「桶键」（变了就必须重写）
## ★★ 2026.10.27：本帧**可见单位 id**（迷雾判据已经在这一趟里算过）。
##    overlay 的血条 / 小地图 / 其它视图直接查它，不再对 256 个单位各查一次迷雾。
##    `visibility_frame` 与 `world.frame_serial` 对齐；不相等（测试直接调 _draw）时
##    调用方退回自己的 `_unit_visible()`。
var _vis_ids: Dictionary = {}
var visibility_frame: int = -1


## 这个单位在**本帧**是不是可见的（只在 `visibility_frame == world.frame_serial` 时可信）。
func is_visible_this_frame(u) -> bool:
	return u != null and _vis_ids.has(u.id)


func sync(dt: float = 1.0 / 60.0) -> void:
	# ★★ 三张小表在**这一次遍历**里一起产出（见下面循环里的三条注释）。
	#    ⚠️ 必须在早退之前清空：否则早退那一帧会留下上一帧的旧值。
	_fade_marked.clear()
	_vis_generals.clear()
	_vis_sel.clear()
	_vis_ids.clear()
	visibility_frame = -1 if world == null else int(world.frame_serial)
	if world == null or palette == null or _quad == null:
		return
	shake_applied_last_frame = 0
	flash_written_last_frame = 0
	downed_count = 0
	hover_instance_count = 0
	var buckets: Dictionary = {}
	# ★★ 有没有「选中 / 正在做动效」的单位？没有就整段跳过每单位的 `String(id)` 与两次字典查询
	#    （1000 单位常态下选中为空 —— 这是每帧 1000 次字符串转换 + 2000 次查表）。
	var track_sel: bool = not (_selection_set.is_empty() and _sel_anim.is_empty())
	# ★★ 悬停同理：常态下没人被悬停 ⇒ 连进度表都不查。
	var track_hover: bool = not (_hover_set.is_empty() and _hover_anim.is_empty())
	# ★★ 变体键的记忆：同一支队伍里绝大多数相邻单位的「阵营/兵种/是否将领/是否濒死」都相同，
	#    记忆上一把键、不同才重新拼 —— 省掉每单位一次的 `%` 格式化（1000 单位常态下几乎全省）。
	var last_fac: String = ""
	var last_type: String = ""
	var last_leader: bool = false
	var last_sel: bool = false
	var last_downed: bool = false
	var last_neutral: bool = false
	var last_key: String = ""
	# ★★ 2026.10.27 移动端屏幕剔除：相机通常只看到地图一角，256 个单位里真正在屏幕内的
	#    可能只有十几个。只把**屏幕附近**的可见单位塞进 MultiMesh，省 GPU 顶点/填充与实例写回。
	#    ⚠️ 只在 mobile 生效：桌面 / 无头测试的 instance_count 断言保持原样。
	var cull_on: bool = OS.has_feature("mobile") and palette.cam != null
	var cull_rect := Rect2()
	if cull_on:
		var vp: Viewport = get_viewport()
		if vp != null:
			cull_rect = Rect2(Vector2.ZERO, vp.get_visible_rect().size).grow(256.0)
	for u in world.units:
		if not u.alive:
			continue
		# ★★ 战争迷雾：看不见的敌方单位**一个实例都不占**（判据只在 logic/fog.gd）
		if not _visible_to_me(u):
			continue
		if cull_on and not cull_rect.has_point(palette.to_px(_render_pos(u))):
			continue
		_vis_ids[u.id] = true
		# ★★ 单次遍历的副产品①：本帧可见单位的**所在格**（建筑层淡出用它）。
		#    ⚠️ 这里只写 1 格（每单位 1 次字典写）——「3×3 内有没有单位」由建筑层
		#       对**建筑自己的 3×3** 查表得出（建筑很少，比每单位写 9 格便宜得多）。
		_fade_marked[Vector2i(u.tx, u.ty)] = true
		var leader: bool = u.is_general()
		# ★★ 副产品②③：将领（贴花）与「选中 / 正在做选中动效」的单位（脚圈）。
		#    这两类都很少 —— 后面只遍历这两张小表，不再各扫一遍 `world.units` + 迷雾。
		if leader:
			_vis_generals.append(u)
		# ★★ 是否被选中：只在这一档才做 `String(u.id)`（选中为空时整段省掉，见 track_sel）。
		#    选中态会换一张**多一圈金描边**的贴图（变体键的第四段），所以也是分桶依据。
		var picked: bool = false
		if track_sel:
			var uid := String(u.id)
			picked = _selection_set.has(uid)
			if picked or _sel_anim.has(uid):
				_vis_sel.append(u)
		var downed: bool = u.is_downed()
		# ★★ 变体键 = 阵营 | 是否将领 | 兵种 | 是否选中 | 是否濒死：各自决定用哪张图 / 哪个材质。
		var key: String
		if u.faction == last_fac and u.unit_type == last_type \
				and leader == last_leader and picked == last_sel and downed == last_downed \
				and u.neutralized == last_neutral and last_key != "":
			key = last_key
		else:
			# ★ 中立化单位用**空阵营键**：SideColorRes 对 "" 返回中性灰（见 side_color.gd）。
			#   键里带上它，才不会被同一阵营的正常单位复用掉那张彩色贴图。
			var fac_key := "" if u.neutralized else String(u.faction)
			key = "%s|%d|%s|%d|%d" % [fac_key, 1 if leader else 0,
				String(u.unit_type), 1 if picked else 0, 1 if downed else 0]
			last_fac = u.faction
			last_type = u.unit_type
			last_leader = leader
			last_sel = picked
			last_downed = downed
			last_neutral = u.neutralized
			last_key = key
		var arr: Array = buckets.get(key, [])
		arr.append(u)
		buckets[key] = arr

	var half_h: float = _quad.size.y * 0.5
	var total: int = 0
	var used: int = 0
	var wrote: int = 0
	for key in buckets.keys():
		var arr: Array = buckets[key]
		# ⚠️ `String.split()` 返回的是无类型 `PackedStringArray` 的元素 ⇒
		#    写 `var parts := key.split("|")` 没问题，但 `String(parts[0])` 之后的
		#    `var rec := _batch_for(...)` **不能**用 `:=`（返回值推不出类型）。
		#    本轮第四次踩同类坑：凡是无类型容器 / 无类型参数参与，都要显式标类型。
		var parts: PackedStringArray = key.split("|")
		var rec: Dictionary = _batch_for(key, String(parts[0]), int(parts[1]) == 1,
			String(parts[2]), int(parts[3]) == 1, int(parts[4]) == 1)
		var mm: MultiMesh = rec["mm"]
		var batch_downed: bool = int(parts[4]) == 1
		if mm.instance_count < arr.size():
			mm.instance_count = maxi(arr.size(), mm.instance_count * 2)
		for i in arr.size():
			var u = arr[i]
			if batch_downed:
				downed_count += 1
			var w: Vector3 = palette.to_world(_render_pos(u))
			# ★ 受击左右振动（纯表现）：X 方向一个小位移，随 hit_flash 衰减
			if u.hit_flash > 0.0:
				w.x += HitFxRes.shake_tiles(u.hit_flash, _hit_amp, _hit_freq) * _cell
				shake_applied_last_frame += 1
			# 立牌原点在**中心** ⇒ 抬到「底边贴地」
			w.y = half_h
			# ★ 优化①：位置与所在批次都没变 ⇒ **跳过这次写入**
			#   （`set_instance_transform` 要走引擎调用，1000 次/帧是实打实的开销）
			var cached_pos: Variant = _last_pos[i] if i < _last_pos.size() else null
			var cached_key: Variant = _last_slot_key[i] if i < _last_slot_key.size() else null
			if cached_key == null or String(cached_key) != key or cached_pos == null \
					or (cached_pos as Vector3) != w:
				mm.set_instance_transform(i, Transform3D(Basis(), w))
				_slot_set(i, w, key)
				wrote += 1
			# ★★ 逐实例自定义数据：`.r` = 受击闪白，`.g` = 悬停填充进度。
			#   ★★ 脏检查必须**带上「这个槽位上现在是哪个单位」**：
			#     MultiMesh 的自定义数据是按**实例下标**存的，而下标每帧都可能换人
			#     （选中态要换批次 / 阵亡 / 被迷雾挡住 / 新兵入列）。只给「当前悬停候选」
			#     写值的话，新占位的单位会**继承上一任留下的填充** ——
			#     实测症状（用户报的 bug）：取消选中一支部队后，该队突然整片变蓝
			#     （蓝 = 自己方阵营色），因为那几个下标上还留着框选预览写的 1。
			#   ★ 单位没换槽、且三个值都没变时才跳过写入（省引擎调用）。
			var flash: float = clampf(u.hit_flash, 0.0, 1.0)
			var hov: float = _hover_tick(u.id, dt) if track_hover else 0.0
			var lf: Array = rec["last_flash"]
			var lu: Array = rec["last_uid"]
			var lh: Array = rec["last_hover"]
			var pf: Variant = lf[i] if i < lf.size() else null
			var pu: Variant = lu[i] if i < lu.size() else null
			var ph: Variant = lh[i] if i < lh.size() else null
			var same_uid: bool = pu != null and pu == u.id
			# 诊断按「现在带着填充的实例数」算，与有没有触发写入无关
			if hov > 0.0:
				hover_instance_count += 1
			if not same_uid or pf == null or float(pf) != flash \
					or ph == null or float(ph) != hov:
				mm.set_instance_custom_data(i, Color(flash, hov, 0.0, 0.0))
				while lu.size() <= i:
					lf.append(null)
					lu.append(null)
					lh.append(null)
				lu[i] = u.id
				lf[i] = flash
				lh[i] = hov
				if flash > 0.0:
					flash_written_last_frame += 1
		mm.visible_instance_count = arr.size()
		(rec["node"] as MultiMeshInstance3D).visible = true
		total += arr.size()
		used += 1
	# 没有实例的批次要隐藏（否则残留上一帧的单位）
	for key in _batches.keys():
		if not buckets.has(key):
			var rec: Dictionary = _batches[key]
			(rec["mm"] as MultiMesh).visible_instance_count = 0
			(rec["node"] as MultiMeshInstance3D).visible = false
	instance_count = total
	visible_count = total
	mesh_batch_count = used
	instance_writes_last_frame = wrote
	_sync_decals(_vis_generals)
	_sync_selection_rings(_vis_sel, dt)


## ★★ 推进一个单位的悬停填充进度（0..1）：目标 = 它在 `_hover_set` 里 ? 1 : 0。
##
## ★ 与选中圈同一套「反向播放」：离开时从 1 退到 0，退完就删掉这一项（进度表不会无限长）。
## ★ 只有「悬停集合非空 / 还有动效在跑」时才会被调用（见 `sync` 的 `track_hover`）。
## ⚠️ 进度是**按单位 id** 算的；写进 MultiMesh 时要连「这个槽位上是谁」一起做脏检查，
##   否则换人占位会继承上一任的填充值（见桶循环里那段注释）。
func _hover_tick(uid: String, dt: float) -> float:
	var want: float = 1.0 if _hover_set.has(uid) else 0.0
	var cur: float = float(_hover_anim.get(uid, 0.0))
	if cur == want:
		return cur
	var p: float = want
	if _hover_sec > 0.0:
		p = move_toward(cur, want, dt / _hover_sec)
	if p <= 0.0001 and want <= 0.0:
		_hover_anim.erase(uid)
		return 0.0
	_hover_anim[uid] = p
	return p


## ★★ 测试用：某个单位**当前槽位**上最后写进 MultiMesh 的自定义数据
##   （`.r` = 受击闪白，`.g` = 悬停填充进度）。
##
## ★ 为什么不直接读 `MultiMesh.get_instance_custom_data`：实测（Godot 4.7 + 无头）
##   它**读不回**刚写进去的值（同 `get_instance_transform`，见 pitfalls）。这里读的是
##   我们自己的写入缓存 —— 它和真正写进缓冲的是同一份，所以能钉住「槽位换人时必须重写」
##   这条判据。
## @return `(r, g)`；`r < 0` = 这一帧没有这个单位的槽位（不可见 / 没画出来）
func last_custom_for(unit_id: String) -> Color:
	for rec in _batches.values():
		var mm: MultiMesh = rec["mm"]
		var lu: Array = rec["last_uid"]
		var lf: Array = rec["last_flash"]
		var lh: Array = rec["last_hover"]
		for i in mm.visible_instance_count:
			if i < lu.size() and String(lu[i]) == unit_id:
				return Color(float(lf[i]), float(lh[i]), 0.0, 0.0)
	return Color(-1.0, -1.0, 0.0, 0.0)


## 将领脚下的贴花：把每个**可见将领**摆一块平放的小面片（逐实例色 = 阵营色）。
##
## ★ 将领很少（个位数）⇒ 直接每帧重填，不需要脏检查。
## ★ 面片是 `PlaneMesh.FACE_Y`：本来就躺在 XZ 平面上 ⇒ **变换用单位基**（不旋转）。
## ★★ 入参 `units_list` 由 `sync()` 的单次遍历顺带收集（只含「活着 + 可见 + 是将领」），
##    这里不再对 `world.units` 扫一遍、也不再做迷雾查询。
func _sync_decals(units_list: Array) -> void:
	decal_count = 0
	if _decal_node == null or _decal_mm == null or world == null or palette == null:
		return
	if _decal_mm.instance_count < units_list.size():
		_decal_mm.instance_count = maxi(units_list.size(), _decal_mm.instance_count * 2)
	var i: int = 0
	for u in units_list:
		var w: Vector3 = palette.to_world(_render_pos(u))
		w.y = 1.0                       # 贴在地面上方一点点（避免与地面 z-fighting）
		_decal_mm.set_instance_transform(i, Transform3D(Basis(), w))
		_decal_mm.set_instance_color(i, SideColorRes.color(cfg, world, String(u.faction), "main"))
		i += 1
	decal_count = i
	_decal_mm.visible_instance_count = i
	_decal_node.visible = i > 0


## ★★ 选中下标：被选中单位脚下的**绿色空心圆**，带「出现 / 收起」动效。
##
## 每个单位的进度 `p ∈ [0,1]` 朝目标（选中 = 1，未选中 = 0）按 `1/_sel_sec` 每秒推进：
##   · 尺寸 = `lerp(scale_from, 1.0, p)` —— 由 150% 收到 100%（= 将领黄色贴花那个大小）；
##   · 不透明度 = `_sel_alpha * p` —— 由 0 升到 80%。
## 取消选中时目标变 0，同一段插值就往回放（**反向动效**）；收到 0 就把这一项清掉。
##
## ★★ 入参 `units_list` 由 `sync()` 的单次遍历顺带收集（只含「活着 + 可见 + 被选中/正在做动效」），
##    这里不再对 `world.units` 扫一遍、也不再做迷雾查询。
func _sync_selection_rings(units_list: Array, dt: float) -> void:
	selection_ring_count = 0
	selection_scale_last = 0.0
	selection_alpha_last = 0.0
	if _sel_layers.is_empty() or world == null or palette == null:
		return
	var rate: float = 1.0 / _sel_sec
	# 先清掉已经不在世界里的单位（阵亡 / 换局），免得进度表无限长大
	var stale: Array = []
	for id in _sel_anim.keys():
		if world.unit_by_id(String(id)) == null:
			stale.append(id)
	for id in stale:
		_sel_anim.erase(id)

	# 每一帧把三层的写入下标各自清零（最后统一写 visible_instance_count）
	var counts: Dictionary = {}
	for rel in _sel_layers.keys():
		counts[String(rel)] = 0
	for u in units_list:
		var id := String(u.id)
		var want: float = 1.0 if _selection_set.has(id) else 0.0
		var p: float = float(_sel_anim.get(id, 0.0))
		if p < want:
			p = minf(want, p + rate * dt)
		elif p > want:
			p = maxf(want, p - rate * dt)
		if p <= 0.0001:
			_sel_anim.erase(id)
			continue
		_sel_anim[id] = p
		# ★ 按「本机视角」分桶：己方 / 友军 / 敌人各一层（圈色不同）
		var rel := SideColorRes.NEUTRAL if u.neutralized \
			else SideColorRes.relation(world, String(u.faction))
		if not _sel_layers.has(rel):
			rel = SideColorRes.ENEMY
		var layer: Dictionary = _sel_layers[rel]
		var mm: MultiMesh = layer["mm"]
		var i: int = int(counts[rel])
		if mm.instance_count <= i:
			mm.instance_count = maxi(i + 1, mm.instance_count * 2)
		var w: Vector3 = palette.to_world(_render_pos(u))
		w.y = 1.0
		var s: float = lerpf(_sel_scale_from, 1.0, p)
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(s, 1.0, s)), w))
		mm.set_instance_custom_data(i, Color(_sel_alpha * p, 0.0, 0.0, 0.0))
		if selection_ring_count == 0:
			selection_scale_last = s
			selection_alpha_last = _sel_alpha * p
		counts[rel] = i + 1
		selection_ring_count += 1
	for rel2 in _sel_layers.keys():
		var layer2: Dictionary = _sel_layers[rel2]
		var n: int = int(counts.get(String(rel2), 0))
		(layer2["mm"] as MultiMesh).visible_instance_count = n
		(layer2["node"] as MultiMeshInstance3D).visible = n > 0


## 写一槽的缓存（下标越界时按需扩容）
func _slot_set(i: int, w: Vector3, key: String) -> void:
	while _last_pos.size() <= i:
		_last_pos.append(null)
		_last_slot_key.append(null)
	_last_pos[i] = w
	_last_slot_key[i] = key


func _visible_to_me(u) -> bool:
	if world == null or world.fog == null or cfg == null:
		return true
	if not cfg.fog_enabled:
		return true
	# ★★ 2026.10.27：己方单位**永远可见** —— 不走迷雾查表（dscj 256 单位里约一半是自己 /
	#    守军，省掉的是每帧几百次 `is_revealed` + `same_side` + 格查表）。
	if String(u.faction) == String(world.my_faction):
		return true
	return world.fog.unit_visible(world.my_faction, u)


## 一个单位立牌在屏幕上的宽度（像素）——覆盖层的选中圈 / 血条用它对齐
##
## ★ 透视下这个值**随位置变化**（近大远小）⇒ 每帧按单位位置现算，
##   绝不要缓存成「一格 = 多少像素」（那正是老 2D 版会错的地方）。
func quad_screen_width(u) -> float:
	if palette == null:
		return 0.0
	var rp: Vector2 = _render_pos(u)
	var a: Vector2 = palette.to_px(rp + Vector2(-QUAD_W * 0.5, 0.0))
	var b: Vector2 = palette.to_px(rp + Vector2(QUAD_W * 0.5, 0.0))
	return a.distance_to(b)


func quad_screen_height(u) -> float:
	return quad_screen_width(u) * QUAD_H_RATIO


## ★★ 立牌在屏幕上的**宽与高**，一次算完：宽要 2 次投影，高只是按比例。
##   覆盖层画血条用它 —— 先调 width 再调 height 的话，height 会把 width 再投一遍
##   （每单位多 2 次 `to_px`，1000 单位就是每帧多 2000 次）。
func quad_screen_size(u) -> Vector2:
	var w: float = quad_screen_width(u)
	return Vector2(w, w * QUAD_H_RATIO)


## 立牌**头顶**在屏幕上的位置（覆盖层放血条 / 字用）
func head_screen_pos(u) -> Vector2:
	if palette == null or palette.cam == null:
		return Vector2.ZERO
	var w: Vector3 = palette.to_world(_render_pos(u))
	w.y = _quad.size.y
	return palette.cam.unproject_position(w)


## 这个单位**这一帧该画在哪**（格）——房主 / 单机 = `u.pos`；客机 = 两条快照之间插值。
##
## ★★ 2026.10.27：视图层一律走这一个入口，不要直接读 `u.pos` ——
##    否则立牌（插值）与血条 / 选中圈（原始 pos）会错开，9Hz 快照下肉眼可见。
func _render_pos(u) -> Vector2:
	if world != null and world.has_method("render_pos_of"):
		return world.render_pos_of(u)
	return u.pos


## 公开入口：覆盖层（血条 / 选中圈 / 名牌）必须与立牌用**同一个**位置。
func render_pos_of(u) -> Vector2:
	return _render_pos(u)


## 选中集合（`game_scene3d` 每帧把 `_selected_ids()` 喂进来）。
##
## ★★ 3D 版据此画**脚下的绿色空心圆贴花**（见 `_sync_selection_rings`）——带出现/收起动效。
##   ⚠️ 这个方法**必须有**：`game_scene3d` 每帧调用它；缺了会抛 `Nonexistent function`
##   并**中断整个 `_process`**（实测过，见 pitfalls）。
var selected_ids: Array = []


func set_selection(ids: Array) -> void:
	selected_ids = ids
	_selection_set = {}
	for id in ids:
		_selection_set[String(id)] = true


## ★★ 悬停填充：`game_scene3d` 每帧把「要填色的单位 id」喂进来
##   （己方 = 整支部队；敌 / 友 = 单个）。手机端由 game_scene 直接喂空表。
##
## ★ 填充是**纯表现**：只改 shader 的混色量，不改贴图、不加批次、不进快照。
## ⚠️ 这个方法**必须有**：缺了会抛 `Nonexistent function` 并中断整个 `_process`（同 set_selection）。
func set_hover(ids: Array) -> void:
	# ★★ 2026.10.27（性能）：**手机端这条每帧都会以空表调用**（触摸端没有悬停），
	#   全空的时候直接返回 —— 否则每帧白建一个空字典（90Hz 下每秒 90 次分配）。
	if ids.is_empty() and _hover_set.is_empty() and _hover_anim.is_empty():
		return
	_hover_set = {}
	for id in ids:
		_hover_set[String(id)] = true
	# 清掉已经不在世界里的（阵亡 / 换局）：悬停集合变化时才做，而且只有 fade-out 尾巴上
	# 那十几个 id —— 不做的话「悬停中被击杀」会留一条永远到不了 0 的进度。
	if world == null or _hover_anim.is_empty():
		return
	for id in _hover_anim.keys():
		if _hover_set.has(String(id)):
			continue
		if world.unit_by_id(String(id)) == null:
			_hover_anim.erase(id)


## ★★ 「压扁档的补偿计数」在 3D 下**恒为 0**（保留是为了接口不破）。
##
## 为什么留着：`test_view` 里有一条按名字读它的断言。3D 下没有「压扁」这件事
## （世界是 y = 0 的真实平面、投影交给引擎），所以补偿次数必然是 0。
## ⚠️ 删掉它会抛 `Invalid access to property` 并**中断整段**（实测），
##    那比留一个恒为 0 的字段危险得多 —— 静默少跑断言比多一个无害字段糟。
var comp_group_count: int = 0