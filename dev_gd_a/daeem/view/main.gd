## main.gd —— ★ 入口 / 唯一的流程调度者：开场页 → 主界面 → 游戏内场景
##
## 流程（需求原文）：
##   1. 启动 = 暗色渐变入场页：上方徽记 + 标题 DAEEM；屏幕下方「————点击任意处进入游戏————」，
##      呼吸式渐显渐隐
##   2. 点击任意处 → 主界面（屏幕正中的一条**地图选择条** + 它下面的 test 按钮）
##   3. 按下 test → 用**选中的那张地图**建逻辑世界并进入游戏内场景
##   4. ★ 游戏内的「设置 → 返回主菜单」→ 拆掉游戏场景、把主界面放回**第 2 步**那个状态
##
## ★ 为什么把「建世界」从 _ready 挪到按下 test 那一刻（而不是先建好再拿白屏盖住）：
##   进游戏之前 world / 相机 / HUD 都不该存在 —— 否则世界会在菜单背后偷偷 tick，
##   而「地图载入失败」这种错也会在玩家还没进游戏时就弹出来。
##   代价是按下按钮那一帧要跑一次装配（载地图 + 字体 + 搭 HUD），原型阶段这点开销无所谓。
## ★ 地图是**按那一刻选中的那张**建的：选择条的意义就在这里 ——
##   建世界的调用只在本文件一处，所以「选了第二张图却进了第一张」这种错没有第二个入口。
##
## ★★ 窗口模式与「回菜单」这两件事**只在本文件实现**（本轮新增的设置菜单是第二条入口）：
##   · `toggle_fullscreen()` —— Ctrl+Q 与设置菜单里的「全屏」都走它，
##     否则两份实现迟早会漂（一份记得还原进入全屏前的窗口模式、另一份忘了）。
##   · `return_to_menu()` —— 拆游戏场景、放回开场页。★ 不重启进程、不新建开场页：
##     玩家上一次选的地图还留在那条选择条上（见那里的注释）。
##
## ★ 职责边界（三层各管一段，谁都不越界）：
##   view/start_screen.gd  开场两页：只认输入、地图选择与自己的两个信号，不认识 world
##   view/game_scene.gd    游戏内场景：装配 world + view + hud，跑主循环
##   view/hud.gd           游戏内 UI：设置菜单只**发信号**，不切窗口也不拆场景
##   本文件                只做连接：把「按钮被按了 + 选了哪张图」翻译成「进哪个游戏」，
##                         把「设置里点了全屏 / 回菜单」翻译成窗口模式与流程切换
##   没有任何一层把玩法规则写进来 —— 规则全在 logic/。
##
## 调试句柄：控制台里 `RTS`（等价于 HTML 版的 window.RTS）。★ 现在它指向游戏内场景
## （view/game_scene.gd），所以**进游戏之前是 null** —— 那是刻意的，没世界可调。
extends Node2D

