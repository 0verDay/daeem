## test_campaign_ai.gd —— **按阵营挂 AI**与难度（dev_plan_7 M7.1 / M7.2）。
##
## 盯的是「不写就会静默错」的那一类：
##   · `faction` / `general` / `none` 三种指派下**只有该负责的那一方动**（判据互斥）；
##   · ★★ **本局玩家席位那一方，哪怕关卡数据里写了 `ai: "faction"` 也不动**
##     （拍板第 13 项「玩家选中哪一方，运行时就把那一方的 AI 摘掉」）；
##   · `resource_mult` 只乘**收入**（不动开局资源）；
##   · 关卡按阵营覆盖的 AI 参数真的生效（`attack_repeat_sec` 这类）；
##   · 关卡显式 `ai: none` 的阵营**不进** AI 名单（哪怕全局 config 里有它）；
##   · 向后兼容：关卡没写 `ai` 的阵营照旧吃全局 `config.ai.factions`。
##
## ⚠️ 语言约定见 tests/test_case.gd（`--script` 下全局 class_name 不可用；只用 preload 常量）。
extends "res://tests/test_case.gd"

const CampaignRes = preload("res://logic/campaign.gd")
const WorldRes = preload("res://logic/world.gd")
const ConfigRes = preload("res://logic/config.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const TMP_ROOT := "res://.tmp_campaign_ai_tests"


func _initialize() -> void:
	run_all(Callable(self, "_run"))


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_clean_tmp()
	_group_roster(cfg)
	_group_player_seat_no_ai(cfg)
	_group_mult(cfg)
	_group_params(cfg)
	_group_faction_colors(cfg)
	_group_backward_compat(cfg)
	_clean_tmp()


# ------------------------------------------------------------------
# 一、AI 名单：谁进、谁不进
# ------------------------------------------------------------------
func _group_roster(cfg) -> void:
	# faction：进名单、进状态表、进资源池
	var w = _make(cfg, "roster_faction", {
		"factions": [
			{"id": "E1", "ai": "faction", "base": [18, 10], "start_food": 100, "start_gold": 50},
		],
	}, ["F1"])
	ok(w != null, "能造出「某一方挂阵营 AI」的世界")
	if w == null:
		return
	ok(w.ai_roster_cfg.size() >= 1, "合并后的 AI 名单非空")
	eq(_roster_ids(w), ["E1", "F1"], "名单 = 关卡点名的 AI 阵营 + 地图划过的阵营")
	ok(w.ai_resources.has("E1"), "E1 有资源池")
	ok(w.ai_factions.size() >= 1, "E1 有 AI 状态表")
	eq(w.resource_pool_for("E1"), w.ai_resources["E1"], "resource_pool_for(E1) 就是它那份池子")
	near(float(w.ai_resources["E1"]["food"]), 100.0, 0.001, "开局粮食来自关卡的 start_food")
	near(float(w.ai_resources["E1"]["gold"]), 50.0, 0.001, "开局黄金来自关卡的 start_gold")
	ok(w.ai_factions.size() == 1, "★ 只有 E1 一方有 AI 状态表（判据互斥）")
	eq(String((w.ai_factions[0] as Dictionary)["faction"]), "E1", "状态表里那一方是 E1")

	# none：不进任何一处
	var w2 = _make(cfg, "roster_none", {
		"factions": [{"id": "E1", "ai": "none", "base": [18, 10]},
			{"id": "ai", "ai": "none", "base": [6, 1]}],
	}, ["F1"])
	ok(w2 != null, "能造出「某一方不挂 AI」的世界")
	if w2 == null:
		return
	ok(not w2.ai_resources.has("E1"), "★ ai: none 的阵营**没有**资源池")
	eq(w2.ai_factions.size(), 0, "★ ai: none 的阵营**没有** AI 状态表")
	# ★★ `ai: none` 的语义是「这一方这一局**不动**」，**不是「不存在」** ——
	#    它照样在名单里（所以它名下的区块归属 / 摆放的单位都成立），只是没有任何 AI 接管它。
	ok(w2.factions.has("E1"), "★ ai: none 的阵营**仍在名单里**（它有地、有摆放，只是不动）")
	# ⚠️ 而**只有 config 提过**的阵营不进这一关（它没被关卡点名）—— 见 _group_backward_compat

	# general：名单里有它（要建基地 / 要有地），但**没有**阵营 AI 状态表
	var w3 = _make(cfg, "roster_general", {
		"factions": [{"id": "E1", "ai": "general", "base": [18, 10]}],
	}, ["F1"])
	ok(w3 != null, "能造出「某一方挂将领性 AI」的世界")
	if w3 == null:
		return
	ok(w3.factions.has("E1"), "ai: general 的阵营进名单（要建基地与地）")
	ok(not w3.ai_resources.has("E1"), "★ ai: general 的阵营**不建**阵营 AI 资源池")
	eq(w3.ai_factions.size(), 0, "★ ai: general 的阵营**不建**阵营 AI 状态表（互斥）")


# ------------------------------------------------------------------
# 二、★★ 玩家席位那一方永远不被 AI 接管
# ------------------------------------------------------------------
func _group_player_seat_no_ai(cfg) -> void:
	# 关卡给**玩家那一方**也写了 ai: faction（编辑器允许这么做，拍板第 13 项）
	var w = _make(cfg, "seat_no_ai", {
		"factions": [
			{"id": "F1", "ai": "faction", "base": [5, 10], "start_food": 999},
			{"id": "E1", "ai": "faction", "base": [18, 10]},
		],
	}, ["F1"])
	ok(w != null, "能造出「玩家那一方也配了 AI」的世界")
	if w == null:
		return
	ok(not w.ai_resources.has("F1"), "★ 玩家席位没有 AI 资源池（哪怕关卡给它配了 AI）")
	var has_f1 := false
	for st in w.ai_factions:
		if String((st as Dictionary)["faction"]) == "F1":
			has_f1 = true
	ok(not has_f1, "★ 玩家席位不在 AI 状态表里（「选中即摘 AI」的落点）")
	ok(w.ai_resources.has("E1"), "另一方的 AI 照常建（只摘玩家那一方）")
	eq(w.player_factions, ["F1"], "只有 F1 是玩家席位")
	# 玩家那一方的钱走 player_resources（不是 ai_resources）
	ok(w.player_resources.has("F1"), "玩家席位有自己的钱包")
	ok(is_same(w.resource_pool_for("F1"), w.resources),
		"★ 本机席位的池子就是 world.resources（同一个对象；用 is_same 比，别用 ==）")
	ok(w.resource_pool_for("F1") != null, "玩家席位永远有池子（不会被当成无限）")

	# ★ 跑 20 秒，确认**没有任何 AI 在指挥玩家那一方的单位**。
	#
	# ⚠️ 这里**不断言「坐标一个都没变」**：玩家方的单位仍会走正常的**单位逻辑**
	#   （战斗警戒 / 站定落点的回位 `reclaim_settled_spot` / 拥挤推挤后的归位），
	#   那些与「谁在指挥它」无关，而且在别的关卡布局下会真的动几步
	#   （实测：新样例地图上两个附属兵自己在 12 秒后挪了 4 格 —— 查清了，
	#     不是 AI 指挥，是[战斗]那一层的归位逻辑；断言改成下面这四条才是在验本意）。
	#   本条要钉的是：**AI 那一层没有接管它**。判据四条：
	#     ① 不在 AI 状态表里；② 没有 AI 资源池；③ 单位的 `has_attack_move` 全是 false
	#        （那是阵营 AI 唯一的出兵手段）；④ 没有单位挂着将领性 AI 的归属区划。
	ok(not has_f1, "★ 玩家席位不在 AI 状态表里（「选中即摘 AI」的落点）")
	for i in 200:
		w.tick(0.1)
	var marched := 0
	var garrisoned := 0
	for u in w.alive_units_of("F1"):
		if bool(u.has_attack_move):
			marched += 1
		if int(u.garrison_zone_id) >= 0:
			garrisoned += 1
	eq(marched, 0, "★ 玩家那一方没有任何单位收到「行军攻击」命令（那是阵营 AI 的唯一出兵手段）")
	eq(garrisoned, 0, "★ 玩家那一方没有单位被将领性 AI 接管（没有归属区划）")
	# 而真正挂了 AI 的那一方确实在做事（招了将 / 招了兵 / 或至少没有在挨饿）
	var e1_now = w.alive_units_of("E1").size()
	ok(e1_now > 0 or float(w.ai_resources["E1"]["food"]) > 0.0,
		"挂着 AI 的那一方在场上有兵（%d 个）" % e1_now)

	# 双人世界：两个席位都不被 AI 接管，第三方 AI 照旧
	var w2 = _make(cfg, "seat_no_ai_coop", {
		"mode": "coop",
		"players": [{"faction": "F1", "base": [5, 10]}, {"faction": "F2", "base": [5, 1]}],
		"allies": [["F1", "F2"]],
		"zones": [{"id": 4, "owner": "F1"}],
		"factions": [
			{"id": "F1", "ai": "faction"},
			{"id": "F2", "ai": "general"},
			{"id": "E1", "ai": "faction", "base": [18, 10]},
		],
	}, ["F1", "F2"])
	ok(w2 != null, "能造出双人世界")
	if w2 == null:
		return
	eq(w2.ai_factions.size(), 1, "★ 双人世界里只有第三方有 AI 状态表")
	eq(String((w2.ai_factions[0] as Dictionary)["faction"]), "E1", "那第三方是 E1")
	ok(w2.player_resources.has("F2"), "客机席位也有自己的钱包")
	# ⚠️★ GDScript 里 `Dictionary == Dictionary` 比的是**内容**，不是引用 ——
	#    两个空字典/内容相同的字典会被判成「相等」，于是这条断言会假红。
	#    要问「是不是同一个对象」必须用 `is_same()`。
	ok(not is_same(w2.resource_pool_for("F2"), w2.resources),
		"★ 客机席位的池子与**本机那一份不是同一个对象**（各花各的钱）")
	ok(is_same(w2.resource_pool_for("F1"), w2.resources),
		"★ 本机席位的池子**就是** world.resources（同一份，HUD 读的就是它）")
	ok(not is_same(w2.resource_pool_for("F2"), w2.resource_pool_for("F1")),
		"★ 两个玩家席位的池子互不相同")
	near(float(w2.resource_pool_for("F2")["food"]), float(cfg.start_food), 0.5,
		"客机席位开局资源与本机一样（各自独立，不是给的不一样）")

	# ★★ 每帧产出也按席位各发各的：给 F1 一块产粮地（c2），F2 一块都不给 ——
	#    跑一段之后 F1 的钱涨、F2 的不涨（这是「资源各自独立」在 tick 那一侧的落点）。
	var w3 = _make_coop_income(cfg)
	ok(w3 != null, "能造出「只有本机席位有地产出」的双人世界")
	if w3 == null:
		return
	var f1_before := float(w3.resource_pool_for("F1")["food"])
	var f2_before := float(w3.resource_pool_for("F2")["food"])
	for i in 20:
		w3.tick(0.1)
	var f1_gain := float(w3.resource_pool_for("F1")["food"]) - f1_before
	var f2_gain := float(w3.resource_pool_for("F2")["food"]) - f2_before
	ok(f1_gain > 0.0, "★ 本机席位（F1）每帧按地盘产能进账（+%.1f）" % f1_gain)
	ok(absf(f2_gain) < 1.0, "★ 客机席位（F2）没有地 → 不进账（%.3f）" % f2_gain)
	ok(not is_same(w3.resource_pool_for("F1"), w3.resource_pool_for("F2")),
		"★ 两人的钱包是两个对象（一人涨不会带上另一个人）")


# ------------------------------------------------------------------
# 三、`resource_mult` 只乘收入
# ------------------------------------------------------------------
func _group_mult(cfg) -> void:
	# 用标准 1.0 与 3.0 各跑同样的帧数，比较**收入**。
	# ★ 要能测出收入，就必须让 E1 **有产出**：样例地图上 c2（id=5）是产粮区（1/地块/秒），
	#   把它划给 E1。⚠️ 目标区划仍是 c1（id=4）且归 F1，否则关卡校验会拦。
	var a = _make_mult_world(cfg, 1.0)
	var b = _make_mult_world(cfg, 3.0)
	ok(a != null and b != null, "能造出两份只差 resource_mult 的世界")
	if a == null or b == null:
		return
	var prod: Dictionary = a.zones.production_of("E1")
	ok(float(prod["food"]) > 0.0, "E1 确实有产粮的地（%.1f/秒）" % float(prod["food"]))
	near(float(a.ai_resources["E1"]["food"]), 500.0, 0.001, "★ 开局资源不受倍率影响（1.0×）")
	near(float(b.ai_resources["E1"]["food"]), 500.0, 0.001, "★ 开局资源不受倍率影响（3.0×）")
	# ⚠️★ 必须**先跑一帧再量**：`upgrade_timer` 的初值是 0，所以 AI 在第一帧会
	#    **花一次钱**升级自己那栋最便宜的建筑（那一下会让「第 1 帧的增量」跳一下）。
	#    从那之后它的冷却被设成 999999 秒 ⇒ 这一段数据里它**再也不会花钱**，
	#    于是每一次 tick 的增量都**精确等于**纯收入 —— 这样才验得干净。
	var step := 0.1
	var da := 0.0
	var db := 0.0
	var jump := false
	a.tick(step)
	b.tick(step)
	for i in 50:
		var a1 := float(a.ai_resources["E1"]["food"])
		var b1 := float(b.ai_resources["E1"]["food"])
		a.tick(step)
		b.tick(step)
		var d1 := float(a.ai_resources["E1"]["food"]) - a1
		var d2 := float(b.ai_resources["E1"]["food"]) - b1
		da = d1
		db = d2
		if d1 < 0.0 or d2 < 0.0:
			jump = true
	ok(not jump, "★ 预热之后 AI 不再花钱（每一帧的粮食增量都 >= 0）")
	var base_rate := float(prod["food"])
	near(da, base_rate * step, 1e-6, "★ 1.0× 的收入 = 地盘产能 × dt（精确值）")
	near(db, base_rate * step * 3.0, 1e-6, "★ 3.0× 的收入正好是 1.0× 的三倍（精确值）")
	near(db, da * 3.0, 1e-6, "★ 两次刻度差值之比 = 3.0")
	# ⚠️ 不拿「池子总额」的比例去验倍率：AI 会按自己的钱决定**升几次级**
	#   （钱多的那一侧更容易多升一次），总额里混进了花费，比出来不是整数。
	#   上面那两条**逐帧增量**才是纯收入，它们已经精确验到了这一件事。
	eq(a.resource_mult_of("E1"), 1.0, "resource_mult_of 读到 1.0")
	eq(b.resource_mult_of("E1"), 3.0, "resource_mult_of 读到 3.0")


# ------------------------------------------------------------------
# 四、关卡按阵营覆盖 AI 参数
# ------------------------------------------------------------------
func _group_params(cfg) -> void:
	var w = _make(cfg, "params", {
		"factions": [{
			"id": "E1", "ai": "faction", "base": [18, 10],
			"faction_ai": {"attack_repeat_sec": 33.0, "generals": 1, "min_retinue": 2},
		}],
	}, ["F1"])
	ok(w != null, "能造出带自定义 AI 参数的世界")
	if w == null:
		return
	var p: Dictionary = w.faction_ai_cfg("E1")
	near(float(p["attack_repeat_sec"]), 33.0, 0.001, "★ 关卡覆盖 attack_repeat_sec")
	eq(int(p["generals"]), 1, "★ 关卡覆盖 generals")
	eq(int(p["min_retinue"]), 2, "★ 关卡覆盖 min_retinue")
	# 没覆盖的键回落到 config
	var glob: Dictionary = cfg.ai_faction_cfg()
	near(float(p["ready_mult"]), float(glob["ready_mult"]), 0.001, "没覆盖的键回落到 config")
	near(float(p["recruit_cooldown_sec"]), float(glob["recruit_cooldown_sec"]), 0.001,
		"没覆盖的键（冷却）也回落")
	# 状态表里存的参数就是这一份（每帧不重算）
	eq(String(w.ai_factions[0]["faction"]), "E1", "状态表里是 E1")
	near(float((w.ai_factions[0] as Dictionary)["params"]["attack_repeat_sec"]), 33.0, 0.001,
		"★ 状态表里存的参数已经是关卡覆盖后的那一份")
	# 白名单：拼错的键不进结果（免得「配了但没生效」静默）
	var w2 = _make(cfg, "params_typo", {
		"factions": [{
			"id": "E1", "ai": "faction", "base": [18, 10],
			"faction_ai": {"attack_repeat_seconds": 1.0},
		}],
	}, ["F1"])
	var p2: Dictionary = w2.faction_ai_cfg("E1")
	ok(not p2.has("attack_repeat_seconds"), "★ 拼错的键**不进**参数表（白名单读取）")
	near(float(p2["attack_repeat_sec"]), float(glob["attack_repeat_sec"]), 0.001,
		"拼错的键不会顶掉真键")
	# 另一方没有覆盖 → 拿到的是全局那份
	near(float(w.faction_ai_cfg("E1")["upgrade_cooldown_sec"]),
		float(glob["upgrade_cooldown_sec"]), 0.001, "未覆盖的一方看全局")


# ------------------------------------------------------------------
# 五、向后兼容：不做战役 / 关卡没写 ai
# ------------------------------------------------------------------
func _group_backward_compat(cfg) -> void:
	# ★ 老入口：行为与加战役之前一致（`cfg.ai_factions` 说了算）
	var w = WorldRes.create(cfg, "res://data/maps/frontier/map.json", true)
	ok(w != null, "老入口（create + with_ai）照样能建世界")
	if w == null:
		return
	eq(w.level, null, "老入口没有关卡")
	var cfg_ids: Array = []
	for e in cfg.ai_factions():
		cfg_ids.append(String((e as Dictionary)["id"]))
	var roster_ids := _roster_ids(w)
	for fid in cfg_ids:
		ok(roster_ids.has(fid), "★ 老入口：config 的 AI 阵营「%s」照旧在名单里" % fid)
	eq(w.ai_factions.size(), cfg_ids.size(), "★ 老入口：AI 状态表条数 = config 的条数")

	# 关卡**没写** ai 的阵营：★ 不进这一局（有 level 时「这一关有哪些阵营」由关卡数据说了算）。
	var w2 = _make(cfg, "compat_level", {
		"factions": [{"id": "E1", "ai": "faction", "base": [18, 10]}],
	}, ["F1"])
	var ids2 := _roster_ids(w2)
	ok(ids2.has("E1"), "关卡点名的 E1 进场")
	for fid in cfg_ids:
		if fid == "E1":
			continue
		ok(not ids2.has(fid),
			"★ 只有 config 提过的「%s」**不进**这一关（加它不该悄悄改变已有战役）" % fid)
	ok(not w2.factions.has("ai"), "★ 那一方也不在世界名单里")

	# ★ 但**关卡显式写 ai: none** 的 config 阵营照样不进（这就是「明确关掉」的写法）
	var w3 = _make(cfg, "compat_off", {
		"factions": [{"id": "ai", "ai": "none"}, {"id": "E1", "ai": "faction", "base": [18, 10]}],
	}, ["F1"])
	ok(not _roster_ids(w3).has("ai"), "★ 关卡写 ai: none 的 config 阵营不进名单")


# ------------------------------------------------------------------
# 工具
# ------------------------------------------------------------------

func _make(cfg, name: String, patch: Dictionary, seats: Array):
	var raw := _read_json("%s/levels/01_beachhead.json" % DEMO_DIR)
	if raw.is_empty():
		return null
	# ⚠️ 不在这里偷偷注入 `{"id": "ai", "ai": "none"}`：有 level 时**只有 config 提过**的
	#    阵营本来就不会进场（`world._merged_ai_roster` 那一条），用不着每个用例都写一遍；
	#    要验「明确关掉」那件事的用例**自己**写那个字段（见 `_group_roster` 的 none 那一段）。
	var p := patch.duplicate()
	for k in p.keys():
		raw[k] = p[k]
	var dir := "%s/%s" % [TMP_ROOT, name]
	_write("%s/campaign.json" % dir, JSON.stringify({"levels": [{"file": "levels/l.json"}]}))
	_write("%s/levels/l.json" % dir, JSON.stringify(raw))
	var c = CampaignRes.load_campaign(dir, cfg)
	if c == null:
		return null
	return WorldRes.create_from_level(cfg, c.level_at(0), String(seats[0]), seats, true)


## 只差 `resource_mult` 的两份世界。
##
## ★★ 这份数据刻意让 AI **不花一分钱**（`generals` / `min_retinue` 都是 0、
##   升级冷却给到天上）—— 这样「粮食增量」就等于**纯收入**，
##   倍率那一件事才验得干净（否则 AI 中途买一次兵，差值会跳一下）。
func _make_mult_world(cfg, mult: float):
	return _make(cfg, "mult_%d" % int(mult * 10), {
		"zones": [{"id": 5, "owner": "E1"}],
		"factions": [{
			"id": "E1", "ai": "faction", "base": [18, 10],
			"resource_mult": mult, "start_food": 500, "start_gold": 500,
			"faction_ai": {"generals": 0, "min_retinue": 0, "upgrade_cooldown_sec": 999999.0},
		}],
	}, ["F1"])


## 双人世界：只有 **F1** 有一块产粮地（c2），F2 一块都没有 ——
## 用来验「每帧产出也按席位各算各的」。
func _make_coop_income(cfg):
	return _make(cfg, "coop_income", {
		"mode": "coop",
		"players": [{"faction": "F1", "base": [5, 10]}, {"faction": "F2", "base": [5, 1]}],
		"allies": [["F1", "F2"]],
		"zones": [{"id": 4, "owner": "F1"}, {"id": 5, "owner": "F1"}],
		"factions": [{"id": "F1", "ai": "none"}, {"id": "F2", "ai": "none"}],
	}, ["F1", "F2"])


## ★★ 阵营配色：战役可以用自己的阵营 id，而配色表里只有内置的那些。
##
## 不登记的话 `cfg.faction_color("F1")` 会退到**品红**，画面上就是
## 「整个战场一片紫、敌我分不清」（玩家实测报的就是这个）。
## 这一组把「登记生效 / 认不出来的颜色要兜底 / 老路径不受影响」三件事钉住。
func _group_faction_colors(cfg) -> void:
	var magenta := Color.MAGENTA

	# ---- 数据里没写颜色 → 按内置配色兜底，**绝不能是品红** ----
	# ★ 这一条就是玩家报的那个 bug：战役用自己的阵营 id（F1/E1），而配色表里只有内置 id，
	#   不兜底的话整场都是 `Color.MAGENTA`（「整个战场一片紫、敌我分不清」）。
	var bare = _make(cfg, "color_bare", {
		"factions": [{"id": "E1", "ai": "faction", "base": [18, 10]}],
	}, ["F1"])
	ok(bare != null, "能造出「关卡没给颜色」的世界")
	if bare != null:
		var b1: Color = bare.cfg.faction_color("F1", "main")
		var b2: Color = bare.cfg.faction_color("E1", "main")
		ok(b1 != magenta, "★ 没写颜色的自定义阵营不再是品红（F1）")
		ok(b2 != magenta, "★ 没写颜色的自定义阵营不再是品红（E1）")
		ok(b1 != b2, "★ 兜底给两方**不同**的颜色（不然还是敌我分不清）")
		ok(bare.cfg.has_faction_color("F1"), "兜底那次也是一次真登记")
		# 兜底取的是内置配色，所以颜色一定能在内置表里找到
		var in_builtin := false
		for fid_b in ["p1", "p2", "p3", "p4"]:
			if b1.is_equal_approx(cfg.faction_color(fid_b, "main")):
				in_builtin = true
		ok(in_builtin, "★ 兜底用的是内置配色（不是随手编的颜色）")

	# ---- 写了颜色 → 登记生效（两个阵营 id 都是自定义的）----
	var w = _make(cfg, "color_ok", {
		"factions": [
			{"id": "F1", "ai": "none", "color": "#5ac8ff"},
			{"id": "E1", "ai": "faction", "base": [18, 10], "color": "#e05a5a"},
		],
	}, ["F1"])
	ok(w != null, "能造出「关卡给了颜色」的世界")
	if w == null:
		return
	var c1: Color = w.cfg.faction_color("F1", "main")
	var c2: Color = w.cfg.faction_color("E1", "main")
	ok(c1 != magenta, "★ 关卡写了颜色的阵营不再退到品红（F1）")
	ok(c2 != magenta, "★ 关卡写了颜色的阵营不再退到品红（E1）")
	ok(c1 != c2, "★ 两方颜色不同（不然还是「敌我分不清」）")
	near(c1.r, 0x5a / 255.0, 0.01, "F1 的主色是按数据解析出来的（红通道）")
	near(c1.g, 0xc8 / 255.0, 0.01, "F1 的主色（绿通道）")
	near(c2.r, 0xe0 / 255.0, 0.01, "E1 的主色（红通道）")
	# sel / bar 没单独写就跟 main 走
	eq(w.cfg.faction_color("F1", "sel"), w.cfg.faction_color("F1", "main"),
		"sel 没写就跟 main 一样（只给一个颜色也能用）")
	eq(w.cfg.faction_color("E1", "bar"), w.cfg.faction_color("E1", "main"),
		"bar 没写就跟 main 一样")
	ok(w.cfg.has_faction_color("F1"), "登记过的阵营能问出来（给排查用）")
	ok(not w.cfg.has_faction_color("nobody"), "没登记的问出来是 false")

	# ---- 颜色写错了 → **不当成黑色**，按内置配色兜底 + 留一条痕迹 ----
	var bad = _make(cfg, "color_bad", {
		"factions": [
			{"id": "F1", "ai": "none", "color": "不是颜色"},
			{"id": "E1", "ai": "faction", "base": [18, 10], "color": "#e05a5a"},
		],
	}, ["F1"])
	ok(bad != null, "能造出「颜色写错」的世界")
	if bad != null:
		var cb: Color = bad.cfg.faction_color("F1", "main")
		ok(cb != Color.BLACK, "★ 写错的颜色**不会**变成黑色（那看起来像渲染坏了）")
		ok(cb != magenta, "★ 写错时按内置配色兜底（不再是品红）")
		ok(bad.cfg.has_faction_color("F1"), "兜底也是一次登记（所以 has 为 true）")
		# 另一方的正确颜色不受影响
		near(bad.cfg.faction_color("E1", "main").r, 0xe0 / 255.0, 0.01, "另一方照常解析")

	# ---- 内置阵营不受影响（老路径 / 固定关卡照旧走配色表）----
	var builtin: Color = w.cfg.faction_color("p1", "main")
	var builtin_enemy: Color = w.cfg.faction_color("enemy", "main")
	ok(builtin != magenta and builtin_enemy != magenta, "内置阵营的颜色仍然来自配色表")
	ok(builtin != builtin_enemy, "p1 与 enemy 本来就是两个颜色")

	# ---- 老路径（不做战役）：一个颜色都不登记，cfg 上不留痕 ----
	var legacy = WorldRes.create(cfg, "res://data/maps/frontier/map.json", false)
	ok(legacy != null, "老入口照样能建世界")
	if legacy != null:
		ok(not legacy.cfg.has_faction_color("F1"),
			"★ 老路径不登记任何关卡颜色（不做战役的世界不该被配色改动影响）")


func _roster_ids(w) -> Array:
	var out: Array = []
	for e in w.ai_roster_cfg:
		out.append(String((e as Dictionary)["id"]))
	return out


func _unit_positions(w, faction: String) -> Array:
	var out: Array = []
	for u in w.alive_units_of(faction):
		out.append([String(u.id), int(u.tx), int(u.ty)])
	out.sort()
	return out


func _moved_any(w, faction: String) -> bool:
	for u in w.alive_units_of(faction):
		if u.moving:
			return true
	return false


func _owner_of(w, zid: int) -> String:
	var z = w.zone_by_id(zid)
	if z == null:
		return "?"
	return String((z as Dictionary)["owner"])


func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var t := f.get_as_text()
	f.close()
	var v: Variant = JSON.parse_string(t)
	if typeof(v) != TYPE_DICTIONARY:
		return {}
	return v


func _write(path: String, text: String) -> void:
	var dir := path.get_base_dir()
	if dir != "":
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		ok(false, "能写临时文件：%s" % path)
		return
	f.store_string(text)
	f.close()


func _clean_tmp() -> void:
	if DirAccess.dir_exists_absolute(TMP_ROOT):
		_remove_dir(TMP_ROOT)


func _remove_dir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if d.current_is_dir():
			_remove_dir("%s/%s" % [path, n])
		else:
			DirAccess.remove_absolute("%s/%s" % [path, n])
		n = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)
