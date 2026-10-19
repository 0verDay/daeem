## test_coop_tech.gd —— 合作 M12.2：**两个玩家席位各吃各的科技**。
##
## 这一条是快照补 tech 的配套：如果房主的科技还按全局一份算，
## 客机启用的「粮食 +5%」会加到房主头上（反之亦然）。
extends "res://tests/test_case.gd"

const CampaignRes = preload("res://logic/campaign.gd")
const WorldRes = preload("res://logic/world.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const LEVEL_ID := "02_twin_line"

func _initialize() -> void:
	_case_name = "test_coop_tech"
	run_all(Callable(self, "_run"))


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID) if camp != null else null
	if lv == null:
		ok(false, "（前提）合作关能载入")
		return
	var w = WorldRes.create_from_level(cfg, lv, "F1", lv.coop_roster(), true)
	if w == null:
		ok(false, "（前提）合作关世界能建出来")
		return

	var f1_base = w.find_base_of("F1")
	var f2_base = w.find_base_of("F2")
	ok(f1_base != null and f2_base != null, "（前提）两边都有大本营")
	if f1_base == null or f2_base == null:
		return
	var f1_hp: float = f1_base.hp_max
	var f2_hp: float = f2_base.hp_max

	# 客机启用「粮食产量 I」+「建筑加固」；房主一条都不启用。
	ok(w.set_tech_active("food_1", true, "F2"), "客机能启用 food_1")
	ok(w.set_tech_active("building_hp", true, "F2"), "客机能启用 building_hp")
	ok(w.set_tech_active("zone_population", true, "F2"), "客机能启用 zone_population")

	ok(w.seat_tech_effects.has("F1") and w.seat_tech_effects.has("F2"),
		"★ 两个玩家席位各有一份科技效果")
	near(float(w.seat_tech_effects["F1"].get("food_per_tile_per_sec", 0.0)), 0.0, 1e-6,
		"★ 房主没启用粮食科技 → 房主那份是 0")
	near(float(w.seat_tech_effects["F2"].get("food_per_tile_per_sec", 0.0)), 0.05, 1e-6,
		"★★ 客机启用的粮食科技只在客机那份里")

	var tiles: int = w.zones.owned_tile_count("F2")
	var base_rate: Dictionary = w.zones.production_of("F2")
	var with_tech: Dictionary = w._accumulate_production("F2", false, w.seat_tech_effects["F2"])
	near(float(with_tech["food"]) - float(base_rate["food"]),
		float(tiles) * 0.05, 1e-6, "★ 客机的粮食产量按自己的地块数加 0.05/格")

	near(w.tech_population_mult("F1"), 1.0, 1e-6, "房主人口倍率仍是 1.0")
	near(w.tech_population_mult("F2"), 1.1, 1e-6, "★ 客机人口倍率是 1.1")

	ok(f2_base.hp_max > f2_hp, "★★ 客机的建筑加固只加客机的楼")
	near(f1_base.hp_max, f1_hp, 1e-6, "★★ 房主的楼没有被客机科技加成")
