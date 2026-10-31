## building_view_3d.gd —— 3D 建筑：**一个 MultiMeshInstance3D 画一批**（网格按类型：有模型用模型，否则单位方块）
##
## ★★ 网格从哪来（本版）：
##   · **城墙 / 箭塔 / 大本营 / 区划中心用 Blender 导出的模型**（`assets/models/*_lowpoly.glb`，
##     路径表 = `BUILDING_MODELS`，见文件末尾 `_uses_model` / `_load_building_mesh`）——
##     模型按「1 单位 = 1 格、底边在 y = 0」建好，落地时**统一缩放格宽 × body_scale**、
##     高度由模型自己决定（不走 `_height_of`）；
##   · 其余类型仍是**单位立方体 `BoxMesh`**，靠**逐实例的非等比缩放**
##     `(格宽 × body_scale, 格宽 × 视觉高度, 格宽 × body_scale)` 表达尺寸差异。
##   两者都是「一批一个 MultiMesh ⇒ 每批 1 次 draw call」。
##   ★ 有模型的类型**只有模型这一条路**：不再有「素材缺失就退回方块」的兜底 ——
##     那会把「模型根本没加载进来」这个真问题，藏成一个看不出差别的立方体。
##     模型加载不到时 `_load_building_mesh` 会 `push_error`，而不是悄悄画方块。
##
## ★★ 高度从哪来（关键：`logic/` 一格不改）：
##   · 方块类型：**纯表现**的常量，写在 `config.json` 的 `render.building_height.<type>`，
##     缺省 1.0 格（见 `_height_of`：箭塔 1.15 / 大本营 1.35 …）；
##   · 模型类型（七种建筑 + 大本营 / 区划中心）：由模型自带 —— 木墙 0.80、石墙 0.88、
##     哨塔 1.16、警戒塔 1.57、粮田 0.33、房屋 0.91、矿脉 0.63、大本营 1.42、旗子 0.86 格高。
##   它**不参与**寻路 / 碰撞 / 攻击（那些都读 `logic/building.gd`
##   的 `body_scale`，仍然是一格里的平面块）。
##   ★ 这条边界很重要：视觉上立起来 ≠ 逻辑上有高度。
##
## ★★ 有单位靠近 ⇒ 整栋淡出（见文件末尾 `_fade_marked_tiles` 与 building_flash.gdshader）：
##   以建筑所在格为中心的 3x3 内有**可见单位**时，整栋淡到 `render.building_fade_alpha`，
##   这样单位不会被建筑挡住。★ 该 shader 写了 ALPHA（走透明管线），靠 `depth_draw_always`
##   强制写深度，建筑之间的前后遮挡才不会按「谁后画谁在上」乱掉。
##   ★★ **被悬停时淡出会收回**（0.1s），**被选中时也直接收回**（即时）：
##     见 building_flash.gdshader 的 `(1 - max(hov, sel))`。
##
## ★★ 悬停 / 选中高亮：
##   · 本体：纯阵营色填充 + 淡出收回（`INSTANCE_CUSTOM.b` / `.a`）；
##   · 外轮廓：反向壳 pass（building_hover_outline.gdshader）——悬停白色 / 选中金色；
##   · **所有折边**：building_edge_ribbon.gd 把模型每条折边展开成面向相机的粗线带，
##     再用 building_edge_outline.gdshader 画白 / 金（不画平面内的三角化对角线）。
##   三种颜色 / 进度完全同源：悬停白色优先，选中金色次之。
##
## ★ 不投影阴影（用户口径）。
extends Node3D

const ConfigRes = preload("res://logic/config.gd")
const PaletteRes = preload("res://view/palette.gd")
const HitFxRes = preload("res://view/hit_fx.gd")
## ★★ 局内「敌 / 友 / 己」三色（本轮新增；判据只在 view/side_color.gd）
const SideColorRes = preload("res://view/side_color.gd")
## ★★ 「3×3 内有可见单位」的按格位图（见 view/fade_stamp.gd）：
##    原来对每一栋建筑各做 9 次 `Dictionary.has(Vector2i)`，旗面那一趟还要再来一遍。
const FadeStampRes = preload("res://view/fade_stamp.gd")
## ★ 建筑材质：逐像素受击闪白（自定义 shader，见文件）
const BUILDING_FLASH_SHADER = preload("res://view/building_flash.gdshader")
## ★★ 外轮廓白描边 / 选中金边：反向壳 pass，挂在材质 `next_pass` 上
const BUILDING_OUTLINE_SHADER = preload("res://view/building_hover_outline.gdshader")
## ★★ 所有折边的粗线带：由 `building_edge_ribbon.gd` 从建筑网格生成
const BuildingEdgeRibbonRes = preload("res://view/building_edge_ribbon.gd")
const BUILDING_EDGE_SHADER = preload("res://view/building_edge_outline.gdshader")
## ★ 建造中的头顶进度条（3D billboard 批次，进度走每实例自定义数据）
const BAR_SHADER = preload("res://view/building_construction_bar.gdshader")

## ★★ 有模型的建筑类型 → 模型路径（Blender 导出；**1 单位 = 1 格**、底边在 y = 0、铺满整格）。
##   游戏里按「格宽 × body_scale」**统一缩放** ⇒ 落地高度 = 模型高 × body_scale：
##     · 木墙（1.0）/ 石墙（1.0）：128 × 128 × 102.4 / 112.6（模型高 0.80 / 0.88，满格 0.98 见方）；
##     · 哨塔 / 警戒塔 / 大本营（0.6）：76.8 × 76.8 × 149 / 200.4 / 182.4（模型高 1.94 / 2.61 / 2.37）；
##     · 粮田 / 房屋（0.6）、矿脉（0.55）：42.2 / 116 / 80.3（模型高 0.55 / 1.51 / 1.14）；
##   · 区划中心（body_scale 1.0，**旗杆**）：128 × …（模型高 1.10 ⇒ 落地 140.8）。
##   ★ 这些类型一律用各自的模型；加载不到由 `_load_building_mesh` 报错，**不退回方块**。
##   ★★ 这张表是**唯一**的「哪些类型走模型」的判据（`_uses_model` / `_mesh_for` 都读它）。
##   ★★ 2026.10.31：七种建筑全部换成 Blender 低模（木墙 / 石墙 / 哨塔 / 警戒塔 / 粮田 / 房屋 / 矿脉）。
##     · 两种墙是**四向对称**的 —— 墙会被摆进环里，没有旋转，模型有正反面就会有一半朝里；
##     · 两面墙都**占满整格**（0.98 见方），与「整格阻塞」的语义对齐；
##     · 模型自带顶点色（GLB 的 COLOR_0）：rgb = 材质原色，a = 阵营色遮罩
##       （1 = 旗 / 屋顶 / 廊柱 / 栅栏这类显眼件吃阵营色，0 = 保留原色）。
const BUILDING_MODELS := {
	"wall": "res://assets/models/wall_lowpoly.glb",
	"tower": "res://assets/models/tower_lowpoly.glb",
	"stone_wall": "res://assets/models/stone_wall_lowpoly.glb",
	"watch_tower": "res://assets/models/watch_tower_lowpoly.glb",
	"base": "res://assets/models/base_lowpoly.glb",
	"zone_center": "res://assets/models/zone_center_lowpoly.glb",
	"farm": "res://assets/models/farm_lowpoly.glb",
	"house": "res://assets/models/house_lowpoly.glb",
	"mine": "res://assets/models/mine_lowpoly.glb",
}

