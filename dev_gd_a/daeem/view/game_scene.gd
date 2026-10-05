## game_scene.gd —— 游戏内场景：装配 world + view + hud，跑主循环
##               （对应 HTML 版 main.js 的 init / loop / bindInput）
##
## ★ 这个文件是从 view/main.gd **整段搬过来**的，只改了一件事：
##   建世界的时机从「启动时」变成「玩家在主界面按下 test 之后」。
##   开场那两页（暗色渐变入场页 / 主界面）在 view/start_screen.gd，
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
##
## ★★ 设置二级菜单那两颗按钮要干的活，本文件**只是转发**（本轮新增）：
##    · 全屏 → `fullscreen_toggled` → view/main.gd 的 `toggle_fullscreen()`
##    · 返回主菜单 → `return_to_menu_requested` → view/main.gd 的 `return_to_menu()`
##    为什么不在这里直接做：一个动的是窗口模式（main 还管着 Ctrl+Q 那条快捷键，
##    两处必须同一份实现），另一个要**销毁本场景自己**（自己删自己是最容易留下
##    半条命的写法）。所以这一层只把 hud 的信号原样往上抛。
extends Node2D

## 设置菜单里点了「全屏 / 窗口化」（请求，执行在 view/main.gd）
signal fullscreen_toggled
## 设置菜单里点了「返回主菜单」（请求，执行在 view/main.gd）
signal return_to_menu_requested

