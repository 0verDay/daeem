## start_screen.gd —— 开场两页：入场页 → 主界面
##
##   入场页：上方**几何徽记 + 带字距的标题 DAEEM + 金色分隔线**；
##           屏幕下方「————点击任意处进入游戏————」，淡入之后呼吸式渐显渐隐
##   主界面：**标题条（徽记 + 字标 + 金线）+ 版式外壳**（左上资料 / 左侧导航 / 右下入口，
##           见 view/menu_chrome.gd）
##
## ★★ 「点击任意处」是**两段动画**（见 `_play_intro_morph()` 与 view/panel_expand.gd 的
##   `play_intro()`）：① 徽记 / 标题 / 金线**落位**到主界面标题条里各自的位置
##   （字号字距一起过渡，落位后切页看不出接缝）；② 切页 + 外壳那三块面板**滑入**。
##   动效总开关关掉时两段都跳过、当场到位。
##
## ★★ 主界面上的**进游戏入口**有两处：
##   · 正中那一列 `MenuColumn`：**五颗测试入口**（各自直连一关，见 `_build_menu`）；
##   · 右下「战役」按钮撑开的面板：**战役菜单**（`view/campaign_menu.gd`，长按进入某一关）。
##   两路都归到本文件的同一个信号 `level_entry_pressed(campaign_id, level_id)` ——
##   ⇒ `view/main.gd` 那侧只认这一个信号（载入战役 / 建世界都在它那儿）。
##
## ★★ 配色与风格（参考图的「暗色渐变底 + 金色细线边框 + 纯几何形状」）：
##   · 底：`view/menu_background.gd`（竖直渐变 + 中心辉光 + 上下金线），**不再有白底**；
##   · 控件：`view/menu_theme.gd`（透明底 + 1px 金线；选定态才是实心金）；
##   · 图形：`view/menu_emblem.gd`（纯 `_draw()` 的几何徽记，零贴图）；
##   · 文字：Label + `view/text_marks.gd` 的两个自绘控件（带字距的标题、金线）。
##   ★ 配色一个都不在本文件里写死：全部来自 `data/config.json` 的 `theme.palette`
##     （经 view/theme.gd）。文案 / 字号 / 位置仍然全部来自 `menu` 段 —— 代码里不写文案字面量。
##
## ★ 为什么单开一个文件而不是塞进 main.gd：
##   这两页在游戏**开始之前**，生命周期与游戏内场景完全不同（那时 world 还是 null），
##   混在一起会让 main.gd 里到处都是 `if 还在菜单里` 的分支 —— 那正是最容易长出陈年 bug 的写法。
##   ★ 但主循环仍然只有一处：这里没有 _process，只有输入、信号与几条 Tween。
##
## ★ 全部用代码搭 Control 树、不建 .tscn（与 hud.gd 同一个理由）：
##   纯文本、可 diff、无头测试能直接实例化检查；代价是不能在编辑器里可视化调布局。
##
## 点击是怎么被收到的（★ 这里踩过一次坑，别再改回去）：
##   整页铺一个 mouse_filter = STOP 的 `Background`（`view/menu_background.gd`，
##   它同时负责画渐变底），`gui_input` **接在它身上**。
##   ⚠️ 第一版把处理器接在父节点 StartRoot 上，结果**点不动**：Godot 的 GUI 命中测试只把事件
##      交给鼠标下**最上层**的那个 Control，而 Background 是后 add_child 的、盖在父节点之上，
##      事件到它那里就停了，父节点的 gui_input 永远不会被调用（父节点不是「上一层」）。
##      所以：收事件的那一个节点，必须就是鼠标下最上层的那一个。
##   标题与提示 Label 一律 IGNORE，否则点在字上会被文字吃掉、点不进游戏。
##   ★★ 于是新加的东西也必须守这条：自绘控件（标题 / 徽记 / 金线 / 扫光）
##      全部 `mouse_filter = IGNORE`（在各自的文件里设死），
##      否则「点击任意处」会在那些**看不见的矩形**上失效 —— 这是最容易踩的坑。
##   CanvasLayer 用 layer = 100，只是保证它画在游戏画面（Hud 那层用的是默认的 1）之上。
extends CanvasLayer

const ConfigRes = preload("res://logic/config.gd")
const ThemeRes = preload("res://view/theme.gd")
const MenuBackgroundRes = preload("res://view/menu_background.gd")
const MenuEmblemRes = preload("res://view/menu_emblem.gd")
const TextMarksRes = preload("res://view/text_marks.gd")
## ★★ 主界面的**新版式外壳**（左上资料 / 左侧导航 / 右下入口，仿 nsoc 的主菜单）——
##    它自带「点按钮撑开面板 + 其他 UI 让路」的机制（view/menu_chrome.gd + view/panel_expand.gd）。
const MenuChromeRes = preload("res://view/menu_chrome.gd")
## ★★ 悬停时「金色自下而上填进来」的那套动效（见 view/fill_button.gd）。
const FillButtonRes = preload("res://view/fill_button.gd")
## ★ 正中那几颗测试按钮的线框样式（与外壳上的按钮同一套）。
const MenuThemeRes = preload("res://view/menu_theme.gd")
## ★★ 选项页菜单（仿 nsoc）：与 HUD 右上角「选项」共用 view/options_panel.gd。
const OptionsPanelRes = preload("res://view/options_panel.gd")

## 入场页被点掉了（main.gd 只需知道这件事，不必知道点的哪个像素）
signal intro_dismissed
## ★★ 玩家选定了「从哪一关进游戏」（主界面正中的 test 按钮，或「战役」面板里长按的那一关）。
##
## ★ 参数是**数据**（战役 id + 关卡 id），不是已经载入的对象：
##   本页不认识 `data/campaigns/`、也不认识 `world` —— 载入战役、挑阵营、建世界
##   全在 `view/main.gd` 那一处（与战役目录扫描同一个口径：数据只有一个来源）。
signal level_entry_pressed(campaign_id: String, level_id: String)
## ★★ 主界面 ai_test_battle：跳过战役过渡画面，直接按关卡的可玩阵营开局。
signal direct_level_requested(campaign_id: String, level_id: String)
## ★★ 主界面 ai_test / ai_test_2 按钮：进入观战（AI 操作被观察方，玩家只看）。
## `allow_orders` = true 时仍允许用 AI 面板下四条指令（ai_test_2）；
## `reveal_all` = true 时只给玩家显示开全图，AI 逻辑仍读正常迷雾（ai_test_2）。
signal ai_test_requested(campaign_id: String, level_id: String,
	allow_orders: bool, reveal_all: bool)
## 合作大厅的开局（transport 已从 lobby 交出来）。
signal coop_host_started(campaign_id: String, level_id: String, transport)
signal coop_guest_started(payload: Dictionary, transport)
## ★★ 合作「AI 队友」本地开局：没有 transport，只带难度设置。
signal coop_solo_started(campaign_id: String, level_id: String, ai_setup: Dictionary)
## ★★ 主菜单「选项 → 设置 → 全屏 / 窗口化」：与游戏内同一条信号链，窗口模式由 main.gd 改。
signal fullscreen_toggled
## ★★ 主菜单「选项 → 退出游戏」：真正 quit 仍是 main.gd 的事。
signal quit_requested

const PAGE_INTRO := 0
const PAGE_MENU := 1

## 提示文案呼吸一次（暗 → 亮）的时长（秒）。★ 这是**动画节奏**，不是玩法数值，
## 与 ui_style.gd 的字号常量同一性质，所以留在 view/ 层而不进 config.json。
const BLINK_PHASE_SEC := 1.2

## 入场页淡入之后、呼吸开始之前的停顿（秒）。★ 让「淡入」与「呼吸」在观感上分成两拍：
##   一边淡入一边呼吸的话，第一眼的印象是「这块字在抖」，而不是「它浮上来」。
const BLINK_START_DELAY := 0.26

## 扫光（参考图那种一道光掠过标题的打光）的时长与两次之间的间隔（秒）。
## ★ 只跑一次：它是**入场**的一部分，不是常驻装饰（常驻会让人一直分神）。
const SHINE_SEC := 1.15
const SHINE_DELAY_SEC := 0.55
## 扫光带的倾斜：0 = 竖直的带，> 0 时带子向右下斜（参考图的掠光是斜的）。
const SHINE_SKEW := 0.34

var cfg: ConfigRes = null

var _page: int = PAGE_INTRO
var _font: Font = null

