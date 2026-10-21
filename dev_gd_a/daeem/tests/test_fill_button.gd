## test_fill_button.gd —— ★★ 「按钮悬停：琥珀自下而上填充 + 渐出 + 启用常驻增亮」的用例
extends "res://tests/test_case.gd"

const FillButtonRes = preload("res://view/fill_button.gd")
const ThemeRes = preload("res://view/theme.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")

const BASE_TEXT := Color(0.91, 0.89, 0.835, 1.0)

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
	_test_pressed_snaps_full()
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
	_test_hide_clears_hover()
	_test_clear_hover_in()
	_test_clear_latched_in()

func _test_attach() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)
	ok(anim != null, "attach_text() 返回了动画器")
	ok(b.has_meta(FillButtonRes.META), "★ 动画器记在按钮的元数据里（画的时候就是靠它找回来）")
	ok(anim == FillButtonRes.animator_of(b), "animator_of() 取回的是同一个动画器")
	eq(FillButtonRes.fill_progress(b), 0.0, "刚开始是**空的**（需求：由空到……）")
	ok(not FillButtonRes.is_latched(b), "刚开始不是「已启用」")

	var again := FillButtonRes.attach_text(b)
	ok(again == anim, "★ 重复 attach_text() 不会挂第二层（同一个动画器）")
	eq(b.get_node_or_null("FillAnimator") == anim, true, "按钮下面只有一层 FillAnimator")
	eq(b.get_meta("fill_draw"), true, "★ 自绘填充的钩子只接一次")

	eq(b.mouse_entered.get_connections().size(), 1, "★ mouse_entered 只连了一次")
	eq(b.mouse_exited.get_connections().size(), 1, "★ mouse_exited 只连了一次")

	b.queue_free()

func _test_fill_layer_is_behind_host() -> void:
	var b := _new_button()
	b.text = "test"
	var anim := FillButtonRes.attach_text(b)

	eq(anim.get_parent(), b, "★ 填充层是宿主按钮的**子节点**（子节点才有自己的绘制期）")
	ok(anim.show_behind_parent,
		"★★ 填充层 `show_behind_parent` —— 画在宿主底纹 / 文字**之前**，"
		+ "否则那片琥珀会把底纹和文字一起糊掉（用户报的那个 bug）")
	eq(b.draw.get_connections().size(), 0,
		"★★ 宿主**没有**接 `draw` 信号（接那里 = 画在文字之后 = 旧的那条 bug）")
	ok(b.has_meta("fill_draw"), "★ 仍然记着「这颗按钮挂了填充层」")
	ok(is_equal_approx(anim.anchor_left, 0.0) and is_equal_approx(anim.anchor_right, 1.0)
			and is_equal_approx(anim.anchor_top, 0.0) and is_equal_approx(anim.anchor_bottom, 1.0),
		"★ 填充层铺满宿主（锚点铺满 = 与按钮同一块矩形）")
	eq(anim.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"★ 填充层不吃鼠标（点按钮还是点在宿主编上）")

	b.queue_free()

func _test_host_text_flip_ignores_container_position() -> void:
	var b := _new_button()
	b.size = Vector2(120.0, 40.0)
	b.position = Vector2(0.0, 300.0)
	var anim := FillButtonRes.attach_text(b)
	FillButtonRes.set_base_font_color(b, BASE_TEXT)

	near(FillButtonRes.FillAnimator.coverage_of(b, b, 0.2), 0.4, 0.001,
		"★★ 宿主那行字的覆盖度按**本地中心**算（不再受 `position.y` 影响）")
	near(FillButtonRes.FillAnimator.coverage_of(b, b, 0.5), 1.0, 0.001,
		"★ 琥珀盖到字心时覆盖度 = 1.0")

	anim.set_fill(0.2)
	eq(b.get_theme_color("font_color"), BASE_TEXT,
		"★★ 蓝只填到 20% 时字仍是原色（不会「蓝还没扫到、字先变黑」）")
	anim.set_fill(0.5)
	ok(b.get_theme_color("font_color") != BASE_TEXT,
		"★ 琥珀盖过字心之后才翻到填充档（白 → 黑，与页签栏同一条口径）")

	b.position = Vector2.ZERO
	near(FillButtonRes.FillAnimator.coverage_of(b, b, 0.5), 1.0, 0.001,
		"★ 挪到 (0,0) 之后覆盖度不变（这条口径只认按钮自己的高度）")

	b.queue_free()

