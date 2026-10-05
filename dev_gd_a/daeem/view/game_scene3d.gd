## game_scene3d.gd —— 3D 游戏内场景（本版重建）：装配 world + 3D 视图 + HUD
##
## ★★ 与旧的 2D `game_scene.gd` 的分工完全一样（见 architecture.md 第一节）：
##   逻辑是纯数据（`logic/world.gd`），渲染是场景节点，两者只通过「读状态 + 收命令」相连。
##   **本文件只做三件事**：建世界、建 3D 视图并每帧同步、把输入 → 命令 → 逻辑。
##
## ★ 3D 场景树（本版）：
##     GameScene3D (Node3D)
##       ├── Camera3D            ← 固定俯角：沿自身坐标轴平移 + 缩放，**不俯仰旋转**
##       ├── GroundView3D        ← 一块 PlaneMesh + 一张烘出来的地形贴图（1 次 draw call）
##       ├── UnitView3D          ← MultiMeshInstance3D + billboard（1000 单位一个批次）
##       └── Overlay2D (CanvasLayer) ← 选中圈 / 标记 / 拖框（屏幕空间，用 palette.to_px 定位）
extends Node3D

const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const MapLibraryRes = preload("res://logic/map_library.gd")
const PaletteRes = preload("res://view/palette.gd")
const GroundViewRes = preload("res://view/ground_view.gd")
const UnitViewRes = preload("res://view/unit_view_3d.gd")
const BuildingViewRes = preload("res://view/building_view_3d.gd")
const Overlay3DRes = preload("res://view/overlay_view_3d.gd")
const InputControllerRes = preload("res://view/input_controller.gd")
const HudRes = preload("res://view/hud.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")
const InteractionRes = preload("res://view/game_interaction.gd")
const CommandRes = preload("res://logic/command_processor.gd")
## ★ 只为复用 uild_roster()（战役席位规则，见 start_level 的说明）——**不实例化它**
const Game2DRes = preload("res://view/game_scene.gd")

const MAP_PATH := MapLibraryRes.FALLBACK_MAP_PATH

## ★ 与 2D 版同名的两条流程信号：main.gd 原样接得上（不需要为 3D 改上层）。
signal fullscreen_toggled
signal return_to_menu_requested

var cfg: ConfigRes = null
var world = null
var cam: Camera3D = null
## ★ 投影助手（`view/palette.gd` 的实例）：所有「格 ↔ 屏幕」的换算都问它
var palette = null
var ground = null
var units = null
## ★ unit_view 是**别名**：2D 版叫这个名字，界面/测试按它读「单位那一层」。
##    3D 版内部叫 units（一个 MultiMesh 层）—— 两个名字都给，省得调用方各记一套。
var unit_view = null
var buildings = null
var overlay = null
var input_ctrl = null
var hud: CanvasLayer = null
## ★★ 与渲染无关的交互核心（game_interaction.gd）：输入路由 / 命令转发 / 事件提示
var interaction = null
## ★ 这一局是从哪一关开的（与 game_interaction.gd 里那份同一个来源；start() 开的局两者为 null）
var level_playing = null
var level_campaign = null
## start_level() 在 _assemble() **之前**记下的关卡，装配时再交给交互核心
var interaction_pending_campaign = null
var interaction_pending_level = null
## 缩放倍率（1.0 = config 里的默认距离；越大 = 相机越远 = 看到越多）
var zoom: float = 1.0

## ---- 相机输入状态（这三样原本住 2D 的 `camera_rig` 里，3D 场景没有那个节点）----
## 为什么必须**整块**移植：漏掉它们的症状是「滚不动 / 拖到地图外」，
## 而那三样正是用户报回来的三个问题（详见 `_camera_update` 的注释）。
## ⚠️ 判据：`camera_rig.gd` 里被 2D 主循环调用的每一个方法，
##    3D 场景都必须有等价物 —— 漏一个是「功能静默缺失」，不报错。
var _mouse_inside: bool = false
var _mouse_pos: Vector2 = Vector2.ZERO
var _space_held: bool = false
var _ui_dragging_camera: bool = false
var _edge_scroll_on: bool = true
## ★★ 地面/迷雾重烘的**节流**（见 _process 里的说明）：每 N 帧查一次
const REBAKE_INTERVAL_FRAMES := 15
var _rebake_tick: int = 0


## 建相机（拆出来是为了让「先建相机、再造投影助手」这条顺序显式可见）
func _build_camera() -> void:
	cam = Camera3D.new()
	cam.name = "Camera3D"
	add_child(cam)
	cam.make_current()
	# 先摆到「地图中心」——正式的对准在 start() 里由 center_on_tile() 做
	_place_camera_looking_at(Vector3(
		float(world.map.cols) * cfg.cell_px * 0.5, 0.0,
		float(world.map.rows) * cfg.cell_px * 0.5))


func start(map_path: String = MAP_PATH) -> bool:
	cfg = ConfigRes.load_default()
	if cfg == null:
		push_error("配置载入失败：%s" % ConfigRes.last_error)
		return false
	cfg.set_viewport_size(
		float(ProjectSettings.get_setting("display/window/size/viewport_width", 1920)),
		float(ProjectSettings.get_setting("display/window/size/viewport_height", 1080)))

	world = WorldRes.create(cfg, map_path)
	if world == null:
		push_error("地图载入失败")
		return false

	_assemble()
	return true


