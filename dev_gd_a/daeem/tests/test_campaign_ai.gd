## test_campaign_ai.gd —— 关卡里的 AI 指派（本轮口径）。
extends "res://tests/test_case.gd"

const WorldRes = preload("res://logic/world.gd")
const LevelRes = preload("res://logic/level.gd")
const GarrisonAiRes = preload("res://logic/garrison_ai.gd")
const GridRes = preload("res://logic/grid.gd")
const RedDotAiRes = preload("res://logic/red_dot_ai.gd")

const TMP_ROOT := "res://.tmp_campaign_ai_tests"
const MAP_ID := "frontier"

func _initialize() -> void:
	_case_name = "test_campaign_ai"
	run_all(_cases)
	_clean_tmp()

func _clean_tmp() -> void:
	if DirAccess.dir_exists_absolute(TMP_ROOT):
		_remove_dir(TMP_ROOT)

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_garrison(cfg)
	_test_garrison_defends_center(cfg)
	_test_garrison_alert_gating(cfg)
	_test_reddot_cfg(cfg)
	_test_reddot_march_tiles(cfg)
	_test_none_and_player(cfg)
	_test_general_roster_profile(cfg)

func _test_general_roster_profile(cfg) -> void:
	var w = _world(cfg, "gen_roster", {
		"factions": [{"id": "E1", "ai": "none", "base": [18, 18]}],
		"start_units": [{"faction": "E1", "kind": "general", "unit_type": "rider",
			"general_index": 5, "x": 18, "y": 18}]})
	if w == null:
		return
	var g = w.unit_by_id("general-E1-5")
	ok(g != null, "★ 名册号 5 → 运行时 id 是 general-E1-5（序号只决定 id）")
	if g == null:
		return
	eq(String(g.unit_type), "rider", "★ 兵种由「哪个将领」决定（这里选了骑手）")
	var rider_slot: int = cfg.general_slot_of_type("rider")
	eq(g.hp_max, cfg.general_hp_at(rider_slot),
		"★ 数值按骑手那一档（含将领血量倍率；与名册号 5 无关）")
	eq(int(g.general_index), cfg.general_slot_of_type("rider"),
		"★ 单位记的将领档 = 兵种在将领表里的下标（不是名册号 5）")

func _test_garrison(cfg) -> void:
	var w = _world(cfg, "garrison", {"factions": [{
		"id": "E1", "ai": "garrison", "base": [18, 18],
		"garrison_ai": {"min_retinue": 7},
	}], "start_units": [{"faction": "E1", "kind": "general", "unit_type": "spearman",
		"x": 17, "y": 17, "ai": "garrison", "zone": 9}]})
	ok(w != null, "能造出 garrison 关卡世界")
	if w == null:
		return
	eq(w.ai_kind_of("E1"), LevelRes.AI_GARRISON, "E1 是阵地性 AI")
	ok(w.find_base_of("E1") == null, "★ AI 阵营没有大本营")
	eq(int(w.garrison_ai_cfg("E1").get("min_retinue", -1)), 7, "★ 关卡 garrison_ai 覆盖生效")
	var gens := 0
	for u in w.units:
		if u.alive and String(u.faction) == "E1" and u.is_general():
			gens += 1
	ok(gens >= 1, "E1 有将领（%d 位）" % gens)

