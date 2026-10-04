## menu_theme.gd —— ★ 进入界面（入场页 / 主界面 / 战役页）的 StyleBox 工厂
##
## 与 `view/ui_style.gd` 的关系：**同一套配色（都取自 view/theme.gd），不同的用法**。
##   · ui_style 是游戏内 HUD：面板**半透明**、浮在地图上；
##   · 本文件是进入界面：底是**不透明渐变**、控件用**金线描边 + 透明底**。
## 两边的观感差别来自「底色是什么」，而不是来自「另一套金色」——这一点别搞混。
##
## 进入界面的控件只有三种状态，各自由主题派生（**不写死第二组颜色**）：
##   ① 空（normal）：透明底 + 1px 金线 —— 参考图里那些框就是这么画的；
##   ② 悬停（hover）：同一根线加亮（accent_bright）+ 极淡的金底 —— 「鼠标在这儿」；
##   ③ 选定 / 按下（pressed / selected）：**实心金** + 近黑的字 ——
##      参考图里没有实心块，但「选了哪一个」必须一眼看得出（页签 / 关卡行都靠它）。
##
## ⚠️ 内边距（content_margin）只在左右各留 12：进入界面的按钮都是**文字居中**，
##   上下不需要内边距（高度由 config 里的 *_height 定死）。
extends RefCounted

const ThemeRes = preload("res://view/theme.gd")

## 线框按钮的左右内边距（文字与金线之间留一点气）
const PAD_X := 12.0


# ------------------------------------------------------------------
# 按钮四态
# ------------------------------------------------------------------

## 透明底 + 金线：进入界面的「默认长相」。
static func button_normal() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	s.border_color = ThemeRes.line()
	s.set_border_width_all(1)
	s.content_margin_left = PAD_X
	s.content_margin_right = PAD_X
	return s


## 悬停：线变亮 + 一层几乎看不见的金底。
## ★ 底色的 alpha 只给 0.08：给多了就成了「实心块」，与选定态分不出来。
## ⚠️ 这一档现在只给**没有填充层**的按钮用（见下面的 `button_hover_clear()`）——
##   挂了 `fill_button` 的按钮，悬停的金由那层自绘填充负责。
static func button_hover() -> StyleBoxFlat:
	var s := button_normal()
	s.bg_color = ThemeRes.accent_alpha(0.08)
	s.border_color = ThemeRes.with_alpha(ThemeRes.accent_bright(), 0.85)
	return s


## ★★ 挂了填充层的按钮在悬停时用的底纹：**底全透明 + 亮线**。
##
## 为什么不能照旧用 `button_hover()` 那 0.08 的金底：
##   填充层画在**底纹下面**，那 0.08 就是「在半透明的金上再叠半透明的金」，
##   观感是「悬停只亮了一点点」——需求要的是「金色自下而上填满」。
##   底透明之后，屏幕上那片金**完全**由填充层给，于是「填到哪」一目了然。
static func button_hover_clear() -> StyleBoxFlat:
	var s := button_normal()
	s.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	s.border_color = ThemeRes.accent_bright()
	return s


## 按下 / 选定：实心金 + 稍亮的线（文字要配 `menu_theme.text_on_fill()` 那一档近黑）。
static func button_selected() -> StyleBoxFlat:
	var s := button_normal()
	s.bg_color = ThemeRes.accent()
	s.border_color = ThemeRes.accent_bright()
	return s


## ★★ 「已启用 / 已选中」那一档：**底色交给填充层**（透明底 + 亮描边）。
##   给挂了 `fill_button` 的行用（战役页的关卡 / 阵营列表就是它）——
##   `button_selected()` 那份实心金会把画在底纹**下面**的填充整个盖住，
##   于是「点击启用后亮度变大」这件事就没地方体现了。
static func button_fill_latched() -> StyleBoxFlat:
	var s := button_normal()
	s.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	s.border_color = ThemeRes.accent_bright()
	s.set_border_width_all(2)
	return s


## ★★ 「已启用 / 已选中」并且鼠标停着：比 `button_selected()` **再亮一档**
##   （需求原话：点击启用时「亮度稍微变大」）。挂填充层的按钮用它当 hover 档 ——
##   否则「选中之后再悬停」会比「选中」更暗（0.08 的金底盖不住实心金）。
static func button_selected_hover() -> StyleBoxFlat:
	var s := button_selected()
	s.bg_color = ThemeRes.accent_bright()
	s.border_color = ThemeRes.with_alpha(Color(1.0, 1.0, 1.0, 1.0), 0.55)
	s.set_border_width_all(2)
	return s


