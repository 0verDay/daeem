## ui_style.gd —— 游戏内 HUD 的 StyleBox 工厂
##
## ★★ 配色不在这里了：全部走 `view/theme.gd`（读 `data/config.json` 的 `theme.palette`）。
##   那才是「暗色渐变底 + 金色细线」这套皮肤的唯一定义处，本文件与
##   `view/menu_theme.gd`（进入界面）都从它取色 —— 于是不会出现两套皮。
##
##   于是这里只剩两种东西：
##     · **面板的 alpha**（半透明那一档）—— 它不是配色而是可读性约束：
##       底栏占屏幕下方 400px、命令卡与页签直接立在地图上，做成不透明会把地图遮死；
##     · **StyleBox 的形状**（描边宽度 / 内边距 / 圆角）—— 形状不属于配色。
##
##   ⚠️ 所以下面的取色函数**不是常量**：主题是数据驱动的，值在运行时才读得到。
##     调用点写 `UiStyleRes.accent()`（多了两个括号），别想着把它们改回常量 ——
##     改回常量就得把配色抄回代码里，那份 JSON 立刻失去意义。
##
## 保留的历史取舍：旧参考图里的白底 / 灰线 / #333 字是**线框稿的占位色**，不搬进游戏。
extends RefCounted

const ThemeRes = preload("res://view/theme.gd")


static func accent() -> Color:
	return ThemeRes.accent()


static func accent_dim() -> Color:
	## 描边的「淡强调色」：同一支金，只是压到 45% —— 浮在地图上的临时面板用它，
	## 免得亮线在暗底上看着像一块脏斑。
	return ThemeRes.with_alpha(ThemeRes.accent(), 0.45)


## 普通面板底 / 占位面板底 / 悬停 / 按下 / 空槽
static func bg() -> Color:
	return ThemeRes.panel_alpha_color(ThemeRes.PANEL_ALPHA, true)


static func bg_soft() -> Color:
	return ThemeRes.panel_alpha_color(ThemeRes.PANEL_SOFT_ALPHA, true)


static func bg_hover() -> Color:
	return ThemeRes.panel_alpha_color(ThemeRes.PANEL_HOVER_ALPHA, true)


static func bg_pressed() -> Color:
	return ThemeRes.panel_alpha_color(ThemeRes.PANEL_PRESSED_ALPHA, false)


static func bg_empty() -> Color:
	return ThemeRes.panel_alpha_color(ThemeRes.PANEL_EMPTY_ALPHA, false)


static func line() -> Color:
	return ThemeRes.line()


static func line_soft() -> Color:
	return ThemeRes.line_soft()


static func text() -> Color:
	return ThemeRes.text()


static func text_dim() -> Color:
	return ThemeRes.text_dim()


static func text_faint() -> Color:
	return ThemeRes.text_faint()


static func text_on_accent() -> Color:
	return ThemeRes.text_on_accent()


## 提示 / 拒绝的红字（招募被拒时在详细信息左栏顶上那行）
static func warn() -> Color:
	return ThemeRes.warning()


# ------------------------------------------------------------------
# 悬停填充金的两端（见 view/fill_button.gd）
#
# ★ 它们**不是**「又一组配色」：底 / 顶就是同一条竖向渐变的两端，
#   而「哪一档」（普通 / 已启用）由 fill_button 按按钮状态选。
#   放在这里是为了让「填充金从哪来」在 HUD 这一侧也有一个名字可读，
#   而不是让每个调用点自己去 `ThemeRes.fill_*()`。
# ------------------------------------------------------------------

static func fill_top() -> Color:
	return ThemeRes.fill_top()


static func fill_bottom() -> Color:
	return ThemeRes.fill_bottom()


static func fill_top_latched() -> Color:
	return ThemeRes.fill_top_latched()


static func fill_bottom_latched() -> Color:
	return ThemeRes.fill_bottom_latched()


## 单位方块里那根血量条的三档颜色（见 view/unit_roster.gd）：
## 一眼看出哪个兵快死了 —— 只写「兵」字的话，满血与残血长得一模一样。
## ⚠️ 这三档**刻意不跟着金色走**：全做成金色就等于把「快死了」这条信息抹掉。
static func hp_high() -> Color:
	return ThemeRes.hp_high()


static func hp_mid() -> Color:
	return ThemeRes.hp_mid()