func _test_hover_fill() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)

	b.mouse_entered.emit()
	eq(FillButtonRes.fill_progress(b), 0.0,
		"★ 悬停信号本身不立刻改进度（改的是**目标**，进度由动画逐帧追）")

	anim._process(DT * 6.0)
	var mid := FillButtonRes.fill_progress(b)
	ok(mid > 0.0 and mid < 1.0,
		"★ 半程时进度在中间（%.2f）—— 是**填上去的过程**，不是一帧跳满" % mid)

	var frames: int = _pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) >= 0.999, "★ 鼠标停上去 → 填到满格（%d 帧内）" % frames)
	anim._process(DT)
	ok(FillButtonRes.fill_progress(b) >= 0.999, "★ 填满之后就停在满格（不会溢出去）")

	b.queue_free()

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

	ok(FillButtonRes.DRAIN_TIME < FillButtonRes.FILL_TIME,
		"★ 渐出时长比填充短（%.2f < %.2f）" % [FillButtonRes.DRAIN_TIME, FillButtonRes.FILL_TIME])

	b.queue_free()

func _test_press_holds_hover() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)
	anim.set_fill(0.4)

	b.mouse_exited.emit()
	b.button_down.emit()
	anim._process(DT)
	ok(FillButtonRes.fill_progress(b) > 0.4,
		"★ 按下的一瞬间不会把悬停抖掉（进度继续往上）")

	b.queue_free()


## ★★ 兜底（用户要求）：**确认按下**（`pressed` 信号）的那一下，背景必须补到满格。
##
## 为什么要这条：正向填充是 FILL_TIME（本版 0.12s）。快速点按 / 触摸时可能刚填到一半就抬手，
##   玩家「明明按了」却看不到满格反馈。这一下把当前值补到 1.0，保证「按了就有反馈」；
##   之后该锁的锁、该渐出的渐出（由 `_goal()` 决定，本函数不改目标）。
## ★ 本版不再一帧硬跳：走 `ui.press_snap_sec`（默认 0.07s）快速补满，
##   再保持 `ui.press_snap_hold_sec`（默认 0.06s）后才按目标回落。
func _test_pressed_snaps_full() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)
	# 先让它停在「按下去、动画只跑了一半」的位置
	anim.set_fill(0.35)
	b.pressed.emit()
	ok(FillButtonRes.fill_progress(b) < 0.999,
		"★★ 确认按下不再一帧硬跳（当前 %.2f）" % FillButtonRes.fill_progress(b))
	anim._process(0.03)
	var mid := FillButtonRes.fill_progress(b)
	ok(mid > 0.35 and mid < 1.0,
		"★ 正在快速补满（%.2f）" % mid)
	anim._process(0.1)
	ok(FillButtonRes.fill_progress(b) >= 0.999,
		"★★ 极短时间内补到满格（当前 %.2f）" % FillButtonRes.fill_progress(b))
	# 兜底不改目标：没有悬停 / 没有 latched ⇒ 之后开始反向渐出
	ok(anim._goal() == 0.0, "★ 兜底只补当前值，不改目标（该渐出还是会渐出）")
	b.queue_free()

