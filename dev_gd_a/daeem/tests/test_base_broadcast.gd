## test_base_broadcast.gd —— 大本营升级**播报**（小地图上方横幅 + 事件口径）
##
## 需求：任何**指挥官阵营**（真人 + command AI）开始升级大本营时向所有玩家播报；
##   取消升级不撤播报；取消后再次升级会再播一条；阵地性 / 红点性 AI 不播。
##
## 这里钉三件事：
##   1. `upgrade_started` 事件带 `faction` / `level` / `target_level` / `secs`；
##   2. `world.is_commander_side()` 的分类（真人 / command = true，garrison / reddot = false）；
##   3. 横幅组件自己的队列行为（小地图上方、最新在下、旧的上移、左滑入、上浮淡出、颜色按阵营）。
extends "res://tests/test_case.gd"

const LevelRes = preload("res://logic/level.gd")
const BroadcastBannerRes = preload("res://view/broadcast_banner.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")
const ThemeRes = preload("res://view/theme.gd")
const UiLayoutRes = preload("res://view/ui_layout.gd")

const DT := 1.0 / 60.0

func _initialize() -> void:
	_case_name = "test_base_broadcast"
	run_all(_cases)

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_event_fields(cfg)
	_test_cancel_and_restart(cfg)
	_test_commander_filter(cfg)
	_test_banner_queue(cfg)
	_test_banner_animation(cfg)
	_test_banner_no_animation(cfg)


# ------------------------------------------------------------------
# 事件
# ------------------------------------------------------------------

func _test_event_fields(cfg) -> void:
	var w = _quiet(cfg)
	var base = _prepared_base(w)
	if base == null:
		return
	ok(w.start_building_upgrade(base.tx, base.ty, w.my_faction), "开始升二本")
	var evts: Array = w.tick(DT)
	var ev := _find(evts, "upgrade_started")
	ok(not ev.is_empty(), "★ 收到 upgrade_started（播报的来源）")
	if ev.is_empty():
		return
	eq(String(ev.get("kind", "")), "building_upgrade", "kind 仍是 building_upgrade")
	eq(String(ev.get("faction", "")), String(w.my_faction), "★ 带 faction（播报要用）")
	eq(int(ev.get("level", -1)), 1, "带当前等级")
	eq(int(ev.get("target_level", -1)), 2, "★ 带目标等级（播报文案用）")
	near(float(ev.get("secs", 0.0)), 40.0, 1e-6, "带实际读条秒数（定死那一档）")


func _test_cancel_and_restart(cfg) -> void:
	var w = _quiet(cfg)
	var base = _prepared_base(w)
	if base == null:
		return
	ok(w.start_building_upgrade(base.tx, base.ty, w.my_faction), "先开始一次")
	eq(_count(w.tick(DT), "upgrade_started"), 1, "★ 第 1 次开始 → 1 条播报事件")
	ok(w.cancel_building_upgrade(base.tx, base.ty, w.my_faction), "取消这次升级")
	var after_cancel: Array = w.tick(DT)
	eq(_count(after_cancel, "upgrade_started"), 0,
		"★★ 取消**不产生**任何播报事件（不撤、也不再播）")
	eq(_count(after_cancel, "upgrade_cancelled"), 1, "取消本身照旧有事件（只是没人播）")
	ok(w.start_building_upgrade(base.tx, base.ty, w.my_faction), "取消后再升一次")
	eq(_count(w.tick(DT), "upgrade_started"), 1,
		"★★ 取消后再升 → 又是一条播报（合计 2 条）")


# ------------------------------------------------------------------
# 阵营分类
# ------------------------------------------------------------------

func _test_commander_filter(cfg) -> void:
	var w = _quiet(cfg)
	var me := String(w.my_faction)
	ok(me != "", "（前提）世界有本机阵营")
	eq(w.is_commander_side(me), true, "★ 真人阵营 = 指挥官阵营")
	eq(w.is_commander_side(""), false, "空阵营不算")

	# ★★ 关卡数据里可玩阵营也可能写着 `ai: garrison`（给没被选中的一方用）：
	#    本机操作的那一方**必须仍然算指挥官阵营**（否则自己的播报被吞掉）。
	w.ai_kind_overrides[me] = LevelRes.AI_GARRISON
	eq(w.is_commander_side(me), true,
		"★★ 本机在操作 → 就算关卡写着 garrison 也照常播报")

	# 把本机挪走之后，它才真正是一方 AI：garrison / reddot 不播，commander 要播。
	var saved_me := String(w.my_faction)
	w.my_faction = ""
	eq(w.is_commander_side(me), false, "★★ 阵地性 AI 不播")
	w.ai_kind_overrides[me] = LevelRes.AI_REDDOT
	eq(w.is_commander_side(me), false, "★★ 红点性 AI 不播")
	w.ai_kind_overrides[me] = LevelRes.AI_COMMANDER
	eq(w.is_commander_side(me), true, "★ command AI = 指挥官阵营（要播）")
	w.ai_kind_overrides.erase(me)
	w.my_faction = saved_me
	eq(w.is_commander_side(me), true, "恢复本机阵营后照旧播报")


