## test_ai_target.gd —— **进攻目标 / 波次**断言（dev_plan_7 M7.2）
##
## 盯的是「不写就会静默错」的那一类：
##   · 四种 `attack_target.kind`（zone / point / building / base）各自解析成**正确的目标格**；
##   · **缺省（不写）退回现状**：AI 自己挑「离自己最近的敌方区划中心」；
##   · ★ 关卡给的目标**不可达 / 解析不出来时要退回现状挑选**（别对着走不到的点发呆）；
##   · 出兵时发一次 `ai_attack_launched`（哪一方 / 派了几位 / 往哪打）；
##   · 出兵仍然走现成的 `order_attack_move`（不新写一套命令）。
##
## ⚠️ 语言约定见 tests/test_case.gd（`--script` 下全局 class_name 不可用；只用 preload 常量）。
extends "res://tests/test_case.gd"

const CampaignRes = preload("res://logic/campaign.gd")
const WorldRes = preload("res://logic/world.gd")
const FactionAiRes = preload("res://logic/faction_ai.gd")
const FactionRes = preload("res://logic/faction.gd")
const UnitRes = preload("res://logic/unit.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const TMP_ROOT := "res://.tmp_ai_target_tests"

## 样例地图上的已知点（生成 demo 数据时定的，见 tests/_gen_demo_campaign.py）
const ZONE_C1 := 4            # c1（现中心 (5,12)，且关卡把它划给 F1）
const BASE_E1 := Vector2i(18, 10)
## 一个远离双方基地的空地（在 c1 里，可通行）
const FAR_POINT := Vector2i(2, 11)
## ★★ 不要再**写死**箭塔那一格（原来是 (8,11)，大本营一挪就失效 —— 实测踩到）。
## building 目标那一条改成**从世界里查**那栋塔（见 `_tower_tile`）：
## 「那一格上真的有建筑」才是这条断言要的前提，而它取决于关卡数据（`BASE_F1 + (3,0)`）。


func _initialize() -> void:
	run_all(Callable(self, "_run"))


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_clean_tmp()
	_group_resolve(cfg)
	_group_default(cfg)
	_group_unreachable(cfg)
	_group_launch(cfg)
	_clean_tmp()


# ------------------------------------------------------------------
# 一、四种 kind 各自解析成正确的目标格
# ------------------------------------------------------------------
func _group_resolve(cfg) -> void:
	# zone：直接就是**那个区划的中心格**（不是「最近的敌方中心」—— 那是缺省时才走的规则）
	var w1 = _make(cfg, "rt_zone", {"factions": [_faction({
		"attack_target": {"kind": "zone", "zone": ZONE_C1}})]})
	ok(w1 != null, "能造出「目标 = 区划 c1」的世界")
	if w1 != null:
		var z1 = w1.zone_by_id(ZONE_C1)
		ok(z1 != null, "（前提）区划 c1 存在")
		var got = w1.level_attack_target("E1")
		ok(got != null, "★ kind=zone 解析出了目标格")
		if got != null and z1 != null:
			eq((got as Vector2i), Vector2i((z1 as Dictionary)["center"]),
				"★ kind=zone 的目标就是**那个区划的中心格**（不参与「谁更近」的比较）")
			eq((got as Vector2i), Vector2i(5, 12), "★ 具体到样例地图：c1 的中心是 (5,12)")

	# point：地图里一个可通行的空地
	var w2 = _make(cfg, "rt_point", {"factions": [_faction({
		"attack_target": {"kind": "point", "x": FAR_POINT.x, "y": FAR_POINT.y}})]})
	ok(w2 != null, "能造出「目标 = 某个坐标」的世界")
	if w2 != null:
		eq(w2.level_attack_target("E1"), FAR_POINT,
			"★ kind=point 解析成那一格（原样）")

	# building：开局摆放的那栋塔所在的格
	#
	# ★★ 那一格**从关卡数据里读**（不再写死）：它是 `BASE_F1 + (3,0)` 算出来的，
	#   大本营一挪这一格就变（实测：区划重排把大本营挪到 (4,6) 之后，写死的 (8,11)
	#   变成了一格空地，这条断言就假红了）。判据是「那一格上真的有建筑」，不是具体坐标。
	var tower := _first_start_building(cfg)
	ok(tower != Vector2i(-1, -1), "（前提）关卡 `start_buildings` 里读得到一栋建筑")
	if tower != Vector2i(-1, -1):
		var w3 = _make(cfg, "rt_building", {"factions": [_faction({
			"attack_target": {"kind": "building", "x": tower.x, "y": tower.y}})]})
		ok(w3 != null, "能造出「目标 = 某栋建筑」的世界")
		if w3 != null:
			ok(w3.building_at(tower.x, tower.y) != null,
				"（前提）那一格上真的有建筑 —— 关卡 `start_buildings` 摆的那栋（%s）" % str(tower))
			var got3 = w3.level_attack_target("E1")
			ok(got3 != null, "★ kind=building 解析出了目标格")
			if got3 != null:
				eq((got3 as Vector2i), tower, "★ kind=building 解析成那栋建筑所在的格")
	# ★ 那一格**没有**建筑时解析不出来 → 退回现状（数据写错了别原地发呆）
	var w3b = _make(cfg, "rt_building_empty", {"factions": [_faction({
		"attack_target": {"kind": "building", "x": FAR_POINT.x, "y": FAR_POINT.y}})]})
	ok(w3b.level_attack_target("E1") == null,
		"★ kind=building 但那一格没有建筑 → null（退回现状挑选）")

	# base：那一方的大本营格
	var w4 = _make(cfg, "rt_base", {"factions": [_faction({
		"attack_target": {"kind": "base", "faction": "F1"}})]})
	ok(w4 != null, "能造出「目标 = F1 的大本营」的世界")
	if w4 != null:
		var fb = w4.find_base_of("F1")
		ok(fb != null, "F1 有大本营")
		if fb != null:
			eq(w4.level_attack_target("E1"), Vector2i(int(fb.tx), int(fb.ty)),
				"★ kind=base 解析成那一方的大本营格")
	var w6 = _make(cfg, "rt_base_missing", {"factions": [_faction({
		"attack_target": {"kind": "base", "faction": "NOPE"}})]})
	ok(w6.level_attack_target("E1") == null, "★ kind=base 但那一方没有大本营 → null（退回现状）")


# ------------------------------------------------------------------
# 二、★ 缺省 = 现状（离自己最近的敌方区划中心）
# ------------------------------------------------------------------
func _group_default(cfg) -> void:
	# ★★ 为什么需要第三个阵营：样例关卡里 F1 是玩家、E1 是敌方 AI，
	#    除此之外**一个敌人都没有**（config 那个 "ai" 被关卡 none 掉了）——
	#    于是「最近的敌方区划中心」根本不存在，AI 会正确地不出兵（那不是这条要验的东西）。
	#    这里放一个 `ai: none` 的第三阵营 N1 占一块地：它既不是 F1 的同方，
	#    也不会自己动，正好当那个「敌方区划」。
	var w = _third_party_world(cfg, "df", {})
	ok(w != null, "能造出「有一个中立第三方占地」的世界")
	if w == null:
		return
	var want = _nearest_enemy_center(w, "E1")
	ok(want != null, "算得出一个「最近的敌方区划中心」")
	if want == null:
		return
	eq(_owner(w, 0), "N1", "第三阵营占着 b1（Zone 0）")
	ok(w.level_attack_target("E1") == null, "没写进攻目标时解析结果是 null（退回现状）")

	# ★★ 把将领**直接喂到满员**再跑：这些用例要钉的是「缺省时它往哪打」，
	#   不是「AI 靠自己的经济多久能攒出一支部队」。不喂的话，出兵的 gate
	#   （每个可进攻的将领都补满**它自己那一档编制**）会把它挡在
	#   「招兵 → 等人口」循环里好几分钟 —— 那让断言量错了东西（实测踩到）。
	_fill_retinues(w, "E1")
	var goal = _run_until_launch(w, 60.0)
	ok(goal != null, "★ 缺省时 AI 会出兵（满员之后一波）")
	if goal != null:
		eq(int(goal.get("x", -1)), (want as Vector2i).x,
			"★ 缺省目标是最近的敌方区划中心（x）")
		eq(int(goal.get("y", -1)), (want as Vector2i).y,
			"★ 缺省目标是最近的敌方区划中心（y）")


# ------------------------------------------------------------------
# 三、★ 不可达 / 解析不出来 → 退回现状
# ------------------------------------------------------------------
func _group_unreachable(cfg) -> void:
	# 指向地图**外**：解析不出来
	var w = _make(cfg, "ur_out", {"factions": [_faction({
		"attack_target": {"kind": "point", "x": 999, "y": 999}})]})
	ok(w.level_attack_target("E1") == null, "★ 目标在地图外 → null（退回现状挑选）")
	# 真跑一段：它照样会出兵（没有对着走不到的点发呆）
	var w2 = _third_party_world(cfg, "ur_out_run", {
		"_target": {"attack_target": {"kind": "point", "x": 999, "y": 999}}})
	var want2 = _nearest_enemy_center(w2, "E1")
	ok(want2 != null, "算得出退回后的目标点")
	if want2 == null:
		return
	_fill_retinues(w2, "E1")
	var goal2 = _run_until_launch(w2, 60.0)
	ok(goal2 != null, "★ 目标不可达时它**照样出兵**（退回现状挑选，不原地发呆）")


# ------------------------------------------------------------------
# 四、出兵播报 + 走现成的行军攻击命令
# ------------------------------------------------------------------
func _group_launch(cfg) -> void:
	var w = _third_party_world(cfg, "launch", {})
	var want = _nearest_enemy_center(w, "E1")
	ok(want != null, "算得出目标点")
	if want == null:
		return
	_fill_retinues(w, "E1")     # 同上：直接喂满员，别让经济节奏左右这条断言
	var goal = _run_until_launch(w, 60.0)
	ok(goal != null, "★ 出兵时会发一条 ai_attack_launched")
	if goal == null:
		return
	eq(String(goal.get("faction", "")), "E1", "事件里写明是哪一方")
	eq(int(goal.get("x", -1)), (want as Vector2i).x, "事件里的目标 x")
	eq(int(goal.get("y", -1)), (want as Vector2i).y, "事件里的目标 y")
	ok(int(goal.get("leaders", 0)) >= 1, "事件里写了派了几位将领（%d）" % int(goal.get("leaders", 0)))

	# 出兵走的是**现成的**行军攻击命令（不是新写的一套）
	var moving := 0
	for u in _generals_of(w, "E1"):
		if u.has_attack_move:
			moving += 1
	ok(moving >= 1, "★ 被派出去的将领带上了 has_attack_move（行军攻击那条现成路径）")
	# ★ 一波之后还会再来一波：`attack_repeat_sec` = 2 秒，所以短时间内会再发
	#   （再喂一次满员：打起来之后它们会掉编制，那不给出兵就不发了）
	_fill_retinues(w, "E1")
	var more := _count_launches(w, 30.0)
	ok(more >= 1, "★ 隔一段时间还会再派一波（又发了 %d 次）" % more)


## 把某一方的将领**直接喂到各自满员**（塞已经生成的附属兵，不走读条）。
##
## ★ 为什么用例需要它：出兵的 gate 是「每个可进攻的将领都补满**它的目标编制**」，
##   而目标编制 = **关卡里给这位将领摆了几个附属兵**（`world.escort_target_of`）——
##   本轮把 `config.json` 的 `unit.general.escort` 全局缺省删掉了。
##   真让 AI 自己招的话，它要跟「区划人口上限 + 读条 10 秒 + 资源」缠好几分钟 ——
##   那几件事与「进攻目标解析成哪一格」毫无关系，却能把断言拖红（实测踩到）。
##
## ★★ 而这些用例的关卡里**一个附属兵都没摆** ⇒ 目标编制是 0 ⇒ gate 从一开始就通过、
##   「补员」那条链根本没被走过。所以这里**显式摆一份测试规模**：
##   把它写进 `world.placed_escorts`（AI 的补员目标读的就是它），再按它喂满。
##   这不是绕过新口径，而是把「关卡摆了几个」这件事在测试里写出来。
const TEST_RETINUE := 5

func _fill_retinues(w, faction: String) -> void:
	if w == null:
		return
	for u in w.units:
		if not u.alive or String(u.faction) != faction or not u.is_general():
			continue
		var gi: int = int(u.general_index)
		if gi >= 0:
			w.placed_escorts["%s|%d" % [faction, gi]] = TEST_RETINUE
		var want_n: int = TEST_RETINUE
		var have: int = u.retinue_size(w)
		var i := 0
		while have + i < want_n:
			var soldier = UnitRes.create(
				w.cfg, "%s-fill%d" % [String(u.id), i], "AI 兵",
				Vector2i(u.tx, u.ty), faction, String(u.unit_type), "", String(u.id),
				String(u.unit_type)
			)
			w.units.append(soldier)
			i += 1


# ------------------------------------------------------------------
# 造世界的工具
# ------------------------------------------------------------------

## E1 的默认阵营配置 + 一个进攻目标（用例只关心进攻目标那一件事）。
##
## ★★ 钱刻意给多（3000）：这些用例要的是「**出兵**那一帧」，而出兵的 gate 是
##   「可进攻的将领都补满**它自己那一档编制**」——编制来自 `unit.general.escort`
##   （config 里是 `[4,5,6]`，共 15 个兵 × 50 金 = 750 金）。
##   只给 400 的话 AI 招到一半就没钱，永远补不满、永远不出兵 ——
##   那会让下面几条断言看起来像「目标解析坏了」，实际是经济不够（实测踩到）。
##   ★ 用例要钉的是「目标解析成哪一格 / 会不会出兵」，不是关卡平衡，
##     所以这里把经济条件一次性给足，不跟着关卡平衡值走。
func _faction(extra: Dictionary) -> Dictionary:
	var d := {
		"id": "E1", "ai": "faction", "base": [BASE_E1.x, BASE_E1.y],
		"start_food": 3000, "start_gold": 3000,
		"faction_ai": {"generals": 3, "min_retinue": 0, "min_ready": 1, "ready_mult": 1.0,
			"attack_repeat_sec": 2.0, "recruit_cooldown_sec": 0.5},
	}
	for k in extra.keys():
		d[k] = extra[k]
	return d


## 从关卡数据里读**第一栋开局摆放的建筑**所在的格（没有 → (-1,-1)）。
##
## ★ 为什么读数据而不是写死坐标：那栋塔的位置是 `BASE_F1 + (3,0)` 算出来的，
##   而大本营是按区划挑的 —— 区划一重排它就变（实测踩到）。
func _first_start_building(cfg) -> Vector2i:
	var raw := _read_json("%s/levels/01_beachhead.json" % DEMO_DIR)
	for e in (raw.get("start_buildings", []) as Array):
		if typeof(e) == TYPE_DICTIONARY:
			var d: Dictionary = e
			return Vector2i(int(d.get("x", -1)), int(d.get("y", -1)))
	return Vector2i(-1, -1)


## 从关卡数据里读**某个兵种**的第一支部队（没有 → (-1,-1)）。
func _first_start_unit(cfg, kind: String) -> Vector2i:
	var raw := _read_json("%s/levels/01_beachhead.json" % DEMO_DIR)
	for e in (raw.get("start_units", []) as Array):
		if typeof(e) == TYPE_DICTIONARY:
			var d: Dictionary = e
			if String(d.get("kind", "")) == kind:
				return Vector2i(int(d.get("x", -1)), int(d.get("y", -1)))
	return Vector2i(-1, -1)


## 在有「一个中立第三方占地」的关卡上造世界（见 `_group_default` 的说明）。
func _third_party_world(cfg, name: String, patch: Dictionary):
	var p := patch.duplicate()
	p["factions"] = [{"id": "ai", "ai": "none"}, {"id": "N1", "ai": "none"},
		_faction(patch.get("_target", {}))]
	# 目标区划 c1 仍归玩家；**另外**把 b1（Zone 0）划给第三方 —— 它是「敌方区划」
	p["zones"] = [{"id": ZONE_C1, "owner": "F1"}, {"id": 0, "owner": "N1"}]
	p.erase("_target")
	return _make(cfg, name, p, false)


func _make(cfg, name: String, patch: Dictionary, inject_default_ai: bool = true):
	var raw := _read_json("%s/levels/01_beachhead.json" % DEMO_DIR)
	if raw.is_empty():
		return null
	# 默认把 config 那个 "ai" 关掉，让用例只关心自己声明的那几方
	var p := patch.duplicate()
	p.erase("_target")
	if inject_default_ai:
		var factions: Array = [{"id": "ai", "ai": "none"}]
		if p.has("factions"):
			for e in (p["factions"] as Array):
				factions.append(e)
		p["factions"] = factions
	for k in p.keys():
		raw[k] = p[k]
	var dir := "%s/%s" % [TMP_ROOT, name]
	_write("%s/campaign.json" % dir, JSON.stringify({"levels": [{"file": "levels/l.json"}]}))
	_write("%s/levels/l.json" % dir, JSON.stringify(raw))
	var c = CampaignRes.load_campaign(dir, cfg)
	if c == null:
		return null
	var w = WorldRes.create_from_level(cfg, c.level_at(0), "F1", ["F1"], true)
	_seed_population(w)
	return w


## ★★ 把每个区划的**人口上限与当前人口**都抬起来 —— 让「招兵」不再受人口限制。
##
## 为什么这些用例需要它（实测踩到，找了两轮才定位）：招一个兵要 `population_cost = 1`，
## 而区划人口从 **0** 开始、按 `production.population × 地块数`（≈3~12/s）涨，
## **上限 `population_cap` 默认是 1**（见 logic/zone.gd）。
## ⇒ 每个区划**同一时刻只够招一个兵**，编制 `[4,5,6]` 那 15 个兵要等好几分钟。
## 于是「240 秒内会不会出兵」这条断言量的其实是**人口上限**，
## 而不是「进攻目标解析对不对 / 出兵那条链通不通」。
## ⚠️ 只写 `population` 没用：`zones.update_population()` 每帧把它夹回 `population_cap`
##    （`minf(cap, ...)`），所以**上限和当前值要一起抬**。
func _seed_population(w) -> void:
	if w == null or w.zones == null:
		return
	for z in w.zones.zones:
		var zd: Dictionary = z
		zd["population_cap"] = 999.0
		zd["population"] = 999.0


## 一直 tick 到第一次 `ai_attack_launched`（最多 max_sec 秒）；返回那条事件（没有 → null）。
func _run_until_launch(w, max_sec: float):
	var steps := int(max_sec / 0.1)
	for i in steps:
		for e in w.tick(0.1):
			var ev: Dictionary = e
			if String(ev.get("type", "")) == "ai_attack_launched":
				return ev
	return null


## 再跑 max_sec 秒，数一共发了几次出兵事件。
func _count_launches(w, max_sec: float) -> int:
	var n := 0
	var steps := int(max_sec / 0.1)
	for i in steps:
		for e in w.tick(0.1):
			if String((e as Dictionary).get("type", "")) == "ai_attack_launched":
				n += 1
	return n


## 这一方还活着的将领（事件里只给「派了几位」，要落到具体单位就得自己数）。
func _generals_of(w, faction: String) -> Array:
	var out: Array = []
	for u in w.units:
		if u.alive and String(u.faction) == faction and u.is_general():
			out.append(u)
	return out


func _owner(w, zid: int) -> String:
	for z in w.zones.zones:
		if int((z as Dictionary).get("id", -1)) == zid:
			return String((z as Dictionary).get("owner", ""))
	return ""


## 「离这一方最近的**敌方区划中心**」—— 就是 `faction_ai._attack_target_default()` 的规则。
##
## ★ 在测试里复刻这一条是有意的：它要钉的是**缺省走的是哪条规则**，
##   而不是「某个写死的坐标」。地图一改，这个期望值跟着变，测试仍然有效。
##   （判据与逻辑层一致：跳过无主 / 盟友的区划、跳过没有中心的。）
func _nearest_enemy_center(w, faction: String):
	if w == null or w.zones == null:
		return null
	var base = w.find_base_of(faction)
	if base == null:
		return null
	var from := Vector2(base.tx, base.ty)
	var best = null
	var best_d := -1.0
	for z in w.zones.zones:
		var zd: Dictionary = z
		var owner := String(zd.get("owner", ""))
		if owner == "":
			continue
		if FactionRes.same_side(owner, faction):
			continue
		var c: Variant = zd.get("center", null)
		if c == null:
			continue
		var ct: Vector2i = c
		var d := from.distance_squared_to(Vector2(ct.x, ct.y))
		if best == null or d < best_d:
			best = ct
			best_d = d
	return best


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("读不到 %s" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("打不开 %s" % path)
		return {}
	var txt := f.get_as_text()
	f.close()
	var data: Variant = JSON.parse_string(txt)
	if typeof(data) != TYPE_DICTIONARY:
		push_error("%s 不是 JSON 对象" % path)
		return {}
	return data


func _write(path: String, text: String) -> void:
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("写不了 %s" % path)
		return
	f.store_string(text)
	f.close()


func _clean_tmp() -> void:
	_remove_dir(TMP_ROOT)


func _remove_dir(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var d := DirAccess.open(path)
	if d == null:
		return
	for sub in d.get_directories():
		_remove_dir(path.path_join(sub))
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)
