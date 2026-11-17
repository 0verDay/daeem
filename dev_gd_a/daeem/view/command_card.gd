## command_card.gd —— 右下 3×3 命令卡（参考图里 QWE / ASD / ZXC 那九格）
##
## ★ 内容**随右侧页签实时切换**（需求原话）。页签是**按选中对象动态显示**的
##   （见 view/page_tabs.gd 的文件头），所以这里可能收到的几套内容是：
##     操作页 → 大本营「升级 / 取消升级」（★ 2026.11.15 起**只剩建筑**：
##              部队的操作页已删除，移动 / 攻击 / 行军回到右键）
##     单位页 → 三行兵种（Q/W/E …；第 1/2/3 行分别要 1/2/3 级大本营） ← config.json 的 recruit.list
##     建筑页 → 城墙(Q) / 箭塔(W)                     ← 来自 config.json 的 building 段（可建的那些）
##     将领页 → 无选中时拖到区划中心招募的一手（Q/W/E）← world.general_recruit_slots()
##     招募页 → 池子抽出的一手（Q/W/E）              ← world.general_recruit_slots()
##     科技页 → **命令卡这里是空的**：九格由 view/tech_grid.gd 画在最上层
##              （同一个 3×3 几何 + 科技自己的三态样式，见那个文件的说明）
##   没内容的格子只显示键位字母、置灰、点了不做事（页签一颗都没有时九格全空，
##   并由 hud 把这整块和页签一起收起；见 `hud._sync_tabs()`）。
##
## ★ 九格的字母**是真快捷键**（需求确认）：有内容的格子优先于其它绑定。
##   这也是 W/A/S/D 从镜头平移里被拿掉的原因（见 view/main.gd）。
##
## ★ 这一层不认识「建造」「招募」「指令」这些概念：它只把格子里的条目原样抛出去，
##   由 hud.gd 翻译成 input_controller 的动作。想加一页，只需要喂一份新的 entries。
##
## ★★ 格子排版（2026.11 定稿）：「**图标 + 一行名字**」。
##   条目带 `icon_mask`（金线蒙版路径）或 `icon_role`（矢量兜底）时：
##   · 图标**铺满整格** —— 它不考虑文字的位置（用户口径）；
##   · 名字叠在最下面那条**略黑的底条**上（`NAME_BAR_H`，填充扫上来时底条淡出，
##     字翻成压金暗色 —— 否则深底 + 深字读不出来）；
##   · 更长的说明（造价 / 效果 / 解锁条件）只进**悬停面板**（见 hud 的 `_hover_detail`）。
##   没有图标的格子（大本营升级那种纯文字）仍是整格居中的一行字、不垫底条。
##   ⚠️ 名字**永远写进 Label、并且可见** —— `cell_label()` 是测试与排查的语义出口，
##      旧版「有图就把名字藏起来」的做法已经作废（用户改口径了）。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const ThemeRes = preload("res://view/theme.gd")
## ★★ 悬停时「金色自下而上填进来」的那套动效（见 view/fill_button.gd）。
const FillButtonRes = preload("res://view/fill_button.gd")
## ★★ 格子里那枚**单位剪影浮雕图**（见 view/unit_card_icon.gd）。
##   本版：单位页的格子不再写兵种名字，改画**该兵种原画的剪影** ——
##   条目里带 `icon_mask`（hud 灌进来的蒙版路径）就画图；
##   只有 `icon_role` 的旧条目 / 蒙版缺失时退回矢量金线（同一条兜底）。
##   没有这两个键的页面（操作 / 建筑 / 科技）照旧只有字。
const UnitCardIconRes = preload("res://view/unit_card_icon.gd")

## 某一格被快捷键激活时发出，原样带上那一条目（鼠标操作改为上拖松手）。
signal entry_activated(entry: Dictionary)
## 手牌拖起 / 移动 / 松手；屏幕位置是视口像素坐标。
signal card_drag_started(entry: Dictionary, screen_pos: Vector2)
signal card_drag_moved(entry: Dictionary, screen_pos: Vector2)
signal card_drag_finished(entry: Dictionary, screen_pos: Vector2, index: int)

## ★★ 某一格被**鼠标悬停**（进入 / 离开）时发出，带上格子序号。
##   hud 收到后会弹「悬停详情面板」（见 view/hover_tip.gd 与 hud._hover_detail）。
##   ★ 只报序号、不报内容：内容是 hud 按**当前的 entries** 取的 ——
##     与快捷键激活那条路（`activate_index`）同一套判据，界面不会出现
##     「点的是这一格、说明写的是上一页那一格」这种错位。
signal cell_hovered(index: int)
signal cell_unhovered(index: int)

var _entries: Array = []
var _cells: Array[Button] = []
var _card_faces: Array[Panel] = []
var _key_labels: Array[Label] = []
var _name_labels: Array[Label] = []
## ★★ 每格的**名字底条**（略黑半透明横条，名字压在它上面）。
##    只有「这格有图标」时才显示 —— 操作页那种纯文字页不需要底条。
var _name_bars: Array[ColorRect] = []
## ★★ 每格的**单位剪影浮雕**层（`view/unit_card_icon.gd` 的 `IconView`）。
##   与 `_name_labels` 一一对应、同一序号；空串 = 这一格不画图标。
var _icon_views: Array = []
## ★★ 招募数量角标（同种多个时显示在格子右下角）。
var _count_labels: Array[Label] = []
## 纯动作页的大图形符号（招募/建筑/科技仍优先使用剪影蒙版）。
var _glyph_labels: Array[Label] = []
## ★★ 演出呼吸高亮：要亮的招募 kind（空 = 不亮）+ 每格的描边层 + 向外扩散的方形波纹。
var glow_kind: String = ""
var _glow_panels: Array[Panel] = []
var _glow_ripples: Array[Panel] = []
var _glow_t: float = 0.0
## 点击牌组切页时的新牌从牌手下方错落升起；鼠标向上拖牌时跟随指针。
const DRAG_LIFT_THRESHOLD := 10.0
const DRAG_RETURN_SEC := 0.20
## ★★ 2026.11.14：拖拽中「卡面显示 / 淡出」的过渡时长，以及手牌区判据向下放宽多少。
##   （见 `_set_drag_face_alpha()`：拖回手牌就淡回来，拖到地图上就淡掉）
const DRAG_FACE_FADE_SEC := 0.12
const DRAG_FACE_SLACK := 40.0
## 所有牌拖到地图上时的卡面透明度：**只淡一点，保持可见**（它自己就是「卡牌虚影」）。
## ★★ 2026.11.16（用户口径）：「透明度需要再减小一些」——从 0.72 → 0.60 → 0.50 → 0.30。
const DRAG_CARD_ALPHA := 0.3
## ★★ 2026.11.14（用户口径）：「卡牌在静止到悬停态时需要有缓动效果」——
##   抬起 / 摆正原来是一帧到位，鼠标一扫过手牌每张牌都会瞬间跳一下。
##   现在走 0.14s 的 ease-out：起步快、收尾稳，抬起与落回同一档。
const HOVER_RAISE_SEC := 0.14
## 悬停时整张牌向上抬多少（设计像素）。
const HOVER_RAISE_PX := 20.0
## ★★ 2026.11.16（用户口径）：「卡牌在被悬停时应当放大」。
##   只放大**被悬停的那一张**；邻居保持 1.0，靠横向让开给放大留出空间。
const HOVER_SCALE := 1.5
var _drag_index: int = -1
var _drag_start_global := Vector2.ZERO
var _dragging_card: bool = false
## ★★ 2026.11.15：正在「被拒绝 → 飞回手牌」的那一格（-1 = 没有）。
##   返程期间**不允许悬停抬起**：两个 Tween 同时写 `position` / `position:y` 会让
##   按钮和卡面被不同的 Tween 拽到两个位置，看起来就是「重影 / 又一张相同的牌」。
var _returning_index: int = -1
## 返程结束后先压住这一格的悬停抬起，直到鼠标离开再进：否则牌刚落到槽位，
## 鼠标还停在上面，抬升 Tween 会立刻把它顶起来 —— 玩家看到的就是「又错位一下」。
var _hover_suppressed_index: int = -1
var _deck_tween: Tween = null
var _drag_tween: Tween = null
var _drag_fade_tween: Tween = null
## 建筑牌「生效后只把自己淡回槽位」的 Tween（不重排整手牌）。
var _restore_tween: Tween = null
## 生效牌「向上缩小淡出」的 Tween：必须能取消，否则回调开始后它还在写同一张牌的
## position / scale，会和淡回 / 重排抢出「两张牌」的错位。
var _success_tween: Tween = null
## 每格当前挂着的「悬停抬起」Tween（再次悬停 / 收手 / 换页时先杀掉，
## 否则两条 Tween 会抢同一个 `position:y`，表现是牌在原地抽搐）。
var _hover_tweens: Array = []
## ★★ 2026.11.16：当前被悬停的那一格（**条目下标**，不是扇形序号；-1 = 没有）。
##   其余牌按它与这一格的距离向左右散开（见 `_raise_card()`）。
var _hover_index: int = -1
## ★★ 2026.11.17（用户口径）：**某张牌被拖出时，其余手牌往屏幕下方沉 + 缩小**，
##   松手（取消 / 放回 / 生效）再反向浮回来。数值与换算见 `UiLayoutRes.CARD_TUCK_*`。
## ★ 为什么用一个 bool 而不是进度 float：下沉本身是一条 0.18s 的 Tween（每张牌各自一条，
##   和悬停抬起共用 `_hover_tweens` 槽位），这里只需要记「现在应该在下沉状态」——
##   `_layout_fan()` 重建手牌时用它决定摆原位还是摆下沉位，动画结束与否与它无关。
var _tucked: bool = false
## 每格**常驻**的那份 StyleBox（悬停时只改它的颜色，不换对象 —— 见 `_cell_style`）。
var _cell_styles: Array = []
## 每格的「常态底色 / 常态描边色」（插值起点）与「上一帧已经写进去的泛光进度」。
var _cell_bg0: Array = []
var _cell_border0: Array = []
var _cell_glow_applied: Array = []
## 拖拽中这张牌当前的「卡面可见度」目标（-1 = 还没有拖过；见 `_set_drag_face_alpha`）。
var _drag_face_alpha: float = -1.0

## ★★ 手机端：按住某一格期间由 hud 置 true —— 「按下」产生的模拟鼠标会让这一格**立刻**
##    收到 mouse_entered，那是「悬停」，而需求是「长按才悬停」⇒ 按住期间忽略鼠标进入。
##    `hover()`（长按到点之后由 hud 调）**不受**它影响，直接发信号。
var touch_suppress_hover: bool = false


## ★★ 格子里的**名字底条**高度（设计像素 @86.67 的格子）。名字就压在这条上。
## 0 / 1 的取舍：够高才装得下 11px 的字，又要尽量少盖图标 —— 15px 是实测折中。
const NAME_BAR_H := 22.0
## 有图标时名字那一行的字号（`ui_style.FS_TINY`：86.67px 的格子里一行放得下 7 个汉字）。
const NAME_ON_ICON_FS := 13


func setup() -> void:
	name = "CommandCard"
	mouse_filter = Control.MOUSE_FILTER_STOP
	# ★★ 2026.11.14（用户口径）：「手牌放至屏幕底部中央」——锚点从「贴右下」
	#   改成「贴底 + 水平居中」，所以走 `apply_bottom_center()`。
	#   ⚠️ 别改回 apply_rect(..., true, true)：那样窗口一拉宽，手牌会贴到右边去。
	UiLayoutRes.apply_bottom_center(self, UiLayoutRes.CARD_RECT)

	for i in UiLayoutRes.CARD_SLOTS:
		var face := Panel.new()
		face.name = "CardFace%d" % (i + 1)
		face.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var face_style := StyleBoxFlat.new()
		face_style.bg_color = UiStyleRes.bg()
		face_style.border_color = UiStyleRes.line()
		face_style.set_border_width_all(2)
		face_style.set_corner_radius_all(10)
		face_style.shadow_color = Color(0.0, 0.0, 0.0, 0.76)
		face_style.shadow_size = 7
		face_style.shadow_offset = Vector2(0.0, 6.0)
		face.add_theme_stylebox_override("panel", face_style)
		face.visible = false
		add_child(face)
		_card_faces.append(face)

		var cell := Button.new()
		cell.name = "CardSlot%d" % (i + 1)
		cell.focus_mode = Control.FOCUS_NONE
		# ★★ 2026.11.14：**不要**裁剪子节点 —— 投影现在由填充层（show_behind_parent 的子节点）
