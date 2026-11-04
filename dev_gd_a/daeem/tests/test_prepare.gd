## test_prepare.gd —— 备战页：主菜单上滑、返回区、两块空面板、王朝/帝国竖排按钮。
##
## 只测「版式对、点得到、状态对」：
##   · 进入：主菜单上滑到只剩 120 高的底部动作条，左侧轮播图渐隐，备战按钮常驻金；
##   · 返回区：整条可点、文字呼吸、点击回主菜单；Esc 同样回主菜单；
##   · 派系：上王朝 / 下帝国，默认帝国选中，两枚互斥；
##   · 退出：主菜单落回原位、轮播图恢复、备战按钮的金渐出。
extends "res://tests/test_case.gd"

const MainScene := preload("res://view/main.tscn")
const LayoutRes := preload("res://view/menu_deck_layout.gd")
const ThemeRes := preload("res://view/theme.gd")
const FillRes := preload("res://view/fill_button.gd")


func _initialize() -> void:
	_case_name = "test_prepare"
	_run()


func _run() -> void:
	await process_frame
	# ★ headless 下根窗口默认是 1:1（visible = 1920×1920），右侧面板会被拉高到
	#   装得下整张列表、测不出滚动。这里在窗口就绪之后显式钉成 1920×1080。
	root.size = Vector2i(1920, 1080)
	await process_frame
	await _test_enter_and_layout()
	await _test_back()
	await _test_animations_off()
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _spawn_main():
	var main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	await _wait_sec(0.15)
	var screen = main.start_screen
	screen.dismiss_intro()
	await _wait_start_page(screen, 1)
	await _wait_sec(0.8)
	return main


