## game_scene.gd —— 游戏内场景：装配 world + view + hud，跑主循环
##               （对应 HTML 版 main.js 的 init / loop / bindInput）
##
## ★ 这个文件是从 view/main.gd **整段搬过来**的，只改了一件事：
##   建世界的时机从「启动时」变成「玩家在主界面按下 test 之后」。
##   开场那两页（白屏入场页 / 主界面）在 view/start_screen.gd，
##   由 view/main.gd 负责把两者接起来 —— 本文件不认识菜单，也不该认识。
##
## ★ 仍然只有一处主循环（就是这里的 _process）：菜单没有自己的 _process。
##
## 本文件只做三件事：
##   1. 建逻辑世界（logic/World）
##   2. 建渲染节点并每帧同步
##   3. 把输入 → 命令 → 逻辑，把逻辑事件 → HUD
## **不在这里写任何玩法规则** —— 规则全在 logic/。
##
## 调试句柄：控制台里 `RTS`（等价于 HTML 版的 window.RTS）。
## 无头测试用不上它，但手玩调参时非常有用（改数值不必重启：RTS.cfg 就是那份配置对象）。
extends Node2D

const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const PaletteRes = preload("res://view/palette.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")
const TerrainViewRes = preload("res://view/terrain_view.gd")
const ZoneViewRes = preload("res://view/zone_view.gd")
const BuildingViewRes = preload("res://view/building_view.gd")
const UnitViewRes = preload("res://view/unit_view.gd")
const OverlayRes = preload("res://view/overlay.gd")
const CameraRigRes = preload("res://view/camera_rig.gd")
const InputControllerRes = preload("res://view/input_controller.gd")
const HudRes = preload("res://view/hud.gd")

const MAP_PATH := "res://data/test_map.json"

var cfg: ConfigRes = null
var world = null
var cam: Camera2D = null

var terrain_view: Node2D = null
var zone_view: Node2D = null
var building_view: Node2D = null
var unit_view: Node2D = null
var overlay: Node2D = null
var camera_rig: Control = null
var input_ctrl: Control = null
var hud: CanvasLayer = null

var _font: Font = null

## 每帧推进逻辑的开关（暂停时关掉；渲染与相机照常跑）
var _running: bool = true


## 进游戏（由 main.gd 在玩家按下 test 时调用一次）。
##
## @param map_path 载入哪张地图（默认 `MAP_PATH`）。
##        ★ 这个参数是**给基准脚本用的测试缝**：`tests/bench_fps.gd` 要在
##          「方案里的 100×100 地图」上量实机帧率 —— 默认那张 27×22 的图上
##          塞 1000 个单位是 1.7 个/格，密度完全失真（碰撞成本会爆掉）。
##          游戏本身永远用默认值。
## @return bool 是否装配成功（配置 / 地图载入失败时返回 false，调用方不必再往下走）
func start(map_path: String = MAP_PATH) -> bool:
	cfg = ConfigRes.load_default()
	if cfg == null:
		push_error("配置载入失败，游戏无法启动：%s" % ConfigRes.last_error)
		return false

	world = WorldRes.create(cfg, map_path)
	if world == null:
		push_error("地图载入失败，游戏无法启动")
		return false

	_build_view()
	_build_hud()
	_build_debug_handles()

	# ★ 开场不再往界面上推任何文案：详细信息栏按需求只显示选中对象与资源，
	#   事件日志整块删掉了，所以「大本营位于 (x, y)」「按 1/2/3…」这类提示都没有去处。
	#   逻辑层的事件仍然在 world.tick() 的返回值里（测试在用），只是没人显示它们。

	# 开场就把 1 号将领选中并放到镜头里，玩家一进来就知道该干什么
	if world.units.size() > 0:
		input_ctrl.select_units([world.units[0]])
		camera_rig.center_on_px(PaletteRes.to_px(world.units[0].pos, cfg))

	return true


