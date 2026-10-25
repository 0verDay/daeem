## main.gd —— ★ 入口 / 唯一的流程调度者：开场页 → 主界面 → 游戏内场景
##
## 流程（需求原文 + 本轮改版的入口）：
##   1. 启动 = 暗色渐变入场页：上方徽记 + 标题 DAEEM；屏幕下方「————点击任意处进入游戏————」，
##      呼吸式渐显渐隐
##   2. 点击任意处 → 主界面（正中：标题条 + **五颗测试入口**；
##      右侧「战役」按钮撑开的是**战役菜单**：轮播 + 关卡圆点 + 描述 + 长按进入）
##   3. 按下任一颗 test_N，或在战役菜单里长按某一关 → 载入那一关并进入游戏内场景
##   4. ★ 游戏内的「设置 → 返回主菜单」→ 拆掉游戏场景、把主界面放回**第 2 步**那个状态
##
## ★ 为什么把「建世界」从 _ready 挪到按下入口那一刻（而不是先建好再拿白屏盖住）：
##   进游戏之前 world / 相机 / HUD 都不该存在 —— 否则世界会在菜单背后偷偷 tick，
##   而「关卡载入失败」这种错也会在玩家还没进游戏时就弹出来。
##   代价是按下按钮那一帧要跑一次装配（载地图 + 字体 + 搭 HUD），原型阶段这点开销无所谓。
## ★ 关卡是**按玩家按下的那一项**建的：入口只带 `campaign_id + level_id`，
##   「载入哪一份战役、取哪一关」只有本文件一处，所以「按了第二关却进了第一关」没有第二个入口。
##
## ★★ 窗口模式与「回菜单」这两件事**只在本文件实现**（本轮新增的选项页是第二条入口）：
##   · `toggle_fullscreen()` —— Ctrl+Q 与选项页里的「全屏」都走它，
##     否则两份实现迟早会漂（一份记得还原进入全屏前的窗口模式、另一份忘了）。
##   · `return_to_menu()` —— 拆游戏场景、放回开场页。★ 不重启进程、不新建开场页：
##     玩家上一次选的那一关还留在菜单上（见那里的注释）。
##
## ★ 职责边界（三层各管一段，谁都不越界）：
##   view/start_screen.gd  开场两页：只认输入、测试按钮与自己的信号，不认识 world
##   view/game_scene3d.gd  游戏内场景（3D 唯一实现）：装配 world + view + hud，跑主循环
##   view/hud.gd           游戏内 UI：选项页只**发信号**，不切窗口也不拆场景
##   本文件                只做连接：把「按了哪一关」翻译成「进哪个游戏」，
##                         把「设置里点了全屏 / 回菜单」翻译成窗口模式与流程切换
##   没有任何一层把玩法规则写进来 —— 规则全在 logic/。
##
## 调试句柄：控制台里 `RTS`（等价于 HTML 版的 window.RTS）。★ 它指向游戏内场景
## （view/game_scene3d.gd），所以**进游戏之前是 null** —— 那是刻意的，没世界可调。
extends Node2D

const ConfigRes = preload("res://logic/config.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")
const StartScreenRes = preload("res://view/start_screen.gd")
## ★★ 入口 = 3D 场景（`view/game_scene3d.gd`）—— **唯一**的游戏内实现。
##   2D 视图栈（`game_scene.gd` / `palette2d.gd` / `terrain_view.gd` 等九个文件）
##   已整体删除；本文件是**流程层**，对「视角怎么画」一无所知。
##   ⚠️ `var game` 必须写成类型 `Node`：`Node3D` 与 `Node2D` 是平级分支，
##      写成 `Node2D` 会让本文件直接 Parse Error（见下面 `var game` 那段）。
const GameSceneRes = preload("res://view/game_scene3d.gd")
## ★★ 战斗入口（本轮改版）：
##   · 主界面正中五颗测试按钮（test_1 / ai_test / ai_test_2 / ai_test_battle / ai_test_hz）
##     —— 各自直连一关（见 config 的 `menu.test_entries`）；
##   · 「战役」按钮撑开的面板里是**战役菜单**（轮播 + 关卡圆点 + 描述 + 长按进入）。
##   两条路都只发 `level_entry_pressed(campaign_id, level_id)`，本文件负责：
##   载入战役 → 取那一关 → 取第一个可玩阵营 → `game.start_level()`。
##
## ★ 单人战役的占位页（`view/campaign_test.gd`）与「地图选择条 + test」那一套已经删掉：
##   它们的功能被上面两条入口取代（用户要求：旧三件套从「战役」面板移除）。
const CampaignLibraryRes = preload("res://logic/campaign_library.gd")
## ★★ 战役过渡画面（view/level_transition.gd）：缩略图 + 简报 + 多阵营选择 + 进度 + 点击进入。
##   只有单人关走它；合作关仍直接进（合作大厅那一路有自己的流程）。
const LevelTransitionRes = preload("res://view/level_transition.gd")
## ★★ 退出确认浮层（`view/quit_confirm.gd`；版式移植自 nsoc 的 quit_confirm.gd）。
##   它只发 `confirmed` / `cancelled`，**自己不 quit** —— 「谁退出」仍然只在本文件。
const QuitConfirmRes = preload("res://view/quit_confirm.gd")
## ★★ 黑屏转场要读动效总开关（`theme.gd` 的 `animations_enabled()`）。
const ThemeRes = preload("res://view/theme.gd")