## ★★ 可动部件：类型 → 模型路径。这些网格**不随建筑本体固定**，而是由 `_sync_flags()` 按
##   游戏状态**逐实例摆**（目前只有区划中心的**旗面**：占领时沿旗杆上升）。
##   ★ 旗面模型按「底边在 y = 0」建好 ⇒ 把它整体平移到哪，底边就落在哪。
const BUILDING_MOVING_MODELS := {
	"zone_center": "res://assets/models/zone_center_flag_lowpoly.glb",
}

## ★★ 「离地抬起量」（世界单位）：所有建筑/旗子都按它贴地（见 `_transform_of` / `_flag_transform`）。
const GROUND_LIFT := 0.6

## ★★ 区划中心旗子的动画几何（**必须与两个模型对得上**；1 单位 = 1 格）。
##   · 旗杆模型 zone_center_lowpoly.glb：杆身 z ∈ [ZC_POLE_BOTTOM, ZC_POLE_TOP]；
##   · 旗面模型 zone_center_flag_lowpoly.glb：底边在 z = 0、高 ZC_CLOTH_H。
##   旗面**底边**随占领进度从杆底线性升到「杆顶 − 旗高」（升到顶时旗面顶边正好到杆顶）。
const ZC_POLE_BOTTOM := 0.12
const ZC_POLE_TOP := 1.02
const ZC_CLOTH_H := 0.32

var cfg: ConfigRes = null
var world = null
var palette = null

var _box: BoxMesh = null
## 类型 → 合并后的模型网格（加载不到 = null ⇒ **不画**，由 `_load_building_mesh` 报错；**不退回方块**）
var _model_meshes: Dictionary = {}
## 可动部件：类型 → 网格（同上，加载不到 = null ⇒ 不画）
var _moving_meshes: Dictionary = {}
## 变体键（"阵营|类型"）→ {node, mm, capacity}
var _batches: Dictionary = {}
## ★★ 旗面批：**颜色**键 → {node, mm}（不同占领方颜色不同，所以按颜色分桶）
var _flag_batches: Dictionary = {}
var _color_cache: Dictionary = {}

## 诊断（只有测试读它）
var instance_count: int = 0
var mesh_batch_count: int = 0
var batches_created: int = 0
## ★ 本帧有多少栋建筑被施加了「受击左右振动」（诊断，测试读它）
var shake_applied_last_frame: int = 0
## ★ 本帧有多少栋建筑写了受击闪白（诊断，测试读它）
var flash_written_last_frame: int = 0
## ★ 本帧有多少栋建筑被「单位靠近」淡出（诊断，测试读它）
var faded_last_frame: int = 0
## ★★ 本帧画了几面旗（区划中心占领动画；诊断，测试读它）
var flag_instance_count: int = 0
## ★ 本帧有几栋建筑带着悬停填充（诊断，测试读它）
var hovered_last_frame: int = 0
## ★ 本帧有几栋建筑带着选中金边（诊断，测试读它）
var selected_last_frame: int = 0
## ★ 本帧画了几个「所有折边」线带实例（建筑 + 旗面；诊断，测试读它）
var edge_instance_count: int = 0

## ★★ 悬停 / 选中高亮（见 config.json 的 `render._hover_fill_comment`）：
##   · `_hover_tiles` = 要填充白边 + 纯阵营色的**地块集合**（悬停 / 拖框预览）；
##   · `_hover_anim`  = 地块 → 0..1 的淡入淡出进度（建筑不会移动 ⇒ 用格坐标当键）；
##   · 填充走**逐实例自定义数据** `INSTANCE_CUSTOM.b`（`.r` 闪白、`.g` 淡出），
##     填充色是**每批次一个 uniform**（建筑批次 = 一个 owner ⇒ 同批必然同色）。
##   · `_selected_tiles` = 选中建筑的地块（金色描边，走 `.a`；即时开关）。
var _hover_tiles: Dictionary = {}
var _hover_anim: Dictionary = {}
var _selected_tiles: Dictionary = {}
var _hover_fill_alpha: float = 1.0
var _hover_sec: float = 0.1
## 外轮廓 / 选中金边的颜色 + 反向壳放大倍率（config）
var _hover_outline: Color = Color.WHITE
var _select_outline: Color = Color(0.949, 0.710, 0.267, 1.0)
var _outline_scale: float = 1.02
## 所有折边的粗线带（建筑本体 / 旗面各一套网格；类型 → 网格 / 层）
var _edge_meshes: Dictionary = {}
var _flag_edge_meshes: Dictionary = {}
var _edge_layers: Dictionary = {}
var _flag_edge_layers: Dictionary = {}
var _edge_mat: ShaderMaterial = null
var _edge_width: float = 0.035
var _edge_crease_deg: float = 8.0
## 受击振动参数（setup 缓存）
var _cell: float = 128.0
var _hit_amp: float = 0.06
var _hit_freq: float = 26.0


func setup(p_cfg: ConfigRes, p_world, p_palette) -> void:
	cfg = p_cfg
	world = p_world
	palette = p_palette
	# 单位立方体（1×1×1，中心在原点）——靠逐实例缩放表达各建筑的真实尺寸
	_box = BoxMesh.new()
	_box.size = Vector3.ONE
	_cell = palette.cell_size()
	_hit_amp = cfg.num("render.hit_shake_cells", 0.06)
	_hit_freq = cfg.num("render.hit_shake_freq", 26.0)
	_model_meshes = {}
	for t in BUILDING_MODELS:
		_model_meshes[t] = _load_building_mesh(BUILDING_MODELS[t])
	_moving_meshes = {}
	for t in BUILDING_MOVING_MODELS:
		_moving_meshes[t] = _load_building_mesh(BUILDING_MOVING_MODELS[t])
	# ★★ 悬停 / 选中样式参数（每帧要用 ⇒ setup 缓存；0 = 立即切换）
	_hover_fill_alpha = clampf(cfg.num("render.hover_fill_alpha", 1.0), 0.0, 1.0)
	_hover_sec = maxf(0.0, cfg.num("render.hover_fill_sec", 0.1))
	_hover_outline = cfg.hover_outline_color
	# ★ 建筑选中描边与单位选中**同一个金**（用户口径：和单位被选中时一样）。
	_select_outline = ConfigRes.parse_color(
		cfg.str_val("render.unit_select_outline_color", "#fff2b0"))
	_outline_scale = maxf(1.0, cfg.building_outline_scale)
	# ★★ 所有折边的粗线带：线宽按网格最大边长缩放并夹住（旗面不会糊成一片）。
	_edge_width = maxf(0.005, cfg.num("render.building_edge_width", 0.035))
	_edge_crease_deg = clampf(cfg.num("render.building_edge_crease_deg", 8.0), 0.0, 179.0)
	_edge_mat = ShaderMaterial.new()
	_edge_mat.shader = BUILDING_EDGE_SHADER
	_edge_mat.set_shader_parameter("hover_color", _hover_outline)
	_edge_mat.set_shader_parameter("select_color", _select_outline)
	# ★★ 折边层必须**晚于建筑本体**绘制（这是「上半地图有线、下半只剩外轮廓」的真因）：
	#   本体与折边都在透明管线（都写 ALPHA），透明对象按**对象包围盒的距离**排序 ——
	#   本体批次覆盖全地图同类建筑、折边批次的包围盒只围着当前选中/悬停的那几栋，
	#   两者的 AABB 中心不同 ⇒ 建筑在地图上半 / 下半时先后顺序会翻。
	#   本体后画时它（ALPHA≈1）会把先画的线带整片盖掉，只剩本体外层的反向壳描边。
	#   `render_priority` 比距离排序优先 ⇒ 折边永远在本体之后画；
	#   背面折边仍然靠深度测试被本体挡住（shader 里按真实视线抬 bias）。
	_edge_mat.render_priority = 1
	_edge_meshes = {}
	# ★★ 建造进度条：一个 billboard MultiMesh 画全部在建建筑（进度走每实例自定义数据）
	_bar_mesh = QuadMesh.new()
	_bar_mesh.size = Vector2(_cell * 0.52, _cell * 0.088)
	_bar_mat = ShaderMaterial.new()
	_bar_mat.shader = BAR_SHADER
	_bar_mm = MultiMesh.new()
	_bar_mm.transform_format = MultiMesh.TRANSFORM_3D
	# ⚠️ 同建筑本体：`use_custom_data` 必须在 `instance_count` **之前**设
	_bar_mm.use_custom_data = true
	_bar_mm.mesh = _bar_mesh
	_bar_mm.instance_count = BAR_CAPACITY
	_bar_node = MultiMeshInstance3D.new()
	_bar_node.name = "BuildProgressBars"
	_bar_node.multimesh = _bar_mm
	_bar_node.material_override = _bar_mat
	_bar_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_bar_node)
	for t in _model_meshes:
		_edge_meshes[t] = _build_edge_mesh(_model_meshes[t])
	_flag_edge_meshes = {}
	for t in _moving_meshes:
		_flag_edge_meshes[t] = _build_edge_mesh(_moving_meshes[t])
	_edge_layers = {}
	_flag_edge_layers = {}
	_hover_tiles = {}
	_hover_anim = {}
	_selected_tiles = {}