#   画在卡身下面（见 view/fill_button.gd 的 _ensure_shadow()），clip_contents = true
#   会把它裁在卡框里，于是卡看起来「没有投影」（用户报的科技卡那条）。
#   卡里的图标 / 名字条本来就都摆在框内，解除裁剪不会溢出。
		# ★★ 本版**不用** Godot 原生的 `tooltip_text` 了：说明改由「命令卡正上方的
		#    悬停详情面板」画（需求要的是那块面板）。两个一起挂会同时冒出两个提示框。
		#   ⚠️ `desc` 这个**数据字段**照旧留着（文案的出处是 config / 逻辑层），
		#      只是不再塞给 Button 的原生 tooltip —— 见 hud._hover_detail。
		_cell_style(i, cell, false)
		UiLayoutRes.apply_rect(cell, UiLayoutRes.card_cell_local(i))
		cell.pressed.connect(_on_cell_pressed.bind(i))
		cell.gui_input.connect(_on_cell_gui_input.bind(i))
		# ★ 悬停：Godot 的 Control 自带这两个信号（不需要自己算鼠标位置）。
		#   子 Label 全是 IGNORE，所以事件一定落在 Button 自己身上。
		#   ⚠️ 填充动效**也用这两个信号**（它自己连的，见 fill_button.setup_host）——
		#      两条路互不干扰：这里只报「第几格」给 hud 弹说明面板。
		cell.mouse_entered.connect(_on_cell_mouse_entered.bind(i))
		cell.mouse_exited.connect(_on_cell_mouse_exited.bind(i))
		# ★★ 悬停填充：一行挂上「自绘填充（画在底纹下面）+ 鼠标跟随 + 填满时把字压成暖黑」
		FillButtonRes.attach_text(cell)
		# ★★ 2026.11.14（用户口径）：「手牌不需要有悬停时的四个角显示了」——
		#   手牌的悬停反馈 = 抬起 + 描边渐变 + 填充，不再叠四角括号。
		FillButtonRes.set_reticle(cell, false)
		# ★★ 每格都带常驻灰底（空格子也不例外）：底纹是全透明的，
		#   灰底画在填充层里、金的上方；这样悬停时灰底不会消失（用户报的 bug）。
		FillButtonRes.set_base_bg(cell, UiStyleRes.bg())
		# ★★ 字色的**统一口径**（用户要求）：「3×3 里的文字都由下往上由白变黑，
		#   与金色填充线同步」。
		#   ⇒ 一律走「原色 + 跟着金色前沿翻面」那条路（`_sync_text()` 里唯一的规则）。
		#   ⚠️ `set_prefer_light` 这行是**历史遗留**（那个开关已经作废，见 fill_button）：
		#      当年它代表「填满时仍用白字」，而白字压金**读不出来** ——
		#      那正是用户报的「3×3 的字被金色填充遮挡」，别再把它当成有效开关。
		FillButtonRes.set_prefer_light(cell, true)
		# ★ 建出来先当「空槽」：不参与泛光 / 点击闪光，等 `set_entries()` 说有内容再打开。
		FillButtonRes.set_available(cell, false)
		add_child(cell)

		# ★★ 金线图标层：**铺满整格**、不吃鼠标。
		#    ★ 它**排在两个 Label / 底条之前**建（= 画在它们下面）—— 快捷键字母与
		#    名字那条底条必须压在图形之上。
		#    ★★ 图标**不考虑文字的位置**（用户口径）：它占满整格，名字改为叠在
		#    最下面那条**略黑的底条**上。以前「图标只占上面 74%」的做法有两个毛病：
		#    ① 蒙版是正方形，塞进扁矩形会被拉伸 ⇒ 图标看着**扁**；
		#    ② 只剩 64px 高，下采样比例更大 ⇒ 更**糊**。
		var cell_size: Vector2 = UiLayoutRes.card_cell_local(i).size
		var icon_view := UnitCardIconRes.IconView.new()
		icon_view.name = "CardIcon%d" % (i + 1)
		cell.add_child(icon_view)
		# ★ `bind(cell)` 铺满整格（图标自己按正方形居中，见 `IconView` / `mask_rect`）。
		icon_view.bind(cell)
		var glyph := Label.new()
		glyph.name = "CardGlyph%d" % (i + 1)
		glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
		glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		glyph.add_theme_font_size_override("font_size", 58)
		glyph.add_theme_color_override("font_color", UiStyleRes.accent_bright())
		glyph.visible = false
		cell.add_child(glyph)
		_glyph_labels.append(glyph)

		# 键位字母贴左上角（参考图就是这样：字母小、名字居中）
		var key_label := Label.new()
		key_label.text = String(UiLayoutRes.CARD_KEYS[i])
		key_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		key_label.add_theme_font_size_override("font_size", UiStyleRes.FS_TINY)
		key_label.add_theme_color_override("font_color", UiStyleRes.text_faint())
		key_label.position = Vector2(4.0, 1.0)
		cell.add_child(key_label)

		# ★★ 名字底条：叠在图标**最下面**的一条略黑横条。
		#    ★ 为什么需要它：图标现在铺满整格，名字直接压在线稿上读不清；
		#      垫一条半透明深色，既保住可读性，又不把图标切掉一块（用户口径：
		#      「图标不需要考虑文字的位置，文字用一个略黑的底条作为容器」）。
		#    ★ 它建在图标**之后**（= 画在图标之上）、名字 Label **之前**（名字再压它）。
		var name_bar := ColorRect.new()
		name_bar.name = "CardNameBar%d" % (i + 1)
		name_bar.color = UiStyleRes.name_bar()
		name_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_bar.position = Vector2(0.0, cell_size.y - NAME_BAR_H)
		name_bar.size = Vector2(cell_size.x, NAME_BAR_H)
		name_bar.visible = false
		cell.add_child(name_bar)

		var name_label := Label.new()
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_label.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)
		name_label.add_theme_color_override("font_color", UiStyleRes.text_faint())
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.clip_text = true
		name_label.size = cell_size
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(name_label)

		# ★★ 两条子 Label 也要**登记**到填充上：不登记的话填充满格时它们仍然是
		#    暖白 / 暗金（压在那片金上读不出来）。登记之后由填充按进度一起压成暖黑。
		FillButtonRes.on_fill_text(cell, key_label, UiStyleRes.text_faint())
		FillButtonRes.on_fill_text(cell, name_label, UiStyleRes.text_faint())

		# ★★ 招募数量角标：右下角的小牌子（只显示 ×N，不遮名字）。
		var count_label := Label.new()
		count_label.name = "CardCount%d" % (i + 1)
		count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		count_label.add_theme_font_size_override("font_size", UiStyleRes.FS_TINY)
		count_label.add_theme_color_override("font_color", UiStyleRes.accent())
		var cb := StyleBoxFlat.new()
		cb.bg_color = Color(0.047, 0.071, 0.102, 0.92)
		cb.border_color = UiStyleRes.accent()
		cb.set_border_width_all(1)
		cb.set_content_margin_all(1.0)
		count_label.add_theme_stylebox_override("normal", cb)
		count_label.size = Vector2(24.0, 16.0)
		count_label.position = Vector2(cell_size.x - 27.0, cell_size.y - 19.0)
		count_label.visible = false
		cell.add_child(count_label)

		# ★★ 教程用：某一类招募格的呼吸描边。边框很细、不吃鼠标，画在格子最上层。
		var glow := Panel.new()
		glow.name = "CardGlow%d" % (i + 1)
		glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var gsb := StyleBoxFlat.new()
		gsb.bg_color = Color(0, 0, 0, 0)
		gsb.border_color = UiStyleRes.accent()
		gsb.set_border_width_all(2)
		glow.add_theme_stylebox_override("panel", gsb)
		glow.visible = false
		cell.add_child(glow)
		_glow_panels.append(glow)

		# 方形波纹：从格子中心向外扩，透明度一路降到 0（参考右键目标的圆圈波纹）。
		var ripple := Panel.new()
		ripple.name = "CardGlowRipple%d" % (i + 1)
		ripple.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var rsb := StyleBoxFlat.new()
		rsb.bg_color = Color(0, 0, 0, 0)
		rsb.border_color = UiStyleRes.accent()
		rsb.set_border_width_all(2)
		ripple.add_theme_stylebox_override("panel", rsb)
		ripple.visible = false
		cell.add_child(ripple)
		_glow_ripples.append(ripple)

		# ★★ 2026.11.14（用户口径）：「拖出生效并回到手牌后，牌面会出现进度条提示其冷却」
		#   → 后来改口径：「进度条还是需要改为**填充**而不是一根条」。
		#   ⇒ 一张**暗纱**（Panel + 圆角 StyleBox）盖在牌面上：高度 = 剩余冷却比例，
		#     贴牌顶往下长；随冷却推进，纱的下沿一路往上退（牌面一点点露出来），
		#     下沿那条 2px 亮线就是「冷却前沿」。
		#   · 用 Panel 而不是 ColorRect：圆角跟着牌走，不会在牌角外顶出方角
		#     （卡片已经关掉 `clip_contents`，见那些格子创建处）；
		#   · 下沿用 StyleBox 的 `border_width_bottom` 画，不必再加一个节点；
		#   · 放最上层（最后 add_child）——它要盖住图标和名字。
		var veil := Panel.new()
		veil.name = "CdVeil%d" % (i + 1)
		veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var vsb := StyleBoxFlat.new()
		vsb.bg_color = Color(0.02, 0.03, 0.05, 0.55)
		# ★★ 2026.11.14（用户口径）：「冷却的进度条是底边的形状，不需要贴合底边，
		#   只需要是直线即可」——
		#   只给**上面两个角**圆角（贴住牌顶的圆角），下面两个角是 0 ⇒ 暗纱的下沿
		#   （冷却前沿）是一条**水平直线**，不再顺着牌底那条圆角拐弯。
		vsb.set_corner_radius_all(0)
		vsb.corner_radius_top_left = 9
		vsb.corner_radius_top_right = 9
		vsb.set_border_width_all(0)
		vsb.border_width_bottom = 2
		vsb.border_color = ThemeRes.with_alpha(UiStyleRes.accent(), 0.75)
		veil.add_theme_stylebox_override("panel", vsb)
		veil.visible = false
		cell.add_child(veil)

		_cells.append(cell)
		_key_labels.append(key_label)
		_name_labels.append(name_label)
		_name_bars.append(name_bar)
		_icon_views.append(icon_view)
		_count_labels.append(count_label)

	# 扇形牌不再使用九宫格外框；每张牌的双层描边与投影构成牌堆轮廓。
	var frame := Panel.new()
	frame.name = "CardFrame"
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	var frame_style := StyleBoxFlat.new()
	frame_style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	frame_style.set_border_width_all(0)
	frame.add_theme_stylebox_override("panel", frame_style)
	add_child(frame)

	set_entries([])


# ------------------------------------------------------------------
# 内容
# ------------------------------------------------------------------

