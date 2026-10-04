## theme.gd —— ★ **全局主题（皮肤）的唯一入口**
##
## 风格来自参考图的三件事（用户需求原文）：
##   「暗色色渐变底 + 金色细线边框 + 纯几何形状组合图标」。
##   ⇒ 这套 UI 只有三种视觉手段：**渐变暗底**、**1px 金色线**、**几何图形**。
##     没有贴图、没有圆角化的花边、没有第二种强调色 —— 加任何一样都是在破坏它。
##
## ★★ 为什么要有这个文件（而不是继续把颜色写在 ui_style.gd 里）：
##   `ui_style.gd` 是**游戏内 HUD** 的 StyleBox 工厂，它的常量是按「面板浮在地图上半透明」
##   这件事定的（面板底色的 alpha 那一堆）。而进入界面（`view/menu_theme.gd`）要的是
##   「不透明渐变底 + 金线」——两边的**用法**不同、但**配色必须是同一套**。
##   于是：配色抽到本文件（读 `data/config.json` 的 `theme.palette`），两边都从这里取。
##   ⇒ 「强调色是金是蓝」只在一个地方决定，不会再出现「菜单金色、HUD 蓝色」这种两套皮。
##
## ★ 为什么配色在 JSON 而不是像字号那样直接写成常量（这是条口径，别再混）：
##   · **能被调的东西进 config.json**：颜色是设计师天天要改的（换个金色、调暗一点），
##     而且 `data/config.json` 已经是全项目「可调数值的唯一来源」（见 logic/config.gd 铁律）。
##   · **度量常量留在代码里**：字号 / 线宽 / 间距不是配色，它们与布局耦合
##     （改字号会撞到 ui_layout 的框），写成常量才能被 `tests/test_ui.gd` 直接断言。
##
## ★ 本文件**不认识 cfg 实例**：`color()` 这些全是静态函数，自己去 JSON 里取。
##   理由：读颜色的地方有十几处（HUD / 菜单 / 小地图），要求每个调用点手里都有一个 cfg
##   会把「取个颜色」变成「先拿到 cfg」。
##
## ⚠️ 所以它**自己缓存那份色板**（`_palette`）：
##   `ConfigRes.load_default()` 是**没有缓存**的（每次都重读并解析整份 JSON，
##   见 logic/config.gd `_load`）—— 而搭一页界面要取几十次颜色，
##   不缓存就是「开一次菜单解析几十遍 config.json」。
##   ⇒ 色板只读一次，之后的 `color()` 是纯字典查表（可以放心在 _draw 里用）。
##
## ⚠️ 与 `data/config.json` 的键名是一一对应的：改键名要两边一起改，
##   兜底值（下面的 DEFAULT_*）同时也写着「这个键应该长什么样」。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")

## 配色所在的路径前缀（`data/config.json` 的 theme 段）。
const PALETTE_PATH := "theme.palette"


# ------------------------------------------------------------------
# 兜底色（JSON 缺键 / 值写坏时用）
#
# ★ 它们不是「备用主题」：值与 config.json 里那份**逐位一致**，只是保证
#   「JSON 被人改坏」时界面仍然是一套能看的暗金，而不是一片洋红 / 全黑
#   （Config.parse_color 的兜底色是 MAGENTA —— 那是给排查用的，不该出现在成品界面上）。
# ------------------------------------------------------------------
const DEFAULT_BG_TOP := Color(0.102, 0.137, 0.204, 1.0)      # #1a2334
const DEFAULT_BG_BOTTOM := Color(0.039, 0.059, 0.094, 1.0)   # #0a0f18

## ★★ 强调色：原来是蓝 #1E98D7，本轮按用户拍板换成金。
##   凡是从前读 `UiStyleRes.ACCENT` 的地方（页签高亮 / 设置按钮 / 命令卡高亮 /
##   科技格 / 小地图视野框 / 部队列表高亮）现在自动是金色 —— 一行 UI 代码都不用改。
const DEFAULT_ACCENT := Color(0.847, 0.698, 0.373, 1.0)      # #d8b25f
const DEFAULT_ACCENT_BRIGHT := Color(0.949, 0.867, 0.627, 1.0)  # #f2dda0
const DEFAULT_ACCENT_DEEP := Color(0.561, 0.455, 0.204, 1.0)    # #8f7434

const DEFAULT_LINE := Color(0.541, 0.459, 0.251, 1.0)        # #8a7540
const DEFAULT_LINE_SOFT := Color(0.290, 0.251, 0.161, 1.0)   # #4a4029