## 开场页用的字体基准字号（标题 / 提示 / 按钮各自另有字号，见 config.json 的 menu 段）
const MENU_FONT_SIZE := 32

## ★★ 进入游戏的黑屏转场（只用于战役过渡画面点「进入」；见 `_on_level_transition_enter`）：
##   `enter_fade_sec`    = 画面推成全黑的时长；
##   `enter_fade_in_sec` = 游戏场景首帧就绪后，从全黑里淡出来的时长。
##   兜底值必须与 data/config.json 的 `menu.transition.enter_fade_*` 一致。
const DEFAULT_ENTER_FADE_SEC := 0.35
const DEFAULT_ENTER_FADE_IN_SEC := 0.40
## ★★ **打开**过渡画面时的黑幕（用户口径：长按进入战役时，战役界面先渐隐、
##   再让战役过渡画面渐显）：
##   `open_fade_sec`    = 战役界面推成全黑的时长（此时过渡画面还没建）；
##   `open_fade_in_sec` = 过渡画面建好之后，从全黑里淡出来（= 它渐显）的时长。
##   兜底值必须与 data/config.json 的 `menu.transition.open_fade_*` 一致。
const DEFAULT_OPEN_FADE_SEC := 0.22
const DEFAULT_OPEN_FADE_IN_SEC := 0.34
## 黑屏层要盖在过渡画面（150）/ 退出确认（200）之上。
const ENTER_FADE_LAYER := 300

var cfg: ConfigRes = null
var start_screen: CanvasLayer = null
## 菜单用的中文字体（开场页建好后留一份：退出确认浮层也要挂同一套字体）。
var _ui_font: Font = null
## ★ 退出确认浮层（第一次点「退出游戏」/ 按安卓返回时才建；之后复用同一个实例）。
var _quit_confirm = null
## ★★ 类型必须是 `Node`，不能是 `Node2D`（本轮实测踩到）：
##    入口切到 3D 之后 `game_scene3d.gd` 是 **`Node3D`**，而 `Node3D` 与 `Node2D` 是
##    **平级的两个分支** —— 写 `var game: Node2D` 会让这一行直接
##      `Parse Error: Value of type "game_scene3d.gd" cannot be assigned to a variable of type "Node2D"`
##    ⇒ **整个 `main.gd` 载不进来** ⇒ 主界面起不来、集成测试大面积掉断言
##    （实测：`test_map_select` 从 73 项掉到 25 项，`test_start_flow` 报「主界面能起来」失败，
##      而且症状看着像「界面坏了」，其实只是这一行的类型标注）。
##    ★ 判据：`main.gd` 是**流程层**，它只该知道「游戏内场景是个节点」，
##      **不该知道**视角是 2D 还是 3D —— 所以类型标注就该停在 `Node`。
var game: Node = null
## ★ 当前的战役过渡画面（没有则是 null；见 `_show_level_transition()`）。
var _level_transition = null
## ★★ 「正在把过渡画面推出来」的闸：`_show_level_transition()` 现在先淡黑再建页
##    （约 0.2s），那段时间 `_level_transition` 还是 null —— 没有这个闸，玩家连点两下
##   会长出两个过渡页（第二个把第一个盖住，收的时候只收掉一个）。
var _transition_opening: bool = false

## ★★ 进入游戏时的黑屏转场（CanvasLayer + 全屏 ColorRect）。
##   它必须活在 main 上：过渡画面在转场中途就被收掉了，黑屏层不能跟着一起没。
var _enter_fade: CanvasLayer = null
var _enter_fade_rect: ColorRect = null
var _enter_fade_tween: Tween = null

## 进全屏之前是哪种窗口模式（退出全屏时还原，见 _handle_window_hotkey）
var _windowed_mode: int = DisplayServer.WINDOW_MODE_WINDOWED


func _ready() -> void:
	cfg = ConfigRes.load_default()
	if cfg == null:
		# ⚠️ 配置坏了就什么都别往下做：开场页读的文案 / 配色也全在这份 JSON 里，
		#   硬着头皮搭一页出来只会让「JSON 写错了」表现为「文案莫名不对」。
		push_error("配置载入失败，游戏无法启动：%s" % ConfigRes.last_error)
		return

	_build_start_screen()


func _build_start_screen() -> void:
	# 中文字体在这里就载入：菜单上「点击任意处进入游戏」是中文，
	# 不挂字体的话 Godot 默认字体会把它画成一排方框。
	var font := FontLoaderRes.load_font(cfg)
	_ui_font = font

	start_screen = StartScreenRes.new()
	start_screen.name = "StartScreen"
	add_child(start_screen)
	start_screen.setup(cfg, font)

	start_screen.intro_dismissed.connect(_on_intro_dismissed)
	start_screen.level_entry_pressed.connect(_on_level_entry_pressed)
	start_screen.direct_level_requested.connect(_on_direct_level_requested)
	start_screen.ai_test_requested.connect(_on_ai_test_requested)
	start_screen.coop_host_started.connect(_on_coop_host_started)
	start_screen.coop_guest_started.connect(_on_coop_guest_started)
	start_screen.coop_solo_started.connect(_on_coop_solo_started)
	# ★★ 主菜单「选项 → 设置 → 全屏」与游戏内走同一个 toggle_fullscreen（唯一实现）。
	start_screen.fullscreen_toggled.connect(toggle_fullscreen)
	start_screen.quit_requested.connect(_on_quit_requested)


