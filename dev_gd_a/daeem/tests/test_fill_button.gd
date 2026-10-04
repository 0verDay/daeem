## test_fill_button.gd —— ★★ 「按钮悬停：金色自下而上填充 + 渐出 + 启用常驻增亮」的用例
##
## 被验的东西（需求原话）：
##   ① 「鼠标悬停在任何按钮上时，按钮背景都会由空到由下往上填充金色背景」；
##   ② 「需要做渐变效果」—— 那一片金是**竖向渐变**（底 / 顶两档色），不是一块死色；
##   ③ 「悬停结束时的反向渐出效果」—— 鼠标移开后进度要能退回去（不是瞬间消失）；
##   ④ 「点击切换启用时（页签 / 科技九格）将其亮度稍微变大」—— 锁定态常驻满格，
##      而且取的是**更亮**的那一档金。
##
## ★ 为什么单开一个文件（而不是塞进 test_ui.gd）：
##   这套动效是一个**独立部件**（view/fill_button.gd），它不认识任何玩法概念
##   （命令卡 / 科技格 / 页签都只是「挂了它的按钮」）。于是它最该被**独立**验证：
##   这里只建一颗裸 Button，不建世界、不进游戏 —— 失败时排查方向一眼就清楚。
##
## ⚠️⚠️ **本文件刻意全是同步用例**（没有一处 `await`）—— 这是踩出来的：
##   ① 一旦用例变成协程，`run_all()` 里那句 `cases.call()` 就**不能用 await 收尾**
##      （4.7 会报 "Trying to call an async function without await"），
##      用例只跑到第一处 await 就被丢掉，表现是「通过 N 项、退出码 1、没有 FAIL」；
##      改由用例自己发 `cases_done` 收尾时，又遇到「引擎拿的是旧缓存、改动看不见」。
##   ② 而**这里根本不需要真帧**：进度是纯数学（`dt / FILL_TIME`，见 fill_button._process），
##      所以直接拿动画器、手动喂 `_process(dt)` 就能把整条动画跑完 ——
##      快、稳、与渲染无关（无头模式下本来就画不出像素）。
##   ⇒ 要验「真鼠标事件」的那几条，走 `mouse_entered` / `mouse_exited` **信号**
##     （引擎信号，不需要帧）；要验「时间推进」的那几条，走手动 `_process(dt)`。
extends "res://tests/test_case.gd"

const FillButtonRes = preload("res://view/fill_button.gd")
const ThemeRes = preload("res://view/theme.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")

## 用哪条字色当「原色」（与命令卡的名字那一条同一档）。
const BASE_TEXT := Color(0.91, 0.89, 0.835, 1.0)

## 手动喂帧用的步长（= 60fps 一帧的秒数，与真跑起来一致）。
const DT := 1.0 / 60.0


func _initialize() -> void:
	_case_name = "fill_button"
	run_all(_cases)


func _cases() -> void:
	_test_attach()
	_test_fill_layer_is_behind_host()
	_test_hover_fill()
	_test_drain_is_gradual()
	_test_press_holds_hover()
	_test_latched()
	_test_gradient()
	_test_text_on_fill()
	_test_host_text_flip_ignores_container_position()
	_test_legible_across_animation()
	_test_disabled_fills_grey()
	_test_animation_switch()
	_test_text_reverts_after_drain()
	_test_fill_underlay_is_transparent()
	_test_prefer_light()
	_test_char_text()
	_test_available_off()


# ------------------------------------------------------------------
# ① 挂载：一行挂上「自绘填充 + 鼠标跟随 + 文字压色」
# ------------------------------------------------------------------

func _test_attach() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)
	ok(anim != null, "attach_text() 返回了动画器")
	ok(b.has_meta(FillButtonRes.META), "★ 动画器记在按钮的元数据里（画的时候就是靠它找回来）")
	ok(anim == FillButtonRes.animator_of(b), "animator_of() 取回的是同一个动画器")
	eq(FillButtonRes.fill_progress(b), 0.0, "刚开始是**空的**（需求：由空到……）")
	ok(not FillButtonRes.is_latched(b), "刚开始不是「已启用」")

	# ★★ 重复挂：必须还是同一个（多挂一层就等于两个动画器抢同一份进度）
	var again := FillButtonRes.attach_text(b)
	ok(again == anim, "★ 重复 attach_text() 不会挂第二层（同一个动画器）")
	eq(b.get_node_or_null("FillAnimator") == anim, true, "按钮下面只有一层 FillAnimator")
	eq(b.get_meta("fill_draw"), true, "★ 自绘填充的钩子只接一次")

	# ★ 鼠标信号只连一次（连两遍 = 「移开鼠标进度还是 1」那种查不出来的怪事）
	eq(b.mouse_entered.get_connections().size(), 1, "★ mouse_entered 只连了一次")
	eq(b.mouse_exited.get_connections().size(), 1, "★ mouse_exited 只连了一次")

	b.queue_free()


