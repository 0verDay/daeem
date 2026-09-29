## fog_view.gd —— 战争迷雾的**灰色遮罩**（对应 logic/fog.gd 算出来的视野掩码）
##
## ★★ 这个文件的全部工作就是「把没视野的地方盖成灰色」：
##   · 地形**永远画**（terrain_view 那层照旧），迷雾只是压在它上面的一层灰 ——
##     这就是需求里「所有地形都是默认全图可见的」那句话的落地方式；
##   · 有视野的格子**不盖**（透出下面的地形 / 区块 / 单位）；
##   · 地图外的格子（exists = false）不盖：那里本来什么都没有，
##     盖上去只会在屏幕外沿多出一圈方块（terrain_view 也不画它们）。
##
## ★ 谁被画出来由别的视图决定（unit_view / building_view / minimap 各自问
##   `world.fog.unit_visible()` / `building_visible()`）：本文件**不负责藏东西**，
##   它只画灰。两件事分开的理由：敌人在灰下面也会被画出来（多画一层无用的东西），
##   所以藏归藏、盖归盖 —— 藏在那儿的是视图的剔除逻辑，不是这一层。
##
## ---- 为什么是「一张贴图」而不是「每格一个 draw_rect」----
##   27×22 = 594 格，每帧 594 次 draw_rect 不会崩，但和 unit_view 那条教训一样
##   （每单位一次 draw_* 是纯 GDScript 开销，见 docs/architecture.md 3.2）：
##   格数一大（编辑器里的 100×100 图 = 10000 格）就明显了。
##   所以这里把掩码烘成一张 **1 像素 = 1 格** 的贴图，再用一次 `draw_texture_rect`
##   铺满整张地图（引擎自己按 NEAREST 放大，边缘是硬的 —— 正好是格子该有的样子）。
##
## ★ 合批与开销：`queue_redraw()` 每帧一次、一次 draw 调用，与单位数无关。
##   贴图只在掩码**真的变了**时重建（比字符串 / 数组比对便宜得多的一次判据）。
##
## ★ 纯表现：只读 world.fog 与 world.map，不写任何逻辑状态（第三条铁律）。
extends Node2D

const ConfigRes = preload("res://logic/config.gd")

var cfg: ConfigRes = null
var world = null

## 当前贴在屏幕上的那张掩码贴图（延迟建：第一帧才知道地图多大）。
var _tex: ImageTexture = null
## 建贴图用的图幅。地图换了（cols/rows 变了）就重建。
var _tex_cols: int = 0
var _tex_rows: int = 0
## 上一次烘图时用的那一行（用来判断「掩码变了没有」）。PackedByteArray 是值语义，
## 比对一次 594 字节几乎免费，比每帧重建一张 Image（要分配 + 上传）便宜得多。
var _last_mask := PackedByteArray()
## ★ 诊断用（只有测试读它）：最近一次 `_draw()` 真的发出了几次迷雾矩形的绘制。
var draw_count: int = 0


func setup(p_cfg: ConfigRes, p_world) -> void:
	cfg = p_cfg
	world = p_world


## 每帧由 game_scene 调（世界变了就重画；贴图按需重烘）。
func sync() -> void:
	_ensure_texture()
	queue_redraw()


## 按当地图尺寸建（或重建）那张 1 像素 = 1 格的遮罩贴图。
func _ensure_texture() -> void:
	if cfg == null or world == null or world.map == null:
		return
	var cols: int = world.map.cols
	var rows: int = world.map.rows
	if cols <= 0 or rows <= 0:
		return
	if _tex != null and _tex_cols == cols and _tex_rows == rows:
		return
	_tex_cols = cols
	_tex_rows = rows
	_last_mask = mask_for(cfg, world, world.my_faction)
	_tex = _bake(_last_mask, world.map, cols, rows)


## 把一份掩码烘成贴图。
##
## ★ 贴图里存的是**白色 + 视野的 alpha**（看得见 = 全透明、看不见 = 不透明），
##   颜色交给 `draw_texture_rect` 的 modulate —— 于是「换个灰色」不用重烘贴图
##   （设计师在 config 里调 mask_color 就能立刻看到）。
##
## ★★ 地图外的格子（`exists = false`）**一律烘成透明**（= 不盖）：
##   terrain_view 与小地图都不画它们，那里露出来的应该是背景；
##   盖上一块灰会在屏幕外沿多出一圈方块，看着像「地图外面还有地」。
static func _bake(mask: PackedByteArray, map, cols: int, rows: int) -> ImageTexture:
	var img := Image.create(cols, rows, false, Image.FORMAT_RGBA8)
	for y in rows:
		for x in cols:
			var i: int = y * cols + x
			var seen: bool = i < mask.size() and mask[i] != 0
			if map != null and not map.tile_exists(x, y):
				seen = true
			img.set_pixel(x, y, Color(1, 1, 1, 0.0 if seen else 1.0))
	return ImageTexture.create_from_image(img)


## 取某阵营本帧的视野掩码。
## ⚠️ 拿不到（`fog` 还没建 / 还没算过）时返回**全 0** —— 也就是整屏都盖灰：
##    宁可让玩家看到「还没算好」，也不要让他以为「对面全在我眼皮底下」。
##
## ★ 用 `world.get("fog")` 而不是 `world.fog`：迷雾的调用方既有真 world（带 fog 字段的
##   对象），也有测试里手搓的**最小替身**（见 tests/test_fog.gd 的 `_make_fake`）。
##   直接点出属性会在替身上报 "Invalid access to property or key 'fog'"，
##   而 `_draw()` 里的报错**不会让测试失败** —— 那正是最容易静默漏掉的一类问题。
static func mask_for(cfg: ConfigRes, world, faction: String) -> PackedByteArray:
	var out := PackedByteArray()
	if world == null or world.map == null:
		return out
	out.resize(world.map.cols * world.map.rows)
	out.fill(0)
	if world.get("fog") == null:
		return out
	var m: Variant = world.fog.sight.get(faction, null)
	if m is PackedByteArray:
		return m
	return out


func _draw() -> void:
	draw_count = 0
	if cfg == null or world == null or world.map == null:
		return
	# 总开关关掉 = 全图有视野 = 一层雾都不画（行为与加迷雾之前一致）
	if not cfg.fog_enabled:
		return
	var cols: int = world.map.cols
	var rows: int = world.map.rows
	var mask := mask_for(cfg, world, world.my_faction)
	# ★ 掩码变了才重烘贴图。掩码是 PackedByteArray（值语义），比对便宜；
	#   而重新烘一张 Image + 上传 GPU 是相对贵的（每帧做就是白费）。
	if _tex == null or _tex_cols != cols or _tex_rows != rows or mask != _last_mask:
		_last_mask = mask
		_tex_cols = cols
		_tex_rows = rows
		_tex = _bake(mask, world.map, cols, rows)
	var cell: float = cfg.cell_px
	# ★★ 一次 `draw_texture_rect` 铺满整张地图（贴图是 1 像素 = 1 格）：
	#    594 格也只有 1 次 draw 调用 —— 与格数无关，也不必逐格判断 `exists`
	#    （不存在的格子已经在那张贴图里烘成透明了）。
	draw_texture_rect(_tex, Rect2(Vector2.ZERO, Vector2(float(cols), float(rows)) * cell),
		false, cfg.fog_mask_color)
	draw_count += 1