const ConfigRes = preload("res://logic/config.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")
const StartScreenRes = preload("res://view/start_screen.gd")
## ★★ 入口**暂时仍是 2D**（`game_scene.gd`）—— 这一轮试过切到 3D，**切完回退了**。
##
## ⚠️⚠️ 回退的原因与证据（改这行之前必读）：
##   把这一行改成 `res://view/game_scene3d.gd` 之后，全套从「38 文件 / 5524 项全绿」
##   掉到「**85 项失败**」，失败集中在 4 个集成测试，而且**不是节点名对不上那么简单**：
##     · `test_ui`（原 1074 项全绿）→ 75 项失败：科技格点击不生效、招募队列不排、
##       悬停提示不更新 —— 这些交互链**依赖 2D 场景暴露的一整套视图层接口**
##       （`game.level_playing`、`hud` 信号接线、各面板 → 命令那条路），
##       而 `game_scene3d` 目前**只重写了渲染**，还没把这些接回去；
##     · `test_view` 8 项 / `test_campaign_test` 1 项 / `test_settings_menu` 1 项：
##       同类原因（老路径的字段与信号）。
##
## ★★ 两次试切的实测曲线（本节最该看的东西）：
##   ① 第一次（只切 preload，3D 场景还没补任何交互接口）
##      ⇒ `38 文件 / 5249 项 / 5164 通过 / **85 失败**`
##        （test_ui 75、test_view 8、test_campaign_test 1、test_settings_menu 1）
##   ② 第二次（补了主循环的**暂停门** + 把事件提示委托给 `game_interaction.gd`）
##      ⇒ `test_ui **929 通过 / 54 失败**`（第一次是 75 失败）
##
## ★ 第二次才看出来的关键事实：那 85 条**几乎全不是「缺成员」** ——
##   运行期只有 1 条 `Nonexistent function '_selected_buildings'`，其余都是**行为差异**，
##   其中最大的一类来自**主循环漏了暂停门**：
##   2D 版把 `world.tick()` 夹在 `if _running:` 里
##   （`_running = not input_ctrl.paused`）⇒ **暂停时逻辑冻结、但渲染与相机照旧**。
##   3D 主循环一开始没有这个门，表现是「暂停之后世界还在跑」；在测试里的样子则是
##   「同一条操作被记了两次」（`entries=["zone_specialize", "zone_specialize"]`）。
##   补上之后 test_ui 直接从 75 失败降到 54。
##
## ★ 还差什么（下一轮从这里接着做）：剩下的 54 条集中在
##   `_selected_buildings`（缺这个成员）、区划特化的读条/取消/汇总文案、
##   以及悬停提示的刷新时机 ⇒ **交互接口还剩一小半没补**。
##
## ⚠️ 为什么两次都回退而不是留着红：**基线保持全绿**是本项目所有后续验证的前提
##   （见 route.md 的验收口径）。留着 54 条红，后面任何一次改动都无法判断
##   「是我弄坏的还是本来就红的」。3D 栈本身由 `tests/test_view3d.gd`（41 项）
##   与 `tests/bench_fps_3d.gd` 独立验证，不受入口影响。
#### ★ 所以「3D 渲染栈已完成」与「3D 场景可以当主入口」是**两件事**：
##   前者已完成并在 `tests/test_view3d.gd`（41 项）与 `tests/bench_fps_3d.gd` 下验证；
##   后者还差「把视图层的交互接口补齐」那一步，那是**独立的一项工作**。
##   ⇒ 在补齐之前，入口保持 2D，基线保持全绿；3D 栈由测试与基准驱动。
##
## ⚠️ 回退过程中实测到的另一个坑（已随回退修掉，留作记录）：
##   切 3D 时 `main.gd` 的 `var game: Node2D` 会直接 Parse Error
##   （`Node3D` 与 `Node2D` 是平级的两个分支）⇒ **整个 main.gd 载不进来** ⇒
##   主界面起不来、`test_map_select` 从 73 项掉到 25 项。症状看着像「界面坏了」，
##   根因只是那一行的类型标注。所以那个字段现在写成 `Node`（见下面 `var game`）。
const GameSceneRes = preload("res://view/game_scene3d.gd")
## ★ 单人战役的**占位界面**（主界面第二颗按钮 `campaign_test` 点进来的那一页）。
const CampaignTestRes = preload("res://view/campaign_test.gd")
## 扫 `data/campaigns/` 给那一页出选项（★ 扫目录这件事只做在 main 这一处：
## 界面不认识「战役数据从哪来」，与地图选择条同一个口径）。
const CampaignLibraryRes = preload("res://logic/campaign_library.gd")

## 开场页用的字体基准字号（标题 / 提示 / 按钮各自另有字号，见 config.json 的 menu 段）
const MENU_FONT_SIZE := 32

var cfg: ConfigRes = null
var start_screen: CanvasLayer = null
## ★ 单人战役的占位界面（`view/campaign_test.gd`；没打开时是 null）。
var campaign_screen: CanvasLayer = null
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

	start_screen = StartScreenRes.new()
	start_screen.name = "StartScreen"
	add_child(start_screen)
	start_screen.setup(cfg, font)

	start_screen.intro_dismissed.connect(_on_intro_dismissed)
	start_screen.test_pressed.connect(_on_test_pressed)
	start_screen.campaign_test_pressed.connect(_on_campaign_test_pressed)


# ------------------------------------------------------------------
# 开场页 → 主界面 → 游戏
# ------------------------------------------------------------------

## 入场页被点掉了。★ 目前不需要额外动作（页面切换在 start_screen 内部完成），
##   但这条线要留着：以后主界面要放「继续游戏 / 设置」之类需要读存档的东西，就在这里接。
func _on_intro_dismissed() -> void:
	pass


## 主界面按下 test：用**选中的那张地图**建世界并进游戏。
##
## ★ 参数由 start_screen 带出来（它才知道玩家在下拉框里选了哪一项）；
##   这里不读任何默认值 —— 「默认进哪张图」这件事只该有一个决定点，
##   否则以后改默认地图就会出现「按钮显示的是一张、进去的是另一张」。
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

	# ★★ 设置菜单里那两条请求（全屏 / 返回主菜单）——见本文件头部「职责边界」。
	game.fullscreen_toggled.connect(toggle_fullscreen)
	game.return_to_menu_requested.connect(return_to_menu)


# ------------------------------------------------------------------
# 单人战役的占位入口（主界面 campaign_test 按钮）
# ------------------------------------------------------------------