const DEFAULT_TEXT := Color(0.910, 0.890, 0.835, 1.0)        # #e8e3d5
const DEFAULT_TEXT_DIM := Color(0.659, 0.624, 0.541, 1.0)    # #a89f8a
const DEFAULT_TEXT_FAINT := Color(0.435, 0.412, 0.341, 1.0)  # #6f6957
const DEFAULT_TEXT_ON_ACCENT := Color(0.078, 0.063, 0.039, 1.0)  # #14100a

## ★★ 「按钮悬停时自下而上填进来的那片金」（见 view/fill_button.gd）。
##   与 `accent`（#d8b25f）**刻意不是同一个值**：那片金要压在文字底下，而面板上的
##   文字是**暖白**的（`text` —— 命令卡 / 科技格 / 部队行都是它）。
##   拿实心 accent 当底，暖白压上去只有 2.6:1，11~15 号的小字会糊。
##   所以填充用**深一档、更饱和的金**（L≈0.34）：
##     · 暖白压上去 ≈3.6:1 —— 11 号字也读得出来；
##     · 而且没掉进「糊成一片棕」：底 / 顶两端是一条**竖直渐变**（R:G 比仍是金）。
## ★ 页签 / 科技格那两块底下还叠着一层半透明的暗底（`.55`），
##   所以这两档是**按叠上之后**仍然像金来定的（不是按「直接铺在渐变底上」定的）。
const DEFAULT_FILL_BOTTOM := Color(0.847, 0.651, 0.282, 1.0) # #d8a648
const DEFAULT_FILL_TOP := Color(0.722, 0.510, 0.227, 1.0)    # #b8823a

## ★★ 「已启用」那一档的增亮金（需求原话：点一下启用之后「亮度稍微变大」）。
##   比上面那两档亮约 17% —— 要的是「看得出它一直亮着」，而不是「闪一下」。
##   为了让「启用态」与「悬停态」是同一个色系（而不是两种金），
##   它直接取 `accent` / `accent_bright` 这一对 —— 也就是界面高亮一直用的那支金。
const DEFAULT_FILL_BOTTOM_LATCHED := Color(0.949, 0.867, 0.627, 1.0)  # #f2dda0（= accent_bright）
const DEFAULT_FILL_TOP_LATCHED := Color(0.847, 0.698, 0.373, 1.0)     # #d8b25f（= accent）

## ★★ 「不可点」那一档的填充（需求：禁用态也要有悬停反馈，但填的是**灰**）。
##   两支灰**刻意压得很低饱和**：金色是「这里能点」的信号，灰必须一眼看出不是金，
##   同时又要与深色面板分得开（否则等于没有反馈）。
const DEFAULT_FILL_DISABLED_BOTTOM := Color(0.404, 0.416, 0.435, 1.0)  # #676a6f
const DEFAULT_FILL_DISABLED_TOP := Color(0.290, 0.302, 0.322, 1.0)     # #4a4d52

## 填充底上的字（暗金褐系）：**暗到能被那片金衬出来**，但保留原字色的色相。
##
## ★★ 为什么是「按亮度定标」而不是「往某一支颜色 lerp」：
##   这两种写法都试过 —— lerp 到固定目标色的结果是
##     · 目标色一改，**有的原色被压暗、有的反而被提亮**（原本就是近黑的
##       `text_on_accent` 会被提亮，字直接糊掉）；
##     · 而且「压到几成」随原色漂，同一个填充进度下每一格字的深浅都不一样。
##   改成「不管原色是什么，都把它定到**同一个目标亮度**」之后，
##   同屏所有挂了填充的字在满格时**一样深**，对比度也可预期。
##   ⚠️ 目标亮度（= 这两个色的 `get_luminance()`）是按**满格实测对比度**定的：
##      · 悬停档的金压出来 ≈8:1；
##      · 启用档更亮的金 ≈6:1。
##      改填充金 / 改这两个色时，`tests/test_fill_button.gd` 里的
##      「全程序对比度」用例会告诉你够不够（它会扫遍整条动画，不只是满格）。
const DEFAULT_TEXT_ON_FILL := Color(0.110, 0.086, 0.047, 1.0)        # #1c160c
const DEFAULT_TEXT_ON_FILL_LATCHED := Color(0.063, 0.047, 0.020, 1.0)  # #100c05


# ------------------------------------------------------------------
# ★★ 动效总开关（需求：给填充动效一个统一开关）
# ------------------------------------------------------------------