## 换一整页内容（最多 9 条，顺序就是 Q/W/E/A/S/D/Z/X/C）
##
## ★★ 条目里的 `ready`（缺省 = true）是本版新增的**置灰**开关：条目在、说明也在，
##    但这一格现在点了没用（典型是濒死将领那颗「再起」——血量还没回到 10%）。
##    ⚠️ 为什么不干脆不画那一格：需求原话是「血量回复至 10% 及以上，则其操作栏中
##      会出现『再起』按钮」——**玩家要能看见它在等什么**（一次都不画的话，
##      玩家只会以为这个功能不存在）。所以画灰 + 悬停说明才是对的做法。
func set_entries(list: Array) -> void:
	# ★★ 2026.11.17：拖牌途中手牌被重建（典型：松手生效 → HUD 立刻刷新）时，
	#   必须**保住下沉状态** —— 否则 `_layout_fan()` 会把其余牌瞬间弹回原位，
	#   紧接着 `_finish_card_drag()` 的反向动画就没东西可动了（看起来是「突然跳上去」）。
	var was_dragging := _dragging_card
	if _deck_tween != null and _deck_tween.is_running():
		_deck_tween.kill()
	if _drag_tween != null and _drag_tween.is_running():
		_drag_tween.kill()
	if _drag_fade_tween != null and _drag_fade_tween.is_running():
		_drag_fade_tween.kill()
	if _restore_tween != null and _restore_tween.is_running():
		_restore_tween.kill()
	if _success_tween != null and _success_tween.is_running():
		_success_tween.kill()
	_drag_index = -1
	_dragging_card = false
	_returning_index = -1
	_hover_suppressed_index = -1
	_hover_index = -1
	_entries = []
	for i in list.size():
		if i >= UiLayoutRes.CARD_SLOTS:
			break
		var e: Variant = list[i]
		if typeof(e) == TYPE_DICTIONARY:
			_entries.append(e)

	for i in _cells.size():
		# ★★ 空字典 = **空格子**（单位页按行解锁后会留下空位，见 hud._recruit_entries）。
		#    它占着序号（Q/W/E/A/S/D/Z/X/C 的键位不挪），但不显示名字、点了不做事。
		var filled: bool = i < _entries.size() and not (_entries[i] as Dictionary).is_empty()
		var cell := _cells[i]
		# ★★ 2026.11.16 修 bug：手牌被重建（内容换了 / 拖出后生效）时，旧的悬停填充
		#   不会自己消失 —— 按钮被拖到地图上再摆回槽位，引擎不会补发 mouse_exited。
		#   这里显式清一遍悬停态；新内容照旧由下面的 set_available / latched 重新决定。
		FillButtonRes.clear_hover_in(cell)
		if filled:
			cell.visible = true
			cell.modulate.a = 1.0
			_card_faces[i].visible = true
			_card_faces[i].modulate.a = 1.0
			var e2: Dictionary = _entries[i]
			var ready: bool = bool(e2.get("ready", true))
			# ★★ 2026.11.14：换页时先把**冷却遮罩**收掉。
			#   命令卡这九颗按钮是**跨页复用**的：在操作页盖过的暗纱，切到建筑页
			#   会留在同一颗按钮上（用户报的「我的单位移动时，建筑牌也有进度条」）。
			#   这一句让「切页那一帧」就是干净的。
			_name_labels[i].text = String(e2.get("name", ""))
			if String(e2.get("type", "")) == "recruit_cancel_all":
				_key_labels[i].text = "ESC"
			elif _has_recruit_progress_entry():
				_key_labels[i].text = String(UiLayoutRes.CARD_KEYS[i - 1]) if i > 0 \
					else ""
			else:
				_key_labels[i].text = String(UiLayoutRes.CARD_KEYS[i])
			# ★★ 条目带 `icon_mask` / `icon_role` ⇒ 这一格画**图标**、把名字那行字藏起来
			#    （需求：「招募单位的按钮内的文字改为图标」）。
			#   `icon_mask` 是主路径（该兵种原画的剪影浮雕）；`icon_role` 是兜底
			#    （蒙版缺失 / 旧条目时退回矢量金线）。
			#   ⚠️ 名字**照旧写进 Label**（只是 `visible = false`）：`cell_label()` 是
			#     测试与排查用的**语义出口**，隐藏文字不该把它一起弄没。
			var role := String(e2.get("icon_role", ""))
			var mask := String(e2.get("icon_mask", ""))
			_set_icon(i, role, mask, ready)
			if i < _glyph_labels.size():
				var glyph := _glyph_labels[i]
				glyph.text = String(e2.get("icon_glyph", ""))
				glyph.visible = glyph.text != "" and role == "" and mask == ""
				glyph.add_theme_font_size_override("font_size",
					int(clampf(cell.size.x * 0.42, 34.0, 58.0)))
			# ★★ 招募批次进度 / 同种数量角标（整条队列共享一个读条，见 world._tick_recruitment）。
			if i < _icon_views.size() and _icon_views[i] != null:
				_icon_views[i].set_progress(float(e2.get("queue_progress", 0.0)))
			if i < _count_labels.size() and _count_labels[i] != null:
				var qc := int(e2.get("queue_count", 0))
				_count_labels[i].text = "×%d" % qc if qc > 1 else ""
				_count_labels[i].visible = qc > 1
			# ★★ 有图标时：名字**照样显示**，只是压到格子最下面那一行（需求：
			#    「图标 + 一行名字，描述全进悬停面板」——单位和建筑都要这样）。
			#    没有图标时（操作页那种）名字照旧居中、用大一号的字。
			#   ⚠️ 名字**永远写进 Label**：`cell_label()` 是测试与排查的语义出口。
			var has_icon: bool = role != "" or mask != "" \
				or String(e2.get("icon_glyph", "")) != ""
			_name_labels[i].visible = true
			_apply_name_layout(i, has_icon)
			# ★ 置灰那一档的**文字也一起变暗**：只把按钮禁掉而名字照旧是亮白的话，
			#   看起来仍然像「能点」（实测里这类「看着能点、点了没反应」最难自查）。
			# ⚠️ 走 `set_base_font_color` / `on_fill_text` 而**不是**直接写
			#    `add_theme_color_override("font_color", …)`：填充动效每帧都会按
			#    「原色 + 当前填充进度」重算这四条字的颜色，直接写 override 会被下一帧盖掉。
			# ★★ 字色口径（用户要求）：「页签内的 3×3 按钮中的文字要改成白色，
			#   和科技页的一样」。所以这里**名字与键位字母统一用暖白**
			#   （`UiStyleRes.text()`）—— 原来键位字母是暗金、名字是暖白，两套色看着不齐。
			#   ★ 科技页那九格的「名字」那一条也是暖白，这里对齐的就是那一档。
			FillButtonRes.set_base_font_color(cell,
				UiStyleRes.text() if ready else UiStyleRes.text_faint())
			# ★★ 名字那条**单独再登记一次**（否则它会停在建出来时的灰色上）。
			#
			# 为什么非要多这一句：这条 Label 是在建按钮时用**灰**（`text_faint`）建出来的，
			#   而填充层在 `attach_text()` 那一刻就把「当下的颜色」当成了这条字的**原色**
			#   （见 fill_button 的 `_current_font_color`）。之后调用点把它改成暖白时，
			#   填充层那边「登记的原色」可能已经等于暖白 ⇒ 走 `on_fill_text` 的
			#   「原色没变」那条近路 ⇒ **一次都没写进 Label**，屏幕上一直是灰的
			#   （用户报的「3×3 里的字是灰的」）。这里显式再登记一次，把渲染色压实。
			FillButtonRes.on_fill_text(cell, _name_labels[i],
				UiStyleRes.text() if ready else UiStyleRes.text_faint())
			FillButtonRes.on_fill_text(cell, _key_labels[i],
				UiStyleRes.text() if ready else UiStyleRes.text_faint())
			_cell_style(i, cell, ready)
			cell.disabled = not ready
			# ★ 有内容 ⇒ 参与动效（从空槽变成有内容的那一帧要把它重新打开）。
			FillButtonRes.set_available(cell, true)
			# ★★ 2026.11.15：建筑格不再有「选中」状态（点选建造已删除，只剩拖牌），
			#   所以 `active` 恒为 false（保留这一个读取：其它页将来也可能用它）。
			#   ★★★ 单位页的招募格不要「点击一闪」（用户口径：局内的单位按钮
			#     「点击后不需要金色填充闪过」）—— 它排进队列，右侧队列 / 红字就是反馈。
			#   其它页（操作 / 招募将领）的格子照旧闪。
			FillButtonRes.set_latched(cell, bool(e2.get("active", false)))
			FillButtonRes.set_click_flash(cell, false)
			# ★★ 置灰的格子**照旧有悬停反馈**，只是填的是**灰**（见 view/fill_button.gd）：
			#   填充层自己看 `disabled` 换档，所以这里**不要**再 `set_available(false)`
			#   —— 那会把动效整个关掉，鼠标停上去一点反应都没有（与需求的「灰色填充」相反）。
		else:
			cell.visible = false
			_card_faces[i].visible = false
			_name_labels[i].text = ""
			_name_labels[i].visible = true
			_set_icon(i, "", "")
			if i < _icon_views.size() and _icon_views[i] != null:
				_icon_views[i].set_progress(0.0)
			if i < _count_labels.size() and _count_labels[i] != null:
				_count_labels[i].text = ""
				_count_labels[i].visible = false
			_apply_name_layout(i, false)
			FillButtonRes.set_base_font_color(cell, UiStyleRes.text_faint())
			FillButtonRes.on_fill_text(cell, _key_labels[i], UiStyleRes.text_faint())
			_cell_style(i, cell, false)
			cell.disabled = false
			# ★★ 2026.11.5：**空格子不参与任何动效**（与科技格同一条口径）——
			#   它没有内容、点了也不做事（`activate_index` 直接 false），
			#   泛光 / 点击闪光都会让它看起来像个「能按的按钮」。
			FillButtonRes.set_latched(cell, false)
			FillButtonRes.set_click_flash(cell, true)
			FillButtonRes.set_available(cell, false)
			if i < _glyph_labels.size():
				_glyph_labels[i].text = ""
				_glyph_labels[i].visible = false
	# ★★ 2026.11.17：只有「拖牌途中被重建」才保住下沉状态（松手那条路紧接着会反向播回来）；
	#   其余情况（换页 / 选别的东西）一律回到原位，免得上一次拖牌的下沉状态漏到这里。
	_tucked = was_dragging
	_layout_fan()
	# ★★ 2026.11.17 保险：拖牌途中被重建（切页 / 选中变了 / 签名变了）时，`_finish_card_drag()`
	#   可能永远不来 —— 不兜这一下，手牌会永远缩在下面。下一帧查一次（见 `_tuck_fallback`）。
	if was_dragging:
		call_deferred("_tuck_fallback")


## 仅把当前页有内容的格子摆成扇形；未用的槽位不显示、不参与鼠标命中。
func _layout_fan() -> void:
	# ★ 重新摆牌 = 直接写 `position` / `rotation` ⇒ 先把悬停 Tween 撤掉，
	#   否则它会在接下来几十毫秒里把牌又拽回旧姿势（换页瞬间的「牌在抽」就是这么来的）。
	_kill_hover_tweens()
	_hover_index = -1
	var visible_indices: Array[int] = []
	for i in _cells.size():
		if i < _entries.size() and not (_entries[i] as Dictionary).is_empty():
			visible_indices.append(i)
	var count := visible_indices.size()
	# ★★ 2026.11.17：重建手牌时如果正处在「拖牌 → 其余牌下沉」的状态（`_tucked`），
	#   直接摆成**下沉位**，否则这一帧会把牌弹回原位、下一帧再沉下去（看得见的抽动）。
	var tuck := 1.0 if _tucked else 0.0
	var tuck_scale := UiLayoutRes.card_tuck_scale(tuck)
	var tuck_sv := Vector2(tuck_scale, tuck_scale)
	for ordinal in count:
		var i := visible_indices[ordinal]
		var cell := _cells[i]
		var r := UiLayoutRes.card_fan_local(ordinal, count)
		var pose: Vector2 = r.position + UiLayoutRes.card_tuck_offset(r.size, tuck)
		var face := _card_faces[i]
		face.position = pose
		face.size = r.size
		face.rotation = UiLayoutRes.card_fan_rotation(ordinal, count)
		face.scale = tuck_sv
		face.z_index = ordinal * 2
		cell.position = pose
		cell.size = r.size
		cell.rotation = UiLayoutRes.card_fan_rotation(ordinal, count)
		cell.scale = tuck_sv
		cell.z_index = ordinal * 2 + 1
		if i < _name_bars.size():
			_name_bars[i].position = Vector2(0.0, r.size.y - NAME_BAR_H)
			_name_bars[i].size = Vector2(r.size.x, NAME_BAR_H)
		if i < _key_labels.size():
			_key_labels[i].position = Vector2(8.0, 6.0)
		if i < _count_labels.size():
			_count_labels[i].position = Vector2(r.size.x - 30.0, 8.0)
		_apply_name_layout(i,
			String((_entries[i] as Dictionary).get("icon_role", "")) != "" \
			or String((_entries[i] as Dictionary).get("icon_mask", "")) != "" \
			or String((_entries[i] as Dictionary).get("icon_glyph", "")) != "")
		if i < _glyph_labels.size():
			var glyph := _glyph_labels[i]
			glyph.position = Vector2(6.0, 22.0)
			glyph.size = Vector2(maxf(0.0, r.size.x - 12.0), maxf(0.0, r.size.y - NAME_BAR_H - 25.0))