# ------------------------------------------------------------------
# ①b ★★ 那层金**画在宿主下面**（用户报的「字被金色填充遮挡」的根因）
#
# 层次必须是：面板 → 金 → 底纹 → 文字 → 子 Label。
# 旧写法把金画在宿主的 `draw` 信号里，而 Godot 4 的 `draw` 信号是在
# `NOTIFICATION_DRAW`（`Button` 在那里画底纹与文字）**之后**才发的 ——
# 于是金排到了文字后面，整块按钮连同文字一起被糊成一片金：
# 实拍 `shots/probe_campaign_hover.png`：选中的关卡 / 阵营那两颗**一个字都看不见**。
# ------------------------------------------------------------------

func _test_fill_layer_is_behind_host() -> void:
	var b := _new_button()
	b.text = "test"
	var anim := FillButtonRes.attach_text(b)

	eq(anim.get_parent(), b, "★ 填充层是宿主按钮的**子节点**（子节点才有自己的绘制期）")
	ok(anim.show_behind_parent,
		"★★ 填充层 `show_behind_parent` —— 画在宿主底纹 / 文字**之前**，"
		+ "否则那片金会把底纹和文字一起糊掉（用户报的那个 bug）")
	eq(b.draw.get_connections().size(), 0,
		"★★ 宿主**没有**接 `draw` 信号（接那里 = 画在文字之后 = 旧的那条 bug）")
	ok(b.has_meta("fill_draw"), "★ 仍然记着「这颗按钮挂了填充层」")
	# 铺满宿主：填充是按宿主的 size 画的，两个坐标系的原点必须重合
	ok(is_equal_approx(anim.anchor_left, 0.0) and is_equal_approx(anim.anchor_right, 1.0)
			and is_equal_approx(anim.anchor_top, 0.0) and is_equal_approx(anim.anchor_bottom, 1.0),
		"★ 填充层铺满宿主（锚点铺满 = 与按钮同一块矩形）")
	eq(anim.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"★ 填充层不吃鼠标（点按钮还是点在宿主编上）")

	b.queue_free()


# ------------------------------------------------------------------
# ⑦a2 ★★ 宿主那行字的「覆盖度」不许跟着容器排版跑
#
# 旧写法用 `n.position.y` 当字的中心 —— 对**子 Label** 是对的（那是按钮内坐标），
# 但对宿主自己就错了：`Button.position` 是它在**父容器里**的位置。
# 按钮被排到下面去之后 `position.y > size.y`，分母被 `maxf(1.0, …)` 夹成 1
# ⇒ 覆盖度恒为 1 ⇒ 悬停第一帧字就翻黑（金还没上来），与「金扫到哪儿」完全脱钩。
# 实测（`tests/probe_fill.gd`）：主界面 test 按钮 pos.y=168 / size.y=80。
# ------------------------------------------------------------------

func _test_host_text_flip_ignores_container_position() -> void:
	var b := _new_button()
	b.size = Vector2(120.0, 40.0)
	# ★★ 复现真实排版：按钮在容器里被排到很下面（position 远大于 size）
	b.position = Vector2(0.0, 300.0)
	var anim := FillButtonRes.attach_text(b)
	FillButtonRes.set_base_font_color(b, BASE_TEXT)

	# 宿主那行字按**本地中心**算：覆盖度 = 2·fill（与居中的子 Label 同一口径）
	near(FillButtonRes.FillAnimator.coverage_of(b, b, 0.2), 0.4, 0.001,
		"★★ 宿主那行字的覆盖度按**本地中心**算（不再受 `position.y` 影响）")
	near(FillButtonRes.FillAnimator.coverage_of(b, b, 0.5), 1.0, 0.001,
		"★ 金盖到字心时覆盖度 = 1.0")

	# 金只填了一点点的时候，字必须还是原色。
	# ⚠️ 旧写法在这一步就已经翻黑了（屏幕上是「金没到、字先没了」）。
	anim.set_fill(0.2)
	eq(b.get_theme_color("font_color"), BASE_TEXT,
		"★★ 金只填到 20% 时字仍是原色（不会「金还没扫到、字先变黑」）")
	anim.set_fill(0.5)
	ok(b.get_theme_color("font_color") != BASE_TEXT,
		"★ 金盖过字心之后才翻到填充档（白 → 黑，与页签栏同一条口径）")

	# ★ 同一个口径：把按钮挪回左上角，得到的是同一组覆盖度（与位置无关）
	b.position = Vector2.ZERO
	near(FillButtonRes.FillAnimator.coverage_of(b, b, 0.5), 1.0, 0.001,
		"★ 挪到 (0,0) 之后覆盖度不变（这条口径只认按钮自己的高度）")

	b.queue_free()


# ------------------------------------------------------------------
# ② 悬停：从下往上填到满（需求①②）
# ------------------------------------------------------------------