## ★ 按下 `campaign_test`：挂出 `view/campaign_test.gd` 那一页（列关卡 + 选阵营 + 开始）。
##
## ★★ 三件事刻意放在这里而不是那一页里（见 `view/campaign_test.gd` 的文件头）：
##   1. **扫战役目录**（`campaign_library.list_campaigns(cfg)`）—— 数据只有一个来源，
##      那一页只管显示；扫出来的选项与「点进去真的能载入」是同一条路。
##   2. 那一页是 `CanvasLayer`（layer 与开场页同一层），挂在 main 下。
##   3. 「选了哪一关就进游戏」这条接线（`level_chosen` → `_on_campaign_level_chosen`）——
##      那一页不认识 `game_scene`，也不认识 `world`。
##
## ⚠️ 幂等：已经开着就不再挂第二页（连点两下按钮不会挂出两层背景）。
func _on_campaign_test_pressed() -> void:
	if campaign_screen != null or game != null:
		return
	var font := FontLoaderRes.load_font(cfg)
	campaign_screen = CampaignTestRes.new()
	campaign_screen.name = "CampaignTestScreen"
	add_child(campaign_screen)
	campaign_screen.setup(CampaignLibraryRes.list_campaigns(cfg), cfg, font)
	campaign_screen.level_chosen.connect(_on_campaign_level_chosen)
	campaign_screen.back_pressed.connect(_on_campaign_back)


## ★★ 在战役页里选好了「哪一关 + 用哪一方」→ 用**关卡装配**那条路进游戏。
##
## 与 `_on_test_pressed()` 的差别只有「怎么建世界」那一处（`game.start()` vs
## `game.start_level()`），其余完全同一条尾：失败就把半成品撤掉、留在菜单上。
##
## ⚠️ 顺序：**先把战役页收掉**再建世界。反过来（先建再收）在无头测试里会看到
##    `_unhandled_input` 一条帧内同时发给两页；而且玩家会看到「载入那一帧」上面
##    还压着一层背景。
func _on_campaign_level_chosen(campaign, level, faction: String) -> void:
	if game != null:
		return                          # 已经在游戏里了（按钮只该生效一次）
	_close_campaign_screen()

	game = GameSceneRes.new()
	game.name = "GameScene"
	add_child(game)
	if not game.start_level(campaign, level, faction):
		game.queue_free()
		game = null
		# 装配失败：把战役页放回来，玩家还能换一关/换一方再试 —— 而不是被丢回主界面
		# （「菜单上有个进不去的入口」比「这一页还开着、能改选」难查得多）。
		_on_campaign_test_pressed()
		return

	# 进游戏之后开场页整层下线（与老路径同一个理由：背景与点击处理器一起停掉）
	start_screen.close()

	game.fullscreen_toggled.connect(toggle_fullscreen)
	game.return_to_menu_requested.connect(return_to_menu)


## 战役页里点了「返回」：收掉那一页，回主界面（开场页本来就还在，只要别关它）。
func _on_campaign_back() -> void:
	_close_campaign_screen()


## 收掉战役占位页（幂等：没开时什么都不做）。
func _close_campaign_screen() -> void:
	if campaign_screen == null:
		return
	var leaving := campaign_screen
	campaign_screen = null
	# ⚠️ 与 return_to_menu() 里那两处同一个理由：这一帧里它可能已经被裁决销毁过，
	#    判空要用 is_instance_valid()，不能写 `!= null`。
	if is_instance_valid(leaving):
		remove_child(leaving)
		leaving.queue_free()


## ★ 设置菜单里点了「返回主菜单」：拆掉游戏场景，把开场页放回**主界面那一页**。
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
## ★ 幂等：不在游戏里（game 为 null）时什么都不做 —— 设置菜单的按钮可能被连点，
##   而那一下不该造出第二个开场页。
func return_to_menu() -> void:
	if game == null:
		return
	# ★ 顺手收掉战役占位页：它是「进游戏之前」的一层，回到主界面时不该还开着
	#   （正常路径上它进游戏之前就收了；这一句挡的是「装配失败又放回来」那条路）。
	_close_campaign_screen()
	var leaving := game
	game = null
	# ★ 顺手把设置菜单收起来：那个面板活在这一局里，而回到菜单之后开场页的
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
	# ⚠️ 拆之前再确认一次：上面那几行（尤其 `is_instance_valid(leaving.hud)`）在
	#   「本场景正在被销毁」那条路上可能刚好跨过一帧，`leaving` 那时已经没了。
	#   `remove_child` 一个已释放的对象会直接报错，所以两道判断都留着。
	if is_instance_valid(leaving):
		remove_child(leaving)
		leaving.queue_free()
	if start_screen != null:
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
##   窗口变成 1280×720」，而用设置菜单退就不会。
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
		get_tree().quit()
