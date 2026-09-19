## overlay.gd —— 覆盖层：攻击线 / 建造预览 / 移动目标点
##                （对应 HTML 版 render.js 里的选中特效那一段）
##
## 不用 TileMapLayer、不用节点，一个 _draw() 全画完 —— 它每帧都在变，
## 建节点反而更贵（docs/pitfalls.md 2.3）。
##
## ★ 只读逻辑状态 + 只画。
## ★ 选中单位时**不画**攻击距离 / 警戒半径那两个圈（按需求去掉；数值仍然在
##   config 与单位详情里，只是不再铺满屏幕）。
extends Node2D

const ConfigRes = preload("res://logic/config.gd")
const PaletteRes = preload("res://view/palette.gd")

var cfg: ConfigRes = null
var world = null

## 由 input_controller 塞进来的纯本地 UI 状态
var hover_tile: Vector2i = Vector2i(-1, -1)
var hover_valid: bool = false
var build_type: String = ""          # '' | 'wall' | 'tower'
var move_marks: Array[Vector2] = []  # 最近一次右键的目标点（格坐标，绿）
var attack_marks: Array[Vector2] = [] # 最近一次「行军攻击」的目标点（格坐标，红）
var debug_aim: bool = false
var mouse_world: Vector2 = Vector2.ZERO


func setup(p_cfg: ConfigRes, p_world) -> void:
	cfg = p_cfg
	world = p_world
	z_index = 20


func _draw() -> void:
	if cfg == null or world == null:
		return
	_draw_attack_lines()
	_draw_move_marks()
	_draw_build_preview()
	_draw_aim_debug()


## 攻击线：单位 → 最近一次开火的目标（单位或建筑），以及箭塔 → 目标
func _draw_attack_lines() -> void:
	for u in world.units:
		if not u.alive or u.attack_flash <= 0.0:
			continue
		var from := PaletteRes.to_px(u.pos, cfg)
		var to := Vector2.ZERO
		if u.last_target != null and u.last_target.alive:
			to = PaletteRes.to_px(u.last_target.pos, cfg)
		elif u.last_building != null and u.last_building.alive:
			to = PaletteRes.to_px(u.last_building.center(), cfg)
		else:
			continue
		var c := cfg.faction_line_color(u.faction, 0.85 * clampf(u.attack_flash, 0.0, 1.0))
		draw_line(from, to, c, 3.0)

	for b in world.building_list:
		if not b.alive or b.type != "tower" or b.flash <= 0.0:
			continue
		if b.last_target == null or not b.last_target.alive:
			continue
		var from_b := PaletteRes.to_px(b.center(), cfg)
		var to_b := PaletteRes.to_px(b.last_target.pos, cfg)
		draw_line(from_b, to_b, cfg.faction_line_color(b.owner, 0.8), 2.5)


## 移动目标点（绿圈 + 十字）与行军攻击目标点（红圈 + 叉）
func _draw_move_marks() -> void:
	for m in move_marks:
		var p := PaletteRes.to_px(m, cfg)
		draw_arc(p, cfg.cell_px * 0.22, 0.0, TAU, 24, Color(0.6, 1.0, 0.7, 0.85), 2.0)
		draw_line(p + Vector2(-6, 0), p + Vector2(6, 0), Color(0.6, 1.0, 0.7, 0.85), 1.5)
		draw_line(p + Vector2(0, -6), p + Vector2(0, 6), Color(0.6, 1.0, 0.7, 0.85), 1.5)
	for m2 in attack_marks:
		var q := PaletteRes.to_px(m2, cfg)
		var c := Color(1.0, 0.45, 0.4, 0.9)
		draw_arc(q, cfg.cell_px * 0.26, 0.0, TAU, 28, c, 2.0)
		# 叉：与移动的十字区分开，一眼能看出这是「行军攻击」
		draw_line(q + Vector2(-7, -7), q + Vector2(7, 7), c, 2.0)
		draw_line(q + Vector2(-7, 7), q + Vector2(7, -7), c, 2.0)


## 建造预览：绿 = 可建，红 = 不可建
func _draw_build_preview() -> void:
	if build_type == "" or hover_tile.x < 0:
		return
	var r := PaletteRes.tile_rect(hover_tile.x, hover_tile.y, cfg)
	var ok: bool = world.can_build_at(hover_tile.x, hover_tile.y)
	var c := Color(0.45, 1.0, 0.5, 0.55) if ok else Color(1.0, 0.4, 0.4, 0.55)
	draw_rect(r, Color(c.r, c.g, c.b, 0.18), true)
	draw_rect(r, c, false, 2.5)


## 坐标调试准星（G 键）：红叉 = 鼠标世界坐标，绿圈 = 判定出的地块中心。
## 两者必须重合 —— HTML 版就是靠它抓住 DPR 坐标错位的。
func _draw_aim_debug() -> void:
	if not debug_aim:
		return
	var w := PaletteRes.to_px(mouse_world, cfg)
	var tile := Vector2i(floori(mouse_world.x), floori(mouse_world.y))
	var center := PaletteRes.to_px(Vector2(float(tile.x) + 0.5, float(tile.y) + 0.5), cfg)
	draw_line(w + Vector2(-9, 0), w + Vector2(9, 0), Color(1, 0.3, 0.3, 0.95), 2.0)
	draw_line(w + Vector2(0, -9), w + Vector2(0, 9), Color(1, 0.3, 0.3, 0.95), 2.0)
	draw_arc(center, cfg.cell_px * 0.42, 0.0, TAU, 40, Color(0.4, 1.0, 0.5, 0.95), 2.0)
