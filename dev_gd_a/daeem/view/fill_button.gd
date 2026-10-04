## fill_button.gd —— ★★ 按钮的「金色自下而上填充」动效（悬停填充 / 反向渐出 / 启用常驻）
##
## 需求原话：
##   「当玩家鼠标悬停在任何按钮上时，按钮背景都会由空到由下往上填充金色背景，
##     需要做渐变效果和悬停结束时的反向渐出效果」；
##   「当某按钮被点击切换启用时（如游戏内右下角的页签和科技的九个按钮），
##     需要特殊处理，当点击启用时将其亮度稍微变大」。
##
## ------------------------------------------------------------------
## 为什么是「子节点动画器 + 宿主自己 _draw」，而不是一个自定义 Button 子类
## ------------------------------------------------------------------
## 项目里所有按钮都是 `Button.new()` 出来的（hud / page_tabs / tech_grid /
## command_card / squad_panel / start_screen / map_select / campaign_test 共八处），
## 而且测试直接盯 `button_at(i)` / `cell_at(i)` 这些**已是 Button** 的引用。
## 把 Button 换成子类要改八处构造点、而 GDScript 的 `--script` 模式**用不了全局
## class_name**（见 tests/test_case.gd 第 16 行那条口径）—— 于是调用点得
## `const FillButtonRes = preload(...)` 再 `.new()`，八处各抄一遍 preload。
##
## 所以这里换一种接法：**按钮仍然是 `Button`**，只是
##   ① `attach_text(button)` 往它身上挂一个**子节点动画器**（推进进度 + 自己画那片金）；
##   ② 那片金由**动画器自己的 `_draw()`** 画，并 `show_behind_parent` 排在宿主下面
##      （层次与理由见下一节）——于是同样不需要按钮子类。
##   ⇒ 调用点只多一行 `FillButtonRes.attach_text(cell)`，其余代码一个字都不用动。
##
## ⚠️ 必须走 `attach_text()`：它一个人把「挂动画器 / 连鼠标信号 / 记住原字色」三件事都做了。
##    只 `attach()` 不 `attach_draw()` ⇒ 动画照跑、屏幕上什么都没有。
##
## ------------------------------------------------------------------
## 画在**哪一层**（★ 本版修过，别再按旧写法改回去）
## ------------------------------------------------------------------
## 层次要的是这样（从下往上）：
##     按钮下面那块面板 → **填充金** → 按钮底纹 → 按钮自己的文字 → 子节点（Label）
##
## 旧写法是「在宿主的 `draw` 信号里画」。那条路**画不到那一层**：
##   Godot 4 的 `CanvasItem` 是先走 `NOTIFICATION_DRAW`（`Button` 在这里画底纹与文字）、
##   **然后**才发 `draw` 信号。于是宿主的字早就画完了，填充金排在那之后 ——
##   屏幕上就是「金把底纹和文字一起糊掉」。
##   实测（`shots/probe_campaign_hover.png`）：选中的关卡 / 阵营那两个按钮整块是金，
##   **一个字都看不见**；用户报的正是「这些字都被金色填充遮挡」。
##   ⚠️ 页签栏那几颗当时看着是对的，纯粹因为它们的字是**子 Label**（子节点画在父节点之后）
##      —— 那是「碰巧」，不是这条路对。
##
## 现在改成**一颗子节点自己画**，并 `show_behind_parent = true`：
##   子节点的绘制命令排在**父节点自己那一批之前**，于是正好是上面那个层次 ——
##   填充盖得住按钮下面的面板、盖不住底纹与文字（这也是各处注释里一直写的口径：
##   「填充层画在底纹**下面**」）。
##
## ⚠️ 代价（调用点要配合）：底纹一旦自己铺了**实底**，那片金就被它盖住了。
##   所以「悬停 / 已启用时要看见金」的那几档底纹必须是**透明的**
##   （`ui_style` 的 `*_clear` / `*_fill` 那一批，测试里有断言盯着）。
## 换成「拿 StyleBoxFlat 当填充」做不到 —— StyleBoxFlat 只有单色，没有渐变，
## 而且每帧新建 StyleBox 就是一帧一次资源分配（这个控件每帧都在动）。
##
## ------------------------------------------------------------------
## 那这片金压不压得住「上面的字」？（★ 本版重做过，别再按旧写法改回去）
## ------------------------------------------------------------------
## 旧写法是「让字色跟着进度**线性 lerp** 到暗档」。它有一个致命的中段：
##   字色与那片金**同时**往中间调走，于是在 fill≈0.3~0.55 那一段两者撞车，
##   实测对比度掉到 **1.09:1**（= 同色）—— 观感就是「字被金盖住了 / 看不见」
##   （用户报的正是这个）。
##
## 现在改成**每帧比对比度选色**（见 `_sync_text()`）：
##   · 底色 = 这颗按钮**底纹的底色** 与「已经盖到**这条字**身上的那部分填色」的合成；
##   · 两个候选：原色（暖白）与「填充底上那一档」（暖黑，由 theme 定亮度）；
##   · 取对比更高的那个 —— 于是「字与底撞色」**结构上不可能发生**，
##     而且换档（金 ⇄ 灰 ⇄ 更亮的启用金）都不用重调阈值。
##   ★ 因为「盖到字身上多少」是按**字自己的中心位置**算的，命令卡那种
##     「键位字母贴左上 + 名字居中」的两行字会在同一帧各自选到合适的色。
##
## ⚠️ 只读 + 发命令：本文件**不认识任何玩法概念**，它只认「谁来填、填多满」。
extends Control

const ThemeRes = preload("res://view/theme.gd")

## 进度存在按钮身上的元数据键（`attach()` 写、`draw()` 读）。
## ★ 用元数据而不是「给 Button 加个字段」：调用点建的是**真 Button**，
##   没有地方能声明那个字段（见文件头那段）。
const META := "fill_animator"

## 填充 / 渐出的时长（秒）。★ 渐出比填充**短一点**：
##   鼠标已经移开了，玩家等的是「它快点让开」，而不是「看它慢慢退回去」。
const FILL_TIME := 0.18
const DRAIN_TIME := 0.13