## 战役关卡入口（签名与 2D 版**逐字相同** ⇒ `main.gd` 一行不用改）。
##
## ★★ 为什么签名必须一致：`main.gd` 是「流程层」，它同时要能驱动 2D 与 3D 两种场景。
##   本版的做法是**让 3D 场景满足同一份接口**（`start` / `start_level` /
##   两条流程信号 / `_unhandled_input`），而不是去改上层 —— 上层不该知道视角怎么画。
func start_level(campaign, level, my_faction: String) -> bool:
	cfg = ConfigRes.load_default()
	if cfg == null:
		push_error("配置载入失败：%s" % ConfigRes.last_error)
		return false
	if level == null:
		push_error("关卡是 null，战役无法启动")
		return false
	cfg.set_viewport_size(
		float(ProjectSettings.get_setting("display/window/size/viewport_width", 1920)),
		float(ProjectSettings.get_setting("display/window/size/viewport_height", 1080)))

	# ★★ `roster` 的拼法**复用 2D 版的 `build_roster()`**，不在这里重写一份。
	#    为什么：那段逻辑里藏着好几条踩出来的契约（「两个可玩阵营都要有家」
	#    「我选的那一方必须排第一 —— `objective.setup()` 拿第一个席位决定打哪条目标」
	#    「真正的 NPC 敌人不进 roster」）。复制一份出来，迟早会与 2D 版不一致，
	#    而那种不一致**只会表现为「某一关莫名判负」**，极难查。
	#    ⇒ 3D 版只负责「把视角画成 3D」，战役席位的规则仍然只有一份实现。
	var roster: Array = Game2DRes.build_roster(level, cfg, my_faction)
	world = WorldRes.create_from_level(cfg, level, my_faction, roster, true)
	if world == null:
		push_error("关卡装配失败（地图 = %s）" % String(level.map_id))
		return false

	# 记下「这一局是从哪一关来的」。★ 它们是**公开变量**（与 `world` / `cfg` 同一个读法：
	#   本工程不给自己持有的状态套一层 getter），界面与测试直接读 `game.level_playing`。
	# ★ 两处都写：交互核心里那份（供共用逻辑读）+ 本场景上那份（供界面与测试读）。
	interaction_pending_campaign = campaign
	interaction_pending_level = level

	_assemble()
	return true


## 把世界接到 3D 视图上（`start` / `start_level` 共用这一段）。
##
## ★ 抽出来的理由：两条入口的差别**只在「怎么建 world」那一处**，
##   视图装配必须完全一致 —— 复制一份迟早会不一样（2D 版也是这么分的）。
func _assemble() -> void:
	_build_camera()
	palette = PaletteRes.create(cfg, cam)

	ground = GroundViewRes.new()
	ground.name = "GroundView3D"
	add_child(ground)
	ground.setup(cfg, world, palette)

	units = UnitViewRes.new()
	units.name = "UnitView3D"
	add_child(units)
	units.setup(cfg, world, palette)
	unit_view = units

	buildings = BuildingViewRes.new()
	buildings.name = "BuildingView3D"
	add_child(buildings)
	buildings.setup(cfg, world, palette)

	# 覆盖层（选中圈 / 移动与攻击标记 / 建造预览 / 拖框）：屏幕空间，用 palette 定位
	var layer := CanvasLayer.new()
	layer.name = "OverlayLayer"
	add_child(layer)
	overlay = Overlay3DRes.new()
	overlay.name = "Overlay3D"
	layer.add_child(overlay)
	overlay.setup(cfg, world, palette, units, ground)

	# 输入层：**复用 2D 那版的 input_controller**（它只依赖 palette 的
	# `to_px` / `to_logic` 与一个 `center_on_px` —— 本版用一个轻量替身满足后者）
	input_ctrl = InputControllerRes.new()
	input_ctrl.name = "InputController"
	add_child(input_ctrl)
	input_ctrl.setup(cfg, world, _make_camera_facade(), palette)
	# ★★ 交互接线（本轮补）：界面 → 逻辑那条路。
	#    `command_issued` 是**唯一改逻辑状态**的入口（交给 command_processor）；
	#    `local_ui_changed` 只重画选中，不碰逻辑。
	#    ⚠️ 漏掉这两条的后果**不报错**：科技格点了没反应、招募队列不排
	#      —— 实测就是 test_ui 那 25 条「区划特化」失败的主因。
	input_ctrl.command_issued.connect(_on_command)
	input_ctrl.local_ui_changed.connect(_on_local_ui_changed)

	_build_hud()
	# 交互核心：宿主（本场景）把已建好的东西交给它，之后每帧由它派发事件
	interaction = InteractionRes.new()
	interaction.setup(self)
	interaction.level_campaign = interaction_pending_campaign
	interaction.level_playing = interaction_pending_level
	# ★★ 「这一局是不是从关卡开的」是**流程状态**，两个外壳都要一模一样地回答它，
	#    所以它存在 `game_interaction.gd` 里（`level_playing` / `level_campaign`）。
	#    ⚠️ 漏了这一步不会报错，只会让 `game.level_playing` 恒为 null ——
	#      实测表现为 `test_campaign_test` 那条「记下了这一局是从关卡开的」失败。
	level_playing = interaction.level_playing
	level_campaign = interaction.level_campaign

	# 开场把镜头对准**地图中心**（而不是大本营）
	#
	# ★ 为什么不是大本营：大本营在地图一角，对准它会让整张地图偏到画面一角
	#   （实测：地图只占了右下 1/3，上半屏全是背景）。玩家一进游戏先要看的是
	#   「战场在哪」，具体到自己的家有一键（Home）可去。
	center_on_tile(Vector2(float(world.map.cols) * 0.5, float(world.map.rows) * 0.5))

	# ★★ 开局把第一个单位选上（与 2D 版两条入口**同一条收尾**）。
	#
	# 为什么要有这一步（本轮实测踩到）：没有它，玩家进游戏时**什么都没选中**，
	#   右下命令卡是空的、底栏写着「未选中」—— 而 2D 版一直是选着一个的。
	#   ⚠️ 它的表现形式是**偶发**的：`test_campaign_test` 那条
	#   「开局就选中了一个单位」时红时绿（实测同一命令两次结果不同），
	#   因为选中是纯本地 UI 状态、会被先前跑过的用例影响。
	#   ★ 判据：开局自动选中是**入口的收尾动作**，不是可选项 ——
	#     两个外壳都必须做，否则「进游戏第一眼看到什么」两套不一致。
	if input_ctrl != null and world.units.size() > 0:
		input_ctrl.select_units([world.units[0]])