## ★★ 悬停填充：`game_scene3d` 每帧把「要填色的建筑格」喂进来（手机端喂空）。
##   · 鼠标悬停 = 那一格一栋；**拖框** = 框里那一批己方建筑（可多栋）。
##   `sync()` 之前调用；只改 shader 的混色量，不改贴图、不加批次、不进快照。
## @param tiles `Vector2i` 的地块数组（建筑不会移动 ⇒ 地块是稳定的键）
func set_hover(tiles: Array) -> void:
	_hover_tiles = {}
	for t in tiles:
		_hover_tiles[t as Vector2i] = true
	# 清掉已经不在世界里的（被打掉 / 换局）：只有 fade-out 尾巴上那几个键，
	# 不做的话「悬停中被拆掉」会留一条永远到不了 0 的进度。
	if world == null or _hover_anim.is_empty():
		return
	for key in _hover_anim.keys():
		if _hover_tiles.has(key):
			continue
		var t2: Vector2i = key
		var still = world.building_at(t2.x, t2.y)
		if still == null or not still.alive:
			_hover_anim.erase(key)


## ★★ 选中的建筑：`game_scene3d` 每帧把「要加金边的建筑格」喂进来。
##   · 己方框选 / 点选的建筑（`selected_buildings`，可多栋）；
##   · 选中的**区划中心**（`selected_zone` 反查到中心格）；
##   · 选中的**敌方建筑**（`selected_enemy` 且 kind == "building"）。
##   与单位选中同一个金色；悬停时白色优先（见 building_hover_outline.gdshader）。
func set_selected(tiles: Array) -> void:
	_selected_tiles = {}
	for t in tiles:
		_selected_tiles[t as Vector2i] = true


## 悬停填充色 = **纯阵营色**（不是 `_faction_or_type_color` 的暗化本体色；
## 否则悬停一堵暗色墙会像"没亮"）。
##
## ★★ 区划中心（owner 恒为空）不能直接取 `owner`：它的「阵营色」是**所属区划**的
##   归属色 —— 已占领 = 占领方主色、读条占领中 = 占领方主色、无主 = 中立灰。
##   这条口径与旗面完全同源（`zone_flag_state`），两处不会出现「旗是蓝的、悬停是灰的」。
## ★ 中立化（大本营被拆）的建筑也按中性灰，与本体色一致。
func _hover_color_of(b, owner: String) -> Color:
	if String(b.type) == "zone_center":
		var st: Dictionary = zone_flag_state(b)
		if float(st.get("progress", 0.0)) > 0.0:
			return st.get("color", cfg.side_color_neutral)
		return cfg.side_color_neutral
	if owner == "" or b.neutralized:
		return cfg.side_color_neutral
	return SideColorRes.color(cfg, world, owner, "main")


## 建筑在世界里的高度（格）——**纯表现**，缺省 1 格
##
## ★★ 2026.10.27（性能）：按**类型**缓存。原来每栋建筑每帧都做一次
##    `"render.building_height.%s" % t`（字符串格式化 + 配置查表）——
##    20 栋建筑就是每帧 20 次格式化。高度只由类型决定，类型一局内不变。
var _height_cache: Dictionary = {}


func _height_of(b) -> float:
	var t := String(b.type)
	var cached: Variant = _height_cache.get(t, null)
	if cached != null:
		return cached
	var h: float = cfg.num("render.building_height.%s" % t, 0.0)
	if h <= 0.0:
		# 没配就用「类型缺省表」：城墙矮、大本营最高
		match t:
			"wall", "stone_wall":
				h = 0.55
			"tower", "watch_tower":
				h = 1.15
			"base":
				h = 1.35
			"zone_center":
				h = 0.35
			# ★ 资源建筑：**兜底**数值。2026.10.31 起 farm / house / mine 也走模型
			#   （见 BUILDING_MODELS），这几档只在模型缺失时才有意义。
			"farm":
				h = 0.55
			"house":
				h = 0.9
			"mine":
				h = 1.3
			_:
				h = 1.0
	h = maxf(0.05, h)
	_height_cache[t] = h
	return h


## 外轮廓白描边 / 选中金边的 pass（挂在材质的 `next_pass` 上）。
## ★ 只靠 `INSTANCE_CUSTOM.b`（悬停）/ `.a`（选中）显隐 ⇒ 不新增本体批次。
func _outline_pass(mesh: Mesh) -> ShaderMaterial:
	var om := ShaderMaterial.new()
	om.shader = BUILDING_OUTLINE_SHADER
	om.set_shader_parameter("outline_scale", _outline_scale)
	om.set_shader_parameter("outline_color", _hover_outline)
	om.set_shader_parameter("select_color", _select_outline)
	# 绕网格 AABB 中心放大（模型原点在底边、旗面原点在左下角，绕中心才是四边都有边）。
	var pivot := Vector3.ZERO
	if mesh != null:
		pivot = mesh.get_aabb().get_center()
	om.set_shader_parameter("outline_pivot", pivot)
	return om


## 从一个建筑网格生成「所有折边」的线带网格。
## ★ 线宽按网格最大边长收窄（旗面 0.32 格 ≈ 0.016），不会被一圈粗边糊住。
## ★ 这里只写**中心线**；面向相机展开与向相机偏移在 shader 里按每实例真实视线算
##   （见 building_edge_ribbon.gd / building_edge_outline.gdshader 的文件头）。
func _build_edge_mesh(mesh: Mesh) -> Mesh:
	if mesh == null:
		return null
	var aabb: AABB = mesh.get_aabb()
	var max_extent: float = maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	var w: float = clampf(minf(_edge_width, max_extent * 0.05), 0.008, 0.035)
	return BuildingEdgeRibbonRes.build(mesh, w, _edge_crease_deg)


## 取（或创建）某个类型的「所有折边」MultiMesh 层。
## ★ 颜色是全局的（白 / 金），与 owner 无关 ⇒ 同一类型的所有建筑共用一个 draw call。
func _edge_layer_for(type: String, moving: bool) -> Dictionary:
	var cache: Dictionary = _flag_edge_layers if moving else _edge_layers
	var hit: Variant = cache.get(type, null)
	if hit != null:
		return hit
	var meshes: Dictionary = _flag_edge_meshes if moving else _edge_meshes
	var mesh: Mesh = meshes.get(type, null)
	if mesh == null and not moving:
		# 方块类建筑（farm / house / mine …）没有预载模型：从 `_box` 现建一份。
		mesh = _build_edge_mesh(_mesh_for(type))
		meshes[type] = mesh
	if mesh == null:
		return {}
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	# ⚠️ `use_custom_data` 必须在 `instance_count` 之前设（同 unit_view_3d 的说明）
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = 64
	var node := MultiMeshInstance3D.new()
	node.name = ("FlagEdges_" if moving else "BuildingEdges_") + type
	node.multimesh = mm
	node.material_override = _edge_mat
	add_child(node)
	var rec := {"node": node, "mm": mm}
	cache[type] = rec
	return rec