## ★★ 逐字「翻面」的两个阈值（覆盖率）。
##
## ⚠️⚠️ 这里**不能**用「逐字 lerp 颜色」：数学上过不去 ——
##   一次 lerp 到一半时字是「中间灰」，而那时底色正好是「半明半暗的金」，
##   两者亮度几乎相同，实测对比度 **1.0:1**（= 完全同色），字直接消失。
##   几种缓动窗口都试过，最差都是 1.0~1.2（见本轮实测记录）。
##   ⇒ 所以改成「**逐字翻面**」：金扫到哪个字，那个字才**整块**从原色换到填充档。
##     因为是一字一字地翻，屏幕观感仍是「金色前沿扫过去，字一个一个变黑」，
##     而不是整行同时翻 —— 但它永远不会经过那个「中间灰」。
##
## 取值：`LO` 之后才允许翻（此时金已经盖过大半，暗字压上去对比已经够）；
##   `HI` 是**迟滞**的上界（避免在阈值附近来回抖）。
##   ⚠️ 这两个值在**内层类**里又写了一遍：GDScript 的内层类看不到外层的常量，
##      改这里记得改 `FillAnimator.FLIP_LO / FLIP_HI` —— 两处必须同值。
const FLIP_LO := 0.62
const FLIP_HI := 0.78


# ------------------------------------------------------------------
# 竖向渐变：一整条 GradientTexture2D（**只在换色时建一次**）
#
# ★ 为什么不跟着进度每帧重建那份渐变：重建就是每帧造一张 CPU 位图 + 上传显存。
#   这里进度只改「露出纹理的哪一段」（区域 + USED_RECT），纹理本身不动
#   —— 见 `FillAnimator.draw_fill_now()` 的 ③。
# ------------------------------------------------------------------


# ------------------------------------------------------------------
# 挂载
# ------------------------------------------------------------------

## 挂上动效（**返回动画器**，给需要读进度 / 锁定态的调用方）。
## 已经挂过的按钮：直接返回原来那个（重复挂等于两个 `_process` 抢同一份进度）。
static func attach(b: Button) -> FillAnimator:
	if b == null:
		return null
	# ⚠️⚠️ **必须先 `has_meta()` 再 `get_meta()`**：4.7 实测，`get_meta(key, 默认值)`
	#   即使给了默认值，**键不存在时照样会打一条引擎错误**
	#   （"The object does not have any 'meta' values with the key …"）。
	#   于是「给个默认值就不会吵」这件事是假的 —— 缺键时只能根本不去读它。
	var old: Variant = b.get_meta(META) if b.has_meta(META) else null
	if old != null and is_instance_valid(old):
		return old
	var anim := FillAnimator.new()
	anim.name = "FillAnimator"
	anim._attach(b)
	b.add_child(anim)
	b.set_meta(META, anim)
	return anim


## ★★ 调用点只需要这一行：挂动画器 + 让这颗按钮**有那层金**。
##
## ★ 那片金由动画器（一颗 `show_behind_parent` 的子节点）自己画，
##   **不再**去接宿主的 `draw` 信号 —— 理由见文件头那一节（接那里等于画在文字之上）。
static func attach_draw(b: Button) -> FillAnimator:
	var anim := attach(b)
	if b != null and not b.has_meta("fill_draw"):
		# ★ 这个标记 = 「这颗按钮已经挂了填充层」（测试与排查读它）。
		#   ⚠️ 旧版本它代表「接了宿主的 draw 信号」，那不是现在这条实现 —— 别按旧义用。
		b.set_meta("fill_draw", true)
	return anim


static func animator_of(b: Button) -> FillAnimator:
	if b == null or not is_instance_valid(b) or not b.has_meta(META):
		return null
	# ⚠️ 这里**不能**写成 `get_meta(META, null)`：键不存在时 Godot 4.7 会打引擎错误，
	#   所以上面先 `has_meta()` 挡一道（见 `attach()` 里那条说明）。
	var a: Variant = b.get_meta(META)
	return a if is_instance_valid(a) else null


# ------------------------------------------------------------------
# 对比度（选字色用，也把「读不读得出来」这件事交给一个可断言的函数）
#
# ★ 用 WCAG 那一套（sRGB 分段线性化 + 0.2126/0.7152/0.0722 加权），
#   **不是** `Color.get_luminance()`（那是 gamma 2.2 近似，算对比度会偏乐观：
#   暖白压填充金，两者给的数是 1.73 vs 2.77）。
# ------------------------------------------------------------------

## 相对亮度缓存（同一批颜色会被反复问，而 `_sync_text` 每帧都在选色）。
static var _rel_cache: Dictionary = {}


static func relative_luminance(c: Color) -> float:
	var key := c.to_html(false)
	var hit: Variant = _rel_cache.get(key, null)
	if hit != null:
		return hit
	var v := 0.2126 * _srgb_chan(c.r) + 0.7152 * _srgb_chan(c.g) + 0.0722 * _srgb_chan(c.b)
	_rel_cache[key] = v
	return v


static func _srgb_chan(v: float) -> float:
	if v <= 0.04045:
		return v / 12.92
	return pow((v + 0.055) / 1.055, 2.4)


