## bench_coop_ai_win.gd - measure time-to-objective when both player-side seats are commander AI.
extends SceneTree

const LEVEL := "res://data/campaigns/demo/levels/dengshen_changjie.json"

func _initialize() -> void:
	var cfg = load("res://logic/config.gd").load_default()
	var lv = load("res://logic/level.gd").load_level(null, LEVEL, cfg)
	if lv == null:
		printerr("level fail")
		quit(1)
		return
	var overrides := {"p1": "commander", "p2": "commander"}
	var profiles := {"p1": {"difficulty": "normal"}, "p2": {"difficulty": "normal"}}
	var w = load("res://logic/world.gd").create_from_level(
		cfg, lv, "p1", ["p1", "p2"], true, overrides, profiles, 20261120, true)
	if w == null:
		printerr("world fail")
		quit(1)
		return
	w.objective_state = load("res://logic/objective.gd").setup(w, lv, ["p1", "p2"], "p1")
	print("commanders=", w.ai_commanders.keys(),
		" player_factions=", w.player_factions,
		" objective=", w.objective_state)
	var dt := 0.1
	var limit := 1800.0
	var next_report := 60.0
	var t0 := Time.get_ticks_msec()
	while w.time < limit:
		w.tick(dt)
		var st := String(w.objective_state.get("state", ""))
		if w.time >= next_report:
			next_report += 60.0
			print("[%5.1fs] state=%s owner(z1)=%s units p1=%d p2=%d df=%d enemy=%d red=%d zones=%s wall_orders=%d/%d" % [
				w.time, st, _zone_owner(w, 1),
				w.alive_units_of("p1").size(), w.alive_units_of("p2").size(),
				w.alive_units_of("df").size(), w.alive_units_of("enemy").size(),
				w.alive_units_of("red1").size(), _owner_counts(w),
				int(w.ai_commanders["p1"].stats.get("wall_orders", 0)),
				int(w.ai_commanders["p2"].stats.get("wall_orders", 0))])
		if st == "won" or st == "lost":
			break
	var st2 := String(w.objective_state.get("state", ""))
	print("RESULT state=%s game_sec=%.1f wall_sec=%.1f reason=%s zone1_owner=%s" % [
		st2, w.time, (Time.get_ticks_msec() - t0) / 1000.0,
		String(w.objective_state.get("reason", "")), _zone_owner(w, 1)])
	print("final units p1=%d p2=%d df=%d enemy=%d red=%d owners=%s" % [
		w.alive_units_of("p1").size(), w.alive_units_of("p2").size(),
		w.alive_units_of("df").size(), w.alive_units_of("enemy").size(),
		w.alive_units_of("red1").size(), _owner_counts(w)])
	quit(0)


func _zone_owner(w, zid: int) -> String:
	var z = w.zone_by_id(zid)
	return String((z as Dictionary).get("owner", "")) if z != null else "?"


func _owner_counts(w) -> Dictionary:
	var out := {}
	for z in w.zones.zones:
		var o := String((z as Dictionary).get("owner", ""))
		out[o] = int(out.get(o, 0)) + 1
	return out