## ★★ 2026.11.17（用户口径）：拖牌开始 / 结束时，把**其余手牌**沉下去 / 浮回来。
##
## @param on        true = 下沉，false = 浮回原位
## @param except    正在被拖（或刚松手、正由返程 / 生效动画接管）的那一张：跳过它
## @param animate   false = 直接到位（重建手牌 / 无动画模式）
##
## ★ 为什么不连被拖的那张一起沉：它跟着指针走，`_update_drag_position()` 每帧都在写它的位置。
## ★ 下沉用 `_ease_card_pose(..., allow_while_dragging = true)`：这条动画**必须**在拖拽期间播
##   （否则 `_ease_card_pose` 会退化成「直接到位」）。
func _set_deck_tucked(on: bool, except_index: int, animate: bool = true) -> void:
	_tucked = on
	var visible_indices := _visible_entry_indices()
	var count := visible_indices.size()
	if count <= 0:
		return
	var tuck := 1.0 if on else 0.0
	var tuck_scale := UiLayoutRes.card_tuck_scale(tuck)
	for ordinal in count:
		var i := visible_indices[ordinal]
		if i == except_index:
			continue
		var base := UiLayoutRes.card_fan_local(ordinal, count)
		var pose: Vector2 = base.position + UiLayoutRes.card_tuck_offset(base.size, tuck)
		_ease_card_pose(i, pose, UiLayoutRes.card_fan_rotation(ordinal, count),
			tuck_scale, true, UiLayoutRes.CARD_TUCK_SEC if animate else 0.0)


## ★★ 2026.11.17 兜底：拖牌途中手牌被重建时，`_finish_card_drag()` 可能永远不来。
##   `set_entries()` 用 `call_deferred` 叫一次这里 —— 只有「还沉着的且已经不在拖」才浮回；
##   正常松手那条路已经先把它放平了（`_tucked == false`）⇒ 这里是空操作。
func _tuck_fallback() -> void:
	if _dragging_card or not _tucked:
		return
	_set_deck_tucked(false, -1, true)


func _raise_card(i: int, raised: bool) -> void:
	if i < 0 or i >= _cells.size() or not _cells[i].visible:
		return
	# 返程中 / 刚落到槽位：不要起悬停抬起（返程 Tween 或「刚回来」的视觉会被打断）。
	if _returning_index == i:
		return
	if raised and _hover_suppressed_index == i:
		return
	# ★★ 2026.11.16：记下「现在是谁被悬停」——其余牌的散开量都要按它来算。
	if raised:
		_hover_index = i
	elif _hover_index == i:
		_hover_index = -1
	# 可见牌按扇形序号排好：散开量由「离悬停牌多远」决定，序号是唯一可靠的依据。
	var visible_indices := _visible_entry_indices()
	var count := visible_indices.size()
	if count <= 0:
		return
	var hover_ordinal := visible_indices.find(_hover_index)
	for ordinal in count:
		var j := visible_indices[ordinal]
		var base := UiLayoutRes.card_fan_local(ordinal, count)
		var target_pos := base.position
		var target_rot := UiLayoutRes.card_fan_rotation(ordinal, count)
		var target_scale := 1.0
		if j == _hover_index:
			# 悬停的那张：抬起 + 摆正 + 放大 + 压在最上层。
			target_pos.y -= HOVER_RAISE_PX
			# 不设 pivot（扇形一直绕左上角转，改 pivot 会连带改所有牌的旋转观感）——
			# 用位置补偿把放大做在**几何中心**：视觉上四周均匀变大，牌心不动。
			target_pos -= _cells[j].size * 0.5 * (HOVER_SCALE - 1.0)
			target_scale = HOVER_SCALE
			target_rot = 0.0
			_cells[j].z_index = UiLayoutRes.CARD_SLOTS * 2 + 2
			_card_faces[j].z_index = UiLayoutRes.CARD_SLOTS * 2 + 1
		else:
			# ★ 同侧所有牌统一让开同一段距离（见 `UiLayoutRes.card_hover_push`）：
			#   换到相邻牌时，同侧牌的距离不变 ⇒ 它们不会跟着动。
			if hover_ordinal >= 0:
				target_pos.x += UiLayoutRes.card_hover_push(ordinal, hover_ordinal)
			_cells[j].z_index = ordinal * 2 + 1
			_card_faces[j].z_index = ordinal * 2
		_ease_card_pose(j, target_pos, target_rot, target_scale)


## 当前页**有内容且可见**的格子下标，按扇形序号排列（散开 / 抬起 / 落回共用）。
func _visible_entry_indices() -> Array[int]:
	var out: Array[int] = []
	for j in _cells.size():
		if j < _entries.size() and not (_entries[j] as Dictionary).is_empty() \
				and _cells[j].visible:
			out.append(j)
	return out


## 把「已经散开的其余牌」收回扇形原位（跳过 `except_index`）。
##
## ★★ 2026.11.16：为什么必须有这一条 —— 拖牌时 `_hover_index` 被清掉、悬停 Tween 也被杀，
##   但**已经让开的邻居**不会自己回来（原先只抬一张牌时没有这个问题）。不收回的话，
##   玩家拖完一张牌松手，手牌会永久停在「中间空一格」的散开姿势上。
##   · 拖动确认那一帧（`_dragging_card == true`）⇒ 直接写回原位，不和拖拽 Tween 抢；
##   · 其它时刻（返程 / 打完一张）⇒ 走 0.14s 的缓动，与悬停落回同一条手感。
func _settle_spread(except_index: int) -> void:
	var visible_indices := _visible_entry_indices()
	var count := visible_indices.size()
	# ★★ 2026.11.17：这里的「原位」要把**下沉状态**算进去 —— 拖牌期间其余牌是沉着的，
	#   直接摆回未下沉的扇位会把它们整排弹起来（下沉动画白做）。
	var tuck := 1.0 if _tucked else 0.0
	var tuck_scale := UiLayoutRes.card_tuck_scale(tuck)
	for ordinal in count:
		var j := visible_indices[ordinal]
		if j == except_index:
			continue
		var base := UiLayoutRes.card_fan_local(ordinal, count)
		var rot := UiLayoutRes.card_fan_rotation(ordinal, count)
		var pose: Vector2 = base.position + UiLayoutRes.card_tuck_offset(base.size, tuck)
		_cells[j].z_index = ordinal * 2 + 1
		_card_faces[j].z_index = ordinal * 2
		# 已经在原位：不再起 Tween（否则会平白多出一段 0.14s 的动画，
		# 「建筑牌生效后不重排其他牌」那条断言会把它算成「动了」）。
		if _cells[j].position.distance_to(pose) < 0.5 \
				and absf(angle_difference(_cells[j].rotation, rot)) < 0.001 \
				and _cells[j].scale.distance_to(Vector2(tuck_scale, tuck_scale)) < 0.001:
			continue
		# ★ 允许在拖牌期间播这段缓动：拖拽 Tween 只写**被拖的那一张**，
		#   邻居的 position 不会和它抢；反而直接硬切会看出「牌堆突然弹一下」。
		_ease_card_pose(j, pose, rot, tuck_scale, true)


## 把第 i 张牌缓动到「抬起 / 落回」的姿势（`_raise_card` 的唯一落地点）。
##
## ★ 为什么用 Tween 而不是每帧 `move_toward`：拖动 / 换页 / 入场那几条路已经在用
##   Tween 写同样的属性（`position` / `rotation`），
##   两条 Tween 会互相覆盖 —— 所以这里**先杀掉自己上一条**，并且只在
##   「没在拖牌 / 没在播牌组动画」时才写。
## ★ `animations_enabled() == false`（无头测试 / 玩家关动效）时**直接到位**：
##   既有断言依赖「调完 `_raise_card` 之后牌就在目标位置」。
## ★ `sec` = 这一段的时长（默认悬停那档 0.14s；「下沉 / 浮回」传 `CARD_TUCK_SEC`）。
func _ease_card_pose(i: int, target_pos: Vector2, target_rot: float,
		target_scale: float = 1.0, allow_while_dragging: bool = false,
		sec: float = HOVER_RAISE_SEC) -> void:
	while _hover_tweens.size() <= i:
		_hover_tweens.append(null)
	var old = _hover_tweens[i]
	if old != null and is_instance_valid(old) and (old as Tween).is_running():
		(old as Tween).kill()
	_hover_tweens[i] = null
	var cell := _cells[i]
	var face := _card_faces[i]
	var target_sv := Vector2(target_scale, target_scale)
	# 已经到位：不起 Tween（换到相邻牌时，同侧的牌目标位置不变，理应一动不动）。
	if cell.position.distance_to(target_pos) < 0.25 \
			and absf(angle_difference(cell.rotation, target_rot)) < 0.001 \
			and cell.scale.distance_to(target_sv) < 0.001:
		cell.position = target_pos
		cell.rotation = target_rot
		cell.scale = target_sv
		face.position = target_pos
		face.rotation = target_rot
		face.scale = target_sv
		return
	if (_dragging_card and not allow_while_dragging) \
			or not ThemeRes.animations_enabled() or sec <= 0.0:
		cell.position = target_pos
		cell.rotation = target_rot
		cell.scale = target_sv
		face.position = target_pos
		face.rotation = target_rot
		face.scale = target_sv
		return
	var tw := create_tween().set_parallel(true)
	tw.tween_property(cell, "position", target_pos, sec) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(cell, "rotation", target_rot, sec) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(cell, "scale", target_sv, sec) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(face, "position", target_pos, sec) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(face, "rotation", target_rot, sec) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(face, "scale", target_sv, sec) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_hover_tweens[i] = tw


## 杀掉所有「悬停抬起」Tween。换页 / 重新摆牌 / 开始拖牌之前必须调 ——
## 那几条路会直接写 `position` / `rotation`，留着 Tween 就会被它拽回去。
func _kill_hover_tweens() -> void:
	for tw in _hover_tweens:
		if tw != null and is_instance_valid(tw) and (tw as Tween).is_running():
			(tw as Tween).kill()
	_hover_tweens.clear()


## 切换页签后对新手牌做一次短促的「从牌手里抽出」入场。
func animate_deck_in() -> void:
	# ★ 入场动画自己写 `position` / `rotation` ⇒ 先把悬停 Tween 撤掉。
	_kill_hover_tweens()
	if _deck_tween != null and _deck_tween.is_running():
		_deck_tween.kill()
	# ★★ 2026.11.15：整手牌重排时把「返程 / 单张淡回」的 Tween 一起掐掉 ——
	#   否则它们会和入场 Tween 同时写同一张牌的 position，表现就是牌重叠 / 乱飞。
	if _drag_tween != null and _drag_tween.is_running():
		_drag_tween.kill()
	if _restore_tween != null and _restore_tween.is_running():
		_restore_tween.kill()
	if _success_tween != null and _success_tween.is_running():
		_success_tween.kill()
	_returning_index = -1
	_hover_suppressed_index = -1
	_hover_index = -1
	# ★★ 2026.11.17：入场是「整手牌从下面抽出来」⇒ 下沉状态一并清掉，
	#   否则入场动画的终点会落在下沉位（换页回来后牌一直是缩着的）。
	_tucked = false
	var visible_indices: Array[int] = []
	for i in _cells.size():
		if _cells[i].visible:
			visible_indices.append(i)
	var count := visible_indices.size()
	if count <= 0 or not is_visible_in_tree():
		return
	for ordinal in count:
		var i := visible_indices[ordinal]
		var target := UiLayoutRes.card_fan_local(ordinal, count)
		var target_rotation := UiLayoutRes.card_fan_rotation(ordinal, count)
		_cells[i].z_index = ordinal * 2 + 1
		_card_faces[i].z_index = ordinal * 2
		_cells[i].modulate.a = 0.0
		_cells[i].scale = Vector2.ONE
		_cells[i].position = target.position + Vector2(0.0, 40.0)
		_cells[i].rotation = target_rotation * 1.5
		_card_faces[i].modulate.a = 0.0
		_card_faces[i].scale = Vector2.ONE
		_card_faces[i].position = _cells[i].position
		_card_faces[i].rotation = _cells[i].rotation
	_deck_tween = create_tween()
	_deck_tween.set_parallel(true)
	for ordinal in count:
		var i := visible_indices[ordinal]
		var target := UiLayoutRes.card_fan_local(ordinal, count)
		var delay := float(ordinal) * 0.025
		_deck_tween.tween_property(_cells[i], "position", target.position, 0.22) \
			.set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_deck_tween.tween_property(_cells[i], "rotation",
			UiLayoutRes.card_fan_rotation(ordinal, count), 0.22) \
			.set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_deck_tween.tween_property(_cells[i], "modulate:a", 1.0, 0.16).set_delay(delay)
		_deck_tween.tween_property(_card_faces[i], "position", target.position, 0.22) \
			.set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_deck_tween.tween_property(_card_faces[i], "rotation",
			UiLayoutRes.card_fan_rotation(ordinal, count), 0.22) \
			.set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_deck_tween.tween_property(_card_faces[i], "modulate:a", 1.0, 0.16).set_delay(delay)