var _root: Control = null
var _bg: Control = null
var _intro: Control = null
var _menu: Control = null
## ★ 新版式外壳（左上资料 / 左侧导航 / 右下入口）—— `view/menu_chrome.gd`。
## 它只跟着主界面一起显隐；**不含**任何进入游戏的逻辑（那是 `_menu` 那一列的事）。
var _chrome: Control = null
## ★★ 主菜单右上角「选项」按钮 + 选项页控制器（overlay + 居中面板）。
var _options_btn: Button = null
var _options_panel = null
## ★ 带字距的标题（`view/text_marks.gd` 的 SpacedLabel，**不是** Label）——
##   节点名仍是 "Title"，测试与排查照旧走 `StartRoot/Intro/Title`。
var _title: Control = null
## ★ 入场页的**徽记**与**标题下面那条金线** —— 与 `_title` 一起参与
##   「入场页 → 主界面」的落位动画（`_play_intro_morph()`）。
##   ⚠️ 这是**入场页那一份**；主界面标题条里另有三块对应的东西（见 `menu_ornaments()`）。
var _emblem: Control = null
var _title_rule: Control = null
## 入场落位动画的 Tween 与「正在跑」标记：
## ★ 标记是必须的 —— 动画期间页面**还是入场页**（`_page` 拦不住第二次点击）。
var _morph_tween: Tween = null
var _intro_morphing: bool = false
var _click_hint: Label = null
## 扫光那一条（盖在标题上的同级兄弟；见 `_build_intro` 末尾）
var _shine: Control = null
var _blink_tween: Tween = null
var _shine_tween: Tween = null
## ★★ 开局「从全黑淡入」那一层（盖在整页最上面、鼠标穿透；见 `_build_boot_fade()`）。
var _boot_fade: ColorRect = null
var _boot_tween: Tween = null
## ★★ 主界面正中那一列的按钮**还不能点**：
##   · 落位动画的 0.5s 里，`_menu` 是「显示但 alpha 0」（为了量目标矩形）；
##   · 切页之后外壳的 `play_intro()` 又把这些按钮从 alpha 0 淡入。
##   这两段里 Button 仍然吃鼠标 —— 不挡的话，快速点击会点到看不见的 `test_1` 直接开局，
##   而 `close()` 会把落位动画掐断、`_menu.modulate.a` 停在 0 ⇒ 回菜单时 logo 与三颗 test 全没了。
var _menu_blocked: bool = true
## ★ 正在等外壳把「首次进主界面」的滑入 + 淡入跑完（只有这条路径该保持封锁）。
##   直接 `show_page(PAGE_MENU)`（回菜单 / 测试 / 别的入口）不该被封 —— 那些路径没有淡入。
var _awaiting_chrome_intro: bool = false




func setup(p_cfg: ConfigRes, p_font: Font) -> void:
	cfg = p_cfg
	_font = p_font

	layer = 100
	# ⚠️ StartRoot 自己不收鼠标（IGNORE）：负责收点击的是盖在它上面的 Background，
	#    见文件头那条踩坑记录。这里写 STOP 只会让人误以为「接在根上就行」。
	_root = Control.new()
	_root.name = "StartRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_build_background()
	_build_intro()
	_build_chrome()
	# ★ 选项按钮要在外壳 attach() 抄初始状态之前挂上并登记为「撑开时滑出」的目标；
	#   它必须在 chrome 之后 add，才能在同一个 _root 里画在外壳之上。
	_build_options_button()
	_build_menu()
	_build_options_panel()
	# ★ 主界面那一列（现在只有标题条）登记为「撑开时要让路」的目标
	#   （dir = 0 = 只淡出不移位）：外壳上的按钮撑开面板时它必须让开。
	if _chrome != null and _menu != null:
		_chrome.add_avoid_target(_menu, 0)
	# ★★ 真正的「进哪一关」入口现在有两处：正中那五颗测试按钮，以及「战役」面板里
	#   长按选中的关卡。外壳把面板那一路往上传一层，这里再转成自己的 level_entry_pressed ——
	#   ⇒ **view/main.gd 那侧只认一个信号**（它只管「载入哪一关」，不关心从哪按的）。
	if _chrome != null:
		_chrome.level_activated.connect(
			func(campaign_id: String, level_id: String):
				level_entry_pressed.emit(campaign_id, level_id))
		_chrome.coop_host_started.connect(
			func(campaign_id: String, level_id: String, transport):
				coop_host_started.emit(campaign_id, level_id, transport))
		_chrome.coop_guest_started.connect(
			func(payload: Dictionary, transport):
				coop_guest_started.emit(payload, transport))
		_chrome.coop_solo_started.connect(
			func(campaign_id: String, level_id: String, ai_setup: Dictionary):
				coop_solo_started.emit(campaign_id, level_id, ai_setup))
		# ★ 首次进主界面：三块面板 + 子控件淡入全部走完，正中的按钮才允许点。
		_chrome.intro_finished.connect(_on_chrome_intro_finished)

	# ★★ 最后才挂「开局从全黑淡入」那层：它要盖在入场页所有元素之上。
	_build_boot_fade()
	show_page(PAGE_INTRO)
	_play_boot_fade_in()


# ------------------------------------------------------------------
# 对外状态
# ------------------------------------------------------------------

func show_page(page: int) -> void:
	# ⚠️ 这两句不是摆设：CanvasLayer 被 hide() 过（`close()` 走过一次）之后，
	#    **光调本函数不会让它重新显示** —— 页内两层的 visible 都对了、整层却还是隐的，
	#    表现就是「回到菜单了，主界面看得见，但按钮点不动」。详见 `open_menu()`。
	show()
	_page = page
	_intro.visible = (page == PAGE_INTRO)
	_menu.visible = (page == PAGE_MENU)
	# ★★ 主界面整列在「入场落位」期间是 alpha 0（为了量目标矩形）；如果动画中途被
	#   `close()` 掐断（快速点击误开局那条），它就会停在 0。这里按页兜底：
	#   只要是主界面，它就必须是不透明的 —— 否则回菜单时 logo 与三颗 test 全看不见。
	if page == PAGE_MENU and _menu != null:
		_menu.modulate.a = 1.0
		# ★ 只有「入场落位刚结束、等外壳淡入」这一条路径要继续封锁；
		#   其它直接切到主界面的路径（回菜单 / 测试）没有淡入，按钮应当立刻可用。
		if not _awaiting_chrome_intro:
			_menu_blocked = false
	# ★ 外壳只在**主界面**上有意义（入场页上不该出现资料 / 侧边栏 / 入口），所以跟着 _menu 一起切。
	if _chrome != null:
		_chrome.visible = (page == PAGE_MENU)
	if _options_btn != null:
		_options_btn.visible = (page == PAGE_MENU)
	if page != PAGE_MENU and _options_panel != null and _options_panel.is_open():
		_options_panel.close()
	if page == PAGE_INTRO:
		start_click_blink()
		start_title_shine()
	else:
		_stop_click_blink()
		_stop_title_shine()
		# ★ 把透明度放回「不透明」：Tween 被 kill 时会停在那一瞬间的中间值上，
		#   不还原的话这行字会以半透明状态留在那儿 —— 以后拿它当别的文案用就会莫名其妙发灰。
		if _click_hint != null:
			_click_hint.modulate.a = 1.0
		# ★ 扫光只在入场页跑；切到主界面时把标题整块收掉 ——
		#   否则它会以「停在半路」的状态继续挂着（它是盖在标题上的一个可见矩形）。
		if _title != null:
			_title.modulate.a = 1.0
		if _shine != null:
			_shine.visible = false
			_shine.modulate.a = 0.0


func page() -> int:
	return _page


## 进了游戏之后整页收起来。★ 必须是 hide() 而不是只把两个子节点设成不可见：
##   hide() 会让 CanvasLayer 的子节点**连输入带 _process 一起停掉**，
##   背景与「点击任意处」的处理器就此彻底下线，游戏里的鼠标事件不会再被这层吃掉。
func close() -> void:
	_stop_click_blink()
	_stop_title_shine()
	# ★ 把没跑完的入场落位动画一起取消：否则它的收尾回调会在游戏画面上
	#   把这一层 `show()` 回来（见 `_cancel_intro_morph()`）。
	_cancel_intro_morph()
	_finish_boot_fade()
	hide()
	# ★★ 进游戏时把本层所有按钮的「悬停（金色填充）」作废。
	#   为什么必须显式清：`hide()` 只是把 CanvasLayer 收起来，**不会**补发 `mouse_exited`，
	#   于是被点过的 `test` 那颗按钮的 `_hovered` 会一直停在 true —— 返回主菜单时
	#   那片金还留在按钮上（手机端尤其明显：手指抬起后模拟鼠标停在原地）。
	#   见 view/fill_button.gd 的 `_on_visibility_changed` / `clear_hover_in`。
	if _options_panel != null and _options_panel.is_open():
		_options_panel.close()
	FillButtonRes.clear_hover_in(self)


