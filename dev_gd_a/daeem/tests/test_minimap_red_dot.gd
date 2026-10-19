## test_minimap_red_dot.gd —— 小地图上的**红点性 AI 将领**标记 + 生成动效（本轮新增）。
##
## 需求（用户口径）：
##   1. 场上有红点性 AI 将领时，小地图用**小红菱形**标出它的位置（**只在它没被观测到**时）；
##   2. 红点刷出来时，在**生成位置**播一个「菱形由大变小」的动效（这条与迷雾无关，每次都播）；
##   3. ★ 被观测到（不在战争迷雾里）⇒ **不画常驻菱形**，生成动效照播；
##   4. ★ **只标将领**，不标附属兵。
##
## 本文件只测**数据 + 几何**（不截图）：标记集合、迷雾口径、动效曲线与到期回收、
## 事件里真的带出生格；「真的画了一帧」由小地图的两个诊断计数兜底。
extends "res://tests/test_case.gd"

const LevelRes = preload("res://logic/level.gd")
const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const RedDotAiRes = preload("res://logic/red_dot_ai.gd")
const FactionRes = preload("res://logic/faction.gd")
const MinimapRes = preload("res://view/minimap.gd")

const TMP_ROOT := "res://.tmp_minimap_red_dot"


func _initialize() -> void:
	_case_name = "test_minimap_red_dot"
	# ★ 本用例要 `await process_frame`（验证「真的画了一帧」）⇒ 不能走 `run_all()`
	#   （那个在 `cases.call()` 之后立刻打印摘要并 quit，协程还没跑完）。
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		_finish()
		return
	var w = _reddot_world(cfg)
	if w == null:
		_finish()
		return

	# ---- 1) 刷一波红点（真实数据路径：reddot_ai 参数 ⊕ 关卡覆盖）----
	var st: Dictionary = w.reddot_states[0] if not w.reddot_states.is_empty() else {}
	ok(not st.is_empty(), "（前提）这一局有一条红点状态（E1）")
	RedDotAiRes.update(w, cfg, 121.0)
	var gens: Array = _generals_of(w, "E1")
	eq(gens.size(), 1, "（前提）第 1 波刷出 1 位红点将领")
	if gens.is_empty():
		_finish()
		return
	var g = gens[0]
	var spawn_tile := Vector2i(g.tx, g.ty)

	# ---- 2) 事件里必须带出生格（动效的位置来源；视图不猜）----
	var events: Array = w.tick(0.001)
	var wave_evt: Dictionary = {}
	for e in events:
		if String((e as Dictionary).get("type", "")) == "red_dot_wave":
			wave_evt = e
			break
	ok(not wave_evt.is_empty(), "★ 刷兵之后推了 `red_dot_wave` 事件")
	if not wave_evt.is_empty():
		var spawns: Variant = wave_evt.get("spawns", null)
		ok(typeof(spawns) == TYPE_ARRAY, "★ 事件带 `spawns`（出生格数组）")
		if typeof(spawns) == TYPE_ARRAY:
			eq((spawns as Array).size(), 1, "★ 每位将领一条出生格")
			if not (spawns as Array).is_empty():
				var s: Dictionary = (spawns as Array)[0]
				v2i_eq(Vector2i(int(s.get("x", -1)), int(s.get("y", -1))), spawn_tile,
					"★ 事件里的出生格 = 将领实际落点")

	# ---- 3) 再摆两位**非红点**将领：一个玩家自己的、一个阵地性 AI 的 ----
	#      （标记只认 reddot；这两种都不该出现）
	var own = UnitRes.create(cfg, "own-g-1", "我方将领", Vector2i(2, 2), "p1",
		UnitRes.KIND_GENERAL, "1", "", "spearman", 0)
	if own != null:
		w.units.append(own)
	var garrison = UnitRes.create(cfg, "garrison-g-1", "驻防将领", Vector2i(3, 3), "E2",
		UnitRes.KIND_GENERAL, "1", "", "spearman", 0)
	if garrison != null:
		w.units.append(garrison)
	ok(w.ai_kind_of("E1") == LevelRes.AI_REDDOT, "（前提）E1 是红点性 AI")
	ok(w.ai_kind_of("E2") == LevelRes.AI_GARRISON, "（前提）E2 是阵地性 AI")

	# ---- 4) 小地图（纯数据 + 几何；不接相机也能建）----
	var mm = MinimapRes.new()
	mm.name = "TestMinimapRedDot"
	mm.size = Vector2(400.0, 400.0)
	root.add_child(mm)
	mm.setup(cfg, w, null, null)
	mm.set_process(false)                  # 动效由测试自己推进，别让帧时间搅进来

	ok(mm.map_rect().size.x > 0.0 and mm.map_rect().size.y > 0.0, "（前提）小地图拿到地图")
	ok(mm.is_red_dot_faction("E1"), "★ E1 被认成红点阵营")
	ok(not mm.is_red_dot_faction("E2"), "★ 阵地性 AI 不是红点阵营")
	ok(not mm.is_red_dot_faction("p1"), "★ 玩家自己永远不是红点阵营")

	# 先把视野清空：这一段只验「标记集合」，别让迷雾状态影响它（第 5 节单独验迷雾口径）
	var side := FactionRes.side_of("p1")
	w.fog.sight[side] = PackedByteArray()
	var marks: Array = mm.red_dot_marks()
	eq(marks.size(), 1, "★★ 只标**红点将领**（我方将领 / 驻防将领 / 附属兵都不标）")
	if not marks.is_empty():
		v2_near(marks[0], g.pos, 1e-4, "★ 标记位置 = 将领的逻辑坐标")

	# ---- 5) 常驻菱形只在**没被观测到**时画（本轮新口径） ----
	var cols: int = int(w.map.cols)
	var rows: int = int(w.map.rows)
	ok(not w.fog.unit_visible("p1", g), "（前提）这位红点将领现在在迷雾里")
	eq(mm.red_dot_marks().size(), 1, "★★ 迷雾里的红点将领画常驻菱形")
	# 5b) 整片视野点亮 ⇒ 它被观测到了 ⇒ 不画菱形（但生成动效照旧）
	var seen := PackedByteArray()
	seen.resize(cols * rows)
	seen.fill(1)
	w.fog.sight[side] = seen
	ok(w.fog.unit_visible("p1", g), "（前提）这位红点将领现在被观测到（不在迷雾里）")
	eq(mm.red_dot_marks().size(), 0, "★★ 被观测到之后不再画常驻菱形")
	mm.note_red_dot_spawns([Vector2(1.5, 1.5)])
	eq(mm.red_dot_fx_count(), 1, "★ 被观测到时**生成动效照播**（只隐藏常驻菱形）")
	mm.advance_red_dot_fx(float(cfg.minimap_red_dot_spawn_sec) + 0.01)
	eq(mm.red_dot_fx_count(), 0, "（清掉这一条探针动效，别影响后面的计数）")
	# 回到迷雾里，供后面的绘制断言使用
	w.fog.sight[side] = PackedByteArray()
	eq(mm.red_dot_marks().size(), 1, "（前提）重新走进迷雾 ⇒ 菱形回来")

	# ---- 6) 生成动效：位置归一、由大变小、到点回收 ----
	eq(mm.red_dot_fx_count(), 0, "（前提）一开始没有动效")
	mm.note_red_dot_spawns([Vector2(3.0, 4.0), [12, 18], Vector2i(7, 8)])
	eq(mm.red_dot_fx_count(), 3, "★ 一波多位将领 → 每条出生格一个动效")
	var pts: Array = mm.red_dot_fx_points()
	if pts.size() == 3:
		v2_near(pts[0], Vector2(3.0, 4.0), 1e-4, "Vector2 位置原样使用")
		v2_near(pts[1], Vector2(12.5, 18.5), 1e-4, "数组 [x,y] 按**格心**")
		v2_near(pts[2], Vector2(7.5, 8.5), 1e-4, "Vector2i 按**格心**")

	var sec: float = float(cfg.minimap_red_dot_spawn_sec)
	ok(sec > 0.0, "（前提）动效时长大于 0（config.minimap.red_dot_spawn_sec）")
	near(mm.red_dot_fx_radius(0.0), cfg.minimap_red_dot_spawn_from_r, 1e-3,
		"★★ 动效起点 = 配置的「起始」尺寸（大）")
	near(mm.red_dot_fx_radius(sec), cfg.minimap_red_dot_r, 1e-3,
		"★★ 动效终点 = 常驻尺寸（小）")
	ok(mm.red_dot_fx_radius(sec * 0.5) < cfg.minimap_red_dot_spawn_from_r,
		"★ 中途比起点小（确实在缩小）")
	ok(mm.red_dot_fx_radius(sec * 0.5) > cfg.minimap_red_dot_r,
		"★ 中途还没收到常驻尺寸（是动画，不是瞬间跳变）")
	near(mm.red_dot_fx_alpha(0.0), 1.0, 1e-3, "起步不透明")
	ok(mm.red_dot_fx_alpha(sec) <= 0.001, "播完时淡出到 0")
	ok(mm.red_dot_fx_alpha(sec * 0.5) > 0.5, "中途还看得见（只在尾段淡出）")

	# 真的画一帧：两个诊断计数都由 `_draw_red_dots()` 写入
	mm.queue_redraw()
	await process_frame
	await process_frame
	eq(mm.red_dot_mark_count, 1, "★ 真的画了 1 个常驻红点标记")
	eq(mm.red_dot_fx_draw_count, 3, "★ 真的画了 3 个生成动效")

	mm.advance_red_dot_fx(sec * 0.5)
	eq(mm.red_dot_fx_count(), 3, "时长过半：动效还在")
	mm.advance_red_dot_fx(sec * 0.5 + 0.01)
	eq(mm.red_dot_fx_count(), 0, "★ 时长走完：动效自动清掉（不会永远留在小地图上）")

	# 空数组 = 什么都不做（别把空波次变成一条 (0,0) 的假动效）
	mm.note_red_dot_spawns([])
	eq(mm.red_dot_fx_count(), 0, "空出生格表不产生动效")

	# ---- 7) 常驻菱形的**呼吸**（本轮新增）----
	var period: float = float(cfg.minimap_red_dot_breath_sec)
	var amp: float = float(cfg.minimap_red_dot_breath_amp)
	ok(period > 0.0 and amp > 0.0, "（前提）呼吸开着（周期 %.2fs / 振幅 %.2f）" % [period, amp])
	mm._breath_clock = 0.0
	near(mm.red_dot_mark_radius(), cfg.minimap_red_dot_r, 1e-4,
		"★ 呼吸相位 0 = 基准尺寸")
	mm._breath_clock = period * 0.25
	near(mm.red_dot_mark_radius(), cfg.minimap_red_dot_r * (1.0 + amp), 1e-4,
		"★★ 1/4 周期 = 最大（放大 amp）")
	mm._breath_clock = period * 0.75
	near(mm.red_dot_mark_radius(), cfg.minimap_red_dot_r * (1.0 - amp), 1e-4,
		"★★ 3/4 周期 = 最小（缩小 amp）")
	# 关掉振幅 ⇒ 恒为基准尺寸（「关掉呼吸」走同一条路）
	var saved_amp: float = cfg.minimap_red_dot_breath_amp
	cfg.minimap_red_dot_breath_amp = 0.0
	mm._breath_clock = period * 0.25
	near(mm.red_dot_mark_radius(), cfg.minimap_red_dot_r, 1e-4, "振幅 0 ⇒ 不呼吸")
	cfg.minimap_red_dot_breath_amp = saved_amp
	mm._breath_clock = 0.0

	mm.queue_free()
	await process_frame
	_cleanup()
	_finish()


