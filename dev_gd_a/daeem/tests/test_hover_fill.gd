## test_hover_fill.gd —— 鼠标悬停高亮（阵营色填充）
##
## 需求口径（2026.10.26）：
##   · 己方单位 → 它**所属整支部队**一起填色；
##   · 敌方 / 友方单位、任意建筑 → 只填那一个；
##   · 手机端整个功能不启用。
##
## 这里钉的是**接线与口径**（谁被点亮 / 不新增批次 / 手机关掉），
## 观感（颜色浓淡、淡入淡出）由用户在编辑器里验收 —— 无头测试不做截图。
extends "res://tests/test_case.gd"

const Game3DRes = preload("res://view/game_scene3d.gd")
const InputControllerRes = preload("res://view/input_controller.gd")
const UnitRes = preload("res://logic/unit.gd")
const BuildingRes = preload("res://logic/building.gd")
const FactionRes = preload("res://logic/faction.gd")
const UnitFlashShaderRes = preload("res://view/unit_flash.gdshader")
const UnitDownedShaderRes = preload("res://view/unit_downed.gdshader")
const BuildingShaderRes = preload("res://view/building_flash.gdshader")
const BuildingOutlineShaderRes = preload("res://view/building_hover_outline.gdshader")
const BuildingEdgeShaderRes = preload("res://view/building_edge_outline.gdshader")
const BuildingEdgeRibbonRes = preload("res://view/building_edge_ribbon.gd")
const BuildingViewRes = preload("res://view/building_view_3d.gd")
const SideColorRes = preload("res://view/side_color.gd")
const UnitSpriteRes = preload("res://view/unit_sprite_3d.gd")
const ConfigRes = preload("res://logic/config.gd")

func _initialize() -> void:
	_case_name = "test_hover_fill"
	_run()

func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	_test_config(cfg)
	_test_shaders()
	_test_edge_ribbon()
	_test_unit_hover_texture(cfg)
	_test_zone_hover_color(cfg)
	await _test_unit_grouping(cfg)
	await _test_views(cfg)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