## ★★ 回到**主界面**（游戏内「设置 → 返回主菜单」走这里）。
##
## 与 `show_page(PAGE_MENU)` 的区别只有一处，但那一处很关键：**它带 `show()`**。
##
## ⚠️ 为什么需要单独一个方法（实测踩到的）：`close()` 里那次 `hide()` 之后，
##    CanvasLayer 整层是隐藏的；而 `show_page()` 只管**页内那两层**（Intro / MainMenu），
##    不会碰整层的可见性。于是「回到菜单」之后：主界面看上去是对的（因为它在隐藏层里），
##    但**鼠标点不到任何东西** —— 背景与主界面都不参与命中测试，test 按钮形同虚设。
##    表现就是「退不回菜单，游戏卡在那一页」。
##    把 `show()` 收进这个语义明确的方法里，而不是散在调用点：
##    凡是「从游戏里回到菜单」都必须走它，@see view/main.gd 的 return_to_menu()。
func open_menu() -> void:
	show()
	_awaiting_chrome_intro = false
	show_page(PAGE_MENU)
	# ★★ 回来时把「开局淡入」与「入场按钮锁」都收干净：
	#   这两样都只属于**第一次**进主界面；从游戏里回来时不该再看到一层黑幕，
	#   也不该出现「按钮看得见却点不动」。
	_finish_boot_fade()
	_menu_blocked = false
	# ★ 回来时选项页必须是关的（可能在上一次菜单里开着就进了游戏 / 切了页）
	if _options_panel != null and _options_panel.is_open():
		_options_panel.close()
	# ★★ 返回主菜单时再清一次悬停（兜底）：清掉之后不会自己填回来，
	#   只有真实 `mouse_entered` 才会 —— 所以「按过的东西」不会一回来就亮着。
	FillButtonRes.clear_hover_in(self)
	# ★★ 同时**解除常驻满格**：进游戏前点开的那块面板（以及它那颗入口按钮）在
	#   游戏期间是隐藏的、金停在满格；回到菜单这一下解除 ⇒ 玩家看到的是「反向渐出」，
	#   而不是「一回来就亮着 / 一回来就没了」。
	FillButtonRes.clear_latched_in(self)


# ------------------------------------------------------------------
# 触摸：手指抬起就作废悬停
# ------------------------------------------------------------------

## ★★ 手机端：**每一次触摸抬起**都立刻作废悬停（本轮修用户报的 bug）。
##
## 症状：长按主菜单某颗按钮再抬起手指，那颗按钮的金色填充**一直留着**。
## 成因：`fill_button` 在 `button_down` / `button_up` 里把 `_hovered` **钉住**（某些平台
##   按下时模拟鼠标会先「离开」，不钉的话按下去金反而退回去）；而触摸抬起后
##   `emulate_mouse_from_touch` 的模拟鼠标**停在原地**、不会补发 `mouse_exited`
##   ⇒ 没有任何一条路会把 `_hovered` 复位。
## 为什么 `call_deferred`：`_input` 早于 Button 的 `button_up`；同步清会被那句「钉住」
##   在同一帧里又置回 true。延到本帧末尾（Button 处理完之后）才清，才真的生效。
## ★ 只认**触摸**抬起：桌面鼠标仍然靠真实的 `mouse_entered` / `mouse_exited`，不受影响。
## ★ 与「常驻满格（latched）」互不干扰：面板开着的那颗按钮是 latched，清 hover 不会让它暗下去。
func _input(event: InputEvent) -> void:
	# 进游戏后这一层是 hide() 的：那时没有任何按钮需要复位，别为每次触摸付一次递归
	if not visible:
		return
	if not (event is InputEventScreenTouch):
		return
	if (event as InputEventScreenTouch).pressed:
		return
	call_deferred("_clear_menu_hover")


func _clear_menu_hover() -> void:
	FillButtonRes.clear_hover_in(self)


# ------------------------------------------------------------------
# 搭界面
# ------------------------------------------------------------------

## 整页渐变底。★ 它同时是收点击的那一层（mouse_filter = STOP 在 menu_background.gd 里设死）。
## ⚠️ 节点名必须叫 "Background"：`view/main.gd` 的调试与两条测试都按这个名字找它，
##    而「鼠标下最上层是它」这件事靠的是**它铺满整页**，不是靠名字。
func _build_background() -> void:
	_bg = MenuBackgroundRes.new()
	_bg.name = "Background"
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.gui_input.connect(_on_page_gui_input)
	_root.add_child(_bg)


func _build_intro() -> void:
	_intro = Control.new()
	_intro.name = "Intro"
	_intro.set_anchors_preset(Control.PRESET_FULL_RECT)
	_intro.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_intro)

	# ---- 徽记：贴着标题上方，水平居中（纯几何自绘，见 menu_emblem.gd）----
	_emblem = MenuEmblemRes.new()
	_emblem.name = "Emblem"
	var e_size := cfg.num("menu.emblem_size", 150.0)
	_emblem.anchor_left = 0.0
	_emblem.anchor_right = 1.0
	_emblem.offset_left = 0.0
	_emblem.offset_right = 0.0
	_emblem.offset_top = cfg.num("menu.emblem_top", 66.0)
	_emblem.offset_bottom = _emblem.offset_top + e_size
	_intro.add_child(_emblem)

	# ---- 标题：带字距 + 横向渐变（参考图那种「左白右金」的一排字）----
	# ★ 它是**自绘控件**（SpacedLabel）而不是 Label：Label 没有 letter-spacing。
	#   于是宽度要自己给（`menu.title_width`）—— 逐字推进算出来的总宽在这个宽度里居中，
	#   见 text_marks.gd `_draw()`。
	_title = TextMarksRes.SpacedLabel.new()
	_title.name = "Title"
	_title.text = cfg.str_val("menu.title", "DAEEM")
	_title.font = _font
	_title.font_size = int(cfg.num("menu.title_size", 128.0))
	_title.tracking = cfg.num("menu.title_tracking", 26.0)
	_title.color_from = _menu_color("menu.title_color", ThemeRes.text())
	_title.color_to = _menu_color("menu.title_gold_color", ThemeRes.accent())
	# 标题的宽度留得比字宽（`title_width`，默认 1160）：太窄会把两端的字挤掉。
	_title.anchor_left = 0.0
	_title.anchor_right = 1.0
	_title.offset_left = 0.0
	_title.offset_right = 0.0
	_title.offset_top = cfg.num("menu.title_top", 200.0)
	_title.offset_bottom = _title.offset_top + cfg.num("menu.title_height", 170.0)
	_intro.add_child(_title)

	# ---- 标题下面那条金色分隔线（参考图里标题上下的细线）----
	_title_rule = _build_rule(_intro, "TitleRule",
		cfg.num("menu.title_top", 200.0) + cfg.num("menu.title_height", 170.0)
			+ cfg.num("menu.title_rule_gap", 44.0))

	# ---- 提示：锚在**下边**（需求要它在屏幕下方）。----
	# ⚠️ 这里踩过一次坑（第一版把提示画到了画面**之外**、完全看不见）：
	#    只写 anchor_bottom = 1.0、把 anchor_top 留在 0 时，控件的上下两条边**各自**算：
	#    y_top 仍是 0 + offset_top，y_bottom 才是屏高 + offset_bottom，
	#    于是 offset_bottom = -110 让底边跑到 1810 之外、文字整个掉出画面。
	#    正确做法是**上下锚都贴底**（anchor_top = anchor_bottom = 1.0），
	#    这时 offset_top 才是「底边距屏幕底多远」，文字在这个位置往**上**长。
	_click_hint = _make_label(
		cfg.str_val("menu.click_text", "————点击任意处进入游戏————"),
		int(cfg.num("menu.click_size", 32.0)),
		_menu_color("menu.click_color", ThemeRes.text_dim())
	)
	_click_hint.name = "ClickHint"
	# ★ 横向也必须「左右都贴边」（anchor_left = 0 / anchor_right = 1 + offset 0）：
	#   两个横向锚都留在 0 的话，Label 只会占它最小宽度、贴在屏幕左边缘，
	#   里面的 horizontal_alignment = CENTER 就完全看不出效果（第一版就是这样偏在左边）。
	_click_hint.anchor_top = 1.0
	_click_hint.anchor_bottom = 1.0
	_click_hint.anchor_left = 0.0
	_click_hint.anchor_right = 1.0
	_click_hint.offset_left = 0.0
	_click_hint.offset_right = 0.0
	_click_hint.offset_top = -cfg.num("menu.click_bottom", 110.0)
	_click_hint.offset_bottom = _click_hint.offset_top
	_intro.add_child(_click_hint)

	# ---- 扫光：盖在标题上的一条斜向亮带，入场时从左掠过右一次 ----
	# ★ 它是 `_title` 的**同级兄弟**（不是子节点）：SpacedLabel 会把自己画在
	#   （0,0)-(w,h) 里，子节点会被它的绘制顺序影响；做成兄弟、且在**其后** add_child，
	#   绘制顺序就是「标题 → 扫光」，这才是「光在上面掠过」。
	# ★ 它盖住的矩形比标题略宽，但 `mouse_filter = IGNORE` ⇒ 不影响「点击任意处」。
	_shine = Control.new()
	_shine.name = "TitleShine"
	_shine.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shine.anchor_left = 0.0
	_shine.anchor_right = 1.0
	_shine.offset_left = 0.0
	_shine.offset_right = 0.0
	_shine.offset_top = _title.offset_top - 24.0
	_shine.offset_bottom = _title.offset_bottom + 24.0
	_shine.draw.connect(_on_shine_draw)
	_intro.add_child(_shine)


