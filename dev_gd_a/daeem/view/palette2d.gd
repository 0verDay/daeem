## palette2d.gd —— **遗留 2D 栈**的坐标换算（`view/palette.gd` 老静态 API 的替身）
##
## ---------------------------------------------------------------------------
## ★★ 这个文件为什么存在（读之前先看 `view/palette.gd` 的文件头）
##
##   `view/palette.gd` 已经从「静态函数集合」重写成**实例类**：它由
##   `PaletteRes.create(cfg, cam: Camera3D)` 造出来，换算全部走**真实的 3D 相机**
##   （`unproject_position` / `project_ray_normal` 与地面求交）。
##   同时新的 3D 栈（`game_scene3d.gd` / `ground_view.gd` / `unit_view_3d.gd` /
##   `overlay_view_3d.gd` / `unit_sprite_3d.gd`）才是真正在跑的那一套。
##
##   但仓库里还留着**一整套 2D 遗留栈**：
##     `game_scene.gd` / `camera_rig.gd` / `terrain_view.gd` / `zone_view.gd` /
##     `fog_view.gd` / `overlay.gd` / `unit_view.gd` / `building_view.gd` / `minimap.gd`，
##   以及一批要跑 `view/main.tscn` → `view/game_scene.gd` 的集成测试。
##   它们调的是**老 palette 的静态签名**（`PaletteRes.to_px(pos, cfg)` 这种），
##   于是**整个文件解析失败**（Parse Error 会连带把依赖它的脚本一起变成
##   "Compilation failed"）。
##
## ★★ 方向（很关键，别走错）：**不要**让 2D 遗留栈去适配 3D 语义。
##    正确做法是——遗留栈继续用它自己那套 **2D 换算**，只是把出处从
##    「已经改成实例类的 palette」搬到这里来，**一份实现、一处存放**。
##    理由：
##      · 遗留栈本来就是 2D 的（格 → 像素就是 `pos * cfg.cell_px`，没有透视）；
##        把它接到 3D 相机上等于让一套死代码依赖另一条活链路，两边都会更难改；
##      · 这些文件只在**无头测试**里被引用（真机跑的是 game_scene3d）；
##      · 「换算只有一处」这条铁律仍然成立：本该在 palette.gd 里的 2D 口径，
##        现在完整地落在本文件里，而不是散进九个文件的私有函数各写一份。
##
## ⚠️ 本文件**只服务遗留 2D 栈**。新写的 3D 代码一律不许 preload 它 ——
##    要用投影请走 `view/palette.gd` 的实例 API（那才是唯一正确的 3D 出处）。
## ---------------------------------------------------------------------------
##
## ★ 与老 palette.gd 的差别只有一个：老版本的 `unit_radius_px` **不随位置变化**，
##   这里也照旧（2D 没有近大远小）。带位置参数的新签名传进来时**忽略**它。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")


## 逻辑坐标（格）→ 绘制坐标（像素）。遗留 2D 栈的**唯一**正向换算。
static func to_px(logic_pos: Vector2, cfg: ConfigRes) -> Vector2:
	if cfg == null:
		return logic_pos
	return logic_pos * cfg.cell_px


## 绘制坐标（像素）→ 逻辑坐标（格）。**只给输入换算用**。
static func to_logic(px_pos: Vector2, cfg: ConfigRes) -> Vector2:
	if cfg == null:
		return px_pos
	var c: float = maxf(1e-9, cfg.cell_px)
	return px_pos / c


## 一个地块的四个角（像素）。
##
## ★★ 顶点顺序与 `view/palette.gd` 的新版**故意保持一致**：左上 → 右上 → 右下 → 左下。
##    `zone_view._outline_groups()` 按下标取边（上→右、下→左、左→上、右→下），
##    顺序一改，描边就会连到对角上去（那种错不报错、只是线走错）。
static func tile_poly(tx: int, ty: int, cfg: ConfigRes) -> PackedVector2Array:
	var c: float = cfg.cell_px if cfg != null else 128.0
	var x := float(tx) * c
	var y := float(ty) * c
	return PackedVector2Array([
		Vector2(x, y), Vector2(x + c, y), Vector2(x + c, y + c), Vector2(x, y + c),
	])


## 一个地块的矩形（像素）。进度条 / 血条这类 UI 读数的落点用它。
static func tile_rect(tx: int, ty: int, cfg: ConfigRes) -> Rect2:
	var c: float = cfg.cell_px if cfg != null else 128.0
	return Rect2(Vector2(float(tx) * c, float(ty) * c), Vector2(c, c))


## 一个**格坐标矩形**（x0..x1, y0..y1）的四个角（像素）。
static func quad_poly(x0: float, y0: float, x1: float, y1: float, cfg: ConfigRes) -> PackedVector2Array:
	var c: float = cfg.cell_px if cfg != null else 128.0
	return PackedVector2Array([
		Vector2(x0 * c, y0 * c), Vector2(x1 * c, y0 * c),
		Vector2(x1 * c, y1 * c), Vector2(x0 * c, y1 * c),
	])


## 整张地图的矩形（像素）—— 相机夹取 / 迷雾遮罩铺满用它。
static func map_rect(cfg: ConfigRes, cols: int, rows: int) -> Rect2:
	var c: float = cfg.cell_px if cfg != null else 128.0
	return Rect2(Vector2.ZERO, Vector2(float(cols) * c, float(rows) * c))


## 整张地图的四个角（像素）。地图边界描边用它。
static func map_poly(cfg: ConfigRes, cols: int, rows: int) -> PackedVector2Array:
	return quad_poly(0.0, 0.0, float(cols), float(rows), cfg)


