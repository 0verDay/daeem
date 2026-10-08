## projectile_view_3d.gd —— 3D 射箭投掷物：**一个小方块 + 一条短线拖尾**
##
## ★★ 它只读 `world.projectiles`（逻辑层的权威状态，见 logic/projectile.gd）：
##   地面位置由逻辑给（`p.pos = start.lerp(end, t)`），这里**只负责画** ——
##   索敌、命中结算、冷却全在逻辑层，视图一个字都不碰。
##
## ★★ 抛物线是**纯表现**：逻辑只走地面直线，这里按**同一个进度 `t`** 把方块抬高
##   `arc_h · 4t(1−t)`（`arc_h` = 起点↔终点距离 × render.projectile_arc_ratio）。
##   于是「看到的命中」与「逻辑的命中」**同帧**。
##
## ★ 拖尾 = 最近 N 个位置的折线（N = render.projectile_trail_len）。位置本身带抛物线
##   高度 ⇒ 拖尾天然跟着曲线弯曲（用户口径：一段短线在方块后方）。
##
## ★ 对象池：每个投掷物占一个 slot（方块 MeshInstance3D + 拖尾 ImmediateMesh），
##   离场归还 —— **不在每帧 new / queue_free**（pitfalls 2.3）。
##
## ★ 迷雾：只画「本机阵营」或「该格对玩家可见」的投掷物（不暴露雾里的敌人）。
extends Node3D

const ConfigRes = preload("res://logic/config.gd")
const FactionRes = preload("res://logic/faction.gd")

var cfg: ConfigRes = null
var world = null
var palette = null

var _box: BoxMesh = null
## 投掷物对象 → slot（Dictionary）。用对象本身当键，命中即消失 ⇒ 键自然回收。
var _slots: Dictionary = {}
var _free: Array = []
var _mats: Dictionary = {}
var _trail_mat: StandardMaterial3D = null

## 视觉常量（setup 里读一次，别每帧 `cfg.num`）
var _arc_ratio: float = 0.18
var _trail_len: int = 6
var _base_h: float = 44.8
var _arc_max: float = 153.6

## 诊断（只有测试读它）——「画出来的东西必须留下可数的痕迹」
var projectile_count: int = 0
var visible_projectile_count: int = 0
var trail_segments_last_frame: int = 0
var slots_created: int = 0


func setup(p_cfg: ConfigRes, p_world, p_palette) -> void:
	cfg = p_cfg
	world = p_world
	palette = p_palette
	var cell: float = palette.cell_size()
	var size: float = maxf(1.0, cell * cfg.num("render.projectile_size", 0.10))
	_arc_ratio = maxf(0.0, cfg.num("render.projectile_arc_ratio", 0.18))
	_trail_len = maxi(2, int(cfg.num("render.projectile_trail_len", 6.0)))
	# 起点/终点也离地一点（约 1/3 格，胸口高度），免得方块一半陷进地面
	_base_h = cell * 0.35
	# 拱高上限：最多抬 ~1.2 格，远距离也不至于拱得离谱
	_arc_max = cell * 1.2

	_box = BoxMesh.new()
	_box.size = Vector3(size, size, size)

	_trail_mat = StandardMaterial3D.new()
	_trail_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_trail_mat.vertex_color_use_as_albedo = true
	_trail_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_trail_mat.cull_mode = BaseMaterial3D.CULL_DISABLED


func _mat_for(faction: String) -> StandardMaterial3D:
	var hit: Variant = _mats.get(faction, null)
	if hit != null:
		return hit
	# 提亮一档：小方块要在地面/单位上看得清
	var col: Color = cfg.faction_color(faction, "main")
	var bright := Color(lerpf(col.r, 1.0, 0.35), lerpf(col.g, 1.0, 0.35), lerpf(col.b, 1.0, 0.35), 1.0)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = bright
	m.cull_mode = BaseMaterial3D.CULL_BACK
	_mats[faction] = m
	return m


