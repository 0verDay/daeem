## test_alliance.gd —— ★ 阵营归属（盟友）：两个 NPC 不再互相攻击、也不争夺同一区划
extends "res://tests/test_case.gd"

const FactionRes = preload("res://logic/faction.gd")
const MapDataRes = preload("res://logic/map_data.gd")
const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const CombatRes = preload("res://logic/combat.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const BuildingRes = preload("res://logic/building.gd")

const AI := "ai"
const NPC := "enemy"
const PLAYER := "p1"

const TMP_DIR := "res://.tmp_test_alliance"

func _initialize() -> void:
	_case_name = "test_alliance"
	_run()

func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	_test_query_api()
	_test_map_data(cfg)
	await _test_world_wiring(cfg)
	await _test_no_friendly_fire(cfg)
	await _test_zone_no_contest(cfg)
	_test_ally_walls_pass(cfg)

	FactionRes.clear_allies()
	_cleanup_tmp()

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)

func _test_query_api() -> void:
	FactionRes.clear_allies()
	ok(not FactionRes.allied(NPC, AI), "清空之后两边不是盟友（默认状态）")
	ok(FactionRes.same_side_for_attack(NPC, NPC), "同一个阵营永远是「一边人」")
	ok(not FactionRes.same_side_for_attack(NPC, AI), "没结盟时两个 NPC 互为敌人")
	ok(not FactionRes.same_side(NPC, AI), "★ same_side 本身不受结盟影响（严格的 a==b）")

	FactionRes.set_allies([[NPC, AI]])
	ok(FactionRes.allied(NPC, AI), "登记之后 enemy 认 ai 是盟友")
	ok(FactionRes.allied(AI, NPC), "★ 关系是**互相**的（反向查询同样命中）")
	ok(FactionRes.same_side_for_attack(NPC, AI), "★ 攻击口径：两边算一边人")
	ok(FactionRes.same_side_for_attack(AI, NPC), "★ 反向也成立")
	ok(not FactionRes.same_side(NPC, AI),
		"★ same_side 说它们不是「同一个阵营」—— 但建筑通行改走 same_side_for_attack")
	ok(not FactionRes.allied(PLAYER, AI), "★ 玩家与 AI 不是盟友（需求：玩家与两边仍互为敌人）")
	ok(not FactionRes.same_side_for_attack(PLAYER, AI), "★ 玩家与 AI 仍然互为敌人")
	ok(not FactionRes.allied(PLAYER, NPC), "★ 玩家与地图对家也仍然互为敌人")

	FactionRes.set_allies([["", AI], [AI, AI], [NPC], "not-an-array", [AI, "  "]])
	ok(not FactionRes.allied("", AI), "空 id 不登记")
	ok(not FactionRes.allied(AI, AI), "自己和自己不算「盟友」（同一个阵营走 same_side）")
	ok(not FactionRes.allied(NPC, AI), "★ 重新登记会**先清空**（上面那批坏数据没有留下旧关系）")

	FactionRes.set_allies([[NPC, AI]])
	eq(FactionRes.side_of(NPC), AI, "★ 同一方的代表 = 字典序最小的那个（ai < enemy）")
	eq(FactionRes.side_of(AI), AI, "★ 两个成员算出来是**同一个**代表（这才是关键）")
	eq(FactionRes.side_of(PLAYER), PLAYER, "没有盟友的阵营，代表就是它自己")
	eq(FactionRes.side_of(""), "", "空 id 的代表还是空（不崩）")
	eq(FactionRes.side_members(NPC), [AI, NPC], "同一方的成员表含两边，顺序稳定（字典序）")
	eq(FactionRes.side_members(PLAYER), [PLAYER], "没结盟时成员表就是它自己")
	eq(FactionRes.side_members(""), [], "空 id 没有成员")

	FactionRes.set_allies([["b", "a"], ["c", "b"]])
	eq(FactionRes.side_of("c"), "a", "★ 三方连成一方（沿盟友关系连通搜索）")
	eq(FactionRes.side_members("c"), ["a", "b", "c"], "三方成员表齐了")
	ok(FactionRes.same_side_for_attack("c", "a"), "★ 隔着 b 也算一边人")

	FactionRes.set_allies([["a", "b"], ["b", "a"], ["a", "b"]])
	eq(FactionRes.ally_pairs().size(), 1, "重复的盟友对只留一条")

	FactionRes.clear_allies()
	eq(FactionRes.ally_pairs().size(), 0, "clear_allies 之后一条关系都不剩")
	ok(not FactionRes.same_side_for_attack(NPC, AI), "清空之后又变回敌人")