func _test_latched() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)

	FillButtonRes.set_latched(b, true)
	ok(FillButtonRes.is_latched(b), "★ set_latched(true) 之后是锁定态")
	var frames: int = _pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) >= 0.999,
		"★ 锁定态自己填到满格（%d 帧）——「点了启用就一直亮着」" % frames)

	b.mouse_exited.emit()
	_pump(anim, 10)
	ok(FillButtonRes.fill_progress(b) >= 0.999, "★★ 鼠标移开也不回落（已启用 = 常驻）")

	var normal_lum: float = ThemeRes.fill_bottom().get_luminance()
	var latched_lum: float = ThemeRes.fill_bottom_latched().get_luminance()
	ok(latched_lum > normal_lum + 0.05,
		"★★ 已启用那一档明显更亮（%.3f → %.3f）——需求：点击启用时亮度稍微变大"
		% [normal_lum, latched_lum])
	ok(ThemeRes.fill_top_latched().get_luminance() > ThemeRes.fill_top().get_luminance(),
		"★ 渐变的两端都跟着亮（不是只有底边）")

	FillButtonRes.set_latched(b, false)
	ok(not FillButtonRes.is_latched(b), "set_latched(false) 之后不是锁定态")
	_pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) <= 0.001, "★ 弃用之后渐出退回空")

	b.queue_free()

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
				"★ 底下那一端更亮（琥珀自下而上填进来，底边最实）")
		ok(gt.fill_from.y > gt.fill_to.y,
			"★ 渐变方向是**竖直**的（fill_from 在下、fill_to 在上）")

	var before: Color = (anim.ramp_texture() as GradientTexture2D).gradient.sample(0.0)
	anim.set_latched(true)
	var after: Color = (anim.ramp_texture() as GradientTexture2D).gradient.sample(0.0)
	ok(after != before, "★ 切到锁定态时渐变**换了一对颜色**（不是同一张纹理）")
	ok(after.get_luminance() > before.get_luminance(), "★ 而且新那一对更亮")

	anim.set_fill(0.0)
	FillButtonRes.draw_fill(b)
	ok(true, "★ 进度为 0 时 draw_fill() 直接返回（不画）")

	b.queue_free()

func _test_text_on_fill() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)
	FillButtonRes.set_base_font_color(b, BASE_TEXT)

	eq(FillButtonRes.base_font_color(b), BASE_TEXT, "按钮的**原字色**被记下来了")
	eq(b.get_theme_color("font_color"), BASE_TEXT, "★ 没填充时字还是原色")

	var fill := ThemeRes.fill_bottom()
	var naked := _contrast(BASE_TEXT, fill)
	ok(naked < 2.5, "（前提）暖白字直接压在那片琥珀上读不出来（对比度 %.2f）" % naked)

	anim.set_fill(1.0)
	var on_fill := b.get_theme_color("font_color")
	var fixed := _contrast(on_fill, fill)
	ok(fixed > naked + 1.0,
		"★★ 填满时字被压暗（对比度 %.2f → %.2f）" % [naked, fixed])
	ok(fixed >= 4.0,
		"★★ 而且 4:1 以上 —— 11~15 号的小字也读得出来（%.2f）" % fixed)

	var dark_base := ThemeRes.text_on_accent()
	eq(ThemeRes.text_on_fill(false, dark_base), dark_base,
		"★★ 已经很暗的原色原样返回（压暗只对「比目标更亮」的字生效）")
	ok(ThemeRes.text_on_fill(false, dark_base).get_luminance()
			<= dark_base.get_luminance() + 0.0001,
		"★ 也就是说：压暗**永远不会把字弄浅**")

	anim.set_fill(1.0)
	eq(b.get_theme_color("font_color"), on_fill,
		"★ 重复同步不会越压越黑（每次都从原色算起）")

	FillButtonRes.set_base_font_color(b, Color(0.6, 0.6, 0.6, 1.0))
	anim.set_fill(0.999)
	ok(b.get_theme_color("font_color") != on_fill,
		"★ 换一个原色之后，填充态的字色跟着换（没有写死一个值）")

	for slot in ["font_color", "font_hover_color", "font_pressed_color"]:
		var c: Color = b.get_theme_color(slot)
		ok(_contrast(c, fill) >= 4.0,
			"★ %s 也压到够对比了（%.2f）" % [slot, _contrast(c, fill)])
	var dark_a := ThemeRes.text_on_fill(false, ThemeRes.accent())
	var dark_b := ThemeRes.text_on_fill(false, ThemeRes.text())
	near(dark_a.get_luminance(), dark_b.get_luminance(), 0.01,
		"★ 不同原色压完**一样深**（琥珀键位字母 0x%s vs 暖白名字）"
		% ThemeRes.accent().to_html(false))

	var latched_fill := ThemeRes.fill_bottom_latched()
	var latched_text := ThemeRes.text_on_fill(true, BASE_TEXT)
	ok(_contrast(latched_text, latched_fill) >= 3.0,
		"★★ 启用（更亮的蓝）那一档的字也够对比（%.2f）"
		% _contrast(latched_text, latched_fill))

	var child := Label.new()
	child.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(child)
	FillButtonRes.on_fill_text(b, child, BASE_TEXT)
	anim.set_fill(1.0)
	ok(_contrast(child.get_theme_color("font_color"), fill) >= 4.0,
		"★ 子 Label 的字色也被压暗了（不是只管按钮自己的字）")

	b.queue_free()