## 主菜单「选项 → 退出游戏」：先弹**退出确认浮层**，不直接关游戏。
## ★ 真正 quit 放在 main.gd（流程层）；StartScreen 只发信号，不认识窗口生命周期。
func _on_quit_requested() -> void:
	_show_quit_confirm()


## ★★ 挂出 / 复用退出确认浮层。
##
## ★ 为什么第一次才建：大多数会话根本不会点退出 —— 不在启动路径上多建一层 CanvasLayer。
## ★ 复用同一个实例：关掉只是把它的子树销毁（`quit_confirm._destroy()`），
##   下次 `request()` 会重建；不重复 add_child，也不重复接信号。
func _show_quit_confirm() -> void:
	if _quit_confirm == null or not is_instance_valid(_quit_confirm):
		_quit_confirm = QuitConfirmRes.new()
		add_child(_quit_confirm)
		_quit_confirm.setup(cfg, _ui_font)
		_quit_confirm.confirmed.connect(_on_quit_confirmed)
	if _quit_confirm.is_open():
		return
	_quit_confirm.request()


## 浮层里点面板确认：遮罩已经渐黑过了（`quit_fade_sec`），这里才真的退出。
func _on_quit_confirmed() -> void:
	get_tree().quit()


## ★★ 安卓返回键（`project.godot` 已把 `config/quit_on_go_back` 关掉，引擎不会先撤）。
##
## 三档（用户拍板的口径）：
##   1. 退出确认已经开着 → 再按返回 = **取消**它；
##   2. 局内选项页开着 → 先关选项页（返回键的第一层语义是「退出当前浮层」）；
##   3. 其余（主菜单 / 入场页 / 局内无浮层）→ 弹退出确认。
func _on_android_back() -> void:
	if _quit_confirm != null and is_instance_valid(_quit_confirm) and _quit_confirm.is_open():
		_quit_confirm.cancel()
		return
	if game != null and is_instance_valid(game):
		var hud = game.hud
		if hud != null and is_instance_valid(hud) \
				and hud.options_panel != null and is_instance_valid(hud.options_panel) \
				and hud.options_panel.is_open():
			hud.options_panel.close()
			return
	_show_quit_confirm()


# ------------------------------------------------------------------
# 开场页 → 主界面 → 游戏
# ------------------------------------------------------------------

## 入场页被点掉了。★ 目前不需要额外动作（页面切换在 start_screen 内部完成），
##   但这条线要留着：以后主界面要放「继续游戏 / 设置」之类需要读存档的东西，就在这里接。
func _on_intro_dismissed() -> void:
	pass


## ★ 直连一张地图开局（**不再有任何界面按钮走这条路**）。
##
## ★★ 保留它是因为「随便开一张图」仍然是测试 / 截图脚本的入口
##   （`tests/test_*.gd`、`tests/bench_*.gd` 几十处 `main._on_test_pressed(...)`）：
##   它绕开「战役 / 关卡」的全部概念，建的是**没有关卡目标**的纯地图局。
##   正式入口（test_1/2/3 与战役菜单）走的是 `_on_level_entry_pressed()`。
##
## ★ 参数是**地图路径**：这里不读任何默认值 —— 「默认进哪张图」只该有一个决定点。
func _on_test_pressed(map_path: String) -> void:
	if game != null:
		return          # 已经进过游戏了（按钮只该生效一次）

	game = GameSceneRes.new()
	game.name = "GameScene"
	add_child(game)
	if not game.start(map_path):
		# 装配失败：把半成品撤掉，玩家留在主界面上，而不是进到一个空的游戏里
		game.queue_free()
		game = null
		return

	# 进游戏之后开场页整层下线：背景与「点击任意处」的处理器一起停掉
	start_screen.close()

	# ★★ 选项页里那两条请求（全屏 / 返回主菜单）——见本文件头部「职责边界」。
	game.fullscreen_toggled.connect(toggle_fullscreen)
	game.return_to_menu_requested.connect(return_to_menu)


# ------------------------------------------------------------------
# 战斗入口（test_1/2/3 与战役菜单长按）—— 统一在这里载入关卡
# ------------------------------------------------------------------