func _on_cell_gui_input(event: InputEvent, i: int) -> void:
	if OS.has_feature("mobile") or touch_suppress_hover:
		return # 触屏由 HUD 的长按 / 拖牌路径处理，不抢模拟鼠标事件。
	# ★★ 2026.11.14（用户报的「操作牌冷却没有生效」）：
	#   `cell.disabled = true` 只挡得住 `pressed`，**挡不住 `gui_input`** ——
	#   Control 是先发 `gui_input` 信号再走 `_gui_input` 虚函数，所以置灰的牌
	#   照样能被拖起来、照样能下达命令。冷却/置灰必须在**拖拽这条路**上自己判一次。
	if not _card_ready(i):
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			_drag_index = i
			_drag_start_global = get_viewport().get_mouse_position()
			_dragging_card = false
		elif _drag_index == i:
			_finish_card_drag(i, get_viewport().get_mouse_position())
		return
	if event is InputEventMouseMotion and _drag_index == i:
		var mm := event as InputEventMouseMotion
		if (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
			return
		_update_drag_position(i, get_viewport().get_mouse_position())
		if _dragging_card:
			accept_event()


func _update_drag_position(i: int, viewport_pos: Vector2) -> void:
	if i < 0 or i >= _cells.size():
		return
	var delta := viewport_pos - _drag_start_global
	if not _dragging_card and delta.y <= -DRAG_LIFT_THRESHOLD:
		# ★★ 置灰的牌（操作牌冷却中 / 建筑没解锁）**拖不起来**。
		#   见 `_on_cell_gui_input` 那段说明：`disabled` 挡不住 gui_input 这条路。
		if not _card_ready(i):
			_drag_index = -1
			return
		_dragging_card = true
		# ★ 拖牌接管这张牌的位置：悬停 Tween 必须先撤，否则它和 `card_drag_moved` 抢。
		_kill_hover_tweens()
		# ★★ 2026.11.15：如果这张牌还在「被拒绝后飞回手牌」的返程 Tween 里，
		#   也要先掐掉 —— 否则返程会继续把牌往旧槽位拽，和新的拖拽叠成重影 / 错位。
		if _drag_tween != null and _drag_tween.is_running():
			_drag_tween.kill()
		if _restore_tween != null and _restore_tween.is_running():
			_restore_tween.kill()
		if _success_tween != null and _success_tween.is_running():
			_success_tween.kill()
		_returning_index = -1
		_hover_suppressed_index = -1
		# ★★ 2026.11.16：只有**刚才真的处于悬停散开**时才把邻居收回原位。
		#   （别在普通拖拽时动机邻居：那张牌可能正处在「生效 / 返程」动画里，
		#    把它拽回扇位会破坏那条动画的起点。）
		if _hover_index >= 0:
			_settle_spread(i)
		_hover_index = -1
		# ★★ 2026.11.17（用户口径）：拖起来的那一刻，**其余手牌往屏幕下方沉 + 缩小**。
		#   松手时在 `_finish_card_drag()` 里反向播回来。
		_set_deck_tucked(true, i, true)
		# 被悬停的牌是放大态；拖起来必须回到 1.0，否则整张牌会拖着放大版走。
		_cells[i].scale = Vector2.ONE
		_card_faces[i].scale = Vector2.ONE
		_drag_face_alpha = -1.0
		if _deck_tween != null and _deck_tween.is_running():
			_deck_tween.kill()
		_cells[i].z_index = UiLayoutRes.CARD_SLOTS * 2 + 4
		_card_faces[i].z_index = UiLayoutRes.CARD_SLOTS * 2 + 3
		if _fades_when_over_map(String(entry_at(i).get("type", ""))):
			# 拖到地图上只淡一点（0.30），它自己就是「卡牌虚影」；
			# ★★ 2026.11.14（用户口径）：「当卡牌没有被打出并被玩家拖回手牌时，
			#   应当再逐渐显示其卡面」—— 淡出只是「离开手牌」时的事，拖回手牌范围
			#   就要淡回来（见下面 `_set_drag_face_alpha()`），否则玩家拖回来时
			#   手上什么都没有，像牌被吞了。
			if _drag_fade_tween != null and _drag_fade_tween.is_running():
				_drag_fade_tween.kill()
			_cells[i].modulate.a = 1.0
			_card_faces[i].modulate.a = 1.0
			_set_drag_face_alpha(i, false)
		card_drag_started.emit(entry_at(i), viewport_pos)
	if not _dragging_card:
		return
	var local: Vector2 = get_global_transform_with_canvas().affine_inverse() * viewport_pos
	_cells[i].rotation = 0.0
	var hold: Vector2 = _cells[i].size * 0.5
	_cells[i].position = local - hold
	_card_faces[i].rotation = 0.0
	_card_faces[i].position = _cells[i].position
	# ★ 拖回手牌范围 ⇒ 卡面逐渐显示出来（拖到地图上停在 0.30）
	#   ★★ 2026.11.15：将领牌也走同一条 —— 否则整张牌会盖住区划中心那一圈。
	if _fades_when_over_map(String(entry_at(i).get("type", ""))):
		_set_drag_face_alpha(i, true)
	card_drag_moved.emit(entry_at(i), viewport_pos)


## ★★ 2026.11.15（用户口径）：**所有牌拖出后都走同一套透明度** ——
##   在手里 1.0，拖到地图上 0.30（半透明卡牌虚影），拖回手里再回 1.0。
##   不再有「某些牌淡到 0 消失」的分支。
func _fades_when_over_map(_type: String) -> bool:
	return true


## 建筑牌在拖拽中的「卡面可见度」：**手牌范围内可见、拖到地图上淡到 0.30**。
##
## ★★ 2026.11.14（用户口径）：「当卡牌没有被打出并被玩家拖回手牌时，应当再逐渐显示其卡面」。
##   旧版只有「拖起来那一下淡到 0」这一条单向的 —— 玩家把牌拖回手牌时，手上是空的，
##   卡面要等到松手后的 `_animate_card_back()` 才回来（中间那几秒像牌被吞了）。
##   现在改成按「牌中心在不在手牌区」双向驱：回到手牌就 0.12s 淡回来。
##
## ★ 判据在**本控件的本地坐标**里：`_cells[i].position` 是相对 `command_card`
##   （它自己就摆在 `CARD_RECT` 那个位置上），所以「手牌区」= `(0,0)..CARD_RECT.size`
##   再向外放宽 `DRAG_FACE_SLACK`。⚠️ 别再拿 `CARD_RECT` 直接 `has_point()`——
##   那是**屏幕**坐标，和本地坐标差着整个手牌的位置（实测：怎么拖都判成「不在手牌」）。
func _set_drag_face_alpha(i: int, follow_pointer: bool) -> void:
	if i < 0 or i >= _cells.size():
		return
	var target := 1.0
	if follow_pointer:
		var rect := Rect2(Vector2.ZERO, UiLayoutRes.CARD_RECT.size).grow(DRAG_FACE_SLACK)
		var center: Vector2 = _cells[i].position + _cells[i].size * 0.5
		if rect.has_point(center):
			target = 1.0
		else:
			# ★ 所有牌统一：拖到地图上都是半透明卡牌虚影，不再淡到 0 消失。
			target = DRAG_CARD_ALPHA
	if _drag_face_alpha >= 0.0 and absf(_drag_face_alpha - target) < 0.001:
		return
	_drag_face_alpha = target
	if _drag_fade_tween != null and _drag_fade_tween.is_running():
		_drag_fade_tween.kill()
	_drag_fade_tween = create_tween().set_parallel(true)
	_drag_fade_tween.tween_property(_cells[i], "modulate:a", target, DRAG_FACE_FADE_SEC)
	_drag_fade_tween.tween_property(_card_faces[i], "modulate:a", target, DRAG_FACE_FADE_SEC)


func _finish_card_drag(i: int, viewport_pos: Vector2 = Vector2.ZERO) -> void:
	var was_drag := _dragging_card
	if _dragging_card:
		# ★ 鼠标牌只能由向上拖起并松手触发；普通点按不激活。
		card_drag_finished.emit(entry_at(i), viewport_pos, i)
		cell_unhovered.emit(i)
		# ★★ 2026.11.16 修 bug：松手后按钮不再收 mouse_exited，清掉拖拽期间残留的悬停填充。
		if i >= 0 and i < _cells.size():
			FillButtonRes.clear_hover_in(_cells[i])
			# ★★ 2026.11.17 修 bug：拖牌松手时必须把**缩放**也复位。
			#   建筑牌拖到同种建筑上升级时，HUD 会在同一条调用栈里刷新手牌；
			#   如果后续动画被 `set_entries()` 提前掐掉，残留的悬停 1.5 倍会被留在牌上。
			#   这里统一回到 1.0，成功 / 返程两条动画都从正确尺寸开始。
			_cells[i].scale = Vector2.ONE
			_card_faces[i].scale = Vector2.ONE
	_drag_index = -1
	_dragging_card = false
	_drag_face_alpha = -1.0
	# ★★ 2026.11.17（用户口径）：松手即反向 —— 取消 / 放回 / 生效三种结局都把
	#   其余手牌浮回原位（生效那张牌自己的「向上飘 + 淡出 / 飞回槽位」由 HUD 接着播）。
	#   ⚠️ 必须放在 `card_drag_finished` 之后：HUD 那边可能重建手牌（`set_entries`），
	#   重建时 `_tucked` 靠 `was_dragging` 保住，这里才开始浮回。
	if was_drag:
		_set_deck_tucked(false, i, true)


## HUD 的触屏路径调用：触摸按下只登记一个拖牌候选；短点不打出手牌。
func begin_touch_drag(i: int, viewport_pos: Vector2) -> void:
	_drag_index = i
	_drag_start_global = viewport_pos
	_dragging_card = false


## HUD 的触屏拖动路径；只有向上越过阈值才抬牌。@return 当前是否已进入拖拽。
func move_touch_drag(i: int, viewport_pos: Vector2) -> bool:
	if i != _drag_index:
		return false
	_update_drag_position(i, viewport_pos)
	return _dragging_card


## HUD 在触摸释放时调用；只有已经上拖的牌才发出 drag-finished 动作。
##
## ★★ 2026.11.14：`pos` 是**松手的位置**（触摸那条路必须传进来）。
##   旧版固定取 `get_viewport().get_mouse_position()` —— 触屏时那是上一次鼠标的位置，
##   于是「操作牌拖出松手 → 落点即操作点」会打在屏幕上的一个莫名其妙的地方。
##   不传（`Vector2.INF`）= 仍然按鼠标走（桌面 / 旧调用点）。
func finish_touch_drag(i: int, pos: Vector2 = Vector2.INF) -> void:
	var at: Vector2 = pos
	if not at.is_finite() or at == Vector2.INF:
		at = get_viewport().get_mouse_position() if get_viewport() != null else Vector2.ZERO
	_finish_card_drag(i, at)


## 当前 `_entries` 下，第 i 张牌在扇形里的位置 / 旋转 / 序号。
## 空字典（保留键位的空槽）不参与摊开 —— 与 `_layout_fan()` 同一条判据。
func _fan_slot_of(i: int) -> Dictionary:
	var ordinal := 0
	var count := 0
	for j in _entries.size():
		if not (_entries[j] as Dictionary).is_empty():
			count += 1
			if j < i:
				ordinal += 1
	if count <= 0:
		return {}
	return {
		"rect": UiLayoutRes.card_fan_local(ordinal, count),
		"rot": UiLayoutRes.card_fan_rotation(ordinal, count),
		"ordinal": ordinal,
	}


## 被拒绝 / 取消的牌飞回手牌。
##
## ★★ 2026.11.15 修 bug（用户报「回到手牌后错位 / 重影 / 又出现一张相同的牌」）：
##   · 返程用 CUBIC（BACK 会先冲过槽位再弹回来，看起来像回到手上又移了一下）；
##   · 末帧按**当前** `_entries` 重算槽位并硬对齐 —— 返程 0.2s 内手牌可能重排
##     （另一张牌生效 / 队列变化 / HUD 刷新），按旧序号落位会和别的牌重叠；
##   · 返程期间 `_returning_index` 会挡住悬停抬起；再抓起同一张牌时直接 kill 返程 Tween。
##   ★ 这里**不会创建任何新卡**：九格按钮与卡面从开局起就固定存在，只改可见性 / 变换。
func _animate_card_back(i: int) -> void:
	# ★★ 2026.11.15：目标不能只算一次 —— 返程 0.2s 里手牌可能因为「另一张牌生效 /
	#   队列变化 / 页面刷新」重新摊开；只按旧序号落位会和别的牌重叠（错位 / 重影）。
	#   这里用 `tween_method` **每帧重新读当前槽位**：手牌怎么变，牌就平滑跟到哪，
	#   末帧自然落在精确位置上，不需要再硬切一下（硬切就是玩家看到的「突然错位」）。
	var slot := _fan_slot_of(i)
	if slot.is_empty():
		return
	_returning_index = i
	_hover_suppressed_index = i
	# ★★ 2026.11.16：返程开始时把整手牌的悬停散开收回去，否则其余牌会停在
	#   「让开旧位置」的姿势上，直到鼠标再次移动。
	var had_hover := _hover_index
	_hover_index = -1
	_kill_hover_tweens()
	if had_hover >= 0:
		_settle_spread(i)
	var start_cell: Vector2 = _cells[i].position
	var start_face: Vector2 = _card_faces[i].position
	var start_rot: float = _cells[i].rotation
	var start_face_rot: float = _card_faces[i].rotation
	var ordinal: int = slot["ordinal"]
	# ★ 缩放复位：`play_drag_success()` 会把牌缩到 0.72 倍，飞回时必须还原。
	_cells[i].scale = Vector2.ONE
	_card_faces[i].scale = Vector2.ONE
	if _drag_tween != null and _drag_tween.is_running():
		_drag_tween.kill()
	if _drag_fade_tween != null and _drag_fade_tween.is_running():
		_drag_fade_tween.kill()
	_drag_tween = create_tween().set_parallel(true)
	_cells[i].z_index = ordinal * 2 + 1
	_card_faces[i].z_index = ordinal * 2
	_drag_tween.tween_method(func(t: float) -> void:
		if _dragging_card or i >= _cells.size():
			return
		var now := _fan_slot_of(i)
		if now.is_empty():
			return
		var r: Rect2 = now["rect"]
		var rr: float = now["rot"]
		var no: int = now["ordinal"]
		_cells[i].z_index = no * 2 + 1
		_card_faces[i].z_index = no * 2
		_cells[i].size = r.size
		_card_faces[i].size = r.size
		_cells[i].position = start_cell.lerp(r.position, t)
		_card_faces[i].position = start_face.lerp(r.position, t)
		_cells[i].rotation = lerp_angle(start_rot, rr, t)
		_card_faces[i].rotation = lerp_angle(start_face_rot, rr, t)
	, 0.0, 1.0, DRAG_RETURN_SEC) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	# 返程用 CUBIC 而不是 BACK：BACK 会先冲过槽位再弹回来，看起来就是「回到手牌后又移了一下」。
	_drag_tween.tween_property(_cells[i], "modulate:a", 1.0, 0.12)
	_drag_tween.tween_property(_card_faces[i], "modulate:a", 1.0, 0.12)
	var on_return_done := func() -> void:
		if not is_instance_valid(self):
			return
		if _returning_index == i:
			_returning_index = -1
		if _dragging_card or i >= _cells.size():
			return
		var now := _fan_slot_of(i)
		if now.is_empty():
			return
		var nr: Rect2 = now["rect"]
		var nr_rot: float = now["rot"]
		_cells[i].position = nr.position
		_cells[i].rotation = nr_rot
		_cells[i].size = nr.size
		_card_faces[i].position = nr.position
		_card_faces[i].rotation = nr_rot
		_card_faces[i].size = nr.size
		# ★★ 2026.11.17：返程落地同样兜一次缩放，避免残留悬停的 1.5 倍。
		if _hover_index != i:
			_cells[i].scale = Vector2.ONE
			_card_faces[i].scale = Vector2.ONE
			_cells[i].pivot_offset = _cells[i].size * 0.5
			_card_faces[i].pivot_offset = _card_faces[i].size * 0.5
	_drag_tween.finished.connect(on_return_done, CONNECT_ONE_SHOT)


func animate_card_back(i: int) -> void:
	_animate_card_back(i)


## ★★ 2026.11.15（用户口径）：**可执行的牌拖出并生效后，牌要消失** ——
##   从松手处向上飘一点 + 缩小 + 淡出；随后**只把自己**淡回当前槽位，
##   **不重排其他牌** —— 用户报的「生效后全部刷新、牌重叠」。
##   ★★ 2026.11.16（用户口径）：「卡牌拖出并生效后不需要刷新整页卡牌」——
##   这条现在对**所有牌**生效（建筑 / 招募 / 将领），不再有「整手牌重新入场」的分支。
##   手牌内容若真的变了，`set_entries()` 已经就地摆好；这里只负责这张牌自己的收尾。
##
## 与 `_animate_card_back()` 的分工（用户明确要求两种动画不同）：
##   · 生效：向上 + 缩小 + 淡出（本函数）——「打出去了」；
##   · 拒绝 / 取消：`_animate_card_back()` 飞回原来的槽位 ——「没收走」。
##
## ★ `scale` / `pivot_offset` 用完必须复位：`animate_deck_in()` 不清这两项
##   （它只管位置 / 旋转 / 透明度），残留的 0.72 倍会被下一张牌继承。
## @param only_this_card true = 只把这一张牌在它**当前槽位**淡回来，**不重排其他牌**
##        （默认就是 true：生效后任何牌都不许刷新整页）。
func play_drag_success(i: int, screen_pos: Vector2, only_this_card: bool = true) -> void:
	if i < 0 or i >= _cells.size() or not _cells[i].visible:
		return
	# ★★ 2026.11.16 修 bug：拖出（按钮跟着指针离开手牌）再收回来时，引擎不会补发
	#   mouse_exited ⇒ 悬停填充会留在牌面上。生效后这张牌必须回到「没悬停」的干净状态。
	FillButtonRes.clear_hover_in(_cells[i])
	_returning_index = -1
	# ★ 只有刚才处于悬停散开时才把邻居收回（见 `_animate_card_back` 同一条说明）。
	if _hover_index >= 0:
		_settle_spread(i)
	_hover_index = -1
	# ★★ 2026.11.17 修 bug：牌回手途中不要再被 mouse_entered 抬到 1.5 倍。
	#   牌会从落点飞回槽位，途中可能正好经过指针；Godot 不会为“牌自己移开”补 mouse_exited，
	#   一旦这时起了悬停 Tween，牌落到手牌后会一直停在 1.5 倍。
	_hover_suppressed_index = i
	if _success_tween != null and _success_tween.is_running():
		_success_tween.kill()
		_success_tween = null
	if _drag_tween != null and _drag_tween.is_running():
		_drag_tween.kill()
	if _drag_fade_tween != null and _drag_fade_tween.is_running():
		_drag_fade_tween.kill()
	var cell := _cells[i]
	var face := _card_faces[i]
	var local: Vector2 = get_global_transform_with_canvas().affine_inverse() * screen_pos
	cell.position = local - cell.size * 0.5
	cell.rotation = 0.0
	cell.modulate.a = 1.0
	cell.pivot_offset = cell.size * 0.5
	cell.scale = Vector2.ONE
	face.position = cell.position
	face.rotation = 0.0
	face.modulate.a = 1.0
	face.pivot_offset = face.size * 0.5
	face.scale = Vector2.ONE
	var out := create_tween().set_parallel(true)
	_success_tween = out
	out.tween_property(cell, "position:y", cell.position.y - 54.0, 0.14) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	out.tween_property(cell, "scale", Vector2(0.72, 0.72), 0.14) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	out.tween_property(cell, "modulate:a", 0.0, 0.14)
	out.tween_property(face, "position:y", face.position.y - 54.0, 0.14) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	out.tween_property(face, "scale", Vector2(0.72, 0.72), 0.14) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	out.tween_property(face, "modulate:a", 0.0, 0.14)
	out.chain().tween_callback(func() -> void:
		if not is_instance_valid(self):
			return
		# ★ 先把这个 Tween 自己停掉：回调可能在最后一条 track 结束时触发，
		#   残留的 position/scale 写入会和下面的「淡回槽位」抢同一张牌。
		if _success_tween != null and _success_tween == out:
			_success_tween.kill()
			_success_tween = null
		cell.scale = Vector2.ONE
		face.scale = Vector2.ONE
		if only_this_card:
			_restore_card_at_slot(i)
		else:
			animate_deck_in())


## 只把一张牌在它**当前**扇形槽位淡回来：不动其他牌、不做整手牌入场。
## 建筑牌生效后用 —— 用户口径「生效后不能全部刷新」。
func _restore_card_at_slot(i: int) -> void:
	if i < 0 or i >= _cells.size():
		return
	# ★★ 2026.11.17：回槽位期间 / 落地后不要让悬停把牌重新放大到 1.5 倍。
	#   用户报的是「升级牌回到手牌仍保持 1.5 倍」——原因是牌回手时指针正好在它上面，
	#   mouse_entered 起了悬停 Tween，而 `_restore_tween` 只写 alpha、不写 scale。
	#   抑制到下一次 `mouse_exited`（见 `_on_cell_mouse_exited`）为止。
	_hover_suppressed_index = i
	if _hover_index == i:
		_hover_index = -1
	var slot := _fan_slot_of(i)
	if slot.is_empty():
		return
	var r: Rect2 = slot["rect"]
	var rot: float = slot["rot"]
	var ordinal: int = slot["ordinal"]
	var cell := _cells[i]
	var face := _card_faces[i]
	cell.position = r.position
	cell.rotation = rot
	cell.size = r.size
	cell.z_index = ordinal * 2 + 1
	cell.modulate.a = 0.0
	cell.scale = Vector2.ONE
	cell.pivot_offset = cell.size * 0.5
	face.position = r.position
	face.rotation = rot
	face.size = r.size
	face.z_index = ordinal * 2
	face.modulate.a = 0.0
	face.scale = Vector2.ONE
	face.pivot_offset = face.size * 0.5
	if _restore_tween != null and _restore_tween.is_running():
		_restore_tween.kill()
	_restore_tween = create_tween().set_parallel(true)
	_restore_tween.tween_property(cell, "modulate:a", 1.0, 0.12)
	_restore_tween.tween_property(face, "modulate:a", 1.0, 0.12)
	# ★★ 2026.11.17：落地再兜一次缩放 —— 即使途中被别的 Tween 写了 1.5 倍，回手完成时也归 1.0。
	_restore_tween.finished.connect(func() -> void:
		if not is_instance_valid(self) or i < 0 or i >= _cells.size() or _dragging_card:
			return
		if _hover_index == i:
			return
		_cells[i].scale = Vector2.ONE
		_card_faces[i].scale = Vector2.ONE
		_cells[i].pivot_offset = _cells[i].size * 0.5
		_card_faces[i].pivot_offset = _card_faces[i].size * 0.5
	, CONNECT_ONE_SHOT)


## 队列开始后，取消牌从左侧滑入，普通招募牌向右错位；打出的兵种从下方补回。
func animate_queue_insert(old_entries: Array, played_kind: String = "",
		played_screen_pos: Vector2 = Vector2.ZERO) -> void:
	if _deck_tween != null and _deck_tween.is_running():
		_deck_tween.kill()
	var old_positions: Dictionary = {}
	var old_visible: Array[int] = []
	for i in old_entries.size():
		if old_entries[i] is Dictionary and not (old_entries[i] as Dictionary).is_empty():
			old_visible.append(i)
	var old_count := old_visible.size()
	for ordinal in old_count:
		old_positions[old_visible[ordinal]] = UiLayoutRes.card_fan_local(ordinal, old_count).position

	var new_visible: Array[int] = []
	for i in _cells.size():
		if _cells[i].visible:
			new_visible.append(i)
	var count := new_visible.size()
	if count == 0:
		return
	var played_index := -1
	if played_kind != "":
		for i in new_visible:
			var e: Dictionary = _entries[i]
			if String(e.get("type", "")) == "recruit" \
					and String(e.get("unit_kind", "")) == played_kind:
				played_index = i
				break

	for ordinal in count:
		var i := new_visible[ordinal]
		var target := UiLayoutRes.card_fan_local(ordinal, count)
		var rot := UiLayoutRes.card_fan_rotation(ordinal, count)
		if i == 0:
			_cells[i].position = target.position + Vector2(-_cells[i].size.x - 30.0, 0.0)
			_cells[i].modulate.a = 0.0
			_card_faces[i].position = _cells[i].position
			_card_faces[i].modulate.a = 0.0
			_cells[i].rotation = rot * 1.3
			_card_faces[i].rotation = rot * 1.3
		elif i == played_index:
			var local: Vector2 = get_global_transform_with_canvas().affine_inverse() * played_screen_pos
			_cells[i].position = local - _cells[i].size * 0.5
			_cells[i].rotation = 0.0
			_cells[i].modulate.a = 1.0
			_card_faces[i].position = _cells[i].position
			_card_faces[i].rotation = 0.0
			_card_faces[i].modulate.a = 1.0
		else:
			var old_i := i - 1
			var from: Vector2 = old_positions.get(old_i, target.position)
			var old_ordinal := old_visible.find(old_i)
			_cells[i].position = from
			_cells[i].rotation = UiLayoutRes.card_fan_rotation(old_ordinal, old_count) \
				if old_count > 0 and old_ordinal >= 0 else rot
			_cells[i].modulate.a = 1.0
			_card_faces[i].position = from
			_card_faces[i].rotation = _cells[i].rotation
			_card_faces[i].modulate.a = 1.0

	_deck_tween = create_tween().set_parallel(true)
	for ordinal in count:
		var i := new_visible[ordinal]
		var target := UiLayoutRes.card_fan_local(ordinal, count)
		var rot := UiLayoutRes.card_fan_rotation(ordinal, count)
		if i == played_index:
			continue
		var delay := 0.0 if i == 0 else 0.025
		_deck_tween.tween_property(_cells[i], "position", target.position, 0.20) \
			.set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_deck_tween.tween_property(_cells[i], "rotation", rot, 0.20) \
			.set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_deck_tween.tween_property(_cells[i], "modulate:a", 1.0, 0.14).set_delay(delay)
		_deck_tween.tween_property(_card_faces[i], "position", target.position, 0.20) \
			.set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_deck_tween.tween_property(_card_faces[i], "rotation", rot, 0.20) \
			.set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_deck_tween.tween_property(_card_faces[i], "modulate:a", 1.0, 0.14).set_delay(delay)
		_cells[i].z_index = ordinal * 2 + 1
		_card_faces[i].z_index = ordinal * 2
	if played_index >= 0:
		call_deferred("_animate_played_recruit_card", played_index, played_screen_pos)


func animate_played_card(unit_kind: String, screen_pos: Vector2) -> void:
	if unit_kind == "":
		return
	for i in _cells.size():
		if i >= _entries.size() or not _cells[i].visible:
			continue
		var e: Dictionary = _entries[i]
		if String(e.get("type", "")) == "recruit" \
				and String(e.get("unit_kind", "")) == unit_kind:
			call_deferred("_animate_played_recruit_card", i, screen_pos)
			return


func _animate_played_recruit_card(i: int, screen_pos: Vector2) -> void:
	if i < 0 or i >= _cells.size() or not _cells[i].visible:
		return
	var ordinal := 0
	var count := 0
	for j in _cells.size():
		if _cells[j].visible:
			if j < i:
				ordinal += 1
			count += 1
	var target := UiLayoutRes.card_fan_local(ordinal, count)
	var local: Vector2 = get_global_transform_with_canvas().affine_inverse() * screen_pos
	_cells[i].position = local - _cells[i].size * 0.5
	_cells[i].rotation = 0.0
	_cells[i].modulate.a = 1.0
	_card_faces[i].position = _cells[i].position
	_card_faces[i].rotation = 0.0
	_card_faces[i].modulate.a = 1.0
	var out := create_tween().set_parallel(true)
	out.tween_property(_cells[i], "position:y", _cells[i].position.y - 46.0, 0.10) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	out.tween_property(_cells[i], "modulate:a", 0.0, 0.10)
	out.tween_property(_card_faces[i], "position:y", _card_faces[i].position.y - 46.0, 0.10) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	out.tween_property(_card_faces[i], "modulate:a", 0.0, 0.10)
	await out.finished
	if not is_instance_valid(self) or i >= _cells.size() or not _cells[i].visible:
		return
	_cells[i].position = target.position + Vector2(0.0, 42.0)
	_cells[i].rotation = 0.0
	_cells[i].modulate.a = 0.0
	_card_faces[i].position = _cells[i].position
	_card_faces[i].rotation = 0.0
	_card_faces[i].modulate.a = 0.0
	var incoming := create_tween().set_parallel(true)
	incoming.tween_property(_cells[i], "position", target.position, 0.18) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	incoming.tween_property(_cells[i], "rotation", UiLayoutRes.card_fan_rotation(ordinal, count), 0.18) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	incoming.tween_property(_cells[i], "modulate:a", 1.0, 0.14)
	incoming.tween_property(_card_faces[i], "position", target.position, 0.18) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	incoming.tween_property(_card_faces[i], "rotation", UiLayoutRes.card_fan_rotation(ordinal, count), 0.18) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	incoming.tween_property(_card_faces[i], "modulate:a", 1.0, 0.14)


## 第 i 格**名字那一行**的排版：有图标 → 压到最下面一窄条、字号小一档；
## 没图标 → 整格居中、用正文号（操作 / 建筑 / 科技那种纯文字格）。
## 第 i 格**名字**的排版：
## · 有图标 → 名字压在最下面那条**略黑底条**上（底条显示出来），字号小一档；
## · 没图标（操作页）→ 底条藏起来，名字整格居中、用正文号。
## ★ 图标**不跟着动**：它始终铺满整格（用户口径：图标不考虑文字的位置）。
func _apply_name_layout(i: int, has_icon: bool) -> void:
	if i < 0 or i >= _name_labels.size():
		return
	var label: Label = _name_labels[i]
	var cell_size: Vector2 = _cells[i].size if i < _cells.size() else Vector2.ZERO
	if i < _name_bars.size() and _name_bars[i] != null and is_instance_valid(_name_bars[i]):
		(_name_bars[i] as ColorRect).visible = has_icon
	if has_icon:
		label.position = Vector2(1.0, cell_size.y - NAME_BAR_H)
		label.size = Vector2(cell_size.x - 2.0, NAME_BAR_H)
		label.add_theme_font_size_override("font_size",
			NAME_ON_ICON_FS if cell_size.x >= 130.0 else UiStyleRes.FS_TINY)
	else:
		label.position = Vector2.ZERO
		label.size = cell_size
		label.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)