func _acquire() -> Dictionary:
	if not _free.is_empty():
		var slot: Dictionary = _free.pop_back()
		(slot["mesh"] as MeshInstance3D).visible = true
		(slot["trail"] as MeshInstance3D).visible = true
		(slot["hist"] as Array).clear()
		return slot
	var mesh := MeshInstance3D.new()
	mesh.mesh = _box
	add_child(mesh)
	var im := ImmediateMesh.new()
	var trail := MeshInstance3D.new()
	trail.mesh = im
	trail.material_override = _trail_mat
	add_child(trail)
	slots_created += 1
	return {"mesh": mesh, "trail": trail, "im": im, "hist": []}


func _release(slot: Dictionary) -> void:
	(slot["mesh"] as MeshInstance3D).visible = false
	(slot["trail"] as MeshInstance3D).visible = false
	(slot["im"] as ImmediateMesh).clear_surfaces()
	(slot["hist"] as Array).clear()
	_free.append(slot)


## 每帧同步（`game_scene3d._process` 在 `world.tick` 与 `units.sync` 之后调）。
func sync() -> void:
	projectile_count = world.projectiles.size() if world != null else 0
	visible_projectile_count = 0
	trail_segments_last_frame = 0
	if world == null or palette == null or _box == null:
		return

	# 这一帧还在场上、且对玩家可见的投掷物（对象引用作键）—— 用来回收消失的 slot
	var seen: Dictionary = {}
	for p in world.projectiles:
		if not _visible_to_me(p):
			continue
		seen[p] = true
		var slot: Dictionary = _slots.get(p, {})
		if slot.is_empty():
			slot = _acquire()
			_slots[p] = slot
		var w: Vector3 = _visual_pos(p)
		var mesh: MeshInstance3D = slot["mesh"]
		mesh.transform = Transform3D(Basis(), w)
		mesh.material_override = _mat_for(String(p.faction))
		_update_trail(slot, w, String(p.faction))
		visible_projectile_count += 1

	# 回收：这一帧不在场上（已命中 / 已消失 / 被迷雾挡住）的投掷物，把 slot 还回池子
	for p in _slots.keys():
		if not seen.has(p):
			_release(_slots[p])
			_slots.erase(p)


## 方块在 3D 里的位置：逻辑地面点 + 抛物线抬升（用逻辑的同一个进度 `t`）。
func _visual_pos(p) -> Vector3:
	var w: Vector3 = palette.to_world(p.pos)
	var dist: float = p.start.distance_to(p.end)
	var arc: float = minf(dist * palette.cell_size() * _arc_ratio, _arc_max)
	w.y = _base_h + arc * 4.0 * p.t * (1.0 - p.t)
	return w


## 拖尾：把当前位置压进环形历史，重建一条折线（最近 N 个点连起来）。
func _update_trail(slot: Dictionary, w: Vector3, faction: String) -> void:
	var hist: Array = slot["hist"]
	hist.append(w)
	while hist.size() > _trail_len:
		hist.pop_front()
	var im: ImmediateMesh = slot["im"]
	im.clear_surfaces()
	if hist.size() < 2:
		(slot["trail"] as MeshInstance3D).visible = false
		return
	(slot["trail"] as MeshInstance3D).visible = true
	var base: Color = cfg.faction_color(faction, "main")
	# 越靠头（最新）越亮：拖尾从「淡淡的一段」收到方块身上
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in hist.size():
		var tt: float = float(i) / float(hist.size() - 1)
		im.surface_set_color(Color(base.r, base.g, base.b, 0.12 + 0.78 * tt))
		im.surface_add_vertex(hist[i])
	im.surface_end()
	trail_segments_last_frame += hist.size() - 1


func _visible_to_me(p) -> bool:
	if world == null or world.fog == null or cfg == null:
		return true
	if not cfg.fog_enabled:
		return true
	if FactionRes.is_player_faction(String(p.faction)):
		return true
	return world.fog.tile_visible(world.my_faction, int(p.pos.x), int(p.pos.y))