# ------------------------------------------------------------------
# 小地图上方的横幅
# ------------------------------------------------------------------

func _test_banner_queue(cfg) -> void:
	var banner = _banner(cfg)
	if banner == null:
		return
	ok(not banner.visible, "一开始不显示")
	eq(banner.line_count(), 0, "一开始没有播报")
	eq(banner.anchor_left, 0.0, "★ 贴左（小地图上方）")
	eq(banner.anchor_bottom, 1.0, "★ 贴底（跟着小地图）")
	near(banner.offset_left, UiLayoutRes.MAP_RECT.position.x, 1.0,
		"★ 左缘 = 小地图左缘")
	var gap: float = cfg.num("ui.broadcast.bottom_gap", 8.0)
	near(banner.offset_bottom,
		UiLayoutRes.MAP_RECT.position.y - gap - UiLayoutRes.DESIGN_H, 1.0,
		"★ 底边在小地图上沿之上 gap 像素")

	var red := Color(0.9, 0.2, 0.2)
	var yellow := Color(0.95, 0.8, 0.2)
	banner.push(banner.format_text("P1", 2), red)
	eq(banner.active_count(), 1, "塞进第 1 条")
	ok(banner.visible, "有内容就显示")
	ok(banner.line_text(0).contains("P1"), "文案里有阵营名（%s）" % banner.line_text(0))
	ok(banner.line_text(0).contains("2"), "文案里有目标等级")
	eq(banner.line_color(0), red, "★ 第 1 条用阵营色（红）")

	banner.push(banner.format_text("P2", 3), yellow)
	eq(banner.active_count(), 2, "第 2 条在最下面")
	ok(banner.line_text(0).contains("P2"), "★ 最新的一条在 index 0（最下面）")
	ok(banner.line_text(1).contains("P1"), "★ 旧的一条上移到 index 1")

	banner.push(banner.format_text("P3", 3), red)
	eq(banner.active_count(), 3, "★ 最多堆叠 3 条")
	ok(banner.line_text(0).contains("P3"), "最新的一条在最下面")
	ok(banner.line_text(2).contains("P1"), "最旧的一条在最上面")

	# 第 4 条挤掉最旧的一条（P1 先进入退场，不算 active）
	banner.push(banner.format_text("P4", 2), yellow)
	eq(banner.active_count(), 3, "★★ 满了之后仍是 3 条有效")
	eq(banner.line_count(), 4, "正在退场的 P1 还会多留一小会儿")
	ok(banner.is_exiting(3), "★ 最旧的 P1 正在向上淡出")
	ok(not banner.line_text(0).contains("P1"), "★★ 最旧的一条被挤掉（现在 index 0 是 P4）")
	ok(banner.line_text(0).contains("P4"), "最新的一条在 index 0")
	ok(banner.line_text(2).contains("P2"), "剩下三条是 P4/P3/P2")

	# 计时：每条各自淡出
	var hold: float = cfg.num("ui.broadcast.hold_sec", 4.0)
	var fade: float = cfg.num("ui.broadcast.fade_sec", 0.25)
	banner.tick(hold * 0.5)
	eq(banner.active_count(), 3, "停留期内还有 3 条有效")
	eq(banner.line_count(), 3, "被挤掉的 P1 已经淡出")
	near(banner.line_alpha(0), 1.0, 1e-6, "停留期内完全不透明")
	banner.tick(hold + fade * 2.0 + 0.01)
	eq(banner.line_count(), 0, "★ 时间到 → 全部清空")
	ok(not banner.visible, "清空后隐藏")
	_free_banner(banner)