const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const MapLibraryRes = preload("res://logic/map_library.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const FactionRes = preload("res://logic/faction.gd")
const Palette2DRes = preload("res://view/palette2d.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")
const TerrainViewRes = preload("res://view/terrain_view.gd")
const ZoneViewRes = preload("res://view/zone_view.gd")
const FogViewRes = preload("res://view/fog_view.gd")
const BuildingViewRes = preload("res://view/building_view.gd")
const UnitViewRes = preload("res://view/unit_view.gd")
const OverlayRes = preload("res://view/overlay.gd")
const CameraRigRes = preload("res://view/camera_rig.gd")
const InputControllerRes = preload("res://view/input_controller.gd")
const HudRes = preload("res://view/hud.gd")

## 默认地图（`start()` 不传参时用它）。
##
## ★ 正常路径**永远**由 `view/main.gd` 把开局页上选中的那张图传进来 ——
##   这个默认值只服务两种调用方：基准脚本（bench_fps 之类）与手玩时直接在编辑器里
##   跑本场景。所以它就是「地图选择条上的第一张」（`logic/map_library.gd` 扫出来的），
##   而不是某个写死的文件名：地图目录一变，这里跟着变，不需要改代码。
const MAP_PATH := MapLibraryRes.FALLBACK_MAP_PATH

var cfg: ConfigRes = null
var world = null
var cam: Camera2D = null

## ★ 这一局是从哪一关开的（`start()` 那条「按一张图直接开一局」的老路径上两者都是 null）。
## ★ 它们**不是玩法状态**：世界自己持有 `level`（`world.level`），这里只是让界面层
##   能回答「我在玩哪一战 / 哪一关」（以后的「返回关卡列表 / 结算面板」要用）。
var level_campaign = null
var level_playing = null

var terrain_view: Node2D = null
var zone_view: Node2D = null
var fog_view: Node2D = null
var building_view: Node2D = null
var unit_view: Node2D = null
var overlay: Node2D = null
var camera_rig: Control = null
var input_ctrl: Control = null
var hud: CanvasLayer = null

## ★★ 2.5D 压扁与深度排序的承载节点：**全部世界内容**都挂在它下面
##   （地形 / 区划 / 建筑 / 单位 / 迷雾 / 覆盖层），它的 `scale.y = cfg.render_squash`。
##   ⚠️ 三样东西**不在**它下面，而且这是刻意的：`cam`（否则相机自身的平移会被压扁）、
##      `camera_rig` / `input_ctrl`（Control 要铺满屏幕接输入）、`hud`（CanvasLayer，
##      本来就不吃 Node2D 的变换 ⇒ HUD 天然不受压扁影响）。`tests/test_view.gd` 钉着这一条。
var content_root: Node2D = null

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
	# ★★ 透视投影的常数里含视口尺寸（ndc → 屏幕像素那一步）——
	#    必须在建任何视图之前喂一次，否则第一帧的投影是拿默认 1920×1080 算的
	#    （窗口不是这个尺寸时，第一帧的位置会整体偏，第二帧才对）。
	cfg.set_viewport_size(
		float(ProjectSettings.get_setting("display/window/size/viewport_width", 1920)),
		float(ProjectSettings.get_setting("display/window/size/viewport_height", 1080)))

	# ★★ 投影整体平移：把**地图中心**搬到视口中心。
	#   为什么必须要（实测）：投影公式把「格 y = 0」固定在视口中心，于是整张地图
	#   落在屏幕**下半部分**（22 行的图落在 y ≈ 1500~2400，视口只有 1080 高）——
	#   结果地图整个在屏幕外、所有单位被剔除逻辑正确剔掉（表现为「字没在单位身上」）。
	#   ⚠️ 必须在建 world 之前设：`palette.to_px` 从第一帧就要用它。
	#
	#   算法（两趟，避免「用自己算自己」）：
	#     ① 偏移先清零，算出「地图中心投影到哪」与「视口中心」之差；
	#     ② 把这个差当成整体平移量。
	cfg.proj_offset = Vector2.ZERO
	var map_center_px := Palette2DRes.to_px(
		Vector2(float(cfg.cols) * 0.5, float(cfg.rows) * 0.5), cfg)
	cfg.proj_offset = map_center_px - Vector2(cfg.proj_vp_half)

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
		camera_rig.center_on_px(Palette2DRes.to_px(world.units[0].pos, cfg))

	return true


## ★★ 从**一关**进游戏（战役路径；`start()` 是「按一张图直接开一局」的老路径）。
##
## 与 `start()` 的差别只有「世界怎么造出来」这一处，之后**完全同一条尾**：
##   `World.create_from_level()` 会依次应用关卡覆盖层（大本营 / 阵营 / 区块归属 / AI 名单）
##   → 关卡的开局摆放（`start_units` / `start_buildings`）→ 目标与胜负（`objective.setup`）。
##   所以 `view/` 一个字都不用改：它读的还是同一个 `world`。
##
## @param campaign `logic/campaign.gd` 的 Campaign（**只记下「在玩哪一战」**；
##        本版没有进度存档，所以它只被 `level_campaign_playing()` 用上 ——
##        留着是为了以后做「返回关卡列表 / 结算」时不必再改这里的签名）
## @param level    `logic/level.gd` 的 Level（必填）
## @param my_faction 本机席位（单人战役 = `level.seats()[0]`）
## @return bool 是否装配成功（与 `start()` 同一条约定：失败时调用方把半成品撤掉）
func start_level(campaign, level, my_faction: String) -> bool:
	cfg = ConfigRes.load_default()
	if cfg == null:
		push_error("配置载入失败，游戏无法启动：%s" % ConfigRes.last_error)
		return false
	if level == null:
		push_error("关卡是 null，战役无法启动")
		return false

	# ★★ roster = **本机负责的席位**（不是「玩家操作的那一方」）。它由两半拼出来：
	#
	#   ① 关卡 `players[]` 声明的席位（`level.seats()`）——
	#      一关可以有**两个都可玩的阵营**（样例第一关 F1 / F2）：玩家挑一个来玩，
	#      但**两个阵营都要有自己的大本营与属地**（选谁就从谁的家开打）。
	#   ② 关卡点名要挂 AI 的参展阵营里、**本机也要负责**的那些 ——
	#      也就是「给玩家当选择、但玩家没选它」的那一方（它照样要有家）。
	#      ⚠️ 真正的 NPC 敌人（E1）**不进** roster：它由 `world._setup_ai_factions()`
	#         自己加进这一局的名单，不需要本机认领（认领了反而会被当成玩家的家判负）。
	#
	# `my_faction` 才是「本机**操作**哪一方」：没被选中的那一方由**盟友 AI** 接管 ——
	# 判据在 `world._setup_ai_factions()` / `_is_ai_piloted()`，它们看
	# `world.player_factions`（= 只有 `my_faction`），**不是** roster。
	#
	# ⚠️ 不要改成 `[my_faction]`：那样另一个阵营连大本营都不会建，地图上根本没有它
	#    （实测：选 F2 时 F2 的 base = (-1,-1) ⇒ 开局直接 `objective_never_held` 判负）。
	# ⚠️ 也不要只传 `level.seats()`：样例第一关的 `players[]` 只声明了 F1 一个席位，
	#    另一个可玩阵营 F2 就没家了（实测：选 F2 时它的 base 是 (-1,-1)）。
	#
	# ★★ **我选的那一方放第一个**（`build_roster` 的第三个参数）：
	#    `objective.setup()` 用**第一个席位**决定「这一局打哪条目标」——
	#    选红方时 roster 是 [F2, F1]，取到的就是红方那条「占领 c1」，
	#    而不是蓝方那条「守住 c1」。顺序本身就是一条契约，别随手改。
	var roster: Array = build_roster(level, cfg, my_faction)
	world = WorldRes.create_from_level(cfg, level, my_faction, roster, true)
	if world == null:
		push_error("关卡装配失败，游戏无法启动（地图 = %s）" % String(level.map_id))
		return false

	# 记下「这一局是从哪一关来的」。★ 它们是**公开变量**（与 `world` / `cfg` 同一个读法：
	#   本工程不给自己持有的状态套一层 getter），界面与测试直接读 `game.level_playing`。
	level_campaign = campaign
	level_playing = level

	_build_view()
	_build_hud()
	_build_debug_handles()

	# 与 `start()` 同一条收尾：开场选中 1 号将领并把它放进镜头
	if world.units.size() > 0:
		input_ctrl.select_units([world.units[0]])
		camera_rig.center_on_px(Palette2DRes.to_px(world.units[0].pos, cfg))

	return true


## ★★ 本局的**席位名单**（本机负责的阵营，顺序有讲究）。
##
## 拼法 = 关卡 `players[]` 声明的席位 + 「**可玩**、且关卡点名要挂 AI」的那几个
##        （后者就是「另一个可选阵营」：它的家也要建出来，但不本机操作）；
##        最后把 `my_faction` 提到**第一位**。
##
## ⚠️⚠️ 顺序不是小事：`objective.setup()` 取**第一个席位**决定「这一局打哪条目标」。
##    一关可以配两条目标（蓝方「守住 c1」/ 红方「占领 c1」），选红方时
##    roster 必须是 `[F2, F1]` —— 否则红方会拿着蓝方的目标进关。
##
## ⚠️ 真正的 NPC 敌人（样例的 E1）**不进**这份名单：它由 `world._setup_ai_factions()`
##    自己加进这一局；认领了反而会被当成「玩家的家」而影响判负。
##
## 抽成静态函数是为了能**被无头测试直接调**（`start_level` 要建场景树，测试里跑不了）——
## `tests/test_campaign_seats.gd` 钉着它，免得两处口径漂开。
static func build_roster(level, cfg, my_faction: String) -> Array:
	var roster: Array = level.seats()
	for e in level.merged_ai_factions(cfg.ai_factions()):
		var fid := String((e as Dictionary).get("id", ""))
		if fid == "" or roster.has(fid):
			continue
		if level.is_playable(fid):
			roster.append(fid)
	if roster.is_empty():
		roster.append(my_faction)
	# ★ 把「我在操作的那一方」提到第一位（它必须是第一个席位）
	var idx: int = roster.find(my_faction)
	if idx > 0:
		roster.remove_at(idx)
		roster.push_front(my_faction)
	return roster

func _build_view() -> void:
	cam = Camera2D.new()
	cam.name = "Camera2D"
	add_child(cam)
	cam.make_current()

	# ★★ 菱形投影的承载节点（等距 / 斜俯视 45°，见 config.json 的 render._comment）。
	#
	#   ★★ 这里**故意不做任何旋转**（`scale` 保持 1、`rotation` 保持 0）：
	#      菱形是 `view/palette.gd` 按顶点**画出来**的多边形，不是「转过的矩形」。
	#      好处是世界空间保持**轴对齐** ⇒ 剔除 Rect2 / 血条 / draw_arc / 汉字
	#      全部照旧正确，一整类「漏了反向补偿就静默画歪」的风险被消掉了。
	#      （试过的那条路：转父节点 + 每处用 Transform2D.inverse() 救回来 —— 能做，
	#        但那是给每一种图元各留一个坑，见 route.md 四十一节与 dev_plan_8。）
	#
	#   ★ 这个节点仍然保留：它是**深度排序**（`y_sort_enabled`）与**图层归属**的锚点
	#     （地形 / 区划 / 建筑 / 单位 / 迷雾 / 覆盖层都挂在它下面）。
	content_root = Node2D.new()
	content_root.name = "ContentRoot"
	content_root.scale = Vector2.ONE
	content_root.y_sort_enabled = cfg.depth_sort
	add_child(content_root)

	# 绘制顺序：地形 -100 / 区块 -50 / 建筑 0 / 单位 10 / **迷雾 15** / 覆盖层 20
	terrain_view = TerrainViewRes.new()
	terrain_view.name = "TerrainView"
	terrain_view.z_index = -100
	content_root.add_child(terrain_view)
	terrain_view.setup(cfg, world.map)

	_font = FontLoaderRes.load_font(cfg)

	zone_view = ZoneViewRes.new()
	zone_view.name = "ZoneView"
	zone_view.z_index = -50
	content_root.add_child(zone_view)
	zone_view.setup(cfg, world, _font, 12)

	# ★★ 战争迷雾：灰色遮罩压在**地形 / 区块 / 建筑 / 单位**之上、覆盖层（攻击线 /
	#    框选矩形 / 建造预览）之下 —— 于是没视野的区域连敌人带地形一起变暗，
	#    而玩家自己的操作标记永远看得清（用户确认：标记与准星不该被雾吃掉）。
	#    ⚠️ 顺序很关键：z_index 15 必须**大于** unit_view 的 10、小于 overlay 的 20。
	fog_view = FogViewRes.new()
	fog_view.name = "FogView"
	fog_view.z_index = 15
	content_root.add_child(fog_view)
	fog_view.setup(cfg, world)

	building_view = BuildingViewRes.new()
	building_view.name = "BuildingView"
	building_view.z_index = 0
	content_root.add_child(building_view)
	building_view.setup(cfg, world)

	unit_view = UnitViewRes.new()
	unit_view.name = "UnitView"
	unit_view.z_index = 10
	content_root.add_child(unit_view)
	unit_view.setup(cfg, world, _font)

	overlay = OverlayRes.new()
	overlay.name = "Overlay"
	overlay.z_index = 20
	content_root.add_child(overlay)
	overlay.setup(cfg, world)

	# ★ 相机是 content_root 的**兄弟**（不是它的子节点）：相机位置是世界像素，
	#   若挂在被压扁的父节点下，相机的平移自己也会被压扁一次（纵向移动变慢 30%）。
	camera_rig = CameraRigRes.new()
	camera_rig.name = "CameraRig"
	add_child(camera_rig)
	camera_rig.setup(cfg, cam, world.map)

	# ★ 输入层也留在 content_root **外面**：它的 Control 要铺满屏幕接输入，
	#   挂进去会被父变换缩放，全屏锚点与鼠标局部坐标就都对不上了。
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
	# ★★ 设置二级菜单的两个请求：原样往上抛（见文件头）。
	#    上面那几条 local_ui_changed / command_issued 是「界面 → 逻辑」，
	#    这两条是「界面 → 流程」，所以它们**不经过逻辑层**。
	hud.fullscreen_toggled.connect(_on_fullscreen_toggled)
	hud.return_to_menu_requested.connect(_on_return_to_menu_requested)


## 设置菜单里点了「全屏 / 窗口化」——转给 main.gd（它管窗口模式，也管 Ctrl+Q）。
func _on_fullscreen_toggled() -> void:
	fullscreen_toggled.emit()


## 设置菜单里点了「返回主菜单」——转给 main.gd（它会拆掉本场景）。
##
## ★ 先确认「本场景确实活着」再转发：返回主菜单的路上，本节点会被摘下来销毁，
##   而这期间队列里可能还压着一次点击 —— 那种情况下不该再发第二条请求
##   （main.gd 侧也有同样的幂等判断，两处都留着是因为代价只有一行）。
##   ⚠️ 用 `is_instance_valid()` 而不是 `is_inside_tree()` 单独判：本函数有可能在
##     **自己已经被释放之后**才被叫到（信号连在已销毁的节点上），
##     那时 `is_inside_tree()` 自己就会报
##     「Invalid call. Nonexistent function 'is_inside_tree' in base 'previously freed'」。
func _on_return_to_menu_requested() -> void:
	if not is_instance_valid(self) or not is_inside_tree():
		return
	return_to_menu_requested.emit()


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

	# ★★ 小地图正在被拖着走 → 这一帧只让「拖动」改相机。
	#   小地图贴着屏幕左下角，而最外圈永远允许边缘滚屏（那是所有贴边控件的共同规则），
	#   两条路同时改相机会让画面贴着下沿发抖 —— 见 camera_rig._ui_dragging_camera。
	#   ⚠️ 判据是**拖动**（越过阈值之后），不是「按着」：按下但没动的那一下是单击，
	#      单击时边缘滚屏照旧（否则按住小地图不动、鼠标又贴着边时画面会突然停一拍）。
	#
	# ★★ 同一时刻的**框选**也要冻住相机（本轮修 bug）：
	#   框的起点是一个**格坐标**，每帧要重投影回屏幕才画得出来 —— 相机一动，
	#   同一个格坐标就落到屏幕上另一处，玩家看到的是「右上角的起点自己跑了」。
	#   两个来源并列（`or`）：小地图拖动与左键框选都可能同时发生。
	camera_rig.set_ui_dragging(
		(hud.minimap != null and hud.minimap.is_dragging()) or input_ctrl.is_dragging_box())

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
	# ★ 迷雾：世界先动，遮罩后盖（`sync()` 里按需重烘掩码贴图）
	fog_view.sync()
	unit_view.set_selection(_selected_ids())
	# ★ 选中的建筑可能是一整批（框选建筑）—— 它们**都**要点亮金色外框
	#   ★ 本轮起这一份还包含「选中的敌对建筑」（见 `_selected_buildings()`）。
	building_view.set_selected_buildings(_selected_buildings())

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
	# ★★ 选中的**敌人**也要画选中圈（本轮新增：玩家可以选中敌对单位）。
	#    ⚠️ 只加单位 —— 建筑不走这条（它的高亮在下面 `_selected_buildings()` 那一份里）。
	#    不加这一句的表现是「右栏报着敌人的数值，地图上却看不出选的是哪一个」。
	if input_ctrl.selected_enemy_kind() == "unit" and input_ctrl.selected_enemy != null:
		ids.append(input_ctrl.selected_enemy.id)
	return ids


## 该点亮金色外框的建筑：**己方那批 + 选中的那个敌人**（如果有）。
##
## ★ 为什么要合并这两份：`building_view` 只认一个集合（谁在里面谁就高亮），
##   而「选中的敌人」是单独一个字段（见 input_controller.selected_enemy 那段理由）。
##   合并放在这一层，是因为它正是「把本地选中状态翻译成渲染输入」的那一层。
##
## ★ 返回的是**新数组**（不是 `selected_buildings` 本身）：后者是 input_controller 的
##   权威列表，往里 append 会把「选中的敌人」永久混进己方选中里 ——
##   那正是这一轮特意避开的坑。
func _selected_buildings() -> Array:
	var out: Array = input_ctrl.selected_buildings.duplicate()
	if input_ctrl.selected_enemy_kind() == "building" and input_ctrl.selected_enemy != null:
		out.append(input_ctrl.selected_enemy)
	return out


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
	building_view.set_selected_buildings(_selected_buildings())


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
				# ★★ 必须按阵营过滤（与下面 upgrade/revive 同一条，**这一类 bug 犯过三次**）：
				#   阵营 AI 每帧重试招募，被拒后推 `recruit_rejected` —— 不过滤的话
				#   玩家会一直看到「只能在己方区划内招募…」这种**别人的**红字，
				#   而且 AI 每帧重试 ⇒ 提示被反复续期、永远不消失（实测报回来的正是这个）。
				if _is_my_event(evt):
					hud.show_notice(hud.recruit_reject_text(
						String(evt.get("reason", "")), String(evt.get("kind", "")),
						int(evt.get("max", 0))))
			"order_rejected":
				if _is_my_event(evt):
					hud.show_notice(hud.order_reject_text(String(evt.get("reason", ""))))
			"tech_rejected":
				# ★ 科技启用被拒（满 3 条）。本地那一下已经给过一句提示了，
				#   这条是**权威侧**的同一句话 —— 两条同文案，所以玩家看到的还是一句。
				# ★★ 同样要按阵营过滤：AI 也会 `set_tech_active()`（名额满了会推这条）。
				if _is_my_event(evt):
					hud.show_notice(hud.tech_reject_text(String(evt.get("reason", ""))))
			"upgrade_rejected":
				# ★ 建筑升级 / 区划特化被拒（拒因码见 logic/upgrade.gd 的那几处判定）。
				# ★★ 把**整个事件**传进去：`busy` 那条文案要点名是哪个对象。
				# ⚠️⚠️ 而且**必须先按阵营过滤**（实测报回来的 bug）：
				#   阵营 AI 每帧都会对**它自己**在读条的建筑重下一次升级单（它的
				#   `upgrade_timer` 在那一帧刚好到点），被拒后推一条 `upgrade_rejected` ——
				#   如果界面不加判断地显示，玩家就会看到「城墙正在读条…」「箭塔正在读条…」
				#   这种**别人的**消息（玩家原话：「可能是敌人的消息传到我这来了」——正是）。
				#   所以只显示**自己这一方**产出的拒因（见 `_is_my_event`）。
				if _is_my_event(evt):
					hud.show_notice(hud.upgrade_reject_text(String(evt.get("reason", "")), evt))
			"revive_rejected":
				# ★★ 「再起」被拒（本轮新增；拒因码见 logic/world.gd 的 revive_reject_reason）。
				#    ⚠️ 与 upgrade_rejected 同一条：**必须先按阵营过滤** ——
				#       AI 也会下单再起（它走同一个入口），不过滤的话玩家会看到
				#       「粮食或黄金不足」这种**别人**的报错。
				if _is_my_event(evt):
					hud.show_notice(hud.revive_reject_text(String(evt.get("reason", ""))))
			"unit_recruited":
				input_ctrl.notify_unit_recruited(evt.get("leader", null), evt.get("unit", null))


## ★★ 这条事件是**本机玩家这一方**产生的吗？（不是就别拿它去打扰玩家）
##
## 为什么需要它（实测报回来的 bug）：阵营 AI 也会升级自己的建筑，而它每帧都会对
## **在读条的那一栋**重下一次升级单（它的冷却计时在那一帧刚好到点），被拒后推
## `upgrade_rejected` —— 界面不加判断地显示，玩家就会看到「城墙正在读条…」
## 「箭塔正在读条…」（原话：「可能是敌人的消息传到我这来了」，正是）。
##
## 判据（**只在逻辑层不知道「谁是本机」时用** —— 逻辑层是权威，它不知道谁是本机）：
##   · 事件带 `faction`：== 本机阵营才算我的；
##   · 不带：**保守地认为是我这边**（宁可多一句提示，也不要漏掉玩家自己的报错）——
##     这类事件都是「有人下了命令、被拒了」，而目前只有命令与 AI 两条来源。
func _is_my_event(evt: Dictionary) -> bool:
	if world == null:
		return true
	if not evt.has("faction"):
		return true
	return FactionRes.same_side(String(evt.get("faction", "")), String(world.my_faction))