## ★★ 每帧同步招募批次的读条与数量（不重建命令卡）。
##   进度是连续变化的，不能塞进 `_card_sig()`（会每帧重建九格）。
func set_recruit_queue(progress: float, counts: Dictionary) -> void:
	var p := clampf(progress, 0.0, 1.0)
	for i in _cells.size():
		if i >= _entries.size():
			continue
		var e: Dictionary = _entries[i]
		var entry_type := String(e.get("type", ""))
		if entry_type != "recruit" and entry_type != "recruit_cancel_all":
			continue
		var kind := String(e.get("unit_kind", ""))
		var c := int(counts.get(kind, 0))
		if i < _icon_views.size() and _icon_views[i] != null:
			_icon_views[i].set_progress(p if entry_type == "recruit_cancel_all" and c > 0 \
				else 0.0)
		if i < _count_labels.size() and _count_labels[i] != null:
			var count := maxi(c, int(e.get("queue_count", 0)))
			_count_labels[i].text = "×%d" % count if count > 1 else ""
			_count_labels[i].visible = count > 1



## ★★ 让某一类格子（`unit_kind`）呼吸高亮；空串 = 关闭。
##   教程「让协防军按钮呼吸高亮」用。高亮状态会一直保留，直到剧本显式关掉。
func set_glow_kind(kind: String) -> void:
	var k := kind.strip_edges()
	if k == glow_kind:
		return
	glow_kind = k
	_glow_t = 0.0
	_update_glow_panels()