func _test_banner_animation(cfg) -> void:
	var prev := ThemeRes.animations_enabled()
	ThemeRes.set_animations_enabled(true)
	var width := UiLayoutRes.MAP_RECT.size.x
	var pop: float = cfg.num("ui.broadcast.pop_sec", 0.22)
	var move: float = cfg.num("ui.broadcast.move_sec", 0.18)
	var hold: float = cfg.num("ui.broadcast.hold_sec", 4.0)
	var fade: float = cfg.num("ui.broadcast.fade_sec", 0.25)

	# 1) 从左往右滑入
	var slide = _banner(cfg)
	if slide == null:
		ThemeRes.set_animations_enabled(prev)
		return
	slide.push("P1", Color.RED)
	near(slide.line_x(0), -width, 1.0, "★ 新通知从左侧屏幕外开始")
	near(slide.line_alpha(0), 0.0, 1e-6, "同时从透明开始")
	slide.tick(pop * 0.5)
	ok(slide.line_x(0) > -width, "★ 半程时已经开始往右滑（%.1f）" % slide.line_x(0))
	slide.tick(pop * 0.5)
	near(slide.line_x(0), 0.0, 0.01, "★ 滑到位")
	near(slide.line_alpha(0), 1.0, 1e-6, "淡入完成")

	# 2) 新通知把旧的通知往上顶一格
	var stack = _banner(cfg)
	if stack == null:
		ThemeRes.set_animations_enabled(prev)
		return
	stack.push("P1", Color.RED)
	stack.tick(pop)
	var base_y: float = stack.line_y(0)
	stack.push("P2", Color.YELLOW)
	stack.tick(move + 0.001)
	ok(stack.line_y(1) < base_y - 1.0,
		"★★ 旧通知上移（%.1f < %.1f）" % [stack.line_y(1), base_y])
	near(stack.line_y(0), base_y, 1.0, "最新的一条留在最下面")

	# 3) 到期后向上飘 + 淡出
	var fader = _banner(cfg)
	if fader == null:
		ThemeRes.set_animations_enabled(prev)
		return
	fader.push("P1", Color.RED)
	fader.tick(pop)
	fader.tick(hold + 0.01)
	ok(fader.is_exiting(0), "到期后开始退场")
	var mid_y: float = fader.line_y(0)
	fader.tick(fade * 0.5)
	ok(fader.line_alpha(0) < 1.0, "退场时透明度下降")
	ok(fader.line_y(0) < mid_y - 0.5,
		"★★ 退场时向上飘（%.1f < %.1f）" % [fader.line_y(0), mid_y])
	fader.tick(fade * 0.5 + 0.01)
	eq(fader.line_count(), 0, "淡出结束后移除")

	ThemeRes.set_animations_enabled(prev)
	_free_banner(slide)
	_free_banner(stack)
	_free_banner(fader)


func _test_banner_no_animation(cfg) -> void:
	var banner = _banner(cfg)
	if banner == null:
		return
	var prev := ThemeRes.animations_enabled()
	ThemeRes.set_animations_enabled(false)
	banner.push(banner.format_text("P1", 2), Color.RED)
	near(banner.line_alpha(0), 1.0, 1e-6, "★ 关动画时直接不透明（不淡入）")
	var hold: float = cfg.num("ui.broadcast.hold_sec", 4.0)
	banner.tick(hold + 0.01)
	eq(banner.line_count(), 0, "★ 关动画时按 hold_sec 直接到期")
	ThemeRes.set_animations_enabled(prev)
	_free_banner(banner)


# ------------------------------------------------------------------
# 工具
# ------------------------------------------------------------------

func _quiet(cfg):
	cfg.combat_enabled = false
	var w = require_world(cfg)
	if w != null:
		for z in w.zones.zones:
			z["production"] = {"food": 0.0, "gold": 0.0, "population": 0.0}
	return w


## 大本营 + 够用资源 + 够门槛的将领（升二本要 2 名）。
func _prepared_base(w):
	if w == null:
		return null
	var base = w.find_base_of(w.my_faction)
	if base == null:
		ok(false, "（前提）有己方大本营")
		return null
	w.resources["food"] = 10000.0
	w.resources["gold"] = 10000.0
	base.level = 1
	var idx := 1
	var need: int = int(w.cfg.upgrade_need_generals("base", int(base.level)))
	while w.general_count_of(w.my_faction) < need and idx < 32:
		var g = w.create_general(w.my_faction, idx, 700 + idx)
		if g == null:
			break
		w.units.append(g)
		idx += 1
	return base


func _banner(cfg):
	var banner = BroadcastBannerRes.new()
	banner.setup(cfg, FontLoaderRes.load_font(cfg))
	return banner


func _free_banner(banner) -> void:
	if banner != null and is_instance_valid(banner):
		banner.free()


func _find(events: Array, type: String) -> Dictionary:
	for e in events:
		if typeof(e) == TYPE_DICTIONARY and String((e as Dictionary).get("type", "")) == type:
			return e
	return {}


func _count(events: Array, type: String) -> int:
	var n := 0
	for e in events:
		if typeof(e) == TYPE_DICTIONARY and String((e as Dictionary).get("type", "")) == type:
			n += 1
	return n
