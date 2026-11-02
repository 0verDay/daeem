## bench_see_ai.gd —— 批量跑 **see_ai（看海）** 对局并打印对局信息（AI vs AI，只读统计）。
##
## 用途：调完数值之后看「两家 commander AI 自己打」会打成什么样 —— 胜率 / 时长 / 节奏 /
## 产能 / 交换比 / 兵种构成 / 科技选择。**不改任何数值**，只读。
##
## 跑法（环境变量给轮数与单局上限）：
##
##   SEE_AI_ROUNDS=10 SEE_AI_CAP=1200 godot --headless --path daeem --script tests/bench_see_ai.gd
##
##   · SEE_AI_ROUNDS 默认 1；SEE_AI_CAP 默认 60（**模拟秒**，不是墙钟）
##   · 每轮换一个固定盐（`create_from_level(seed_value = 轮次)`），同参数可复现
##   · 一局 20 分钟模拟 ≈ 25~95 秒墙钟（10 轮约 8 分钟）
##
## 装配口径与 `view/game_scene3d.gd` 的 `start_ai_observer()` 一致：
##   · create_from_level(..., observer_mode = true)
##   · 参战双方全部覆盖成 commander，难度 normal
##   · 起手资源 / 派系 / 地图 / 目标都来自关卡数据 ai_test_battle（p1 王朝 / p2 帝国）
##   · 终局判定：大本营被拆 → 负；或**关卡目标**达成（p1 拿到 zone 0 / p2 拿到 zone 2）
##     —— 观战方自己没有 objective_state，所以这里逐帧按同一套规则自己判。
## ⚠️ 与 `require_config()` 的区别：这里用**干净的** load_default()（维护费 / 科技扣金都开着），
##    否则跑到中后期会因为「测试关掉了持续消耗」而失真。
extends "res://tests/test_case.gd"