func _test_hover_fill() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)

	# ★ 走引擎自己的信号（与项目里其它「模拟悬停」的用例同一条约定）
	b.mouse_entered.emit()
	eq(FillButtonRes.fill_progress(b), 0.0,
		"★ 悬停信号本身不立刻改进度（改的是**目标**，进度由动画逐帧追）")

	# 半程：进度落在中间 —— 这就是「由空到满」那个过程本身
	anim._process(DT * 6.0)
	var mid := FillButtonRes.fill_progress(b)
	ok(mid > 0.0 and mid < 1.0,
		"★ 半程时进度在中间（%.2f）—— 是**填上去的过程**，不是一帧跳满" % mid)

	# 跑满：进度到 1，并且**不再变**
	var frames: int = _pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) >= 0.999, "★ 鼠标停上去 → 填到满格（%d 帧内）" % frames)
	anim._process(DT)
	ok(FillButtonRes.fill_progress(b) >= 0.999, "★ 填满之后就停在满格（不会溢出去）")

	b.queue_free()


# ------------------------------------------------------------------
# ③ 移开：**反向渐出**（需求③）
# ------------------------------------------------------------------

func _test_drain_is_gradual() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)
	b.mouse_entered.emit()
	_pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) >= 0.999, "（前提）先填满")

	b.mouse_exited.emit()
	anim._process(DT)                          # 只走一帧
	var after_one := FillButtonRes.fill_progress(b)
	ok(after_one < 0.999 and after_one > 0.0,
		"★★ 移开一帧之后**还在退**（%.2f）—— 是渐出，不是瞬间清零" % after_one)

	var frames: int = _pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) <= 0.001, "★ 渐出到头 = 空（再用 %d 帧）" % frames)

	# ★ 渐出比填充**短**（鼠标已经移开了，玩家等的是它快点让开）
	ok(FillButtonRes.DRAIN_TIME < FillButtonRes.FILL_TIME,
		"★ 渐出时长比填充短（%.2f < %.2f）" % [FillButtonRes.DRAIN_TIME, FillButtonRes.FILL_TIME])

	b.queue_free()


# ------------------------------------------------------------------
# ④ 按下：不许把悬停抖掉
# ------------------------------------------------------------------

func _test_press_holds_hover() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)
	anim.set_fill(0.4)

	# 某些平台（触摸 / 手写笔）按下时会先发 mouse_exited —— 那一下不能把金退掉
	b.mouse_exited.emit()
	b.button_down.emit()
	anim._process(DT)
	ok(FillButtonRes.fill_progress(b) > 0.4,
		"★ 按下的一瞬间不会把悬停抖掉（进度继续往上）")

	b.queue_free()


# ------------------------------------------------------------------
# ⑤ 已启用（锁定）：常驻满格 + **更亮**的那一档（需求④）
# ------------------------------------------------------------------

func _test_latched() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)

	FillButtonRes.set_latched(b, true)
	ok(FillButtonRes.is_latched(b), "★ set_latched(true) 之后是锁定态")
	# ★ 锁定态**没有悬停**也要自己填到满
	var frames: int = _pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) >= 0.999,
		"★ 锁定态自己填到满格（%d 帧）——「点了启用就一直亮着」" % frames)

	# ★★ 不许回落：鼠标移开照旧满格
	b.mouse_exited.emit()
	_pump(anim, 10)
	ok(FillButtonRes.fill_progress(b) >= 0.999, "★★ 鼠标移开也不回落（已启用 = 常驻）")

	# ★ 亮度：锁定那一档的两端都要比悬停档**更亮**
	var normal_lum: float = ThemeRes.fill_bottom().get_luminance()
	var latched_lum: float = ThemeRes.fill_bottom_latched().get_luminance()
	ok(latched_lum > normal_lum + 0.05,
		"★★ 已启用那一档明显更亮（%.3f → %.3f）——需求：点击启用时亮度稍微变大"
		% [normal_lum, latched_lum])
	ok(ThemeRes.fill_top_latched().get_luminance() > ThemeRes.fill_top().get_luminance(),
		"★ 渐变的两端都跟着亮（不是只有底边）")

	# ★ 弃用之后要能退回空
	FillButtonRes.set_latched(b, false)
	ok(not FillButtonRes.is_latched(b), "set_latched(false) 之后不是锁定态")
	_pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) <= 0.001, "★ 弃用之后渐出退回空")

	b.queue_free()


# ------------------------------------------------------------------
# ⑥ 那是一片**竖向渐变**（需求②）
# ------------------------------------------------------------------