## 把这一帧的折边实例写进各类型的 MultiMesh。
## @param items 类型 → [{x: Transform3D, h: 悬停进度, s: 选中 0/1}]
func _sync_edge_layers(items: Dictionary, moving: bool) -> void:
	var cache: Dictionary = _flag_edge_layers if moving else _edge_layers
	for type in items.keys():
		var rec: Dictionary = _edge_layer_for(String(type), moving)
		if rec.is_empty():
			continue
		var list: Array = items[type]
		var mm: MultiMesh = rec["mm"]
		if mm.instance_count < list.size():
			mm.instance_count = maxi(list.size(), mm.instance_count * 2)
		for i in list.size():
			var it: Dictionary = list[i]
			mm.set_instance_transform(i, it["x"])
			# `.b` = 悬停进度（白），`.a` = 选中（金）；与本体 / 反向壳同一套通道。
			mm.set_instance_custom_data(i, Color(0.0, 0.0,
				float(it["h"]), float(it["s"])))
		mm.visible_instance_count = list.size()
		(rec["node"] as MultiMeshInstance3D).visible = true
		edge_instance_count += list.size()
	for type2 in cache.keys():
		if items.has(type2):
			continue
		var rec2: Dictionary = cache[type2]
		(rec2["mm"] as MultiMesh).visible_instance_count = 0
		(rec2["node"] as MultiMeshInstance3D).visible = false


func _batch_for(key: String, color: Color, type: String = "",
		hover_color: Color = Color.WHITE) -> Dictionary:
	var hit: Variant = _batches.get(key, null)
	if hit != null:
		return hit
	var mat := ShaderMaterial.new()
	mat.shader = BUILDING_FLASH_SHADER
	mat.set_shader_parameter("base_color", color)
	# ★★ 悬停填充：颜色 = **本批的纯阵营色**（不是暗化过的 `color`，见 `_hover_color_of`）
	mat.set_shader_parameter("hover_fill_color", hover_color)
	mat.set_shader_parameter("hover_fill_alpha", _hover_fill_alpha)
	# ★★ 外轮廓白边 / 选中金边：同一材质的第二个 pass（反向壳）
	mat.next_pass = _outline_pass(_mesh_for(type))
	mat.set_shader_parameter("flash_strength", cfg.num("render.hit_flash_alpha", 0.8))
	# ★ 有单位靠近时整栋淡到的不透明度（见 building_flash.gdshader 的 depth_draw_always 说明）
	mat.set_shader_parameter("fade_alpha", cfg.num("render.building_fade_alpha", 0.3))

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	# ★ 有模型的类型（城墙 / 箭塔 / 大本营 / 区划中心）用各自的模型网格；其余仍是单位方块（逐实例缩放表达尺寸）
	mm.mesh = _mesh_for(type)
	# ★⚠️ `use_custom_data` 必须在 `instance_count` **之前**设（见 unit_view_3d 的说明）
	mm.use_custom_data = true
	mm.instance_count = 64

	var node := MultiMeshInstance3D.new()
	node.name = "Buildings_" + key
	node.multimesh = mm
	node.material_override = mat
	add_child(node)
	batches_created += 1
	var rec := {"node": node, "mm": mm}
	_batches[key] = rec
	return rec


## 每帧同步（建筑很少，重建的代价可忽略；但仍按「阵营 + 类型 + 等级」分桶以保持合批）
func sync(dt: float = 1.0 / 60.0) -> void:
	if world == null or palette == null or _box == null:
		return
	shake_applied_last_frame = 0
	flash_written_last_frame = 0
	# ★ 建造动画 / 进度条要用本帧 dt（`_transform_of()` 的签名不动，改成读这个字段）
	_frame_dt = dt
	faded_last_frame = 0
	hovered_last_frame = 0
	selected_last_frame = 0
	flag_instance_count = 0
	edge_instance_count = 0
	# ★ 悬停淡入淡出每帧的推进量（`render.hover_fill_sec`；= 0 表示立即切换）
	var hover_step: float = 1.0 if _hover_sec <= 0.0 else dt / _hover_sec
	# ★ 先把「哪些格附近有可见单位」标出来（一次 O(单位数)），建筑逐栋查表即可
	var marked: Dictionary = _fade_marked_tiles()
	# ★★ 2026.10.28（性能）：把那张字典铺成位图**一次**，之后逐栋只做下标
	#   （见 `_fade_at` 与 `view/fade_stamp.gd`）。旗面那一趟复用同一张位图。
	var stamp: PackedByteArray = FadeStampRes.build(marked, int(world.map.cols), int(world.map.rows))
	var buckets: Dictionary = {}
	# 类型 → [{x, h, s}]：这一帧所有折边线带实例（与本体同一次遍历收集）
	var edge_items: Dictionary = {}
	# ★★ 同一批建筑在列表里通常挨在一起（玩家一口气拉的一排墙）⇒ 记住上一把键，
	#   只有 owner / type / 悬停色变了才重新拼字符串。
	var last_owner: String = ""
	var last_type: String = ""
	var last_suffix: String = ""
	var last_key: String = ""
	for b in world.building_list:
		if not b.alive:
			continue
		# ★★ 战争迷雾：看不见的敌方建筑**一个实例都不占**
		#    （判据只在 logic/fog.gd：己方 / 无主永远可见，敌方「见过就记住」）
		if not _visible_to_me(b):
			continue
		var owner_s := String(b.owner)
		var type_s := String(b.type)
		# ★★ 为什么键里要带**悬停色**：悬停填充色是每批次一个 uniform，而区划中心的
		#   owner 恒为空、填充色却跟着所属区划的归属走（蓝 / 黄 / 红 / 灰）。
		#   不并进键里的话，所有区划中心会共用「第一次建批时」那一个颜色。
		var suffix := ""
		if type_s == "zone_center":
			suffix = "|h" + _color_hex(_hover_color_of(b, owner_s))
		elif b.neutralized:
			suffix = "|hn"
		var key: String
		if last_key != "" and owner_s == last_owner and type_s == last_type \
				and suffix == last_suffix:
			key = last_key
		else:
			last_owner = owner_s
			last_type = type_s
			last_suffix = suffix
			key = "%s|%s%s" % [owner_s, type_s, suffix]
			last_key = key
		var arr: Array = buckets.get(key, [])
		arr.append(b)
		buckets[key] = arr

	var total: int = 0
	var used: int = 0
	for key in buckets.keys():
		var arr: Array = buckets[key]
		var b0 = arr[0]
		var owner := String(b0.owner)
		var col: Color = _faction_or_type_color(b0, owner)
		var type_s := String(b0.type)
		var rec: Dictionary = _batch_for(key, col, type_s, _hover_color_of(b0, owner))
		var mm: MultiMesh = rec["mm"]
		if mm.instance_count < arr.size():
			mm.instance_count = maxi(arr.size(), mm.instance_count * 2)
		for i in arr.size():
			var xform: Transform3D = _transform_of(arr[i])
			mm.set_instance_transform(i, xform)
			# ★ 受击闪白（.r）+ 靠近淡出（.g）+ 悬停填充（.b）+ 选中金边（.a）：
			#   逐实例自定义数据（建筑很少，直接每帧写，不做脏检查）。
			var flash: float = clampf(arr[i].hit_flash, 0.0, 1.0)
			var fade: float = 1.0 if _fade_at(stamp, arr[i]) else 0.0
			var tile := Vector2i(arr[i].tx, arr[i].ty)
			var wanted: bool = _hover_tiles.has(tile)
			var hov: float = move_toward(
				float(_hover_anim.get(tile, 0.0)), 1.0 if wanted else 0.0, hover_step)
			if hov <= 0.0001 and not wanted:
				_hover_anim.erase(tile)
				hov = 0.0
			else:
				_hover_anim[tile] = hov
			# ★ 选中金边：即时开关（与单位选中同一条手感），不做过场动画。
			var sel: float = 1.0 if _selected_tiles.has(tile) else 0.0
			mm.set_instance_custom_data(i, Color(flash, fade, hov, sel))
			if flash > 0.0:
				flash_written_last_frame += 1
			if fade > 0.0:
				faded_last_frame += 1
			if hov > 0.0:
				hovered_last_frame += 1
			if sel > 0.0:
				selected_last_frame += 1
			# ★ 折边线带：与本体同变换、同进度（hover/选中），另一层 MultiMesh 画。
			var elist: Array = edge_items.get(type_s, [])
			elist.append({"x": xform, "h": hov, "s": sel})
			edge_items[type_s] = elist
		mm.visible_instance_count = arr.size()
		(rec["node"] as MultiMeshInstance3D).visible = true
		total += arr.size()
		used += 1
	for key in _batches.keys():
		if not buckets.has(key):
			var rec2: Dictionary = _batches[key]
			(rec2["mm"] as MultiMesh).visible_instance_count = 0
			(rec2["node"] as MultiMeshInstance3D).visible = false
	instance_count = total
	mesh_batch_count = used
	# ★★ 所有折边的粗线带（与本体同一次遍历收集的变换 / 进度）
	_sync_edge_layers(edge_items, false)
	# ★★ 旗面（可动部件）单独一发：按占领进度摆在旗杆上（见 `_sync_flags`）
	_sync_flags(marked, stamp)
	# ★★ 建造表现：推进弹跳计时 + 画在建建筑的头顶进度条
	_sync_build_bars()