## `true` = 播填充 / 渐出动画；`false` = **立刻到位**（不播动画，状态照常切换）。
##
## ★ 为什么不做进 `data/config.json`：
##   它要能被**运行时**切（低动效偏好 / 以后设置菜单里加一项），而且**必须对
##   所有已经建好的按钮立刻生效**。走 config 的话就得让每颗按钮去监听配置变更；
##   这里是一处静态标志，`fill_button` 每帧读它 —— 改一下，全场生效。
##   ⚠️ 与 `reset_cache()` 同一类「给测试 / 设置用的口子」，别在日常逻辑里随手改。
static var _animations_enabled: bool = true


static func animations_enabled() -> bool:
	return _animations_enabled


## 开关填充 / 渐出动画。
## ★ 关掉**不改变任何状态**（悬停还是悬停、启用还是启用），只是把「过渡过程」
##   压成 0 秒 ⇒ 观感**立刻到位**，而不是「没有反馈」。
static func set_animations_enabled(on: bool) -> void:
	_animations_enabled = on

const DEFAULT_GLOW := Color(0.847, 0.698, 0.373, 1.0)        # #d8b25f
const DEFAULT_GLOW_ALPHA := 0.10

const DEFAULT_WARNING := Color(0.878, 0.541, 0.416, 1.0)     # #e08a6a
const DEFAULT_HP_HIGH := Color(0.478, 0.690, 0.416, 1.0)     # #7ab06a
const DEFAULT_HP_MID := Color(0.847, 0.698, 0.373, 1.0)      # #d8b25f
const DEFAULT_HP_LOW := Color(0.788, 0.349, 0.247, 1.0)      # #c9593f

## 「面板是半透明」这一档的 alpha（★ 不是配色，是**可读性约束**）：
##   HUD 底栏占屏幕下方 400px、命令卡与页签直接立在地图上，
##   做成不透明会把地图遮死（这是旧主题就踩过的坑，别再改回 1.0）。
##   ⇒ 所以 bg_top / bg_bottom 只用来**派生**面板底色，面板自己的 alpha 在这里定。
const PANEL_ALPHA := 0.86
const PANEL_SOFT_ALPHA := 0.72
const PANEL_EMPTY_ALPHA := 0.55
const PANEL_HOVER_ALPHA := 0.92
const PANEL_PRESSED_ALPHA := 0.95
## 悬停详情面板（浮在地图上）要比底栏更不透明一点：它只有 340 宽，
## 地图的格子线会从下面透上来把 13 号字糊掉。
const PANEL_HOVER_TIP_ALPHA := 0.93

## 选中态 / 高亮态底色的 alpha（同一支强调色，只是浓淡）。
const ACCENT_SELECT_ALPHA := 0.22
const ACCENT_PRESSED_ALPHA := 0.35


# ------------------------------------------------------------------
# 取色
# ------------------------------------------------------------------

## 缓存下来的色板（`data/config.json` 的 theme.palette 那一层）。
## ★ static：整个进程里只有一份，与「主题是全局的」这件事一致。
static var _palette: Dictionary = {}
## 已经找过一遍了吗 —— ★ 必须与「_palette 是空的」分开记：
##   一份**合法的空色板**（JSON 里把 theme 删了）与「还没找过」是两种状态，
##   只看 `_palette.is_empty()` 的话，前者会每次都重读一遍盘。
static var _palette_loaded: bool = false


## theme.palette 那一层（找不到 → 空字典）。
static func palette() -> Dictionary:
	if _palette_loaded:
		return _palette
	_palette_loaded = true
	var cfg: Variant = ConfigRes.load_default()
	if cfg == null:
		# 配置坏了：不报错、不崩 —— 让下面的 DEFAULT_* 顶上，界面仍然画得出来
		# （真正的错误已经由 ConfigRes.load_default() 自己 push_error 过了）。
		_palette = {}
		return _palette
	var v: Variant = cfg.get_path_value(PALETTE_PATH)
	_palette = v if typeof(v) == TYPE_DICTIONARY else {}
	return _palette


## 丢掉缓存，下次取色重新读盘。
## ★ 给测试用（改了 config.json 的色板之后要能重新读到），运行时**不该**调它 ——
##   主题在运行中变来变去会让「同一个东西两帧不同色」。
static func reset_cache() -> void:
	_palette = {}
	_palette_loaded = false