func _test_gradient() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)

	var tex := anim.ramp_texture()
	ok(tex is GradientTexture2D, "填充用的是一张 GradientTexture2D（不是一块死色）")
	if tex is GradientTexture2D:
		var gt := tex as GradientTexture2D
		ok(gt.gradient != null, "它有渐变对象")
		if gt.gradient != null:
			var g: Gradient = gt.gradient
			var top: Color = g.sample(1.0)
			var bottom: Color = g.sample(0.0)
			ok(top != bottom,
				"★ 两端颜色**不同**（顶 %s / 底 %s）" % [str(top), str(bottom)])
			ok(bottom.get_luminance() > top.get_luminance(),
				"★ 底下那一端更亮（金自下而上填进来，底边最实）")
		# ★ fill_from 在下边、fill_to 在上边 ⇒ 这是一条**竖直**渐变
		ok(gt.fill_from.y > gt.fill_to.y,
			"★ 渐变方向是**竖直**的（fill_from 在下、fill_to 在上）")

	# 换色：锁定态必须真的换掉那对颜色（否则「增亮」只是自说自话）
	var before: Color = (anim.ramp_texture() as GradientTexture2D).gradient.sample(0.0)
	anim.set_latched(true)
	var after: Color = (anim.ramp_texture() as GradientTexture2D).gradient.sample(0.0)
	ok(after != before, "★ 切到锁定态时渐变**换了一对颜色**（不是同一张纹理）")
	ok(after.get_luminance() > before.get_luminance(), "★ 而且新那一对更亮")

	# ★ 进度为 0 时不该画（`draw_fill` 直接返回）——这一步不许报错
	anim.set_fill(0.0)
	FillButtonRes.draw_fill(b)
	ok(true, "★ 进度为 0 时 draw_fill() 直接返回（不画）")

	b.queue_free()


# ------------------------------------------------------------------
# ⑦ 填满时字要压成暖黑（否则暖白压金读不出来）
# ------------------------------------------------------------------

func _test_text_on_fill() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)
	FillButtonRes.set_base_font_color(b, BASE_TEXT)

	eq(FillButtonRes.base_font_color(b), BASE_TEXT, "按钮的**原字色**被记下来了")
	eq(b.get_theme_color("font_color"), BASE_TEXT, "★ 没填充时字还是原色")

	# ★★ 判据是**对比度**（WCAG 那套算在 0~1 的 sRGB 上：1.73 = 暖白压金，读不出来），
	#   不是「亮度小于某个数」——后者会因为填充金本身的底色深浅而失真。
	var fill := ThemeRes.fill_bottom()
	var naked := _contrast(BASE_TEXT, fill)
	ok(naked < 2.5, "（前提）暖白字直接压在那片金上读不出来（对比度 %.2f）" % naked)

	anim.set_fill(1.0)
	var on_fill := b.get_theme_color("font_color")
	var fixed := _contrast(on_fill, fill)
	ok(fixed > naked + 1.0,
		"★★ 填满时字被压暗（对比度 %.2f → %.2f）" % [naked, fixed])
	ok(fixed >= 4.0,
		"★★ 而且 4:1 以上 —— 11~15 号的小字也读得出来（%.2f）" % fixed)

	# ★★ 本来就是**暗色**的原色**不许被压亮**（实测踩过：页签 / 战役页那些按钮上
	#   本来就挂着近黑的 `text_on_accent`，硬压会把它们拉到比原来更亮，字反而变糊）。
	var dark_base := ThemeRes.text_on_accent()
	eq(ThemeRes.text_on_fill(false, dark_base), dark_base,
		"★★ 已经很暗的原色原样返回（压暗只对「比目标更亮」的字生效）")
	ok(ThemeRes.text_on_fill(false, dark_base).get_luminance()
			<= dark_base.get_luminance() + 0.0001,
		"★ 也就是说：压暗**永远不会把字弄浅**")

	# ★ 可重入：同一个进度再同步一遍，字色不该越压越黑
	anim.set_fill(1.0)
	eq(b.get_theme_color("font_color"), on_fill,
		"★ 重复同步不会越压越黑（每次都从原色算起）")

	# ★ 原色真的变了，字色跟着变
	FillButtonRes.set_base_font_color(b, Color(0.6, 0.6, 0.6, 1.0))
	anim.set_fill(0.999)
	ok(b.get_theme_color("font_color") != on_fill,
		"★ 换一个原色之后，填充态的字色跟着换（没有写死一个值）")

	# ★ 四个态都要给（引擎按当前态挑一个；只给 font_color 会在悬停时跳回暖白），
	#   而且**两条语义色**（键位字母是暗金、名字是暖白）压完要一样深
	for slot in ["font_color", "font_hover_color", "font_pressed_color"]:
		var c: Color = b.get_theme_color(slot)
		ok(_contrast(c, fill) >= 4.0,
			"★ %s 也压到够对比了（%.2f）" % [slot, _contrast(c, fill)])
	var dark_a := ThemeRes.text_on_fill(false, ThemeRes.accent())
	var dark_b := ThemeRes.text_on_fill(false, ThemeRes.text())
	near(dark_a.get_luminance(), dark_b.get_luminance(), 0.01,
		"★ 不同原色压完**一样深**（暗金键位字母 0x%s vs 暖白名字）"
		% ThemeRes.accent().to_html(false))

	# ★ 启用档的金更亮 ⇒ 字要更暗，对比度不能掉下来
	var latched_fill := ThemeRes.fill_bottom_latched()
	var latched_text := ThemeRes.text_on_fill(true, BASE_TEXT)
	ok(_contrast(latched_text, latched_fill) >= 3.0,
		"★★ 启用（更亮的金）那一档的字也够对比（%.2f）"
		% _contrast(latched_text, latched_fill))

	# ★ 子 Label（命令卡的键位字母 / 科技格那两行字）也要跟着压
	var child := Label.new()
	child.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(child)
	FillButtonRes.on_fill_text(b, child, BASE_TEXT)
	anim.set_fill(1.0)
	ok(_contrast(child.get_theme_color("font_color"), fill) >= 4.0,
		"★ 子 Label 的字色也被压暗了（不是只管按钮自己的字）")

	b.queue_free()


