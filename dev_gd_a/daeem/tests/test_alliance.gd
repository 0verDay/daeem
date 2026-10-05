## test_alliance.gd —— ★ 阵营归属（盟友）：两个 NPC 不再互相攻击、也不争夺同一区划
##
## 需求原文：
##   1. 「为游戏添加阵营归属，让『边关』地图中的两个 ai 的阵营关系变为友善，不再相互攻击」
##   2. 「不相互攻击，且不争夺同一区划」
##   3. 配置**写在地图文件里**（所以只有边关友善，别的图照旧）
##   4. 玩家与两边**仍然互为敌人**
##
## 「边关」上的两个 NPC（实测）：`enemy`（地图对家 · 红 · 9 个守军 + 1 本营 + 2 塔 + 3 墙）
## 与 `ai`（阵营 AI · 橙 · 有资源库、会招将出兵）。地图的 `allies` 字段把它俩结成一方。
##
## 这个文件分四层钉：
##   1. `logic/faction.gd` 的纯查询（盟友表、同一方、代表 id、可复现性）；
##   2. 地图数据解析（`allies` 字段读得进来、写坏了也不炸）；
##   3. ★ 端到端：边关那一局里，两个 NPC 真的不再互相打、也不再抢同一块地；
##   4. ★ 「不互相攻击」**没有**顺带把「建筑通行」也改掉（盟友的城墙照样挡盟友）——
##      用户只要求不互相攻击，拆墙是另一条需求。
##
## ⚠️ `FactionRes` 的盟友表是 **static**：每个用例都要自己 `clear_allies()` 收尾，
##    否则上一条用例的结盟会漏给下一条（这本身就是「换图必须清干净」那条的回归）。
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

## 临时地图目录（跑完删掉；见 `_cleanup_tmp`）
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
	# ★ 后面三条要动 static 盟友表，统一在末尾清一次（每条自己也会清）
	await _test_world_wiring(cfg)
	await _test_no_friendly_fire(cfg)
	await _test_zone_no_contest(cfg)
	_test_walls_still_block()

	FactionRes.clear_allies()
	_cleanup_tmp()

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 1) 纯查询：盟友表 / 同一方 / 代表 id
# ------------------------------------------------------------------
func _test_query_api() -> void:
	FactionRes.clear_allies()
	ok(not FactionRes.allied(NPC, AI), "清空之后两边不是盟友（默认状态）")
	ok(FactionRes.same_side_for_attack(NPC, NPC), "同一个阵营永远是「一边人」")
	ok(not FactionRes.same_side_for_attack(NPC, AI), "没结盟时两个 NPC 互为敌人")
	ok(not FactionRes.same_side(NPC, AI), "★ same_side 本身不受结盟影响（它管建筑通行）")

	FactionRes.set_allies([[NPC, AI]])
	ok(FactionRes.allied(NPC, AI), "登记之后 enemy 认 ai 是盟友")
	ok(FactionRes.allied(AI, NPC), "★ 关系是**互相**的（反向查询同样命中）")
	ok(FactionRes.same_side_for_attack(NPC, AI), "★ 攻击口径：两边算一边人")
	ok(FactionRes.same_side_for_attack(AI, NPC), "★ 反向也成立")
	ok(not FactionRes.same_side(NPC, AI),
		"★★ 但 same_side（建筑通行）**仍然**说它们不是同一方 —— 盟友的墙照样挡盟友")
	ok(not FactionRes.allied(PLAYER, AI), "★ 玩家与 AI 不是盟友（需求：玩家与两边仍互为敌人）")
	ok(not FactionRes.same_side_for_attack(PLAYER, AI), "★ 玩家与 AI 仍然互为敌人")
	ok(not FactionRes.allied(PLAYER, NPC), "★ 玩家与地图对家也仍然互为敌人")

	# 空值 / 同名 / 坏数据一律不吃进表
	FactionRes.set_allies([["", AI], [AI, AI], [NPC], "not-an-array", [AI, "  "]])
	ok(not FactionRes.allied("", AI), "空 id 不登记")
	ok(not FactionRes.allied(AI, AI), "自己和自己不算「盟友」（同一个阵营走 same_side）")
	ok(not FactionRes.allied(NPC, AI), "★ 重新登记会**先清空**（上面那批坏数据没有留下旧关系）")

	# 「同一方」的代表与成员
	FactionRes.set_allies([[NPC, AI]])
	eq(FactionRes.side_of(NPC), AI, "★ 同一方的代表 = 字典序最小的那个（ai < enemy）")
	eq(FactionRes.side_of(AI), AI, "★ 两个成员算出来是**同一个**代表（这才是关键）")
	eq(FactionRes.side_of(PLAYER), PLAYER, "没有盟友的阵营，代表就是它自己")
	eq(FactionRes.side_of(""), "", "空 id 的代表还是空（不崩）")
	eq(FactionRes.side_members(NPC), [AI, NPC], "同一方的成员表含两边，顺序稳定（字典序）")
	eq(FactionRes.side_members(PLAYER), [PLAYER], "没结盟时成员表就是它自己")
	eq(FactionRes.side_members(""), [], "空 id 没有成员")

	# 三方链条：a-b、b-c ⇒ 三个都是一方
	FactionRes.set_allies([["b", "a"], ["c", "b"]])
	eq(FactionRes.side_of("c"), "a", "★ 三方连成一方（沿盟友关系连通搜索）")
	eq(FactionRes.side_members("c"), ["a", "b", "c"], "三方成员表齐了")
	ok(FactionRes.same_side_for_attack("c", "a"), "★ 隔着 b 也算一边人")

	# 重复登记同一对不会出错
	FactionRes.set_allies([["a", "b"], ["b", "a"], ["a", "b"]])
	eq(FactionRes.ally_pairs().size(), 1, "重复的盟友对只留一条")

	FactionRes.clear_allies()
	eq(FactionRes.ally_pairs().size(), 0, "clear_allies 之后一条关系都不剩")
	ok(not FactionRes.same_side_for_attack(NPC, AI), "清空之后又变回敌人")


