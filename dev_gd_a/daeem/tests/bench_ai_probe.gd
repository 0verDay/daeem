## 临时探针：合作关 + AI 队友，跑一会儿看有没有运行期报错。确认后并入正式测试。
extends SceneTree

func _initialize() -> void:
	var cfg = load("res://logic/config.gd").load_default()
	if cfg == null:
		printerr("config fail")
		quit(1)
		return
	var L = load("res://logic/level.gd")
	var lv = L.load_level(null, "res://data/campaigns/demo/levels/02_twin_line.json", cfg)
	print("level=", lv != null, " map=", lv.map_id if lv != null else "")
	if lv == null:
		quit(1)
		return
	var W = load("res://logic/world.gd")
	var w = W.create_from_level(cfg, lv, "F1", ["F1", "F2"], true,
		{"F2": "commander"}, {"F2": {"difficulty": "normal"}})
	print("world=", w != null)
	if w == null:
		quit(1)
		return
	print("factions=", w.factions, " cmdrs=", w.commander_factions())
	print("base F2=", w.find_base_of("F2"))
	print("pool F2=", w.resource_pool_for("F2"))
	print("units F2=", w.alive_units_of("F2").size(), " dir=", w.ai_directive_of("F2"))
	print("panel=", w.ai_panel_state("F2"))
	for i in 300:
		var ev = w.tick(0.1)
		if i % 50 == 0:
			var c = w.ai_commanders.get("F2", null)
			if c != null:
				print("t=%.1f army=%d food=%.0f gold=%.0f base=%d stats=%s" % [
					w.time, c.panel_state()["army"], c.panel_state()["food"],
					c.panel_state()["gold"], w.base_level_of("F2"), c.stats])
	# 试一条行军指令
	var reason = w.set_ai_directive("F2", "march", 10.0, 10.0, "F1")
	print("march reason=", reason, " dir=", w.ai_directive_of("F2"))
	for i in 100:
		w.tick(0.1)
	var c2 = w.ai_commanders.get("F2", null)
	if c2 != null:
		print("after march stats=", c2.stats, " panel=", c2.panel_state())
	quit(0)