## 主界面的**新版式外壳**（仿 nsoc）：左上资料 / 左侧导航 / 右下三个入口。
##
## ★★ 它与 `_menu`（正中那一列）的分工：
##   · 本函数建的这个外壳 = **版式**：资料、五个侧边栏入口、右下战役 / 演义 / 合作模式；
##     点它们会撑开一块面板（机制在 view/panel_expand.gd）；「战役」那块里是战役菜单。
##   · `_build_menu()` 建的那一列 = **五颗测试入口**（直连关卡）。
##
## ⚠️ 顺序：先在 `_root` 上 `add_child` 外壳、再建那一列 —— `add_child` 的先后就是叠放顺序。
## ⚠️ `setup()` 必须在 `add_child` **之后**调：外壳内部的转场引擎要 `await get_tree().process_frame`
##    才能抄到稳定的布局（见 view/panel_expand.gd 的 `attach()`）——不在树上时 `get_tree()` 是 null。
func _build_chrome() -> void:
	_chrome = MenuChromeRes.new()
	_root.add_child(_chrome)
	_chrome.setup(cfg, _font)


## ★★ 主菜单右上角「选项」：位置 / 尺寸照 nsoc（160×80，右上角留 20px）。
## ★ 它同时登记到 panel_expand 的「撑开时滑出」名单里（dir=1 = 向右），
##   否则外壳面板撑满全屏后它还会浮在最上面。
func _build_options_button() -> void:
	_options_btn = Button.new()
	_options_btn.name = "OptionsButton"
	_options_btn.text = cfg.str_val("settings.title", "选项")
	_options_btn.focus_mode = Control.FOCUS_NONE
	_options_btn.add_theme_font_size_override("font_size",
		cfg.int_val("menu.chrome.options_font_size", 28))
	if _font != null:
		_options_btn.add_theme_font_override("font", _font)
	var w: float = cfg.num("menu.chrome.options_w", 160.0)
	var h: float = cfg.num("menu.chrome.options_h", 80.0)
	var m: float = cfg.num("menu.chrome.options_margin", 20.0)
	_options_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT, false)
	_options_btn.offset_left = -m - w
	_options_btn.offset_top = m
	_options_btn.offset_right = -m
	_options_btn.offset_bottom = m + h
	FillButtonRes.attach_text(_options_btn)
	FillButtonRes.set_base_font_color(_options_btn, MenuThemeRes.text_normal())
	FillButtonRes.set_panel_color(_options_btn, ThemeRes.bg_top())
	_options_btn.add_theme_stylebox_override("normal", MenuThemeRes.button_normal())
	_options_btn.add_theme_stylebox_override("hover", MenuThemeRes.button_hover_clear())
	_options_btn.add_theme_stylebox_override("pressed", MenuThemeRes.button_fill_latched())
	_options_btn.add_theme_stylebox_override("focus", MenuThemeRes.button_normal())
	_options_btn.add_theme_stylebox_override("disabled", MenuThemeRes.button_disabled())
	_options_btn.add_theme_color_override("font_disabled_color", MenuThemeRes.text_disabled())
	_root.add_child(_options_btn)
	if _chrome != null:
		var eng = _chrome.expand_engine()
		if eng != null:
			eng.add_target(_options_btn, 1)
			# ★ panel_expand 会把这些目标拍平成 TOP_LEFT（为了 Tween position/size）；
			#   收回之后把「选项」按钮的右上锚点补回来，否则窗口一变宽它就不贴右上了。
			eng.reversed.connect(_restore_options_button_anchor)


func _restore_options_button_anchor() -> void:
	if _options_btn == null:
		return
	var w: float = cfg.num("menu.chrome.options_w", 160.0)
	var h: float = cfg.num("menu.chrome.options_h", 80.0)
	var m: float = cfg.num("menu.chrome.options_margin", 20.0)
	_options_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT, false)
	_options_btn.offset_left = -m - w
	_options_btn.offset_top = m
	_options_btn.offset_right = -m
	_options_btn.offset_bottom = m + h


## ★★ 选项页（overlay + 居中面板）—— 与 HUD 共用 view/options_panel.gd。
func _build_options_panel() -> void:
	if _options_btn == null:
		return
	_options_panel = OptionsPanelRes.new()
	_options_panel.name = "OptionsPanel"
	_root.add_child(_options_panel)
	_options_panel.setup(_root, _font, cfg, {
		"style": "menu",
		"resume_label": cfg.str_val("settings.back_text", "返回"),
		"settings_label": cfg.str_val("settings.panel_title", "设置"),
		"back_label": cfg.str_val("settings.back_text", "返回"),
		"panel_title": cfg.str_val("settings.panel_title", "设置"),
		"exit_label": cfg.str_val("settings.exit_game_text", "退出游戏"),
		"fullscreen_on_text": cfg.str_val("settings.fullscreen_on_text", "窗口化"),
		"fullscreen_off_text": cfg.str_val("settings.fullscreen_off_text", "全屏"),
		"fullscreen_action": Callable(self, "_on_options_fullscreen"),
		"exit_action": Callable(self, "_on_options_quit"),
		"can_open": Callable(self, "_can_open_options"),
	})
	_options_btn.pressed.connect(_on_options_pressed)


func _on_options_pressed() -> void:
	if _options_panel != null:
		_options_panel.open()


func _on_options_fullscreen() -> void:
	fullscreen_toggled.emit()


func _on_options_quit() -> void:
	quit_requested.emit()


## 外壳在撑开面板 / 转场时，选项按钮不该再弹出另一块浮层。
func _can_open_options() -> bool:
	if _page != PAGE_MENU or _intro_morphing:
		return false
	if _chrome == null:
		return true
	var eng = _chrome.expand_engine()
	if eng == null:
		return true
	return not eng.is_busy() and not eng.is_expanded()


## ★ 主菜单右上角「选项」按钮 / 选项页 —— 只给测试与排查用。
func options_button() -> Button:
	return _options_btn


func options_panel():
	return _options_panel