func _test_map_data(cfg) -> void:
	var m = require_map(cfg)
	if m == null:
		return
	ok(not m.allies.is_empty(), "★ 边关地图里读到了 allies（%s）" % str(m.allies))
	var found := false
	for pr in m.allies:
		var pair: Array = pr
		if pair.size() == 2 and ((String(pair[0]) == NPC and String(pair[1]) == AI)
				or (String(pair[0]) == AI and String(pair[1]) == NPC)):
			found = true
	ok(found, "★ 那一对正是 enemy ↔ ai")

	var arena = MapDataRes.load_from("res://data/maps/arena/map.json", cfg)
	ok(arena != null, "占位图也能载入")
	if arena != null:
		eq(arena.allies.size(), 0, "★ 没写 allies 的图 = 没有任何盟友（换图不会带着上一张的关系）")

	var bad = MapDataRes.load_from(_write_map("allies_bad.json", {
		"cols": 4, "rows": 3,
		"layout": ["....", "....", "...."],
		"base": [1, 1],
		"allies": ["nope", [AI], [AI, ""], [AI, AI], [AI, NPC, "extra"]],
	}), cfg)
	ok(bad != null, "带坏 allies 的地图也能载入")
	if bad != null:
		eq(bad.allies.size(), 1, "坏项全被跳过，只剩合法的那一条（多余元素被忽略）")
		if bad.allies.size() == 1:
			eq(String((bad.allies[0] as Array)[0]), AI, "合法那一条读对了")
			eq(String((bad.allies[0] as Array)[1]), NPC, "第二个也读对了")

	var plain = MapDataRes.load_from(_write_map("allies_none.json", {
		"cols": 4, "rows": 3,
		"layout": ["....", "....", "...."],
		"base": [1, 1],
	}), cfg)
	ok(plain != null and plain.allies.size() == 0, "缺字段 → 空表")

func _test_world_wiring(cfg) -> void:
	var w = require_world_create(cfg, true)
	ok(w != null, "边关那张图能开出一局（带阵营 AI）")
	if w == null:
		FactionRes.clear_allies()
		return
	ok(w.factions.has(AI), "这一局名单里有阵营 AI（%s）" % AI)
	ok(FactionRes.allied(NPC, AI), "★★ 开完一局之后，enemy 与 ai 是盟友（地图数据被注入）")
	ok(not FactionRes.allied(PLAYER, AI), "★ 玩家不是 AI 的盟友")
	ok(not FactionRes.allied(PLAYER, NPC), "★ 玩家也不是地图对家的盟友")
	ok(not FactionRes.same_side_for_attack(PLAYER, NPC), "★ 玩家与地图对家仍然互为敌人")
	ok(not FactionRes.same_side_for_attack(PLAYER, AI), "★ 玩家与阵营 AI 仍然互为敌人")
	ok(FactionRes.same_side_for_attack(NPC, AI), "★★ 而两个 NPC 之间是「一边人」")

	var arena = require_world_create(cfg, true, "res://data/maps/arena/map.json")
	ok(arena != null, "占位图也能开出一局")
	if arena != null:
		ok(not FactionRes.allied(NPC, AI),
			"★★ 换到没结盟的图之后，上一张图的盟友关系**没有**跟过来（reset 里先清后写）")
	var back = require_world_create(cfg, true)
	if back != null:
		ok(FactionRes.allied(NPC, AI), "换回边关又结盟（幂等）")
	FactionRes.clear_allies()