func _test_garrison_defends_center(cfg) -> void:
	var w = _world(cfg, "garrison_defend", {"factions": [{
		"id": "E1", "ai": "garrison", "base": [18, 18]}],
		"start_units": [{"faction": "E1", "kind": "general", "unit_type": "spearman",
			"x": 17, "y": 16, "ai": "garrison", "zone": 9}]})
	ok(w != null, "能造出 garrison 世界（守中心用例）")
	if w == null:
		return
	var g = null
	for u in w.units:
		if u.alive and String(u.faction) == "E1" and int(u.garrison_zone_id) >= 0 \
				and GarrisonAiRes.is_patrol_leader(w, u):
			g = u
			break
	ok(g != null, "E1 有一位「有归属区划」的带队守将")
	if g == null:
		return
	var z: Dictionary = w.zone_by_id(int(g.garrison_zone_id))
	ok(z != null and z.get("center", null) != null, "它负责的区划有中心")
	if z == null or z.get("center", null) == null:
		return
	var center: Vector2i = z["center"]

	z["capture_state"] = "reading"
	z["capture_faction"] = "enemy"
	z["progress"] = 0.2
	ok(GarrisonAiRes._center_under_attack(w, g, z), "★ 判据：敌对在读条 ⇒ 中心被攻击")
	z["capture_faction"] = String(g.faction)
	ok(not GarrisonAiRes._center_under_attack(w, g, z), "自己人在读条不算威胁")
	z["capture_faction"] = "enemy"
	z["capture_state"] = "frozen"
	ok(GarrisonAiRes._center_under_attack(w, g, z),
		"★ 冻住（双方同场、谁都没涨）**仍然算威胁**（敌人还在场上）")
	z["capture_state"] = "decaying"
	ok(not GarrisonAiRes._center_under_attack(w, g, z), "★ 敌人在退（decaying）不算威胁")
	z["capture_state"] = "reading"
	z["progress"] = 0.0
	ok(not GarrisonAiRes._center_under_attack(w, g, z), "进度为 0 不算威胁")

	z["progress"] = 0.2
	g.stop()
	g.drop_engagement()
	ok(not g.defending_center, "（前提）还没进入「守中心」状态")
	GarrisonAiRes.update(w, cfg, 1.0 / 60.0)
	ok(g.defending_center, "★★ 敌对在占我的区划中心 → 守将立刻进入「守中心」")
	ok(g.goal.distance_to(GridRes.center_of(center)) < 3.0,
		"★★ 它接到的命令目标是**区划中心**")

	z["capture_state"] = ""
	z["capture_faction"] = ""
	z["progress"] = 0.0
	# ★ 2026.10.28：驻地 AI 决策降到 10 Hz（`ai.garrison.decision_interval_sec`）。
	#   第二次 update 的 dt 只有 1/60，会被节流掉 —— 显式推进到下一决策点。
	GarrisonAiRes.force_next(w)
	GarrisonAiRes.update(w, cfg, 1.0 / 60.0)
	ok(not g.defending_center, "★ 威胁解除 → 退出「守中心」，恢复正常巡逻")