## 相机替身：`input_controller` 只用到 `center_on_px` 这一个方法。
##
## ★ 为什么不改成「让 input_controller 直接收 Camera3D」：那一改要动 1000 多行的
##   输入层，而它承载着 1000+ 项断言。接口最小化是这里更划算的做法。
func _make_camera_facade() -> Object:
	var f := CameraFacade.new()
	f.scene = self
	return f


class CameraFacade:
	extends RefCounted
	var scene = null

	## 2D 版语义：把镜头中心移到屏幕像素点。3D 版把屏幕点反算成地面点，再平移相机。
	## ★★ 把镜头**精确**移到某个屏幕点对着的那一格上。
	##
	## ⚠️ 路径要精确（用户报的「小地图转移视角位置不准确」就出在这里）：
	##   屏幕点 → 射线求交得到**地面点** → 转成**格** → 用 `center_on_tile_precise`
	##   让「画面中心正好是这一格」。**不要**走「反算地面点再平移」那条 ——
	##   那次往返在透视下有误差（越靠屏幕边缘越大）。
	func center_on_px(screen_px: Vector2) -> void:
		if scene == null:
			return
		scene.center_on_screen_precise(screen_px)

	## ★★ 「把镜头对准这一格」——**小地图点击 / 拖动走的就是它**。
	##
	## ⚠️⚠️ 为什么必须有这一个方法（本轮实测抓到的**真 bug**，症状与用户的
	##   「点小地图转移视角不准」完全一致）：
	##   `minimap._jump_to()` 原来写的是
	##       `camera_rig.center_on_px(Palette2DRes.to_px(格))`
	##   —— 它把**世界像素**当成**屏幕像素**喂进了 `center_on_px`。
	##   · 2D 遗留栈里这两个坐标系**恰好重合**（世界像素 == 屏幕像素），所以那条写法「能用」；
	##   · 3D 里**根本不重合**：`center_on_px` 拿这个数当屏幕点去打射线求交，
	##     于是「点小地图上的某一格」会落到地图上完全不同的一格。
	##   ⇒ 实测误差（27×22 图、1920×1080 视口）：**最大 15.06 格**，最小 0.71 格。
	##
	## ⚠️ 顺带纠正这篇 dev_plan 里的一条**误判**：那里记的「残留误差 ~1.5 格」是
	##   **测量姿势**造出来的假象 —— 无头下鼠标停在 (0,0)、边缘滚屏一直开着，
	##   `await` 一帧就把镜头往左上滚走约半格。**关掉滚屏 + 冻结 `_process` 之后，
	##   `center_on_tile_precise` 的误差是 0.0000 格**（`_place_camera_looking_at`
	##   本身没有「up 与位置不自洽」的问题，那里推的方向是错的）。
	##
	## ★ 修在这一层而不是 `minimap.gd`：小地图**本来就拿着格坐标**
	##   （`to_world(local_pos)` 就是格），让它绕一圈「格 → 世界像素 → 屏幕像素」
	##   只会多出两个可能对不上的换算（本项目那条「换算只有一处」的铁律）。
	## ★ `center_on_tile_precise` 内部已经做了牛顿迭代 + `clamp_look_point()`，
	##   所以出界点会自动被夹到地图边上。
	func center_on_tile(tile: Vector2) -> void:
		if scene != null:
			scene.center_on_tile_precise(tile)

	## ★★ 滚轮缩放：`input_controller` 的滚轮走 `camera_rig.zoom_at(...)`，
	##    而 3D 版的缩放在**场景**上（`game_scene3d.zoom_at`：改相机距离并保持锚点不动）。
	##    ⚠️ 替身漏了这个方法**不报错**，只是「滚轮缩放完全没反应」——
	##      实测是在 `test_view` 的滚轮用例里以 `Nonexistent function 'zoom_at'` 暴露的。
	## ★★ 滚轮缩放：`input_controller` 的滚轮走 `camera_rig.zoom_at(...)`。
	##
	## ⚠️⚠️ **因子必须取倒数**（这是本轮实测出来的一个真缺陷，不是笔误）：
	##   `input_controller` 是按 **2D 的语义**传因子的 —— 向上滚传 `zoom_step`（1.12，
	##   2D 里 `Camera2D.zoom` 越大 = 画面越大 = 拉近）；而 3D 的 `game.zoom` 是
	##   **相机距离倍率**，越大 = 越远 = 画面越小，方向**天然相反**。
	##   不取倒数的话：向上滚变成拉远、向下滚变成拉近（实测 `test_view` 里
	##   「最远视野 = 3.0、最紧 = 0.35」正好反了）。
	##   ★ 修在这一层而不是 `input_controller`：那个文件同时服务 2D 与 3D，
	##     改它会把 2D 的方向弄反 —— 语义差异就地消化掉。
	func zoom_at(screen_pos: Vector2, factor: float) -> void:
		if scene != null:
			scene.zoom_at(screen_pos, 1.0 / factor)

	## ★★ 小地图要的视口尺寸。为什么替身也必须有它：
	##    `minimap.gd` 用 `get_viewport_rect()` 与 `cam` 去**取视口四角**，
	##    而那一步是「视野框画在哪」的唯一来源。缺了它视野框会静默变成 0×0 空矩形
	##    （实测如此，而且**不报任何错**）。
	func get_viewport_rect() -> Rect2:
		if scene == null or scene.cam == null:
			return Rect2()
		# ⚠️ 显式标类型：scene 是无类型引用 ⇒ get_viewport() 推不出类型（第 7 次同类坑）
		var vp: Viewport = scene.cam.get_viewport()
		if vp == null:
			return Rect2()
		return Rect2(Vector2.ZERO, vp.get_visible_rect().size)

	## ★★ `minimap.gd` 里的 `camera_rig.cam` 在 2D 版是 `Camera2D`，3D 版给 `Camera3D`。
	##    安全的原因：`minimap.view_rect_world()` 只在**没有 palette** 时才去读它的
	##    `zoom` / `position`（见那里的分流），3D 路上根本不碰这两个属性。
	var cam: Camera3D:
		get:
			return scene.cam if scene != null else null


