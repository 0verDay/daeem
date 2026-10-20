## test_level_transition.gd —— ★★ 战役过渡画面 + 多阵营选择
##
## 覆盖：
##   1. `logic/level_brief.gd`：标题 / 简报 / 可玩阵营 / 各自目标 / 目标区；
##   2. `view/map_preview.gd`：有地图、目标区高亮、大本营与出生点数量；
##   3. `view/level_transition.gd`：三块面板（缩略图 / 描述 / 阵营行）/ 阵营面板 / 进度条 / 提示；
##      **阵营选项是描述面板下方的独立面板（左右并排、边界与上面两块对齐）**；
##      **所有面板都有滑入动效**（左从左边 / 描述从右边 / 阵营自下而上）；
##      未选不可进、点面板选中（琥珀金边）、点提示才发 enter_requested；
##      单阵营自动选中；
##   4. main 接线：单人关先进过渡、选阵营后进入；Esc 取消回菜单；合作关直接开局。
extends "res://tests/test_case.gd"

const CampaignRes = preload("res://logic/campaign.gd")
const CampaignLibraryRes = preload("res://logic/campaign_library.gd")
const LevelBriefRes = preload("res://logic/level_brief.gd")
const MapPreviewRes = preload("res://view/map_preview.gd")
const LevelTransitionRes = preload("res://view/level_transition.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")
const ThemeRes = preload("res://view/theme.gd")
const MapLibraryRes = preload("res://logic/map_library.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const FERRY_DIR := "res://data/campaigns/ferry"

var _cfg = null
var _font: Font = null


func _initialize() -> void:
	_case_name = "test_level_transition"
	_run()


func _run() -> void:
	await process_frame
	_cfg = require_config()
	if _cfg != null:
		_font = FontLoaderRes.load_font(_cfg)
		_test_brief_data()
		await _test_widget()
		await _test_panel_slide()
		await _test_bar_sequence()
		await _test_main_flow()
		await _test_coop_skips()

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 1. 简报数据
# ------------------------------------------------------------------

func _test_brief_data() -> void:
	var c = CampaignRes.load_campaign(DEMO_DIR, _cfg)
	ok(c != null, "（前提）demo 战役能载入")
	if c == null:
		return
	var lv = c.level("01_beachhead")
	ok(lv != null, "（前提）01_beachhead 能载入")
	if lv == null:
		return

	var entries: Array = LevelBriefRes.playable_entries(lv)
	eq(entries.size(), 2, "★ 第一关有两个可玩阵营")
	if entries.size() == 2:
		eq(String(entries[0]["id"]), "F1", "第一个是 F1")
		eq(String(entries[0]["name"]), "蓝方", "F1 的显示名来自战役数据")
		ok(String(entries[0]["goal"]).contains("守住"), "★ F1 的目标是「守住…」（%s）"
			% String(entries[0]["goal"]))
		eq(String(entries[1]["id"]), "F2", "第二个是 F2")
		ok(String(entries[1]["goal"]).contains("攻占"), "★ F2 的目标是「攻占…」（%s）"
			% String(entries[1]["goal"]))
		ok(String(entries[0]["color"]).begins_with("#"), "★ 阵营颜色是从战役数据带出来的")

	var title := LevelBriefRes.title(c, lv)
	ok(title.contains("东征") and title.contains("渡口"), "★ 标题 = 战役名 · 关卡名（%s）" % title)
	var brief := LevelBriefRes.briefing_text(lv)
	ok(brief.contains("渡口") and brief.contains("c1"), "★ 简报读的是关卡 JSON 的 briefing[]")
	ok(LevelBriefRes.mode_text(lv) == "单人", "模式文案：单人")

	# 目标区：c1（id=4）——缩略图高亮就靠它。
	var zs: Array = LevelBriefRes.objective_zone_ids(lv)
	ok(zs.has(4), "★ 目标区 id = 4（c1）")
	ok(LevelBriefRes.zone_label(lv, 4).contains("c1"), "★ 区划显示名是 c1")

	# 没写 briefing 时的自动兜底。
	var saved: Array = lv.briefing.duplicate()
	lv.briefing = []
	var auto := LevelBriefRes.briefing_text(lv)
	ok(auto.contains("蓝方") and auto.contains("守住"), "★ 没有 briefing 时按「名字：目标」自动生成")
	lv.briefing = saved

	var f = CampaignRes.load_campaign(FERRY_DIR, _cfg)
	ok(f != null, "（前提）ferry 战役能载入")
	if f != null:
		var fl = f.level("ferry")
		ok(fl != null, "（前提）ferry 关卡能载入")
		if fl != null:
			ok(LevelBriefRes.objective_zone_ids(fl).has(0), "★ 渡口争夺的目标区是 0（b1）")
			eq(LevelBriefRes.playable_entries(fl).size(), 2, "渡口争夺也是两个可玩阵营")


# ------------------------------------------------------------------
# 2. 过渡画面本体
# ------------------------------------------------------------------

func _test_widget() -> void:
	var c = CampaignRes.load_campaign(DEMO_DIR, _cfg)
	var lv = c.level("01_beachhead") if c != null else null
	if lv == null:
		return

	ThemeRes.set_animations_enabled(false)
	var tr = LevelTransitionRes.new()
	root.add_child(tr)
	tr.setup(_cfg, _font, c, lv)
	await _wait_ready(tr)
	await _test_panel_layout(tr)
	ok(not tr.panel_slide_active(), "★ 动效总开关关掉时不播滑入（面板直接在终点）")

	# 缩略图：左面板里有地图、目标区高亮、大本营与出生点。
	var pv = tr.preview()
	ok(pv != null, "★ 左边有战场缩略图")
	if pv != null:
		ok(pv.has_map(), "★ 缩略图拿到了关卡地图")
		ok(pv.map_rect().size.x > 10.0 and pv.map_rect().size.y > 10.0,
			"★ 缩略图铺开了（%.0f×%.0f）" % [pv.map_rect().size.x, pv.map_rect().size.y])
		ok(pv.objective_zone_ids().has(4), "★ 缩略图知道目标区（c1 / 4）")
		ok(pv.base_count() >= 2, "★ 至少画了双方的大本营（%d 个）" % pv.base_count())
		ok(pv.spawn_count() > 0, "★ 画了开局出生点（%d 个）" % pv.spawn_count())
		# ★★ 本轮新增：未选可玩阵营时，缩略图的标识全是灰的。
		eq(pv.view_faction, "", "★ 多阵营且未选时，缩略图没有「我方视角」")
		eq(pv.zone_owner_color("F1"), _cfg.side_color_neutral,
			"★★ 未选阵营：区划 / 标识用灰色")
		eq(pv.zone_owner_color("GD1"), _cfg.side_color_neutral,
			"★★ 未选阵营：盟友标识也是灰的（还不知道谁是我）")

	# 两块大面板 + 描述面板下方的阵营面板行。
	ok(tr.faction_panel_count() == 2, "★ 多阵营时有两块阵营面板")
	eq(tr.selected_faction(), "", "★ 默认不预选（必须自己选）")
	eq(tr.hint_text(), "————请选择阵营————", "★ 未选时提示「请选择阵营」")
	ok(tr.ready_to_enter(), "（前提）动效关掉时加载立即完成")
	near(tr.progress_value(), 100.0, 0.001, "★ 进度条到 100")

	var entered: Array = []
	tr.enter_requested.connect(func(fid: String): entered.append(fid))
	# 未选时点提示：什么都不该发生。
	await _click_at(tr.hint_rect().get_center())
	eq(entered.size(), 0, "★★ 没选阵营时点提示不会进入")

	# 点第一块阵营面板 → 选中 + 琥珀金边。
	var card: Panel = tr.faction_panel(0)
	ok(card != null, "（前提）第一块阵营面板在")
	if card != null:
		await _click_at(card.get_global_rect().get_center())
	eq(tr.selected_faction(), "F1", "★★ 点阵营面板选中了 F1")
	ok(tr.hint_text().contains("蓝方"), "★ 提示变成「作为蓝方进入游戏」（%s）" % tr.hint_text())
	# ★★ 选中后缩略图立刻切到 F1 视角：己方蓝 / 盟友黄 / 敌人红。
	if pv != null:
		eq(pv.view_faction, "F1", "★★ 选中 F1 后缩略图切到 F1 视角")
		eq(pv.zone_owner_color("F1"), _cfg.side_color_self, "★★ 己方区划 / 标识 = 蓝")
		eq(pv.zone_owner_color("GD1"), _cfg.side_color_ally, "★★ 盟友区划 / 标识 = 黄")
		eq(pv.zone_owner_color("F2"), _cfg.side_color_enemy, "★★ 敌方区划 / 标识 = 红")
	if card != null:
		var sb = card.get_theme_stylebox("panel")
		if sb is StyleBoxFlat:
			eq((sb as StyleBoxFlat).border_width_left, 2, "★ 选中的阵营面板是加粗琥珀金边（2px）")

	# 点提示 → 发信号，带上选中的阵营。
	await _click_at(tr.hint_rect().get_center())
	eq(entered.size(), 1, "★★ 选好之后点提示 → enter_requested 一次")
	if entered.size() == 1:
		eq(String(entered[0]), "F1", "★ 带的是选中的阵营")
	tr.queue_free()
	await process_frame

	# 单阵营：自动选中，不需要阵营面板。
	lv.playable_override = ["F1"]
	var tr2 = LevelTransitionRes.new()
	root.add_child(tr2)
	tr2.setup(_cfg, _font, c, lv)
	await _wait_ready(tr2)
	await process_frame
	eq(tr2.faction_panel_count(), 0, "★ 单阵营不出现阵营面板")
	ok(tr2.faction_row() == null, "★ 单阵营连阵营面板行都不建")
	ok(tr2.info_panel() != null and tr2.map_panel() != null, "（前提）两块面板都在")
	if tr2.info_panel() != null and tr2.map_panel() != null:
		# ★ 没有阵营面板行时，描述面板仍然吃满整列（与左面板同高）。
		near(tr2.info_panel().size.y, tr2.map_panel().size.y, 0.5,
			"★ 单阵营：描述面板与缩略图等高（整列都是它的）")
	eq(tr2.selected_faction(), "F1", "★ 单阵营自动选中 F1")
	ok(tr2.hint_text().contains("蓝方"), "★ 提示直接是「作为蓝方进入游戏」")
	eq(tr2.preview().view_faction, "F1", "★ 单阵营自动选中 ⇒ 缩略图直接按 F1 视角上色")
	var entered2: Array = []
	tr2.enter_requested.connect(func(fid: String): entered2.append(fid))
	await _click_at(tr2.hint_rect().get_center())
	eq(entered2.size(), 1, "★ 单阵营点提示直接进入")
	tr2.queue_free()
	lv.playable_override = []
	await process_frame
	ThemeRes.set_animations_enabled(true)


# ------------------------------------------------------------------
# 版式：阵营选项是描述面板下方的两块独立面板
# ------------------------------------------------------------------

## ★★ 用户口径（本轮）：「将选择阵营的两个选项抽出作为单独的两个面板（目前按钮是附属
##   在描述面板中）。这两个面板将放在描述面板下方，水平排列，边界要与其他面板对齐。」
##   这里不看像素长相，只钉住**结构**：谁是谁的父节点、谁在谁下方、边对得上不对得上。
func _test_panel_layout(tr) -> void:
	# 排版是 deferred 的（首帧才量得到 root 尺寸），多等两帧再量。
	await process_frame
	await process_frame
	var info_panel: Panel = tr.info_panel()
	var map_panel: Panel = tr.map_panel()
	var row: Control = tr.faction_row()
	ok(info_panel != null and map_panel != null, "（前提）缩略图 / 描述两块面板都在")
	ok(row != null, "★★ 多阵营时建了阵营面板行")
	var p0: Panel = tr.faction_panel(0)
	var p1: Panel = tr.faction_panel(1)
	ok(p0 != null and p1 != null, "（前提）两块阵营面板都在")
	if info_panel == null or map_panel == null or row == null or p0 == null or p1 == null:
		return

	var ir := info_panel.get_global_rect()
	var mr := map_panel.get_global_rect()
	var rr := row.get_global_rect()
	var r0 := p0.get_global_rect()
	var r1 := p1.get_global_rect()

	# 1) 从描述面板里抽出来了。
	ok(p0.get_parent() == row, "★★ 阵营面板挂在独立的面板行上")
	ok(not info_panel.is_ancestor_of(row), "★★ 阵营行不再是描述面板的子节点")

	# 2) 在描述面板下方、水平并排。
	ok(r0.position.y >= ir.end.y - 0.5,
		"★★ 阵营面板在描述面板下方（%.1f ≥ %.1f）" % [r0.position.y, ir.end.y])
	near(r0.position.y - ir.end.y, tr.gap(), 0.5, "★ 与描述面板的竖向间距 = gap")
	near(r0.position.y, r1.position.y, 0.5, "★★ 两块面板水平并排（同一个 y）")
	near(r0.size.x, r1.size.x, 0.5, "★ 两块等宽（平分整行）")
	near(r0.size.y, r1.size.y, 0.5, "★ 两块等高")
	near(r1.position.x - r0.end.x, tr.gap(), 0.5, "★ 两块之间的间距 = gap")

	# 3) 边界与上面两块面板逐边对齐。
	near(rr.position.x, ir.position.x, 0.5, "★★ 行左边界 = 描述面板左边界")
	near(rr.end.x, ir.end.x, 0.5, "★★ 行右边界 = 描述面板右边界")
	near(r0.position.x, mr.end.x + tr.gap(), 0.5, "★ 左边界 = 缩略图右边 + gap（与描述面板同一条竖线）")
	near(r1.end.x, ir.end.x, 0.5, "★★ 最后一块的右边界 = 描述面板右边界")
	near(r1.end.x, tr._root.size.x - tr.margin(), 0.5, "★ 最右边离屏幕右边缘 = 外留白 margin")
	near(r0.end.y, mr.end.y, 0.5, "★★ 底边 = 缩略图面板底边")
	near(r1.end.y, mr.end.y, 0.5, "★★ 底边（第二块）同样齐平")

	# 4) 描述面板：让出了一截高度，但仍然装得下自己的标题 + 简报（不许压字）。
	ok(ir.size.y < mr.size.y - 1.0, "★★ 描述面板比缩略图矮（下方让给了阵营面板）")
	ok(ir.size.y >= tr.desc_natural_height() - 0.5,
		"★★ 描述面板高度 ≥ 内容自然高度（%.1f ≥ %.1f）"
		% [ir.size.y, tr.desc_natural_height()])

	# 5) 三块加起来正好铺满内容区（没有谁悬空、也没有谁超出）。
	near(rr.position.y, ir.end.y + tr.gap(), 0.5, "★ 行顶 = 描述面板底 + gap")
	near(rr.end.y, mr.end.y, 0.5, "★★ 行底 = 缩略图底（右下角严丝合缝）")


# ------------------------------------------------------------------
# 面板滑入：过渡界面的所有面板都有滑入动效
# ------------------------------------------------------------------

## ★★ 用户口径：所有面板**同时**滑入，并且阵营选项到位时**尺寸不许变**（不许上跳/变大）。
##   断言：① 三块面板都从画面外起跑（同一帧 —— 没有错开）；
##        ② 起跑时阵营面板的尺寸 = 落位后的尺寸（尺寸只在排版定稿时定一次）；
##        ③ 跑完回到排版位置、完全不透明。
func _test_panel_slide() -> void:
	var c = CampaignRes.load_campaign(DEMO_DIR, _cfg)
	var lv = c.level("01_beachhead") if c != null else null
	if lv == null:
		return
	ThemeRes.set_animations_enabled(true)
	var tr = LevelTransitionRes.new()
	root.add_child(tr)
	tr.setup(_cfg, _font, c, lv)
	# 排版要**两遍**才定稿（首帧量到的简报高度不可信），所以滑入会比画面出现晚 1~2 帧。
	var wait_start: int = Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < wait_start and not tr.panel_slide_started():
		await process_frame
	ok(tr.panel_slide_started(), "★★ 排版定稿之后开始播滑入")
	# ★ 轮询到「正在跑」就立刻量：起跑点是 `_play_panel_slide()` 在**同一帧**写下的，
	#   这里不能再多等一帧 —— 首帧加载慢的时候会拍到动画中段（实测 x 已经滑进来 200px）。
	while Time.get_ticks_msec() < wait_start and not tr.panel_slide_active():
		await process_frame
	ok(tr.panel_slide_active(), "★★ 滑入正在跑")
	var mp: Panel = tr.map_panel()
	var ip: Panel = tr.info_panel()
	var f0: Panel = tr.faction_panel(0)
	if mp == null or ip == null or f0 == null:
		ok(false, "（前提）三块面板都在")
		return
	var final_left_x: float = tr.margin()
	var final_right_x: float = tr._root.size.x - tr.margin() - ip.size.x
	ok(mp.position.x < final_left_x - 1.0,
		"★★ 缩略图面板在最终位置**左侧**起跑（x=%.1f）" % mp.position.x)
	ok(ip.position.x > final_right_x + 1.0,
		"★★ 描述面板在最终位置**右侧**起跑（x=%.1f）" % ip.position.x)
	ok(f0.position.y > 1.0, "★★ 阵营面板在行内位置**下方**起跑（y=%.1f）" % f0.position.y)
	# ★ 三块同一帧都还是偏移的 = 同时起跑（没有一个在等前一个先走完）。
	ok(mp.position.x < final_left_x and ip.position.x > final_right_x
			and f0.position.y > 1.0,
		"★★ 三块面板**同时**起跑（没有错开）")
	var f0_size_before: Vector2 = f0.size

	var deadline: int = Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline and tr.panel_slide_active():
		await process_frame
	ok(not tr.panel_slide_active(), "★ 滑入会自己结束")
	near(mp.position.x, tr.margin(), 0.5, "★★ 落位后缩略图面板贴回 margin")
	near(ip.position.x + ip.size.x, tr._root.size.x - tr.margin(), 0.5,
		"★★ 落位后描述面板右边界贴回屏幕右边")
	near(f0.position.y, 0.0, 0.5, "★★ 落位后阵营面板回到行内位置")
	near(f0.modulate.a, 1.0, 0.01, "★ 滑入同时淡入（结束时完全不透明）")
	# ★★ 尺寸不变：起跑时与落位后必须一模一样（以前这里会突然长高 ~1/2，看着像向上吸附）。
	near(f0.size.x, f0_size_before.x, 0.001,
		"★★ 阵营面板宽度在滑入前后不变（%.1f）" % f0.size.x)
	near(f0.size.y, f0_size_before.y, 0.001,
		"★★ 阵营面板高度在滑入前后不变（%.1f）—— 不再「到位时上跳/变大」" % f0.size.y)
	tr.queue_free()
	await process_frame
	ThemeRes.set_animations_enabled(true)


# ------------------------------------------------------------------
# 3. main 接线
# ------------------------------------------------------------------

## ★★ 进度条时序（本轮口径）：从下方升起 → 实时进度 → 满后下滑 → **完全出画**才可进入。
## 用真实预加载（不做假进度）；只断言「位置 / 门槛」这几条。
func _test_bar_sequence() -> void:
	var c = CampaignRes.load_campaign(DEMO_DIR, _cfg)
	var lv = c.level("01_beachhead") if c != null else null
	if lv == null:
		return
	ThemeRes.set_animations_enabled(true)
	var tr = LevelTransitionRes.new()
	root.add_child(tr)
	tr.setup(_cfg, _font, c, lv)
	# 等第一次排版（deferred `_layout` 才会启动升起）
	for i in 3:
		await process_frame
	ok(tr.bar_intro_done() == false, "★ 刚出现时，进度条还在从下方升上来")
	ok(tr.bar_y() > tr.bar_home_y() + 10.0,
		"★★ 起点在目标位置下方（%.1f > %.1f）" % [tr.bar_y(), tr.bar_home_y()])
	ok(not tr.ready_to_enter(), "★★ 条还在画面里时不允许进入")
	# 实时进度：显示值必须等于真实加载值（没有追帧 / 保底时长）
	near(tr.progress_value(), tr._load_progress * 100.0, 0.001,
		"★★ 进度条实时 = 真实加载进度（无追赶）")

	var deadline: int = Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline and not tr.bar_intro_done():
		await process_frame
	ok(tr.bar_intro_done(), "★ 进度条升到位")
	near(tr.bar_y(), tr.bar_home_y(), 0.5, "★ 到位后 y = 目标位置")
	ok(not tr.bar_offscreen(), "★ 到位时条仍在画面里")
	ok(not tr.ready_to_enter(), "★★ 条在画面里（未下滑）时仍不允许进入")

	# ★★ 用户口径：条还在落画时提示必须**一点都看不见**。
	#   旧写法让提示与下滑同时淡入（EASE_OUT 前 1/3 就到九成），所以这里既查
	#   「ready 之前 alpha 恒为 0」，也查「ready 那一刻才刚开始淡入」。
	var hint_visible_while_bar := false
	deadline = Time.get_ticks_msec() + 6000
	while Time.get_ticks_msec() < deadline and not tr.ready_to_enter():
		if not tr.bar_offscreen() and tr._hint_label.modulate.a > 0.01:
			hint_visible_while_bar = true
		await process_frame
	ok(not hint_visible_while_bar, "★★ 进度条完全落画之前，提示文字始终不可见")
	ok(tr.ready_to_enter(), "★ 下滑结束后允许进入")
	ok(tr.bar_offscreen(), "★★ 只有条完全移出画面之后才 ready_to_enter")
	near(tr.progress_value(), 100.0, 0.001, "★ 进入时进度是 100")
	ok(tr._hint_label.modulate.a < 0.95,
		"★★ 条刚落画时提示才刚开始淡入（alpha=%.2f）" % tr._hint_label.modulate.a)

	# 淡入跑完（之后会进入呼吸，alpha 在 0.45~1 之间来回）⇒ 用「见过的最大值」判。
	var max_hint_alpha: float = tr._hint_label.modulate.a
	deadline = Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline and max_hint_alpha < 0.98:
		max_hint_alpha = maxf(max_hint_alpha, tr._hint_label.modulate.a)
		await process_frame
	ok(max_hint_alpha >= 0.98, "★ 提示文字最终完全浮现（最高 alpha=%.2f）" % max_hint_alpha)
	# 呼吸确实在跑：等它压暗一次（0.9s 半周期，给 2s 足够）。
	var min_hint_alpha: float = tr._hint_label.modulate.a
	deadline = Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline and min_hint_alpha > 0.9:
		min_hint_alpha = minf(min_hint_alpha, tr._hint_label.modulate.a)
		await process_frame
	ok(min_hint_alpha <= 0.9, "★ 淡入之后提示开始呼吸（最低 alpha=%.2f）" % min_hint_alpha)
	tr.queue_free()
	await process_frame
	ThemeRes.set_animations_enabled(true)


func _test_main_flow() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	ThemeRes.set_animations_enabled(true)
	main._on_level_entry_pressed("demo", "01_beachhead")
	# ★★ 打开转场（用户口径：战役界面先渐隐，随后过渡画面再渐显）：
	#    先出现一张全屏黑幕（推黑），过渡页在黑幕最黑时才建出来，最后黑幕淡出。
	ok(main.enter_fade() != null, "★★ 打开过渡画面时先推黑幕（战役界面渐隐）")
	await process_frame
	var tr = await _wait_transition(main)
	ok(tr != null, "★★ 单人关先挂出战役过渡画面")
	# 过渡页刚建出来时黑幕还在（渐显用的就是它）—— 页面不是「啪」地出现的。
	if tr != null and main.enter_fade() != null:
		ok(main.enter_fade().modulate.a > 0.3,
			"★★ 过渡画面是在黑幕底下建出来的（黑幕 alpha=%.2f）" % main.enter_fade().modulate.a)
	eq(main.game, null, "★ 过渡画面阶段还没有建世界")
	if tr == null:
		main.queue_free()
		return
	# 选 F2，让断言能证明「进的是玩家选的那一方」。
	ok(tr.select_faction("F2"), "选 F2")
	await _wait_ready(tr)
	ok(tr.ready_to_enter(), "（前提）过渡画面已经可以进入")
	ok(main.enter_fade() == null, "★★ 渐显结束后黑幕被拆掉（过渡画面完全可见）")
	await _click_at(tr.hint_rect().get_center())
	# ★★ 用户口径：点「进入」先黑屏淡入，再建游戏，最后从黑里淡出。
	var fade = main.enter_fade()
	ok(fade != null, "★★ 点「进入」之后出现了黑屏转场层")
	if fade != null:
		ok(fade.modulate.a < 0.95, "★ 黑幕正在推成全黑（alpha=%.2f）" % fade.modulate.a)
		ok(fade.color.a >= 0.99, "★ 黑幕颜色是不透明黑（alpha=%.2f）" % fade.color.a)
	var deadline: int = Time.get_ticks_msec() + 6000
	while Time.get_ticks_msec() < deadline and main.game == null:
		await process_frame
	# 建世界发生在黑屏底下：此刻黑幕必须还在、而且已经全黑。
	var black_at_build = main.enter_fade()
	ok(black_at_build != null, "★★ 建世界时黑幕仍然在（收过渡页 / 建世界的接缝被盖住）")
	if black_at_build != null:
		ok(black_at_build.modulate.a > 0.8,
			"★★ 建世界时屏幕是全黑的（alpha=%.2f）" % black_at_build.modulate.a)
	await process_frame
	ok(main.game != null, "★★ 过渡画面点「进入」之后建出了世界")
	if main.game != null:
		eq(String(main.game.world.my_faction), "F2", "★★ 用的是玩家在过渡画面里选的 F2")
	ok(main.level_transition() == null, "★ 进入后过渡画面被收掉")

	# 黑幕从全黑淡出 → 拆掉：游戏首帧亮起来之后不该再压着一层黑。
	deadline = Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline and main.enter_fade() != null:
		await process_frame
	ok(main.enter_fade() == null, "★★ 游戏首帧就绪后黑幕淡出并被拆掉")
	main.queue_free()
	await process_frame

	# Esc 取消：收掉过渡画面，留在菜单，不建世界。
	var main2 = await _spawn_main()
	if main2 == null:
		return
	main2._on_level_entry_pressed("demo", "01_beachhead")
	await process_frame
	var tr2 = await _wait_transition(main2)
	ok(tr2 != null, "（前提）第二局也挂出了过渡画面")
	if tr2 != null:
		tr2.cancel()
		var d2: int = Time.get_ticks_msec() + 4000
		while Time.get_ticks_msec() < d2 and main2.level_transition() != null:
			await process_frame
	ok(main2.level_transition() == null, "★ Esc/取消之后过渡画面被收掉")
	eq(main2.game, null, "★ 取消不会建世界")
	main2.queue_free()
	await process_frame


## 合作关跳过过渡（用户口径）。
func _test_coop_skips() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	main._on_level_entry_pressed("demo", "02_twin_line")
	await process_frame
	await process_frame
	ok(main.level_transition() == null, "★ 合作关不挂过渡画面")
	ok(main.game != null, "★ 合作关仍然直接开局（老路径不变）")
	main.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 工具
# ------------------------------------------------------------------

func _spawn_main() -> Node:
	var packed = load("res://view/main.tscn")
	if packed == null:
		return null
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	return main


func _wait_transition(main):
	var deadline: int = Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline and main.level_transition() == null:
		await process_frame
	return main.level_transition()


func _wait_ready(tr) -> void:
	var deadline: int = Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline and not tr.ready_to_enter():
		await process_frame


func _click_at(pos: Vector2) -> void:
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = pos
	root.push_input(down, true)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = pos
	root.push_input(up, true)
	await process_frame
	await process_frame