## ★★ 警戒唤醒（2026.11）：阵地性 AI 默认静止；只有敌军进入 10 格 / 敌对区划压境才巡逻。
##
## 三条用例各自造一个干净世界（互不污染巡逻路线 / 计时器）：
##   1. 静默：没有威胁时跑三个巡逻间隔也不生成路线；关掉开关则回到旧行为；
##   2. 部队临近：把敌对单位放到 9 格内 ⇒ 唤醒并开始巡逻；挪到 12 格 ⇒ 再次静止；
##   3. 区划压境：直接相邻 / 隔一个区划两种距离，配 `alert_zone_gap` 1 vs 2 对照。
func _test_garrison_alert_gating(cfg) -> void:
	var gc: Dictionary = cfg.ai_garrison_cfg()
	var saved_gap: int = int(gc.get("alert_zone_gap", 2))
	var saved_enabled: bool = bool(gc.get("alert_enabled", true))

	# ---- 1) 静默 + A/B 回退开关 ----
	var w1 = _alert_world(cfg, "alert_dormant")
	if w1 != null:
		var g1 = _first_patrol_leader(w1)
		ok(g1 != null, "（前提）静默世界有一位带队守将")
		if g1 != null:
			_clear_zone_owners(w1)
			_tick_ai(w1, cfg, 1.0)
			ok(not bool(g1.garrison_alert_active), "★ 没有威胁 ⇒ 不进入警戒")
			_tick_ai(w1, cfg, 6.0)
			ok(not bool(g1.garrison_alert_active), "★ 静默期一直保持静止")
			ok(g1.patrol_points.is_empty(), "★★ 静默期不生成巡逻路线（= 没启动巡逻）")
			ok(g1.patrol_timer <= 0.0, "★ 静默期巡逻计时器保持归零")
			# A/B：关掉开关 = 旧行为（一定会巡逻）。
			gc["alert_enabled"] = false
			_tick_ai(w1, cfg, 6.0)
			ok(not g1.patrol_points.is_empty(), "★ 关掉 alert_enabled ⇒ 回到旧行为（会巡逻）")
			gc["alert_enabled"] = saved_enabled

	# ---- 2) 部队临近（10 格）----
	var w2 = _alert_world(cfg, "alert_troop")
	if w2 != null:
		var g2 = _first_patrol_leader(w2)
		ok(g2 != null, "（前提）部队临近世界有一位带队守将")
		if g2 != null:
			_clear_zone_owners(w2)
			_tick_ai(w2, cfg, 0.6)
			ok(not bool(g2.garrison_alert_active), "（前提）附近没有敌军 ⇒ 静止")
			var e = _hostile_at(w2, g2, 9.0)
			ok(e != null, "（前提）刷出一个敌对单位")
			_tick_ai(w2, cfg, 0.6)
			ok(bool(g2.garrison_alert_active), "★★ 敌军进入 9 格 ⇒ 唤醒")
			_tick_ai(w2, cfg, 5.0)
			ok(not g2.patrol_points.is_empty() or not g2.path.is_empty(),
				"★★ 唤醒后真的开始巡逻（有路线 / 有路径）")
			# 敌人退到 12 格 ⇒ 下一次复检应当再次静止。
			e.pos = g2.pos + Vector2(12.0, 0.0)
			e.sync_tile(w2.map)
			_tick_ai(w2, cfg, 1.0)
			ok(not bool(g2.garrison_alert_active), "★★ 敌军退出 10 格 ⇒ 重新静止")

	# ---- 3) 区划压境（区划图步数）----
	var w3 = _alert_world(cfg, "alert_zone")
	if w3 != null:
		var g3 = _first_patrol_leader(w3)
		ok(g3 != null, "（前提）区划压境世界有一位带队守将")
		if g3 != null:
			_clear_zone_owners(w3)
			var zid: int = int(g3.garrison_zone_id)
			var near1: Array = w3.zones.neighbors_of(zid)
			ok(not near1.is_empty(), "★★ 区划邻接表已建好（有直接相邻区划）")
			# 邻接表必须是**真的共享一条边**（不能只靠包围盒 / 斜角）。
			var adj_ok := true
			for nid in near1:
				var nz: Variant = w3.zones.zones_by_id.get(int(nid), null)
				if nz == null:
					adj_ok = false
					continue
				var touch := false
				for t in (nz as Dictionary)["tiles"]:
					var tv: Vector2i = t
					for d in GridRes.DIRS4:
						var oz: Variant = w3.zones.zone_at(tv.x + d.x, tv.y + d.y)
						if oz != null and int((oz as Dictionary)["id"]) == zid:
							touch = true
							break
					if touch:
						break
				if not touch:
					adj_ok = false
			ok(adj_ok, "★★ 邻接表里的每一对区划都真的共享一条边（不是包围盒 / 斜角）")
			var within2: Array = w3.zones.zones_within(zid, 2)
			ok(within2.has(zid) and within2.size() > near1.size(),
				"★★ zones_within(2) 比直接相邻多出一圈")
			var far2: int = -1
			for nid in within2:
				var n := int(nid)
				if n != zid and not near1.has(n):
					far2 = n
					break
			ok(far2 >= 0, "（前提）存在「隔一个区划」的区划")
			if far2 >= 0:
				var z2: Dictionary = w3.zones.zones_by_id[far2]
				z2["owner"] = "enemy"
				# 判据层：gap=1 看不到「隔一个区划」，gap=2 看得到。
				var z_self: Dictionary = w3.zones.zones_by_id[zid]
				ok(not GarrisonAiRes._hostile_zone_within(w3, g3, z_self, 1),
					"★ gap=1：隔一个区划的敌人不算压境")
				ok(GarrisonAiRes._hostile_zone_within(w3, g3, z_self, 2),
					"★★ gap=2：隔一个区划的敌人算压境")
				# 决策层：用配置切 gap，确认守将真的从「静止」翻成「警戒」。
				gc["alert_zone_gap"] = 1
				_tick_ai(w3, cfg, 1.0)
				ok(not bool(g3.garrison_alert_active),
					"★ gap=1 时守将保持静止（隔一个区划不唤醒）")
				gc["alert_zone_gap"] = 2
				_tick_ai(w3, cfg, 1.0)
				ok(bool(g3.garrison_alert_active),
					"★★ gap=2 时守将被唤醒（区划压境）")
				# 敌人那格变回无主 ⇒ 应当再次静止。
				z2["owner"] = ""
				_tick_ai(w3, cfg, 1.0)
				ok(not bool(g3.garrison_alert_active), "★★ 敌对区划失去归属 ⇒ 重新静止")
	gc["alert_zone_gap"] = saved_gap
	gc["alert_enabled"] = saved_enabled