func _test_enter_and_layout() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var screen = main.start_screen
	var deck = screen.menu_deck()
	var mp = screen.main_panel()
	var pp = screen.prepare_panel()
	ok(pp != null, "备战页控件存在")
	if pp == null:
		return
	var w: float = deck.size.x
	var h: float = deck.size.y
	var side: float = LayoutRes.side_w(w)
	var panel_inset: float = clampf(round(h * 0.0602), 24.0, 80.0)
	var faction_top: float = LayoutRes.PREP_HEADER_H
	var faction_half: float = (h - faction_top) * 0.5
	ok(not pp.visible, "主菜单页：备战页隐藏")
	near(screen.art().modulate.a, 1.0, 0.01, "主菜单页：左侧轮播图可见")

	mp.bottom_buttons()[1].pressed.emit()
	if ThemeRes.animations_enabled():
		await _wait_sec(0.1)
		ok(mp.position.y < -1.0 and mp.position.y > -(h - LayoutRes.PREP_HEADER_H) + 1.0, "转场中途：主菜单正在上滑")
		ok(pp.visible and pp.modulate.a > 0.0 and pp.modulate.a < 1.0,
			"转场中途：备战页正在淡入")
		ok(screen.art().modulate.a < 1.0, "转场中途：左侧轮播图正在渐隐")
	ok(await _wait_page(deck, "prepare"), "进入备战页")
	await _wait_sec(0.35)

	# ---- 主菜单：只剩顶部动作条 ----
	near(mp.position.x, w - side, 1.0, "主菜单仍在右列")
	near(mp.position.y, -(h - LayoutRes.PREP_HEADER_H), 1.0,
		"主菜单上滑到只剩底部动作条")
	var b0: Rect2 = mp.bottom_buttons()[0].get_global_rect()
	var b1: Rect2 = mp.bottom_buttons()[1].get_global_rect()
	near(b0.position.y, 0.0, 1.0, "自定义按钮顶到屏幕顶")
	near(b0.position.x, w - side, 1.0, "自定义按钮在左半")
	near(b1.position.x, w - side * 0.5, 1.0, "备战按钮在右半")
	near(b1.size.y, 120.0, 1.0, "顶部动作条高 120")

	# ---- 返回区 ----
	var br: Rect2 = pp.back_area().get_global_rect()
	near(br.position.x, 0.0, 1.0, "返回区贴屏幕左缘")
	near(br.position.y, 0.0, 1.0, "返回区贴屏幕顶")
	near(br.size.x, w - side, 1.0, "返回区到主菜单左缘为止")
	near(br.size.y, 120.0, 1.0, "返回区与动作条同高")
	eq(pp.back_label().text, "——点此返回主菜单——", "返回区文案")
	eq(pp.back_label().horizontal_alignment, HORIZONTAL_ALIGNMENT_CENTER,
		"返回文字水平居中")
	eq(pp.back_label().vertical_alignment, VERTICAL_ALIGNMENT_CENTER,
		"返回文字垂直居中")
	var ba: float = pp.back_label().modulate.a
	ok(ba > 0.1 and ba < 0.999, "返回文字在呼吸显隐（%f）" % ba)

	# ---- 两块面板：左空底板 / 右弹性列表 ----
	eq(pp.panels().size(), 2, "两块面板")
	var p0: Rect2 = pp.panels()[0].get_global_rect()
	var p1: Rect2 = pp.panels()[1].get_global_rect()
	near(p0.position.x, 140.0, 1.0, "左面板 x=140")
	near(p0.size.x, 1000.0, 1.0, "左面板宽 1000")
	near(p1.position.x, 1190.0, 1.0, "右面板 x=1190")
	near(p1.size.x, 500.0, 1.0, "右面板宽 500")
	near(p0.position.y, LayoutRes.PREP_HEADER_H + panel_inset, 1.0, "面板顶边在动作条下方留白")
	near(p0.end.y, h - panel_inset, 1.0, "面板底边离屏幕底同样的留白")
	near(p0.end.y, p1.end.y, 0.5, "两块面板同底")
	ok(not p0.intersects(p1), "两块面板不重叠")
	eq(pp.panels()[0].get_child_count(), 1, "左面板装了详情卡")
	ok(pp.detail() != null, "左面板详情卡存在")
	if pp.detail() != null:
		ok(not pp.detail().has_detail(), "默认没有选中项")
		ok(pp.detail().hint_visible(), "默认显示「点击右侧查看详情」提示")
	ok(pp.panels()[1].get_child_count() >= 1, "右面板装了内容")

	# ---- 右面板：将领 / 单位 / 科技 弹性列表 ----
	var cfg = screen.cfg
	var roster = pp.roster()
	ok(roster != null, "右面板列表存在")
	if roster != null:
		var lr: Rect2 = roster.get_global_rect()
		ok(p1.encloses(lr), "列表完全落在右面板里")
		near(lr.position.x, p1.position.x + 16.0, 1.0, "列表左边留 16px")
		near(lr.size.x, p1.size.x - 32.0, 1.0, "列表宽度 = 面板宽 − 2×16")

		var hs: Array = roster.section_headers()
		eq(hs.size(), 3, "三个分节")
		eq(hs[0].text, "将领——", "第一节：将领——")
		eq(hs[1].text, "单位——", "第二节：单位——")
		eq(hs[2].text, "科技——", "第三节：科技——")
		ok(hs[0].get_global_rect().position.y < hs[1].get_global_rect().position.y,
			"将领分节在单位之上")
		ok(hs[1].get_global_rect().position.y < hs[2].get_global_rect().position.y,
			"单位分节在科技之上")

		# 将领：零阶 0 → 一阶 1..3 → 二阶 4..6 → 三阶 7..9
		eq(roster.general_buttons().size(), 10, "10 位将领（0 + 9 可招募）")
		eq(roster.tile_label(roster.general_buttons()[0]), "将领 0", "零阶是开局将领 0")
		eq(roster.tile_label(roster.general_buttons()[9]), "将领 9", "最后是三阶将领 9")
		eq(roster.tile_tier(roster.general_buttons()[0]), 0, "将领 0 零阶")
		eq(roster.tile_tier(roster.general_buttons()[1]), 1, "将领 1 一阶")
		eq(roster.tile_tier(roster.general_buttons()[4]), 2, "将领 4 二阶")
		eq(roster.tile_tier(roster.general_buttons()[7]), 3, "将领 7 三阶")

		# 阶小标题：将领 4 个（零/一/二/三），单位 3 个，科技 3 个
		var th: Array = roster.tier_headers()
		eq(th.size(), 10, "4 + 3 + 3 个阶小标题")
		var want_tiers := ["零阶", "一阶", "二阶", "三阶",
			"一阶", "二阶", "三阶", "一阶", "二阶", "三阶"]
		for i in want_tiers.size():
			eq(th[i].text, want_tiers[i], "阶小标题顺序：%d" % i)

		# 磁贴：一排三个、约 150×110，图标在上 / 名字在下
		eq(roster.tile_columns(), 3, "一排三个磁贴")
		var g0: Button = roster.general_buttons()[0]
		var g1: Button = roster.general_buttons()[1]
		var g2: Button = roster.general_buttons()[2]
		var g3: Button = roster.general_buttons()[3]
		var g4: Button = roster.general_buttons()[4]
		var tile_w: float = (lr.size.x - 2.0 * 8.0) / 3.0
		near(g0.size.y, roster.tile_height(), 1.0, "磁贴高 %.0f" % roster.tile_height())
		near(g0.size.x, tile_w, 1.5, "零阶单格与满行同宽（补空位）")
		near(g1.size.x, tile_w, 1.5, "磁贴宽按三列均分")
		var r0: Rect2 = g0.get_global_rect()
		var r1: Rect2 = g1.get_global_rect()
		var r2: Rect2 = g2.get_global_rect()
		var r3: Rect2 = g3.get_global_rect()
		var r4: Rect2 = g4.get_global_rect()
		ok(r0.position.y < r1.position.y - 1.0, "零阶单独一行在最上")
		near(r1.position.y, r2.position.y, 0.5, "一阶三格同一行")
		near(r2.position.y, r3.position.y, 0.5, "一阶三格同一行")
		ok(r4.position.y > r1.position.y + 1.0, "二阶换行")
		near(r4.position.x, r1.position.x, 0.5, "二阶回到第一列")
		near(r0.position.x, r1.position.x, 0.5, "零阶与一阶左对齐")
		ok(r1.end.x < r2.position.x and r2.end.x < r3.position.x, "三列从左到右不重叠")

		# 将领没有图标 → 编号占位；单位 / 科技用金线蒙版
		eq(roster.tile_placeholder(g0), "0", "开局将领的占位编号")
		eq(roster.tile_placeholder(roster.general_buttons()[9]), "9", "三阶将领的占位编号")
		ok(roster.tile_icon_mask(g0) == "", "将领没有图标蒙版")
		ok(g0.has_node("PlaceholderIcon"), "将领磁贴用文字占位图标")
		ok(not g0.has_node("Icon"), "将领磁贴不画金线图标")

		# 单位 / 科技：与当前派系（默认帝国）的数据逐条对齐
		var empire_units: Array = cfg.clan_recruit_list("empire")
		eq(roster.unit_buttons().size(), empire_units.size(), "帝国单位数")
		for i in empire_units.size():
			eq(roster.tile_label(roster.unit_buttons()[i]),
				String((empire_units[i] as Dictionary).get("label", "")),
				"帝国单位名：%d" % i)
		for b in roster.unit_buttons():
			ok(roster.tile_icon_mask(b) != "", "帝国单位有图标蒙版：%s" % roster.tile_label(b))
			ok(b.has_node("Icon"), "帝国单位磁贴画金线图标")
		var empire_tech_names := _tech_names(cfg, "empire")
		eq(roster.tech_buttons().size(), empire_tech_names.size(), "帝国科技数（跳过空槽）")
		for b in roster.tech_buttons():
			var nm: String = roster.tile_label(b)
			ok(empire_tech_names.has(nm), "帝国科技名：%s" % nm)
			ok(nm.strip_edges() != "", "科技按钮没有空名字")
			ok(roster.tile_icon_mask(b) != "", "帝国科技有图标蒙版：%s" % nm)

		# ---- 点磁贴 → 左面板详情 + 选中金边 ----
		var d = pp.detail()
		ok(d != null, "详情卡存在")
		roster.scroll_to(0.0)
		await _click_at(g1.get_global_rect().get_center())
		await _wait_sec(0.15)
		ok(d.has_detail(), "点将领后左面板有详情")
		eq(d.title_text(), "将领 1", "详情标题 = 将领 1")
		ok(d.subtitle_text().find("一阶") >= 0, "详情副标题含一阶")
		eq(String(d.last_item().get("kind", "")), "general", "详情类型 = general")
		eq(roster.selected_tile(), g1, "被点的将领磁贴保持选中")
		eq((g1.get_theme_stylebox("normal") as StyleBoxFlat).border_width_left, 2,
			"选中磁贴是 2px 金边")
		var gtitles := _section_titles(d)
		ok(gtitles.has("说明") and gtitles.has("属性") and gtitles.has("造价 / 招募"),
			"将领详情含说明 / 属性 / 造价")

		var ub: Button = roster.unit_buttons()[0]
		ub.pressed.emit()
		await _wait_sec(0.1)
		eq(String(d.last_item().get("kind", "")), "unit", "点单位后详情切到 unit")
		eq(d.title_text(), roster.tile_label(ub), "单位详情标题")
		eq(roster.selected_tile(), ub, "单位磁贴变为选中")
		eq((g1.get_theme_stylebox("normal") as StyleBoxFlat).border_width_left, 1,
			"上一枚磁贴恢复 1px")
		var utitles := _section_titles(d)
		ok(utitles.has("说明") and utitles.has("造价 / 招募"), "单位详情含说明 / 造价")

		var tb: Button = roster.tech_buttons()[0]
		tb.pressed.emit()
		await _wait_sec(0.1)
		eq(String(d.last_item().get("kind", "")), "tech", "点科技后详情切到 tech")
		eq(d.title_text(), roster.tile_label(tb), "科技详情标题")
		eq(roster.selected_tile(), tb, "科技磁贴变为选中")
		var ttitles := _section_titles(d)
		ok(ttitles.has("说明") and ttitles.has("效果"), "科技详情含说明 / 效果")

		# 可过度拖拽：内容超过视口，越界量被阻尼吃掉
		var limit: float = roster.max_scroll()
		ok(limit > 80.0, "内容明显长于视口（可滚 %.0f px）" % limit)
		roster.scroll_to(-80.0)
		ok(roster.logical_offset() < 0.0, "允许向上过拉")
		ok(roster.display_offset() < 0.0 and roster.display_offset() > -80.0,
			"上过拉在画面上被阻尼（%.1f → %.1f）"
			% [-80.0, roster.display_offset()])
		roster.scroll_to(limit + 80.0)
		ok(roster.logical_offset() > limit, "允许向下过拉")
		ok(roster.display_offset() > limit and roster.display_offset() < limit + 80.0,
			"下过拉在画面上被阻尼")
		roster.scroll_to(300.0)
		near(roster.logical_offset(), 300.0, 0.1, "区间内拖到 300px")
		for b in roster.item_buttons():
			ok(b is Button, "列表项是按钮：%s" % b.name)

	# ---- 右侧两枚竖排按钮 ----
	eq(pp.faction_buttons().size(), 2, "两枚派系按钮")
	var f0: Rect2 = pp.faction_buttons()[0].get_global_rect()
	var f1: Rect2 = pp.faction_buttons()[1].get_global_rect()
	near(f0.position.x, w - 200.0, 1.0, "派系按钮贴右缘")
	near(f0.size.x, 200.0, 1.0, "派系按钮宽 200")
	near(f0.end.x, w, 0.5, "派系按钮到屏幕右缘")
	near(f0.position.y, faction_top, 1.0, "王朝在上")
	near(f0.size.y, faction_half, 1.0, "上下两枚均分")
	near(f1.position.y, faction_top + faction_half, 1.0, "帝国在下")
	near(f1.end.y, h, 0.5, "下半贴到屏幕底")
	near(f0.end.y, f1.position.y, 0.5, "两枚严格上下相接")
	eq(pp.faction_buttons()[0].display_text(), "王朝", "上：王朝")
	eq(pp.faction_buttons()[1].display_text(), "帝国", "下：帝国")
	ok(pp.faction_buttons()[0].text.is_empty(), "按钮本身不画横排字（交给竖排 Label）")
	ok(not pp.faction_buttons()[0].is_selected(), "王朝初始未选中（白框）")
	ok(pp.faction_buttons()[1].is_selected(), "帝国初始选中（黑块 / 金色填充）")
	eq(pp.selected_faction(), "empire", "默认派系 = 帝国")

	# 点上面那枚：互斥切换，右面板三节跟着换成王朝的数据
	await _click_at(f0.get_center())
	await _wait_sec(0.25)
	eq(pp.selected_faction(), "dynasty", "点王朝切到王朝")
	ok(pp.faction_buttons()[0].is_selected(), "王朝变选中")
	ok(not pp.faction_buttons()[1].is_selected(), "帝国变未选中")
	if roster != null:
		eq(roster.faction_id(), "dynasty", "列表跟着切到王朝")
		var dyn_units: Array = cfg.clan_recruit_list("dynasty")
		eq(roster.unit_buttons().size(), dyn_units.size(), "王朝单位数")
		eq(roster.tile_label(roster.unit_buttons()[0]),
			String((dyn_units[0] as Dictionary).get("label", "")), "王朝第一个单位")
		var dyn_tech: Array = _tech_names(cfg, "dynasty")
		eq(roster.tech_buttons().size(), dyn_tech.size(), "王朝科技数")
		for b in roster.tech_buttons():
			var nm: String = roster.tile_label(b)
			ok(dyn_tech.has(nm), "王朝科技名：%s" % nm)
		near(roster.logical_offset(), 0.0, 1.0, "换派系后列表回到顶部")
		ok(not pp.detail().has_detail(), "切派系清空左侧详情")
		ok(pp.detail().hint_visible(), "切派系回到提示态")
		eq(roster.selected_tile(), null, "切派系清空磁贴选中")
		# 王朝的组合单位（协防军）详情要显示「编成」而不是单兵属性
		var dyn_ub: Button = roster.unit_buttons()[0]
		dyn_ub.pressed.emit()
		await _wait_sec(0.1)
		eq(String(pp.detail().last_item().get("kind", "")), "unit", "王朝组合单位详情")
		ok(_section_titles(pp.detail()).has("编成"), "组合单位详情含编成")
		ok(_section_titles(pp.detail()).has("说明"), "组合单位详情含说明")

		# 真拖一下：向上拖 = 内容往下滚；拖动松手不会顺手点掉列表项
		roster.scroll_to(0.0)
		var drag_btn: Button = roster.general_buttons()[3]
		var drag_from: Vector2 = drag_btn.get_global_rect().get_center()
		await _drag_at(drag_from, drag_from + Vector2(0.0, -160.0))
		await _wait_sec(0.1)
		ok(roster.logical_offset() > 50.0,
			"向上拖动列表确实滚动了（%.0f px）" % roster.logical_offset())
		eq(deck.current_page(), "prepare", "拖动列表不跳页")
		ok(not drag_btn.is_pressed(), "拖动后原按钮不再停在按下态")
		ok(FillRes.fill_progress(drag_btn) < 0.1, "拖动后原按钮的金色已退回")
		near(drag_btn.scale.x, 1.0, 0.01, "拖动后按下缩放已复位")
		roster.scroll_to(0.0)

		# 列表项可点：悬停有金填充、移开退回；点击不跳页、不改派系
		var gb: Button = roster.general_buttons()[0]
		ok(FillRes.animator_of(gb) != null, "列表项挂了填充动效")
		gb.mouse_entered.emit()
		await _wait_sec(0.2)
		ok(FillRes.fill_progress(gb) > 0.9, "悬停列表项时金色填充")
		gb.mouse_exited.emit()
		await _wait_sec(0.2)
		ok(FillRes.fill_progress(gb) < 0.1, "移开后金色退回")
		await _click_at(gb.get_global_rect().get_center())
		await _wait_sec(0.15)
		eq(deck.current_page(), "prepare", "点列表项不跳页（暂无点击逻辑）")
		eq(pp.selected_faction(), "dynasty", "点列表项不改派系")

	# ---- 左侧轮播图：已渐隐并停表 ----
	near(screen.art().modulate.a, 0.0, 0.01, "备战页：左侧轮播图已渐隐")
	ok(not screen.art().is_running(), "备战页：轮播图停表（不再空转）")

	# ---- 备战按钮：金色常驻 ----
	var btn: Button = mp.bottom_button(1)
	ok(FillRes.is_latched(btn), "备战按钮锁成常驻金")
	ok(FillRes.fill_progress(btn) >= 0.999, "备战按钮填满")
	ok(not FillRes.is_latched(mp.bottom_button(0)), "自定义按钮不常驻")

	main.queue_free()
	await process_frame