## 把镜头中心移到某个**屏幕像素**（精确版：射线求交拿到那一格，再用法对准）。
##
## ★ 与 `center_on_screen` 的区别：那个是「反算地面点再平移」，透视下**有往返误差**；
##   这个先把屏幕点解成格，再用 `center_on_tile_precise` 迭代对准 ⇒ 落点准。
func center_on_screen_precise(screen_px: Vector2) -> void:
	var lg = palette.to_logic(screen_px)
	if lg == null:
		return
	center_on_tile_precise(lg)


## 把镜头中心移到某个**屏幕像素**（保留：语义就是「对准这一格」，内部走精确版）
func center_on_screen(screen_px: Vector2) -> void:
	center_on_screen_precise(screen_px)


## 把镜头中心移到某个**格**
##
## ★★ 做法：保持相机姿态与高度不变，只把「它看向的地面点」搬到目标格。
##   于是「格 → 屏幕」的中心映射恒定 —— 这就是「相机在同一高度」的实现方式。
func center_on_tile(logic_pos: Vector2) -> void:
	if cam == null or palette == null:
		return
	var target: Vector3 = palette.to_world(logic_pos)
	_place_camera_looking_at(target)


func _place_camera_looking_at(target: Vector3) -> void:
	# ★★ up 参数必须是**世界 UP**，不能传「从相机指向目标」的那个方向向量：
	#    后者与视线**共线**，`look_at_from_position` 会警告
	#    「Target and up vectors are colinear」并产生绕本地 Z 轴的不确定旋转（实测踩到）。
	#    俯角由**相机位置**表达（沿 cam_up 退开 d），朝向由 look_at 从
	#    「位置 + 目标 + 世界 UP」推出来。
	var cam_up := Vector3(0.0, sin(cfg.cam_pitch), cos(cfg.cam_pitch)).normalized()
	var d: float = cfg.cam_height * zoom
	# ⚠️ `far` 必须跟着距离走：默认 4000 在距离 6400 时会把地面整个裁掉
	#    （实测症状是「整屏一片背景色」，而且不报任何错）。
	cam.near = 1.0
	cam.far = maxf(cam.far, d * 2.5 + 1000.0)
	cam.look_at_from_position(target + cam_up * d, target, Vector3.UP)
	# ★★ `fov` 必须在 `look_at_from_position()` **之后**设：
	#    实测那个调用会把 fov 重置回默认 75（我原先在它之前设 40，被无声覆盖）。
	cam.fov = rad_to_deg(cfg.cam_fov)