func _update_glow_panels() -> void:
	var pulse := 0.2 + 0.8 * (0.5 - 0.5 * cos(_glow_t * TAU / 1.4))
	var rip_t := fmod(_glow_t, 1.4) / 1.4
	var rip_e := 1.0 - (1.0 - rip_t) * (1.0 - rip_t)
	for i in _glow_panels.size():
		var panel: Panel = _glow_panels[i]
		if panel == null or not is_instance_valid(panel):
			continue
		var hit := false
		if glow_kind != "" and i < _entries.size() and not (_entries[i] as Dictionary).is_empty():
			var e: Dictionary = _entries[i]
			hit = String(e.get("unit_kind", e.get("kind", ""))) == glow_kind
		panel.visible = hit
		if hit:
			var sb: StyleBoxFlat = panel.get_theme_stylebox("panel") as StyleBoxFlat
			if sb != null:
				var c := UiStyleRes.accent()
				sb.border_color = Color(c.r, c.g, c.b, 0.35 + 0.6 * pulse)
				sb.bg_color = Color(c.r, c.g, c.b, 0.05 + 0.10 * pulse)
		# 方形波纹：只在匹配的格子上从内向外扩。
		if i < _glow_ripples.size():
			var rip: Panel = _glow_ripples[i]
			if rip == null or not is_instance_valid(rip):
				continue
			rip.visible = hit
			if hit:
				var cell: Vector2 = UiLayoutRes.card_cell_local(i).size
				var s := lerpf(cell.x * 0.32, cell.x * 1.18, rip_e)
				rip.position = (cell - Vector2(s, s)) * 0.5
				rip.size = Vector2(s, s)
				var rsb: StyleBoxFlat = rip.get_theme_stylebox("panel") as StyleBoxFlat
				if rsb != null:
					var rc := UiStyleRes.accent()
					rsb.border_color = Color(rc.r, rc.g, rc.b, (1.0 - rip_t) * 0.9)


