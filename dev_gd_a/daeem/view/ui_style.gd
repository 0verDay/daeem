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

## 字号（参考图是 1920×1080 的稿子，这里的字号按那个尺度定）
const FS_TINY := 11
const FS_SMALL := 13
const FS_BODY := 15
const FS_TITLE := 17
const FS_BIG := 44


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
static func tab_normal() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.0, 0.0, 0.0, 0.0)
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