## 一栋建筑在世界里的变换：底边贴地、尺寸 = 本体平面尺寸 × 视觉高度
##
## ★ `body_scale` 是 **logic 的权威**（占一格的比例，碰撞也用它）；
##   这里只把它翻译成 3D 的宽 / 深，**不新增任何尺寸来源**。
##   高度来自 `_height_of()`（纯表现）；有模型的类型（城墙）改用模型自带的高度。
## ★★ 2026.10.27（性能）：**静态变换缓存**（建筑实例 id → 不含受击振动的 Transform3D）。
##
## 建筑不会移动、不会缩放：`_transform_of()` 里的 `palette.to_world(center)`、
## `body_scale()`、`_height_of()` 每帧重算的都是同一串常量。
## 缓存键带 `world.building_revision`：建筑增 / 删 / 换归属时整表作废
## （归属会换颜色、但不动变换；这一条只是保险，代价是每帧一次整数比较）。
## 受击振动仍然是每帧现算的**偏移量**，行为不变。
var _xform_cache: Dictionary = {}
var _xform_rev: int = -1


## ---- 建造表现：升起 / 完成弹跳 / 头顶进度条（2026.10.31）----
##
## ★ 逻辑层早就有 `build_sec` 读条（`is_under_construction()` / `build_progress()`），
##   这一层只负责**画出来**：读条期间整栋沉在地面以下匀速升起，读完那一刻弹一下再落地。
## ★★ 为什么不能走 `_xform_cache`：那个缓存的前提是「建筑不会移动」。在建的建筑**每帧都在动**，
##   所以 `_transform_of()` 对「在建 / 正在弹」的实例绕开缓存现算，其余照旧命中缓存。
## ★ 全员可见性沿用 `_visible_to_me()`（战争迷雾里看不见的敌方建筑不画条）。
const POP_UP_SEC := 0.16        ## 弹起段（秒）
const POP_FALL_SEC := 0.14      ## 落下段（秒）
const POP_SQUASH_SEC := 0.16    ## 落地压扁的回弹段（秒）
const POP_CELLS := 0.16         ## 弹起高度（格）；0.16 格 ≈ 20 世界单位
const BAR_CAPACITY := 64        ## 同时最多画多少条进度条

## 上一帧这一栋是否在建（iid -> bool）：用来抓「建造完成」那一帧
var _was_constructing: Dictionary = {}
## 正在弹的实例：iid -> 已经过的时间（秒）
var _pop_elapsed: Dictionary = {}
## 本帧 dt（`sync()` 写、`_transform_of()` 读 —— 它的签名不能改，调用点很多）
var _frame_dt: float = 0.0

## 进度条批次
var _bar_mesh: QuadMesh = null
var _bar_mat: ShaderMaterial = null
var _bar_mm: MultiMesh = null
var _bar_node: MultiMeshInstance3D = null


## 一栋建筑在建 / 弹跳时的**额外变换**（dy = 竖直偏移，sy = 纵向缩放）。
## 返回空字典 = 没有动画（调用方走缓存）。
func _anim_state(b) -> Dictionary:
	var iid: int = int(b.get_instance_id())
	if b.is_under_construction():
		# 全程匀速跟着读条：进度 0% 整栋埋在土里，100% 刚好到地面
		var p: float = b.build_progress()
		return {"dy": -_world_height_of(b) * (1.0 - p)}
	var t: Variant = _pop_elapsed.get(iid, null)
	if t == null:
		return {}
	var e: float = float(t)
	if e < POP_UP_SEC:
		var u: float = e / POP_UP_SEC
		return {"dy": POP_CELLS * _cell * (1.0 - (1.0 - u) * (1.0 - u))}
	if e < POP_UP_SEC + POP_FALL_SEC:
		var u2: float = (e - POP_UP_SEC) / POP_FALL_SEC
		return {"dy": POP_CELLS * _cell * (1.0 - u2 * u2)}
	var u3: float = (e - POP_UP_SEC - POP_FALL_SEC) / POP_SQUASH_SEC
	if u3 <= 1.0:
		# 落地压扁：0 → -10% → 0，正弦包络；模型原点在底边 ⇒ 缩放不会陷进地里
		return {"dy": 0.0, "sy": 1.0 - 0.10 * sin(PI * u3)}
	return {}


## 这栋建筑在世界里有多高（世界单位）：模型类型读模型 AABB，方块类型读 `_height_of`。
func _world_height_of(b) -> float:
	var t := String(b.type)
	var s: float = b.body_scale(cfg)
	if _uses_model(t):
		var m: Mesh = _model_meshes.get(t, null)
		if m != null:
			return m.get_aabb().size.y * _cell * s
	return _cell * _height_of(b)


