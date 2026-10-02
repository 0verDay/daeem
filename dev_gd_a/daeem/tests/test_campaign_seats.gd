## test_campaign_seats.gd —— **「选边关」**（一关两个可玩阵营，选一个来打）的断言。
##
## 样例第一关就是这种关卡：
##   · 蓝方（F1）**守住 c1 150 秒**；红方（F2）**占领 c1**（归属翻过来那一帧就赢）；
##   · 两边**是对立的**（不是盟友）—— 所以校验第 7 条的「互为同方」在这里**不适用**，
##     改拦「每个可玩阵营都要有属于它的目标」（见 logic/level.gd 的 `_ck_allies`）；
##   · 玩家选中哪一方，运行时那一方由本机操作、另一方交给 AI。
##
## 盯的是「不写就会静默错」的那一类（每一条都是实测踩出来的）：
##   · 两条目标按 `for` 分开，选谁取谁那条（取错了 = 红方拿着「守住 c1」进关）；
##   · ★ **守方席位名单只含本机操作的那一方**（把敌人也算进去的话：①「占领 c1」的判据
##     会变成「归我或归敌人」⇒ 开局第一帧就判胜；②敌人的家被拆会连累玩家判负）；
##   · ★ **没被选中的那一方真的挂着 AI**（两边都没有 AI 的话，你选红方就是一路平推）；
##   · ★ **只有玩家自己那一方有开局附属兵**（AI 那一边要自己招 —— 否则一局只出一波，
##     「招将 → 招满 → 出征」那个波次节奏根本不存在）；
##   · ★ 每个区划的中心建筑都建得出来（大本营的自动防御阵地不许压在中心格上）。
##
## ⚠️ 语言约定见 tests/test_case.gd（`--script` 下全局 class_name 不可用；只用 preload 常量）。
extends "res://tests/test_case.gd"

