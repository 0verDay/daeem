## test_story_dialogue.gd —— 左下通知栈：播报 + 对话（打字机 / 点击 / 自动 / 排队）。
extends "res://tests/test_case.gd"

const NoticeStackRes = preload("res://view/notice_stack.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")
const ThemeRes = preload("res://view/theme.gd")
const UiLayoutRes = preload("res://view/ui_layout.gd")

const DT := 1.0 / 60.0


func _initialize() -> void:
	_case_name = "test_story_dialogue"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	var prev := ThemeRes.animations_enabled()
	ThemeRes.set_animations_enabled(true)
	_test_typewriter_click(cfg)
	_test_fast_forward_click(cfg)
	_test_auto_advance(cfg)
	_test_queue(cfg)
	_test_broadcast_moves_up(cfg)
	_test_clear(cfg)
	ThemeRes.set_animations_enabled(prev)


func _test_typewriter_click(cfg) -> void:
	var s = _stack(cfg)
	if s == null:
		return
	var finished: Array = []
	s.dialogue_finished.connect(func(id: int) -> void: finished.append(id))
	var id: int = s.push_dialogue("测试对话，逐字显示。", {"type_sec": 0.01, "auto_sec": -1.0})
	ok(s.has_dialogue(), "★ 压入对话后处于激活状态")
	eq(s.dialogue_id(), id, "★ 返回的 id 与当前对话一致")
	ok(s.dialogue_typing(), "★ 打字机未完成")
	eq(s.advance_dialogue(), false, "★ 第一次推进只补全逐字")
	ok(not s.dialogue_typing(), "★ 逐字已补全")
	eq(s.advance_dialogue(), true, "★ 第二次推进才结束整条")
	s.tick(0.3)   # 等退场动画走完（finished 在退场后发出）
	eq(finished, [id], "★ 发出 dialogue_finished")
	ok(not s.has_dialogue(), "结束后没有活跃对话")
	_free_stack(s)


func _test_fast_forward_click(cfg) -> void:
	var s = _stack(cfg)
	if s == null:
		return
	var finished: Array = []
	s.dialogue_finished.connect(func(id: int) -> void: finished.append(id))
	var id: int = s.push_dialogue("点击快速通过", {"type_sec": 0.01, "auto_sec": -1.0})
	ok(s.dialogue_typing(), "（前提）点击前来不及打完")
	eq(s.fast_forward_dialogue(), true, "★★ 点击一步快速通过")
	s.tick(0.3)
	eq(finished, [id], "★★ 点击后对话 finished")
	ok(not s.has_dialogue(), "点击后没有活跃对话")
	_free_stack(s)


func _test_auto_advance(cfg) -> void:
	var s = _stack(cfg)
	if s == null:
		return
	var finished: Array = []
	s.dialogue_finished.connect(func(id: int) -> void: finished.append(id))
	var text := "自动推进"
	var type_sec := 0.01
	var auto_sec := 0.05
	var id: int = s.push_dialogue(text, {"type_sec": type_sec, "auto_sec": auto_sec})
	# 先走完逐字
	s.tick(float(text.length()) * type_sec + 0.02)
	ok(not s.dialogue_typing(), "（前提）逐字完成")
	s.tick(auto_sec + 0.02)
	s.tick(0.3)   # 退场动画结束才发 finished
	eq(finished, [id], "★ auto_sec 到期自动推进")
	ok(not s.has_dialogue(), "自动推进后没有活跃对话")
	_free_stack(s)


func _test_queue(cfg) -> void:
	var s = _stack(cfg)
	if s == null:
		return
	var ids: Array = []
	s.dialogue_finished.connect(func(id: int) -> void: ids.append(id))
	var a: int = s.push_dialogue("第一条", {"type_sec": 0.0, "auto_sec": -1.0})
	var b: int = s.push_dialogue("第二条", {"type_sec": 0.0, "auto_sec": -1.0})
	eq(s.dialogue_id(), a, "★★ 同一时刻只显示第一条")
	var y_before := s.line_y(0)
	eq(s.advance_dialogue(), true, "推进第一条")
	eq(s.dialogue_id(), -1, "★★ 退场期间不立刻起第二条")
	s.tick(0.1)
	ok(s.line_y(0) < y_before - 1.0, "★★ 旧对话在消失时上移（before=%.1f after=%.1f）" % [y_before, s.line_y(0)])
	s.tick(0.3)   # 第一条上移淡出后，第二条才接上
	eq(s.dialogue_id(), b, "★★ 队列里的第二条接上")
	ok(s.dialogue_text().contains("第二条"), "第二条文本正确")
	eq(s.advance_dialogue(), true, "推进第二条")
	s.tick(0.3)
	eq(ids, [a, b], "两条都发 finished")
	_free_stack(s)


func _test_broadcast_moves_up(cfg) -> void:
	var s = _stack(cfg)
	if s == null:
		return
	var pop: float = cfg.num("ui.broadcast.pop_sec", 0.22)
	var move: float = cfg.num("ui.broadcast.move_sec", 0.18)
	s.push("播报一行", Color.RED)
	s.tick(pop)
	var base_y: float = s.line_y(0)
	s.push_dialogue("对话出现，播报上移。", {"type_sec": 0.0, "auto_sec": -1.0})
	s.tick(move + 0.01)
	# 对话在最下面（index 0），播报被顶到 index 1。
	ok(s.line_text(0).contains("对话出现"), "★ 对话占最下面")
	ok(s.line_text(1).contains("播报一行"), "★ 播报在对话上面")
	ok(s.line_y(1) < base_y - 1.0, "★★ 对话出现后播报向上移位")
	_free_stack(s)


func _test_clear(cfg) -> void:
	var s = _stack(cfg)
	if s == null:
		return
	s.push("播报", Color.RED)
	s.push_dialogue("对话", {"type_sec": 0.0, "auto_sec": -1.0})
	ok(s.has_dialogue(), "（前提）有对话")
	s.clear_dialogue()
	ok(not s.has_dialogue(), "★ clear_dialogue 清掉对话")
	ok(s.line_count() >= 1, "播报保留")
	s.clear()
	eq(s.line_count(), 0, "clear 清空全部")
	_free_stack(s)


# ------------------------------------------------------------------
func _stack(cfg) -> NoticeStackRes:
	var s := NoticeStackRes.new()
	s.setup(cfg, FontLoaderRes.load_font(cfg))
	return s


func _free_stack(s) -> void:
	if s != null and is_instance_valid(s):
		s.free()