func _transform_of(b) -> Transform3D:
	# ★★ 在建 / 正在弹：现算并绕开缓存（建筑此刻每帧都在动）
	var anim: Dictionary = _anim_state(b)
	if not anim.is_empty():
		var xa: Transform3D = _static_transform_of(b)
		xa.origin.y += float(anim.get("dy", 0.0))
		var sy: Variant = anim.get("sy", null)
		if sy != null and _uses_model(String(b.type)):
			var ka: float = _cell * b.body_scale(cfg)
			xa.basis = Basis().scaled(Vector3(ka, ka * float(sy), ka))
		if b.hit_flash > 0.0:
			var cell_a: float = palette.cell_size()
			var shake_a: float = HitFxRes.shake_tiles(b.hit_flash, _hit_amp, _hit_freq) * cell_a
			shake_applied_last_frame += 1
			xa.origin = Vector3(xa.origin.x + shake_a, xa.origin.y, xa.origin.z)
		return xa
	var rev: int = int(world.building_revision)
	if _xform_rev != rev:
		_xform_cache.clear()
		_xform_rev = rev
	var iid: int = int(b.get_instance_id())
	var cached: Variant = _xform_cache.get(iid, null)
	if cached == null:
		cached = _static_transform_of(b)
		_xform_cache[iid] = cached
	var xf: Transform3D = cached
	# ★ 受击左右振动（纯表现）：X 方向一个小位移，随 hit_flash 衰减
	if b.hit_flash > 0.0:
		var cell: float = palette.cell_size()
		var shake: float = HitFxRes.shake_tiles(b.hit_flash, _hit_amp, _hit_freq) * cell
		shake_applied_last_frame += 1
		xf.origin = Vector3(xf.origin.x + shake, xf.origin.y, xf.origin.z)
	return xf


## 建造中建筑的头顶进度条：一个 billboard MultiMesh 全画完。
## ★ 同时负责**推进弹跳计时**与「在建 → 完工」那一刻的检测（每帧一次遍历）。
func _sync_build_bars() -> void:
	if _bar_mm == null or palette == null or palette.cam == null:
		return
	var cam_basis: Basis = palette.cam.global_transform.basis
	var shown: int = 0
	var seen: Dictionary = {}
	for b in world.building_list:
		if not b.alive:
			continue
		var iid: int = int(b.get_instance_id())
		seen[iid] = true
		var cons: bool = b.is_under_construction()
		# 上一帧在建、这一帧完工 ⇒ 起跳
		if _was_constructing.get(iid, false) and not cons:
			_pop_elapsed[iid] = 0.0
		_was_constructing[iid] = cons
		if _pop_elapsed.has(iid):
			var e: float = float(_pop_elapsed[iid]) + _frame_dt
			if e > POP_UP_SEC + POP_FALL_SEC + POP_SQUASH_SEC:
				_pop_elapsed.erase(iid)
			else:
				_pop_elapsed[iid] = e
		if not cons or shown >= BAR_CAPACITY:
			continue
		if not _visible_to_me(b):
			continue
		var pos: Vector3 = palette.to_world(b.center())
		pos.y = GROUND_LIFT + _world_height_of(b) + _cell * 0.22
		_bar_mm.set_instance_transform(shown, Transform3D(cam_basis, pos))
		_bar_mm.set_instance_custom_data(shown,
			Color(clampf(b.build_progress(), 0.0, 1.0), 1.0, 0.0, 0.0))
		shown += 1
	# 清掉已经不存在的建筑留下的状态
	for k in _was_constructing.keys():
		if not seen.has(k):
			_was_constructing.erase(k)
	for k in _pop_elapsed.keys():
		if not seen.has(k):
			_pop_elapsed.erase(k)
	_bar_mm.visible_instance_count = shown
	_bar_node.visible = shown > 0


## ★★ 建筑在**屏幕上**的包围矩形（点击 / 悬停 / 框选用）。
##
## ★ 为什么需要它：建筑有**高度**（大本营 1.35 格、箭塔更高），鼠标点在模型上半部分时，
##   射线打到的地面格是**建筑后方**的地块 —— 只按 `hover_tile` 判会「点不到立着的那半截」。
##   这里把模型 AABB 的 8 个角按实例变换投到屏幕，取包围盒。
## ★ 只读：不参与逻辑，不改 world；没有网格 / 相机时返回空 Rect2（调用方退回地面格判定）。
func screen_rect_of(b) -> Rect2:
	if b == null or palette == null or palette.cam == null:
		return Rect2()
	var mesh: Mesh = _mesh_for(String(b.type))
	if mesh == null:
		return Rect2()
	var aabb: AABB = mesh.get_aabb()
	var xf: Transform3D = _transform_of(b)
	var cam: Camera3D = palette.cam
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for i in 8:
		var c: Vector3 = aabb.position
		if (i & 1) != 0:
			c.x += aabb.size.x
		if (i & 2) != 0:
			c.y += aabb.size.y
		if (i & 4) != 0:
			c.z += aabb.size.z
		var wp: Vector3 = xf * c
		if cam.is_position_behind(wp):
			continue
		var sp: Vector2 = cam.unproject_position(wp)
		mn.x = minf(mn.x, sp.x)
		mn.y = minf(mn.y, sp.y)
		mx.x = maxf(mx.x, sp.x)
		mx.y = maxf(mx.y, sp.y)
	if mx.x < mn.x or mx.y < mn.y:
		return Rect2()
	return Rect2(mn, mx - mn)


## `_transform_of()` 的**静态部分**（不含受击振动）——这是会被缓存的那一半。
func _static_transform_of(b) -> Transform3D:
	var cell: float = palette.cell_size()
	var c: Vector2 = b.center()
	var base: Vector3 = palette.to_world(c)
	var s: float = b.body_scale(cfg)
	# ★★ 有模型的类型（城墙 / 箭塔 / 大本营 / 区划中心）：模型已按「1 单位 = 1 格、底边在 y = 0」建好 ⇒
	#    统一缩放格宽 × body_scale、底边直接贴地（高度由模型自己决定，不再走 `_height_of`）。
	if _uses_model(String(b.type)):
		var k: float = cell * s
		return Transform3D(Basis().scaled(Vector3(k, k, k)),
			Vector3(base.x, GROUND_LIFT, base.z))
	var w: float = cell * s
	var h: float = cell * _height_of(b)
	# 立方体以**中心**为原点 ⇒ 抬到「底边贴地」，并贴在地面之上一点避免 z-fighting
	var pos := Vector3(base.x, h * 0.5 + GROUND_LIFT, base.z)
	return Transform3D(Basis().scaled(Vector3(w, h, w)), pos)


# ------------------------------------------------------------------
# ★★ 区划中心旗子（占领动画）：旗面沿旗杆上升，升起程度 = 占领进度
# ------------------------------------------------------------------

## 这一类型有没有**可动部件**（旗面）。
func _uses_moving(type: String) -> bool:
	return BUILDING_MOVING_MODELS.has(type)


## 一面旗子现在该画成什么样：`progress` 0 = **不画**（无人占领），0~1 = 升起程度；`color` = 旗色。
##
## ★ 口径（与 logic/zone.gd 的字段一一对应，别在别处重算）：
##   · 已被某一方占领（`owner != ""`）                → progress 1.0（升到顶），旗色 = 归属方主色；
##   · 正在被读条占领（`capture_state != ""` 且有进度）→ progress = 该进度，旗色 = 占领方主色；
##   · 其余（无主且无人读条）                        → progress 0.0（**旗杆上没有旗子**）。
func zone_flag_state(b) -> Dictionary:
	var fallback: Color = cfg.color("zone_center")
	if world == null:
		return {"progress": 0.0, "color": fallback}
	var z: Variant = world.zone_by_id(int(b.zone_id))
	if z == null:
		return {"progress": 0.0, "color": fallback}
	var owner := String(z["owner"])
	if owner != "":
		return {"progress": 1.0, "color": SideColorRes.color(cfg, world, owner, "main")}
	var who := String(z.get("capture_faction", ""))
	var state := String(z.get("capture_state", ""))
	var prog: float = clampf(float(z.get("progress", 0.0)), 0.0, 1.0)
	if state != "" and prog > 0.0 and who != "":
		return {"progress": prog, "color": SideColorRes.color(cfg, world, who, "main")}
	return {"progress": 0.0, "color": fallback}