## ★★ 玩家选定了「哪一份战役的哪一关」→ 载入 → 取第一个可玩阵营 → 进游戏。
##
## ★ 两条入口共用（主界面正中三颗 test_N / 战役菜单里长按的那一关）：
##   参数是**数据**（campaign_id + level_id），载入与建世界都在这里，
##   界面那侧不认识 `campaign` / `world`（与「战役目录扫描只有一处」同一个口径）。
##
## ★ 单人关不再直接建世界：先挂**战役过渡画面**（`view/level_transition.gd`），
##   玩家在里面看缩略图 / 简报、多可玩阵营时选一方、点「进入」才走建世界那条尾。
##   合作关仍直接开局（`level.mode == "coop"`），因为合作大厅有自己的流程。
##
## ★ 占位战役 / 占位关（`campaigns_menu.json` 里没填 campaign_id / level_id 的）：
##   根本不会走到这里（`view/campaign_menu.gd` 的 activate_chapter 会直接不发信号）。
##   但数据写坏（战役 / 关卡读不出来）也必须**安静地不动**：宁可不进游戏，
##   也不要进到一个空 World 里（那样报错会离真正的数据问题很远）。
func _on_level_entry_pressed(campaign_id: String, level_id: String) -> void:
	if game != null:
		return
	var option := _find_campaign_option(campaign_id)
	if option.is_empty():
		push_warning("战役不存在：%s" % campaign_id)
		return
	var campaign = CampaignLibraryRes.load_campaign_by_option(option, cfg)
	if campaign == null:
		push_warning("战役载入失败：%s" % campaign_id)
		return
	var level = campaign.level(level_id) if campaign.has_method("level") else null
	if level == null:
		push_warning("关卡不存在：%s / %s" % [campaign_id, level_id])
		return
	var playable: Array = level.playable_ids()
	if playable.is_empty():
		push_warning("关卡没有可玩阵营：%s / %s" % [campaign_id, level_id])
		return
	# ★★ 合作关跳过过渡与阵营选择（用户口径：仍走合作大厅 / 直接开局那一路）。
	if String(level.mode) == "coop":
		_on_campaign_level_chosen(campaign, level, String(playable[0]))
		return
	_show_level_transition(campaign, level)


## ★★ 主界面 ai_test_battle：跳过战役过渡画面，直接按关卡的可玩阵营开局。
##
## 与 `_on_level_entry_pressed()` 的区别只有「不挂过渡画面」：
##   关卡已经把玩家席位标成唯一可玩（ai_test_battle 是 p2），所以直接取第一个可玩阵营。
## 用于「快速试一把和 commander AI 对打」，不用先看简报再点进入。
func _on_direct_level_requested(campaign_id: String, level_id: String) -> void:
	if game != null:
		return
	var option := _find_campaign_option(campaign_id)
	if option.is_empty():
		push_warning("direct 关卡战役不存在：%s" % campaign_id)
		return
	var campaign = CampaignLibraryRes.load_campaign_by_option(option, cfg)
	if campaign == null:
		push_warning("direct 关卡战役载入失败：%s" % campaign_id)
		return
	var level = campaign.level(level_id) if campaign.has_method("level") else null
	if level == null:
		push_warning("direct 关卡不存在：%s / %s" % [campaign_id, level_id])
		return
	var playable: Array = level.playable_ids()
	if playable.is_empty():
		push_warning("direct 关卡没有可玩阵营：%s / %s" % [campaign_id, level_id])
		return
	_on_campaign_level_chosen(campaign, level, String(playable[0]))


## ★★ 主界面「ai_test / ai_test_2」按钮：载入演示战役对应关卡，AI 接管被观察方，玩家观战。
## 不走战役过渡 / 阵营选择：这一关只有一个席位，且它本来就是给观察 AI 用的。
## `allow_orders` = true（ai_test_2）时，观战仍允许用 AI 面板下四条指令；
## `reveal_all` = true 时只给玩家显示开全图（AI 逻辑仍走正常迷雾）。
func _on_ai_test_requested(campaign_id: String, level_id: String,
		allow_orders: bool = false, reveal_all: bool = false) -> void:
	if game != null:
		return
	var option := _find_campaign_option(campaign_id)
	if option.is_empty():
		push_warning("ai_test 战役不存在：%s" % campaign_id)
		return
	var campaign = CampaignLibraryRes.load_campaign_by_option(option, cfg)
	var level = campaign.level(level_id) if campaign != null and campaign.has_method("level") else null
	if level == null:
		push_warning("ai_test 关卡不存在：%s / %s" % [campaign_id, level_id])
		return
	game = GameSceneRes.new()
	game.name = "GameScene"
	add_child(game)
	if not game.start_ai_observer(level, allow_orders, reveal_all):
		game.queue_free()
		game = null
		return
	start_screen.close()
	game.fullscreen_toggled.connect(toggle_fullscreen)
	game.return_to_menu_requested.connect(return_to_menu)


## 在扫出来的战役表里按 id 找那一项（找不到 → 空字典）。
func _find_campaign_option(campaign_id: String) -> Dictionary:
	for item in CampaignLibraryRes.list_campaigns(cfg):
		if String((item as Dictionary).get("id", "")) == campaign_id:
			return item
	return {}


## ★★ 把「一份已载入的战役 + 那一关 + 用哪一方」装配进游戏。
##
## 与 `_on_test_pressed()` 的差别只有「怎么建世界」那一处（`game.start()` vs
## `game.start_level()`），其余完全同一条尾：失败就把半成品撤掉、留在菜单上。
##
## ⚠️ 进游戏之前**不**手动收面板：`start_screen.close()` 会把整层菜单隐藏，
##   撑开的面板跟着一起看不见；「返回主菜单」时由 `start_screen.reset_panels()`
##   一步收回到初始态（见 `return_to_menu()`）。
func _on_campaign_level_chosen(campaign, level, faction: String) -> void:
	if game != null:
		return                          # 已经在游戏里了（按钮只该生效一次）

	game = GameSceneRes.new()
	game.name = "GameScene"
	add_child(game)
	if not game.start_level(campaign, level, faction):
		game.queue_free()
		game = null
		# 装配失败：人留在主界面（战役菜单还在面板里，可以换一关再试）。
		return

	# 进游戏之后开场页整层下线（与老路径同一个理由：背景与点击处理器一起停掉）
	start_screen.close()

	game.fullscreen_toggled.connect(toggle_fullscreen)
	game.return_to_menu_requested.connect(return_to_menu)