func _test_back() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var screen = main.start_screen
	var deck = screen.menu_deck()
	var mp = screen.main_panel()
	var pp = screen.prepare_panel()

	deck.goto_prepare()
	ok(await _wait_page(deck, "prepare"), "（前提）进入备战页")
	# 真点返回区中心
	await _click_at(pp.back_area().get_global_rect().get_center())
	ok(await _wait_page(deck, "main"), "点返回区回到主菜单")
	near(mp.position.y, 0.0, 1.0, "主菜单落回原位")
	ok(not pp.visible, "备战页隐藏")
	near(screen.art().modulate.a, 1.0, 0.01, "左侧轮播图恢复")
	ok(screen.art().is_running(), "轮播图恢复走表")
	var btn: Button = mp.bottom_button(1)
	ok(not FillRes.is_latched(btn), "返回后解除常驻金")
	await _wait_sec(0.3)
	ok(FillRes.fill_progress(btn) <= 0.01, "金色填充已反向渐出")

	# Esc / 返回键等价于返回区
	deck.goto_prepare()
	ok(await _wait_page(deck, "prepare"), "再次进入备战页")
	ok(screen.handle_back(), "Esc / 返回键被备战页受理")
	ok(await _wait_page(deck, "main"), "Esc 回到主菜单")

	# 列表滚动位置不跨页保留：离开前滚到中段，再进来回到顶部
	deck.goto_prepare()
	ok(await _wait_page(deck, "prepare"), "第三次进入备战页")
	ok(not pp.detail().has_detail(), "重新进入时详情默认空白")
	pp.roster().general_buttons()[0].pressed.emit()
	await _wait_sec(0.1)
	ok(pp.detail().has_detail(), "重新进入后点磁贴能出详情")
	pp.roster().scroll_to(420.0)
	await _wait_sec(0.1)
	screen.handle_back()
	ok(await _wait_page(deck, "main"), "带着滚动位置返回主菜单")
	deck.goto_prepare()
	ok(await _wait_page(deck, "prepare"), "第四次进入备战页")
	near(pp.roster().logical_offset(), 0.0, 1.0, "重新进入时列表回到顶部")
	ok(not pp.detail().has_detail(), "重新进入时详情被清空")
	ok(pp.detail().hint_visible(), "重新进入时回到提示态")
	eq(pp.roster().selected_tile(), null, "重新进入时磁贴选中被清空")
	screen.handle_back()
	ok(await _wait_page(deck, "main"), "收尾回到主菜单")

	# 自定义仍不跳转
	mp.bottom_buttons()[0].pressed.emit()
	await _wait_sec(0.1)
	eq(deck.current_page(), "main", "自定义按钮不跳转")

	main.queue_free()
	await process_frame