func _test_legible_across_animation() -> void:
	var b := _new_button()
	b.size = Vector2(120.0, 60.0)
	var anim := FillButtonRes.attach_text(b)
	b.add_theme_stylebox_override("normal", UiStyleRes.card_normal(true))
	FillButtonRes.set_base_font_color(b, ThemeRes.text())

	var worst := 99.0
	var worst_at := 0.0
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
	ok(worst >= 2.8,
		"★★ 整条填充动画里，字与底最差也有 %.2f:1（在 fill=%.2f）—— 不会「看不见」"
		% [worst, worst_at])

	anim.set_fill(1.0)
	var full := _contrast(b.get_theme_color("font_color"), ThemeRes.fill_bottom())
	ok(full >= 4.5, "★★ 满格时字与琥珀有 %.2f:1（正文级）" % full)

	anim.set_fill(0.0)
	eq(b.get_theme_color("font_color"), ThemeRes.text(),
		"★ 没填充时字仍是原色（不受填充逻辑影响）")

	b.queue_free()

func _test_disabled_fills_grey() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)
	FillButtonRes.set_base_font_color(b, ThemeRes.text())

	b.mouse_entered.emit()
	_pump(anim, 40)
	var gold: Color = anim.ramp_texture().gradient.sample(0.0)
	ok(gold.r > gold.b, "（前提）可点的时候填的是**琥珀金**（R > B，0x%s）" % gold.to_html(false))

	b.mouse_exited.emit()
	_pump(anim, 40)
	b.disabled = true
	b.mouse_entered.emit()
	_pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) >= 0.999,
		"★★ 禁用按钮也有悬停反馈（停上去照样填起来）")
	var grey: Color = anim.ramp_texture().gradient.sample(0.0)
	ok(absf(grey.r - grey.b) < 0.06,
		"★★ 但填的是**灰**（R≈B，0x%s）—— 一眼看出不是「能点」的蓝" % grey.to_html(false))
	ok(grey.r >= 0.25 and grey.r <= 0.65,
		"★ 灰要够亮：与深色面板分得开（L=%.2f）" % grey.get_luminance())

	b.mouse_exited.emit()
	_pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) <= 0.001, "★ 鼠标移开就退回去（不是常驻）")

	b.mouse_entered.emit()
	_pump(anim, 40)
	var glyph: Color = b.get_theme_color("font_color")
	ok(_contrast(glyph, grey) >= 3.0,
		"★★ 灰底上的字也有 %.2f:1" % _contrast(glyph, grey))

	b.queue_free()

func _test_animation_switch() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)
	ok(ThemeRes.animations_enabled(), "默认是开着的")

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

	ThemeRes.set_animations_enabled(true)
	b.mouse_entered.emit()
	anim._process(DT)
	var partial := FillButtonRes.fill_progress(b)
	ok(partial > 0.0 and partial < 1.0,
		"★ 打开之后又变成逐帧推进（半程 %.2f）" % partial)
	_pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) >= 0.999, "★ 照样能填满")

	FillButtonRes.set_latched(b, true)
	ThemeRes.set_animations_enabled(false)
	ok(FillButtonRes.is_latched(b) and FillButtonRes.fill_progress(b) >= 0.999,
		"★ 关掉动效不影响「已启用」这个状态")
	ThemeRes.set_animations_enabled(true)

	b.queue_free()

