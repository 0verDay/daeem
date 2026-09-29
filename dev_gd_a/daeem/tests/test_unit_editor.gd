## test_unit_editor.gd —— 「单位编辑器」改的那些数值，游戏侧**真的会读**
##
## 背景：本轮新增了 `dev_gd_a/tools/unit_editor/`（一个改 data/config.json 的编辑器）。
## 编辑器本身有 600 项 Python 断言（tools/unit_editor/test_model.py + test_app.py），
## 但那些只证明「它写对了 JSON 的键」——**键对不对，得由读它的这一侧说了算**。
## 所以这个文件盯的是跨语言的那条缝：
##
##   一、config 契约：建筑定义 / 建造读条 / 可攻击 / 逐级攻击 / 单位图标
##   二、将领的**独立数值**（unit.general.stats）：三位将领互不干扰、没写的项跟随兵种
##   三、编辑器里「新建建筑」写出来的那一份数据，在游戏里能建、能打、名字来自 config
##   四、建造读条：读条期间不开火、读满就开火、开局自带的东西不等读条
##   五、建造页（HUD）读的是 config：加一栋楼，那一页立刻多一格
##   六、★★ 视野半径（本版新增）：兵种的 `unit.types.<id>.vision` 就是单位的视野，
##        将领的 `unit.general.stats[i].vision` 能单独覆盖 —— 编辑器里那两个输入框改的就是它们
##
## ⚠️ 每节都拿**自己那一份 cfg**（`require_config()` 每次都是新实例），
##    因为这一份文件里会往 cfg.data 里注入测试用的建筑 / 数值，
##    共用一个实例会让后面的断言看到前面改过的数据。
##
## ⚠️ 最后一节要真的把 main.tscn 挂进场景树（`_initialize()` 阶段 add_child 会静默失效），
##    所以这个文件走 test_ui / test_unit_types 那套 **async** 写法：自己打印汇总并 quit。
extends "res://tests/test_case.gd"