const CampaignRes = preload("res://logic/campaign.gd")
const WorldRes = preload("res://logic/world.gd")
const ObjectiveRes = preload("res://logic/objective.gd")
const BuildingRes = preload("res://logic/building.gd")
const FactionRes = preload("res://logic/faction.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const LEVEL_ID := "01_beachhead"
## 目标区划 c1（蓝方守、红方攻的都是它）
const OBJ_ZONE := 4


func _initialize() -> void:
	run_all(Callable(self, "_run"))


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_group_data(cfg)
	_group_objective_pick(cfg)
	_group_ai_swap(cfg)
	_group_escort(cfg)
	_group_centers(cfg)
	_group_base_loss(cfg)
	_group_capture(cfg)
	_group_ai_ally_acts(cfg)


# ------------------------------------------------------------------
# 一、数据：两个都可玩、互为敌对、各有一条目标
# ------------------------------------------------------------------
func _group_data(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	ok(camp != null, "样例战役能载入")
	if camp == null:
		return
	eq(camp.playable_ids(), ["F1", "F2"], "★ 战役里可玩的是两个阵营（蓝方 F1 / 红方 F2）")

	var lv = camp.level(LEVEL_ID)
	ok(lv != null, "第一关能载入")
	if lv == null:
		return
	eq(lv.playable_ids(), ["F1", "F2"], "★ 第一关可选的两个阵营")
	ok(lv.has_per_faction_objectives(), "★ 这一关是「选边关」（目标按阵营分开）")

	# ★★ 两个可玩阵营**是对立的**（这一关就是「选边打」）——
	#    「必须互为同方」那条规则只对**普通关卡**（目标只有一份）成立。
	FactionRes.set_allies(lv.effective_allies())
	ok(not FactionRes.same_side_for_attack("F1", "F2"),
		"★ 蓝方与红方是敌对关系（选边关的设计前提）")

	# ★ 这一关**必须**一个拦截项、一个警告都没有
	var blocks: Array = lv.blockers()
	var detail := ""
	for b in blocks:
		detail += " / %s" % String((b as Dictionary)["msg"])
	ok(blocks.is_empty(), "样例第一关没有拦截项%s" % detail)
	eq(lv.check(cfg.ai_factions()).size(), 0, "样例第一关连警告都没有")


# ------------------------------------------------------------------
# 二、★ 目标按阵营取：选谁就打谁那条
# ------------------------------------------------------------------
func _group_objective_pick(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID)

	eq(String(lv.objective_of("F1")["kind"]), "hold_zone", "★ 蓝方的目标是**守住** c1")
	eq(String(lv.objective_of("F2")["kind"]), "capture_zone", "★ 红方的目标是**攻占** c1")
	eq(int(lv.objective_of("F1")["zone"]), OBJ_ZONE, "蓝方守的是 c1")
	eq(int(lv.objective_of("F2")["zone"]), OBJ_ZONE, "红方攻的也是 c1（同一个区划）")
	ok(lv.objective_for("ZZ") == null,
		"★ 没点名给某一方、也没有通用那一条时 → null（**不退回第一条**）")

	# 两条目标的人话
	ok(lv.objective_label("F1").contains("守"), "蓝方那句话是「守住…」")
	ok(lv.objective_label("F2").contains("占领"), "红方那句话是「占领…」")

	# ★★ 运行时：选谁，`objective_state` 里就是谁那条
	var w1 = _world(cfg, lv, "F1")
	if w1 != null:
		eq(String(w1.objective_state["kind"]), "hold_zone", "★ 选蓝方 → 打的是「守住」那条")
		eq(String(w1.objective_state["state"]), "running", "开局是进行中")
	var w2 = _world(cfg, lv, "F2")
	if w2 != null:
		eq(String(w2.objective_state["kind"]), "capture_zone", "★ 选红方 → 打的是「攻占」那条")
		eq(String(w2.objective_state["state"]), "running",
			"★ 红方开局**不判负也不判胜**（c1 在蓝方手里，得自己打下来）")
		eq(w2.objective_state["defend"], ["F2"], "★ 守方席位只有本机操作的 F2")


# ------------------------------------------------------------------
# 三、★ 选谁就摘谁的 AI，另一方真的在动
# ------------------------------------------------------------------
func _group_ai_swap(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID)

	var w1 = _world(cfg, lv, "F1")
	ok(w1 != null, "选蓝方能建出世界")
	if w1 != null:
		eq(_piloted(w1), ["F2"], "★ 选蓝方 → 红方 F2 由 AI 接管")
		eq(w1.player_factions, ["F1"], "★ 本机操作的是 F1")
		eq(w1.player_seats, ["F1", "F2"], "两个席位都在本机（两个家都要建出来）")
		ok(w1.faction_bases.has("F2"), "★ 没被选中的红方照样有大本营（在地图上真的存在）")
		ok(w1.resource_pool_for("F2") != null, "红方有 AI 资源池（它要招兵出兵）")

	var w2 = _world(cfg, lv, "F2")
	ok(w2 != null, "选红方能建出世界")
	if w2 != null:
		# ★ 蓝方挂的是**将领性（守家）AI** —— 它**不进** `ai_factions` 状态表
		#   （那条路是「阵营性 AI」专用的，两者判据必须互斥，见 route.md 33.3）。
		#   它的行为走**单位上的 `garrison_zone_id`**，所以这里要验的是那个。
		eq(_piloted(w2), [], "★ 守家 AI 不建『阵营 AI 状态表』（判据互斥）")
		eq(w2.player_factions, ["F2"], "★ 本机操作的是 F2")
		ok(w2.player_seats.has("F1") and w2.player_seats.has("F2"),
			"席位名单里两边都在（两个家都要建出来；顺序 = 我选的那一方在前）")
		ok(w2.faction_bases.has("F1"), "没被选中的蓝方照样有大本营")
		# ★★ 守家 AI 的落点：它的将领必须有**归属区划**（否则它一动不动）
		var garrisoned := 0
		var generals := 0
		for u in w2.units:
			if not u.alive or String(u.faction) != "F1":
				continue
			var k := String(u.kind)
			if k == "general" or k.begins_with("general_"):
				generals += 1
				if int(u.garrison_zone_id) >= 0:
					garrisoned += 1
		ok(generals > 0 and garrisoned == generals,
			"★ 蓝方（守家 AI）的将领都拿到了归属区划（%d/%d）" % [garrisoned, generals])

	# ★★ 两边的 AI 名单**正好互换** —— 这就是「选谁有实际差别」的判据
	if w1 != null and w2 != null:
		ok(_piloted(w1) != _piloted(w2), "★ 选蓝方与选红方的 AI 名单不一样")
		ok(not _piloted(w1).has("F1") and not _piloted(w2).has("F2"),
			"★ 选中哪一方，那一方就**不在** AI 名单里（运行时摘掉）")

	# 资源池：选中那一方走玩家钱包，另一方走它自己的池子
	if w2 != null:
		var mine: Variant = w2.resource_pool_for("F2")
		var foe: Variant = w2.resource_pool_for("F1")
		ok(mine != null and foe != null, "两方都有资源池")
		# ⚠️ 比「不是同一个对象」要用 `is_same`：两个池子**内容**可能一样
		#    （都还是开局那点钱），而 `Dictionary` 的 `==` 是**逐字段比较**，
		#    拿 `!=` 判会得出「它们是同一个」（假红）。
		ok(not is_same(mine, foe), "★ 本机钱包与对手的池子**不是同一个对象**")
		ok(is_same(mine, w2.resources),
			"★★ 本机席位的池子就是 `world.resources`（HUD 与扣费必须是同一份数）")


# ------------------------------------------------------------------
# 四、★ 开局附属兵：只有玩家自己那一方有
# ------------------------------------------------------------------
func _group_escort(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID)

	for seat in ["F1", "F2"]:
		var w = _world(cfg, lv, String(seat))
		if w == null:
			continue
		ok(w.units.size() > 0, "[%s] 世界里有单位" % seat)
		var mine := _unit_count(w, String(seat))
		ok(mine > 3,
			"★ [%s] 玩家自己的那一方有开局附属兵（%d 个单位 > 3 位光杆将领）" % [seat, mine])
		var foe := "F2" if String(seat) == "F1" else "F1"
		# ★★ AI 那一方**没有**开局附属兵：它得自己「招将 → 招满 → 出征」，
		#    那才是波次节奏（给满编的话第一波瞬间就到，中间那段经营不存在）。
		eq(_general_count(w, foe), 3, "★ [%s] 对手只有 3 位光杆将领" % seat)
		eq(_escort_count(w, foe), 0,
			"★ [%s] 对手一个附属兵都没有（它必须自己招）" % seat)


# ------------------------------------------------------------------
# 五、★ 每个区划的中心建筑都建得出来
# ------------------------------------------------------------------
func _group_centers(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID)
	var w = _world(cfg, lv, "F1")
	if w == null:
		return
	# ⚠️ 大本营的自动防御阵地是「城墙 = 基地正上方」「箭塔 = 基地 + (2,0)」。
	#    基地点位没挑好时，那道箭塔正好压在区划中心格上 ⇒ 中立中心建筑**静默**建不出来
	#    （引擎只 push 一条 warning）。实测：红方的家放在 (4,1) 时 b1 的中心就没了。
	var missing: Array = []
	for z in w.zones.zones:
		var zd: Dictionary = z
		var c: Variant = zd["center"]
		if c == null:
			continue
		var t: Vector2i = c
		var b = w.building_at(t.x, t.y)
		if b == null or String(b.type) != BuildingRes.TYPE_ZONE_CENTER:
			var what := "空"
			if b != null:
				what = String(b.type)
			missing.append("c%d(%d,%d)=%s" % [int(zd["id"]), t.x, t.y, what])
	ok(missing.is_empty(), "★ 每个区划中心都建出来了（缺：%s）" % str(missing))


# ------------------------------------------------------------------
# 六、★ 大本营被拆：判**自己的席位**，不判「同方」
# ------------------------------------------------------------------
func _group_base_loss(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID)

	# 选蓝方：守方席位只有 F1
	var w = _world(cfg, lv, "F1")
	if w == null:
		return
	var st: Dictionary = w.objective_state
	eq(st["defend"], ["F1"], "★ 守方席位只有本机操作的那一方")

	# 拆掉自己的家 ⇒ 判负（哪怕对手的家还在）
	_kill_base(w, "F1")
	ObjectiveRes.update(w, cfg, st, 0.5)
	eq(String(st["state"]), "lost", "★ 拆掉自己席位的家 → 判负")
	eq(String(st["reason"]), ObjectiveRes.R_BASE_DESTROYED, "原因是 base_destroyed")

	# ★ 只拆**对手**的家 ⇒ **不**判负（那不是玩家的家）
	var w2 = _world(cfg, lv, "F1")
	if w2 == null:
		return
	var st2: Dictionary = w2.objective_state
	_kill_base(w2, "F2")
	ObjectiveRes.update(w2, cfg, st2, 0.5)
	eq(String(st2["state"]), "running",
		"★ 只拆掉对手的家 → 不判负（它不在守方席位里）")


# ------------------------------------------------------------------
# 七、★ 红方站进 c1 ⇒ 归属翻过来 ⇒ 立刻判胜
# ------------------------------------------------------------------
func _group_capture(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID)
	var w = _world(cfg, lv, "F2")
	if w == null:
		return
	var st: Dictionary = w.objective_state
	eq(String(st["kind"]), "capture_zone", "红方打的是攻占目标")
	var before := _owner(w, OBJ_ZONE)
	ok(before != "F2", "（前提）c1 开局不归红方（实际 %s）" % before)

	# 直接把 c1 的归属翻成红方（等价于「红方打下来了」那一帧）
	_set_owner(w, OBJ_ZONE, "F2")
	ObjectiveRes.update(w, cfg, st, 0.1)
	eq(String(st["state"]), "won", "★ 归属一翻过来就**立刻判胜**")
	eq(String(st["reason"]), "", "胜局没有原因")

	# ★ 反过来：红方一开始没打下来时**不能**判胜（否则一进关就赢）
	var w2 = _world(cfg, lv, "F2")
	if w2 == null:
		return
	var st2: Dictionary = w2.objective_state
	ObjectiveRes.update(w2, cfg, st2, 0.5)
	eq(String(st2["state"]), "running", "★ 没打下来之前一直进行中")


# ------------------------------------------------------------------
# 八、★ 没被选中的那一方真的会动
# ------------------------------------------------------------------
func _group_ai_ally_acts(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level(LEVEL_ID)
	# ★ 选蓝方 → 红方（阵营性 AI）应当自己招兵并出兵打过来
	var w = _world(cfg, lv, "F1")
	if w == null:
		return
	var before := _unit_count(w, "F2")
	var peak := before
	var launches := 0
	var t := 0.0
	while t < 240.0:
		for e in w.tick(0.1):
			var ev: Dictionary = e
			if String(ev.get("type", "")) == "ai_attack_launched" and String(ev.get("faction", "")) == "F2":
				launches += 1
		t += 0.1
		peak = maxi(peak, _unit_count(w, "F2"))
	# ⚠️ 判据是**峰值**，不是终值：它的兵是**会被打光的**（实测 240 秒里 3 → 17 → 3）——
	#   拿终值跟开局比会得出「它没招过兵」这种与事实相反的结论（这一条曾经就是这么假红的）。
	ok(peak > before, "★ 红方 AI 会自己招兵（开局 %d → 峰值 %d 个单位）" % [before, peak])
	ok(launches > 0, "★ 红方 AI 会自己出兵（240 秒里 %d 波）" % launches)


# ------------------------------------------------------------------
# 工具
# ------------------------------------------------------------------

## 按「玩家选 `seat`」造一个第一关的世界。
##
## ★★ roster 的拼法与顺序与 `view/game_scene.gd` 的 `build_roster()` **逐句对应**
##    （那边要建场景树，无头测试里跑不了）：
##      关卡 `players[]` 的席位 + 「可玩、且关卡点名要挂 AI」的那几个，
##      最后把**我选的那一方提到第一位**（第一位决定「打哪条目标」）。
##    ⚠️ 两处漂开就会变成「测试绿、进游戏不对」。
func _world(cfg, lv, seat: String):
	var roster: Array = _roster_for(cfg, lv)
	var idx: int = roster.find(seat)
	if idx > 0:
		roster.remove_at(idx)
		roster.push_front(seat)
	if roster.is_empty():
		roster.append(seat)
	return WorldRes.create_from_level(cfg, lv, seat, roster, true)


## 与 `view/game_scene.gd` 的 `build_roster()` 里那段拼装同一个口径（不含「提到第一位」）。
func _roster_for(cfg, lv) -> Array:
	var roster: Array = lv.seats()
	for e in lv.merged_ai_factions(cfg.ai_factions()):
		var fid := String((e as Dictionary).get("id", ""))
		if fid == "" or roster.has(fid):
			continue
		if lv.is_playable(fid):
			roster.append(fid)
	return roster


## 这一局**被 AI 接管**的阵营 id（顺序与 `world.ai_factions` 一致）。
func _piloted(w) -> Array:
	var out: Array = []
	for st in w.ai_factions:
		out.append(String((st as Dictionary)["faction"]))
	return out


## 场上活着的、属于 `fid` 的单位数。
func _unit_count(w, fid: String) -> int:
	var n := 0
	for u in w.units:
		if u.alive and String(u.faction) == fid:
			n += 1
	return n


## 场上活着的、属于 `fid` 的**将领**数（不含附属兵）。
func _general_count(w, fid: String) -> int:
	var n := 0
	for u in w.units:
		if not u.alive or String(u.faction) != fid:
			continue
		var k := String(u.kind)
		if k == "general" or k.begins_with("general_"):
			n += 1
	return n


## 场上活着的、属于 `fid` 的**附属兵**数（= 跟着将领的那些）。
func _escort_count(w, fid: String) -> int:
	var n := 0
	for u in w.units:
		if not u.alive or String(u.faction) != fid:
			continue
		if String(u.leader_id) != "":
			n += 1
	return n


## 把某一方的大本营从世界上摘掉（= 战斗结算那一刻；大本营本身不可被 `take_damage` 打死）。
func _kill_base(w, fid: String) -> void:
	var b = w.find_base_of(fid)
	if b == null:
		ok(false, "（前提）%s 有大本营" % fid)
		return
	b.alive = false
	b.hp = 0.0
	w.remove_building(b, true)


func _owner(w, zid: int) -> String:
	var z = w.zone_by_id(zid)
	if z == null:
		return ""
	return String((z as Dictionary)["owner"])


## 直接把某一区的归属写成 `owner`（模拟「打下来了」那一帧）。
func _set_owner(w, zid: int, owner: String) -> void:
	var z = w.zone_by_id(zid)
	if z == null:
		return
	var d: Dictionary = z
	d["owner"] = owner
	d["capture_faction"] = ""
	d["capture_state"] = ""
	d["progress"] = 0.0