## 每帧主循环：推进逻辑 → 同步视图 → 把本地 UI 状态交给覆盖层。
##
## ★ 这与 2D 版 `game_scene.gd` 的 `_process` 是同一条思路（架构文档第一节）：
##   **world 是权威，视图只读它**；这里不写任何玩法规则。
func _process(dt: float) -> void:
	if world == null or input_ctrl == null:
		return
	# ① 输入：轮询鼠标（只有 input_controller 允许读鼠标）
	input_ctrl.poll_mouse()
	# ② 暂停门：★★ **推进逻辑必须夹在这个门后面**（本轮实测踩到）。
	#    2D 版的口径是「暂停时**逻辑冻结，但渲染与相机照旧**」，暂停键在
	#    `input_ctrl.paused`（不是 world 的字段 —— 逻辑层不知道什么叫暂停）。
	#    ⚠️ 漏了这个门的表现：暂停之后世界还在跑；在测试里则是
	#      「同一条操作被记了两次」（实测 test_ui 报 entries 里两个 zone_specialize）。
	var running: bool = not bool(input_ctrl.paused)
	var events: Array = []
	if running:
		# ★ 必须夹住 dt：帧一慢 dt 就变大，而 dt 越大这一帧做的活越多 ⇒ 帧更慢。
		#   这就是经典的「死亡螺旋」：实测 1000 单位时单帧从 86 ms 滚到 666 ms，
		#   夹住之后稳定在十几毫秒（2D 版为此专门写过注释，同一条教训）。
		var logic_dt: float = minf(dt, cfg.sim_max_dt)
		events = world.tick(logic_dt)
		input_ctrl.drop_dead_selection()
	_consume_events(events)
	# ③ 视图：单位 MultiMesh 每帧重填（位置会变）
	units.sync()
	buildings.sync()
	# ④ 覆盖层：纯本地 UI 状态塞进去，它只画
	overlay.hover_tile = input_ctrl.hover_tile
	overlay.hover_valid = input_ctrl.hover_valid
	overlay.build_type = input_ctrl.build_type
	overlay.move_marks = input_ctrl.move_marks
	overlay.attack_marks = input_ctrl.attack_marks
	overlay.drag_active = input_ctrl.drag_active
	overlay.drag_rect = input_ctrl.drag_box()
	overlay.mouse_world = input_ctrl.mouse_world
	overlay.set_selection(_selected_ids())
	overlay.sync()
	# ⑤ 地面归属 / 迷雾变了就重烘贴图 —— **必须节流**
	#
	# ★★ 为什么（本轮实测的帧率瓶颈之一）：
	#   「变了才重烘」的函数内部虽然会短路（不真的重画那张图），但**判断本身**不便宜：
	#     `ground._zone_signature()` 要遍历全部区块并拼字符串；
	#     `ground._fog_signature()` 要做 18 次 `tile_visible` + 拼字符串。
	#   而这两个数据**一秒钟也变不了几次** ⇒ 每帧判一次就是每帧几百次字符串操作。
	#   ⇒ 每 15 帧（约 0.25 秒）查一次：归属与迷雾的观感延迟在 0.25 秒内，玩家察觉不到。
	_rebake_tick += 1
	if _rebake_tick >= REBAKE_INTERVAL_FRAMES:
		_rebake_tick = 0
		ground.rebake()
	# ⑥ 相机输入（方向键 / 边缘滚屏 / Space 加速 / 夹取）——**整块**在这里
	_camera_update(dt)


## 该被点亮选中圈的单位 id（本机选中 + 选中的敌方单位）
func _selected_ids() -> Array:
	var ids: Array = []
	for u in input_ctrl.selected_units:
		ids.append(u.id)
	if input_ctrl.selected_enemy_kind() == "unit" and input_ctrl.selected_enemy != null:
		ids.append(input_ctrl.selected_enemy.id)
	return ids


## ★★ 相机每帧更新（边缘滚屏 / 方向键 / Space 加速 / 夹取）——**整块从 2D 移植**。
##
## ⚠️⚠️ 为什么这一段必须存在（用户报回来的三个问题全部出自它的缺失）：
##   我第一版只写了「方向键平移」和「滚轮缩放」，而 2D 的 `camera_rig.update()`
##   还含三件事，我**整块漏掉了**：
##     ① **边缘滚屏**（鼠标推到屏幕边缘）⇒ 症状：鼠标移到边缘视图不动；
##     ② **Space 加速**（按住 Space 平移更快）⇒ 症状：长距离移动太慢；
##     ③ **相机夹取** `clamp_position()` ⇒ 症状：小地图长按能把镜头拖到地图外。
##   ★ 判据：`camera_rig.gd` 里被 2D 主循环调用的**每一个**方法，
##     3D 场景都要有等价物。漏掉其中任何一个都是「功能静默缺失」——
##     不报错、测试也不红，只有玩的人会发现。
func _camera_update(dt: float) -> void:
	if cam == null or palette == null:
		return
	# ① 先把「鼠标在不在窗口内 / 有没有压着可点控件」问清楚（与 2D 同一条判据）
	var mouse_screen: Vector2 = get_viewport().get_mouse_position()
	var in_window: bool = Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size).has_point(mouse_screen)
	# ★ 判据必须是「可点控件」而不是「所有 HUD 面板」：底栏把屏幕下沿整个盖住了，
	#   若连详细信息面板也让路，鼠标就永远滚不到地图下方（2D 版为此写过注释）。
	_mouse_inside = in_window and (hud == null or not hud.blocks_edge_scroll(mouse_screen))
	_mouse_pos = mouse_screen
	_space_held = Input.is_key_pressed(KEY_SPACE)
	_ui_dragging_camera = (hud != null and hud.minimap != null and hud.minimap.is_dragging()) \
		or (input_ctrl != null and input_ctrl.is_dragging_box())

	# ② 方向键平移（W/A/S/D **不**参与：它们归右下命令卡，见 2D 版的注释）
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_DOWN):
		dir.y += 1.0
	if dir.length_squared() > 0.0:
		var speed: float = cfg.num("camera.key_pan_speed", 900.0)
		pan_screen(dir.normalized() * speed * dt * (2.5 if _space_held else 1.0))

	# ③ 边缘滚屏（越贴边滚得越快：归一化后取平方，与 2D / HTML 版同一手感）
	if _edge_scroll_on and _mouse_inside and not _space_held and not _ui_dragging_camera:
		var margin: float = cfg.camera_edge_size
		var max_speed: float = cfg.num("camera.edge_max_speed", 1500.0)
		var vp: Vector2 = get_viewport().get_visible_rect().size
		var e := Vector2.ZERO
		if _mouse_pos.x < margin:
			e.x = -_edge_power(margin - _mouse_pos.x, margin)
		elif _mouse_pos.x > vp.x - margin:
			e.x = _edge_power(_mouse_pos.x - (vp.x - margin), margin)
		if _mouse_pos.y < margin:
			e.y = -_edge_power(margin - _mouse_pos.y, margin)
		elif _mouse_pos.y > vp.y - margin:
			e.y = _edge_power(_mouse_pos.y - (vp.y - margin), margin)
		if e.length_squared() > 0.0:
			pan_screen(e * max_speed * dt)

	# ④ 夹取：镜头看向的地面点必须留在地图矩形内
	#    ★ 这是「小地图长按能把镜头拖到地图外」的直接修复。
	clamp_look_point()