## 禁用（没有可用地图 / 不能开始）：线变暗、底透明。
## ★ 只压线的亮度，**不**把控件做成半透明 —— 半透明会让它看起来「还在，只是灰了」，
##   而禁用该看起来就是「不参与」。
static func button_disabled() -> StyleBoxFlat:
	var s := button_normal()
	s.border_color = ThemeRes.line_soft()
	return s


## 透明底 + 更亮的金线：给「少数几个主行动」用（战役页的「开始」）。
## 它**不是**实心金：实心金留给「当前选中的那一项」，主按钮与选中项撞色就分不清了。
static func button_primary() -> StyleBoxFlat:
	var s := button_normal()
	s.bg_color = ThemeRes.accent_alpha(0.10)
	s.border_color = ThemeRes.with_alpha(ThemeRes.accent_bright(), 0.95)
	return s


# ------------------------------------------------------------------
# 下拉列表（PopupMenu）
#
# ★★ 需求（本版）：「下拉列表也搞相同的风格化」—— 意思是列表要与
#   「暗底 + 金线 + 悬停金」这一套**看起来是同一件东西**，而不是引擎默认的浅色 HUD 皮。
#   三处刻意与默认不同：
#     · 底板：不透明深底 + **金色描边**（与线框按钮同一条线）+ 小圆角 + 一点内阴影；
#     · 悬停行：**实心淡金底 + 左侧一条金色竖线**（与部队列表的选中行同一套语言：
#       「竖线 + 淡金底」在别处已经用过，玩家已经会读了）；
#     · 左右留白比默认大一点：中文项在两个字的宽度下贴着边框会显得挤。
# ------------------------------------------------------------------

## 列表那块底板。
## ★★ 这里**必须不透明**（与 HUD 面板相反）：PopupMenu 是引擎的**独立窗口**，
##   底下没有渐变背景可透 —— 用半透明会直接看到桌面 / 后面的别的东西。
static func popup_panel() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = ThemeRes.with_alpha(ThemeRes.bg_bottom(), 1.0)
	s.border_color = ThemeRes.line()
	s.set_border_width_all(1)
	s.set_corner_radius_all(2)
	s.set_content_margin_all(6.0)
	# 一点内阴影：列表贴到屏幕边缘时，「这块是浮在上面的」比纯色更容易看出来
	s.shadow_color = Color(0.0, 0.0, 0.0, 0.55)
	s.shadow_size = 6
	s.shadow_offset = Vector2(0.0, 2.0)
	return s


## 列表里鼠标停在一项上的底纹：**实心淡金底 + 左侧金线**（与部队列表的选中行同一套）。
## ★ 用实心（`accent_alpha` 那一档）而不是 0.16 那种极淡底：列表项是**独立窗口**里的
##   一行文字，没有别的东西帮它强调「鼠标在这儿」，淡到几乎看不见就等于没有反馈。
static func popup_row_hover() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = ThemeRes.accent_alpha(0.22)
	s.border_color = ThemeRes.accent()
	s.border_width_left = 2
	s.content_margin_left = 8.0
	s.content_margin_right = 6.0
	s.content_margin_top = 4.0
	s.content_margin_bottom = 4.0
	return s


## 列表项之间的分隔线（有 `separator` 的项用）。
static func popup_separator() -> StyleBoxLine:
	var s := StyleBoxLine.new()
	s.color = ThemeRes.with_alpha(ThemeRes.line(), 0.55)
	s.thickness = 1
	return s


# ------------------------------------------------------------------
# 字色（三档，见 config.json 的 menu._comment：暗底 + 金线之后必须这么分）
# ------------------------------------------------------------------

## 线框按钮上的字（暖白）
static func text_normal() -> Color:
	return ThemeRes.text()


## 实心金底上的字（近黑）
static func text_on_fill() -> Color:
	return ThemeRes.text_on_accent()


## 禁用时的字
static func text_disabled() -> Color:
	return ThemeRes.text_faint()


## 次要文字（标签 / 说明）
static func text_dim() -> Color:
	return ThemeRes.text_dim()


# ------------------------------------------------------------------
# 悬停填充金的两端（见 view/fill_button.gd）
#
# ★ 与 HUD 那一侧**同一套金**（都取自 theme.gd）：进入界面与游戏内不会出现两种金。
# ------------------------------------------------------------------

static func fill_top() -> Color:
	return ThemeRes.fill_top()


static func fill_bottom() -> Color:
	return ThemeRes.fill_bottom()


static func fill_top_latched() -> Color:
	return ThemeRes.fill_top_latched()


static func fill_bottom_latched() -> Color:
	return ThemeRes.fill_bottom_latched()
