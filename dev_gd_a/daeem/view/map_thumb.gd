## map_thumb.gd —— 合作大厅里的**地图缩略图**（纯 `_draw()`，不读图片资源）。
##
## 与 `view/map_preview.gd` 的区别：这里只要「一眼认出地形」——
## 把 `MapData` 的地形烘成 1 像素/格的贴图，按宽高比居中放大；不画目标 / 大本营 / 出生点。
## 配色与游戏内地面同源（`data/config.json` 的 `colors.*`，含 2026.10.20 新增的 `water`）。
extends Control

const PADDING := 8.0

var _cfg = null
var _map = null
var _tex: ImageTexture = null
var _cover: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	clip_contents = true
	resized.connect(queue_redraw)


func setup(cfg, map) -> void:
	_cfg = cfg
	_map = map
	_bake()
	queue_redraw()


## true = cover（填满控件、可能裁边，用于详情/准备的正方形缩略图）；
## false = contain（完整显示地图，用于地图选择卡片）。
func set_cover(on: bool) -> void:
	_cover = on
	queue_redraw()


func has_map() -> bool:
	return _map != null


func map():
	return _map


func map_rect() -> Rect2:
	if _map == null or _map.cols <= 0 or _map.rows <= 0:
		return Rect2()
	var avail := size - Vector2(PADDING, PADDING) * 2.0
	var aspect := float(_map.cols) / float(_map.rows)
	if _cover:
		var w := avail.x
		var h := w / aspect
		if h < avail.y:
			h = avail.y
			w = h * aspect
		return Rect2(Vector2((size.x - w) * 0.5, (size.y - h) * 0.5), Vector2(w, h))
	var w := avail.x
	var h := w / aspect
	if h > avail.y:
		h = avail.y
		w = h * aspect
	return Rect2(Vector2((size.x - w) * 0.5, (size.y - h) * 0.5), Vector2(w, h))


func _bake() -> void:
	_tex = null
	if _map == null or _map.cols <= 0 or _map.rows <= 0:
		return
	var img := Image.create(int(_map.cols), int(_map.rows), false, Image.FORMAT_RGBA8)
	var c_grass := Color(0.16, 0.24, 0.16)
	var c_grass_alt := Color(0.14, 0.21, 0.15)
	var c_forest := Color(0.10, 0.18, 0.12)
	var c_mountain := Color(0.22, 0.20, 0.17)
	var c_water := Color(0.18, 0.31, 0.40)
	if _cfg != null:
		c_grass = _cfg.color("grass")
		c_grass_alt = _cfg.color("grass_alt")
		c_forest = _cfg.color("forest")
		c_mountain = _cfg.color("mountain")
		c_water = _cfg.color("water")
	for y in int(_map.rows):
		for x in int(_map.cols):
			if not _map.tile_exists(x, y):
				img.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			var t := String(_map.terrain.get_cell(x, y))
			var c: Color = c_grass if (x + y) % 2 == 0 else c_grass_alt
			if t == "mountain":
				c = c_mountain
			elif t == "water":
				c = c_water
			elif t == "forest":
				c = c_forest
			img.set_pixel(x, y, c)
	_tex = ImageTexture.create_from_image(img)


func _draw() -> void:
	if _tex == null:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.09, 0.10, 0.9), true)
		return
	draw_texture_rect(_tex, map_rect(), false)