func _build_view() -> void:
	cam = Camera2D.new()
	cam.name = "Camera2D"
	add_child(cam)
	cam.make_current()

	# 绘制顺序：地形 -100 / 区块 -50 / 建筑 0 / 单位 10 / 覆盖层 20
	terrain_view = TerrainViewRes.new()
	terrain_view.name = "TerrainView"
	terrain_view.z_index = -100
	add_child(terrain_view)
	terrain_view.setup(cfg, world.map)

	_font = FontLoaderRes.load_font(cfg)

	zone_view = ZoneViewRes.new()
	zone_view.name = "ZoneView"
	zone_view.z_index = -50
	add_child(zone_view)
	zone_view.setup(cfg, world, _font, 12)

	building_view = BuildingViewRes.new()
	building_view.name = "BuildingView"
	building_view.z_index = 0
	add_child(building_view)
	building_view.setup(cfg, world)

	unit_view = UnitViewRes.new()
	unit_view.name = "UnitView"
	unit_view.z_index = 10
	add_child(unit_view)
	unit_view.setup(cfg, world)

	overlay = OverlayRes.new()
	overlay.name = "Overlay"
	overlay.z_index = 20
	add_child(overlay)
	overlay.setup(cfg, world)

	camera_rig = CameraRigRes.new()
	camera_rig.name = "CameraRig"
	add_child(camera_rig)
	camera_rig.setup(cfg, cam, world.map)

	input_ctrl = InputControllerRes.new()
	input_ctrl.name = "InputController"
	add_child(input_ctrl)
	input_ctrl.setup(cfg, world, camera_rig)

	input_ctrl.command_issued.connect(_on_command)
	input_ctrl.local_ui_changed.connect(_on_local_ui_changed)
	# ★ 不再接 input_ctrl.toast：事件日志整块删掉了，toast 目前没有显示窗口。
	#   信号本身留着（它是输入层的反馈通道），以后要加浮动提示只需在这里接上。


func _build_hud() -> void:
	var theme := FontLoaderRes.build_theme(cfg, 15)
	hud = HudRes.new()
	hud.name = "Hud"
	add_child(hud)
	hud.setup(cfg, world, input_ctrl, theme, camera_rig)


func _build_debug_handles() -> void:
	# 与 HTML 版的 window.RTS 对应：手玩调参用
	Engine.set_meta("RTS", self)