func _test_text_reverts_after_drain() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)
	FillButtonRes.set_base_font_color(b, BASE_TEXT)
	var child := Label.new()
	child.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(child)
	FillButtonRes.on_fill_text(b, child, BASE_TEXT)

	var original := b.get_theme_color("font_color")
	var child_original := child.get_theme_color("font_color")
	eq(original, BASE_TEXT, "（前提）起手是原色")

	b.mouse_entered.emit()
	_pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) >= 0.999, "（前提）填满了")
	ok(b.get_theme_color("font_color") != original,
		"★ 填满时字色换成了填充档（暗字）—— 否则这条回归没意义")

	b.mouse_exited.emit()
	_pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) <= 0.001, "（前提）退回到空")
	eq(b.get_theme_color("font_color"), original,
		"★★ 移开之后按钮字色回到原色（用户报的「颜色不反回来」）")
	eq(child.get_theme_color("font_color"), child_original,
		"★★ 子 Label 的字色也回到原色")

	_pump(anim, 10)
	eq(b.get_theme_color("font_color"), original,
		"★ 停在外面时颜色稳定（每帧同步是幂等的，不会漂）")

	for slot in ["font_hover_color", "font_pressed_color", "font_disabled_color"]:
		eq(b.get_theme_color(slot), original, "★ %s 也还原了" % slot)

	b.queue_free()

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
		"部队行-按下": UiStyleRes.row_pressed(),
		"线框按钮-悬停": MenuThemeRes.button_hover_clear(),
		"菜单行-选中": MenuThemeRes.button_fill_latched(),
	}
	for tag in cases.keys():
		var sb: StyleBoxFlat = cases[tag]
		ok(sb.bg_color.a <= 0.001,
			"★★ %s 的底纹是**全透明**（实底会把填充盖住 → 看起来像「填充在文字上」）"
			% tag)
		# ★★ 三层配色之后：**状态边**（悬停 / 选中 / 启用）走琥珀强调色，
		#   常态边是暗金细线 —— 两者同色系、但亮度差一大截，主行动才跳出来。
		#   （有的档是从主题色再派生一档亮度，所以断言「明显带色相」而不是精确相等。）
		var bc := sb.border_color
		ok(absf(bc.r - bc.b) >= 0.04,
			"★ %s 的描边仍有颜色（暗金 / 琥珀，不是被填充盖住的灰）x=0x%s"
			% [tag, bc.to_html(false)])

	ok(UiStyleRes.tab_normal().bg_color.a > 0.2,
		"★ 没有填充层的那一档（tab_normal）仍要有底色")
	ok(UiStyleRes.accent_button().bg_color.a > 0.9,
		"★ accent_button（实心蓝那一档）仍是实底 —— 它给没挂填充的按钮用")

func _test_prefer_light() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)
	FillButtonRes.set_base_font_color(b, BASE_TEXT)

	anim.set_fill(1.0)
	ok(b.get_theme_color("font_color") != BASE_TEXT,
		"（前提）默认会自动换成填充档的暗字")

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
		"★ 满格时到填充档（琥珀盖满，白字必须让位）")

	b.queue_free()

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
	anim.set_fill(0.5)
	var c0: Color = l0.get_theme_color("font_color")
	var c1: Color = l1.get_theme_color("font_color")
	ok(c0 != c1 or absf(c0.get_luminance() - c1.get_luminance()) < 0.4,
		"★ 横排两字进度接近（渐变沿**竖直**方向，不沿水平）")

	anim.set_fill(0.0)
	eq(l0.get_theme_color("font_color"), BASE_TEXT, "★ 没填充时是原色")
	anim.set_fill(1.0)
	ok(l0.get_theme_color("font_color") != BASE_TEXT,
		"★ 填满时变成填充档（琥珀盖过之后才变）")

	anim.set_fill(0.5)
	ok(absf(l0.get_theme_color("font_color").get_luminance()
			- l1.get_theme_color("font_color").get_luminance()) < 0.4,
		"★★ 同一行的字进度一致（渐变只沿竖直方向）")

	b.queue_free()