func _build_menu() -> void:
	# ★★ 结构（从外到内，测试按节点路径找控件，别随手改名字）：
	#   `MainMenu`（CenterContainer，整页铺满、负责居中）
	#     └ `MenuOuter`（VBox，**把标题条与按钮列竖着连起来**）
	#         ├ `MenuOrnaments`（标题条：徽记 + DAEEM + 金线，自己也是一个 VBox）
	#         ├ 一个下边距（`menu_rule_gap`，标题条与那一列之间的呼吸）
	#         └ `MenuColumn`（VBox：config 的 menu.test_entries）
	#
	# ★★ 为什么标题条与按钮列要放进**同一个 VBox**（而不是各摆各的）：
	#   第一版把标题条锚在屏幕下边、按钮列整页居中，两者互不知情 ——
	#   结果在 1920×1080 上（实测截图）标题条正好落在按钮列底下、贴着字标，
	#   而且窗口比例一变就可能直接压到按钮上（无头 1920×1920 的视口里就是撞上的）。
	#   连成一列之后，「标题在按钮上方」是**排版保证**的，不是靠两个坐标碰巧错开。
	#
	# ★★ 但标题条**不能**直接当 MenuColumn 的孩子：VBox 的 `separation` 作用于
	#   **每一对**相邻子节点，塞进去会让「标题 → 选择条」也吃一份按钮间距
	#   （实测过：想要 48，量出来 268）。所以中间隔一层 MenuOuter，
	#   它自己的 separation 用标题专用的 `menu_rule_gap`。
	_menu = CenterContainer.new()
	_menu.name = "MainMenu"
	_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	_menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_menu)

	# ★ 整块往下推一点（`menu_column_offset`）：CenterContainer 是严格居中的，
	#   而这套版式里「标题 + 选择条 + 两颗按钮」整块居中时，上方会留下一大条空白
	#   （实测截图：内容整体偏上、下半个屏幕全空）。用一个负的上边距把它压下来。
	var pad := MarginContainer.new()
	pad.name = "MenuPad"
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_theme_constant_override("margin_top",
		cfg.int_val("menu.menu_column_offset", 120))
	_menu.add_child(pad)

	var outer := VBoxContainer.new()
	outer.name = "MenuOuter"
	outer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outer.add_theme_constant_override("separation",
		cfg.int_val("menu.menu_rule_gap", 40))
	pad.add_child(outer)

	# ---- 标题条：徽记 / 字标 / 金线，竖着摞（VBox 自己管间距）----
	var ornaments := VBoxContainer.new()
	ornaments.name = "MenuOrnaments"
	ornaments.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ornaments.add_theme_constant_override("separation",
		cfg.int_val("menu.menu_title_gap", 22))
	outer.add_child(ornaments)

	# 1) 徽记：★ 用 CenterContainer 包住 —— 自绘控件的宽度是按内容算的，
	#    直接放进 VBox 会被拉满整行（那枚圆环就跑到屏幕左边去了）。
	var emblem_wrap := CenterContainer.new()
	emblem_wrap.name = "MenuEmblemWrap"
	emblem_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ornaments.add_child(emblem_wrap)
	var e_size := cfg.num("menu.menu_emblem_size", 112.0)
	var emblem := MenuEmblemRes.new()
	emblem.name = "MenuEmblem"
	emblem.custom_minimum_size = Vector2(e_size, e_size)
	emblem_wrap.add_child(emblem)

	# 2) 字标（带字距的那排字）
	var word := TextMarksRes.SpacedLabel.new()
	word.name = "MenuWordmark"
	word.text = cfg.str_val("menu.title", "DAEEM")
	word.font = _font
	word.font_size = int(cfg.num("menu.menu_title_size", 44.0))
	word.tracking = cfg.num("menu.menu_title_tracking", 14.0)
	word.color_from = _menu_color("menu.menu_title_color", ThemeRes.text())
	word.color_to = _menu_color("menu.menu_title_gold_color", ThemeRes.accent())
	word.custom_minimum_size = Vector2(0.0, cfg.num("menu.menu_title_height", 58.0))
	# ★ 自绘的 SpacedLabel 是按**控件宽度**居中的，所以必须让它在 VBox 里横向撑满；
	#   而 VBox 对 Control 的默认就是「撑满 + 取最小高度」，这里只需给高度。
	word.size_flags_horizontal = Control.SIZE_FILL
	ornaments.add_child(word)

	# 3) 金线（两端渐隐，宽度固定 ⇒ 用 CenterContainer 居中）
	var rule_wrap := CenterContainer.new()
	rule_wrap.name = "MenuRuleWrap"
	rule_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ornaments.add_child(rule_wrap)
	var rule := TextMarksRes.Rule.new()
	rule.name = "MenuRule"
	rule.line_color = ThemeRes.with_alpha(ThemeRes.line(), 0.85)
	rule.line_width = 1.0
	rule.fade = 60.0
	rule.custom_minimum_size = Vector2(cfg.num("menu.menu_rule_width", 220.0), 1.0)
	rule_wrap.add_child(rule)

	# ★★ 正中那一列按钮（`MenuColumn`）：**五颗测试入口**，各自直连一关。
	#
	#   为什么又回到 MenuOuter 里：这三颗是「进游戏」的快捷入口，与标题条同属主界面正中那一块；
	#   放进同一个 VBox 才有「标题在上、按钮在下」的排版保证（旧版把两者各摆各的，窗口比例一变
	#   就会撞上 —— 见本函数开头那段注释）。
	#
	#   数据来自 `menu.test_entries[]`（label / campaign / level）：加一颗按钮只改 JSON，
	#   不必碰代码；「点进去进哪一关」也由数据说了算（载入与建世界在 view/main.gd）。
	var column := VBoxContainer.new()
	column.name = "MenuColumn"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation",
		cfg.int_val("menu.test_button_gap", 48))
	outer.add_child(column)
	for entry in _test_entries():
		column.add_child(_make_test_button(entry))


## `menu.test_entries` 那一张表（每项 `{label, campaign, level}`）。
## ★ 读不到 / 写坏 → 返回空表（界面是「只有标题条」，不崩）；不在这里编默认关卡：
##   默认值写死在代码里会让「数据没了」表现成「按钮还在、进的是别的一关」。
func _test_entries() -> Array:
	var v: Variant = cfg.get_path_value("menu.test_entries") if cfg != null else null
	var out: Array = []
	if typeof(v) != TYPE_ARRAY:
		return out
	for item in (v as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		var label := String(d.get("label", "")).strip_edges()
		var campaign := String(d.get("campaign", "")).strip_edges()
		var level := String(d.get("level", "")).strip_edges()
		var coop := bool(d.get("coop", false))
		var ai_observer := bool(d.get("ai_observer", false))
		var ai_observer_orders := bool(d.get("ai_observer_orders", false))
		var ai_observer_reveal := bool(d.get("ai_observer_reveal", false))
		var direct := bool(d.get("direct", false))
		var coop_ai := bool(d.get("coop_ai", false))
		if label == "" or campaign == "" or level == "":
			continue
		out.append({"label": label, "campaign": campaign, "level": level,
			"coop": coop, "ai_observer": ai_observer,
			"ai_observer_orders": ai_observer_orders,
			"ai_observer_reveal": ai_observer_reveal,
			"direct": direct, "coop_ai": coop_ai})
	return out


## 一颗 test_N 按钮：与主界面其它按钮同一套线框 + 悬停金（见 view/fill_button.gd）。
func _make_test_button(entry: Dictionary) -> Button:
	var b := Button.new()
	b.name = "TestLevelButton"
	b.text = String(entry["label"])
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(
		cfg.num("menu.test_button_width", 240.0),
		cfg.num("menu.test_button_height", 80.0)
	)
	if _font != null:
		b.add_theme_font_override("font", _font)
	b.add_theme_font_size_override("font_size", cfg.int_val("menu.test_button_size", 28))
	# ★ 顺序不能换：attach_text() 必须在挂样式之前（挂样式那一步会写「原字色」）。
	FillButtonRes.attach_text(b)
	FillButtonRes.set_base_font_color(b, MenuThemeRes.text_normal())
	# 底是**面板的深色底**：显式告诉填充层，别去扫 pressed 那格的实心金（见 menu_chrome 同一段注释）
	FillButtonRes.set_panel_color(b, ThemeRes.bg_top())
	FillButtonRes.set_prefer_light(b, true)
	b.add_theme_stylebox_override("normal", MenuThemeRes.button_normal())
	b.add_theme_stylebox_override("hover", MenuThemeRes.button_hover_clear())
	b.add_theme_stylebox_override("pressed", MenuThemeRes.button_fill_latched())
	b.add_theme_stylebox_override("focus", MenuThemeRes.button_normal())
	b.add_theme_stylebox_override("disabled", MenuThemeRes.button_disabled())
	b.add_theme_color_override("font_disabled_color", MenuThemeRes.text_disabled())
	FillButtonRes.set_latched(b, false)
	var campaign_id := String(entry["campaign"])
	var level_id := String(entry["level"])
	var is_coop := bool(entry.get("coop", false))
	var is_ai_test := bool(entry.get("ai_observer", false))
	var allow_orders := bool(entry.get("ai_observer_orders", false))
	var reveal_all := bool(entry.get("ai_observer_reveal", false))
	var is_direct := bool(entry.get("direct", false))
	var is_coop_ai := bool(entry.get("coop_ai", false))
	b.pressed.connect(func():
		# ⚠️ 本文件是 CanvasLayer（不是 Control）：可见性用 `visible`，没有 is_visible_in_tree()。
		if not visible:
			return
		# ★★ 入场落位 + 外壳首次淡入期间，这一列是 alpha 0 / 半透明 —— 看得见之前不许点。
		if _menu_blocked:
			return
		if is_ai_test:
			ai_test_requested.emit(campaign_id, level_id, allow_orders, reveal_all)
			return
		# ★★ ai_test_hz：直接开「合作 + AI 队友」本地局（玩家第 1 席位，commander 接管第 2 席位）。
		#    不弹合作大厅，也不要求先选地图。
		if is_coop_ai:
			coop_solo_started.emit(campaign_id, level_id, {"difficulty": "normal"})
			return
		# ★★ ai_test_battle：跳过战役过渡画面，直接按关卡的可玩阵营开局（玩家就是 p2）。
		if is_direct:
			direct_level_requested.emit(campaign_id, level_id)
			return
		if is_coop and _chrome != null:
			_chrome.open_coop_panel()
			return
		level_entry_pressed.emit(campaign_id, level_id))
	return b


## 标题下面那条金色分隔线（参考图里标题上下的细线）。
##
## ★ 位置是**算出来的**（标题底 + title_rule_gap），不是又一个绝对坐标 ——
##   改标题字号 / 高度时这条线自己跟着走，不会漂到字上去。
func _build_rule(parent: Control, node_name: String, y: float) -> Control:
	var rule := TextMarksRes.Rule.new()
	rule.name = node_name
	rule.line_color = ThemeRes.with_alpha(ThemeRes.line(), 0.9)
	rule.line_width = cfg.num("menu.title_rule_height", 1.0)
	# 两端渐隐（参考图的线是「中间实、两头化开」的）
	rule.fade = cfg.num("menu.title_rule_fade", 40.0)
	var w := cfg.num("menu.title_rule_width", 460.0)
	rule.anchor_left = 0.5
	rule.anchor_right = 0.5
	rule.offset_left = -w * 0.5
	rule.offset_right = w * 0.5
	rule.offset_top = y
	rule.offset_bottom = y + 1.0
	parent.add_child(rule)
	return rule


func _make_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	if _font != null:
		label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# ★ 文字不吃鼠标：否则点在标题 / 提示那几个字上会被 Label 吃掉，
	#   而「点击任意处」恰恰要求点在字上也算数。
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


## 取 menu.* 下的颜色。★ 用 Config.parse_color 那条路（解析 "#rrggbb" / "rgba(...)"），
##   而不是自己读字符串再 Color() —— 配色写法与全项目保持一致。
func _menu_color(path: String, fallback: Color) -> Color:
	var v: Variant = cfg.get_path_value(path)
	if typeof(v) == TYPE_STRING:
		return ConfigRes.parse_color(String(v), fallback)
	return fallback


# ------------------------------------------------------------------
# 开局从全黑淡入（盖在入场页最上面的一层，鼠标穿透）
# ------------------------------------------------------------------

## 只在「动效开着且时长 > 0」时建这一层；否则整个动画跳过（与全项目同一条口径）。
## ★ 一定要在 `_build_menu` / `_build_options_panel` 之后 add：它得盖住入场页所有元素，
##   也要盖住（此时还隐藏着的）主界面。
func _build_boot_fade() -> void:
	if not ThemeRes.animations_enabled():
		return
	if cfg.num("menu.intro_fade_in_sec", 0.8) <= 0.0:
		return
	_boot_fade = ColorRect.new()
	_boot_fade.name = "BootFade"
	var c: Color = _menu_color("menu.intro_fade_in_color", Color(0.0, 0.0, 0.0))
	c.a = 1.0
	_boot_fade.color = c
	_boot_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# ★ 只负责「看」，不负责「挡」：淡入期间玩家照样可以点一下跳过入场页。
	_boot_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_boot_fade)