## 单位半径（像素）—— 由逻辑半径（格）换算，各处不许自己写 cell_px * factor。
##
## ⚠️ 参数是**单位类型 id**（unit_type），不是 kind：将领的 kind 是 general，
##    它真正的半径为所属类型（长枪兵 / 长弓兵 / 骑手）的那一个。
## ★ 第三个参数（位置）是 3D 版新增的：2D 里半径**不随位置变化**，收了但不用。
static func unit_radius_px(cfg: ConfigRes, unit_type: String = "spearman",
		_at: Vector2 = Vector2.ZERO) -> float:
	if cfg == null:
		return 0.0
	return cfg.unit_radius_of(unit_type) * cfg.cell_px


## 建筑本体在屏幕上的矩形。
##
## ★ 尺寸**只有一个来源**：logic 的 `building.body_scale()`（墙体 1.0 = 填满整格，
##   大本营 / 箭塔 0.6 = 居中留边）。这里不许再写一套内缩量。
static func building_rect(b, cfg: ConfigRes) -> Rect2:
	var r := tile_rect(b.tx, b.ty, cfg)
	if cfg == null:
		return r
	var inset: float = cfg.cell_px * (1.0 - b.body_scale(cfg)) * 0.5
	if inset <= 0.0:
		return r
	return Rect2(r.position + Vector2(inset, inset), r.size - Vector2(inset * 2.0, inset * 2.0))


## 建筑矩形在**节点局部坐标**里的位置（节点原点 = 自己那一格的左上角）。
static func building_local_rect(b, cfg: ConfigRes) -> Rect2:
	var r := building_rect(b, cfg)
	var origin := tile_rect(b.tx, b.ty, cfg).position
	return Rect2(r.position - origin, r.size)


## 以某点为中心、给定**半径**（格）的四边形（像素）。
##
## ★ 与 `building_rect` 的区别：那个是「整数格范围 + body_scale 内缩」，
##   这个是「任意中心 + 任意半径」—— 塔顶 / 大本营内圈那种同心缩小用它。
##
## ⚠️ 实现方式注意：**必须**用 `to_px` 逐点算，不许写成 `center_px ± r_px` 的
##    平铺矩形 —— 后者在没有旋转时结果相同，但一旦投影口径变了（比如以后 2D
##    也斜放），两者的差就会变成「内圈贴到格子外面」那类静默错位。
static func centered_poly(center: Vector2, half_w: float, half_h: float,
		cfg: ConfigRes) -> PackedVector2Array:
	return PackedVector2Array([
		to_px(center + Vector2(-half_w, -half_h), cfg),
		to_px(center + Vector2(half_w, -half_h), cfg),
		to_px(center + Vector2(half_w, half_h), cfg),
		to_px(center + Vector2(-half_w, half_h), cfg),
	])


## 建筑本体在地面上的四个角（世界像素）。
##
## ★ 以**格心**为中心、按 `body_scale` 的半宽 / 半高铺开 —— 与
##   `building_local_poly` 是同一个形状，只是坐标系不同。
static func building_poly(b, cfg: ConfigRes) -> PackedVector2Array:
	var half: float = b.body_scale(cfg) * 0.5
	var c: Vector2 = b.center()
	return centered_poly(c, half, half, cfg)


## 建筑本体在**节点局部坐标**（原点 = 格心）里的四个角。
##
## ★ 节点原点放在格心，于是局部多边形天然以 (0,0) 为中心 ——
##   老版本那套「绝对矩形减格左上角」的居中偏移从此只有一处来源。
static func building_local_poly(b, cfg: ConfigRes) -> PackedVector2Array:
	var half: float = b.body_scale(cfg) * 0.5
	return PackedVector2Array([
		to_px(Vector2(-half, -half), cfg),
		to_px(Vector2(half, -half), cfg),
		to_px(Vector2(half, half), cfg),
		to_px(Vector2(-half, half), cfg),
	])


## 一个多边形的轴对齐外接框（血条 / 命中判定的落点用它）。
static func rect_of(poly: PackedVector2Array) -> Rect2:
	if poly.is_empty():
		return Rect2()
	var mn := poly[0]
	var mx := poly[0]
	for p in poly:
		mn = mn.min(p)
		mx = mx.max(p)
	return Rect2(mn, mx - mn)


# ------------------------------------------------------------------
# 2.5D 的补偿量（遗留 2D 栈里全都是**恒等**）
# ------------------------------------------------------------------
##
## ★★ 为什么恒等：2D 栈的世界空间**没有压扁**（`ContentRoot.scale = (1, 1)`），
##    所以「字 / 血条 / 光晕要被反向补偿」这件事在这里不需要做任何事。
##    ⚠️ 这几个函数**必须留着**：unit_view / building_view / overlay 都在调它们。
##       直接删掉调用点会让「有没有补偿」这个口径从代码里消失，等 2D 栈真被
##       重新启用（或者被谁抄去当参考）时，那些调用点就无从判断了。
##       保留 + 返回恒等 = 口径写在脸上：这里**没有**压扁，不是「忘了补偿」。

## 纵向补偿倍率。2D：恒等 1。
static func comp_scale(_cfg: ConfigRes) -> float:
	return 1.0


## 把一个「屏幕尺寸」按补偿换算回世界尺寸。2D：恒等。
static func comp_extent(_cfg: ConfigRes, extent: Vector2) -> Vector2:
	return extent


## 把一个「世界尺寸」按补偿换算成屏幕尺寸。2D：恒等（世界像素 == 屏幕像素）。
static func screen_metric(_cfg: ConfigRes, px: float) -> float:
	return px


## 颜色混合：把 over 以 alpha 叠在 base 上（与 `view/palette.gd` 的同名函数同一份语义）
static func mix(base: Color, over: Color, t: float) -> Color:
	return base.lerp(over, clampf(t, 0.0, 1.0))