static func hp_low() -> Color:
	return ThemeRes.hp_low()


## 字号（旧参考图是 1920×1080 的稿子，这里的字号按那个尺度定）
## ★ 字号 / 线宽这类**度量**留在代码里（不跟着配色进 JSON）：它们与布局耦合，
##   改一个会撞到 ui_layout 的框，而且 tests/test_ui.gd 直接断言它们。
const FS_TINY := 11
const FS_SMALL := 13
const FS_BODY := 15
const FS_TITLE := 17
## ⚠️ 这个 44 **只当「量字号用的基准」**了：右栏头像里那个字是按方框现算的
##   （`detail_panel._avatar_font_size()`）—— 44 的字塞进 40×40 的方框会装不下，
##   被裁成「右下角一块」（手玩报过，见那里的注释）。格子 / 左栏那些字都不用这个。
const FS_BIG := 44
## ★ 「单位名称」那一行：旧参考图实测「单位名称」四个字 x 924..1034（宽 110）、
##   y 881..908（字高约 28）⇒ 字号按 29 定（再大右边那 220px 就装不下了）。
const FS_UNIT_NAME := 29


## 通用底板。
##
## ⚠️ 两个颜色参数的默认值是**哨兵**（alpha < 0 = 没给），不是 `bg()` / `line()`：
##   GDScript 不允许默认参数表达式引用同类里的其它静态函数名（解析期就报错），
##   而把配色抄成字面量又会立刻漂成第二份主题 —— 所以进函数再补默认值。
static func panel_style(bg_color: Color = Color(-1, -1, -1, -1),
		border_color: Color = Color(-1, -1, -1, -1), border_width: int = 1) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg() if bg_color.a < 0.0 else bg_color
	s.border_color = line() if border_color.a < 0.0 else border_color
	s.set_border_width_all(border_width)
	s.set_content_margin_all(8.0)
	return s


## ★★ 悬停详情面板（住在命令卡**正上方**，见 ui_layout 的 HOVER_* 那一节）的底板。
##
## 与其它面板同一套深色半透明，但两处**有意不同**：
##   · 描边用 `accent_dim()`（那档淡金）而不是通用描边色 —— 它是**浮在地图上**的临时面板，
##     周围没有底栏那条深色衬底，亮线 + 半透明底会让它看着像地图上的一块脏斑；
##   · 底色比底栏**再不透明一点**（0.86 → 0.93）：它只有 340 宽、又**浮在地图上**，
##     地图的格子线与区块轮廓会从下面透上来，字（13 号）就糊了。
static func hover_panel() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = ThemeRes.panel_alpha_color(ThemeRes.PANEL_HOVER_TIP_ALPHA, true)
	s.border_color = accent_dim()
	s.set_border_width_all(1)
	s.set_corner_radius_all(3)
	s.set_content_margin_all(0.0)      # 内侧留白由 ui_layout.HOVER_PAD 定，子控件自己摆
	return s


## 部队列表的一行（四态）
static func row_normal() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	s.border_color = line_soft()
	s.border_width_bottom = 1
	s.content_margin_left = 8.0
	s.content_margin_right = 4.0
	return s


static func row_hover() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	# ★★ **底透明**（本版修）：部队列表每一行都挂了填充层，而填充层画在底纹**下面**
	#   （见 view/fill_button.gd 的文件头）。这里再铺一层 0.92 的暗底就等于把
	#   「自下而上填进来的金」整个盖住 —— 悬停时只剩一条亮线，金看不见了。
	#   底色交给填充层，这一档只负责「描边亮起来」。
	s.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	s.border_color = line()
	s.border_width_bottom = 1
	s.content_margin_left = 8.0
	s.content_margin_right = 4.0
	return s


## 当前选中的队伍：左侧一条金色竖线 + 淡金底
static func row_active() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = ThemeRes.accent_alpha(ThemeRes.ACCENT_SELECT_ALPHA)
	s.border_color = accent()
	s.border_width_left = 3
	s.content_margin_left = 8.0
	s.content_margin_right = 4.0
	return s


## 空槽：底纹与其它行一样，只有文字变淡（置灰靠字色，不靠色块）
static func row_empty() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	s.border_color = line_soft()
	s.border_width_bottom = 1
	s.content_margin_left = 8.0
	s.content_margin_right = 4.0
	return s