## 旗面在世界里的变换：**底边**随进度从杆底线性升到「杆顶 − 旗高」。
## ★ 旗面模型底边在局部 y = 0 ⇒ 整体抬到 `GROUND_LIFT + 底边高度 × k` 就是它的世界位置。
func _flag_transform(b, progress: float) -> Transform3D:
	var cell: float = palette.cell_size()
	var base: Vector3 = palette.to_world(b.center())
	var shake := 0.0
	if b.hit_flash > 0.0:
		shake = HitFxRes.shake_tiles(b.hit_flash, _hit_amp, _hit_freq) * cell
	var k: float = cell * b.body_scale(cfg)
	var t: float = clampf(progress, 0.0, 1.0)
	var z_bottom: float = lerpf(ZC_POLE_BOTTOM, ZC_POLE_TOP - ZC_CLOTH_H, t)
	return Transform3D(Basis().scaled(Vector3(k, k, k)),
		Vector3(base.x + shake, GROUND_LIFT + z_bottom * k, base.z))


## 旗面的 MultiMesh（按「类型 + 颜色」分桶：不同占领方颜色不同 ⇒ 一批一色）。
func _flag_batch_for(key: String, color: Color, type: String) -> Dictionary:
	var hit: Variant = _flag_batches.get(key, null)
	if hit != null:
		return hit
	var mat := ShaderMaterial.new()
	mat.shader = BUILDING_FLASH_SHADER
	mat.set_shader_parameter("base_color", color)
	# ★★ 旗面也随区划中心一起「白边 + 同色填充」；填充色 = 旗色。
	mat.set_shader_parameter("hover_fill_color", color)
	mat.set_shader_parameter("hover_fill_alpha", _hover_fill_alpha)
	mat.next_pass = _outline_pass(_moving_meshes.get(type, null))
	mat.set_shader_parameter("flash_strength", cfg.num("render.hit_flash_alpha", 0.8))
	mat.set_shader_parameter("fade_alpha", cfg.num("render.building_fade_alpha", 0.3))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _moving_meshes.get(type, null)
	# ★⚠️ `use_custom_data` 必须在 `instance_count` **之前**设（见 unit_view_3d 的说明）
	mm.use_custom_data = true
	mm.instance_count = 16
	var node := MultiMeshInstance3D.new()
	node.name = "Flags_" + key
	node.multimesh = mm
	node.material_override = mat
	add_child(node)
	batches_created += 1
	var rec := {"node": node, "mm": mm}
	_flag_batches[key] = rec
	return rec


## 每帧摆旗面：只画 `progress > 0` 的区划中心，逐面按进度抬高（闪白 / 淡出与建筑同一条口径）。
##
## ★★ 2026.10.28（性能）：`stamp` 是 `sync()` 已经算好的「3×3 内有可见单位」位图，
##   这里不再对每一面旗重做 9 次字典探测（见 `_fade_at`）。
func _sync_flags(marked: Dictionary, stamp: PackedByteArray = PackedByteArray()) -> void:
	if world == null or cfg == null:
		return
	var buckets: Dictionary = {}
	# 旗面类型的折边实例（与旗面本体同变换 / 同进度）
	var edge_items: Dictionary = {}
	for b in world.building_list:
		if not b.alive or not _uses_moving(String(b.type)):
			continue
		# ★★ 战争迷雾：看不见的敌方建筑不给画旗（判据同建筑本体）
		if not _visible_to_me(b):
			continue
		var st: Dictionary = zone_flag_state(b)
		var pr: float = float(st["progress"])
		if pr <= 0.0:
			continue
		var type := String(b.type)
		var col: Color = st["color"]
		var key := "%s|%s" % [type, _color_hex(col)]
		var rec: Variant = buckets.get(key, null)
		if rec == null:
			rec = {"type": type, "color": col, "items": []}
			buckets[key] = rec
		(rec["items"] as Array).append({"b": b, "p": pr})
	for key in buckets.keys():
		var rec2: Dictionary = buckets[key]
		var items: Array = rec2["items"]
		var type_s := String(rec2["type"])
		var brec: Dictionary = _flag_batch_for(key, rec2["color"], type_s)
		var mm: MultiMesh = brec["mm"]
		if mm.instance_count < items.size():
			mm.instance_count = maxi(items.size(), mm.instance_count * 2)
		for i in items.size():
			var b = items[i]["b"]
			var xform: Transform3D = _flag_transform(b, float(items[i]["p"]))
			mm.set_instance_transform(i, xform)
			var flash: float = clampf(b.hit_flash, 0.0, 1.0)
			var fade: float = 1.0 if _flag_fade(b, marked, stamp) else 0.0
			# ★ 悬停进度：主循环刚推进过同一格的 `_hover_anim`（旗面在它之后跑）
			#   ⇒ 旗面与本体的白边 / 填充 / 透明度恢复完全同步。
			var tile := Vector2i(b.tx, b.ty)
			var hov: float = clampf(float(_hover_anim.get(tile, 0.0)), 0.0, 1.0)
			var sel: float = 1.0 if _selected_tiles.has(tile) else 0.0
			mm.set_instance_custom_data(i, Color(flash, fade, hov, sel))
			var elist: Array = edge_items.get(type_s, [])
			elist.append({"x": xform, "h": hov, "s": sel})
			edge_items[type_s] = elist
		mm.visible_instance_count = items.size()
		(brec["node"] as MultiMeshInstance3D).visible = true
		flag_instance_count += items.size()
	for key in _flag_batches.keys():
		if not buckets.has(key):
			var r2: Dictionary = _flag_batches[key]
			(r2["mm"] as MultiMesh).visible_instance_count = 0
			(r2["node"] as MultiMeshInstance3D).visible = false
	# ★★ 旗面也有「所有折边」：与旗面同变换 / 同进度。
	_sync_edge_layers(edge_items, true)


## 旗面的淡出判据：有位图就走快路径，没有就退回按字典查 9 格（语义一致）。
func _flag_fade(b, marked: Dictionary, stamp: PackedByteArray) -> bool:
	if not stamp.is_empty():
		return _fade_at(stamp, b)
	return should_fade(b, marked)


## `Color.to_html()` 的缓存：同一帧里几十面旗常常是同一个颜色，
## 而 `to_html` 每次都要拼一个 6 位十六进制字符串（纯分配）。
var _color_hex_cache: Dictionary = {}


func _color_hex(c: Color) -> String:
	var hit: Variant = _color_hex_cache.get(c, null)
	if hit != null:
		return String(hit)
	var s := c.to_html(false)
	_color_hex_cache[c] = s
	return s


func _faction_or_type_color(b, owner: String) -> Color:
	# 无主的（区划中心）用它们自己的颜色，别去查阵营色（查不到会画成默认灰）
	if owner == "":
		match String(b.type):
			"zone_center":
				return cfg.color("zone_center")
			"stone_wall":
				return cfg.color("stone_wall")
			"tower":
				return cfg.color("tower")
			"watch_tower":
				return cfg.color("watch_tower")
			_:
				return cfg.color("wall")
	# ★★ 中立化（大本营被拆）：保留归属，但一律画成中性灰。
	if b.neutralized:
		var nkey := "%s|%s|n" % [owner, String(b.type)]
		var nhit: Variant = _color_cache.get(nkey, null)
		if nhit != null:
			return nhit
		var nc: Color = cfg.side_color_neutral
		match String(b.type):
			"wall":
				nc = nc.darkened(0.35)
			"stone_wall":
				nc = nc.darkened(0.5)
			"tower":
				nc = nc.darkened(0.12)
			"watch_tower":
				nc = nc.darkened(0.0)
		_color_cache[nkey] = nc
		return nc
	var key := "%s|%s" % [owner, String(b.type)]
	var hit: Variant = _color_cache.get(key, null)
	if hit != null:
		return hit
	# ★★ 本轮起**所有有主建筑**都按「本机视角的己 / 友 / 敌」三色着色
	#   （用户口径：所有敌人都显示红色）。墙 / 塔用同色的明度差区分类型 ——
	#   否则红墙和红塔在密集城墙里糊成一片。
	var side: Color = SideColorRes.color(cfg, world, owner, "main")
	var c: Color
	match String(b.type):
		"wall":
			c = side.darkened(0.35)
		"stone_wall":
			c = side.darkened(0.5)
		"tower":
			c = side.darkened(0.12)
		"watch_tower":
			c = side
		"farm":
			c = side.darkened(0.15)
		"house":
			c = side.lightened(0.15)
		"mine":
			c = side.darkened(0.35)
		_:
			c = side
	_color_cache[key] = c
	return c