# ------------------------------------------------------------------
# ⑦b ★★ 全程序可读性：**不许有任何一段进度让字与底撞色**
#
# 这是照着一个真实报障写的用例：「按钮被金色填充后，里面的文字会看不见，
# 似乎被直接遮挡了」。实测真因不是遮挡，而是**对比度在中途塌了** ——
# 旧实现让字色与那片金按同一条曲线对向插值，fill≈0.4~0.5 时两者撞成
# 同一个中间调（最差 1.09:1，WCAG 里 1:1 = 完全同色）。
# ⇒ 现在字色是「每帧比对比度选色」（见 fill_button._sync_text）。
#   这条用例把 0..1 扫一遍，任何一段低于下限就红。
# ------------------------------------------------------------------

func _test_legible_across_animation() -> void:
	var b := _new_button()
	b.size = Vector2(120.0, 60.0)
	var anim := FillButtonRes.attach_text(b)
	# 给一个**真实的底纹**（命令卡那一档：透明底 + 金线），让合成底色是真的
	b.add_theme_stylebox_override("normal", UiStyleRes.card_normal(true))
	FillButtonRes.set_base_font_color(b, ThemeRes.text())

	var worst := 99.0
	var worst_at := 0.0
	# ★ 字底下真实的底：**面板暗底**（命令卡格子是全透明底纹，实际坐在底栏上）
	#   ⇄ 填充金。覆盖比例按**字自己的中心**算（与 fill_button._coverage 同一口径）：
	#   字在垂直中心 ⇒ 覆盖 = 2·fill。命令卡那一格的字是居中的，所以就是这个关系。
	var panel := ThemeRes.with_alpha(ThemeRes.bg_bottom(), 1.0)
	for i in range(51):
		var f := float(i) / 50.0
		anim.set_fill(f)
		var glyph: Color = b.get_theme_color("font_color")
		var under := panel.lerp(ThemeRes.fill_bottom(), clampf(f * 2.0, 0.0, 1.0))
		var ratio := _contrast(glyph, under)
		if ratio < worst:
			worst = ratio
			worst_at = f
	# ★ 实测下限 2.80:1（fill≈0.38）—— 这是「逐字翻面」（`FLIP_HI`）能达到的上限：
	#   翻面**之前**那一瞬，亮字压在「已经盖了大半的金」上，是整条动画最差的一刻。
	#   再早翻面 = 「金还没扫到、字先黑了」；再晚翻面 = 亮字更读不出来。
	#   ★ 旧实现（字色与金按同一条曲线对向 lerp）在同一位置只有 **1.09:1**
	#     —— 那正是用户看到的「字被填充盖住了」。
	ok(worst >= 2.8,
		"★★ 整条填充动画里，字与底最差也有 %.2f:1（在 fill=%.2f）—— 不会「看不见」"
		% [worst, worst_at])

	# ★ 满格必须足够清楚（这是停留时间最长的状态）
	anim.set_fill(1.0)
	var full := _contrast(b.get_theme_color("font_color"), ThemeRes.fill_bottom())
	ok(full >= 4.5, "★★ 满格时字与金有 %.2f:1（正文级）" % full)

	# ★ 空的时候字是原色（不能为了「填满时好看」把常态也改暗）
	anim.set_fill(0.0)
	eq(b.get_theme_color("font_color"), ThemeRes.text(),
		"★ 没填充时字仍是原色（不受填充逻辑影响）")

	b.queue_free()


# ------------------------------------------------------------------
# ⑦c ★★ 禁用态：填的是**灰**，不是金（需求）
# ------------------------------------------------------------------