func _alert_world(cfg, name: String):
	return _world(cfg, name, {"factions": [{
		"id": "E1", "ai": "garrison", "base": [18, 18]}],
		"start_units": [{"faction": "E1", "kind": "general", "unit_type": "spearman",
			"x": 17, "y": 16, "ai": "garrison", "zone": 9}]})


func _first_patrol_leader(w):
	for u in w.units:
		if u.alive and String(u.faction) == "E1" and int(u.garrison_zone_id) >= 0 \
				and GarrisonAiRes.is_patrol_leader(w, u):
			return u
	return null


func _clear_zone_owners(w) -> void:
	for z in w.zones.zones:
		(z as Dictionary)["owner"] = ""


## 在离守将 `dist` 格处放一个敌对单位（只改坐标，不跑 tick —— 判定只看 pos）。
func _hostile_at(w, g, dist: float):
	var e = w.spawn_enemy(g.tx, g.ty)
	if e == null:
		return null
	e.pos = g.pos + Vector2(dist, 0.0)
	e.sync_tile(w.map)
	return e


## 手动推进守军 AI：每次 force_next 让决策不被节流掉（与 test 里其它地方同一做法）。
func _tick_ai(w, cfg, seconds: float, dt: float = 0.1) -> void:
	var n: int = maxi(1, int(round(seconds / dt)))
	for i in n:
		GarrisonAiRes.force_next(w)
		GarrisonAiRes.update(w, cfg, dt)


func _test_reddot_cfg(cfg) -> void:
	var w = _world(cfg, "reddot", {"factions": [{
		"id": "E1", "ai": "reddot", "base": [18, 18],
		"spawn_region": {"kind": "point", "x": 18, "y": 18, "radius": 2},
		"attack_target": {"kind": "point", "x": 2, "y": 11},
		"reddot_ai": {"wave_time_expr": "2x+1", "general_count_expr": "x+2", "escort_count": 5},
	}]})
	ok(w != null, "能造出 reddot 关卡世界")
	if w == null:
		return
	eq(w.ai_kind_of("E1"), LevelRes.AI_REDDOT, "E1 是红点性 AI")
	eq(String(w.reddot_ai_cfg("E1").get("wave_time_expr", "")), "2x+1", "★ 关卡 reddot_ai 覆盖生效")
	eq(int(w.reddot_ai_cfg("E1").get("escort_count", -1)), 5, "★ 共享附属单位数量按关卡覆盖")
	ok(w.reddot_states.size() == 1, "红点状态表建了一条（E1）")
	if w.reddot_states.size() == 1:
		eq(String((w.reddot_states[0] as Dictionary).get("faction", "")), "E1", "那一方是 E1")

## ★★ 关卡里那一方的 `reddot_ai` fixture（`rd_extra` 是额外的覆盖键，通常给 march_tiles）。
func _reddot_fac(rd_extra: Dictionary) -> Dictionary:
	var rd := {"general_count_expr": "2"}
	for k in rd_extra.keys():
		rd[k] = rd_extra[k]
	return {
		"id": "E1", "ai": "reddot", "base": [18, 18],
		"spawn_region": {"kind": "point", "x": 18, "y": 18, "radius": 2},
		"attack_target": {"kind": "point", "x": 1, "y": 1},
		"reddot_ai": rd,
	}