func _process(dt: float) -> void:
	# ★ 世界还没建（start() 尚未被调用）时直接返回：
	#   节点是进游戏那一刻才挂上来的，这里是第二道保险，防止以后有人在别处提前 add_child。
	if world == null or input_ctrl == null:
		return

	input_ctrl.poll_mouse()
	_sync_pause()
	camera_rig.update(dt)

	# 键盘平移：**只剩方向键**。
	# ★ W / A / S / D 已经从镜头平移里拿掉（UI 改版时定的）：那四个键交给右下命令卡，
	#   否则「建筑页按 W = 建箭塔」会和「W = 向上平移」打架。
	#   现在鼠标的移动手段是：方向键 + 鼠标推到屏幕边缘滚屏（见下面的 set_mouse）。
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_DOWN):
		dir.y += 1.0
	camera_rig.add_pan(dir)
	camera_rig.set_space_held(Input.is_key_pressed(KEY_SPACE))

	# 边缘滚屏的开关条件（camera_rig 的 _mouse_inside）。
	# ★ 这个方法以前**从来没有被调用过**，于是边缘滚屏实际上一直是死的 ——
	#   现在接上：鼠标在窗口内、且不在可点控件上时才滚。
	#   ⚠️ 判定必须是「可点控件」而不是「所有 HUD 面板」：底栏把屏幕下沿整个盖住了，
	#      若连详细信息面板也让路，鼠标就永远滚不到地图下方。
	var mouse_screen := get_viewport().get_mouse_position()
	var in_window := Rect2(Vector2.ZERO, get_viewport_rect().size).has_point(mouse_screen)
	camera_rig.set_mouse(in_window and not hud.blocks_edge_scroll(mouse_screen), mouse_screen)

	# ★ 小地图正在被拖着走 → 这一帧只让「拖动」改相机。
	#   小地图贴着屏幕左下角，而最外圈永远允许边缘滚屏（那是所有贴边控件的共同规则），
	#   两条路同时改相机会让画面贴着下沿发抖 —— 见 camera_rig._ui_dragging_camera。
	#   ⚠️ 判据是**拖动**（越过阈值之后），不是「按着」：按下但没动的那一下是单击，
	#      单击时边缘滚屏照旧（否则按住小地图不动、鼠标又贴着边时画面会突然停一拍）。
	camera_rig.set_ui_dragging(hud.minimap != null and hud.minimap.is_dragging())

	# 逻辑推进（暂停时冻结；渲染与相机不受影响）
	if _running:
		# ★★ 必须夹住 dt：帧一慢，dt 就变大，而 dt 越大这一帧要做的活越多
		#    （位移按 dt 算、拐点跨得更多、认账计时也走得更远）——于是帧更慢。
		#    这就是经典的「死亡螺旋」：实测 1000 单位在某次实机运行里
		#    单帧从 86 ms 一路滚到 666 ms，而夹住之后稳定在十几毫秒。
		#    夹住 dt 的代价是「卡顿时时间变慢」而不是「卡顿被放大」——
		#    对即时战略来说后者才是不可接受的。
		var logic_dt: float = minf(dt, cfg.sim_max_dt)
		# ★ tick 的返回值是逻辑事件（击杀 / 建筑被拆 / 招募…）。
		#   现在只处理两件事：招募被拒 → 左栏红字；招募完成 → 把新兵选上
		#   （见 _consume_events）。其余事件照旧只被读走（读走 = 清空缓冲），
		#   测试与将来的日志都靠这条边界。
		var events: Array = world.tick(logic_dt)
		_consume_events(events)
		input_ctrl.drop_dead_selection()

	# 逻辑 → 渲染：每帧读状态同步节点（view 从不改逻辑）
	unit_view.sync(dt)
	building_view.sync()
	unit_view.set_selection(_selected_ids())
	# ★ 选中的建筑可能是一整批（框选建筑）—— 它们**都**要点亮金色外框
	building_view.set_selected_buildings(input_ctrl.selected_buildings)

	# 把纯本地的 UI 状态交给覆盖层画
	overlay.hover_tile = input_ctrl.hover_tile
	overlay.hover_valid = input_ctrl.hover_valid
	overlay.build_type = input_ctrl.build_type
	overlay.move_marks = input_ctrl.move_marks
	overlay.attack_marks = input_ctrl.attack_marks
	overlay.debug_aim = input_ctrl.debug_aim
	overlay.mouse_world = input_ctrl.mouse_world
	# ★ 框选矩形（纯本地状态，只画不改逻辑）
	overlay.drag_active = input_ctrl.drag_active
	overlay.drag_rect = input_ctrl.drag_box()
	zone_view.show_names = input_ctrl.show_zone_names
	overlay.queue_redraw()
	zone_view.sync()


func _selected_ids() -> Array:
	var ids: Array = []
	for u in input_ctrl.selected_units:
		ids.append(u.id)
	return ids


## 暂停时把世界冻住（渲染照常）
func _sync_pause() -> void:
	_running = not input_ctrl.paused