## JSON 里 `theme.palette.<key>` 的颜色。取不到 / 写坏 → fallback。
static func color(key: String, fallback: Color) -> Color:
	var raw: Variant = palette().get(key, null)
	if typeof(raw) == TYPE_STRING:
		return ConfigRes.parse_color(String(raw), fallback)
	return fallback


static func bg_top() -> Color:
	return color("bg_top", DEFAULT_BG_TOP)


static func bg_bottom() -> Color:
	return color("bg_bottom", DEFAULT_BG_BOTTOM)


static func accent() -> Color:
	return color("accent", DEFAULT_ACCENT)


static func accent_bright() -> Color:
	return color("accent_bright", DEFAULT_ACCENT_BRIGHT)


static func accent_deep() -> Color:
	return color("accent_deep", DEFAULT_ACCENT_DEEP)


static func line() -> Color:
	return color("line", DEFAULT_LINE)


static func line_soft() -> Color:
	return color("line_soft", DEFAULT_LINE_SOFT)


static func text() -> Color:
	return color("text", DEFAULT_TEXT)


static func text_dim() -> Color:
	return color("text_dim", DEFAULT_TEXT_DIM)


static func text_faint() -> Color:
	return color("text_faint", DEFAULT_TEXT_FAINT)


static func text_on_accent() -> Color:
	return color("text_on_accent", DEFAULT_TEXT_ON_ACCENT)


# ------------------------------------------------------------------
# 填充金（悬停 / 已启用那一片，见 view/fill_button.gd）
# ------------------------------------------------------------------

static func fill_bottom() -> Color:
	return color("fill_bottom", DEFAULT_FILL_BOTTOM)


static func fill_top() -> Color:
	return color("fill_top", DEFAULT_FILL_TOP)


static func fill_bottom_latched() -> Color:
	return color("fill_bottom_latched", DEFAULT_FILL_BOTTOM_LATCHED)


static func fill_top_latched() -> Color:
	return color("fill_top_latched", DEFAULT_FILL_TOP_LATCHED)


## 禁用态那一档的灰（不可点，但鼠标停上去要有反馈）。
static func fill_disabled_bottom() -> Color:
	return color("fill_disabled_bottom", DEFAULT_FILL_DISABLED_BOTTOM)


static func fill_disabled_top() -> Color:
	return color("fill_disabled_top", DEFAULT_FILL_DISABLED_TOP)


## 填充底上的字：把原字色压到**能被那片金衬出来**的暗度。
##
## @param on  启用（锁定）态那一档 —— 它比悬停态更亮，字要跟着再暗一点
## @param base 原字色；★ 「**在填充上还是不是那个色**」这件事只有调用方知道
##             （命令卡的键位字母是暗金、单位名是暖白、血量是语义色），所以由它给。
##   ⚠️ 不传（或传哨兵 `Color(-1,-1,-1,-1)`）= 用主题的正文色 `text()`。
##
## ★★ **只有「比目标更亮」的原色才需要压**（本版修，实测踩过）：
##   页签 / 战役页那些按钮上本来就挂着**近黑**的字
##   （选中态用的 `text_on_accent`，L≈0.06）。那一档**不需要**压暗 ——
##   硬压的结果是 `fit_luminance()` 把它的亮度**拉到 0.08（更亮）**，
##   于是「明明该是深色字，屏幕上却比原来还浅」（而且断言读到的值与预期差 20%）。
##   ⇒ 判据是「压完之后确实更暗」，否则原样返回（暗字保持暗）。
##   这一条同时让**忘记登记原色**的调用点不会变糟：默认的暖白会被压暗，
##   已经是暗色的则原地不动。
static func text_on_fill(on: bool = false, base: Color = Color(-1.0, -1.0, -1.0, -1.0)) -> Color:
	var from := base if base.a >= 0.0 else text()
	var key := "text_on_fill_latched" if on else "text_on_fill"
	var fallback := DEFAULT_TEXT_ON_FILL_LATCHED if on else DEFAULT_TEXT_ON_FILL
	var target := color(key, fallback).get_luminance()
	if from.get_luminance() <= target:
		return from
	return fit_luminance(from, target)