func _play_boot_fade_in() -> void:
	if _boot_fade == null:
		return
	var sec: float = cfg.num("menu.intro_fade_in_sec", 0.8)
	if not ThemeRes.animations_enabled() or sec <= 0.0:
		_finish_boot_fade()
		return
	_boot_fade.modulate.a = 1.0
	_boot_tween = create_tween()
	_boot_tween.tween_property(_boot_fade, "modulate:a", 0.0, sec) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_boot_tween.tween_callback(_finish_boot_fade)


func _finish_boot_fade() -> void:
	if _boot_tween != null and _boot_tween.is_valid():
		_boot_tween.kill()
	_boot_tween = null
	if _boot_fade != null and is_instance_valid(_boot_fade):
		_boot_fade.queue_free()
	_boot_fade = null


## 开局淡入那一层（只给测试用；淡入结束后是 null）。
func boot_fade() -> ColorRect:
	return _boot_fade if _boot_fade != null and is_instance_valid(_boot_fade) else null


func boot_fade_sec() -> float:
	return cfg.num("menu.intro_fade_in_sec", 0.8) if cfg != null else 0.0


## ★ 正中那一列现在是否被「看得见之前不许点」挡着（只给测试用）。
func menu_blocked() -> bool:
	return _menu_blocked


# ------------------------------------------------------------------
# 提示文案的呼吸（渐显渐隐）
# ------------------------------------------------------------------

## 让下方提示「————点击任意处进入游戏————」一直呼吸。
##
## ★ 用 Tween 而不是 `_process`：一条循环 Tween 就够了，而且**暂停时它也会跟着停**
##   （Tween 绑在节点上，节点不处理时就冻结），不必自己算时间。
## ★ 动的是 `modulate:a` 而不是 `visible`：渐隐渐显要的是透明度连续变化，
##   切 visible 只会得到「一闪一闪」。暗端也不设 0（留 alpha_min），否则文字会整个消失。
##
## ★★ 本轮加了一段「淡入 + 停顿」当**前奏**（见 `intro_fade_sec` / BLINK_START_DELAY）：
##   入场页现在是一整块（徽记 + 标题 + 金线 + 提示）一起浮上来，
##   浮上来之后提示才开始呼吸 —— 于是「首帧就可见」这件事**没有变**
##   （tween 的起点 = 当前值 = 亮端），只是它先落到暗端再呼吸。
func start_click_blink() -> void:
	if _click_hint == null:
		return
	_stop_click_blink()

	var lo := clampf(cfg.num("menu.click_alpha_min", 0.15), 0.0, 1.0)
	var hi := clampf(cfg.num("menu.click_alpha_max", 1.0), 0.0, 1.0)
	if hi < lo:
		var tmp := lo
		lo = hi
		hi = tmp

	# ★ 必须从暗端起步：先设成暗，再让 loop 把「暗→亮→暗」跑起来，
	#   否则第一轮会从当前值（亮）开始，看起来像闪了一下才进入节奏。
	_click_hint.modulate.a = lo
	_blink_tween = create_tween()
	# 1) 淡入：从暗端升到亮端（这一段时间里整页也在淡入）
	_blink_tween.tween_property(_click_hint, "modulate:a", hi,
		cfg.num("menu.intro_fade_sec", 0.9)).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	# 2) 停一拍（呼吸还没开始，让「浮上来」这件事先被看清）
	_blink_tween.tween_interval(BLINK_START_DELAY)
	# 3) 之后是**无限**的呼吸
	_blink_tween.set_loops()
	_blink_tween.tween_property(_click_hint, "modulate:a", lo, BLINK_PHASE_SEC) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_blink_tween.tween_property(_click_hint, "modulate:a", hi, BLINK_PHASE_SEC) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _stop_click_blink() -> void:
	if _blink_tween != null and _blink_tween.is_valid():
		_blink_tween.kill()
	_blink_tween = null


# ------------------------------------------------------------------
# 标题的扫光（入场一次）
# ------------------------------------------------------------------

## 一道斜向的亮带从标题左边掠到右边，一次就结束（见 SHINE_SEC / SHINE_DELAY_SEC）。
##
## ★★ 为什么要有它：参考图那排字的「打光感」是这套风格里唯一的动效来源。
##   静态的渐变标题虽然对，但整个入场页就没有任何东西在动 —— 而入场页的职责
##   恰恰是「让玩家知道游戏活着」。
## ★ 它是**盖在标题上的一个空 Control**，自己在 `_draw` 里画那条带子（见 `_on_shine_draw`）：
##   比复制一份文字做遮罩省事得多，而且完全不影响文字本身的绘制。
func start_title_shine() -> void:
	if _shine == null or _title == null:
		return
	_stop_title_shine()
	_shine.visible = true
	# 起点在标题左侧之外，终点在右侧之外（0 → 1 是「带子中心扫过整块标题」的进度）
	_shine.modulate.a = 0.0
	_shine.set_meta("shine_t", 0.0)
	_shine.queue_redraw()
	_shine_tween = create_tween()
	_shine_tween.tween_interval(SHINE_DELAY_SEC)
	_shine_tween.tween_method(_set_shine_t, 0.0, 1.0, SHINE_SEC) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_shine_tween.tween_callback(_stop_title_shine)


func _stop_title_shine() -> void:
	if _shine_tween != null and _shine_tween.is_valid():
		_shine_tween.kill()
	_shine_tween = null
	if _shine != null:
		_shine.visible = false
		_shine.modulate.a = 0.0


