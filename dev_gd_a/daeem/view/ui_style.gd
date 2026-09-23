## ui_style.gd —— 新 UI 的配色与 StyleBox 工厂
##
## 取舍（已与需求确认）：**布局逐像素照参考图，配色沿用原来的深色半透明 + 蓝高亮**。
## 参考图里的白底 / 灰线 / #333 字是线框稿的占位色，不搬进游戏 ——
## 但那个蓝（#1E98D7）是真在用的强调色：设置按钮、当前页签、命令卡的高亮都走它。
##
## ★ 面板是半透明的：底栏占屏幕下方 400px，做成不透明会把地图遮死。
extends RefCounted

const ACCENT := Color(30.0 / 255.0, 152.0 / 255.0, 215.0 / 255.0, 1.0)      # #1E98D7
const ACCENT_DIM := Color(30.0 / 255.0, 152.0 / 255.0, 215.0 / 255.0, 0.45)

const BG := Color(0.055, 0.065, 0.085, 0.86)        # 普通面板底
const BG_SOFT := Color(0.075, 0.085, 0.110, 0.72)   # 占位面板（更淡）
const BG_HOVER := Color(0.16, 0.18, 0.22, 0.92)
const BG_PRESSED := Color(0.22, 0.25, 0.30, 0.95)
const BG_EMPTY := Color(0.05, 0.06, 0.075, 0.55)    # 空槽 / 空命令格

const LINE := Color(1.0, 1.0, 1.0, 0.16)
const LINE_SOFT := Color(1.0, 1.0, 1.0, 0.07)

const TEXT := Color(0.92, 0.94, 0.98)
const TEXT_DIM := Color(0.66, 0.70, 0.76)
const TEXT_FAINT := Color(0.42, 0.45, 0.50)
const TEXT_ON_ACCENT := Color(0.97, 0.99, 1.0)

## 提示 / 拒绝的红字（招募被拒时在详细信息左栏顶上那行）
const WARN := Color(1.0, 0.45, 0.42)

## 单位方块里那根血量条的三档颜色（见 view/unit_roster.gd）：
## 一眼看出哪个兵快死了 —— 只写「兵」字的话，满血与残血长得一模一样。
const HP_HIGH := Color(0.45, 0.82, 0.45)
const HP_MID := Color(0.90, 0.78, 0.35)
const HP_LOW := Color(0.88, 0.35, 0.32)

## 字号（参考图是 1920×1080 的稿子，这里的字号按那个尺度定）
const FS_TINY := 11
const FS_SMALL := 13
const FS_BODY := 15
const FS_TITLE := 17
## ⚠️ 这个 44 **只当「量字号用的基准」**了：右栏头像里那个字是按方框现算的
##   （`detail_panel._avatar_font_size()`）—— 44 的字塞进 40×40 的方框会装不下，
##   被裁成「右下角一块」（手玩报过，见那里的注释）。格子 / 左栏那些字都不用这个。
const FS_BIG := 44
## ★ 「单位名称」那一行：参考图实测「单位名称」四个字 x 924..1034（宽 110）、
##   y 881..908（字高约 28）⇒ 字号按 29 定（再大右边那 220px 就装不下了）。
const FS_UNIT_NAME := 29


## 通用底板
static func panel_style(bg: Color = BG, border: Color = LINE, border_width: int = 1) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(border_width)
	s.set_content_margin_all(8.0)
	return s


## 部队列表的一行（四态）
static func row_normal() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	s.border_color = LINE_SOFT
	s.border_width_bottom = 1
	s.content_margin_left = 8.0
	s.content_margin_right = 4.0
	return s


static func row_hover() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = BG_HOVER
	s.border_color = LINE
	s.border_width_bottom = 1
	s.content_margin_left = 8.0
	s.content_margin_right = 4.0
	return s


## 当前选中的队伍：左侧一条蓝竖线 + 淡蓝底
static func row_active() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.22)
	s.border_color = ACCENT
	s.border_width_left = 3
	s.content_margin_left = 8.0
	s.content_margin_right = 4.0
	return s


## 空槽：底纹与其它行一样，只有文字变淡（置灰靠字色，不靠色块）
static func row_empty() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	s.border_color = LINE_SOFT
	s.border_width_bottom = 1
	s.content_margin_left = 8.0
	s.content_margin_right = 4.0
	return s


## 命令卡的格子（参考图里格与格之间就是一条线，所以只描边、不留缝）
static func card_normal(filled: bool = true) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.0, 0.0, 0.0, 0.0) if filled else BG_EMPTY
	s.border_color = LINE
	s.set_border_width_all(1)
	s.content_margin_left = 2.0
	s.content_margin_right = 2.0
	s.content_margin_top = 2.0
	s.content_margin_bottom = 2.0
	return s


static func card_hover() -> StyleBoxFlat:
	var s := card_normal(true)
	s.bg_color = BG_HOVER
	s.border_color = ACCENT_DIM
	return s


static func card_pressed() -> StyleBoxFlat:
	var s := card_normal(true)
	s.bg_color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.35)
	s.border_color = ACCENT
	return s


## 页签按钮（普通 / 当前页 / 悬停）
##
## ★★ 普通态的底色是 **BG_EMPTY**（与「空命令格 / 空槽」同一套），**不是全透明**。
##
## 为什么（手玩报的 bug + 截图实测）：「选中建筑时看不到页签」——
##   原来普通态是 `bg = 全透明 + 1px 白线（alpha 0.16）`，而页签列是**直接立在地图上**的
##   （它自己没有底板），于是非当前页的页签看起来就是「地图透出来的一块」：
##   截图里那块 100×240 的像素与旁边的地图**一模一样**，只有一条几乎看不见的线。
##   换成 BG_EMPTY 之后，页签在任何底图上都看得见，且与右边的空命令格是同一套观感。
static func tab_normal() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = BG_EMPTY
	s.border_color = LINE
	s.set_border_width_all(1)
	return s


static func tab_hover() -> StyleBoxFlat:
	var s := tab_normal()
	s.bg_color = BG_HOVER
	return s


static func tab_active() -> StyleBoxFlat:
	var s := tab_normal()
	s.bg_color = ACCENT
	s.border_color = ACCENT
	return s


## 设置按钮：参考图里它是实心的蓝
static func accent_button() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = ACCENT
	s.border_color = Color(1.0, 1.0, 1.0, 0.25)
	s.set_border_width_all(1)
	return s


static func accent_button_hover() -> StyleBoxFlat:
	var s := accent_button()
	s.bg_color = Color(ACCENT.r + 0.08, ACCENT.g + 0.08, ACCENT.b + 0.05, 1.0)
	return s