const CampaignRes = preload("res://logic/campaign.gd")
const WorldRes = preload("res://logic/world.gd")
const LevelRes = preload("res://logic/level.gd")
const ConfigRes = preload("res://logic/config.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const LEVEL_ID := "ai_test_battle"
## 桌面端 `sim.step_sec = 0` ⇒ 每个渲染帧推进一次；按 60 fps 取 1/60。
const DT := 1.0 / 60.0

func _initialize() -> void:
	_case_name = "bench_see_ai"
	_run()

func _env_int(key: String, def: int) -> int:
	var v := OS.get_environment(key)
	return def if v == "" else int(v)

func _env_float(key: String, def: float) -> float:
	var v := OS.get_environment(key)
	return def if v == "" else float(v)

func _run() -> void:
	var rounds := _env_int("SEE_AI_ROUNDS", 1)
	var cap := _env_float("SEE_AI_CAP", 60.0)
	print("[start] rounds=%d cap=%.0fs dt=1/60" % [rounds, cap])
	var started := Time.get_ticks_msec()
	var rows: Array = []
	for r in rounds:
		var t0 := Time.get_ticks_msec()
		var row := _play(r + 1, cap)
		row["wall"] = (Time.get_ticks_msec() - t0) / 1000.0
		_print_row(row)
		rows.append(row)
	_print_aggregate(rows, (Time.get_ticks_msec() - started) / 1000.0)
	quit(0)


func _fmt_time(sec: float) -> String:
	var s := int(round(sec))
	return "%d:%02d" % [s / 60, s % 60]


func _avg(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var sum := 0.0
	for v in values:
		sum += float(v)
	return sum / float(values.size())


func _play(idx: int, cap: float) -> Dictionary:
	var cfg = ConfigRes.load_default()
	if cfg == null:
		return {"round": idx, "error": "config 载入失败"}
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	if camp == null:
		return {"round": idx, "error": "战役载入失败"}
	var level = camp.level(LEVEL_ID)
	if level == null:
		return {"round": idx, "error": "关卡载入失败"}

	var seats: Array = level.seats()
	var overrides: Dictionary = {}
	var profiles: Dictionary = {}
	for meta in level.faction_meta:
		if typeof(meta) != TYPE_DICTIONARY:
			continue
		var fid := String((meta as Dictionary).get("id", ""))
		if fid == "":
			continue
		overrides[fid] = LevelRes.AI_COMMANDER
		profiles[fid] = {"difficulty": "normal"}
	var w = WorldRes.create_from_level(cfg, level, String(seats[0]), seats, true,
		overrides, profiles, idx, true)
	if w == null:
		return {"round": idx, "error": "世界装配失败"}

	var losses := {"p1": 0, "p2": 0}
	var built := {"p1": 0, "p2": 0}
	var bld_lost := {"p1": 0, "p2": 0}
	var gens_lost := {"p1": 0, "p2": 0}
	var comp := {"p1": {}, "p2": {}}
	var first_contact := -1.0
	var first_blood := -1.0
	var first_bld_down := -1.0
	var peak_units := 0
	var t := 0.0
	var end_reason := "cap"
	var winner := ""

	while t < cap:
		var evs: Array = w.tick(DT)
		t += DT
		for e in evs:
			var ev: Dictionary = e
			var et := String(ev.get("type", ""))
			if et == "kill":
				var u = ev.get("unit", null)
				if u != null:
					var f := String(u.faction)
					if losses.has(f):
						losses[f] = int(losses[f]) + 1
					if gens_lost.has(f) and u.is_general():
						gens_lost[f] = int(gens_lost[f]) + 1
					if first_blood < 0.0:
						first_blood = t
			elif et == "unit_recruited" or et == "zone_unit_recruited":
				var nu = ev.get("unit", null)
				if nu != null:
					var nf := String(nu.faction)
					if built.has(nf):
						built[nf] = int(built[nf]) + 1
						var table: Dictionary = comp[nf]
						var ut := String(nu.unit_type)
						# 招来的「将领」也走 zone_unit_recruited（它的 unit_type 是原生兵种名）
						# —— 加个后缀，免得把「招到一位长弓兵型将领」看成「造了一个长弓兵」。
						if et == "zone_unit_recruited":
							ut = ut + "(将)"
						table[ut] = int(table.get(ut, 0)) + 1
			elif et == "unit_hit" or et == "building_hit":
				if first_contact < 0.0:
					first_contact = t
			elif et == "building_down":
				var bd = ev.get("building", null)
				if bd != null:
					var bf := String(bd.owner)
					if bld_lost.has(bf):
						bld_lost[bf] = int(bld_lost[bf]) + 1
					if first_bld_down < 0.0:
						first_bld_down = t
					if bd.type == "base" and (bf == "p1" or bf == "p2"):
						end_reason = "基地被拆"
						winner = "p2" if bf == "p1" else "p1"
						break

		if int(w.frame_serial) % 30 == 0:
			peak_units = maxi(peak_units, w.units.size())
			if end_reason == "基地被拆":
				break
			var b1 = w.find_base_of("p1")
			var b2 = w.find_base_of("p2")
			if b1 == null or b2 == null:
				end_reason = "基地被拆"
				winner = "p2" if b1 == null and b2 != null else ("p1" if b2 == null and b1 != null else "draw")
				break
			var z0 = w.zone_by_id(0)
			var z2 = w.zone_by_id(2)
			if z0 != null and String(z0.owner) == "p1":
				end_reason = "目标区划"
				winner = "p1"
				break
			if z2 != null and String(z2.owner) == "p2":
				end_reason = "目标区划"
				winner = "p2"
				break

	var row: Dictionary = {
		"round": idx, "time": t, "end": end_reason, "winner": winner,
		"first_contact": first_contact, "first_blood": first_blood,
		"first_bld_down": first_bld_down, "peak_units": peak_units,
		"losses": losses, "built": built, "bld_lost": bld_lost,
		"gens_lost": gens_lost, "comp": comp,
	}
	for fid in ["p1", "p2"]:
		var base = w.find_base_of(fid)
		var zones := 0
		for z in w.zones.zones:
			if String((z as Dictionary).get("owner", "")) == fid:
				zones += 1
		var pool: Dictionary = {}
		var pv: Variant = w.ai_faction_resources.get(fid, null)
		if typeof(pv) == TYPE_DICTIONARY:
			pool = pv
		var gens := 0
		var units_n := 0
		for u in w.units:
			if u == null or not u.alive or String(u.faction) != fid:
				continue
			units_n += 1
			if u.is_general():
				gens += 1
		row[fid] = {
			"base_lv": w.base_level_of(fid),
			"base_hp": -1.0 if base == null else float(base.hp),
			"base_hp_max": -1.0 if base == null else float(base.hp_max),
			"zones": zones, "gens": gens, "units": units_n,
			"food": float(pool.get("food", 0.0)),
			"gold": float(pool.get("gold", 0.0)),
			"techs": int(w.tech.active_count(fid)) if w.tech != null else 0,
			"tech_ids": w.tech.active_ids(fid) if w.tech != null else [],
		}
	var z0o := ""
	var z2o := ""
	var zz0 = w.zone_by_id(0)
	var zz2 = w.zone_by_id(2)
	if zz0 != null:
		z0o = String(zz0.owner)
	if zz2 != null:
		z2o = String(zz2.owner)
	row["z0"] = z0o
	row["z2"] = z2o
	return row


func _print_row(row: Dictionary) -> void:
	if row.has("error"):
		print("[round %02d] ERROR %s" % [int(row.get("round", 0)), String(row["error"])])
		return
	var r := int(row["round"])
	var w := String(row["winner"])
	print("[round %02d] 时长 %s 结束=%s 胜=%s 首次接触 %s 首杀 %s 首次拆建筑 %s 峰值单位 %d"
		% [r, _fmt_time(float(row["time"])), String(row["end"]),
		   ("draw" if w == "" else w),
		   ("—" if float(row["first_contact"]) < 0.0 else _fmt_time(float(row["first_contact"]))),
		   ("—" if float(row["first_blood"]) < 0.0 else _fmt_time(float(row["first_blood"]))),
		   ("—" if float(row["first_bld_down"]) < 0.0 else _fmt_time(float(row["first_bld_down"]))),
		   int(row["peak_units"])])
	for fid in ["p1", "p2"]:
		var s: Dictionary = row[fid]
		var hp_pct := 0.0
		if float(s["base_hp_max"]) > 0.0:
			hp_pct = float(s["base_hp"]) / float(s["base_hp_max"]) * 100.0
		print("[round %02d]   %s 本营Lv%d(血%d/%d %.0f%%) 区划%d 将%d 兵%d 粮%d 金%d 科技%d 造%d 损%d 建筑损%d 将领阵亡%d"
			% [r, fid, int(s["base_lv"]), int(s["base_hp"]), int(s["base_hp_max"]), hp_pct,
			   int(s["zones"]), int(s["gens"]), int(s["units"]), int(s["food"]),
			   int(s["gold"]), int(s["techs"]), int(row["built"][fid]),
			   int(row["losses"][fid]), int(row["bld_lost"][fid]),
			   int(row["gens_lost"][fid])])
	print("[round %02d]   目标区划：zone0=%s（p1 要） zone2=%s（p2 要） 墙钟 %.1fs"
		% [r, ("无主" if String(row["z0"]) == "" else String(row["z0"])),
		   ("无主" if String(row["z2"]) == "" else String(row["z2"])), float(row["wall"])])
	for fid in ["p1", "p2"]:
		var table: Dictionary = row["comp"][fid]
		var keys: Array = table.keys()
		keys.sort_custom(func(a, b): return int(table[a]) > int(table[b]))
		var parts: Array = []
		for k in keys:
			parts.append("%s×%d" % [String(k), int(table[k])])
		print("[round %02d]   %s 生产构成：%s" % [r, fid,
			("、".join(parts) if not parts.is_empty() else "（没有生产）")])
		var ids: Array = row[fid].get("tech_ids", [])
		if not ids.is_empty():
			var names: Array = []
			for tid in ids:
				names.append(String(tid))
			print("[round %02d]   %s 科技：%s" % [r, fid, "、".join(names)])


func _print_aggregate(rows: Array, elapsed: float) -> void:
	var wins := {"p1": 0, "p2": 0, "draw": 0}
	var reasons: Dictionary = {}
	var durations: Array = []
	var contacts: Array = []
	var bloods: Array = []
	var peaked: Array = []
	var stats := {}
	for fid in ["p1", "p2"]:
		stats[fid] = {"zones": [], "lv": [], "units": [], "gens": [], "built": [],
			"losses": [], "bld_lost": [], "gens_lost": [], "techs": [], "food": [], "gold": []}
	var comp_total := {"p1": {}, "p2": {}}
	var tech_freq := {"p1": {}, "p2": {}}
	var capped := 0
	var n := 0
	for row in rows:
		if row.has("error"):
			continue
		n += 1
		var w := String(row["winner"])
		if w == "":
			wins["draw"] = int(wins["draw"]) + 1
		else:
			wins[w] = int(wins[w]) + 1
		var reason := String(row["end"])
		reasons[reason] = int(reasons.get(reason, 0)) + 1
		if reason == "cap":
			capped += 1
		durations.append(row["time"])
		peaked.append(row["peak_units"])
		if float(row["first_contact"]) >= 0.0:
			contacts.append(row["first_contact"])
		if float(row["first_blood"]) >= 0.0:
			bloods.append(row["first_blood"])
		for fid in ["p1", "p2"]:
			var s: Dictionary = row[fid]
			stats[fid]["zones"].append(s["zones"])
			stats[fid]["lv"].append(s["base_lv"])
			stats[fid]["units"].append(s["units"])
			stats[fid]["gens"].append(s["gens"])
			stats[fid]["built"].append(row["built"][fid])
			stats[fid]["losses"].append(row["losses"][fid])
			stats[fid]["bld_lost"].append(row["bld_lost"][fid])
			stats[fid]["gens_lost"].append(row["gens_lost"][fid])
			stats[fid]["techs"].append(s["techs"])
			stats[fid]["food"].append(s["food"])
			stats[fid]["gold"].append(s["gold"])
			var table: Dictionary = row["comp"][fid]
			for k in table.keys():
				comp_total[fid][k] = int(comp_total[fid].get(k, 0)) + int(table[k])
			for tid in (s.get("tech_ids", []) as Array):
				tech_freq[fid][String(tid)] = int(tech_freq[fid].get(String(tid), 0)) + 1

	var reason_parts: Array = []
	for k in reasons.keys():
		reason_parts.append("%s×%d" % [String(k), int(reasons[k])])
	print("[agg] 轮数 %d　墙钟 %.1fs（平均 %.1fs/轮）"
		% [n, elapsed, elapsed / maxf(1.0, float(n))])
	print("[agg] 胜负 p1=%d p2=%d 未分胜负=%d　结束方式 %s"
		% [int(wins["p1"]), int(wins["p2"]), int(wins["draw"]), "、".join(reason_parts)])
	print("[agg] 时长 平均 %s　首次接触 平均 %s　首杀 平均 %s　打到上限 %d 轮　峰值单位 平均 %.1f"
		% [_fmt_time(_avg(durations)),
		   ("（一次都没打起来）" if contacts.is_empty() else _fmt_time(_avg(contacts))),
		   ("（无人阵亡）" if bloods.is_empty() else _fmt_time(_avg(bloods))),
		   capped, _avg(peaked)])
	for fid in ["p1", "p2"]:
		var s: Dictionary = stats[fid]
		print("[agg] %s 区划 %.1f　本营Lv %.1f　存活兵 %.1f（将 %.1f）　累计生产 %.1f　阵亡 %.1f（将 %.1f）　建筑损失 %.1f　科技 %.1f　余粮 %.0f 余金 %.0f"
			% [fid, _avg(s["zones"]), _avg(s["lv"]), _avg(s["units"]), _avg(s["gens"]),
			   _avg(s["built"]), _avg(s["losses"]), _avg(s["gens_lost"]),
			   _avg(s["bld_lost"]), _avg(s["techs"]),
			   _avg(s["food"]), _avg(s["gold"])])
	for fid in ["p1", "p2"]:
		var table: Dictionary = comp_total[fid]
		var keys: Array = table.keys()
		keys.sort_custom(func(a, b): return int(table[a]) > int(table[b]))
		var parts: Array = []
		for k in keys:
			parts.append("%s×%d" % [String(k), int(table[k])])
		print("[agg] %s 生产构成合计：%s" % [fid, "、".join(parts)])
		var tf: Dictionary = tech_freq[fid]
		var tkeys: Array = tf.keys()
		tkeys.sort_custom(func(a, b): return int(tf[a]) > int(tf[b]))
		var tp: Array = []
		for k in tkeys:
			tp.append("%s×%d" % [String(k), int(tf[k])])
		print("[agg] %s 科技选择：%s" % [fid, "、".join(tp)])