func _edge_power(depth: float, margin: float) -> float:
	var tt: float = clampf(depth / maxf(1.0, margin), 0.0, 1.0)
	return tt * tt


## 把「镜头看向的地面点」夹进地图矩形（外接框口径，与 2D 一致）。
##
## ★ 为什么夹的是**看向的点**而不是相机位置：3D 里相机在斜上方，
##   它的 x/z 与「画面中心对着哪一格」差一个偏移；要保证「画面中心不跑出地图」，
##   夹的必须是后者。夹相机位置会让画面中心在贴边时偏出去半屏。
func clamp_look_point() -> void:
	if world == null or palette == null:
		return
	var cell: float = palette.cell_size()
	var cols: float = float(world.map.cols)
	var rows: float = float(world.map.rows)
	var look: Vector3 = _ground_under_screen(_view_center())
	var lp: Vector2 = palette.world_to_logic(look)
	var cx: float = clampf(lp.x, 0.0, cols)
	var cy: float = clampf(lp.y, 0.0, rows)
	if absf(cx - lp.x) < 1e-4 and absf(cy - lp.y) < 1e-4:
		return                      # 没越界，别白摆一次相机（摆相机要重算投影）
	_place_camera_looking_at(Vector3(cx * cell, 0.0, cy * cell))


## F 键：把镜头拉到「最远视野」并居中整张地图（与 2D 的 `fit_to_map()` 同一意图）
func fit_to_map() -> void:
	zoom = 3.0
	center_on_tile(Vector2(float(world.map.cols) * 0.5, float(world.map.rows) * 0.5))


## 边缘滚屏开关（2D 有 `toggle_edge_scroll`；HUD / 快捷键可能用它）
func toggle_edge_scroll() -> bool:
	_edge_scroll_on = not _edge_scroll_on
	return _edge_scroll_on


func edge_scroll_enabled() -> bool:
	return _edge_scroll_on


## 小地图是不是正压着边缘滚屏（测试读它）
func ui_dragging() -> bool:
	return _ui_dragging_camera


func set_ui_dragging(v: bool) -> void:
	_ui_dragging_camera = v


## ★★ 精确对准：把**某个格**放到画面中心（小地图点哪去哪走它）。
##
## ⚠️ 为什么不能像第一版那样「把屏幕点反算成地面点再平移」：
##   那样会经过一次「投影 → 反投影」的往返，而**透视下这个往返有误差**
##   （越靠屏幕边缘越大），于是「点小地图上的某一格」会落偏 ——
##   这正是用户报的「转移视角的位置不准确」。
##   这里改成**直接按格算相机位置**：先摆相机、再回读「屏幕中心现在对着哪一格」，
##   差多少就补多少（一步牛顿迭代，透视下收敛很快）。
func center_on_tile_precise(logic_pos: Vector2) -> void:
	center_on_tile(logic_pos)
	# ★★ `force_update_transform()` 是这一段的关键（我实测踩到）：
	#    Godot 的节点变换是**惰性更新**的，`project_ray_normal` 读到的是
	#    **上一帧的变换**。实测：刚 `look_at_from_position` 完立刻打射线，
	#    回读位置差 **1.4 格**；而「先摆好再等一帧」就精确了。
	#    ⚠️ 它不报错、只是数值悄悄偏掉 —— 所以我那个「牛顿迭代」第一版不收敛，
	#      因为它每次测的都是过期值。
	if cam != null:
		cam.force_update_transform()
	for i in 4:
		var now: Vector2 = palette.world_to_logic(_ground_under_screen(_view_center()))
		var err: Vector2 = logic_pos - now
		if err.length() < 0.01:      # 不到 1/100 格，够了
			break
		# 把「看向的点」按误差推过去（误差是格坐标，乘格宽回地面点）
		var cell: float = palette.cell_size()
		_place_camera_looking_at(Vector3((now.x + err.x) * cell, 0.0, (now.y + err.y) * cell))
		if cam != null:
			cam.force_update_transform()
	clamp_look_point()