const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const BuildingRes = preload("res://logic/building.gd")
const CombatRes = preload("res://logic/combat.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const FactionRes = preload("res://logic/faction.gd")

const DT := 1.0 / 60.0

## 编辑器「新建建筑」写出来的那一份数据长这样（照 tools/unit_editor/model.py 的键表）。
## 放在这里当**契约样本**：游戏侧读不出它，就说明两边漂了。
const NEW_BUILDING := {
	"id": "outpost", "name": "前哨站", "hotkey": "K", "buildable": true,
	"build_sec": 1.0,
	"cost": {"food": 0, "gold": 0},
	"hp_max": 250,
	"body_scale": 0.6,
	"blocks_player": false, "blocks_enemy": false,
	"body_blocks_player": false, "body_blocks_enemy": true,
	"attackable": true, "damage": 20, "range": 3, "cooldown": 1.0,
	"color": "#888888", "desc": "测试用的新建筑",
}


func _initialize() -> void:
	_case_name = "test_unit_editor"
	_run()


func _run() -> void:
	_test_config_contract()
	_test_general_overrides()
	_test_vision()
	_test_new_building()
	_test_construction()
	# ★ 关键：先等一帧，root.add_child() 才会真的生效（见 pitfalls 1.2）
	await process_frame
	await _test_hud_build_page()

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 一、config 契约：建筑定义 / 攻击 / 图标
# ------------------------------------------------------------------

func _test_config_contract() -> void:
	var cfg = require_config()
	if cfg == null:
		return

	# ---- 建筑定义：config 优先于 building.gd 的 DEFS 兜底 ----
	ok(cfg.has_building_type("wall"), "wall 是 config 里定义的建筑")
	ok(cfg.has_building_type("tower"), "tower 是 config 里定义的建筑")
	ok(cfg.has_building_type("base"), "base 在 config 里（虽然不可建造）")
	ok(not cfg.has_building_type("zone_center"),
		"★ 区划中心**不是** config 里的建筑（它是中立障碍，编辑器不管它）")
	eq(cfg.building_type_ids(), ["wall", "tower", "base"],
		"建筑类型的顺序 = 文件里的顺序")
	eq(cfg.building_def("wall").get("name"), "城墙", "建筑定义读得到名字")
	eq(cfg.building_def("wall").get("buildable"), true, "城墙可建造")
	eq(cfg.building_def("base").get("buildable"), false, "★ 大本营不可建造")
	eq(cfg.building_def("wall", {"name": "兜底名"}).get("name"), "城墙",
		"★ config 里写了的键**盖掉**兜底（不是反过来）")
	eq(cfg.building_def("no_such_type", {"name": "兜底名"}).get("name"), "兜底名",
		"config 里没有的类型 → 用调用方给的兜底")

	var buildable: Array = cfg.buildable_building_defs()
	eq(buildable.size(), 2, "★ 建造页那两项：城墙 + 箭塔")
	eq(String(buildable[0].get("id", "")), "wall", "第一项是城墙")
	eq(String(buildable[1].get("id", "")), "tower", "第二项是箭塔")

	# ---- 造价 / 血量 / 建造读条 / 能不能攻击 ----
	eq(cfg.building_max_hp("wall"), 300.0, "城墙血量 300（从这里读）")
	eq(cfg.building_max_hp("base"), 1000.0, "大本营血量 1000")
	eq(cfg.building_build_sec("wall"), 0.0, "★ 城墙建造时间默认 0（瞬发，与从前一致）")
	eq(cfg.building_attackable("tower"), true, "箭塔可攻击")
	eq(cfg.building_attackable("wall"), false, "★ 城墙不可攻击（编辑器里那个勾没打）")

	# ---- 逐级攻击：没写就沿用基础值 ----
	var lv1: Dictionary = cfg.building_attack_of("tower", 1)
	near(float(lv1["damage"]), 12.0, 1e-6, "1 级箭塔伤害 = 基础值 12")
	near(float(lv1["range"]), 3.0, 1e-6, "1 级箭塔射程 = 3")
	near(float(lv1["cooldown"]), 0.8, 1e-6, "1 级箭塔间隔 = 0.8")
	# 给 2 级写一份自己的攻击数值（编辑器里「自定」那一栏写的就是这几个键）
	cfg.data["upgrade"]["levels"]["tower"][1]["damage"] = 30.0
	cfg.data["upgrade"]["levels"]["tower"][1]["range"] = 4.0
	# ⚠️ upgrade.levels 是**载入时缓存**的（config.gd 的 _cache_upgrades），
	#    所以这里要重新载入一次才看得到刚写进去的键 —— 与编辑器改完文件再开一局同理。
	var fresh = require_config()
	fresh.data["upgrade"]["levels"]["tower"][1]["damage"] = 30.0
	fresh.data["upgrade"]["levels"]["tower"][1]["range"] = 4.0
	var cfg2 = _reload(fresh)
	var lv2: Dictionary = cfg2.building_attack_of("tower", 2)
	near(float(lv2["damage"]), 30.0, 1e-6, "★★ 2 级自己写的伤害 30 生效")
	near(float(lv2["range"]), 4.0, 1e-6, "2 级自己写的射程 4 生效")
	near(float(lv2["cooldown"]), 0.8, 1e-6, "★ 2 级没写的间隔沿用基础值 0.8")
	near(float(cfg2.building_attack_of("tower", 1)["damage"]), 12.0, 1e-6,
		"★ 1 级不受影响（还是 12）")
	near(float(cfg2.building_attack_of("tower", 3)["damage"]), 12.0, 1e-6,
		"★ 3 级没写 → 沿用基础值")

	# ---- 地图上的那个字（unit.types.<id>.icon；编辑器里「地图上的字」那一栏）----
	eq(cfg.unit_icon_of("spearman"), "枪", "★ 地图上的字来自 config（枪）")
	eq(cfg.unit_icon_of("enemy"), "敌", "测试敌人也有自己的字")
	eq(cfg.unit_icon_of("no_such_type"), "单",
		"★ 认不出来的类型退成兜底名「单位」的第一个字（总有字可画）")
	eq(cfg.unit_icon_of("general"), "枪", "★ 将领（kind = general）用所属兵种那个字")
	eq(cfg.unit_icon_of("general_3"), "骑", "区划招募出来的 general_3 也是")
	var cfg3 = _reload(_mutated("unit", "types", "spearman", "icon", "矛"))
	eq(cfg3.unit_icon_of("spearman"), "矛", "★ 改了 config 的字 → 游戏读到的就变了")
	eq(cfg3.unit_icon_of("general"), "矛", "将领也跟着换（它用的是兵种的字）")
	# 手改配置写了两个字：只画第一个
	var cfg_wide = _reload(_mutated("unit", "types", "rider", "icon", "骑手"))
	eq(cfg_wide.unit_icon_of("rider"), "骑", "★ 手改写了两个字也只取第一个")
	# 没写这个键 → 名字的第一个字
	var cfg_noicon = require_config()
	cfg_noicon.data["unit"]["types"]["spearman"].erase("icon")
	eq(_reload(cfg_noicon).unit_icon_of("spearman"), "长",
		"★ 没写这个键 → 用名字的第一个字（长枪兵 → 长）")


## 把一份改过 data 的 cfg 的原始字典重新载入一遍（模拟「编辑器改完文件再开一局」）。
## ★ 为什么需要它：`_cache_*` 那一批是**载入时整理好**的（这是刻意的性能取舍），
##   所以「改了 data 里 upgrade.levels 的键」必须重新载入才生效 ——
##   只改**读的时候才查表**的那些键（building_def / build_sec / attackable / 单位图标）
##   不需要这一步。
func _reload(src) -> RefCounted:
	var cls = script_at("res://logic/config.gd")
	var cfg = cls.new()
	cfg.data = src.data
	cfg._cache_scalars()
	return cfg


func _mutated(path0: String, path1: String, path2: String, key: String, value) -> RefCounted:
	var cfg = require_config()
	cfg.data[path0][path1][path2][key] = value
	return cfg


## 一份带「将领数值覆盖」的配置（重新载入过，所以缓存也是新的）
func _with_general_stats(stats: Array) -> RefCounted:
	var cfg = require_config()
	cfg.data["unit"]["general"]["stats"] = stats
	return _reload(cfg)


## 直接在某个格子上摆一个测试敌人（**不走 spawn_enemy**）。
## ★ 为什么不用 spawn_enemy：它会做可达性检查、找不到就把人放到别处
##   （那时「敌人不在射程里」会让箭塔断言假失败）。这里要的是**确定性**：
##   我说它在 (x, y)，它就必须在 (x, y)。
func _place_enemy(w, cfg, tile: Vector2i):
	var e = UnitRes.create(cfg, "tester-%d-%d" % [tile.x, tile.y], "测试敌人", tile,
		FactionRes.NPC_FACTION, UnitRes.KIND_ENEMY)
	w.units.append(e)
	return e


## 把场上**别的**会攻击的建筑全拆掉，只留 `keep` 那一栋。
## ★ 为什么必须拆：地图上本来就有预置的箭塔（伤害 12），它们也会打这个敌人 ——
##   于是「敌人掉了多少血」分不清是谁打的（实测踩到：期望 20，实际抠掉 32）。
func _clear_other_attackers(w, cfg, keep) -> void:
	for b in w.building_list.duplicate():
		if b == keep:
			continue
		if b.is_attackable(cfg):
			w.remove_building(b, true)


# ------------------------------------------------------------------
# 二、将领的独立数值（unit.general.stats）
# ------------------------------------------------------------------

func _test_general_overrides() -> void:
	var cfg = require_config()
	if cfg == null:
		return

	# ---- 默认：完全跟随所属兵种（与加 stats 之前逐位一致）----
	eq(cfg.general_stat_overrides(0), {}, "★ 默认没有覆盖（stats[0] = {}）")
	near(cfg.general_hp_at(0), cfg.unit_hp_of("spearman"), 1e-6,
		"将领 1 的血量 = 长枪兵那一档")
	near(cfg.general_speed_at(2), cfg.unit_speed_of("rider"), 1e-6,
		"将领 3 的移速 = 骑手那一档")
	eq(cfg.general_name_at(0), "", "默认没有名字覆盖（调用方兜底「将领 N」）")
	var w0 = require_world(cfg)
	var g0 = w0.unit_by_id("general-1")
	ok(g0 != null, "开局将领在场")
	near(g0.hp_max, cfg.unit_hp_of("spearman"), 1e-6, "开局将领 1 的血量走兵种表")
	eq(g0.general_index, 0, "★ 单位自己知道是第几位将领")

	# ---- 写覆盖：三位将领互不干扰 ----
	# ⚠️ stats 是**载入时缓存**的（config.gd 的 _cache_unit_types），
	#    所以这里改完要重新载入一次才看得到 —— 与「编辑器改完文件再开一局」同理。
	var cfg4 = _reload(_with_general_stats([
		{"hp_max": 260, "name": "西境枪将"},
		{"hp_max": 300, "damage": 40},
		{},
	]))
	var w = require_world(cfg4)
	var g1 = w.unit_by_id("general-1")
	var g2 = w.unit_by_id("general-2")
	var g3 = w.unit_by_id("general-3")
	near(g1.hp_max, 260.0, 1e-6, "★★ 将领 1 用自己的血量 260")
	near(g2.hp_max, 300.0, 1e-6, "★★ 将领 2 用自己的血量 300（不是 260！）")
	near(g3.hp_max, cfg4.unit_hp_of("rider"), 1e-6,
		"★★ 将领 3 没写覆盖 → 跟随骑手（140）")
	near(g2.combat_damage(cfg4), 40.0, 1e-6, "将领 2 用自己的攻击力 40")
	near(g1.combat_damage(cfg4), cfg4.unit_combat_of("spearman")["damage"], 1e-6,
		"★ 将领 1 没写攻击力 → 跟随长枪兵（20）")
	near(g1.combat_range(cfg4), cfg4.unit_combat_of("spearman")["range"], 1e-6,
		"没写的项一律跟随")
	eq(g1.name, "西境枪将", "★ 将领名字覆盖生效（开局那三个的名字从这里来）")
	eq(g2.name, "将领 2", "没写名字 → 原来的「将领 N」")
	near(g1.speed(cfg4, w.map), cfg4.unit_speed_of("spearman"), 1e-6, "速度也能覆盖（这里没写）")
	near(cfg4.general_hp_at(1), 300.0, 1e-6, "查询口（悬停详情用）与单位身上的值一致")
	near(g1.hp, 260.0, 1e-6, "当前血量也跟着上限走（开局满血）")

	# ---- 附属兵**不吃**将领的覆盖（它们是兵，不是那一位将领）----
	var esc: Array = w.retinue_of(g1.id)
	ok(esc.size() > 0, "将领 1 带着附属兵")
	if esc.size() > 0:
		near(esc[0].hp_max, cfg4.unit_hp_of("spearman"), 1e-6,
			"★★ 附属兵的血量走**兵种**那一档（160），不是将领的 260")
		eq(esc[0].general_index, -1, "附属兵不是将领（序号 -1）")

	# ---- 护卫数（三位共用同一个数）----
	eq(cfg4.general_escort_count(), 3, "开局护卫数 3")
	cfg4.data["unit"]["general"]["escort"] = 5
	var cfg5 = _reload(cfg4)
	eq(cfg5.general_escort_count(), 5, "改成 5 立刻生效")


# ------------------------------------------------------------------
# 二·五、视野半径（`unit.types.<id>.vision` / `unit.general.stats[i].vision`）
#
# ★ 编辑器里那两个输入框改的就是这两个键，所以这里必须验到「**游戏侧真的读它**」：
#   `cfg.unit_vision_of()` 是对外的查询口，而 `unit.vision` 是出生那一刻抄进对象的值
#   （战争迷雾每帧只读后者，见 logic/fog.gd）。
# ⚠️ `unit.types` 与 `unit.general.stats` 都是**载入时缓存**的，
#    所以改了 data 必须 `_reload()` —— 与编辑器改完文件再开一局同一个道理。
# ------------------------------------------------------------------

func _test_vision() -> void:
	var cfg = require_config()
	if cfg == null:
		return

	# ---- 契约：四个兵种都有自己的视野 ----
	for t in ["spearman", "longbowman", "rider", "enemy"]:
		ok(cfg.unit_vision_of(t) > 0.0, "%s 的视野 > 0（编辑器里那一栏有数）" % t)
	ok(cfg.fog_vision_default > 0.0, "fog.vision_default > 0（没写 vision 的兜底）")
	ok(cfg.fog_vision_building > 0.0, "fog.vision_building > 0（建筑也给视野）")
	near(cfg.unit_vision_of("longbowman"), 10.0, 1e-6,
		"长弓兵视野 10（看得比长枪兵远 —— 这是 config 里写的那组数）")
	ok(cfg.unit_vision_of("longbowman") > cfg.unit_vision_of("spearman"),
		"★ 长弓兵视野 > 长枪兵（编辑器里改这两个数就能调）")

	# ---- 将领默认跟随所属兵种 ----
	eq(String(cfg.general_type_at(0)), "spearman", "（前提）将领 1 是长枪兵型")
	near(cfg.general_vision_at(0), cfg.unit_vision_of("spearman"), 1e-6,
		"★ 将领 1 没写覆盖 → 视野跟随长枪兵")
	near(cfg.general_vision_at(1), cfg.unit_vision_of("longbowman"), 1e-6,
		"★ 将领 2 跟随长弓兵（10）")

	# ---- 改了 unit.types 里的 vision → 重新载入之后生效 ----
	var cfg2 = _reload(_mutated("unit", "types", "rider", "vision", 3))
	near(cfg2.unit_vision_of("rider"), 3.0, 1e-6, "★ 改了兵种的 vision → 查询口读到新值")

	# ---- 出生时抄进单位身上（迷雾读的就是它）----
	var w = require_world(cfg2)
	var g3 = w.unit_by_id("general-3")
	ok(g3 != null, "（前提）将领 3 在场")
	if g3 != null:
		near(g3.vision, 3.0, 1e-6,
			"★★ 将领 3 的视野 = 骑手那一档（出生时从 config 抄到单位身上）")
	var g1 = w.unit_by_id("general-1")
	if g1 != null:
		near(g1.vision, cfg2.unit_vision_of("spearman"), 1e-6, "将领 1 的视野走长枪兵那一档")
		# 附属兵吃**兵种**那一档，不吃将领的覆盖（与血量同一条口径）
		var esc: Array = w.retinue_of(g1.id)
		ok(esc.size() > 0, "（前提）将领 1 带着附属兵")
		if esc.size() > 0:
			near(esc[0].vision, cfg2.unit_vision_of("spearman"), 1e-6,
				"附属兵的视野走兵种那一档")

	# ---- 将领单独覆盖视野 ----
	var cfg3 = _reload(_with_general_stats([{"vision": 20}, {}, {}]))
	near(cfg3.general_vision_at(0), 20.0, 1e-6, "★ 将领 1 单独覆盖视野 20")
	near(cfg3.general_vision_at(1), cfg3.unit_vision_of("longbowman"), 1e-6,
		"★ 将领 2 没写 → 仍然跟随长弓兵（10）")
	near(cfg3.unit_vision_of("spearman"), 8.0, 1e-6,
		"★ 覆盖只作用于那一位将领，不改兵种本身")
	var w2 = require_world(cfg3)
	var g1b = w2.unit_by_id("general-1")
	var g2b = w2.unit_by_id("general-2")
	if g1b != null:
		near(g1b.vision, 20.0, 1e-6, "★★ 开局将领 1 真的带着 20 格视野上场")
	if g2b != null:
		near(g2b.vision, cfg3.unit_vision_of("longbowman"), 1e-6,
			"★★ 将领 2 不受影响（还是 10）")

	# ---- 建筑（大本营 / 箭塔）也给视野，而且是**每个类型自己一个值** ----
	near(cfg3.building_vision(), cfg3.fog_vision_building, 1e-6,
		"`building_vision()` = fog.vision_building（没写 vision 的建筑用它兜底）")
	near(cfg3.building_vision_of("tower"), 12.0, 1e-6,
		"★★ 箭塔自己的视野 12（编辑器「建筑」页那一栏）")
	near(cfg3.building_vision_of("base"), 9.0, 1e-6, "大本营 9")
	near(cfg3.building_vision_of("wall"), 5.0, 1e-6, "城墙 5")
	# 改了 config 里那一栏 → 重新载入之后生效
	var cfg_b = require_config()
	if cfg_b.data.has("building") and cfg_b.data["building"].has("tower"):
		cfg_b.data["building"]["tower"]["vision"] = 3
	var cfg_b2 = _reload(cfg_b)
	near(cfg_b2.building_vision_of("tower"), 3.0, 1e-6,
		"★ 改了箭塔的 vision → 查询口读到新值")
	# 删掉那个键 → 退回 fog.vision_building
	var cfg_b3 = require_config()
	cfg_b3.data["building"]["tower"].erase("vision")
	near(_reload(cfg_b3).building_vision_of("tower"), cfg_b3.fog_vision_building, 1e-6,
		"★★ 没写 / 删掉 vision → 退回 fog.vision_building（编辑器里「清空」那一下）")

	# 出生时抄进建筑身上（迷雾读的就是它）
	var w3 = require_world(cfg3)
	var t3 = null
	for bb in w3.building_list:
		if bb.type == "tower" and bb.owner == FactionRes.DEFAULT_FACTION:
			t3 = bb
			break
	ok(t3 != null, "（前提）开局有己方箭塔")
	if t3 != null:
		near(t3.vision, 12.0, 1e-6,
			"★★ 箭塔身上带着自己那个视野（出生时从 config 抄到建筑身上）")
	var base3 = w3.find_base_of(FactionRes.DEFAULT_FACTION)
	if base3 != null:
		near(base3.vision, 9.0, 1e-6, "大本营身上带着 9")

	# ---- 迷雾侧真的按这些数算（与 tests/test_fog.gd 的分工：
	#      那边验「视野规则」，这里只验「编辑器改的那个数传到了迷雾手里」）----
	var base_b = w2.find_base_of(FactionRes.DEFAULT_FACTION)
	if base_b != null:
		ok(w2.fog.tile_visible(FactionRes.DEFAULT_FACTION, base_b.tx, base_b.ty),
			"★ 迷雾算过了：己方大本营那一格自己有视野")
		var own_units: Array = w2.alive_units_of(FactionRes.DEFAULT_FACTION)
		if own_units.size() > 0:
			var u = own_units[0]
			ok(w2.fog.tile_visible(FactionRes.DEFAULT_FACTION, u.tx, u.ty),
				"★ 自己人站的那一格一定有视野")


# ------------------------------------------------------------------
# 三、编辑器里「新建建筑」写出来的数据，游戏里能建、能打
# ------------------------------------------------------------------

func _test_new_building() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	cfg.data["building"]["outpost"] = NEW_BUILDING.duplicate(true)

	# ---- 契约 ----
	ok(cfg.has_building_type("outpost"), "★ 新建筑被认出来了")
	eq(cfg.building_type_ids().size(), 4, "建筑类型多了一种")
	eq(cfg.buildable_building_defs().size(), 3, "★ 建造页那一份列表也多了它")
	eq(cfg.building_max_hp("outpost"), 250.0, "血量来自 config")
	eq(cfg.building_build_sec("outpost"), 1.0, "建造时间来自 config")
	eq(cfg.building_attackable("outpost"), true, "可攻击")
	near(cfg.building_attack_of("outpost", 1)["damage"], 20.0, 1e-6, "攻击力来自 config")

	# ---- 世界里真的建得出来 ----
	var w = require_world(cfg)
	var base_b = w.find_base_of(FactionRes.DEFAULT_FACTION)
	ok(base_b != null, "（前提）有己方大本营")
	if base_b == null:
		return
	var tile: Vector2i = _free_tile_near(w, base_b.tx + 4, base_b.ty)
	ok(tile.x >= 0, "（前提）找得到一个空格")
	if tile.x < 0:
		return
	var b = w.add_building("outpost", tile.x, tile.y, FactionRes.DEFAULT_FACTION)
	ok(b != null, "★★ 编辑器里新加的建筑能真的建出来")
	if b == null:
		return
	eq(b.display_name(), "前哨站", "★★ 名字来自 config（不是代码里写死的）")
	near(b.hp_max, 250.0, 1e-6, "血量来自 config")
	ok(b.is_attackable(cfg), "★ 它算「会攻击的建筑」（判据是 config 的 attackable）")
	near(b.attack_damage(cfg), 20.0, 1e-6, "它的伤害走 config 的 20")
	near(b.attack_range(cfg), 3.0, 1e-6, "它的射程走 config 的 3")
	eq(b.def().get("body_scale"), 0.6, "本体大小也走 config")
	near(b.body_scale(cfg), 0.6, 1e-6, "body_scale 与配置一致")

	# ---- 阻挡语义也来自 config（新建筑默认「格子不封、本体挡敌方」）----
	ok(not b.blocks(FactionRes.DEFAULT_FACTION), "己方不被整格挡")
	ok(not b.blocks("p2"), "★ 它格子对敌方也不封（config 里 blocks_enemy = false）")
	ok(b.body_blocks("p2"), "★ 但本体挡敌方（body_blocks_enemy = true）")
	ok(not b.body_blocks(FactionRes.DEFAULT_FACTION), "本体不挡己方")

	# ---- 它会开火（直接调 update_towers，绕开 AI；别的塔先拆掉）----
	b.finish_construction()               # 先跳过建造读条（读条那一条在下一节单独验）
	_clear_other_attackers(w, cfg, b)
	var e = _place_enemy(w, cfg, Vector2i(tile.x + 2, tile.y))
	ok(e != null, "射程内放了一个测试敌人")
	ok(b.center().distance_to(e.pos) <= b.attack_range(cfg), "敌人确实在射程里")
	var hp0: float = e.hp
	CombatRes.update_towers(w, cfg, DT)
	eq(b.last_target, e, "★ 它锁定了这个敌人")
	near(e.hp, hp0 - 20.0, 1e-6, "★★ 新建筑开火，伤害 = config 的 20")

	# ---- 建造命令：只有「可建造」的类型能建 ----
	var tile2: Vector2i = _free_tile_near(w, base_b.tx - 4, base_b.ty + 2)
	if tile2.x >= 0:
		var cmd := {"kind": "build", "build_type": "outpost", "tx": tile2.x, "ty": tile2.y,
			"faction": FactionRes.DEFAULT_FACTION}
		ok(CommandRes.apply(w, cfg, cmd), "★ 建造命令认这个新类型")
		ok(w.building_at(tile2.x, tile2.y) != null, "那一格上真的多了一栋")
	var tile3: Vector2i = _free_tile_near(w, base_b.tx - 4, base_b.ty - 2)
	if tile3.x >= 0:
		var cmd2 := {"kind": "build", "build_type": "base", "tx": tile3.x, "ty": tile3.y,
			"faction": FactionRes.DEFAULT_FACTION}
		ok(not CommandRes.apply(w, cfg, cmd2),
			"★ 不可建造的类型（大本营）拒绝建造命令")
		ok(w.building_at(tile3.x, tile3.y) == null, "那一格上什么都没建出来")


func _free_tile_near(w, cx: int, cy: int) -> Vector2i:
	for r in range(0, 9):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				if absi(dx) != r and absi(dy) != r:
					continue                     # 只看这一圈的边长
				var t := Vector2i(cx + dx, cy + dy)
				if w.can_build_at(t.x, t.y):
					return t
	return Vector2i(-1, -1)


# ------------------------------------------------------------------
# 四、建造读条
# ------------------------------------------------------------------

func _test_construction() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	cfg.data["building"]["outpost"] = NEW_BUILDING.duplicate(true)

	var w = require_world(cfg)
	var base_b = w.find_base_of(FactionRes.DEFAULT_FACTION)
	var tile: Vector2i = _free_tile_near(w, base_b.tx + 4, base_b.ty)
	ok(tile.x >= 0, "（前提）找得到一个空格")
	if tile.x < 0:
		return
	var b = w.add_building("outpost", tile.x, tile.y, FactionRes.DEFAULT_FACTION)
	ok(b != null, "（前提）新建筑建好了")
	if b == null:
		return
	ok(b.is_under_construction(), "★ 建出来就在建造读条里（build_sec = 1）")
	near(b.build_progress(), 0.0, 1e-6, "刚开始：进度 0")
	near(b.build_eta(), 1.0, 1e-6, "剩余时间 = 整条 1 秒")

	# 读条期间：不开火（别的塔先拆掉，否则掉的血分不清是谁打的）
	_clear_other_attackers(w, cfg, b)
	var e = _place_enemy(w, cfg, Vector2i(tile.x + 2, tile.y))
	if e != null:
		var hp0: float = e.hp
		CombatRes.update_towers(w, cfg, DT)
		near(e.hp, hp0, 1e-6, "★★ 建造读条中不开火（还没有战斗力）")
		eq(b.last_target, null, "★ 它连目标都没锁（压根没进开火那一段）")
		# ⚠️ 这个靶子到此为止：接下来那一秒走的是**真的 world.tick**，
		#    友军单位会顺手把它打死 ——「造完之后开火」那一条要另放一个满血的。
		w.units.erase(e)

	# 走真实路径：world.tick 推进读条
	var events: Array = []
	for i in 30:
		events.append_array(w.tick(DT))
	ok(b.is_under_construction(), "0.5 秒之后还在造")
	near(b.build_progress(), 0.5, 0.06, "进度条走到一半左右")
	for i in 30:
		events.append_array(w.tick(DT))
	ok(not b.is_under_construction(), "★★ 1 秒之后造完了")
	near(b.build_progress(), 1.0, 1e-6, "造完之后进度 = 1")
	var ready := false
	for ev in events:
		if typeof(ev) == TYPE_DICTIONARY and String(ev.get("type", "")) == "building_ready":
			ready = true
	ok(ready, "★ 广播了 building_ready 事件（视图/日志要用）")

	# 造完之后就开火（重新放一个满血敌人：上面那个在那一秒里被友军打掉了）
	var e2 = _place_enemy(w, cfg, Vector2i(tile.x + 2, tile.y))
	if e2 != null:
		var hp1: float = e2.hp
		CombatRes.update_towers(w, cfg, DT)
		eq(b.last_target, e2, "★ 造完之后锁定敌人了")
		near(e2.hp, hp1 - 20.0, 1e-6, "★★ 造完之后就开火了")

	# 开局自带的东西**不等读条**（哪怕 config 里写了 build_sec）
	var cfg2 = require_config()
	cfg2.data["building"]["base"]["build_sec"] = 5.0
	cfg2.data["building"]["tower"]["build_sec"] = 5.0
	var w2 = require_world(cfg2)
	var b2 = w2.find_base_of(FactionRes.DEFAULT_FACTION)
	ok(b2 != null, "（前提）开局有己方大本营")
	if b2 != null:
		ok(not b2.is_under_construction(),
			"★★ 开局的大本营直接完工（instant，不等 5 秒）")
	# 而**玩家下达的建造**要等
	var tile2: Vector2i = _free_tile_near(w2, b2.tx + 4, b2.ty)
	if tile2.x >= 0:
		var t2 = w2.add_building("tower", tile2.x, tile2.y, FactionRes.DEFAULT_FACTION)
		if t2 != null:
			ok(t2.is_under_construction(), "★ 玩家建的箭塔要等（build_sec = 5）")


# ------------------------------------------------------------------
# 五、建造页（HUD）读的是 config
# ------------------------------------------------------------------

func _test_hud_build_page() -> void:
	var packed = load("res://view/main.tscn")
	if packed == null:
		ok(false, "main.tscn 能载入")
		return
	var root_node = (packed as PackedScene).instantiate()
	root.add_child(root_node)
	await process_frame
	root_node._on_test_pressed()          # 与玩家点一下 test 完全同一条路
	await process_frame
	await process_frame
	var main = root_node.game
	ok(main != null, "★ 按下 test 之后建出了游戏内场景")
	if main == null:
		root_node.queue_free()
		return

	main.input_ctrl.select_units([])      # 什么都没选中 → 建筑页
	main.hud.refresh()
	var card = main.hud.command_card
	eq(card.entries().size(), 2, "（前提）建造页默认两项：城墙 / 箭塔")
	eq(String(card.entry_at(0).get("build_type", "")), "wall", "第 1 项是城墙")
	eq(card.cell_label(0), "城墙", "名字来自 config")

	# ★★ 往配置里加一栋楼 —— 建造页立刻多一格（这就是「编辑器加建筑」那一整条路）
	main.cfg.data["building"]["outpost"] = NEW_BUILDING.duplicate(true)
	main.hud.rebuild_card()
	eq(card.entries().size(), 3, "★★ 编辑器里新加的建筑出现在建造页了")
	eq(String(card.entry_at(2).get("build_type", "")), "outpost", "第 3 格就是它")
	eq(card.cell_label(2), "前哨站", "★ 格子上是 config 里的名字")

	# 取消「可建造」→ 它从建造页消失（一个勾真的管用）
	main.cfg.data["building"]["outpost"]["buildable"] = false
	main.hud.rebuild_card()
	eq(card.entries().size(), 2, "★★ 取消「可建造」→ 它从建造页消失")

	# 改名 / 改说明也立刻反映在卡片上（名字来自 config）
	main.cfg.data["building"]["outpost"]["buildable"] = true
	main.cfg.data["building"]["outpost"]["name"] = "石头哨塔"
	main.hud.rebuild_card()
	eq(card.cell_label(2), "石头哨塔", "★ 改名之后卡片上的字跟着变")

	root_node.queue_free()