# ------------------------------------------------------------------
# 2) 地图数据：allies 字段
# ------------------------------------------------------------------
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

	# 另一张图（占位图）没写 allies ⇒ 空表 ⇒ 各打各的
	var arena = MapDataRes.load_from("res://data/maps/arena/map.json", cfg)
	ok(arena != null, "占位图也能载入")
	if arena != null:
		eq(arena.allies.size(), 0, "★ 没写 allies 的图 = 没有任何盟友（换图不会带着上一张的关系）")

	# 坏数据：不是数组 / 单项不是数组 / 少于两个 / 空串 / 同一个阵营 → 全部跳过，不崩
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

	# 完全没有 allies 字段：空表（老地图行为一字不变）
	var plain = MapDataRes.load_from(_write_map("allies_none.json", {
		"cols": 4, "rows": 3,
		"layout": ["....", "....", "...."],
		"base": [1, 1],
	}), cfg)
	ok(plain != null and plain.allies.size() == 0, "缺字段 → 空表")


# ------------------------------------------------------------------
# 3) 世界接线：边关那一局的盟友表真的被注入了
# ------------------------------------------------------------------
func _test_world_wiring(cfg) -> void:
	# ★ 用 `with_ai = true` 显式建这一局：边关的「两个 AI」里有一个是**配置**里的
	#   阵营 AI（config.ai.factions），而测试脚手架默认是**不带 AI** 的干净世界
	#   （见 test_case.require_world 的说明）。这一条正是「边关那一局」的前提。
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

	# ★ 换一张图（没写 allies）必须把上一张的关系丢掉
	var arena = require_world_create(cfg, true, "res://data/maps/arena/map.json")
	ok(arena != null, "占位图也能开出一局")
	if arena != null:
		ok(not FactionRes.allied(NPC, AI),
			"★★ 换到没结盟的图之后，上一张图的盟友关系**没有**跟过来（reset 里先清后写）")
	# 换回边关，确认又有了
	var back = require_world_create(cfg, true)
	if back != null:
		ok(FactionRes.allied(NPC, AI), "换回边关又结盟（幂等）")
	FactionRes.clear_allies()