func _test_disabled_fills_grey() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)
	FillButtonRes.set_base_font_color(b, ThemeRes.text())

	# 可点的时候：填金
	b.mouse_entered.emit()
	_pump(anim, 40)
	var gold: Color = anim.ramp_texture().gradient.sample(0.0)
	ok(gold.r > gold.b, "（前提）可点的时候填的是**金**（R > B，0x%s）" % gold.to_html(false))

	# 禁用：鼠标移开再停上去，应该填灰
	b.mouse_exited.emit()
	_pump(anim, 40)
	b.disabled = true
	b.mouse_entered.emit()
	_pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) >= 0.999,
		"★★ 禁用按钮也有悬停反馈（停上去照样填起来）")
	var grey: Color = anim.ramp_texture().gradient.sample(0.0)
	ok(absf(grey.r - grey.b) < 0.06,
		"★★ 但填的是**灰**（R≈B，0x%s）—— 一眼看出不是「能点」的金" % grey.to_html(false))
	ok(grey.r >= 0.25 and grey.r <= 0.65,
		"★ 灰要够亮：与深色面板分得开（L=%.2f）" % grey.get_luminance())

	# 移开就退回去（禁用态的反馈是**悬停式**的，不会常驻）
	b.mouse_exited.emit()
	_pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) <= 0.001, "★ 鼠标移开就退回去（不是常驻）")

	# 字压在灰上也要读得出来
	b.mouse_entered.emit()
	_pump(anim, 40)
	var glyph: Color = b.get_theme_color("font_color")
	ok(_contrast(glyph, grey) >= 3.0,
		"★★ 灰底上的字也有 %.2f:1" % _contrast(glyph, grey))

	b.queue_free()


# ------------------------------------------------------------------
# ⑦d ★★ 动效总开关（需求：给填充动效一个统一开关）
# ------------------------------------------------------------------

func _test_animation_switch() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)
	ok(ThemeRes.animations_enabled(), "默认是开着的")

	# 关掉之后：**一帧**就该到位（而不是慢慢填）
	ThemeRes.set_animations_enabled(false)
	ok(not ThemeRes.animations_enabled(), "能关掉")
	b.mouse_entered.emit()
	anim._process(DT)
	ok(FillButtonRes.fill_progress(b) >= 0.999,
		"★★ 关掉之后一帧就填满（不播过渡：fill=%.2f）" % FillButtonRes.fill_progress(b))
	b.mouse_exited.emit()
	anim._process(DT)
	ok(FillButtonRes.fill_progress(b) <= 0.001,
		"★★ 移开也是一帧退回去（状态照常切换，只是没有过渡）")

	# 打开之后：恢复逐帧推进
	ThemeRes.set_animations_enabled(true)
	b.mouse_entered.emit()
	anim._process(DT)
	var partial := FillButtonRes.fill_progress(b)
	ok(partial > 0.0 and partial < 1.0,
		"★ 打开之后又变成逐帧推进（半程 %.2f）" % partial)
	_pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) >= 0.999, "★ 照样能填满")

	# ★ 开关**不改状态**：启用态该亮还是亮
	FillButtonRes.set_latched(b, true)
	ThemeRes.set_animations_enabled(false)
	ok(FillButtonRes.is_latched(b) and FillButtonRes.fill_progress(b) >= 0.999,
		"★ 关掉动效不影响「已启用」这个状态")
	ThemeRes.set_animations_enabled(true)

	b.queue_free()


# ------------------------------------------------------------------
# ⑦e ★★ 回归：移开之后字色**必须回到原色**（用户报的「移出时颜色不反回来」）
#
# 旧实现的病根：`_process` 里「已经到目标就 return」那条提前返回，
# 让**停在目标值之后**再也不会同步字色 —— 最后一帧的字色永久留在屏幕上。
# ------------------------------------------------------------------

func _test_text_reverts_after_drain() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)
	FillButtonRes.set_base_font_color(b, BASE_TEXT)
	# 子 Label 也挂上（命令卡 / 科技格那种两行字）
	var child := Label.new()
	child.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(child)
	FillButtonRes.on_fill_text(b, child, BASE_TEXT)

	var original := b.get_theme_color("font_color")
	var child_original := child.get_theme_color("font_color")
	eq(original, BASE_TEXT, "（前提）起手是原色")

	# 悬停 → 填满
	b.mouse_entered.emit()
	_pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) >= 0.999, "（前提）填满了")
	ok(b.get_theme_color("font_color") != original,
		"★ 填满时字色换成了填充档（暗字）—— 否则这条回归没意义")

	# 移开 → 退回去，并且字色**回到原色**
	b.mouse_exited.emit()
	_pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) <= 0.001, "（前提）退回到空")
	eq(b.get_theme_color("font_color"), original,
		"★★ 移开之后按钮字色回到原色（用户报的「颜色不反回来」）")
	eq(child.get_theme_color("font_color"), child_original,
		"★★ 子 Label 的字色也回到原色")

	# ★ 再多喂几帧（模拟鼠标停在外面不动）：颜色不许自己又变
	_pump(anim, 10)
	eq(b.get_theme_color("font_color"), original,
		"★ 停在外面时颜色稳定（每帧同步是幂等的，不会漂）")

	# ★ 四个态都要还原（只还原 font_color 的话，悬停那一档会跳回暗字）
	for slot in ["font_hover_color", "font_pressed_color", "font_disabled_color"]:
		eq(b.get_theme_color(slot), original, "★ %s 也还原了" % slot)

	b.queue_free()