func _set_shine_t(t: float) -> void:
	if _shine == null:
		return
	_shine.set_meta("shine_t", t)
	# 带子的亮度：两端淡（进入 / 离开），中段最亮 —— 用 sin 曲线，避免「啪地出现」
	_shine.modulate.a = sin(clampf(t, 0.0, 1.0) * PI)
	_shine.queue_redraw()


## 扫光那一条的画法：一个**斜的**矩形，用一次 `draw_set_transform` 把坐标系歪一下
## （比手算四边形的顶点少一半代码，而且线宽 / 采样都不会出错）。
func _on_shine_draw() -> void:
	if _shine == null:
		return
	var w: float = _shine.size.x
	var h: float = _shine.size.y
	if w <= 1.0 or h <= 1.0:
		return
	var t: float = float(_shine.get_meta("shine_t", 0.0))
	var band_w: float = maxf(40.0, w * 0.10)
	# 带子的中心：从 -band_w 扫到 w + band_w
	var cx: float = -band_w + (w + band_w * 2.0) * t
	_shine.draw_set_transform(Vector2(cx, h * 0.5), SHINE_SKEW, Vector2.ONE)
	var gold := ThemeRes.accent_bright()
	# 三段不同 alpha 的竖条拼出「两头淡」的带子（不引 shader：见 text_marks.gd Rule 的同一条理由）
	var seg := band_w / 3.0
	var alphas := [0.10, 0.22, 0.10]
	for i in 3:
		var a: float = alphas[i]
		_shine.draw_rect(Rect2(-band_w * 0.5 + seg * float(i), -h, seg, h * 2.0),
			ThemeRes.with_alpha(gold, a), true)
	_shine.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# ------------------------------------------------------------------
# 输入
# ------------------------------------------------------------------

## ★ 接的是 Background（鼠标下最上层的那一个），不是父节点 StartRoot —— 见文件头的踩坑记录。
func _on_page_gui_input(event: InputEvent) -> void:
	if _page != PAGE_INTRO:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		dismiss_intro()


## 入场页 → 主界面。★ 判定与动作分开写，是为了让测试能直接调这个函数
##   模拟「玩家点了一下」，而**不必知道**判定写在 gui_input 的哪个条件里
##   （把判定抄进测试等于测了另一份实现）。
## ⚠️ 但这**不能**代替「点击真的能到达处理器」那条验证：
##   第一版就是处理器接错了节点，而这个函数单独调照样通过，
##   于是测试全绿、游戏里点不动。接线本身必须另外测（见 tests/test_start_flow.gd）。
## @return bool 这一次点击是否真的生效（已经在主界面 / 动画正在跑时为 false）
##
## ★★ 现在这里是**两段动画**（见 `_play_intro_morph()` 与 `view/panel_expand.gd` 的 `play_intro()`）：
##   ① 徽记 / 标题 / 金线缓动到主界面标题条里各自的位置（此时主界面还藏着）；
##   ② 落位之后才切页，并让主菜单的三块面板从屏幕外滑入。
##
## ★★ 所以本函数**同步返回** true（= "这次点击被受理了"），而**切页发生在动画之后**：
##   调用方若需要「已经到主界面了」，得等 `intro_dismissed` 信号或轮询 `page()` ——
##   别指望这一行之后就已经切好了（tests/test_menu_chrome.gd 就是这么等的）。
##   这个形状是刻意的：把 `await` 写在**本函数里**会让它的返回值变成协程对象，
##   而调用点（含测试）用的都是 `if dismiss_intro():` 这种布尔用法。
func dismiss_intro() -> bool:
	if _page != PAGE_INTRO or _intro_morphing:
		return false
	_stop_click_blink()
	# ★ 扫光也要现在停掉：它是**入场页专属**的一次性装饰，而落位动画只搬标题、不带它 ——
	#   不先停的话，那条斜的亮带会**留在原地**（标题缩走了、它还在），像一块灰色斜方块
	#   （实测截图抓到的）。
	_stop_title_shine()
	if not ThemeRes.animations_enabled() or _intro_morph_sec() <= 0.0:
		# 动效总开关关掉 ⇒ 两段都跳过，当场到位（与 fill_button / 徽记同一条口径）
		_finish_intro()
		return true
	_intro_morphing = true
	_play_intro_morph()
	return true


## 真正切到主界面（并让外壳的面板滑入）。★ 只在落位动画跑完、或被跳过时走一次。
func _finish_intro() -> void:
	if _page != PAGE_INTRO:
		return
	_intro_morphing = false
	# ★ 落位动画期间主界面是「显示但 alpha 0」（理由见 `_play_intro_morph()`）——这里把它放出来。
	#   面板自己的滑入由 `play_intro()` 负责（那时外壳才第一次显示）。
	if _menu != null:
		_menu.modulate.a = 1.0
	# ★ 必须在 show_page 之前立起「等外壳淡入」：show_page 会按它决定要不要解除封锁。
	_awaiting_chrome_intro = (_chrome != null)
	show_page(PAGE_MENU)
	if _chrome != null:
		# ★ 外壳滑入 + 子控件淡入**全部**完成后才会发 intro_finished（`_menu_blocked` 到那时才解除）。
		_chrome.play_intro()
	else:
		_menu_blocked = false
	intro_dismissed.emit()


## ★ 外壳把「首次进主界面」的滑入 + 淡入全部跑完了：正中那一列现在真的看得见，可以点了。
func _on_chrome_intro_finished() -> void:
	_awaiting_chrome_intro = false
	_menu_blocked = false


## ★★ 入场页的**落位动画**：徽记 / 标题 / 金线缓动到主界面标题条里各自的位置。
##
## 做法：把入场页那三块**拍平锚点**（位置与尺寸从此由 Tween 说了算），终点取主界面标题条里
## 对应三块的**屏幕矩形**，然后并行 Tween `position` / `size`；标题还要把**字号与字距**
## 一起走过去（不然只有外框在缩、字是「跳」的），金线要把**两端的渐隐长度**过渡过去。
## 三块落位的那一瞬间才切页 —— 主界面那三块本来就在同一位置，于是看不出接缝。
##
## ⚠️⚠️ **必须先让主界面「显示但 alpha 0」并等排版落定**，再量终点：
##   容器只在自己**显示**的时候才把子节点排到位 —— 实测量到的是 (0,0)（那行字的宽度甚至是 0），
##   于是徽记会缩到屏幕**左上角**去、字和线干脆一动不动（用户报的正是这个）。
##   落定要等几帧（父容器 sort → 子控件尺寸变化 → 子容器再 sort，一跳一帧），所以走
##   `_wait_targets_ready()` 轮询；等不到就**不做这段动画**（宁可少一段动画，也不能把 logo 搬去角落）。
##
## ★ 收尾用 `tween_callback` 而不是 `await finished`：动画被 `_cancel_intro_morph()` 杀掉时
##   回调不会来（正是我们要的：不再切页），也不会留下一个永远等不到恢复的协程。
func _play_intro_morph() -> void:
	# ★★ 从这里开始到「外壳首次滑入淡入结束」，正中那列的按钮**一律不响应**。
	#   它们马上会以 alpha 0 显示（为了量目标矩形）——不挡就是「看不见却点得到」，
	#   快速点击会直接开一局，把落位动画掐断（用户实测报的 bug）。
	_menu_blocked = true
	# ① 先让主界面「出场」：`visible = true` 但 alpha 0 —— 排版要它显示才算得出来，而 alpha 0 看不见。
	#   ⚠️ **外壳这时仍然藏着**：它整块都在屏幕边上（资料 / 侧边栏 / 右下入口），
	#      提前显示就会在落位动画期间露出一堆按钮；而且它里面有能点的东西 ——
	#      显示在 alpha 0 上等于给玩家一片「看不见但点得到」的按钮。
	if _menu != null:
		_menu.visible = true
		_menu.modulate.a = 0.0

	var ready: bool = await _wait_targets_ready()
	if not is_instance_valid(self) or not _intro_morphing:
		return
	if not ready:
		push_warning("入场落位动画：主界面的排版没能在若干帧内落定，改为直接切页（不做落位）。")
		_finish_intro()
		return

	var targets: Array = _morph_targets()
	var sec: float = _intro_morph_sec()
	_morph_tween = create_tween()
	_morph_tween.set_parallel(true)
	_morph_tween.set_trans(Tween.TRANS_CUBIC)
	_morph_tween.set_ease(Tween.EASE_IN_OUT)
	_morph_slide(_morph_tween, _emblem, targets[0][1], sec)
	_morph_slide(_morph_tween, _title, targets[1][1], sec)
	_morph_slide(_morph_tween, _title_rule, targets[2][1], sec)
	# 标题的字号与字距、金线的渐隐长度 —— 一起走过去
	var dst_word: Control = targets[1][1]
	var dst_rule: Control = targets[2][1]
	if _title != null and dst_word != null:
		var t = _title
		var w = dst_word
		_morph_tween.tween_method(_set_title_font_size, float(t.font_size), float(w.font_size), sec)
		_morph_tween.tween_method(_set_title_tracking, float(t.tracking), float(w.tracking), sec)
	if _title_rule != null and dst_rule != null:
		var r = _title_rule
		var d = dst_rule
		_morph_tween.tween_method(_set_rule_fade, float(r.fade), float(d.fade), sec)
	# 提示文字淡出（主界面上没有它）
	if _click_hint != null:
		_morph_tween.tween_property(_click_hint, "modulate:a", 0.0, sec * 0.5)
	_morph_tween.tween_callback(_on_morph_done).set_delay(sec)