## 打印摘要并按失败数决定退出码（与 `test_case.run_all()` 同一格式；
## 这里自己写一份是因为 `_run()` 是协程，不能走 run_all 的同步收尾）。
func _finish() -> void:
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 夹具
# ------------------------------------------------------------------

## 一局「玩家 p1 + 红点 E1 + 阵地性 E2」的合成关卡（`frontier` 图，够大）。
func _reddot_world(cfg):
	var level_json := {
		"map": "frontier",
		"name": "minimap red dot probe",
		"players": [{"faction": "p1"}],
		"factions": [
			{
				"id": "E1", "ai": "reddot", "base": [18, 18],
				"spawn_region": {"kind": "point", "x": 18, "y": 18, "radius": 3},
				"attack_target": {"kind": "point", "x": 7, "y": 2},
				"reddot_ai": {
					"wave_time_expr": "x+1", "general_count_expr": "1",
					"escort_count": 2, "spawn_radius": 3,
					"general_weights": [{"general": 1, "weight": 1}],
				},
			},
			{"id": "E2", "ai": "garrison", "base": [5, 18]},
		],
		"start_units": [],
		"objectives": [],
	}
	var lv = LevelRes.from_data(level_json, cfg, null, "minimap_red_dot_probe", "")
	ok(lv != null, "（前提）合成关卡能载入")
	if lv == null:
		return null
	var w = WorldRes.create_from_level(cfg, lv, "p1", ["p1"], true)
	ok(w != null, "（前提）合成世界能建出来")
	return w


func _generals_of(w, faction: String) -> Array:
	var out: Array = []
	for u in w.units:
		if u.alive and String(u.faction) == faction and u.is_general():
			out.append(u)
	return out


func _cleanup() -> void:
	if DirAccess.dir_exists_absolute(TMP_ROOT):
		DirAccess.remove_absolute(TMP_ROOT)