## ★★ 折边线带：box 应该只描 12 条棱（平面内的三角对角线不描）；
##   crease=0 时才把对角线也描出来（顶点数变多）。
func _test_edge_ribbon() -> void:
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var em: ArrayMesh = BuildingEdgeRibbonRes.build(box, 0.03, 8.0)
	ok(em.get_surface_count() > 0, "★★ box 折边线带生成了网格")
	var arr: Array = em.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	eq(verts.size(), 48, "★★ box 只描 12 条棱（12 棱 × 4 顶点 = 48）")
	eq((arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size(), 72,
		"★★ 每条棱两个三角形（12 棱 × 6 索引 = 72）")
	# ★ 展开在 shader 里做 ⇒ 网格必须带「边方向 + 侧向/线宽」两个属性。
	eq((arr[Mesh.ARRAY_NORMAL] as PackedVector3Array).size(), 48,
		"★★ 每条 ribbon 顶点带边方向（shader 按真实视线展开）")
	eq((arr[Mesh.ARRAY_TEX_UV] as PackedVector2Array).size(), 48,
		"★★ 每条 ribbon 顶点带侧向 / 线宽（UV.x / UV.y）")
	var em2: ArrayMesh = BuildingEdgeRibbonRes.build(box, 0.03, 0.0)
	var verts2: PackedVector3Array = (em2.surface_get_arrays(0) as Array)[Mesh.ARRAY_VERTEX]
	ok(verts2.size() > 48,
		"★★ crease=0 时连平面内的三角对角线也描（%d > 48）" % verts2.size())


func _test_config(cfg) -> void:
	var a: float = cfg.num("render.hover_fill_alpha", -1.0)
	ok(a >= 0.0 and a <= 1.0, "★ render.hover_fill_alpha 在 0..1 内")
	near(a, 1.0, 0.001, "★★ 默认 1.0 = 纯色填充（不是旧的 0.7 半透明罩色）")
	ok(cfg.num("render.hover_fill_sec", -1.0) >= 0.0,
		"★ render.hover_fill_sec ≥ 0（0 = 立即切换）")
	ok(cfg.hover_outline_color.r > 0.99 and cfg.hover_outline_color.g > 0.99 \
			and cfg.hover_outline_color.b > 0.99,
		"★★ 悬停描边是白色（%s）" % cfg.hover_outline_color.to_html(false))
	ok(cfg.building_outline_scale > 1.0,
		"★★ 建筑描边是向外放大的倍率（%.3f > 1）" % cfg.building_outline_scale)
	ok(cfg.num("render.building_edge_width", -1.0) > 0.0,
		"★★ 建筑所有折边的线带宽度有值（%f）" % cfg.num("render.building_edge_width", -1.0))
	ok(cfg.num("render.building_edge_crease_deg", -1.0) >= 0.0,
		"★★ 折边阈值 ≥ 0（0 = 连三角化对角线也画）")
	ok(cfg.hover_pick_radius_tiles > 0.0,
		"★★ 悬停拾取的格半径剪枝有值（%f）" % cfg.hover_pick_radius_tiles)


func _test_shaders() -> void:
	var uf: String = UnitFlashShaderRes.code
	ok(uf.contains("INSTANCE_CUSTOM.g"), "★ 单位 shader 从每实例数据读悬停进度(.g)")
	ok(uf.contains("hover_tex") and uf.contains("hover_fill_alpha"),
		"★★ 单位 shader 有悬停贴图 / 混合强度（纯阵营色 + 白描边烘在贴图里）")
	ok(uf.contains("hover_tex : source_color"),
		"★★ 悬停贴图按 sRGB 采样（否则阵营色会发白：实测 #5ac8ff → #a0e5ff）")
	ok(uf.contains("ALPHA_SCISSOR_THRESHOLD"),
		"★★ 单位 shader 仍然写 scissor（不透明管线、深度正确 —— 别为了悬停把它删了）")
	var ud: String = UnitDownedShaderRes.code
	ok(ud.contains("hover_tex"), "★ 濒死 shader 也支持悬停样式（部队里的濒死将领跟着亮）")
	ok(not ud.contains("ALPHA_SCISSOR_THRESHOLD ="), "★ 濒死 shader 仍然不写 scissor")
	var bf: String = BuildingShaderRes.code
	ok(bf.contains("INSTANCE_CUSTOM.b"), "★★ 建筑 shader 从每实例数据读悬停进度(.b)")
	ok(bf.contains("hover_fill_color"), "★ 建筑 shader 有填充色 uniform")
	ok(bf.contains("v_selected = INSTANCE_CUSTOM.a"),
		"★★ 建筑 shader 读选中状态（.a）")
	ok(bf.contains("max(hov, sel)"),
		"★★ 悬停**或选中**都把淡出收回（选中也保证不透明）")
	ok(bf.contains("depth_draw_always"), "★★ 建筑 shader 仍然写 depth_draw_always（别删）")
	ok(bf.contains("shade"), "★ 建筑的假光照仍然作用在填充后的颜色上（不丢立体感）")
	var bo: String = BuildingOutlineShaderRes.code
	ok(bo.contains("INSTANCE_CUSTOM.b"), "★★ 描边 pass 按每实例悬停进度显隐")
	ok(bo.contains("cull_front"), "★★ 描边是反向壳（只画背面）")
	ok(bo.contains("outline_scale") and bo.contains("outline_color"),
		"★ 描边有粗细 / 颜色两个 uniform")
	ok(bo.contains("outline_pivot"),
		"★★ 描边绕网格 AABB 中心放大（旗面 / 模型的原点不在中心，四边都要有白边）")
	ok(bo.contains("ALPHA = max(hov, sel)"),
		"★★ 悬停与选中共用一条描边 pass（悬停白边按进度淡入）")
	ok(bo.contains("INSTANCE_CUSTOM.a"),
		"★★ 建筑选中状态走每实例数据 .a（不新增 MultiMesh 批次）")
	ok(bo.contains("select_color"),
		"★★ 选中描边有独立的金色 uniform（与单位选中同色）")
	ok(bo.contains("mix(select_color.rgb, outline_color.rgb, hov)"),
		"★★ 悬停白色优先于选中金色（与单位「悬停 > 选中」同口径）")
	var be: String = BuildingEdgeShaderRes.code
	ok(be.contains("INSTANCE_CUSTOM.b") and be.contains("INSTANCE_CUSTOM.a"),
		"★★ 折边线带同时读悬停(.b) / 选中(.a)")
	ok(be.contains("MODELVIEW_MATRIX = mat4(1.0)") and be.contains("cross(edge_dir, to_cam)"),
		"★★ 折边在顶点着色器里按**真实视线**展开（修下半屏线带被深度挡掉）")
	ok(be.contains("hover_color") and be.contains("select_color"),
		"★★ 折边线带有白 / 金两个颜色 uniform")
	ok(be.contains("mix(select_color.rgb, hover_color.rgb, hov)"),
		"★★ 折边线带也是悬停白色优先")


## ★★ 单位悬停贴图：必须是「纯阵营色躯体 + 白描边」，而且**alpha 与原贴图逐像素一致**
##   —— 否则 shader 交叉混合时剪影会「胀一下」（art 档的 6px 安全边最容易踩）。
func _test_unit_hover_texture(cfg) -> void:
	var path: String = cfg.unit_sprite_of("spearman")
	if path == "" or not ResourceLoader.exists(path):
		ok(false, "找不到 spearman 立牌素材，无法验证悬停贴图")
		return
	var col: Color = cfg.side_color_self
	var outline: Color = col
	# 这张贴图不是选中态 ⇒ sel 不会参与上色；传白色只为满足签名。
	var sel: Color = Color.WHITE
	var white: Color = cfg.hover_outline_color
	var base: ImageTexture = UnitSpriteRes.bake_asset(path, col, false, outline, "art",
		false, sel, false, white)
	var hov: ImageTexture = UnitSpriteRes.bake_asset(path, col, false, outline, "art",
		false, sel, true, white)
	ok(base != hov, "★ 悬停是另一张帖图（不是直接改原图的颜色）")
	var a: Image = base.get_image()
	var b: Image = hov.get_image()
	eq(b.get_width(), a.get_width(), "★ 悬停贴图与原贴图同宽")
	eq(b.get_height(), a.get_height(), "★ 悬停贴图与原贴图同高")
	# ① art 档：原画不透明的地方，悬停贴图也必须是实心的（不能有任何洞），
	#   而且躯体要变成**纯阵营色** —— 这正是「纯色填充」的口径。
	var strong := 0
	var holes := 0
	var solid := 0
	var white_hits := 0
	for y in a.get_height():
		for x in a.get_width():
			var pa: Color = a.get_pixel(x, y)
			var pb: Color = b.get_pixel(x, y)
			if pa.a > 0.9:
				strong += 1
				if pb.a < 0.9:
					holes += 1
				if _near_col(pb, col):
					solid += 1
			if pb.a > 0.95 and pb.r > 0.98 and pb.g > 0.98 and pb.b > 0.98:
				white_hits += 1
	eq(holes, 0, "★★ 原画不透明处，悬停贴图没有洞（%d 个实心像素）" % strong)
	ok(solid > strong * 0.95,
		"★★ 原画的躯体在悬停贴图里换成了纯阵营色（%d / %d）" % [solid, strong])
	ok(white_hits > 100, "★★ 悬停贴图里有一圈**白色**描边像素（%d）" % white_hits)

	# ② faction 档：躯体本来就是阵营色 ⇒ 可以直接比「阵营色像素」的形状。
	#    padding / fit 偏了会让这一块的像素数或包围盒变化（剪影会「胀一下」）。
	var base_f: ImageTexture = UnitSpriteRes.bake_asset(path, col, false, outline,
		"faction", false, sel, false, white)
	var hov_f: ImageTexture = UnitSpriteRes.bake_asset(path, col, false, outline,
		"faction", false, sel, true, white)
	var af: Image = base_f.get_image()
	var bf: Image = hov_f.get_image()
	var n_a := _count_solid_col(af, col)
	var n_b := _count_solid_col(bf, col)
	eq(n_b, n_a, "★★ 阵营色躯体的像素数完全一致（%d，剪影不会胀）" % n_a)
	eq(_bbox_solid_col(bf, col), _bbox_solid_col(af, col),
		"★★ 阵营色躯体的包围盒完全一致（位置 / 大小都没偏）")


func _near_col(c: Color, ref: Color) -> bool:
	return c.a > 0.5 and absf(c.r - ref.r) < 0.02 \
		and absf(c.g - ref.g) < 0.02 and absf(c.b - ref.b) < 0.02


## 「实心躯干」像素：alpha 满 + 颜色正好是阵营色。
## ★ 不用 `_near_col`（alpha > 0.5）是刻意的：描边与躯体的**抗锯齿交界**会被合成成
##   不同的中间色（普通描边是深色、悬停描边是白色），那圈像素数本来就会差几个；
##   这里只比「完全没有被描边污染的实心躯体」，形状有没有偏靠它来钉。
func _is_solid_col(c: Color, ref: Color) -> bool:
	return c.a > 0.999 and absf(c.r - ref.r) < 0.01 \
		and absf(c.g - ref.g) < 0.01 and absf(c.b - ref.b) < 0.01


func _count_solid_col(img: Image, ref: Color) -> int:
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			if _is_solid_col(img.get_pixel(x, y), ref):
				n += 1
	return n


func _bbox_solid_col(img: Image, ref: Color) -> Rect2i:
	var lo := Vector2i(99999, 99999)
	var hi := Vector2i(-1, -1)
	for y in img.get_height():
		for x in img.get_width():
			if _is_solid_col(img.get_pixel(x, y), ref):
				lo.x = mini(lo.x, x)
				lo.y = mini(lo.y, y)
				hi.x = maxi(hi.x, x)
				hi.y = maxi(hi.y, y)
	if hi.x < 0:
		return Rect2i()
	return Rect2i(lo, hi - lo + Vector2i.ONE)


## ★★ 区划中心本身 owner 为空：悬停填充色必须取**所属区划**的归属色。
##   已占领 / 读条中 = 该方主色（与旗面同源）；无主 = 中立灰。
func _test_zone_hover_color(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var bv = BuildingViewRes.new()
	bv.cfg = cfg
	bv.world = w
	var zc = null
	for b in w.building_list:
		if b != null and b.alive and String(b.type) == "zone_center":
			zc = b
			break
	if zc == null:
		bv.free()
		ok(false, "地图里找不到区划中心，无法验证悬停归属色")
		return
	var z = w.zone_by_id(int(zc.zone_id))
	if z == null:
		bv.free()
		ok(false, "区划中心没有对应区划")
		return
	var saved_owner := String(z["owner"])
	var saved_capture := String(z.get("capture_faction", ""))
	var saved_state := String(z.get("capture_state", ""))
	var saved_progress: float = float(z.get("progress", 0.0))

	z["owner"] = "p1"
	var want: Color = SideColorRes.color(cfg, w, "p1", "main")
	near(bv._hover_color_of(zc, "").r, want.r, 0.001,
		"★★ 已占领区划中心：悬停填充 = 占领方阵营色")
	# 接线：这个颜色真的落到了建筑材质的 uniform 上，而且材质挂了白描边 pass。
	var rec: Dictionary = bv._batch_for("|zone_center", Color(1, 0, 1),
		"zone_center", bv._hover_color_of(zc, ""))
	var mat: ShaderMaterial = rec["node"].material_override
	var got: Color = mat.get_shader_parameter("hover_fill_color")
	near(got.r, want.r, 0.001, "★★ 区划中心材质拿到的填充色 = 归属方阵营色")
	ok(mat.next_pass != null, "★★ 建筑材质挂了描边 pass（next_pass）")
	ok(mat.next_pass.shader == BuildingOutlineShaderRes,
		"★★ next_pass 用的就是建筑描边 shader")
	var want_sel: Color = ConfigRes.parse_color(
		cfg.str_val("render.unit_select_outline_color", "#f2b544"))
	var got_sel: Color = mat.next_pass.get_shader_parameter("select_color")
	near(got_sel.r, want_sel.r, 0.001, "★★ 选中描边颜色 = 单位选中金")
	near(got_sel.g, want_sel.g, 0.001, "★★ 选中描边绿色通道也一致")

	z["owner"] = ""
	z["capture_faction"] = "enemy"
	z["capture_state"] = "reading"
	z["progress"] = 0.5
	near(bv._hover_color_of(zc, "").r,
		SideColorRes.color(cfg, w, "enemy", "main").r, 0.001,
		"★★ 读条占领中的区划中心：悬停填充 = 占领方颜色（与旗面一致）")

	z["owner"] = ""
	z["capture_faction"] = ""
	z["capture_state"] = ""
	z["progress"] = 0.0
	near(bv._hover_color_of(zc, "").r, cfg.side_color_neutral.r, 0.001,
		"★★ 无主区划中心：悬停填充 = 中立灰")

	z["owner"] = saved_owner
	z["capture_faction"] = saved_capture
	z["capture_state"] = saved_state
	z["progress"] = saved_progress
	bv.free()


## 口径：己方 = 整支部队；敌 / 友 = 单个；拾取剪枝只是省算、不改判定口径。
func _test_unit_grouping(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	# 用一份**只有自己造的单位**的列表，避免地图预置单位干扰命中排序（跑完还原）。
	var saved: Array = w.units
	w.units = []
	w.my_faction = "p1"
	var leader = UnitRes.create(cfg, "hf_leader", "队长", Vector2i(4, 4),
		"p1", "general", "", "", "spearman", 0)
	var a1 = UnitRes.create(cfg, "hf_a1", "兵一", Vector2i(4, 5),
		"p1", "spearman", "", "hf_leader", "spearman")
	var a2 = UnitRes.create(cfg, "hf_a2", "兵二", Vector2i(5, 4),
		"p1", "spearman", "", "hf_leader", "spearman")
	var foe = UnitRes.create(cfg, "hf_foe", "敌人", Vector2i(20, 15),
		"enemy", "spearman", "", "", "spearman")
	var pal = UnitRes.create(cfg, "hf_pal", "盟友", Vector2i(24, 18),
		"p2", "spearman", "", "", "spearman")
	w.units.append(leader)
	w.units.append(a1)
	w.units.append(a2)
	w.units.append(foe)
	w.units.append(pal)
	# 一栋己方建筑（框选兜底那条路要验「框里的己方建筑」）
	var saved_buildings: Array = w.building_list
	var wall = BuildingRes.create(cfg, "wall", 8, 8, "p1")
	w.building_list = saved_buildings.duplicate()
	w.building_list.append(wall)

	var ic = InputControllerRes.new()
	ic.cfg = cfg
	ic.world = w

	# ① 悬停附属兵 → 将领 + 两个兵（整支部队）
	ic._hover_on_unit(a1)
	eq(ic.hover_unit_ids.size(), 3, "★★ 悬停己方附属兵 → 整支部队（3 个 id）")
	ok(ic.hover_unit_ids.has("hf_leader") and ic.hover_unit_ids.has("hf_a1")
		and ic.hover_unit_ids.has("hf_a2"), "★★ 整队的 id 就这三个（将领 + 两个兵）")
	ok(ic.hover_buildings.is_empty(), "★ 悬停单位时不带建筑")
	# ② 悬停将领 → 同一队
	ic._hover_on_unit(leader)
	eq(ic.hover_unit_ids.size(), 3, "★★ 悬停将领 → 同一支部队（3 个 id）")
	# ③ 敌方 → 只有它自己
	ic._hover_on_unit(foe)
	eq(ic.hover_unit_ids, ["hf_foe"], "★★ 悬停敌方单位 → 只点亮它自己（不展开它的部队）")
	# ④ 友方（盟友）→ 也只有它自己：判据是 world.my_faction，**不是** same_side
	FactionRes.set_allies([["p1", "p2"]])
	ok(FactionRes.same_side_for_attack("p2", "p1"), "（前提）p2 与 p1 是盟友")
	ic._hover_on_unit(pal)
	eq(ic.hover_unit_ids, ["hf_pal"], "★★ 悬停友方单位 → 仍只点亮它自己（不展开整队）")
	FactionRes.clear_allies()
	ic._clear_hover()
	ok(ic.hover_unit_ids.is_empty() and ic.hover_unit == null,
		"★ 清空后悬停状态全归零")

	# ⑤ 拖框预览：己方单位（整队）> 己方建筑（那一批）> 光标单目标
	#   `_hover_from_box()` 只读 `drag_box()`（= 两个世界点围出的矩形），与松手时
	#   `box_select` 的判据逐条一致，所以这里直接摆那两个点。
	ic.drag_start_world = Vector2(4.1, 4.1)
	ic.drag_current_world = Vector2(4.9, 4.9)       # 只框住将领一个人的脚底
	ok(ic._hover_from_box(), "★★ 框到己方单位 ⇒ 预览命中")
	eq(ic.hover_unit_ids.size(), 3, "★★ 框里只框到一个人也整队亮（3 个 id）")
	ok(ic.hover_buildings.is_empty(), "★ 有己方单位时建筑让位（优先级更低）")

	ic.drag_start_world = Vector2(8.1, 8.1)
	ic.drag_current_world = Vector2(8.9, 8.9)       # 只框住那栋己方城墙
	ok(ic._hover_from_box(), "★★ 框到己方建筑 ⇒ 预览命中")
	ok(ic.hover_unit_ids.is_empty(), "★ 只框到建筑时没有单位被点亮")
	eq(ic.hover_buildings, [Vector2i(8, 8)], "★★ 框里的己方建筑那一格被点亮")

	ic.drag_start_world = Vector2(4.1, 4.1)
	ic.drag_current_world = Vector2(8.9, 8.9)       # 单位 + 建筑同时在框里
	ok(ic._hover_from_box(), "★ 单位 + 建筑都在框里 ⇒ 仍然命中")
	eq(ic.hover_unit_ids.size(), 3, "★★ 单位优先：整队亮")
	ok(ic.hover_buildings.is_empty(), "★★ 单位优先时建筑不亮（需求：建筑优先级低于单位）")

	ic.drag_start_world = Vector2(12.0, 12.0)
	ic.drag_current_world = Vector2(13.0, 13.0)     # 空的
	ok(not ic._hover_from_box(), "★ 框里什么都没有 ⇒ 退回光标单目标那条路")

	ic.drag_start_world = Vector2(24.1, 18.1)
	ic.drag_current_world = Vector2(24.9, 18.9)     # 只有盟友（非己方）
	ok(not ic._hover_from_box(), "★★ 框到友方单位不算「己方」⇒ 不预览（同 box_select 口径）")

	ic.drag_start_world = Vector2.ZERO
	ic.drag_current_world = Vector2.ZERO
	ic._clear_hover()

	# ⑤.5 触摸端：双指框选用**屏幕矩形**判定（与 box_select_screen 逐条一致）
	var cam = make_test_camera(cfg)
	# ★ 相机必须先真的在这个视口里跑过一帧，否则 `unproject_position` 全是 0
	#   （见 pitfalls 10.3：投影 API 会退化成零值 ⇒ 屏幕框会落在原点、命中全乱）。
	await process_frame
	var screen_pal = make_test_palette(cfg, cam)
	if screen_pal != null:
		ic.palette = screen_pal
		ic.touch_mode = true
		ic.drag_screen_valid = true
		ic.drag_screen_box = ic._unit_icon_screen_rect(leader).grow(2.0)
		ok(ic._hover_from_box(), "★★ 触摸端：屏幕框罩住立牌 ⇒ 预览命中")
		eq(ic.hover_unit_ids.size(), 3, "★★ 触摸端屏幕框只碰到一个兵也整队亮")
		ok(ic.hover_from_box, "★★ 标记成「来自框选」（手机端只有这一路放行）")
		# 建筑：屏幕框罩住城墙那一格的屏幕点
		var bp: Vector2 = screen_pal.to_px(wall.center())
		ic.drag_screen_box = Rect2(bp - Vector2(2.0, 2.0), Vector2(4.0, 4.0))
		ok(ic._hover_from_box(), "★★ 触摸端：屏幕框罩住己方城墙 ⇒ 预览命中")
		ok(ic.hover_unit_ids.is_empty(), "★ 触摸端：只框到建筑时没有单位被点亮")
		eq(ic.hover_buildings, [Vector2i(8, 8)], "★★ 触摸端框里的己方建筑被点亮")
		# 屏幕框为空 ⇒ 没有预览
		var empty_p: Vector2 = screen_pal.to_px(Vector2(12.5, 12.5))
		ic.drag_screen_box = Rect2(empty_p - Vector2(2.0, 2.0), Vector2(4.0, 4.0))
		ok(not ic._hover_from_box(), "★ 触摸端空框 ⇒ 不出预览")
		ok(not ic.hover_from_box, "★ 空框不会标记成「来自框选」")
		# 没有屏幕框（老路径）⇒ 退回世界矩形
		ic.drag_screen_valid = false
		ic.drag_start_world = Vector2(4.1, 4.1)
		ic.drag_current_world = Vector2(4.9, 4.9)
		ok(ic._hover_from_box(), "★ 触摸端没有屏幕框时退回世界矩形")
		eq(ic.hover_unit_ids.size(), 3, "★ 退回世界矩形后口径不变（整队）")
		ic.touch_mode = false
		ic.drag_screen_valid = false

	# ⑥ 拾取剪枝：只省算，不改「谁算命中」的口径
	#   ★ 这个探针世界里的单位是后加的，迷雾掩码里没有它们 ⇒ 敌方会被「看不见」挡掉。
	#     这里只验拾取的距离口径，所以临时把本世界的迷雾摘掉（跑完还原）。
	var saved_fog = w.fog
	w.fog = null
	var saved_pad: float = cfg.unit_hit_pad_px
	cfg.unit_hit_pad_px = cfg.cell_px * 3.0      # 脚底圆半径 ≈ 3 格，好观察剪枝
	var probe: Vector2 = foe.pos + Vector2(2.0, 0.0)
	var unpruned = ic._pick_any_unit_at(probe)
	ok(unpruned == foe, "★ 不剪枝时：2 格外（在放大后的命中圆内）也算命中")
	var pruned = ic._pick_any_unit_at(probe, 0.5)
	ok(pruned == null, "★★ 剪枝半径 0.5 格 → 先被距离挡掉（不会为每个兵投一次屏）")
	var kept = ic._pick_any_unit_at(probe, 2.5)
	ok(kept == foe, "★ 剪枝半径 2.5 格 → 命中不变（只是省算）")
	cfg.unit_hit_pad_px = saved_pad
	w.fog = saved_fog

	w.units = saved
	w.building_list = saved_buildings
	ic.free()


func _test_views(cfg) -> void:
	var game = Game3DRes.new()
	root.add_child(game)
	await process_frame
	ok(game.start(), "3D 游戏场景装得起来")
	if game.world == null:
		game.queue_free()
		return
	await process_frame
	await process_frame
	game.set_process(false)          # 冻住主循环，让计数确定

	var w = game.world
	var units = game.units
	var buildings = game.buildings

	# ① 单位：己方整队被点亮，**不新增批次**（钉住「不加 MultiMesh 变体桶」这条契约）
	units.set_hover([])
	units.sync(0.2)
	var base_batches: int = units.mesh_batch_count
	var base_created: int = units.batches_created
	var target = null
	for u in w.units:
		if u.alive and units._visible_to_me(u):
			target = u
			break
	if target != null:
		var team: Array = w.group_of(target)
		game.input_ctrl._hover_on_unit(target)
		eq(game.input_ctrl.hover_unit_ids.size(), team.size(),
			"★★ 悬停己方单位 → hover_unit_ids = 整支部队（%d）" % team.size())
		units.set_hover(game.input_ctrl.hover_unit_ids)
		units.sync(0.2)
		var expect := 0
		for m in team:
			if m.alive and units._visible_to_me(m):
				expect += 1
		eq(units.hover_instance_count, expect,
			"★★ 被填充的实例数 = 可见的队伍人数（%d）" % expect)
		eq(units.mesh_batch_count, base_batches,
			"★★ 悬停不新增 MultiMesh 批次（%d == %d）" % [units.mesh_batch_count, base_batches])
		eq(units.batches_created, base_created, "★★ 也不会新建批次")
		# 淡出：0.2s 足够走完 0.1s 的淡出
		units.set_hover([])
		units.sync(0.2)
		eq(units.hover_instance_count, 0, "★ 移开鼠标后填充退回 0（淡出完成）")

		# ★★ 回归（用户报的 bug）：MultiMesh 自定义数据按**实例下标**存，而选中态会换批次。
		#   「在某批次里亮过 1 → 换到另一批次淡出 → 换回来」时，旧批次的那几个下标上
		#   还留着 1；只给"当前悬停候选"写值的话，换回来的部队会整片变蓝。
		units.set_selection([])
		units.set_hover([target.id])
		units.sync(0.2)
		var c1: Color = units.last_custom_for(target.id)
		near(c1.g, 1.0, 0.01, "★ （前提）该单位在当前批次的槽位填充满 1")
		units.set_selection([target.id])      # 换到「选中」批次
		units.set_hover([])                   # 淡出发生在**另一个**批次里
		units.sync(0.2)
		units.set_selection([])               # 换回原批次（旧槽位上还留着 1）
		units.sync(0.2)
		near(units.last_custom_for(target.id).g, 0.0, 0.01,
			"★★ 换批次再换回来后槽位被重写成 0（不继承旧填充 —— 用户报的「取消选中后整队变蓝」）")
		units.set_selection([])
		units.set_hover([])
		units.sync(0.2)
	else:
		ok(false, "地图里找不到可用于悬停测试的己方单位")

	# ② 建筑：只有鼠标底下那一栋 .b > 0
	var b0 = null
	for b in w.building_list:
		if b.alive and buildings._visible_to_me(b):
			b0 = b
			break
	if b0 != null:
		ok(not buildings._edge_meshes.is_empty(),
			"★★ 建筑网格生成了「所有折边」的线带网格（%d 类）" % buildings._edge_meshes.size())
		ok(buildings._edge_mat.render_priority > 0,
			"★★ 折边层晚于建筑本体绘制（透明排序，render_priority=%d）"
				% buildings._edge_mat.render_priority)
		buildings.set_hover([Vector2i(b0.tx, b0.ty)])
		buildings.sync(0.2)
		ok(buildings.edge_instance_count > 0,
			"★★ 折边线带真的画了（%d 个实例）" % buildings.edge_instance_count)
		ok(not buildings._edge_layers.is_empty(),
			"★★ 折边线带按类型建了 MultiMesh 层（%d 类）" % buildings._edge_layers.size())
		eq(buildings.hovered_last_frame, 1, "★★ 只有鼠标底下那一栋建筑被填充")
		# ★ 不读 MultiMesh 的逐实例数据：实测（Godot 4.7 + 无头）`get_instance_transform` /
		#   `get_instance_custom_data` **读不回**刚写进去的值（见 unit_view_3d 的同一处注释），
		#   所以钉的是建筑层自己的进度表（真实的一手数据）。
		eq(buildings._hover_anim.size(), 1, "★★ 进度表里正好一栋（那一栋）")
		ok(absf(float(buildings._hover_anim.values()[0]) - 1.0) < 0.01,
			"★★ 0.2s ≥ hover_fill_sec(0.1s) ⇒ 进度满 1.0")
		buildings.set_hover([])
		buildings.sync(0.2)
		eq(buildings.hovered_last_frame, 0, "★ 移开后建筑填充归零")
		ok(buildings._hover_anim.is_empty(), "★ 进度表清空（不会一直留着）")

		# ★★ 建筑选中金边：即时开关，走 .a，不新增批次
		var base_created_sel: int = buildings.batches_created
		buildings.set_selected([Vector2i(b0.tx, b0.ty)])
		buildings.sync(0.2)
		eq(buildings.selected_last_frame, 1, "★★ 选中的那一栋建筑带上金边")
		eq(buildings._selected_tiles.size(), 1, "★★ 选中集合里正好一栋")
		eq(buildings.batches_created, base_created_sel,
			"★★ 建筑选中不新增 MultiMesh 批次")
		buildings.set_selected([])
		buildings.sync(0.2)
		eq(buildings.selected_last_frame, 0, "★ 取消选中后金边归零")

		# 接线：己方建筑 / 区划中心 / 敌方建筑三种选中都要换算成「地块」
		game.input_ctrl.select_building(b0)
		eq(game._selected_building_tiles_for_view(), [Vector2i(b0.tx, b0.ty)],
			"★★ 选中的己方建筑 → 它的地块")
		if w.zones != null and not w.zones.zones.is_empty():
			var z0 = w.zones.zones[0]
			var zc0 = game._zone_center_building_of(z0)
			if zc0 != null:
				game.input_ctrl.select_zone(z0)
				eq(game._selected_building_tiles_for_view(),
					[Vector2i(zc0.tx, zc0.ty)],
					"★★ 选中的区划 → 它的中心建筑地块也加金边")
		game.input_ctrl.select_enemy(b0)
		eq(game._selected_building_tiles_for_view(), [Vector2i(b0.tx, b0.ty)],
			"★★ 选中的敌方建筑 → 也加金边")
		game.input_ctrl.select_units([])
		ok(game._selected_building_tiles_for_view().is_empty(),
			"★ 清空选中后没有建筑金边")
	else:
		ok(false, "地图里找不到可用于悬停测试的建筑")

	# ③ 触摸端门：只有**双指框选预览**放行（没有悬停这一说）
	game.input_ctrl.hover_unit_ids = ["dummy"]
	game.input_ctrl.hover_buildings = [Vector2i(0, 0)]
	game.touch_device = false
	game.input_ctrl.hover_from_box = false
	eq(game._hover_ids_for_view(), ["dummy"], "★ 桌面端把悬停 id 交给视图层")
	eq(game._hover_buildings_for_view().size(), 1, "★ 桌面端把悬停建筑交给视图层")
	game.touch_device = true
	ok(game._hover_ids_for_view().is_empty(), "★★ 触摸端非框选 ⇒ 不出单位遮罩")
	ok(game._hover_buildings_for_view().is_empty(), "★★ 触摸端非框选 ⇒ 不出建筑遮罩")
	game.input_ctrl.hover_from_box = true
	eq(game._hover_ids_for_view(), ["dummy"], "★★ 触摸端双指框选预览照常出遮罩")
	eq(game._hover_buildings_for_view().size(), 1, "★★ 触摸端框选预览也管建筑")
	game.touch_device = false
	game.input_ctrl.hover_from_box = false
	game.input_ctrl._clear_hover()

	game.queue_free()
	await process_frame