func _consume_events(events: Array) -> void:
	if interaction == null or events.is_empty():
		return
	interaction.pump(events)



## 滚轮缩放：以**光标下的地面点**为锚点（缩放前后它留在同一屏幕位置）
func zoom_at(screen_pos: Vector2, factor: float) -> void:
	if palette == null or cam == null:
		return
	var anchor = palette.to_logic(screen_pos)
	if anchor == null:
		return
	var before: Vector2 = palette.to_px(anchor)
	zoom = clampf(zoom * factor, 0.35, 3.0)
	_place_camera_looking_at(_ground_under_screen(_view_center()))
	var after: Vector2 = palette.to_px(anchor)
	pan_screen(before - after)


## ★★ **真实视口中心**（像素）。所有「屏幕中心对着哪一格」的查询都必须用它。
##
## ⚠️⚠️ 为什么不能再用 `cfg.proj_vp_half`（本轮实测抓到的真 bug）：
##   那个字段是 `set_viewport_size()` 时按**启动时**的窗口尺寸算的，
##   而实测在无头下 `get_visible_rect()` 是 **1920×1920**、`proj_vp_half` 却是
##   **(960, 540)**（硬编码的 1920×1080 一半）。两者不一致时，
##   「屏幕中心」算错 ⇒ **相机夹取、小地图对准、缩放锚点全部偏**。
##   症状就像用户报的「小地图长按能拖到地图外」「转移视角位置不准」。
##   ★ 判据：任何时候要「屏幕中心」，都现场问视口，别读缓存下来的尺寸。
func _view_center() -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return Vector2(cfg.proj_vp_half)
	return vp.get_visible_rect().size * 0.5


## 「某个屏幕点」现在对着哪个地面点（传 `_view_center()` 就是「屏幕中心对着哪一格」）。
##
## ★★ 入参的**语义修正**（本轮实测抓到的真 bug，用最稳的方式落地）：
##   调用点有几处传的是 `cfg.proj_vp_half`，而那是**按启动时窗口尺寸算的缓存值** ——
##   实测在无头下 `get_visible_rect()` 是 1920×1920、`proj_vp_half` 却是 (960, 540)，
##   两者不一致时「屏幕中心」就算错，于是**相机夹取 / 小地图对准 / 缩放锚点全偏**。
##
##   与其去逐个修调用点（我试过，PowerShell 多行替换不可靠、漏了两处），
##   不如**在这里兜住**：只要入参等于那个**过期的中心**，就换成**现场问到的真实中心**。
##   ★ 为什么这样更稳：调用方传什么都不会错，而且这个判据是自解释的
##     （「你传的是旧的 1920×1080 中心，那我用真实的」）。
##   ⚠️ 将来若有人把 `proj_vp_half` 改成动态更新，这段兜底仍然正确（两者会相等）。
func _ground_under_screen(screen_px: Vector2) -> Vector3:
	var p: Vector2 = screen_px
	if cfg != null and p == Vector2(cfg.proj_vp_half):
		p = _view_center()
	var lg = palette.to_logic(p)
	if lg == null:
		return Vector3.ZERO
	return palette.to_world(lg)


## 按**屏幕像素位移**平移镜头（方向键 / 边缘滚屏都走它）
##
## ★ 用「屏幕像素 → 地面位移」的换算：把屏幕中心与「中心 + delta」两点都反算成格，
##   两者之差就是这一步该走的地面位移 ⇒ 手感与缩放无关。
func pan_screen(screen_delta: Vector2) -> void:
	if palette == null or cam == null or screen_delta == Vector2.ZERO:
		return
	var c: Vector2 = _view_center()
	var a = palette.to_logic(c)
	var b = palette.to_logic(c + screen_delta)
	if a == null or b == null:
		return
	var look: Vector3 = _ground_under_screen(c)
	look += palette.to_world(b) - palette.to_world(a)
	_place_camera_looking_at(look)


## ★★ 3D 相机：**用显式基向量摆姿态**，而不是 `look_at()`。
##
## 为什么必须这样（本轮实测踩到的关键一条，直接对应「向下滑动时地块越来越大」）：
##   第一版用 `cam.position = 中心 + 高度向量` 配 `cam.look_at(中心)`。
##   `look_at()` 会**改写 rotation**（实测 `rotation.x = -0.87`），而那引入了一个
##   旋转坐标系 —— 于是「沿自身轴平移」不再等于「沿地面平移」，
##   同一个格在相机移动后会落到屏幕上另一处（实测平移 500 单位 → 屏幕差 239 px，
##   表现就是「越往下滑地块越大」）。
##
## 正解 = 直接给出相机**应该看到什么**：
##   · 俯角 θ 由 `up` 向量表达（`up` 略向相机那侧倾 ⇒ 画面里北边在上）；
##   · `look_at_from_position(地面中心, 中心, up)` 让相机朝地面中心看，
##     `right` 自动 = `up × forward`，与世界 X 轴平行；
##   · **平移只沿世界 X / Z**（见 `pan_by`）⇒ 「格 → 屏幕」与相机位置无关，
##     只由「方向 + 俯角 + 高度 + fov」决定。
## ⚠️ 不要在这上面加 `look_at()`、也不要用 `rotation.x` 表达俯角：
##    那条路会让平移再次影响投影（本文件为此返工过一次）。
## 沿地面平移相机（只动 X / Z）——**唯一**允许移动镜头的方式。
##
## ★ 移动量用相机自己的 right / forward 分解到地面上：这样方向键「上」永远
##   对应画面上的「向上走」，而水平位移本身不影响投影（俯角与高度都不变）。