func _test_animations_off() -> void:
	ThemeRes.set_animations_enabled(false)
	var main = await _spawn_main()
	if main != null:
		var screen = main.start_screen
		var deck = screen.menu_deck()
		var mp = screen.main_panel()
		deck.goto_prepare()
		eq(deck.current_page(), "prepare", "动效关闭：进入备战页同步到位")
		near(mp.position.y, -(deck.size.y - LayoutRes.PREP_HEADER_H), 1.0,
			"动效关闭：主菜单同步上滑")
		near(screen.prepare_panel().back_label().modulate.a, 1.0, 0.01,
			"动效关闭：返回文字不呼吸、保持常亮")
		screen.handle_back()
		eq(deck.current_page(), "main", "动效关闭：返回同步到位")
		near(mp.position.y, 0.0, 1.0, "动效关闭：主菜单同步落回")
		main.queue_free()
		await process_frame
	ThemeRes.set_animations_enabled(true)


# ------------------------------------------------------------------
# 脚手架
# ------------------------------------------------------------------

## 某一派系科技页里**非空槽**的科技名（与列表的建法同一口径）。
func _tech_names(cfg, clan: String) -> Array:
	var out: Array = []
	for e in cfg.tech_list_for(clan):
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = e
		if String(d.get("id", "")) == "":
			continue
		var nm := String(d.get("name", "")).strip_edges()
		if nm != "":
			out.append(nm)
	return out