func _test_reddot_march_tiles(cfg) -> void:
	# ★★ 走**真实数据路径**：`march_tiles` 写在**关卡 JSON** 的 `reddot_ai` 里，
	#    由 `config.ai.reddot` ⊕ 关卡覆盖合并进 `params`。
	#    ⚠️ 这条用例原来是把 `w.reddot_states[0]["params"]["march_tiles"]` **直接赋值**的 ——
	#    绕开了合并，于是「config 漏声明 march_tiles ⇒ 关卡这个键被白名单丢掉」的 bug
	#    一直测不出来（红点将领只会退回单点目标，永远不按 march_tiles 随机行军）。
	var t1 := Vector2i(18, 18)
	var t2 := Vector2i(19, 18)
	var pts: Array = RedDotAiRes._march_points([[t1.x, t1.y], [t2.x, t2.y]])
	eq(pts.size(), 2, "★ `_march_points` 解析出 2 个目标点")
	eq(pts[0], GridRes.center_of(t1), "★ 目标点 = 那一格的中心")

	# 1) 先造一个**不写** march_tiles 的探针世界，只为挑两个可站人的格子当行军目标。
	var probe = _world(cfg, "reddot_march_probe", {"factions": [_reddot_fac({})]})
	ok(probe != null, "能造出 reddot 探针世界（march_tiles 用例）")
	if probe == null:
		return
	var near: Array = []
	for r in range(0, 6):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if near.size() >= 2:
					break
				var t := Vector2i(18 + dx, 18 + dy)
				if near.has(t):
					continue
				if not probe.map.tile_exists(t.x, t.y) or not probe.map.terrain_walkable(t.x, t.y):
					continue
				if probe.building_at(t.x, t.y) != null:
					continue
				near.append(t)
	ok(near.size() >= 2, "找到两个可站人的格子当行军目标")
	if near.size() < 2:
		return
	var raw: Array = []
	for t in near:
		raw.append([t.x, t.y])

	# 2) 把这两个格子写进**关卡数据**，造真正的世界。
	var w = _world(cfg, "reddot_march", {"factions": [_reddot_fac({"march_tiles": raw})]})
	ok(w != null, "能造出 reddot 关卡世界（march_tiles 用例）")
	if w == null or w.reddot_states.is_empty():
		ok(false, "红点状态表建起来了")
		return
	# ★★ 根因断言：关卡写的 march_tiles 必须经 `config.ai.reddot` 的声明合并进 params
	#    （漏声明 ⇒ `world._ai_cfg_with_override` 的白名单把它丢掉，这一条当场变红）。
	ok(not w.reddot_ai_cfg("E1").get("march_tiles", []).is_empty(),
		"★★ 关卡 `reddot_ai.march_tiles` 经 config 合并进了 params")

	RedDotAiRes.update(w, cfg, 61.0)
	var goals: Array = []
	for u in w.units:
		if u.alive and String(u.faction) == "E1" and u.is_general():
			goals.append(u.goal)
	ok(goals.size() >= 1, "★ 第 1 波刷出了将领（%d 位）" % goals.size())
	var allowed: Array = []
	for t in near:
		allowed.append(GridRes.center_of(t))
	for g in goals:
		var hit := false
		for c in allowed:
			if (g as Vector2).distance_to(c) < 3.0:
				hit = true
		ok(hit, "★★ 每一位将领的行军目标都落在 march_tiles 里（%s）" % str(g))

func _test_none_and_player(cfg) -> void:
	var w = _world(cfg, "none", {"factions": [
		{"id": "E1", "ai": "none", "base": [18, 18]}]})
	ok(w != null, "能造出 none 关卡世界")
	if w == null:
		return
	eq(w.ai_kind_of("E1"), LevelRes.AI_NONE, "★ ai: none 的阵营这一局不动")
	eq(w.ai_kind_of("p1"), LevelRes.AI_NONE, "★ 玩家席位不算 AI")
	ok(w.find_base_of("p1") != null, "玩家 p1 有大本营")

func _world(cfg, name: String, patch: Dictionary):
	var level_json := {
		"map": MAP_ID, "name": name,
		"players": [{"faction": "p1"}],
		"start_units": [],
	}
	for k in patch.keys():
		level_json[k] = patch[k]
	var path := "%s/%s.json" % [TMP_ROOT, name]
	_write(path, JSON.stringify(level_json))
	var lcls := script_at("res://logic/level.gd")
	if lcls == null:
		return null
	var lv = lcls.load_level(null, path, cfg)
	if lv == null:
		ok(false, "关卡能载入：%s" % name)
		return null
	return WorldRes.create_from_level(cfg, lv, "p1", ["p1"], true)

func _write(path: String, text: String) -> void:
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		ok(false, "能写临时关卡：%s" % path)
		return
	f.store_string(text)
	f.close()

func _remove_dir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for sub in d.get_directories():
		_remove_dir(path.path_join(sub))
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)