func _test_no_friendly_fire(cfg) -> void:
	var w = require_world_create(cfg, true)
	if w == null:
		FactionRes.clear_allies()
		return
	var tiles := _two_free_tiles(w)
	ok(tiles.size() == 2, "找得到两格空地放测试单位")
	if tiles.size() != 2:
		FactionRes.clear_allies()
		return
	var a = UnitRes.create(cfg, "ally-test-npc", "对家兵",
		tiles[0], NPC, UnitRes.UNIT_TYPE_SPEARMAN)
	var b = UnitRes.create(cfg, "ally-test-ai", "AI 兵",
		tiles[1], AI, UnitRes.UNIT_TYPE_SPEARMAN)
	w.units.append(a)
	w.units.append(b)
	var ia: int = w.units.size() - 2
	var ib: int = w.units.size() - 1
	ok(a.pos.distance_to(b.pos) <= cfg.aggro_range,
		"（前提）两个单位在彼此警戒半径内（%.1f ≤ %.1f）"
		% [a.pos.distance_to(b.pos), cfg.aggro_range])

	CombatRes.acquire_target(w, cfg, a, -1)
	ok(a.target == null or a.target != b, "★ 对家兵**不**把 AI 兵当目标（GDScript 路）")
	CombatRes.acquire_target(w, cfg, b, -1)
	ok(b.target == null or b.target != a, "★ AI 兵**不**把对家兵当目标（GDScript 路）")

	if w.crowd != null:
		w.crowd.refresh_targets(w, cfg)
		if w.crowd.targets_ready(w):
			CombatRes.acquire_target(w, cfg, a, ia)
			ok(a.target == null or a.target != b, "★ 内核那条路也不把盟友当目标")
			CombatRes.acquire_target(w, cfg, b, ib)
			ok(b.target == null or b.target != a, "★ 反向同样")
		else:
			ok(true, "（跳过）这一局没开 C# 索敌内核，4.2 不适用")
	else:
		ok(true, "（跳过）world.crowd 为 null")

	var tower = _place_tower_near(w, cfg, b)
	if tower != null:
		CombatRes.update_towers(w, cfg, 0.016)
		ok(tower.last_target == null or tower.last_target != b,
			"★ 对家的箭塔**不**把 AI 兵当目标")
		w.remove_building(tower, false)

	ok(not a.order_attack_unit(w, cfg, b), "★ 直接给对家兵下「打 AI 兵」的命令被拒")
	ok(not CommandRes.apply_attack(w, cfg, {
		"kind": "attack", "faction": NPC, "ids": [a.id], "target_id": b.id,
	}), "★ 走命令层同样被拒（目标不是敌方）")

	var p1_unit = null
	for u in w.units:
		if u.alive and String(u.faction) == PLAYER:
			p1_unit = u
			break
	if p1_unit != null:
		ok(not FactionRes.same_side_for_attack(NPC, PLAYER),
			"★ 地图对家与玩家仍然是敌人")
		ok(not FactionRes.same_side_for_attack(AI, PLAYER),
			"★ 阵营 AI 与玩家仍然是敌人")

	w.units.erase(a)
	w.units.erase(b)
	FactionRes.clear_allies()

func _test_zone_no_contest(cfg) -> void:
	var w = require_world_create(cfg, true)
	if w == null:
		FactionRes.clear_allies()
		return
	if w.zones == null or w.zones.zones.is_empty():
		ok(false, "这一局有区块（占领用例的前提）")
		FactionRes.clear_allies()
		return

	var enemy_zone: Dictionary = {}
	for z in w.zones.zones:
		if String((z as Dictionary).get("owner", "")) == NPC:
			enemy_zone = z
			break
	if enemy_zone.is_empty():
		for z2 in w.zones.zones:
			if String((z2 as Dictionary).get("owner", "")) == "":
				z2["owner"] = NPC
				enemy_zone = z2
				break
	ok(not enemy_zone.is_empty(), "（前提）拿得到一块属于 enemy 的区划")
	if enemy_zone.is_empty():
		FactionRes.clear_allies()
		return

	var t := _walkable_tile_in_zone(w, int(enemy_zone["id"]))
	if t.x >= 0:
		var s = UnitRes.create(cfg, "ally-test-zone", "AI 兵", t, AI, UnitRes.UNIT_TYPE_SPEARMAN)
		w.units.append(s)
		w.zones.update(cfg, 0.5, w.units, w.factions)
		eq(String(enemy_zone.get("capture_state", "")), "",
			"★ AI 的兵站在盟友（enemy）的区划里**不读条**（不抢盟友的地）")
		ok(float((enemy_zone.get("progress_by", {}) as Dictionary).get(AI, 0.0)) <= 0.0,
			"★ 它在那一块的进度是 0")
		w.units.erase(s)
	else:
		ok(false, "找得到盟友区划里的一格空地")

	var unowned: Dictionary = {}
	for z3 in w.zones.zones:
		if String((z3 as Dictionary).get("owner", "")) == "":
			unowned = z3
			break
	if not unowned.is_empty():
		var t2 := _walkable_tile_in_zone(w, int(unowned["id"]))
		if t2.x >= 0:
			var u1 = UnitRes.create(cfg, "ally-test-c1", "对家兵", t2, NPC, UnitRes.UNIT_TYPE_SPEARMAN)
			var u2 = UnitRes.create(cfg, "ally-test-c2", "AI 兵", t2, AI, UnitRes.UNIT_TYPE_SPEARMAN)
			w.units.append(u1)
			w.units.append(u2)
			(unowned["progress_by"] as Dictionary).clear()
			w.zones.update(cfg, 0.25, w.units, w.factions)
			ok(String(unowned.get("capture_state", "")) != "frozen",
				"★ 两个盟友同处一区**不会冻住**（它们算一方，不是「两方对峙」）")
			ok(String(unowned.get("capture_state", "")) == "reading"
					or String(unowned.get("owner", "")) != "",
				"★ 而是一起在读条（人数合并）")
			w.units.erase(u1)
			w.units.erase(u2)
		else:
			ok(false, "找得到无主区块里的一格空地")
	else:
		ok(true, "（跳过）这张图上没有无主区块")

	if String(enemy_zone.get("owner", "")) == NPC:
		var t3 := _walkable_tile_in_zone(w, int(enemy_zone["id"]))
		var b = null
		if t3.x >= 0:
			b = w.add_building(BuildingRes.TYPE_WALL, t3.x, t3.y, AI, true, true)
		if b != null:
			w.zones.refresh_building_ownership(cfg, w.building_list, w.factions)
			eq(String(enemy_zone.get("owner", "")), NPC,
				"★ 盟友的建筑落在这块地上，归属**不会**从 enemy 翻给 AI")
			w.remove_building(b, false)
		else:
			ok(true, "（跳过）那一格建不了建筑")

	FactionRes.clear_allies()