# ------------------------------------------------------------------
# ⑦f ★★ 回归：「填充层在文字之上」——底纹不许自己铺实底
#
# 填充层画在**底纹下面**，所以只要底纹铺了实底，那片金就被盖住，
# 观感就是「填充压在文字上」。钉住：挂了填充的那几档底纹必须**全透明**。
#
# ★★ 本版补上了**命令卡**与**部队列表**那三档（`card_hover` / `card_pressed` /
#   `row_hover`）：它们的格子 / 行也全都挂了填充层，原来铺的是 0.92 的暗底 ——
#   在旧层次（金画在底纹上面）下看不出来；层次改正之后它就会把金压在下面。
# ------------------------------------------------------------------

func _test_fill_underlay_is_transparent() -> void:
	var cases := {
		"页签-普通": UiStyleRes.tab_plain(),
		"页签-当前页": UiStyleRes.tab_latched(),
		"科技格-普通": UiStyleRes.tech_fill(),
		"科技格-已启用": UiStyleRes.tech_latched(),
		"设置按钮-常态": UiStyleRes.accent_button_clear(),
		"设置按钮-展开": UiStyleRes.accent_button_latched(),
		"命令卡-悬停": UiStyleRes.card_hover(),
		"命令卡-按下": UiStyleRes.card_pressed(),
		"部队行-悬停": UiStyleRes.row_hover(),
		"线框按钮-悬停": MenuThemeRes.button_hover_clear(),
		"菜单行-选中": MenuThemeRes.button_fill_latched(),
	}
	for tag in cases.keys():
		var sb: StyleBoxFlat = cases[tag]
		ok(sb.bg_color.a <= 0.001,
			"★★ %s 的底纹是**全透明**（实底会把填充盖住 → 看起来像「填充在文字上」）"
			% tag)
		ok(sb.border_color.r > sb.border_color.b, "★ %s 的描边仍是金色（R > B）" % tag)

	# ★ 反过来：**没挂填充**的档必须仍是不透明 / 半透明的实底（否则地图透出来）
	ok(UiStyleRes.tab_normal().bg_color.a > 0.2,
		"★ 没有填充层的那一档（tab_normal）仍要有底色")
	ok(UiStyleRes.accent_button().bg_color.a > 0.9,
		"★ accent_button（实心金那一档）仍是实底 —— 它给没挂填充的按钮用")


# ------------------------------------------------------------------
# ⑦g ★★ 「白字跟着金色前沿渐变」那一档（页签 / 设置按钮 / 主界面按钮）
# ------------------------------------------------------------------

func _test_prefer_light() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)
	FillButtonRes.set_base_font_color(b, BASE_TEXT)

	anim.set_fill(1.0)
	ok(b.get_theme_color("font_color") != BASE_TEXT,
		"（前提）默认会自动换成填充档的暗字")

	# ★★ 字色的**统一口径**（用户要求）：「金的前沿扫到哪个字，那个字由白变黑」。
	#   ⚠️ 实现是**逐字翻面**（`FLIP_LO/HI`），不是逐字 lerp ——
	#      lerp 到一半时字是中间灰，而那时底色正好是半明半暗的金，
	#      两者亮度几乎相同（实测 1.0:1，字直接消失）。所以这里钉的是：
	#      **要么是原色、要么是填充档，不许出现第三个中间色**。
	anim.set_fill(0.0)
	eq(b.get_theme_color("font_color"), BASE_TEXT,
		"★★ 没填充时是纯原色（亮字）")
	anim.set_fill(0.5)
	var mid: Color = b.get_theme_color("font_color")
	var dark := ThemeRes.text_on_fill(false, BASE_TEXT)
	ok(mid == BASE_TEXT or mid == dark,
		"★★ 半程也只可能是「原色」或「填充档」二者之一（实际 %s）—— 不许有中间灰"
		% mid.to_html(false))
	ok(mid.get_luminance() >= dark.get_luminance(),
		"★ 而且不会比填充档更暗")
	anim.set_fill(1.0)
	ok(b.get_theme_color("font_color") != BASE_TEXT,
		"★ 满格时到填充档（金盖满，白字必须让位）")

	b.queue_free()


# ------------------------------------------------------------------
# ⑦h ★★ 逐字渐变：金的前沿扫到哪个字、那个字才变色（用户需求原文）
# ------------------------------------------------------------------