# ------------------------------------------------------------------
# 战役过渡画面（缩略图 + 简报 + 多阵营选择 + 进度 + 点击进入）
# ------------------------------------------------------------------

## ★★ 单人关卡：先进过渡画面，再由玩家点「进入」才建世界。
## 合作关不走这里（`_on_level_entry_pressed` 里直接开局）。
##
## ★★ 打开时是一段**先隐后显**的转场（用户口径：长按战役进入时，战役界面渐隐，
##   随后再让过渡画面渐显）：
##     ① 先推黑幕（`open_fade_sec`，默认 0.22s）—— 战役界面连同撑开的面板一起渐隐；
##     ② 在黑幕底下建过渡页（它自己的面板滑入同时开始，于是渐显那一段能看到滑入）；
##     ③ 黑幕淡出（`open_fade_in_sec`，默认 0.34s）—— 过渡画面渐显。
##   ★ 复用 `_enter_fade` 那套黑幕：露出一块全屏纯色，顺带把这两拍里的点击挡掉
##     （否则玩家能在这 0.2s 里再点一次，长出第二个过渡页）。
##   ★ 动效总开关关掉 / 时长为 0 ⇒ 两拍都跳过，行为与以前完全一样（同步建页）。
func _show_level_transition(campaign, level) -> void:
	if _transition_opening:
		return
	if _level_transition != null and is_instance_valid(_level_transition):
		return
	var fade_out: float = _open_fade_sec()
	var fade_in: float = _open_fade_in_sec()
	var use_fade: bool = ThemeRes.animations_enabled() and fade_out > 0.0
	_transition_opening = true
	if use_fade:
		await _fade_to_black(fade_out)
	if not is_instance_valid(self):
		return
	# ★ 建页放在「黑幕最黑」这一刻：玩家看到的是「战役界面没了 → 过渡画面从黑里出来」，
	#   中间不会露出主菜单或清屏色。
	_level_transition = LevelTransitionRes.new()
	_level_transition.name = "LevelTransition"
	add_child(_level_transition)
	_level_transition.setup(cfg, _ui_font, campaign, level)
	_level_transition.enter_requested.connect(
		_on_level_transition_enter.bind(campaign, level))
	_level_transition.cancelled.connect(_on_level_transition_cancelled)
	_transition_opening = false
	if use_fade and fade_in > 0.0:
		await _fade_from_black(fade_in)
	elif use_fade:
		# 渐显时长配成 0：黑幕直接拆掉（不淡），页面立刻可见。
		_clear_enter_fade()


## 过渡画面里点「进入」：先黑屏，再收画面 + 建世界，等游戏首帧就绪后才从黑里淡出。
##
## ★★ 为什么黑屏层在本文件而不在过渡画面里（用户口径：进入游戏要有黑屏淡入淡出）：
##   转场的中间一步是「收掉过渡画面 → 建游戏场景」，这一瞬间背后是主菜单 / 空画面；
##   黑屏层如果挂在过渡画面上，会跟着 `queue_free()` 一起没掉，正好露出那一帧。
##   挂在 main 上才能从「点进入」一直盖到「游戏首帧画出来」，把接缝完全藏住。
##
## ★ 顺序不能反：
##   1. 先在过渡页上推成全黑（这 0.35s 里玩家看到的是过渡页渐暗，不是菜单）；
##   2. 全黑之后才收过渡页、建世界 —— 建世界是同步的，慢也发生在黑屏底下；
##   3. 等两帧再淡出黑（第一帧是游戏场景 `_ready` / 首帧绘制落地的时间）。
func _on_level_transition_enter(faction: String, campaign, level) -> void:
	# 信号只该发一次；万一连发，第二次直接忽略（黑屏层已经在跑了）。
	if _enter_fade != null and is_instance_valid(_enter_fade):
		return
	# 动效总开关关掉 = 立刻到位（与全项目同一条口径）：不建黑屏层，直接走老路径。
	if not ThemeRes.animations_enabled() or _enter_fade_sec() <= 0.0:
		_close_level_transition()
		_on_campaign_level_chosen(campaign, level, faction)
		return
	await _fade_to_black(_enter_fade_sec())
	if not is_instance_valid(self):
		return
	_close_level_transition()
	_on_campaign_level_chosen(campaign, level, faction)
	# ★ 建世界失败（game 仍是 null）也照样把黑幕淡掉：玩家回到菜单，
	#   而不是永远卡在一片全黑里（失败提示由 `_on_campaign_level_chosen` 负责）。
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_instance_valid(self):
		return
	await _fade_from_black(_enter_fade_in_sec())