# ------------------------------------------------------------------
# 4) ★ 不互相攻击（索敌 / 箭塔 / 手点）
# ------------------------------------------------------------------
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

	# ---- 4.1 GDScript 那条索敌路径（不走内核）：逐个扫描也要认盟友 ----
	#    关掉内核就退回逐个扫描，正好把「另一条实现」也钉住。
	CombatRes.acquire_target(w, cfg, a, -1)
	ok(a.target == null or a.target != b, "★ 对家兵**不**把 AI 兵当目标（GDScript 路）")
	CombatRes.acquire_target(w, cfg, b, -1)
	ok(b.target == null or b.target != a, "★ AI 兵**不**把对家兵当目标（GDScript 路）")

	# ---- 4.2 批量索敌（C# 内核那条路）：内核按「一方」分组，盟友是同一个下标 ----
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

	# ---- 4.3 箭塔不射盟友 ----
	var tower = _place_tower_near(w, cfg, b)
	if tower != null:
		CombatRes.update_towers(w, cfg, 0.016)
		ok(tower.last_target == null or tower.last_target != b,
			"★ 对家的箭塔**不**把 AI 兵当目标")
		w.remove_building(tower, false)

	# ---- 4.4 手点也不行：命令层与逻辑层各拦一道 ----
	ok(not a.order_attack_unit(w, cfg, b), "★ 直接给对家兵下「打 AI 兵」的命令被拒")
	ok(not CommandRes.apply_attack(w, cfg, {
		"kind": "attack", "faction": NPC, "ids": [a.id], "target_id": b.id,
	}), "★ 走命令层同样被拒（目标不是敌方）")

	# ---- 4.5 对玩家照旧：友善**没有**传染给玩家 ----
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


# ------------------------------------------------------------------
# 5) ★ 不争夺同一区划
# ------------------------------------------------------------------
func _test_zone_no_contest(cfg) -> void:
	var w = require_world_create(cfg, true)
	if w == null:
		FactionRes.clear_allies()
		return
	if w.zones == null or w.zones.zones.is_empty():
		ok(false, "这一局有区块（占领用例的前提）")
		FactionRes.clear_allies()
		return

	# ---- 5.1 盟友的地：本方的兵站上去**不读条**（不抢盟友的区划）----
	var enemy_zone: Dictionary = {}
	for z in w.zones.zones:
		if String((z as Dictionary).get("owner", "")) == NPC:
			enemy_zone = z
			break
	if enemy_zone.is_empty():
		# 地图上 enemy 没有地时，自己给它一块：先记下一个无主区块
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

	# ---- 5.2 两个盟友的兵同处一区：算**一方**（不互相抵消）----
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
			# 清掉可能残留的进度，只看这一帧
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

	# ---- 5.3 建筑归属：盟友的建筑不会把对方的地翻走 ----
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


# ------------------------------------------------------------------
# 6) ★ 盟友照样互相挡路（用户只要「不互相攻击」，没要拆墙）
# ------------------------------------------------------------------
func _test_walls_still_block() -> void:
	FactionRes.set_allies([[NPC, AI]])
	# building.blocks / body_blocks 走的是 same_side（按阵营），不是攻击口径 ——
	# 所以「盟友的城墙对盟友的军队照旧阻挡」。
	ok(not FactionRes.same_side(NPC, AI),
		"★ same_side（建筑通行口径）对盟友仍然为 false ⇒ 城墙照样挡盟友")
	FactionRes.clear_allies()


# ------------------------------------------------------------------
# 工具
# ------------------------------------------------------------------

## 直接建一局世界（**带阵营 AI**）。test_case 的 `require_world` 默认 `with_ai = false`
## （那是「干净世界」用的），而这一份测试要的就是「边关那一局」——
## 两个 NPC 里有一个是配置里的阵营 AI，不带 AI 就根本不在场。
func require_world_create(cfg, with_ai: bool = true,
		map_path: String = DEFAULT_MAP_PATH):
	var cls := script_at("res://logic/world.gd")
	if cls == null:
		return null
	var w = cls.create(cfg, map_path, with_ai)
	ok(w != null, "世界能建出来（with_ai = %s）" % str(with_ai))
	return w


## 找两个相邻的空地（地形可走、没有建筑、没有别的东西）
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


## 在离 u 最近的一格空地上放一座属于 NPC 的箭塔（让它在射程内）
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


## 某个区块里的一格可走空地（找不到返回 (-1,-1)）
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


## 写一张临时地图到工程里的测试目录下（与 test_map_editor.gd 同一套做法）
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


## 跑完把临时地图目录删掉（★ 与 test_map_editor.gd 同一条规矩：
## 测试不该在工程里留下垃圾 —— 上一次忘了删，`git status` 里就多出一个 `.tmp_test_alliance/`）。
func _cleanup_tmp() -> void:
	var dir := DirAccess.open(TMP_DIR)
	if dir == null:
		return
	for name in dir.get_files():
		DirAccess.remove_absolute("%s/%s" % [TMP_DIR, name])
	DirAccess.remove_absolute(TMP_DIR)
