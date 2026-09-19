## palette.gd —— 配色与坐标换算的唯一入口（对应 HTML 版 js/render.js 顶部的约定）
##
## ★★ 两条铁律（HTML 版为这两件事吃过两次大亏，见 docs/pitfalls.md 3.1）：
##
##   1. **逻辑坐标是「格」，像素只在 view/ 出现**，换算只有这一个文件里的两个函数。
##      任何时候在 logic/ 里看到 cell_px / 64 / `* CELL`，就是错。
##
##   2. **相机数学与所有输入换算必须用同一套屏幕坐标**。
##      Godot 里这件事由引擎负责（`Camera2D.get_global_mouse_position()`），
##      所以本文件**不自己手算屏幕→世界**，只做「世界（格）→ 世界（像素）」这一段。
##      HTML 版的坐标错位根因就是「绘制用一套、鼠标换算用另一套」，这里刻意不留这个口子。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")


## 逻辑坐标（格）→ 绘制坐标（像素）
static func to_px(logic_pos: Vector2, cfg: ConfigRes) -> Vector2:
	return logic_pos * cfg.cell_px


## 绘制坐标（像素）→ 逻辑坐标（格）。**只给输入换算用**，
## 而且只有当输入已经是世界坐标（而不是屏幕坐标）时才该调用它。
static func to_logic(px_pos: Vector2, cfg: ConfigRes) -> Vector2:
	return px_pos / cfg.cell_px


## 一个地块在屏幕上的矩形（像素）
static func tile_rect(tx: int, ty: int, cfg: ConfigRes) -> Rect2:
	var c: float = cfg.cell_px
	return Rect2(Vector2(tx * c, ty * c), Vector2(c, c))


## 单位半径（像素）—— 由逻辑半径（格）换算，不要各处自己写 cell * factor
static func unit_radius_px(cfg: ConfigRes, kind: String = "general") -> float:
	return cfg.unit_radius_of(kind) * cfg.cell_px


## 建筑在屏幕上的矩形。
##
## ★ 尺寸**只有一个来源**：logic 的 building.body_scale()（墙体 1.0 = 填满整格，
##   大本营 / 箭塔 0.6 = 居中、四周各留 0.2 格）。这里不许再写一套内缩量 ——
##   否则「看着能过、实际被挡」这种最难查的错位迟早出现。
static func building_rect(b, cfg: ConfigRes) -> Rect2:
	var r := tile_rect(b.tx, b.ty, cfg)
	var inset: float = cfg.cell_px * (1.0 - b.body_scale(cfg)) * 0.5
	if inset <= 0.0:
		return r
	return Rect2(r.position + Vector2(inset, inset), r.size - Vector2(inset * 2.0, inset * 2.0))


## 建筑矩形在**节点局部坐标**里的位置（building_view 的节点原点 = 自己那一格的左上角）。
##
## ★ 这个函数存在的唯一理由：`building_rect()` 是**绝对**矩形，里面那个居中偏移很容易被忘掉。
##   第一版就是那么错的：只取了 `rect.size`、从局部 (0,0) 开始画 ——
##   城墙（1.0 格）看不出问题，大本营 / 箭塔却贴到了格子的**左上角**（手玩一眼就看出来了）。
##   `tests/test_building_body.gd` 会断言它的中心正好落在格心。
static func building_local_rect(b, cfg: ConfigRes) -> Rect2:
	var r := building_rect(b, cfg)
	var origin := tile_rect(b.tx, b.ty, cfg).position
	return Rect2(r.position - origin, r.size)


## 颜色混合：把 over 以 alpha 叠在 base 上（Godot 的 lerp 用起来更直观）
static func mix(base: Color, over: Color, t: float) -> Color:
	return base.lerp(over, clampf(t, 0.0, 1.0))