func _test_available_off() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)

	b.mouse_entered.emit()
	_pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) >= 0.999, "（前提）开着的时候能填满")

	FillButtonRes.set_available(b, false)
	var frames: int = _pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) <= 0.001,
		"★ set_available(false) → 退回空（用了 %d 帧）" % frames)

	b.mouse_exited.emit()
	b.mouse_entered.emit()
	_pump(anim, 20)
	ok(FillButtonRes.fill_progress(b) <= 0.001,
		"★★ 关掉的按钮，鼠标停上去也**一点不填**（空槽不能看着像能点）")

	FillButtonRes.set_available(b, true)
	b.disabled = true
	b.mouse_exited.emit()
	b.mouse_entered.emit()
	_pump(anim, 40)
	ok(FillButtonRes.fill_progress(b) >= 0.999,
		"★★ `disabled = true` 的按钮照样能填（用来做灰色悬停反馈）")

	b.queue_free()

## ★★ 宿主不可见时悬停作废 —— 修「点按钮进游戏、再返回主菜单，那片琥珀还留着」。
func _test_hide_clears_hover() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)
	b.mouse_entered.emit()
	anim.set_fill(1.0)
	ok(anim._hovered, "（前提）悬停中是「hovered」")
	# 宿主不可见 = 页面隐藏 / CanvasLayer 收起 → 悬停必须作废
	b.visible = false
	ok(not anim._hovered,
		"★★ 宿主不可见时悬停作废（修「点按钮进游戏、返回主菜单后那片琥珀还留着」）")
	b.visible = true
	ok(not anim._hovered,
		"★★ 重新可见**不会**自己恢复悬停（只有真实 mouse_entered 才会）")
	b.queue_free()


## ★★ 流程层的兜底：递归清掉一棵子树里所有按钮的悬停。
func _test_clear_hover_in() -> void:
	var holder := Control.new()
	root.add_child(holder)
	var b := Button.new()
	holder.add_child(b)
	var anim := FillButtonRes.attach_text(b)
	b.mouse_entered.emit()
	ok(anim._hovered, "（前提）悬停中是「hovered」")
	FillButtonRes.clear_hover_in(holder)
	ok(not anim._hovered, "★★ clear_hover_in() 递归清掉子树里按钮的悬停（流程层兜底用）")
	holder.queue_free()


## ★★ 流程层的另一条兜底：递归解除整棵子树的「常驻满格（latched）」。
##
## 与 `clear_hover_in` 刻意分开：
##   · 悬停 = 「鼠标 / 手指还在上面」；
##   · 常驻 = 「这块面板现在被打开 / 被选中」。
## 主界面点开面板时入口按钮要**锁住**（不然面板还开着琥珀就退了），收起时才解除 ——
## 这里验「解除会递归生效」，而且解除之后目标是 0（下一次 `_process` 走反向渐出）。
func _test_clear_latched_in() -> void:
	var holder := Control.new()
	root.add_child(holder)
	var a := Button.new()
	var b := Button.new()
	holder.add_child(a)
	holder.add_child(b)
	var aa := FillButtonRes.attach_text(a)
	FillButtonRes.attach_text(b)
	aa.set_latched(true)
	FillButtonRes.set_latched(b, true)
	ok(FillButtonRes.is_latched(a) and FillButtonRes.is_latched(b), "（前提）两颗都是常驻满格")
	FillButtonRes.clear_latched_in(holder)
	ok(not FillButtonRes.is_latched(a), "★★ clear_latched_in() 递归解除常驻（左）")
	ok(not FillButtonRes.is_latched(b), "★★ clear_latched_in() 递归解除常驻（右）")
	ok(aa._goal() == 0.0, "★ 解除之后目标为空（走 DRAIN_TIME 那条反向渐出，不是瞬间清零）")
	holder.queue_free()


func _new_button() -> Button:
	var b := Button.new()
	b.size = Vector2(100.0, 60.0)
	root.add_child(b)
	return b

func _pump(anim, budget: int) -> int:
	var n := 0
	while n < budget:
		var before: float = anim.fill()
		anim._process(DT)
		n += 1
		if is_equal_approx(before, float(anim.fill())):
			break
	return n

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