func _visible_to_me(b) -> bool:
	if world == null or world.fog == null or cfg == null:
		return true
	if not cfg.fog_enabled:
		return true
	return world.fog.building_visible(world.my_faction, b)


# ------------------------------------------------------------------
# ★★ 有单位靠近 ⇒ 建筑淡出（本轮新增；口径见 config.json 的 _building_fade_comment）
# ------------------------------------------------------------------

## 「哪些格上有可见单位」——每格记 1 次（不再连 8 邻格一起标）。
## ★ 建筑只落在这些格之一就淡出 ⇒ 「以建筑为中心的 3x3 内有单位」= **查建筑自己的 9 格**。
##   比「逐建筑扫全部单位」便宜（建筑逐帧重画；单位可能有几十个）。
## ★ 只算**当前可见**的单位：迷雾里的敌人不该让建筑淡出 —— 那会把它的位置漏出去。
## ★★ 由 `game_scene3d` 每帧喂进来（来自 `unit_view_3d` 同一次遍历算好的「可见单位所在格」）。
##    它是**一次性**的：被 `_fade_marked_tiles()` 消费一次就清空 —— 所以「单独调用 sync()」
##    （测试）与「game_scene3d 每帧喂」两条路都不会读到上一帧的旧值。
##    null = 没人喂 ⇒ 退回自算（测试 / 独立使用时不破）。
var _provided_marked = null


## 外部喂入「可见单位所在格」（见上一行注释）。下一帧没人再喂就恢复自算。
func set_fade_marked(m: Variant) -> void:
	_provided_marked = m


func _fade_marked_tiles() -> Dictionary:
	# ★ 喂进来的那一份**只消费一次**（见 `_provided_marked` 的注释）。
	if _provided_marked != null:
		var provided: Variant = _provided_marked
		_provided_marked = null
		return provided
	var marked: Dictionary = {}
	if world == null:
		return marked
	for u in world.units:
		if not u.alive:
			continue
		if not _unit_visible(u):
			continue
		marked[Vector2i(u.tx, u.ty)] = true
	return marked


## 这栋建筑要不要淡出（它**自己的 3×3** 里有没有可见单位 = 查 `marked` 9 格）。
##
## ★ 保留这个「按字典查 9 格」的版本是为了**接口不变**（`tests/test_view3d.gd` 直接拿
##   `_fade_marked_tiles()` 的结果调它）。`sync()` 那一侧走 `_fade_at()` 的位图快路径，
##   两者语义逐位一致（见 `view/fade_stamp.gd` 的等价性说明）。
func should_fade(b, marked: Dictionary) -> bool:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if marked.has(Vector2i(b.tx + dx, b.ty + dy)):
				return true
	return false


## `should_fade()` 的位图快路径：一次数组下标（见 `view/fade_stamp.gd`）。
## ★★ 2026.10.28（性能）：城墙上限 240 段、加上箭塔 / 大本营，`building_list` 可以是**几百栋**；
##   原来每帧对每栋各做 9 次「新建 `Vector2i` + 字典哈希」——而 `_sync_flags()`
##   还会把同一份判断再跑一遍（旗面）。位图把这两遍都压成一次下标。
func _fade_at(stamp: PackedByteArray, b) -> bool:
	if stamp.is_empty():
		return false
	var t: int = int(b.ty) * int(world.map.cols) + int(b.tx)
	return t >= 0 and t < stamp.size() and stamp[t] != 0


## 单位对「我这边」可不可见（与 unit_view_3d 同一条判据：迷雾的唯一出处是 logic/fog.gd）。
func _unit_visible(u) -> bool:
	if world == null or world.fog == null or cfg == null:
		return true
	if not cfg.fog_enabled:
		return true
	return world.fog.unit_visible(world.my_faction, u)


# ------------------------------------------------------------------
# ★★ 建筑模型（本轮新增）：用 Blender 导出的 `.glb` 取代单位方块
# ------------------------------------------------------------------

## 这一类型是不是走模型（而不是单位方块）。
## ★ 只此一处判据：`_batch_for` 选网格、`_transform_of` 选变换都读它，两边永远一致。
## ★★ 这里**不看**模型是否加载成功 —— 这些类型就是模型这条路，
##   加载失败由 `_load_building_mesh` 报错，绝不退回方块（见文件头）。
func _uses_model(type: String) -> bool:
	return BUILDING_MODELS.has(type)


## 这一类型用哪个网格：有模型的走模型，其余走单位方块。
## ★ 与 `_uses_model` 同源（同一张 `BUILDING_MODELS`）⇒ 不会出现「变换按模型算、网格却是方块」。
func _mesh_for(type: String) -> Mesh:
	if _uses_model(type):
		return _model_meshes.get(type, null)
	return _box


## 载入一个建筑模型；失败返回 null 并 `push_error`（**不退回方块**）。
## ★★ 不走 `ResourceLoader.exists` 那道「保险」：导出后的工程里，源文件路径与存在的资源
##   不是一回事（资源被改写成 `.scn` / `.ctex` 并重映射），先 `exists` 再 `load` 会在
##   导出包里把「模型在」误判成「模型不在」⇒ 悄悄退回方块。`load()` 自己会走重映射。
func _load_building_mesh(path: String) -> Mesh:
	var res: Variant = load(path)
	if res is PackedScene:
		var inst: Node = (res as PackedScene).instantiate()
		var m: Mesh = _build_merged_mesh(inst)
		inst.free()
		if m != null:
			return m
	push_error("建筑模型加载失败：%s（该类型不退回方块，请确认素材已导入 / 已随工程导出）" % path)
	return null


## 把导入场景里**所有** MeshInstance3D 的网格按各自节点变换**合并成一个** ArrayMesh。
## ★★ 为什么不「取一个网格」：Blender 里的模型往往是**多个物体的组合**（塔身 + 基座 + 尖顶 …），
##   glb 会把它们当成**多个 mesh** 带进来，而 MultiMesh 一个批次只能挂一个 mesh。
##   取「第一个」只会拿到排在前面的那块、取「占地最大」又会丢掉细部 —— 两种都错。
##   正确做法是**全都要**：合成一个再交给 MultiMesh。
func _build_merged_mesh(root: Node) -> Mesh:
	var parts: Array = []
	_collect_meshes(root, Transform3D.IDENTITY, parts)
	if parts.is_empty():
		return null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for e in parts:
		var m: Mesh = e["mesh"]
		for s in m.get_surface_count():
			st.append_from(m, s, e["xform"])
	return st.commit()


## 深度优先收集所有 MeshInstance3D 的网格，以及它**相对根节点**的变换。
## ★ 合并时必须带上节点自身的平移 / 旋转 / 缩放，否则各部分的位置会丢（柱子会塌回原点）。
func _collect_meshes(node: Node, parent: Transform3D, out: Array) -> void:
	var here: Transform3D = parent * node.transform
	if node is MeshInstance3D:
		var m: Mesh = (node as MeshInstance3D).mesh
		if m != null:
			out.append({"mesh": m, "xform": here})
	for ch in node.get_children():
		_collect_meshes(ch, here, out)