## 详情卡里各分节的标题（测试用）。
func _section_titles(detail) -> Array:
	var out: Array = []
	for s in detail.last_item().get("sections", []):
		if typeof(s) == TYPE_DICTIONARY:
			out.append(String((s as Dictionary).get("title", "")))
	return out


func _click_at(pos: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	root.push_input(motion, true)
	await process_frame
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = pos
	down.global_position = pos
	root.push_input(down, true)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = pos
	up.global_position = pos
	root.push_input(up, true)
	await process_frame
	await process_frame


## 按住拖动（列表的 `_input` 认的是 global_position / 位移，不依赖控件自己的 gui_input）。
func _drag_at(from: Vector2, to: Vector2) -> void:
	var m0 := InputEventMouseMotion.new()
	m0.position = from
	m0.global_position = from
	root.push_input(m0, true)
	await process_frame
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = from
	down.global_position = from
	root.push_input(down, true)
	await process_frame
	var move := InputEventMouseMotion.new()
	move.position = to
	move.global_position = to
	move.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(move, true)
	await process_frame
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = to
	up.global_position = to
	root.push_input(up, true)
	await process_frame
	await process_frame


func _wait_sec(sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


## 等入场页切到主菜单（start_screen 的 page，不是 deck 的 page）——
## deck 在 prepare_intro 里就已经是 main 了，等它会立刻返回、还在落位中途。
func _wait_start_page(screen, page: int, timeout_ms: int = 8000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if int(screen.page()) == page:
			return true
		await process_frame
	return int(screen.page()) == page


func _wait_page(deck, page: String, timeout_ms: int = 8000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if deck.current_page() == page and not deck.is_busy():
			return true
		await process_frame
	return deck.current_page() == page and not deck.is_busy()




