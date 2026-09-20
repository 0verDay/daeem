## main.gd —— ★ 入口 / 唯一的流程调度者：开场页 → 主界面 → 游戏内场景
##
## 流程（需求原文）：
##   1. 启动 = 白屏入场页：上方标题 DAEEM；屏幕下方「————点击任意处进入游戏————」，
##      呼吸式渐显渐隐
##   2. 点击任意处 → 主界面（本轮没有别的 UI，屏幕正中央一个 test 按钮）
##   3. 按下 test → 建逻辑世界并进入游戏内场景（就是以前启动就直接进的那一套）
##
## ★ 为什么把「建世界」从 _ready 挪到按下 test 那一刻（而不是先建好再拿白屏盖住）：
##   进游戏之前 world / 相机 / HUD 都不该存在 —— 否则世界会在菜单背后偷偷 tick，
##   而「地图载入失败」这种错也会在玩家还没进游戏时就弹出来。
##   代价是按下按钮那一帧要跑一次装配（载地图 + 字体 + 搭 HUD），原型阶段这点开销无所谓。
##
## ★ 职责边界（三层各管一段，谁都不越界）：
##   view/start_screen.gd  开场两页：只认输入与自己的两个信号，不认识 world
##   view/game_scene.gd    游戏内场景：装配 world + view + hud，跑主循环
##   本文件                只做连接：把「按钮被按了」翻译成「进游戏」
##   没有任何一层把玩法规则写进来 —— 规则全在 logic/。
##
## 调试句柄：控制台里 `RTS`（等价于 HTML 版的 window.RTS）。★ 现在它指向游戏内场景
## （view/game_scene.gd），所以**进游戏之前是 null** —— 那是刻意的，没世界可调。
extends Node2D

const ConfigRes = preload("res://logic/config.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")
const StartScreenRes = preload("res://view/start_screen.gd")
const GameSceneRes = preload("res://view/game_scene.gd")

## 开场页用的字体基准字号（标题 / 提示 / 按钮各自另有字号，见 config.json 的 menu 段）
const MENU_FONT_SIZE := 32

var cfg: ConfigRes = null
var start_screen: CanvasLayer = null
var game: Node2D = null


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


# ------------------------------------------------------------------
# 开场页 → 主界面 → 游戏
# ------------------------------------------------------------------

## 入场页被点掉了。★ 目前不需要额外动作（页面切换在 start_screen 内部完成），
##   但这条线要留着：以后主界面要放「继续游戏 / 设置」之类需要读存档的东西，就在这里接。
func _on_intro_dismissed() -> void:
	pass


## 主界面按下 test：建世界并进游戏。
func _on_test_pressed() -> void:
	if game != null:
		return          # 已经进过游戏了（按钮只该生效一次）

	game = GameSceneRes.new()
	game.name = "GameScene"
	add_child(game)
	if not game.start():
		# 装配失败：把半成品撤掉，玩家留在主界面上，而不是进到一个空的游戏里
		game.queue_free()
		game = null
		return

	# 进游戏之后开场页整层下线：白底与「点击任意处」的处理器一起停掉
	start_screen.close()


# ------------------------------------------------------------------
# 转发给游戏内场景（★ _process 仍然只有一处，就在 game_scene 里）
# ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if game != null:
		game._unhandled_input(event)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		get_tree().quit()