## 命令卡的格子（参考图里格与格之间就是一条线，所以只描边、不留缝）
static func card_normal(filled: bool = true) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.0, 0.0, 0.0, 0.0) if filled else bg_empty()
	s.border_color = line()
	s.set_border_width_all(1)
	s.content_margin_left = 2.0
	s.content_margin_right = 2.0
	s.content_margin_top = 2.0
	s.content_margin_bottom = 2.0
	return s


## 命令卡的格子：悬停 —— **底透明 + 亮线**（本版修：见下面那条 ⚠️）。
##
## ⚠️⚠️ 原来这里铺的是 `bg_hover()`（0.92 的暗底）。那在「填充层画在底纹上面」的旧层次下
##   看不出问题（金把它盖住了），但填充层现在是画在底纹**下面**的（见 view/fill_button.gd）——
##   实底一铺，悬停时那片金就被压在下面，屏幕上只剩一条亮线（用户要的是「金自下而上填满」）。
##   ⇒ 与 `accent_button_clear()` / `tab_plain()` / `tech_fill()` 同一档：底色交给填充层。
static func card_hover() -> StyleBoxFlat:
	var s := card_normal(true)
	s.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	s.border_color = accent_dim()
	return s


## 命令卡的格子：按下 —— 同样**底透明**（理由与 `card_hover()` 那段一样）：
## 这一下按下去的反馈由「填充已满格的更亮的金 + 亮描边」给，不需要再铺一层淡金底。
static func card_pressed() -> StyleBoxFlat:
	var s := card_normal(true)
	s.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	s.border_color = accent()
	s.set_border_width_all(2)
	return s


# ------------------------------------------------------------------
# 科技页的九格（3×3，**盖在命令卡上**）
#
# ★ 为什么底色是**不透明**的（与命令卡那几个格子刻意不同）：
#   科技页是**另一套内容**，不是「往命令卡上填字」——
#   命令卡在科技页里是空的（它按 entries 画格子底色 / 描边），
#   半透明的科技格会让下面那 3×3 的旧网格与描边透出来（看着像两个网格叠在一起）。
#   所以四个状态（普通 / 悬停 / 按下 / 禁用）都直接用 ui_style 的实色。
# ------------------------------------------------------------------

## 科技格：**没启用**的样子（浅底 + 描边，一眼能看出是「可点的格子」）
static func tech_normal() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg()
	s.border_color = line()
	s.set_border_width_all(1)
	s.set_content_margin_all(2.0)
	return s


static func tech_hover() -> StyleBoxFlat:
	var s := tech_normal()
	s.bg_color = bg_hover()
	s.border_color = accent_dim()
	return s


## ★ 科技格：**已启用**的样子 —— 实心强调色（与「当前页签 / 设置按钮」同一档金），
##   加上一圈更亮的外框，所以「哪三格在生效」一眼就看得出（需求要的可见反馈）。
static func tech_active() -> StyleBoxFlat:
	var s := tech_normal()
	s.bg_color = accent()
	s.border_color = ThemeRes.accent_bright()
	s.set_border_width_all(2)
	return s


static func tech_active_hover() -> StyleBoxFlat:
	var s := tech_active()
	s.bg_color = ThemeRes.lighten(accent(), 0.12)
	return s


## 空格子（表里没有第 i 条科技时）：与「空命令格」同一档底，点了不做事
static func tech_disabled() -> StyleBoxFlat:
	var s := tech_normal()
	s.bg_color = ThemeRes.with_alpha(ThemeRes.bg_bottom(), 1.0)
	s.border_color = line_soft()
	return s


## 页签按钮（普通 / 当前页 / 悬停）
##
## ★★ 普通态的底色是 **bg_empty()**（与「空命令格 / 空槽」同一套），**不是全透明**。
##
## 为什么（手玩报的 bug + 截图实测）：「选中建筑时看不到页签」——
##   原来普通态是 `bg = 全透明 + 1px 淡线`，而页签列是**直接立在地图上**的
##   （它自己没有底板），于是非当前页的页签看起来就是「地图透出来的一块」：
##   截图里那块 100×240 的像素与旁边的地图**一模一样**，只有一条几乎看不见的线。
##   换成 bg_empty() 之后，页签在任何底图上都看得见，且与右边的空命令格是同一套观感。
static func tab_normal() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg_empty()
	s.border_color = line()
	s.set_border_width_all(1)
	return s