## 两色的对比度（1.0 = 完全同色，越大越清楚；正文一般要 ≥4.5）。
static func contrast(a: Color, b: Color) -> float:
	var la := relative_luminance(a)
	var lb := relative_luminance(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


# ------------------------------------------------------------------
# 绘制（唯一碰 draw_* 的地方）
# ------------------------------------------------------------------

## 画某颗按钮当前进度下的那一片金（**画在动画器自己的绘制里**，见文件头那一节）。
##
## ★ 真正的调用点是 `FillAnimator._draw()`；这个静态入口留着给「手里只有那颗按钮」
##   的调用方（测试 / 排查）：它会转交给动画器。
##   ⚠️ `draw_*` 只能在**那个控件自己的绘制期**里调（引擎会报
##      "Drawing is only allowed inside NOTIFICATION_DRAW…"），
##      所以从外面调它只在「进度为 0（直接返回）」这类无害场合是安全的。
static func draw_fill(b: Button) -> void:
	var anim := animator_of(b)
	if anim == null:
		return
	anim.draw_fill_now()


# ------------------------------------------------------------------
# 动画器
# ------------------------------------------------------------------

## 一颗按钮的填充状态 + 那片金的**绘制者**。它是个 `Control`，挂在宿主按钮下面
##   （`_process` 才有地方跑、`_draw` 才有地方画），并且 `show_behind_parent = true`
##   ⇒ 它画的东西排在宿主的底纹 / 文字**之前**（层次见文件头那一节）。
class FillAnimator extends Control:
	## 已经填了多少（0 = 空，1 = 满）。★ 只读用途请走 `host` 上的静态接口。
	var _fill: float = 0.0
	## 目标：0（鼠标不在）/ 1（鼠标在）/ 1（已启用 —— 锁定态不会退回 0）。
	var _latched: bool = false
	## 鼠标是否停在这颗按钮上（按下时也算「在」，否则一按下背景就退回去）。
	var _hovered: bool = false
	## 鼠标信号连过了吗（`setup_host()` 可能被调多次：它要幂等，不然信号会连两遍）。
	var _host_ready: bool = false
	## 允许填充吗（被显式关掉时为 false）。⚠️ **禁用态不再是 false**：
	##   需求要「禁用按钮也有悬停反馈，只是填灰的」，所以禁用走 `_goal()` 里的灰档，
	##   这个字段留给「空槽 / 压根不是一个可交互动效」的场合。
	var _available: bool = true
	## ★ 这一帧用的是**灰档**（按钮被禁用 ⇒ 填灰，见 `_goal()`）。
	var _grey: bool = false
	## 上一帧是不是灰档（换档时要重取渐变颜色，见 `_process`）。
	var _was_grey: bool = false
	## 与文件顶部的 `FLIP_LO / FLIP_HI` **同值**（内层类读不到外层的常量，只能再写一份）。
	const FLIP_LO := 0.62
	const FLIP_HI := 0.78
	## 每条文字**当前翻了没有**（逐字 / 逐条各自记 —— 迟滞要靠它）。
	var _flipped: Dictionary = {}
	## ⚠️ 已作废（只是记着）——见 `set_prefer_light()`：字色现在只有「跟着金前沿翻黑」一条规则。
	var _prefer_light: bool = false
	## 「行模式」的文字节点（整行共用一个渐变进度，见 `_char_t`）。
	var _row_text_nodes: Dictionary = {}
	## 宿主按钮（退了 → 自己收摊）。
	var _button: Button = null
	## 渐变纹理（只有换色时才重建）。
	var _ramp: GradientTexture2D = null
	## 当前档位的**填色两端**（缓存下来：`_sync_text` 每帧要拿它算对比度，
	##   不能每帧去问 theme —— 那是「取个颜色」变成「每帧几十次字典查表」）。
	var _bottom: Color = Color(0, 0, 0, 1)
	var _top: Color = Color(1, 1, 1, 1)
	## 调用点显式指定的「按钮下面的底色」（alpha < 0 = 没给，于是按底纹猜）。
	var _panel_override: Color = Color(-1.0, -1.0, -1.0, -1.0)
	## 每一条按钮上文字 / 子 Label 的**原色**（`_sync_text()` 每次都从它算，可重入）。
	var _text: Dictionary = {}
	var _dirty: Array[Node] = []
	## 「有字色要重算，但当时还没法算」（纹理还没建好）——`_sync_text()` 会置这个标。
	var _text_dirty: bool = false

	func _attach(b: Button) -> void:
		_button = b
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		# ★★ 排到宿主**下面**去画（这是本版修「金把字糊掉」的那一行）：
		#   `show_behind_parent` 让它这批绘制命令排在宿主自己的绘制命令**之前** ——
		#   于是层次回到「面板 → 金 → 底纹 → 文字 → 子 Label」。
		#   ⚠️ 不能改成「在宿主的 `draw` 信号里画」：那条路排在文字**之后**（见文件头）。
		#   ⚠️ 也不要用 `z_index`：那是给兄弟节点排序用的，且与 CanvasLayer / y_sort 有交互；
		#      `show_behind_parent` 才是「画在父节点背后」这件事的专用开关。
		show_behind_parent = true
		# 铺满宿主（填充按宿主的 `size` 画，本地原点必须与宿主重合）。
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_ramp = GradientTexture2D.new()
		_ramp.width = 1
		_ramp.height = 64
		_ramp.fill_from = Vector2(0.0, 1.0)      # ① 起点在**下边**
		_ramp.fill_to = Vector2(0.0, 0.0)        #    终点在上边 ⇒ 竖向渐变
		# 采样只落在 0..1 之内（区域的 USED_RECT 就是这么算的），
		# 但边缘那一两像素可能擦到界外 —— REPEAT_NONE 把它按 clamp 处理，不会绕回来。
		# ⚠️ 枚举名是 `REPEAT_NONE`（4.7 实测）：**没有** REPEAT_CLAMP / REPEAT_DISABLED 这两个名字。
		_ramp.repeat = GradientTexture2D.REPEAT_NONE
		set_colors(ThemeRes.fill_top(), ThemeRes.fill_bottom())
		b.resized.connect(queue_redraw)
		# ★ 记得「初始是哪个档」（可点 = 金档），否则第一帧会误判成换档、白刷一次。
		_was_grey = is_grey()
		_refresh_colors()


	## 动画器自己的绘制：**那片金就是在这一层画出来的**。
	func _draw() -> void:
		draw_fill_now()


	## 画当前进度下的那一片金（`_draw()` 与静态入口 `FillButtonRes.draw_fill()` 都走它）。
	##
	## ⚠️ `draw_*` 只能在本控件的绘制期里调，别从外面直接调它。
	func draw_fill_now() -> void:
		if not _available or _button == null or not is_instance_valid(_button):
			return
		var fill: float = _fill
		if fill <= 0.0001:
			return

		# ① 这块按钮的**本地**矩形。
		#
		# ⚠️⚠️ 这里**必须**是本地坐标（`(0,0)..size`），**不能**用
		#   `get_global_transform_with_canvas()` 算出来的画布坐标 ——
		#   `draw_*` 是在**这个控件自己的变换里**执行的，画布坐标会被再加一次控件的
		#   位置 / 缩放（偏移翻倍）。实测症状：填充金画到了按钮右下方的空白处，
		#   按钮本身一点金都看不见（`shots/probe_fill.png` 就是这么抓出来的）。
		#   ★ 本地坐标同时天然处理了「锚点 / 容器排版把按钮摆在哪儿」——
		#     不管按钮在屏幕哪里、被拉到多大，`(0,0)..size` 永远是它自己。
		#   ★ 取的是**宿主的** `size`：动画器铺满宿主（`PRESET_FULL_RECT`），
		#     两者原点重合，所以这块矩形在两个坐标系里是同一个矩形。
		var r := Rect2(Vector2.ZERO, _button.size)

		# ② 自下而上：填充区 = 这块矩形的**下半部分**（底边不动，顶边随进度往上长）。
		var h: float = r.size.y * fill
		if h < 1.0:
			return
		var region := Rect2(r.position.x, r.position.y + r.size.y - h, r.size.x, h)

		# ③ 纹理按「整块按钮的高度」来配：于是 USED_RECT 一缩，
		#    这一段金就从**整个渐变的最底端**往上截 —— 渐变**不会跟着进度跑**，
		#    底边永远是最深的那一档（要的就是这个：进度只改「露出多少」）。
		var used := Rect2(0.0, 1.0 - fill, 1.0, fill)
		# ★ 这里用局部变量取一次纹理，而不是把 `_ramp` 直接写进调用：
		#   `draw_texture_rect_region()` 那一格要的是 `Texture2D` 类型。
		var ramp: Texture2D = _ramp
		draw_texture_rect_region(ramp, region, used)

		# ④ 那一条「金色的前沿」：填充还没走完时，在顶边上压一条极淡的亮线。
		#    没有它，截止线看着像一块被裁掉色块；有了它才像「一条亮线在往上推」。
		if fill < 0.995:
			draw_rect(Rect2(region.position.x, region.position.y,
				region.size.x, 1.0), Color(1.0, 0.97, 0.86, 0.22), true)

	## 接上鼠标信号（**幂等**：第二次调用只刷新颜色，不再连一遍信号 ——
	## 连两遍的表现是「移开鼠标后进度还是 1」那种查不出来的怪事）。
	func setup_host() -> void:
		var b := _button
		if b == null:
			return
		if not _host_ready:
			_host_ready = true
			b.mouse_entered.connect(_on_mouse_entered)
			b.mouse_exited.connect(_on_mouse_exited)
			b.button_down.connect(_on_button_down)
			b.button_up.connect(_on_button_up)
		_refresh_colors()

	func _process(dt: float) -> void:
		if _button == null or not is_instance_valid(_button):
			set_process(false)
			return
		# ★ 禁用态变了（可点 ⇄ 不可点）要**换档取色**：金 ⇄ 灰。
		if is_grey() != _was_grey:
			_was_grey = is_grey()
			_refresh_colors()
		# ★ `_text_dirty` 是「登记过字色、但还没同步过」那一档（见 `_sync_text()`）。
		if _text_dirty or not _dirty.is_empty():
			_sync_text()
		var goal := _goal()
		if is_equal_approx(_fill, goal):
			# ★★ 已经到目标：仍然把字色同步一遍。
			#   ⚠️ 这一句是**必须的**（用户报的「移出后颜色不反回来」）：进度停在
			#     目标值时下面那条 `_sync_text()` 不会跑，于是「最后一帧的字色」会
			#     永久留在屏幕上 —— 而那一帧恰好是填充刚到满格（暗字）、或者刚退到空
			#     （亮字）的那一帧。只要中途有任何一次没同步上，颜色就卡住了。
			#   ★ 它是幂等的（每次都从原色算起），每帧调也不会「越压越黑」；
			#     真正的开销只有「每帧一次字典遍历 + 几次颜色比较」，可忽略。
			_sync_text()
			return
		# ★★ 动效总开关：关掉 = 一步到位（不播过渡），状态照旧。
		var step := 1.0
		if ThemeRes.animations_enabled():
			step = dt / maxf(0.001, FILL_TIME if goal > _fill else DRAIN_TIME)
		_fill = move_toward(_fill, goal, step)
		_sync_text()
		queue_redraw()

	## 这一帧该填到多少。
	##
	## ★★ 三条档位（本版）：**禁用 = 灰**（需求：不可点的按钮也要有悬停反馈，
	##   只是填灰的）、**启用 = 金且常驻**、**悬停 = 金**。
	## ★ 与被 `set_available(false)` 关掉的那个字段分开记：关掉 = 这个按钮不参与
	##   悬停动效（空槽 / 压根不是按钮），禁用 = 参与，但填灰。
	func _goal() -> float:
		if not _available or _button == null or not is_instance_valid(_button):
			return 0.0
		var can_hover: bool = _hovered and _button.mouse_filter != Control.MOUSE_FILTER_IGNORE
		if _button.disabled:
			# 禁用态：只有鼠标停上来才填（灰），移开就退回去；不算「已启用」。
			return 1.0 if can_hover else 0.0
		if _latched or can_hover:
			return 1.0
		return 0.0

	## 这一帧是不是灰档（禁用 + 已经填起来了一点点）。★ 用「已经填了多少」而不是
	## 「现在禁不禁用」判断：否则「从禁用变成可用」的途中颜色会**中途跳一次金**。
	func is_grey() -> bool:
		return _button != null and is_instance_valid(_button) and _button.disabled


	## ★★ 「这片填充上**只准用原色（那个亮字）**，不许自动换成填充档的暗字」。
	##
	## ⚠️⚠️ **本开关已经作废**（保留着只是为了不动那 9 处调用点）。
	##
	## 它早期的作用是「填满时也强制用亮字」。那条口径**已经被用户推翻**：
	##   用户后来的要求是「**所有**被金压住的字，一律像右下角页签栏那样由白变黑」。
	##   现在字色只有一条规则（见 `_sync_text()`）：金的前沿扫到哪条字，哪条字就翻到
	##   「填充底上那一档」（白 → 黑）。
	## ⇒ 这个字段现在**只是记下来**（读写都不影响画面），`set_prefer_light(false)` 也一样。
	##   ❌ 别照着旧注释去「恢复白字」：白字压在金上正是用户报的那个 bug。
	func set_prefer_light(v: bool) -> void:
		if _prefer_light == v:
			return
		_prefer_light = v
		_sync_text()
		queue_redraw()

	func _on_mouse_entered() -> void:
		_hovered = true

	func _on_mouse_exited() -> void:
		_hovered = false

	## 按下的一瞬间把悬停**钉住**：某些平台（触摸 / 手写笔）按下时鼠标会先「离开」，
	##   不钉的话表现是「按下去背景反而退回去了」—— 手玩的反馈全丢了。
	func _on_button_down() -> void:
		_hovered = true

	func _on_button_up() -> void:
		_hovered = true


	# ---------------- 对外状态 ----------------

	func fill() -> float:
		return _fill


	func latched() -> bool:
		return _latched


	func available() -> bool:
		return _available


	func ramp_texture() -> Texture2D:
		return _ramp

	## 立刻把进度设成一个值（动画会从那里继续）。测试与「不必动画」的场合用它。
	func set_fill(v: float) -> void:
		_fill = clampf(v, 0.0, 1.0)
		_sync_text()
		queue_redraw()


	## 启用 / 弃用。★ 锁定态**常驻满格**（不回落），并与悬停档分开取色（更亮）。
	##
	## ⚠️ 打开锁定时**当场把进度钉到 1**：那一档本来就是「一直亮着」的常驻态，
	##   让它从 0 淡入等于「点了启用还要等两帧才满」——而且**依赖帧**：
	##   无头 / 刚建好还没进 `_process` 的时候，读到的进度就是 0
	##   （实测：战役页关卡行一开始就选中，断言读到 fill=0 而画面其实该是满的）。
	##   关掉的时候不钉（那一下要的就是「渐渐退回去」，见文件头的需求③）。
	## ★ 无论值有没有变，**都要重取色 + 同步字色**：调用点常常每帧重复设同一个值，
	##   而「值没变」并不代表颜色是对的（换档发生在别处时尤其如此）。
	func set_latched(v: bool) -> void:
		var changed := _latched != v
		_latched = v
		if changed and v:
			_fill = 1.0
		_refresh_colors()
		queue_redraw()


	## 允许 / 禁止填充。
	##
	## ⚠️ **禁用态不要用它**：需求要的是「禁用按钮悬停时填**灰**」，那条走
	##   `_goal()` 里的 `_button.disabled` 分支（自动生效）。
	##   这个接口留给「空槽 / 压根不该有动效」的场合。
	func set_available(v: bool) -> void:
		_available = v
		queue_redraw()


	# ---------------- 颜色 ----------------

	## 换渐变色（顶 / 底两端）。只在**换态**（普通 ⇄ 锁定）与初始化时调。
	func set_colors(top: Color, bottom: Color) -> void:
		var g := Gradient.new()
		g.set_color(0, bottom)                   # offset 0 = fill_from（下边）
		g.set_color(1, top)                      # offset 1 = fill_to（上边）
		_ramp.gradient = g
		queue_redraw()


	## 登记一条「压在这片金上的文字」的原色。
	## ★ 不登记的话，填充满格时那条字仍然是原色（暖白压金 = 读不出来）。
	##
	## ⚠️⚠️ **登记完必须当场同步一次**（不能等下一帧 `_process`）：
	##   调用点写的是「我在这一帧把字色设成 X」，而屏幕上那一帧已经用旧色画完了 ——
	##   实测踩到的表现是「记下来了（`base_font_color()` 读得对），但
	##   `get_theme_color("font_color")` 还是引擎默认那一档」：
	##   填满时字也没被压暗（暖白糊在金上），而且**永远**不会补上（因为进度不再变，
	##   `_process` 里那句 `is_equal_approx(_fill, goal) → return` 会提前返回）。
	func on_fill_text(n: Control, base: Color) -> void:
		if n == null:
			return
		if _text.has(n) and _text[n] == base:
			# ★★ 原色没变 —— 但**不能就此 return**：这条字的**渲染色**可能还没同步过。
			#   实测踩到的 bug：命令卡的名字 Label 建出来时是灰的（`text_faint`），
			#   注册时把那个灰登记成「原色」；之后调用点把它改成暖白时，
			#   因为「登记的原色已经==暖白」而提前返回 ⇒ **一次都没写进 Label**
			#   ⇒ 屏幕上一直是灰的（用户报的「3×3 里的字是灰的」）。
			#   所以这里必须照样同步一次（`_sync_text` 幂等，重复调不会越压越黑）。
			_sync_text()
			return
		_text[n] = base
		_front(n)
		_sync_text()


	## 按钮自己的字：★ 一律用这个接口，**不要**再 `add_theme_color_override("font_color", …)`。
	## 直接写 override 会被下一次同步盖掉（进度一变就重算），看起来像「我的颜色没生效」。
	func set_base_font_color(c: Color) -> void:
		on_fill_text(_button, c)


	## ★★ 把**按钮自己那行字**登记成「行模式」：整行共用一个渐变进度。
	##   用于 `Button.text` 那种引擎自己画的整行文字（没法逐字改色）。
	##   要**逐字**渐变请用 `set_char_labels()`。
	func set_row_text(c: Color) -> void:
		on_fill_text(_button, c)
		_row_text_nodes[_button] = true


	## ★★ 逐字渐变：给每个字一颗小 Label，金的前沿扫到哪个字、那个字才变色。
	##   创建出来的 Label 会**登记**进 `_text`，于是 `_sync_text` 会按各自的垂直位置
	##   分别算颜色 —— 这就是「白 → 黑」那条会跟着金色前沿走的斜线。
	##
	## 调用点（`attach_char_text()`）负责调用；这里只管登记。
	func set_char_labels(labels: Array, base: Color) -> void:
		for l in labels:
			var lb := l as Control
			if lb == null:
				continue
			_text[lb] = base
			_front(lb)
		_sync_text()


	func base_font_color(default_color: Color = ThemeRes.text()) -> Color:
		var base: Variant = _text.get(_button, null)
		return base if typeof(base) == TYPE_COLOR else default_color


	## 有登记过的字要重新按当前进度压色（调用点改了原色之后由 `_front()` 抛进来）。
	func _front(n: Node) -> void:
		if _dirty.has(n):
			return
		_dirty.append(n)


	## 换填色档位：锁定 = 更亮的金；禁用 = 灰；其余 = 普通的金。
	## ★ 只在**换态**（普通 / 锁定 / 禁用）时调 —— 不是每帧。
	func _refresh_colors() -> void:
		if _latched:
			_bottom = ThemeRes.fill_bottom_latched()
			_top = ThemeRes.fill_top_latched()
		elif is_grey():
			_bottom = ThemeRes.fill_disabled_bottom()
			_top = ThemeRes.fill_disabled_top()
		else:
			_bottom = ThemeRes.fill_bottom()
			_top = ThemeRes.fill_top()
		set_colors(_top, _bottom)
		_sync_text()


	## 把每一条登记过的字按**当前进度**定成「在那块底上读得出来」的颜色。
	##
	## ★★ 这是修「填充后文字看不见」的地方（用户报的那个）：
	##   字不只是被动地压暗，而是**每帧拿两个候选色去比对比度**
	##     · 原色（暖白那一档）
	##     · 填充底上那一档（暖黑那一档）
	##   比谁在**这一帧真实合成出来的底色**上对比更高，用谁。
	##   ⇒ 「字与金撞成同一个中间调」这件事**从结构上不可能再发生**，
	##     而且换成灰档 / 更亮的启用档也不用重新调阈值（它自己会选）。
	##
	## 底色 = `stylebox(normal) 的底色` 与「已经盖到字那儿的那部分填色」的合成，
	##   位置取**字自己的中心**（而不是按钮中心）：命令卡那种一格两行字
	##   （键位字母贴左上、名字居中）在同一帧拿到的底色本来就不一样。
	##
	## ★ 可重入：每次都从 `_text` 里的**原色**算起，所以重复调用不会越压越黑。
	## ⚠️ 加 `_ramp` 那道闸是为了「还没 `_attach()` 就被调」时不出错
	##   （挂载顺序见 `attach()`：先 `_attach()` 再 `add_child()`）。
	func _sync_text() -> void:
		_dirty.clear()
		if _ramp == null:
			_text_dirty = true
			return
		_text_dirty = false
		var panel := _panel_color()
		for key in _text.keys():
			var n = key
			if not is_instance_valid(n):
				_text.erase(key)
				continue
			var base: Color = _text[key]
			var under := panel.lerp(_bottom, _coverage(n))
			var on_fill := ThemeRes.text_on_fill(_latched, base)
			# ★★ 一条**统一**规则，不再需要调用点传「要不要白字」的开关：
			#
			#   · 原色**比填充档亮**（暖白那类，界面上的绝大多数）⇒ 走
			#     「跟着金色前沿由原色渐变到填充档」：金扫到哪个字、那个字才变 ——
			#     这就是用户要的「白字由下往上由白变黑，和金色线同步」。
			#   · 原色**本来就比填充档暗**（例如科技格已启用那档用的近黑）⇒
			#     渐变方向是「变亮」，在暗底/金底上都不该乱动，保持原色；
			#     真要变也是变暗（下方分支的自动选色），不会把它弄浅。
			#
			# ★ 为什么不再用「比对比度自动选色」当主路：实测它在几处（命令卡 / 下拉选择条）
			#   把底色估错，于是把暖白字**整块**换成近黑 —— 屏幕上就是用户报的
			#   「3×3 的字是灰的」「主界面按钮的字是黑的」。那条路现在只作为
			#   「原色已经比填充档暗」时的兜底。
			var c := base
			# ★★ 逐字翻面（见 `FLIP_LO / FLIP_HI` 那段）：金扫到这条字身上多少，
			#   决定它**整块**是用原色还是填充档 —— 中间不插值（插值会变成看不见的灰）。
			#   ⚠️ 只在「原色比填充档亮」时才翻；本来就暗的（科技格已启用那档）
			#      保持原色，不然会把它弄浅。
			if base.get_luminance() > on_fill.get_luminance():
				var cov := _coverage(n)
				var was: bool = bool(_flipped.get(n, false))
				var now := was
				if _latched:
					now = true
				elif was:
					now = cov > FLIP_LO * 0.5      # 迟滞：翻过之后要退得更多才翻回来
				else:
					now = cov >= FLIP_HI
				_flipped[n] = now
				c = on_fill if now else base
			if n == _button:
				# 宿主按钮：四个态一起给（引擎按当前态挑一个，暖白 → 暖黑不会跳变）
				for slot in ["font_color", "font_hover_color", "font_pressed_color",
						"font_disabled_color"]:
					n.add_theme_color_override(slot, c)
			else:
				n.add_theme_color_override("font_color", c)


	## 这颗按钮**底纹的底色**（填充画在它**下面**）。
	##
	## 优先用调用点**显式给的**（`set_panel_color`）—— 那是唯一准确的来源。
	## 没给的时候只能按「哪一格底纹有底色」猜，猜法是：
	##   取第一个「底色不透明」的槽，再把它按 alpha 合成到主题暗底上
	##   （很多槽是全透明的，那时字底下其实是**更下面那层深色面板**）。
	##
	## ⚠️⚠️ 猜法有两个实测踩到的坑，所以**能显式给就显式给**：
	##   ① 只看 `normal` 不行：按钮 `disabled` 时引擎画的是 `disabled` 那一格
	##      （`card_normal(false)` = `bg_empty()` 是实底，与 normal 的全透明完全不同）；
	##   ② 按「第一个有底的」扫也不行：那可能会扫到**画面上根本没用到**的那一格
	##      （实测：下拉选择条的 `pressed` 是实心金，于是空鼠标时也按「金字底」算，
	##       字色当场选错 —— 用户看到的就是「字变灰了」）。
	func _panel_color() -> Color:
		if _panel_override.a >= 0.0:
			return _panel_override
		# 兜底：游戏里这些面板都坐在主题的深色渐变底上（HUD）或深色渐变页底（菜单），
		# 两者都接近 bg_bottom，用它能同时覆盖两种场合。
		var base := ThemeRes.with_alpha(ThemeRes.bg_bottom(), 1.0)
		if _button == null or not is_instance_valid(_button):
			return base
		for slot in _panel_slots():
			var sb: StyleBox = _button.get_theme_stylebox(slot)
			if sb is StyleBoxFlat:
				var bg := (sb as StyleBoxFlat).bg_color
				if bg.a > 0.001:
					return base.lerp(bg, bg.a)
		return base


	## ★★ 显式告诉填充层「这颗按钮下面是什么底色」（nil = 让填充层自己猜）。
	## 调用点知道得最准，所以**能用就用**：见 `_panel_color()` 里那两条 ⚠️。
	## @param c  没归一化的颜色也行（`a = 0` 会被当成「透出主题暗底」）
	func set_panel_color(c: Color) -> void:
		if c.a >= 0.0:
			_panel_override = ThemeRes.with_alpha(ThemeRes.bg_bottom(), 1.0).lerp(c, c.a) \
				if c.a < 0.999 else c
		_sync_text()
		queue_redraw()


	## 引擎画这颗按钮时**可能用到**的底纹槽，按「当前最可能的那一个」排在前面。
	##
	## ⚠️ 这里只能**猜**：Godot 不暴露「当前实际生效的是哪一格底纹」（那在
	##   `BaseButton::get_draw_mode()` 里，脚本读不到）。好在只要挑到
	##   「**有底色**的那一格」就够准了 —— 挂填充的按钮上这些格子基本同色，
	##   真正的差别只在「透明 vs 有底」。
	##
	## ⚠️⚠️ 还有一个**调用时机**的坑（实测踩到）：`attach_text()` 常常在
	##   「建按钮的中途」就被调（那时 hover / pressed 还没设完），于是那一瞬间
	##   可能挑到别的一格、算出错误的底色。所以 `_panel_color()` 是**每帧**调的
	##   （在 `_sync_text()` 里）—— 下一帧就正了。
	##   ⇒ 别依赖 `attach_text()` 那一瞬间算出来的颜色。
	func _panel_slots() -> Array:
		if _button != null and is_instance_valid(_button) and _button.disabled:
			return ["disabled", "normal", "hover"]
		return ["normal", "hover", "pressed", "disabled"]


	## 这一帧「填色盖到 `n` 身上多少」（0..1）——按 `n` 的**垂直中心**算。
	func _coverage(n: Node) -> float:
		return coverage_of(_button, n, _fill)


	## ★★ 「金色前沿盖到 `n` 的**垂直中心**没有」（0..1）。
	##
	## ★ 做成**静态**函数是为了让「逐字那套」和「单块文字」共用同一个口径 ——
	##   两边各写一份的话，某个字符的翻面时机会和它旁边那条金错开半帧。
	##
	## ⚠️⚠️ `n == b`（宿主按钮自己那行引擎画的字）时**必须**按本地中心算：
	##   宿主的 `position` 是**它在父容器里的位置**，不是按钮内部坐标 ——
	##   按钮被 VBox / CenterContainer 排到下面去之后 `position.y` 会大过 `size.y`，
	##   这条式子的分母被 `maxf(1.0, …)` 夹成 1 ⇒ 进度只要不是 0，覆盖度就是 1
	##   ⇒ 字在**悬停第一帧**就翻黑（金还没上来，字先看不见了），
	##      而且与「金扫到哪儿」完全脱钩。
	##   实测（`tests/probe_fill.gd`，跑完即删）：主界面 test 按钮 pos.y=168 / size.y=80、
	##   战役页第二颗阵营按钮 pos.y=64 / size.y=56 —— 两颗都落在这一档。
	##   ★ 子 Label（页签的逐字 / 命令卡 / 科技格）的 `position` 本来就是**按钮内**坐标，
	##     所以只有宿主那一档要特判。
	static func coverage_of(b: Control, n: Node, fill: float) -> float:
		if b == null or b.size.y <= 1.0:
			return fill
		var c := n as Control
		var center_y := b.size.y * 0.5
		if c != null and c != b:
			center_y = c.position.y + c.size.y * 0.5
		return clampf(fill * b.size.y / maxf(1.0, b.size.y - center_y), 0.0, 1.0)


	# ---------------- 选色用的对比度（内层类自带一份，见 `_sync_text` 里的说明） ----------------

	func _contrast(a: Color, b: Color) -> float:
		var la := _rel(a)
		var lb := _rel(b)
		return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


	func _rel(c: Color) -> float:
		return 0.2126 * _chan(c.r) + 0.7152 * _chan(c.g) + 0.0722 * _chan(c.b)


	func _chan(v: float) -> float:
		if v <= 0.04045:
			return v / 12.92
		return pow((v + 0.055) / 1.055, 2.4)


## ★★ 逐字渐变：把 `b.text` 拆成**一字一颗小 Label**，于是金色前沿扫到哪个字、
##   那个字才从 `base` 渐变到「填充档」（用户要的「白字由下往上由白变黑」）。
##
## 为什么必须逐字拆：`Button.text` 是引擎**一次性**画出来的一整块，脚本没法只改
##   其中一个字的颜色。只有拆成多个 Label 才能做出「跟着那条金色前沿走的斜线」。
##
## ⚠️ 拆完要把 `b.text` 置空，否则引擎还会在底下再画一遍原文（重影）。
##   ★ 调用点若要保留可读的文案（测试 / 无障碍），自己另存一份 —— 本函数不动它。
##
## @param b     宿主按钮
## @param text  要画的文字
## @param font  字体（用来逐字量宽，保证字距与原排版一致）
## @param font_size  字号（★ 必须与按钮上原本的字号一致，否则逐字宽度会算错）
## @param base  原字色（渐变起点）
## @return 创建出来的逐字 Label（调用点通常不用它）
static func attach_char_text(b: Button, text: String, font: Font, font_size: int,
		base: Color) -> Array:
	var anim := attach_draw(b)
	if anim == null or text.length() == 0:
		return []
	var labels: Array = []
	var sizes: Array = []
	var total := 0.0
	for i in text.length():
		var w: float = _advance(font, font_size, text, i)
		sizes.append(w)
		total += w
	var x := (b.size.x - total) * 0.5
	for i in text.length():
		var w: float = sizes[i]
		var l := Label.new()
		l.name = "Char%d" % i
		l.text = text.substr(i, 1)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.size = Vector2(w, b.size.y)
		l.position = Vector2(x, 0.0)
		l.add_theme_font_size_override("font_size", font_size)
		l.add_theme_color_override("font_color", base)
		if font != null:
			l.add_theme_font_override("font", font)
		b.add_child(l)
		labels.append(l)
		x += w
	# ⚠️ 置空 `text`：不然引擎会在这些 Label 底下把整行原文再画一遍（重影）。
	#   ★ 这里**不动**调用点自己存的文案（那是它的数据，不是本控件的）。
	b.text = ""
	anim.set_char_labels(labels, base)
	return labels


## 单个字符的**排版宽度**（用来逐字对齐）。
##
## ⚠️ 字距（kerning）没法单独问，所以用「前 i+1 个字的宽 − 前 i 个字的宽」差分 ——
##   这样总宽天然等于整行的宽，逐字拼回去与引擎原排版一致。
static func _advance(font: Font, font_size: int, text: String, i: int) -> float:
	if font == null:
		return float(font_size) * 0.6
	var w_pre := font.get_string_size(text.substr(0, i),
		HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var w_post := font.get_string_size(text.substr(0, i + 1),
		HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var d := w_post - w_pre
	if d <= 0.0:
		var w_all := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		d = w_all / maxf(1.0, float(text.length()))
	return d


# ------------------------------------------------------------------
# 静态小接口（调用点 / 测试都从这儿读，不必先取动画器）
# ------------------------------------------------------------------

## 挂上「自绘填充」+ 「填充时压字色」这一整套（= `attach_draw` + `setup_host`）。
## ★★ 调用点用这一个：`FillButtonRes.attach_text(cell)`。
static func attach_text(b: Button) -> FillAnimator:
	var anim := attach_draw(b)
	if anim != null:
		anim.setup_host()
		anim.set_base_font_color(_current_font_color(b))
	return anim


## 某颗按钮填了多少（没挂动效 = 0）。
static func fill_progress(b: Button) -> float:
	var a := animator_of(b)
	return 0.0 if a == null else a.fill()


## 立刻设进度（测试 / 不需要动画的场合）。
static func set_fill(b: Button, v: float) -> void:
	var a := animator_of(b)
	if a != null:
		a.set_fill(v)


## 这颗按钮是不是「已启用」的常驻态（页签当前页 / 科技九格里启用的那几格）。
static func is_latched(b: Button) -> bool:
	var a := animator_of(b)
	return a != null and a.latched()


## 置 / 撤「已启用」。★ 锁定态不回落，且取更亮的那一档金 + 更暗的字（需求：亮度变大）。
static func set_latched(b: Button, on: bool) -> void:
	var a := animator_of(b)
	if a != null:
		a.set_latched(on)


## 这颗按钮允不允许填充（禁用态 = false）。
static func set_available(b: Button, on: bool) -> void:
	var a := animator_of(b)
	if a != null:
		a.set_available(on)


## ⚠️ **已作废**（保留只为不改那 9 处调用点）：旧义是「这片填充上只准用亮字」。
##   字色现在只有一条规则 —— 金的前沿扫到哪条字、哪条字就翻成填充档（白 → 黑），
##   见 `_sync_text()` 与 `FillAnimator.set_prefer_light()`。读写都不影响画面。
static func set_prefer_light(b: Button, on: bool) -> void:
	var a := animator_of(b)
	if a != null:
		a.set_prefer_light(on)


## ★★ 显式指定「这颗按钮下面的底色」（调用点比填充层猜得准，见 `_panel_color`）。
static func set_panel_color(b: Button, c: Color) -> void:
	var a := animator_of(b)
	if a != null:
		a.set_panel_color(c)


## 把一条文字挂到按钮的填充上（**按钮自己的字**直接传宿主的 `base_font_color()`）。
static func on_fill_text(host: Button, n: Control, base: Color) -> void:
	var a := animator_of(host)
	if a != null:
		a.on_fill_text(n, base)


## 改宿主按钮自己的字色（★ 替代 `add_theme_color_override("font_color", …)`）。
static func set_base_font_color(b: Button, c: Color) -> void:
	var a := animator_of(b)
	if a != null:
		a.set_base_font_color(c)


## 某颗按钮当前的原字色（探针 / 测试看它现在记着什么）。
static func base_font_color(b: Button, default_color: Color = Color(-1.0, -1.0, -1.0, -1.0)) -> Color:
	var a := animator_of(b)
	var fallback := default_color
	if fallback.a < 0.0:
		fallback = _current_font_color(b)
	return fallback if a == null else a.base_font_color(fallback)


## 按钮**当前挂着**的 `font_color` override（= 屏幕上的字色）。
static func _current_font_color(b: Button) -> Color:
	if b == null:
		return ThemeRes.text()
	var v: Variant = b.get_theme_color("font_color")
	return v if typeof(v) == TYPE_COLOR else ThemeRes.text()