## 把 `c` 的亮度**定到 `target`**（保持色相：三个通道同乘一个系数）。
##
## ★ 为什么要「同乘」而不是「往灰走」：往灰走会把命令卡键位字母那支**暗金**
##   压成一块脏灰；同乘只是把它整体调暗，暗金仍然是暗金。
## ★ `target` 高于原亮度时系数 > 1 ⇒ 也是同一个式子（所以近黑的字不会被提亮出问题：
##   调用方给的目标永远低于它们）。色相不变，超出 1 的通道被 clamp 回 1。
## ⚠️ 亮度口径用引擎的 `Color.get_luminance()`（gamma 2.2 近似）——
##   与调色 / 对比度断言**同一把尺**，不自己算一套 sRGB 分段函数。
static func fit_luminance(c: Color, target: float) -> Color:
	var lum := c.get_luminance()
	if lum <= 0.0001:
		return Color(c.r, c.g, c.b, c.a)
	var k := clampf(target, 0.0, 1.0) / lum
	return Color(clampf(c.r * k, 0.0, 1.0), clampf(c.g * k, 0.0, 1.0),
		clampf(c.b * k, 0.0, 1.0), c.a)


static func warning() -> Color:
	return color("warning", DEFAULT_WARNING)


static func hp_high() -> Color:
	return color("hp_high", DEFAULT_HP_HIGH)


static func hp_mid() -> Color:
	return color("hp_mid", DEFAULT_HP_MID)


static func hp_low() -> Color:
	return color("hp_low", DEFAULT_HP_LOW)


## 中心辉光（入场页 / 主界面背景那团光）。alpha 单独一个键，便于「有颜色但几乎看不见」。
static func glow(alpha_scale: float = 1.0) -> Color:
	var c := color("glow", DEFAULT_GLOW)
	var a: float = DEFAULT_GLOW_ALPHA
	var raw: Variant = palette().get("glow_alpha", null)
	if typeof(raw) == TYPE_FLOAT or typeof(raw) == TYPE_INT:
		a = float(raw)
	c.a = clampf(a * alpha_scale, 0.0, 1.0)
	return c


# ------------------------------------------------------------------
# 派生
# ------------------------------------------------------------------

## 同一个颜色换个 alpha（面板底色几乎都是这么来的）。
static func with_alpha(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, clampf(a, 0.0, 1.0))


## 往白（t > 0）或黑（t < 0）拉一点 —— 悬停 / 按下态**不写死第二组颜色**，
## 一律由基色派生：以后改主题只改一个基色，四个态自动跟着走。
##
## @param toward  往哪个色拉（默认按 t 的正负取白 / 黑）。
##   ★★ 有了它，「填充底上的字」才能与「填充金」同源：与其再写死一组
##     「金底上的字是什么色」，不如说「把原字色往填充金的方向按比例压下去」——
##     于是以后换一套主题色，字色自动跟着走。
static func lighten(c: Color, t: float, toward: Color = Color(-1.0, -1.0, -1.0, -1.0)) -> Color:
	var target := toward
	if target.a < 0.0:
		target = Color(1.0, 1.0, 1.0, c.a) if t >= 0.0 else Color(0.0, 0.0, 0.0, c.a)
	return c.lerp(Color(target.r, target.g, target.b, c.a), clampf(absf(t), 0.0, 1.0))


## 两色混合（保留 base 的 alpha）。
static func mix(base: Color, over: Color, t: float) -> Color:
	return base.lerp(over, clampf(t, 0.0, 1.0))


## 半透明强调色（选中底 / 按下底）。
static func accent_alpha(a: float) -> Color:
	return with_alpha(accent(), a)


## 进入界面那片**不透明**渐变底的基色。
##
## ★ 它读的是 `menu.bg`（那一页自己的配置），读不到才退回主题的 `bg_top`：
##   入场页 / 主界面 / 战役页**整页都是不透明的**，与 HUD 那些「浮在地图上的半透明面板」
##   是两种东西 —— 半透明面板要的是「暗到能看清字、又透得出地图」，
##   而整页底的职责只是「给金线一个够暗的衬底」。
##   把这一档留在 `menu` 段（而不是塞进 theme.palette）也是这个原因：
##   `theme.palette` 描述的是**全局色板**，`menu.bg` 描述的是**这一页有多暗**。
static func menu_bg() -> Color:
	var cfg: Variant = ConfigRes.load_default()
	if cfg != null:
		var v: Variant = cfg.get_path_value("menu.bg")
		if typeof(v) == TYPE_STRING:
			return ConfigRes.parse_color(String(v), bg_top())
	return bg_top()


## 面板底：由 bg_top（或 bg_bottom）派生 + 固定 alpha。
##   ★ 为什么要派生而不是直接读两个新键：面板色**必须**与渐变底同源，
##     否则「底是暖黑、面板是冷黑」会看出一块块补丁。
static func panel_alpha_color(a: float, top: bool = true) -> Color:
	return with_alpha(bg_top() if top else bg_bottom(), a)