func _test_ally_walls_pass(cfg) -> void:
	FactionRes.set_allies([[NPC, AI]])
	ok(FactionRes.allied(NPC, AI), "（前提）两边已结盟")
	var wall = BuildingRes.create(cfg, "wall", 0, 0, NPC)
	ok(wall != null, "（前提）造一栋属于 %s 的城墙" % NPC)
	if wall != null:
		ok(not wall.blocks(AI), "★ 盟友的城墙整格**放行**给盟友（blocks = false）")
		ok(not wall.body_blocks(AI), "★ 盟友的城墙本体也不挡盟友（body_blocks = false）")
		ok(wall.blocks("p9-nobody"), "★ 非盟友 / 敌对仍被城墙挡死（blocks = true）")
		ok(not wall.blocks(NPC), "★ 同阵营照样放行（与从前一致）")
	FactionRes.clear_allies()

func require_world_create(cfg, with_ai: bool = true,
		map_path: String = DEFAULT_MAP_PATH):
	var cls := script_at("res://logic/world.gd")
	if cls == null:
		return null
	var w = cls.create(cfg, map_path, with_ai)
	ok(w != null, "世界能建出来（with_ai = %s）" % str(with_ai))
	return w

func _two_free_tiles(w) -> Array:
	var out: Array = []
	for y in w.map.rows:
		for x in w.map.cols:
			if not w.map.terrain_walkable(x, y):
				continue
			if w.building_at(x, y) != null:
				continue
			out.append(Vector2i(x, y))
			if out.size() >= 2:
				return out
	return out

func _place_tower_near(w, cfg, u):
	for y in range(maxi(0, u.ty - 2), mini(w.map.rows, u.ty + 3)):
		for x in range(maxi(0, u.tx - 2), mini(w.map.cols, u.tx + 3)):
			if Vector2i(x, y) == Vector2i(u.tx, u.ty):
				continue
			if not w.map.terrain_walkable(x, y):
				continue
			if w.building_at(x, y) != null:
				continue
			var b = w.add_building(BuildingRes.TYPE_TOWER, x, y, NPC, true, true)
			if b != null:
				return b
	return null

func _walkable_tile_in_zone(w, zone_id: int) -> Vector2i:
	for y in w.map.rows:
		for x in w.map.cols:
			if not w.map.terrain_walkable(x, y):
				continue
			var z = w.zones.zone_at(x, y)
			if z == null or int((z as Dictionary)["id"]) != zone_id:
				continue
			if w.building_at(x, y) != null:
				continue
			return Vector2i(x, y)
	return Vector2i(-1, -1)

func _write_map(file_name: String, data: Dictionary) -> String:
	var dir := TMP_DIR
	DirAccess.make_dir_recursive_absolute(dir)
	var path := "%s/%s" % [dir, file_name]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		ok(false, "测试地图写得出来：%s" % path)
		return path
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	return path

func _cleanup_tmp() -> void:
	var dir := DirAccess.open(TMP_DIR)
	if dir == null:
		return
	for name in dir.get_files():
		DirAccess.remove_absolute("%s/%s" % [TMP_DIR, name])
	DirAccess.remove_absolute(TMP_DIR)