func _test_char_text() -> void:
	var b := _new_button()
	FillButtonRes.attach_text(b)
	var f: Font = b.get_theme_font("font")
	var labels := FillButtonRes.attach_char_text(b, "操作", f, 17, BASE_TEXT)
	eq(labels.size(), 2, "★ 两个字拆成两颗 Label")
	eq(b.text, "", "★ 按钮自己的 text 被置空（否则引擎会在逐字 Label 底下重画一遍）")

	var l0: Label = labels[0]
	var l1: Label = labels[1]
	var anim := FillButtonRes.animator_of(b)
	# 金盖到一半：两颗字的进度应当**不同** —— 这就是「斜线」而不是整块翻面
	anim.set_fill(0.5)
	var c0: Color = l0.get_theme_color("font_color")
	var c1: Color = l1.get_theme_color("font_color")
	ok(c0 != c1 or absf(c0.get_luminance() - c1.get_luminance()) < 0.4,
		"★ 横排两字进度接近（渐变沿**竖直**方向，不沿水平）")

	anim.set_fill(0.0)
	eq(l0.get_theme_color("font_color"), BASE_TEXT, "★ 没填充时是原色")
	anim.set_fill(1.0)
	ok(l0.get_theme_color("font_color") != BASE_TEXT,
		"★ 填满时变成填充档（金盖过之后才变）")

	# ★★ 关键：**行内的两个字**在同一帧应当同色（金是自下而上的水平前沿），
	#   而「上下两行」才会不同 —— 这里只能用一颗按钮验证「同一行同色」。
	anim.set_fill(0.5)
	ok(absf(l0.get_theme_color("font_color").get_luminance()
			- l1.get_theme_color("font_color").get_luminance()) < 0.4,
		"★★ 同一行的字进度一致（渐变只沿竖直方向）")

	b.queue_free()


# ------------------------------------------------------------------
# ⑧ `set_available(false)`：整个动效关掉（空槽那种，不是「禁用」）
# ------------------------------------------------------------------

func _test_available_off() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)

	b.mouse_entered.emit()
	_pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) >= 0.999, "（前提）开着的时候能填满")

	# ★ `set_available(false)` = 这个按钮**完全不参与**动效（空槽那种）
	FillButtonRes.set_available(b, false)
	var frames: int = _pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) <= 0.001,
		"★ set_available(false) → 退回空（用了 %d 帧）" % frames)

	b.mouse_exited.emit()
	b.mouse_entered.emit()
	_pump(anim, 20)
	ok(FillButtonRes.fill_progress(b) <= 0.001,
		"★★ 关掉的按钮，鼠标停上去也**一点不填**（空槽不能看着像能点）")

	# ★★ 直接在 `disabled` 的按钮上也要能填灰（这是需求④的那条路：
	#   命令卡置灰的格子 / 地图选择条被禁用时都走它，**不**经过 set_available）。
	FillButtonRes.set_available(b, true)
	b.disabled = true
	b.mouse_exited.emit()
	b.mouse_entered.emit()
	_pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) >= 0.999,
		"★★ `disabled = true` 的按钮照样能填（用来做灰色悬停反馈）")

	b.queue_free()


# ------------------------------------------------------------------
# 小工具
# ------------------------------------------------------------------

## 建一颗挂好动效的裸按钮（每个用例自己建、自己 `queue_free`）。
func _new_button() -> Button:
	var b := Button.new()
	b.size = Vector2(100.0, 60.0)
	root.add_child(b)
	return b


## 手动推进动画（每次一帧的量），最多 `budget` 帧；返回实际喂了几帧。
## ★ 为什么可以直接喂 `_process(dt)`：进度是**纯数学**（`dt / FILL_TIME`，见
##   fill_button 的 `_process`），与渲染无关 —— 于是这条用例不需要真帧、
##   也不受「无头 / 引擎拿旧缓存」影响。带上限是为了「条件永远不成立」时不挂死。
func _pump(anim, budget: int) -> int:
	var n := 0
	while n < budget:
		var before: float = anim.fill()
		anim._process(DT)
		n += 1
		if is_equal_approx(before, float(anim.fill())):
			break
	return n


## WCAG 对比度（在 0~1 的 sRGB 上算，与设计规范同一把尺）。
## ★ 不用 `Color.get_luminance()`：那个是 gamma 2.2 近似，拿来算对比度会偏乐观
##   （实测：暖白压填充金，两者差 1.73 vs 2.77）——认定「读不读得出来」要用这一把。
func _contrast(a: Color, b: Color) -> float:
	var la := _relative(a)
	var lb := _relative(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


func _relative(c: Color) -> float:
	return 0.2126 * _chan(c.r) + 0.7152 * _chan(c.g) + 0.0722 * _chan(c.b)


func _chan(v: float) -> float:
	if v <= 0.04045:
		return v / 12.92
	return pow((v + 0.055) / 1.055, 2.4)
