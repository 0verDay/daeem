## terrain_view.gd —— 地形渲染（对应 HTML 版 render.js 的地形那一段）
##
## ★ 这里**只画**，通行性判定一律读 logic/map_data.gd 的地形网格。
##   绝不把 TileMapLayer 的图块数据当权威 —— 否则换一张图集就能悄悄改变玩法
##   （而且这种 bug 极难查：看起来只是换了个贴图，见 docs/pitfalls.md 2.2）。
##
## 数量多且不需要交互（384 格），所以用一个节点 _draw() 画全部，
## 而不是每格一个节点（那是 docs/pitfalls.md 2.3 明确禁止的写法）。
extends Node2D

const ConfigRes = preload("res://logic/config.gd")
const PaletteRes = preload("res://view/palette.gd")

var cfg: ConfigRes = null
var map = null

var _color_grass: Color
var _color_grass_alt: Color
var _color_forest: Color
var _color_mountain: Color
var _color_mountain_edge: Color
var _color_grid: Color


func setup(p_cfg: ConfigRes, p_map) -> void:
	cfg = p_cfg
	map = p_map
	_color_grass = cfg.color("grass")
	_color_grass_alt = cfg.color("grass_alt")
	_color_forest = cfg.color("forest")
	_color_mountain = cfg.color("mountain")
	_color_mountain_edge = cfg.color("mountain_edge")
	_color_grid = cfg.color("grid")
	queue_redraw()


func _draw() -> void:
	if cfg == null or map == null:
		return
	var cell: float = cfg.cell_px
	var grid_line := PackedVector2Array()

	for ty in map.rows:
		for tx in map.cols:
			var r := PaletteRes.tile_rect(tx, ty, cfg)
			var t := String(map.terrain.get_cell(tx, ty))
			match t:
				"mountain":
					draw_rect(r, _color_mountain, true)
					# 山体描一圈亮边：地形是可通行性的唯一真相，画得让人一眼看出来
					draw_rect(r, _color_mountain_edge, false, maxf(1.0, cell * 0.04))
				"forest":
					draw_rect(r, _color_forest, true)
				_:
					# 棋盘格微差：让地块边界看得出来，又不至于像格子纸
					draw_rect(r, _color_grass if (tx + ty) % 2 == 0 else _color_grass_alt, true)

	# 网格线单独走一条多段线，比每格画两次线少 768 次 draw 调用
	for tx in map.cols + 1:
		var x: float = tx * cell
		grid_line.append(Vector2(x, 0.0))
		grid_line.append(Vector2(x, map.rows * cell))
	for ty in map.rows + 1:
		var y: float = ty * cell
		grid_line.append(Vector2(0.0, y))
		grid_line.append(Vector2(map.cols * cell, y))
	draw_multiline(grid_line, _color_grid, 1.0)

	# 地图边界：给镜头一个「到底了」的参照
	var border := Rect2(Vector2.ZERO, Vector2(map.cols * cell, map.rows * cell))
	draw_rect(border, Color(1, 1, 1, 0.18), false, 2.0)