## 把屏幕推成全黑（0 → 1）。
func _fade_to_black(sec: float) -> void:
	_ensure_enter_fade()
	if _enter_fade_rect == null or not is_instance_valid(_enter_fade_rect):
		return
	_enter_fade_rect.modulate.a = 0.0
	_enter_fade_tween = create_tween()
	_enter_fade_tween.tween_property(_enter_fade_rect, "modulate:a", 1.0, sec) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	await _enter_fade_tween.finished
	_enter_fade_tween = null


## 从全黑里淡出来（1 → 0），完了把黑屏层整个拆掉（不常驻一条全屏 ColorRect）。
func _fade_from_black(sec: float) -> void:
	if _enter_fade_rect == null or not is_instance_valid(_enter_fade_rect):
		_clear_enter_fade()
		return
	_enter_fade_rect.modulate.a = 1.0
	_enter_fade_tween = create_tween()
	_enter_fade_tween.tween_property(_enter_fade_rect, "modulate:a", 0.0, sec) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	await _enter_fade_tween.finished
	_enter_fade_tween = null
	_clear_enter_fade()


## 懒建黑屏层：第一次进入时才建（不在启动路径上多挂一层 CanvasLayer）。
func _ensure_enter_fade() -> void:
	if _enter_fade != null and is_instance_valid(_enter_fade) \
			and _enter_fade_rect != null and is_instance_valid(_enter_fade_rect):
		return
	if _enter_fade != null and is_instance_valid(_enter_fade):
		_enter_fade.queue_free()
	_enter_fade = CanvasLayer.new()
	_enter_fade.name = "EnterFade"
	_enter_fade.layer = ENTER_FADE_LAYER
	add_child(_enter_fade)
	_enter_fade_rect = ColorRect.new()
	_enter_fade_rect.name = "Black"
	var c: Color = _enter_fade_color()
	c.a = 1.0
	_enter_fade_rect.color = c
	_enter_fade_rect.modulate.a = 0.0
	_enter_fade_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# ★ 转场期间连点无效：黑幕既要盖住画面，也要挡住鼠标。
	_enter_fade_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	_enter_fade.add_child(_enter_fade_rect)


## 拆掉黑屏层（幂等；`return_to_menu()` 也会兜一次，避免残留一层黑幕）。
func _clear_enter_fade() -> void:
	if _enter_fade_tween != null and _enter_fade_tween.is_valid():
		_enter_fade_tween.kill()
	_enter_fade_tween = null
	if _enter_fade != null and is_instance_valid(_enter_fade):
		_enter_fade.queue_free()
	_enter_fade = null
	_enter_fade_rect = null


func _enter_fade_sec() -> float:
	if cfg == null:
		return DEFAULT_ENTER_FADE_SEC
	return maxf(0.0, cfg.num("menu.transition.enter_fade_sec", DEFAULT_ENTER_FADE_SEC))


func _enter_fade_in_sec() -> float:
	if cfg == null:
		return DEFAULT_ENTER_FADE_IN_SEC
	return maxf(0.0, cfg.num("menu.transition.enter_fade_in_sec", DEFAULT_ENTER_FADE_IN_SEC))


func _enter_fade_color() -> Color:
	if cfg == null:
		return Color.BLACK
	return ConfigRes.parse_color(
		cfg.str_val("menu.transition.enter_fade_color", "#000000"), Color.BLACK)


## 「把过渡画面推出来」的两拍时长（见 `_show_level_transition` 的说明）。
func _open_fade_sec() -> float:
	if cfg == null:
		return DEFAULT_OPEN_FADE_SEC
	return maxf(0.0, cfg.num("menu.transition.open_fade_sec", DEFAULT_OPEN_FADE_SEC))


func _open_fade_in_sec() -> float:
	if cfg == null:
		return DEFAULT_OPEN_FADE_IN_SEC
	return maxf(0.0, cfg.num("menu.transition.open_fade_in_sec", DEFAULT_OPEN_FADE_IN_SEC))


## 当前黑屏转场层（只给测试 / 排查用；没有则是 null）。
func enter_fade():
	return _enter_fade_rect if _enter_fade_rect != null and is_instance_valid(_enter_fade_rect) else null


## Esc 取消：收掉过渡画面，留在主界面（不建世界）。
func _on_level_transition_cancelled() -> void:
	_close_level_transition()


func _close_level_transition() -> void:
	if _level_transition != null and is_instance_valid(_level_transition):
		_level_transition.queue_free()
	_level_transition = null


## 当前过渡画面（只给测试 / 排查用；没有则是 null）。
func level_transition():
	return _level_transition if _level_transition != null and is_instance_valid(_level_transition) else null


