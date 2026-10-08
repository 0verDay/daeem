## order_flag_view_3d.gd —— 右键指令在目标点插的 **3D 旗子**（**无碰撞**，纯表现）
##
## ★★ 取代旧的「屏幕空间两个圈」（`overlay_view_3d._draw_move_marks`）：
##   现在是立在目标点上的 3D 旗子 —— **移动 = 绿**、**行军 = 黄**（config 的
##   `render.flag_move_color` / `flag_attack_color`）。
##
## ★★ 生命周期（谁插、谁收）：
##   · **插**：`game_scene3d._on_command()` 收到本机的 `move` / `attack_move` 命令时调 `plant()`；
##     每道新命令**替换**当前唯一那面旗（与旧 `clear_marks()` 的「只留最新」同一条口径）。
##   · **收**：`sync()` 每帧问一句「这道命令的单位全完成了吗」——**全完成才收旗**。
##     判据读逻辑（不发明规则）：对命令里的每个单位，`not alive` **或**
##     （`not u.moving` **且** `not u.has_attack_move`）就算它完成
##     （行军攻击的完成标志就是 `has_attack_move`，见 logic/combat.gd）。
##   · `attack` / `stop` 命令 → `game_scene3d` 直接 `clear()`（那不是「到点」的指令）。
##
## ★ 只读 `world`，不改任何逻辑状态；节点上没有 CollisionObject ⇒ 天然无碰撞。
extends Node3D

const ConfigRes = preload("res://logic/config.gd")

var cfg: ConfigRes = null
var world = null
var palette = null

var _node: Node3D = null
var _cloth: MeshInstance3D = null
var _mat_move: StandardMaterial3D = null
var _mat_attack: StandardMaterial3D = null

## 当前旗子的状态
var kind: String = ""
var ids: Array = []
var active: bool = false

## 诊断（只有测试读它）
var flags_planted: int = 0


func setup(p_cfg: ConfigRes, p_world, p_palette) -> void:
	cfg = p_cfg
	world = p_world
	palette = p_palette
	var cell: float = palette.cell_size()
	var h: float = maxf(cell * 0.05, cell * cfg.num("render.flag_height", 0.5))
	var pole_r: float = maxf(0.5, cell * 0.015)
	var cloth_w: float = cell * 0.22
	var cloth_h: float = cell * 0.14

	var pole := CylinderMesh.new()
	pole.top_radius = pole_r
	pole.bottom_radius = pole_r
	pole.height = h
	pole.radial_segments = 6
	pole.rings = 1
	var pole_mat := StandardMaterial3D.new()
	pole_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pole_mat.albedo_color = Color(0.92, 0.92, 0.95, 1.0)
	var pole_mi := MeshInstance3D.new()
	pole_mi.mesh = pole
	pole_mi.material_override = pole_mat
	pole_mi.position = Vector3(0.0, h * 0.5, 0.0)     # 底边贴地

	# 旗面：一块小方片，挂在杆顶、向 +X 伸出（cull_disabled ⇒ 两面都看得见）
	var cloth := QuadMesh.new()
	cloth.size = Vector2(cloth_w, cloth_h)
	_mat_move = _make_mat(ConfigRes.parse_color(cfg.str_val("render.flag_move_color", "#4cd964")))
	_mat_attack = _make_mat(ConfigRes.parse_color(cfg.str_val("render.flag_attack_color", "#e6c200")))
	_cloth = MeshInstance3D.new()
	_cloth.mesh = cloth
	_cloth.material_override = _mat_move
	_cloth.position = Vector3(cloth_w * 0.5, h - cloth_h * 0.5, 0.0)

	_node = Node3D.new()
	_node.name = "OrderFlag"
	_node.add_child(pole_mi)
	_node.add_child(_cloth)
	_node.visible = false
	add_child(_node)


func _make_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


## 在 `pos`（格）插一面旗；`ids` = 这道命令的单位 id（用来判「完成」）。
## ★ 每道新命令替换当前那面旗（只留最新）。
func plant(p_kind: String, pos: Vector2, p_ids: Array) -> void:
	kind = p_kind
	ids = p_ids.duplicate()
	active = true
	flags_planted += 1
	if _node == null or palette == null:
		return
	_node.position = palette.to_world(pos)
	_node.visible = true
	_cloth.material_override = _mat_attack if kind == "attack_move" else _mat_move


## 收旗（命令完成 / attack / stop）。
func clear() -> void:
	active = false
	ids = []
	if _node != null:
		_node.visible = false


## 每帧同步：命令完成就收旗（判据见文件头）。
func sync() -> void:
	if _node == null:
		return
	if not active:
		_node.visible = false
		return
	if _all_done():
		clear()
		return
	_node.visible = true


## 这道命令的单位是不是**全部完成**了（`not alive` 或「停下且不在行军攻击」）。
func _all_done() -> bool:
	if ids.is_empty():
		return true
	if world == null:
		return false
	for id in ids:
		var u = world.unit_by_id(String(id))
		if u != null and u.alive and (u.moving or u.has_attack_move):
			return false
	return true