## 落位动画的三对「入场页 → 主界面标题条里那一块」。
func _morph_targets() -> Array:
	var orn := menu_ornaments()
	if orn == null:
		return []
	return [
		[_emblem, orn.get_node_or_null("MenuEmblemWrap/MenuEmblem")],
		[_title, orn.get_node_or_null("MenuWordmark")],
		[_title_rule, orn.get_node_or_null("MenuRuleWrap/MenuRule")],
	]


## 等主界面的排版真的算出来。@return false = 等不到（调用方应放弃动画、直接切页）。
##
## ★ 判据是「三块目标都排过版」，而不是「等一帧」：容器排版的落定要经过
##   「父容器 sort → 子控件尺寸变化 → 子容器再 sort」好几跳，一跳可能就是一帧 ——
##   只等固定帧数是**赌**出来的，赌输的表现就是「徽记飞到屏幕左上角」。
##
## ⚠️⚠️ 判据里**不能**用「尺寸 > 1」：金线本来就只有 1px 高（`custom_minimum_size.y = 1`），
##   那样写会把一条**排得好好的**金线判成「没排过版」而整条跳过 —— 实测踩到：线一动不动。
##   所以这里判的是**位置不为零**：这三块都住在整页居中的那一列里，真排过版就绝不可能在 (0,0)。
func _wait_targets_ready(max_frames: int = 8) -> bool:
	var targets: Array = _morph_targets()
	if targets.size() < 3:
		return false
	for i in max_frames:
		var ready := true
		for pair in targets:
			var dst: Control = pair[1]
			if dst == null:
				return false
			var r: Rect2 = dst.get_global_rect()
			if r.position == Vector2.ZERO or r.size.x < 0.5:
				ready = false
				break
		if ready:
			return true
		await get_tree().process_frame
	return false



func _on_morph_done() -> void:
	_morph_tween = null
	if not _intro_morphing:
		return                      # 中途被取消（例如进了游戏）—— 不要把菜单 show() 出来
	# ★ 两枚徽记的**转速对齐**：入场页那枚从入场起就一直在转，主界面那枚还停在 0 ——
	#   不接过去的话，切页那一瞬间图形会「跳」一个角度（最多能差几十度）。
	var orn := menu_ornaments()
	var dst_emblem: Control = orn.get_node_or_null("MenuEmblemWrap/MenuEmblem") if orn != null else null
	if dst_emblem != null and _emblem != null and dst_emblem.has_method("set_spin_angle"):
		dst_emblem.set_spin_angle(_emblem.arc_angle())
	_finish_intro()


## 把 `src` 从「它此刻的屏幕矩形」缓动到 `dst` 此刻的屏幕矩形。
##
## ★ 两端都用**屏幕矩形**：两边挂在不同的父节点 / 容器里，只有屏幕坐标是同一个坐标系。
## ★ 拍平锚点：之后 `position/size` 完全由 Tween 写（锚点还挂着的话，容器会在动画中途把它们拽回去）。
## ⚠️ 这里**不**做「尺寸太小就跳过」的判断：金线本来就只有 1px 高，那种守卫会把一条
##   排得好好的线整条判掉（实测踩到过：线一动不动）。目标可不可信由 `_wait_targets_ready()`
##   统一把关，那之后再量到的矩形就是可信的。
func _morph_slide(tw: Tween, src: Control, dst: Control, sec: float) -> void:
	if src == null or dst == null:
		return
	var to: Rect2 = dst.get_global_rect()
	var from: Rect2 = src.get_global_rect()
	var origin: Vector2 = _intro.global_position if _intro != null else Vector2.ZERO
	src.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	src.position = from.position - origin
	src.size = from.size
	tw.tween_property(src, "position", to.position - origin, sec)
	tw.tween_property(src, "size", to.size, sec)


func _intro_morph_sec() -> float:
	return cfg.num("menu.intro_morph_sec", 0.5) if cfg != null else 0.5


func _set_title_font_size(v: float) -> void:
	var t = _title
	if t != null:
		t.font_size = int(round(v))


func _set_title_tracking(v: float) -> void:
	var t = _title
	if t != null:
		t.tracking = v


func _set_rule_fade(v: float) -> void:
	var r = _title_rule
	if r != null:
		r.fade = v


## 取消还没跑完的落位动画（进游戏 / 被别的路径切走时）。
## ★ 杀掉 Tween 之后那个收尾回调就不会来，于是**不会再切页** ——
##   否则它会在游戏画面上把菜单 `show()` 出来。
func _cancel_intro_morph() -> void:
	if _morph_tween != null and _morph_tween.is_valid():
		_morph_tween.kill()
	_morph_tween = null
	_intro_morphing = false


## 主界面标题条那几块（徽记 / 字标 / 金线）—— **只给测试与排查用**。
##
## ★ 为什么要开这个口子：它们住在 `MenuOrnaments`（一个 VBox，见 `_build_menu` 的结构图），
##   而那一层为什么必须与按钮列一起放进同一个 VBox、又为什么不能直接塞进 MenuColumn，
##   写在 `_build_menu` 里。测试要断言「标题条真的在那一列上方、且没有把列撑歪」，
##   光靠节点路径要写一长串，所以这里转一层。
func menu_ornaments() -> Control:
	return _menu.get_node_or_null("MenuPad/MenuOuter/MenuOrnaments") if _menu != null else null


## ★ 主界面的**版式外壳**（左上资料 / 左侧导航 / 右下入口）—— 只给测试与排查用。
## ★ 它自带撑开 / 让路的机制：测试走 `menu_chrome().expand_engine()` 看展开状态与那块空面板。
func menu_chrome() -> Control:
	return _chrome


## ★ 主界面正中那几颗测试入口 —— 只给测试与排查用。
## ★ 顺序 = `menu.test_entries` 里的顺序（左列从上到下）。
## 打开合作面板（右下角「合作模式」与测试用；不模拟鼠标）。
func open_coop_panel() -> void:
	if _chrome != null:
		_chrome.open_coop_panel()


func test_buttons() -> Array:
	if _menu == null:
		return []
	var column := _menu.get_node_or_null("MenuPad/MenuOuter/MenuColumn")
	if column == null:
		return []
	var out: Array = []
	for c in column.get_children():
		if c is Button:
			out.append(c)
	return out


## ★ 当前撑开面板里那块战役菜单（`view/campaign_menu.gd`）—— 只给测试与排查用。
##
## ★ 战役菜单住在**「战役」那颗按钮撑开的面板**里：要拿它得先把那块面板展开
##   （点「战役」，或 `menu_chrome().expand_engine().expand(...)`），再问这里。
##   没展开 / 展开的是别的块时返回 null。
func campaign_menu():
	return _chrome.campaign_menu() if _chrome != null else null


## ★★ 把撑开的面板立刻收回初始态（不播动画）—— 回主菜单时用。
##
## 为什么需要：从战役菜单长按进入游戏时，整层菜单只是被 `hide()` 了，面板还停在撑开态；
##   不收回的话「返回主菜单」之后玩家看到的是那块开着的面板，而不是主界面。
##   ★ 用**即时**收回：游戏期间这一层是隐藏的，播放收回动画既没人看见、又可能跑一半。
func reset_panels() -> void:
	if _options_panel != null and _options_panel.is_open():
		_options_panel.close()
	if _chrome != null:
		_chrome.reset_secondary_panel()


## 入场页标题（`view/text_marks.gd` 的 SpacedLabel，**不是** Label）。
## ★ 给测试用：它是自绘控件，`text` / `tracking` / `measured_width()` 都要从这里读。
func intro_title() -> Control:
	return _title