## ★★ 合作大厅：房主点了开始。transport 已经由大厅交出来。
## 关卡载入与单人入口共用 `_find_campaign_option` / `CampaignLibrary`（数据只有一个来源）；
## 真正的世界与网络接线在 `game_scene3d.start_coop_host()`。
func _on_coop_host_started(campaign_id: String, level_id: String, transport) -> void:
	if game != null:
		if transport != null:
			transport.close()
		return
	var option := _find_campaign_option(campaign_id)
	if option.is_empty():
		push_warning("合作战役不存在：%s" % campaign_id)
		if transport != null:
			transport.close()
		return
	var campaign = CampaignLibraryRes.load_campaign_by_option(option, cfg)
	var level = campaign.level(level_id) if campaign != null and campaign.has_method("level") else null
	if level == null or String(level.mode) != "coop":
		push_warning("合作关卡不存在或不是 coop：%s / %s" % [campaign_id, level_id])
		if transport != null:
			transport.close()
		return
	game = GameSceneRes.new()
	game.name = "GameScene"
	add_child(game)
	if not game.start_coop_host(campaign, level, transport):
		if transport != null:
			transport.close()
		game.queue_free()
		game = null
		return
	start_screen.close()
	game.fullscreen_toggled.connect(toggle_fullscreen)
	game.return_to_menu_requested.connect(return_to_menu)


## ★★ 合作模式「AI 队友」：本地单人开局（无 transport / 无 HostSession）。
## 关卡载入与真人合作局共用同一段；真正的世界装配在 `game_scene3d.start_coop_solo()`。
func _on_coop_solo_started(campaign_id: String, level_id: String, ai_setup: Dictionary) -> void:
	if game != null:
		return
	var option := _find_campaign_option(campaign_id)
	if option.is_empty():
		push_warning("合作战役不存在：%s" % campaign_id)
		return
	var campaign = CampaignLibraryRes.load_campaign_by_option(option, cfg)
	var level = campaign.level(level_id) if campaign != null and campaign.has_method("level") else null
	if level == null or String(level.mode) != "coop":
		push_warning("合作关卡不存在或不是 coop：%s / %s" % [campaign_id, level_id])
		return
	game = GameSceneRes.new()
	game.name = "GameScene"
	add_child(game)
	if not game.start_coop_solo(level, ai_setup):
		game.queue_free()
		game = null
		return
	start_screen.close()
	game.fullscreen_toggled.connect(toggle_fullscreen)
	game.return_to_menu_requested.connect(return_to_menu)


## ★★ 合作大厅：客机收到房主的 `start`（lobby 已把 transport 交出来）。
func _on_coop_guest_started(payload: Dictionary, transport) -> void:
	if game != null:
		if transport != null:
			transport.close()
		return
	game = GameSceneRes.new()
	game.name = "GameScene"
	add_child(game)
	if not game.start_coop_guest(payload, transport):
		if transport != null:
			transport.close()
		game.queue_free()
		game = null
		return
	start_screen.close()
	game.fullscreen_toggled.connect(toggle_fullscreen)
	game.return_to_menu_requested.connect(return_to_menu)


## ★ 选项页里点了「返回主菜单」：拆掉游戏场景，把开场页放回**主界面那一页**。
##
## ★★ 为什么不重启进程 / 不新建开场页：
##   · 不重启：玩家只是想换张图（甚至只是误点），重启等于把窗口、全屏状态、字体
##     全部重来一遍 —— 又慢又可能丢状态；
##   · 不新建：原来那个 StartScreen 一直挂在树上（只是 `close()` 成隐藏），
##     它里面那条地图选择条**还留着玩家上次选的那张图** —— 新开一局就是同一个选择，
##     这正是「退回菜单再进来」该有的手感。
##
## ★ 顺序（拆旧 → 放新）不能反：
##   1. 先把 game 摘下来（`remove_child` + `queue_free`）而不是只 `queue_free()`：
##      `queue_free` 要到帧末才真的销毁，那一帧里 game_scene 的 `_process` 还会跑、
##      `_unhandled_input` 还会接事件，而此时菜单已经在底下等着被点了 ——
##      表现就是「刚回到菜单，底下那个世界还在动，点一下还指挥到了单位」。
##      `remove_child` 立刻让它离开场景树（`_process` / 输入一起停）。
##   2. 再把 game 置空：`_unhandled_input` 与 `_on_test_pressed` 都以它为「有没有在游戏里」
##      的判据，置空之后「再点一次 test」才会真的建一局新的。
##   3. 最后 `open_menu()`：回主界面、**不**回入场页（那一次「点击任意处」玩家已经付过了）。
##      ⚠️ 必须走 `open_menu()` 而不是 `show_page(PAGE_MENU)`：前者带 `show()` ——
##         `close()` 那次 hide() 之后整层是隐藏的，只切页内两层的话主界面看着在、
##         实际点不动（坑写在 start_screen.gd 那个函数的注释里）。
##
## ★ 幂等：不在游戏里（game 为 null）时什么都不做 —— 选项页的按钮可能被连点，
##   而那一下不该造出第二个开场页。
func return_to_menu() -> void:
	_close_level_transition()
	# ★ 刚进游戏就马上回菜单时，黑屏淡出可能还没跑完；这里先把它收掉，
	#   否则主界面上会残留一层（最多 0.4s 的）黑幕，期间点哪里都点不动。
	_clear_enter_fade()
	if game == null:
		return
	var leaving := game
	game = null
	# ★ 顺手把选项页收起来：那个面板活在这一局里，而回到菜单之后开场页的
	#   背景会盖在它下面（CanvasLayer layer=100 对 HUD 的默认 1）——
	#   不收的话，等下次进游戏它会**还开着**（HUD 是新建的，但同一帧的旧 HUD
	#   会带着开着的面板一起被销毁，看着像闪了一下）。
	# ⚠️ 这里必须用 `is_instance_valid()` 而不是 `!= null`：走进本函数的那条路
	#    （HUD 按钮 → 信号 → game_scene → 本函数）中间**可能已经被裁决销毁过一次**
	#    （比如玩家连点、或者场景正在被拆），此时 `hud` 已经不是 null 而是
	#    「previously freed」，写 `!= null` 会直接报
	#    「Invalid call. Nonexistent function '...' in base 'previously freed'」。
	if is_instance_valid(leaving) and is_instance_valid(leaving.hud):
		leaving.hud.set_settings_menu_open(false)
	# 合作局：主菜单路径也要先把 bye / transport 收干净（幂等；已收过就是空操作）。
	if is_instance_valid(leaving) and leaving.has_method("_shutdown_coop"):
		leaving._shutdown_coop()
	# ⚠️ 拆之前再确认一次：上面那几行（尤其 `is_instance_valid(leaving.hud)`）在
	#   「本场景正在被销毁」那条路上可能刚好跨过一帧，`leaving` 那时已经没了。
	#   `remove_child` 一个已释放的对象会直接报错，所以两道判断都留着。
	if is_instance_valid(leaving):
		remove_child(leaving)
		leaving.queue_free()
	if start_screen != null:
		# ★★ 先把可能开着的战役面板一步收回初始态，再显示主界面 ——
		#   从战役菜单长按进游戏时那一层只是 hide() 了，面板还停在撑开态。
		start_screen.reset_panels()
		start_screen.open_menu()