# ------------------------------------------------------------------
# 输入 → 命令 → 逻辑
# ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if input_ctrl == null:
		return
	if event is InputEventKey:
		# ★ 先问命令卡（Q/W/E/A/S/D/Z/X/C）：**有内容的格子**优先于其它绑定，
		#   空格子会自动落到 input_controller 的那套老快捷键上。
		var used := false
		if hud != null:
			used = hud.handle_key(event)
		if used or input_ctrl.handle_key(event):
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		# ★★ 底栏（详细信息 / 阵营 / 命令卡 / 页签，**不含**左下小地图）上
		#    **不许用滚轮缩放地图**（用户需求）。
		#    判据是**这一下滚轮自己的坐标**（不是每帧缓存的鼠标位置）：
		#    鼠标移出底栏之后，下一下滚动就照常缩放 —— 没有需要复位的状态。
		#    ⚠️ 走 hud 的几何查询（hud 认识 ui_layout），input_controller 不认识 HUD，
		#       所以这一问放在这一层，命令流那条路（handle_mouse_button）一行不改。
		if _is_wheel(event as InputEventMouseButton) and hud != null \
				and hud.blocks_wheel_zoom((event as InputEventMouseButton).position):
			get_viewport().set_input_as_handled()
			return
		if input_ctrl.handle_mouse_button(event):
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		input_ctrl.poll_mouse()
		# ★ 框选那条状态机也要吃移动事件（越过阈值才算「在拖框」）
		input_ctrl.handle_mouse_motion(event)


## 这个鼠标按键是不是**滚轮**（只有滚轮会缩放地图；其它按键照旧交给 input_controller）
func _is_wheel(event: InputEventMouseButton) -> bool:
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, \
		MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT:
			return true
	return false


## ★ 唯一改逻辑状态的地方：把命令交给 command_processor
func _on_command(cmd: Dictionary) -> void:
	if world == null:
		return
	CommandRes.apply(world, cfg, cmd)


func _on_local_ui_changed() -> void:
	# 本地 UI 变了只需要重画，不碰逻辑
	unit_view.set_selection(_selected_ids())
	building_view.set_selected_buildings(input_ctrl.selected_buildings)


## 逻辑事件 → 界面文案 / 本地状态。★ **只有这里**把事件翻成中文（逻辑层不写 UI 文案）。
##
## 现在处理五件事：
##   · `recruit_rejected` → 左栏那行红字（招募被拒的原因要给玩家看见）；
##   · `unit_recruited`   → **如果玩家此刻仍选中着那个将领，新兵也一起被选上**
##     （需求原话；选中是纯本地状态，所以落在 input_controller.notify_unit_recruited）；
##   · `order_rejected`   → 「将领正在招募，它和它的部队不接受指令」（同上那行红字）；
##   · `tech_rejected`    → ★ 「最多只能同时启用 3 个科技」（点第 4 个科技时）；
##   · `upgrade_rejected` → ★ 升级 / 特化被拒（满级 / 读条中 / 钱不够 / 不是自己的）。
## 其它事件（击杀 / 建筑被拆…）暂时没有界面画它们，
## 要恢复日志的话在这里加翻译、再给 detail_panel 加一块列表即可。
func _consume_events(events: Array) -> void:
	if hud == null:
		return
	for evt in events:
		match String(evt.get("type", "")):
			"recruit_rejected":
				# ★ max 来自事件（区划招募的队列上限可能与「将领招募」那条不同）；
				#   没带（0）时 hud 用单位那条表的上限。
				hud.show_notice(hud.recruit_reject_text(
					String(evt.get("reason", "")), String(evt.get("kind", "")),
					int(evt.get("max", 0))))
			"order_rejected":
				hud.show_notice(hud.order_reject_text(String(evt.get("reason", ""))))
			"tech_rejected":
				# ★ 科技启用被拒（满 3 条）。本地那一下已经给过一句提示了，
				#   这条是**权威侧**的同一句话 —— 两条同文案，所以玩家看到的还是一句。
				hud.show_notice(hud.tech_reject_text(String(evt.get("reason", ""))))
			"upgrade_rejected":
				# ★ 建筑升级 / 区划特化被拒（拒因码见 logic/upgrade.gd 的那几处判定）
				hud.show_notice(hud.upgrade_reject_text(String(evt.get("reason", ""))))
			"unit_recruited":
				input_ctrl.notify_unit_recruited(evt.get("leader", null), evt.get("unit", null))