func _process(dt: float) -> void:
	if not is_visible_in_tree():
		return
	# ★★ 2026.11.15：动画都结束后做一次「空格子不许露脸」的兜底。
	#   用户报的「用掉一张牌后，每页同一序号都多一张空白牌」= 某个空槽的
	#   按钮 / 卡面没被收起，残留成一张空白牌；这里在无动画时强制隐藏。
	var animating: bool = _dragging_card or _returning_index >= 0 \
		or (_success_tween != null and _success_tween.is_running()) \
		or (_restore_tween != null and _restore_tween.is_running()) \
		or (_deck_tween != null and _deck_tween.is_running()) \
		or (_drag_tween != null and _drag_tween.is_running())
	if not animating:
		for i in _cells.size():
			var filled: bool = i < _entries.size() \
				and not (_entries[i] as Dictionary).is_empty()
			if not filled and _cells[i].visible:
				_cells[i].visible = false
				_card_faces[i].visible = false
	_glow_t += maxf(0.0, dt)
	if glow_kind != "":
		_update_glow_panels()
	for i in _cells.size():
		# ★★ 2026.11.15：卡面（暗色底板）**每帧硬跟随按钮**。
		#   按钮和卡面是两个兄弟节点，只要有任何一条动画只写了其中一个，
		#   就会出现「一张有内容的牌 + 一张空白牌叠在一起」；这里把不变量钉死：
		#   卡面的 position / size / rotation / scale / 层级永远等于按钮。
		var cell_i: Control = _cells[i]
		var face_i: Control = _card_faces[i]
		if not cell_i.visible:
			face_i.visible = false
		else:
			face_i.visible = true
			face_i.position = cell_i.position
			face_i.size = cell_i.size
			face_i.rotation = cell_i.rotation
			face_i.scale = cell_i.scale
			face_i.pivot_offset = cell_i.pivot_offset
			face_i.modulate.a = cell_i.modulate.a
			face_i.z_index = cell_i.z_index - 1
		# ★★ 2026.11.14：描边 / 底色跟着**泛光进度**缓动（见 `_sync_cell_style`）。
		#   与下面那段名字底条同一个循环，省一次 9 格遍历。
		_sync_cell_style(i)
	for i in _name_bars.size():
		var bar: ColorRect = _name_bars[i]
		if bar == null or not is_instance_valid(bar) or not bar.visible:
			continue
		if i >= _cells.size():
			continue
		var p: float = clampf(FillButtonRes.fill_progress(_cells[i]), 0.0, 1.0)
		var c := UiStyleRes.name_bar()
		bar.color = Color(c.r, c.g, c.b, c.a * (1.0 - p))


## 给第 i 格套上**一份常驻底纹**（`_cell_styles[i]`），只有颜色会随悬停进度变。
##
## ★★ 2026.11.14（用户口径）：「卡牌在静止到悬停态时需要有缓动效果……描边与填充也跟着缓动」。
##   原来四档是**四个不同的 StyleBox**（normal / hover / pressed / disabled），
##   鼠标一进就由引擎整块换掉 ⇒ 描边颜色当场从暗金跳成亮金（没有任何过渡）。
##   现在 normal / hover / disabled **共用同一份** StyleBox，颜色由
##   `_sync_cell_style()` 按 `fill_button` 的**泛光进度**逐帧插值（那个进度本身就是缓动的），
##   于是描边与底色都跟着「抬起」一起渐变；只有按下（`pressed`）仍然是瞬时换档 ——
##   按下是**点击反馈**，本来就不该慢。
##
## ⚠️ `filled` 只影响「常态长什么样」（空格子的底色略淡），它不改变缓动逻辑。
func _cell_style(i: int, cell: Button, filled: bool) -> void:
	while _cell_styles.size() <= i:
		_cell_styles.append(null)
		_cell_bg0.append(Color(0, 0, 0, 0))
		_cell_border0.append(Color(0, 0, 0, 0))
		_cell_glow_applied.append(-1.0)
	var sb: StyleBoxFlat = _cell_styles[i]
	var base: StyleBoxFlat = UiStyleRes.card_normal(filled)
	if sb == null:
		sb = base.duplicate() as StyleBoxFlat
		_cell_styles[i] = sb
	# ★ 把「常态那一档」的形状参数抄过来（圆角 / 阴影 / 内容边距），颜色单独记。
	sb.set_corner_radius_all(base.corner_radius_top_left)
	sb.shadow_color = base.shadow_color
	sb.shadow_size = base.shadow_size
	sb.shadow_offset = base.shadow_offset
	sb.content_margin_left = base.content_margin_left
	sb.content_margin_right = base.content_margin_right
	sb.content_margin_top = base.content_margin_top
	sb.content_margin_bottom = base.content_margin_bottom
	sb.set_border_width_all(base.border_width_top)
	sb.bg_color = base.bg_color
	sb.border_color = base.border_color
	_cell_bg0[i] = base.bg_color
	_cell_border0[i] = base.border_color
	_cell_glow_applied[i] = -1.0          # 强制下一帧按当前进度重算一次
	cell.add_theme_stylebox_override("normal", sb)
	cell.add_theme_stylebox_override("hover", sb)      # 与常态同一份 ⇒ 引擎换档不再跳色
	cell.add_theme_stylebox_override("disabled", sb)
	cell.add_theme_stylebox_override("pressed", UiStyleRes.card_pressed())
	cell.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


## 按**泛光进度**把第 i 格的描边 / 底色插值到「悬停档」。
##
## 进度来自 `fill_button` 的 `_glow`（悬停 0→1，时长 `ui.hover_in_sec`），
## 所以它和四边泛光 / 瞄准框**同一个节拍**：牌抬起的同时，描边也在变亮。
## ⚠️ 只在进度真的变了的时候写 StyleBox（每帧无脑写会触发表格重绘）。
func _sync_cell_style(i: int) -> void:
	if i < 0 or i >= _cell_styles.size() or i >= _cells.size():
		return
	var sb: StyleBoxFlat = _cell_styles[i]
	if sb == null:
		return
	var cell: Button = _cells[i]
	if not cell.visible:
		return
	var g: float = clampf(FillButtonRes.glow_progress(cell), 0.0, 1.0)
	if absf(g - float(_cell_glow_applied[i])) < 0.002:
		return
	_cell_glow_applied[i] = g
	# 置灰（不可点）的格子：往「暗金」那档靠，不要变成亮金（那看起来像能点）
	var hot: Color = UiStyleRes.accent_dim() if cell.disabled else UiStyleRes.accent_bright()
	var bc0: Color = _cell_border0[i]
	var bg0: Color = _cell_bg0[i]
	sb.border_color = bc0.lerp(hot, g)
	sb.bg_color = Color(bg0.r, bg0.g, bg0.b, bg0.a * (1.0 - g))


## 给第 i 格换图标（`mask` 为空且 `role` 也为空 = 这一格不画图标）。
## ★ 本层不认识「兵种」：兵种 → 蒙版路径 / 图形的映射在 view/unit_card_icon.gd，
##   条目那一侧（hud）算好 —— 这里只收两个字符串。
## @param mask 剪影浮雕蒙版路径（主路径）
## @param role 矢量金线图形（蒙版缺失时的兜底）
## @param ready 这一格现在能不能点（锁住的行图标也画暗一档，与灰字同一个观感）
func _set_icon(i: int, role: String, mask: String, ready: bool = true) -> void:
	if i < 0 or i >= _icon_views.size():
		return
	var v = _icon_views[i]
	if v == null or not is_instance_valid(v):
		return
	v.set_role(role)
	v.set_mask(mask)
	v.set_ready(ready)


func _on_cell_pressed(i: int) -> void:
	# 鼠标点按刻意不激活：手牌统一通过向上拖起并松手打出。
	# 快捷键仍直接走 handle_key() -> activate_index()。
	return


## 鼠标进入 / 离开第 i 格 —— **只转发序号**（内容由 hud 现取，见上面那两个信号的说明）
func _on_cell_mouse_entered(i: int) -> void:
	if _dragging_card:
		return
	if touch_suppress_hover:
		return                       # 手机端按住期间不弹（长按到点后由 hud 调 hover()）
	_raise_card(i, true)
	cell_hovered.emit(i)


func _on_cell_mouse_exited(i: int) -> void:
	if _hover_suppressed_index == i:
		_hover_suppressed_index = -1
	if _dragging_card:
		return
	_raise_card(i, false)
	cell_unhovered.emit(i)


## 模拟悬停第 i 格 / 离开它（等价于玩家的鼠标停上去 / 移开）。
## ★ 与 `press()` 那条同一条约定：测试走**和引擎同一条信号**，不另开一条捷径。
## ★★ 手机端的长按也走这里 —— 所以它**绕开** `touch_suppress_hover` 直接发信号。
func hover(i: int) -> void:
	cell_hovered.emit(i)


func unhover(i: int) -> void:
	cell_unhovered.emit(i)


## 激活第 i 格。@return true = 这一格有内容、动作已发出
func activate_index(i: int) -> bool:
	if i < 0 or i >= _entries.size():
		return false
	if (_entries[i] as Dictionary).is_empty():
		return false                     # 空格子（单位页按行解锁留下的空位）
	entry_activated.emit(_entries[i])
	return true


## 键盘：只有**有内容的格**才吃掉按键（空格子让给别人，见 hud.handle_key）
##
## ★★ 被置灰的格子（`ready == false`）**也不吃按键**（本版新增）：与点击那条路
##   保持一致 —— 否则按 Q 会静默地什么都不发生（格子画着灰、键盘却"接受了"这一下），
##   而玩家更可能只是想按 Q 做别的事（那几个字母同时也是别的绑定的候选）。
##
## ★ 带修饰键的组合（Ctrl / Alt / Cmd）一律放行，不吃。
##   为什么必须有这条：`game_scene._unhandled_input` 里命令卡**排在 input_controller 之前**
##   （先问 hud 再问输入控制器），不放行的话 Ctrl+Q（开发者快捷键：全屏）会先被 Q 格吃掉
##   → 按一下全屏会顺手招募一个兵。
##   顺带把 Ctrl+W / Ctrl+E / … 这一整类组合键都让出来了。
##   ⚠️ 只挡 ctrl / alt / meta：Shift 不算 —— Shift+Q 在玩家看来仍然是 Q 格。
func handle_key(event: InputEventKey) -> bool:
	if not event.pressed or event.echo:
		return false
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return false
	var slot: int = int(UiLayoutRes.CARD_KEY_TO_SLOT.get(event.keycode, -1))
	if _has_recruit_progress_entry():
		slot += 1 # 读条牌展示在最左，但不占单位牌的 Q/W/... 快捷键序号。
	if slot < 0 or slot >= _entries.size():
		return false
	if (_entries[slot] as Dictionary).is_empty():
		return false                     # 空格子不吃按键（让给别的绑定）
	if not bool((_entries[slot] as Dictionary).get("ready", true)):
		return false
	if String((_entries[slot] as Dictionary).get("type", "")) == "recruit_cancel_all":
		return false # 取消队列固定使用 Esc，不占用 Q/W/... 牌位快捷键。
	activate_index(slot)
	return true


func _has_recruit_progress_entry() -> bool:
	return not _entries.is_empty() and _entries[0] is Dictionary \
		and String((_entries[0] as Dictionary).get("type", "")) == "recruit_cancel_all" \
		and bool((_entries[0] as Dictionary).get("queue_card", false))


# ------------------------------------------------------------------
# 给测试 / hud 用的小接口
# ------------------------------------------------------------------

func entries() -> Array:
	return _entries


func entry_at(i: int) -> Dictionary:
	if i < 0 or i >= _entries.size():
		return {}
	return _entries[i]


## 这一格现在**能不能拖 / 能不能点**（`ready = false` = 置灰：冷却中、没解锁）。
## ★★ 2026.11.14：拖拽这条路以前完全没看这个字段 —— 置灰的牌照样拖得起来、
##   照样能在松手时下达（用户报的「操作牌冷却没有生效」就是这个）。
func _card_ready(i: int) -> bool:
	return bool(entry_at(i).get("ready", true))


func cell_at(i: int) -> Button:
	if i < 0 or i >= _cells.size():
		return null
	return _cells[i]


## 第 i 格显示的名字（空格子为空串）
func cell_label(i: int) -> String:
	if i < 0 or i >= _name_labels.size():
		return ""
	return _name_labels[i].text


## 第 i 格那行名字**现在看不看得见**。
## ★ 有图标的格子把名字藏起来了（文字由图标代替），但 `cell_label()` 仍读得到 ——
##   这两件事在这里是分开的两个出口，测试要断言哪一个就取哪一个。
func cell_label_visible(i: int) -> bool:
	if i < 0 or i >= _name_labels.size():
		return false
	return _name_labels[i].visible


## 第 i 格现在画的是哪张图标（空串 = 不画图标、只有字）。
func cell_icon_role(i: int) -> String:
	if i < 0 or i >= _icon_views.size():
		return ""
	var v = _icon_views[i]
	return String(v.role()) if v != null and is_instance_valid(v) else ""


## 第 i 格现在画的**剪影蒙版路径**（空串 = 走矢量兜底 / 没有图标）。
## ★ 与 `cell_icon_role()` 是两个出口：主路径是蒙版，role 只在缺蒙版时才会被画。
func cell_icon_path(i: int) -> String:
	if i < 0 or i >= _icon_views.size():
		return ""
	var v = _icon_views[i]
	return String(v.mask_path()) if v != null and is_instance_valid(v) else ""