static func tab_hover() -> StyleBoxFlat:
	var s := tab_normal()
	s.bg_color = bg_hover()
	return s


static func tab_active() -> StyleBoxFlat:
	var s := tab_normal()
	s.bg_color = accent()
	s.border_color = accent()
	return s


## 设置按钮：参考图里它是实心的强调色
static func accent_button() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = accent()
	s.border_color = ThemeRes.with_alpha(ThemeRes.accent_bright(), 0.45)
	s.set_border_width_all(1)
	return s


static func accent_button_hover() -> StyleBoxFlat:
	var s := accent_button()
	s.bg_color = ThemeRes.lighten(accent(), 0.10)
	return s


## ★★ 挂了填充层的实心金按钮（设置菜单那两颗）在悬停时用的底纹：**底透明 + 亮线**。
##   为什么不能照旧用 `accent_button_hover()`：填充层画在底纹**下面**，
##   那 0.10 的提亮色等于把填充金压暗一点点 —— 屏幕上就成了「悬停反而更闷」。
##   底透明之后，那片金完全由填充层给（它能给到**更亮**的一档，见 fill_*_latched）。
static func accent_button_clear() -> StyleBoxFlat:
	var s := accent_button()
	s.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	s.border_color = ThemeRes.accent_bright()
	return s


## ★★ 「已启用 / 已展开」那一档：与 `accent_button()` 同源，只是**更亮一档**
##   （需求原话：点击启用时「亮度稍微变大」）。设置按钮展开菜单时用它。
##
## ⚠️⚠️ **底必须是透明的**（与 `accent_button_clear()` 同一档）：挂了填充层的按钮，
##   那片金是填充层画在**底纹下面**的 —— 底纹一旦自己铺实底，就把填充盖住了，
##   观感就是「填充层在文字之上」（用户报的正是这个）。底色统一交给填充层。
static func accent_button_latched() -> StyleBoxFlat:
	var s := accent_button_clear()
	s.border_color = ThemeRes.accent_bright()
	s.set_border_width_all(2)
	return s


# ------------------------------------------------------------------
# ★★ 「自绘填充」那一档的底纹（见 view/fill_button.gd）
#
# 页签与科技格原本自带一层**半透明暗底**（页签 0.55 / 科技格 0.86），
# 那层暗底会把画在它下面的填充金压暗成一块土黄。
# 于是这两个控件改用下面这一对：**底透明、只留描边** ——
# 底色交给填充层（它就是干这个的），而「这块地方看得见」这件事
# 由**填充 + 描边**一起负责：
#   · 没悬停没启用 → 一条金线（+ 页签那列自己的半透明板）；
#   · 悬停 → 金自下而上填进来；
#   · 已启用 → 常驻满格的金（更亮，见 fill_*_latched）。
# ⚠️ 旧的那几档（tab_normal / tech_normal / …）**留着不动**：
#   它们是「没有填充层的按钮」的底纹，也是 tests 直接断言的那一份。
# ------------------------------------------------------------------

## 页签：只有描边（填充层负责底色）。
static func tab_plain() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	s.border_color = line()
	s.set_border_width_all(1)
	return s


## 页签：悬停 —— 描边亮起（填充层正在往上填）。
static func tab_plain_hover() -> StyleBoxFlat:
	var s := tab_plain()
	s.border_color = ThemeRes.with_alpha(ThemeRes.accent_bright(), 0.9)
	return s


## 页签：**当前页** —— 底透明 + 亮描边（底色由「常驻满格填充」给，比实心色块更亮一档）。
static func tab_latched() -> StyleBoxFlat:
	var s := tab_plain()
	s.border_color = ThemeRes.accent_bright()
	s.set_border_width_all(2)
	return s


## 科技格：只有描边（底透明；空格子仍走 `tech_disabled()` 的实底）。
static func tech_fill() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	s.border_color = line()
	s.set_border_width_all(1)
	s.set_content_margin_all(2.0)
	return s


static func tech_fill_hover() -> StyleBoxFlat:
	var s := tech_fill()
	s.border_color = ThemeRes.with_alpha(ThemeRes.accent_bright(), 0.9)
	return s


## 科技格：**已启用** —— 底透明 + 更亮的双线框（底色由常驻满格填充给）。
static func tech_latched() -> StyleBoxFlat:
	var s := tech_fill()
	s.border_color = ThemeRes.accent_bright()
	s.set_border_width_all(2)
	return s