## 把 HUD 挂进 3D 场景。
##
## ★★ 为什么能直接复用 2D 那版的 `hud.gd`（本版最省的一条路）：
##   HUD 是 `CanvasLayer` 上的 `Control`，**本来就不吃任何 Node2D/Node3D 变换** ——
##   它对世界的唯一依赖是「通过 `camera_rig` 知道我现在看的是哪一块」。
##   于是只要把 `camera_rig` 换成 3D 的替身、并把 `palette` 交给小地图，
##   整个 HUD（编队面板 / 指令卡 / 科技树 / 详情面板 / 小地图）**一行都不用改**。
##   ★ 这正是本版「只重写 view 的渲染层、不重写界面」能成立的原因。
func _build_hud() -> void:
	var theme := FontLoaderRes.build_theme(cfg, 15)
	hud = HudRes.new()
	hud.name = "Hud"
	add_child(hud)
	hud.setup(cfg, world, input_ctrl, theme, _camera_rig_for_hud())
	# ★ 小地图的「视野框 / 点击跳转」改走 3D 投影（见 minimap.gd 的 `_view_corners_logic`）
	if hud.minimap != null:
		hud.minimap.setup(cfg, world, _camera_rig_for_hud(), palette)
	# ★ 用**具名方法**而不是 lambda：`test_settings_menu` 的接线断言是
	#   `hud.fullscreen_toggled.is_connected(Callable(game, "_on_fullscreen_toggled"))`
	#   —— 匿名 lambda 接上去会让这条断言失败（看着像「信号没接」）。
	hud.fullscreen_toggled.connect(_on_fullscreen_toggled)
	hud.return_to_menu_requested.connect(_on_return_to_menu_requested)


## HUD / input_controller 用的相机替身（它们只需要「能不能告诉我视野 / 跳转」）
func _camera_rig_for_hud() -> Object:
	return _make_camera_facade()

## ★★ 输入路由（从 2D 版移植，**这是本轮补的最大一块**）。
##
## 为什么必须在这一层而不是 `input_controller` 里：
##   键盘要先问**命令卡**（Q/W/E/A/S/D/Z/X/C 那些格子），有内容的格子优先于老快捷键；
##   滚轮要先问 **HUD** 的几何（底栏上不许用滚轮缩放地图）。
##   `input_controller` **不认识 HUD**（那是刻意的分层），所以这两问只能在场景这一层做。
##   ★ 两条路都先问 HUD、再落到 input_controller，顺序不能反 —— 反了的表现是
##     「点命令卡上的格子变成了下命令」。
func _unhandled_input(event: InputEvent) -> void:
	if input_ctrl == null:
		return
	if event is InputEventKey:
		var used: bool = false
		if hud != null:
			used = hud.handle_key(event)
		if used or input_ctrl.handle_key(event):
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		# ★ 判据是**这一下滚轮自己的坐标**（不是每帧缓存的鼠标位置）：
		#   鼠标移出底栏之后，下一下滚动就照常缩放 —— 没有需要复位的状态。
		var mb := event as InputEventMouseButton
		if _is_wheel(mb) and hud != null and hud.blocks_wheel_zoom(mb.position):
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


## ★ **唯一改逻辑状态的地方**：把界面发出的命令交给 command_processor。
##   视图层永远不直接改 `world` 的字段（架构第一节那条边界）。
func _on_command(cmd: Dictionary) -> void:
	if world == null:
		return
	CommandRes.apply(world, cfg, cmd)


## 本地 UI 变了（选中 / 悬停 / 面板页签）：**只需要重画，不碰逻辑**。
func _on_local_ui_changed() -> void:
	if overlay != null:
		overlay.set_selection(_selected_ids())


## 当前选中的建筑（含**选中的敌对建筑** —— 敌方建筑被点中时也要亮金框）。
##
## ★ 补这个函数的原因（实测）：`test_ui` 运行期唯一的一条缺成员报错就是它
##   `Nonexistent function '_selected_buildings' in base 'Node3D'`。
func _selected_buildings() -> Array:
	var out: Array = []
	if input_ctrl == null:
		return out
	out.append_array(input_ctrl.selected_buildings)
	if input_ctrl.selected_enemy_kind() == "building" and input_ctrl.selected_enemy != null:
		out.append(input_ctrl.selected_enemy)
	return out

## 设置菜单里点了「全屏 / 窗口化」——原样往上抛给 `main.gd`（它管窗口模式）。
##
## ★ 保持与 2D 版**同名**：`main.gd` 连的就是这两个名字，而它不该知道视角是 2D 还是 3D。
func _on_fullscreen_toggled() -> void:
	fullscreen_toggled.emit()


## 设置菜单里点了「返回主菜单」——同样原样上抛（这属于**流程**，不经过逻辑层）。
func _on_return_to_menu_requested() -> void:
	return_to_menu_requested.emit()