# ------------------------------------------------------------------
# 转发给游戏内场景（★ _process 仍然只有一处，就在 game_scene 里）
# ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	# ★ 开发者快捷键（Ctrl+Q 全屏）放在这里，而不是 input_controller ——
	#   它要在**任何一页**都能按：开场页 / 主界面根本没有 world 与 input_controller
	#   （那两个是按下 test 进游戏时才建的）。
	#   窗口模式本来也就是本文件的事 —— 它已经接管了 NOTIFICATION_WM_CLOSE_REQUEST。
	if _handle_window_hotkey(event):
		get_viewport().set_input_as_handled()
		return
	if game != null:
		game._unhandled_input(event)


## Ctrl+Q：全屏 ↔ 窗口（开发者快捷键）。
##
## ★ 为什么要记住「进全屏之前是哪种窗口模式」：Godot 有五种窗口模式
##   （windowed / minimized / maximized / fullscreen / exclusive fullscreen）。
##   这里的语义只是「在全屏和窗口之间切」，退出时直接写 WINDOW_MODE_WINDOWED
##   会把「最大化」这类状态吃掉 —— 而开发时常常就是最大化窗口在调的。
## ★ 用 WINDOW_MODE_FULLSCREEN（无边框全屏）而不是 EXCLUSIVE_FULLSCREEN：
##   前者切换更快、对多显示器更友好，这个游戏没有需要独占全屏的理由。
## ⚠️ 必须判 ctrl：Q 本身是命令卡第 0 格的键（招募），不判的话按一下 Q 就跳全屏。
##   （反过来的那一半在 command_card.handle_key：它必须放行带修饰键的组合。）
## ⚠️ 无头（--headless）下 DisplayServer 是空实现，不会真的改窗口模式 ——
##   所以测试只验「这个按键归谁消费」，不去断言真实窗口状态（见 tests/test_view.gd）。
##
## @return true = 本事件已被消费
func _handle_window_hotkey(event: InputEvent) -> bool:
	if not (event is InputEventKey):
		return false
	var k: InputEventKey = event as InputEventKey
	if not k.pressed or k.echo:
		return false
	if k.keycode != KEY_Q or not k.ctrl_pressed:
		return false
	toggle_fullscreen()
	return true


## ★★ 全屏 ↔ 窗口（**唯一的实现**）。
##
## 两条入口都走它：开发者快捷键 Ctrl+Q（`_handle_window_hotkey`）与
## 游戏内「设置 → 全屏 / 窗口化」（`game.fullscreen_toggled` 连到这里）。
## ★ 为什么必须只有一份：它记着「进全屏之前是哪种窗口模式」（见下面那条注释），
##   抄成两份的话，其中一份早晚会忘了还原 —— 表现是「按 Ctrl+Q 退出全屏之后
##   窗口变成 1280×720」，而用选项页退就不会。
##
## ⚠️ 无头（`--headless`）下 DisplayServer 是空实现：这个函数**什么都不会发生**
##   （也不会报错）。所以测试只验「请求真的走到了这里」，不去断言真实窗口模式。
func toggle_fullscreen() -> void:
	var mode: int = DisplayServer.window_get_mode()
	if mode == DisplayServer.WINDOW_MODE_FULLSCREEN \
			or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
		DisplayServer.window_set_mode(_windowed_mode)
	else:
		_windowed_mode = mode
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# ★ 桌面窗口 X **不拦**（nsoc 原样）：直接退出，不弹确认浮层。
		get_tree().quit()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
		# ★ 安卓返回：引擎那边已由 project.godot 的 config/quit_on_go_back=false 放行，
		#   这里按「取消浮层 → 关选项页 → 弹退出确认」三档处理。
		_on_android_back()
