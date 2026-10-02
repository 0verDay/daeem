## level.gd —— **一关**：「一张地图 + 一层覆盖」。
##
## ★★ 关卡文件（`data/campaigns/<id>/levels/<file>.json`）的形状 —— 与 dev_plan_7 第二节同一份：
##
##     {
##       "name": "第一关·渡口", "mode": "solo", "map": "dongzheng",
##       "players":  [{"faction": "F1", "base": [5, 4]}],
##       "factions": [{"id": "E1", "ai": "faction", "base": [18, 14], "resource_mult": 1.3,
##                     "attack_target": {"kind": "zone", "zone": 2},
##                     "faction_ai": {"generals": 2, "attack_repeat_sec": 12.0}}],
##       "allies":   [["E1", "E2"]]        ← 不写就用地图的
##       "zones":    [{"id": 4, "owner": "F1"}]   ← 开局的区块归属（覆盖地图的）
##       "start_units":     [{"faction": "E1", "kind": "enemy", "x": 11, "y": 4, "hold": true}],
##       "start_buildings": [{"type": "tower", "x": 5, "y": 3, "owner": "F1"}],
##       "objectives":      [{"kind": "hold_zone", "zone": 2, "hold_sec": 90}],
##       "fail_conditions": [{"kind": "zone_lost", "zone": 4}],
##       "briefing": []
##     }
##
## ★★ **覆盖规则**（这是本文件存在的主要理由：**唯一**的一处合并实现）：
##   · `players[].base` **覆盖**地图的 `faction_bases[那一方]`；
##   · `factions[].base` 同上；
##   · `allies` 写了就用关卡的，**一个字都没写**才用地图的；
##   · `zones[].owner` 覆盖地图 `zone_list[].owner` 的开局归属；
##   · `start_units` / `start_buildings` 是**追加**（地图的预置单位 / 建筑照旧先生效）。
##   ⚠️ 覆盖是**逐字段**的，不是「整块替换」——所以「关卡只改了大本营」不会把
##      地图的盟友关系一起抹掉。
##
## ★ 为什么关卡不把地图数据搬进来（1.3.3）：`data/maps/frontier/map.json` 里那套
##   对家据点与守军**是给手玩测试用的**，它必须继续有效（地图选择条 → 按 test 直接开一局）；
##   关卡是**在它之上的另一层**，不是它的替代品。
##
## ⚠️ 跨文件引用只用**本文件里的 preload 常量**（`--script` 下全局 class_name 不可用）。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")
const MapDataRes = preload("res://logic/map_data.gd")
const MapLibraryRes = preload("res://logic/map_library.gd")
const FactionRes = preload("res://logic/faction.gd")
const GridRes = preload("res://logic/grid.gd")

## 模式
const MODE_SOLO := "solo"
const MODE_COOP := "coop"

## 目标种类：第一版**只有**这一种（「守住指定区划 N 秒」，见 dev_plan_7 1.3.6）
const OBJ_HOLD_ZONE := "hold_zone"
## ★★ 「**攻占**指定区划」——一关两个可玩阵营各打各的时候，进攻方用这一条。
## 判胜是**立刻**的：目标区划的归属方翻成玩家同方的那一帧就赢（不要求再守 N 秒）。
const OBJ_CAPTURE_ZONE := "capture_zone"
## `objectives[].for` 的字段名（这一条目标是给哪个阵营的）。空 = 对任何玩家都成立。
const OBJ_FIELD_FOR := "for"

## 额外的失败条件种类：第一批**只有**这一种（大本营被拆那条是常开的，不写在数据里）
const FAIL_ZONE_LOST := "zone_lost"

## `factions[].ai` 的取值。
const AI_FACTION := "faction"
const AI_GENERAL := "general"
const AI_NONE := "none"

## `attack_target.kind` 的取值（见 dev_plan_7 2.4）。
const TARGET_ZONE := "zone"
const TARGET_POINT := "point"
const TARGET_BUILDING := "building"
const TARGET_BASE := "base"

## 校验级别：`block` = 拦（不许导出 / 不许开局）；`warn` = 只是提醒。
const SEV_BLOCK := "block"
const SEV_WARN := "warn"


## 读一份关卡 JSON 成 Level。
##
## @param campaign 所属战役（`Campaign`；只用来定位目录与拿默认模式，可以是 null）
## @param file     关卡文件，**相对战役目录**的路径（也可以给绝对 / res:// 路径）
## @return Level 或 **null**（文件读不出来 / 不是 JSON 对象 / 地图不存在 —— 都在这里收口）
##
## ⚠️ 地图**载入失败就整关失败**：没有地图，这个 Level 的绝大多数方法（校验 / 合并 / 目标）
##    都无从谈起。而「一张坏地图」不该让整个战役列表空掉 —— 那一层由 `Campaign` 负责
##    （跳过这一关，并把 id 记进 `load_error`）。
static func load_level(campaign, file: String, cfg: ConfigRes = null) -> RefCounted:
	var p := resolve_path(campaign, file)
	if p == "":
		return null
	var data: Variant = read_json(p)
	if typeof(data) != TYPE_DICTIONARY:
		push_error("关卡 JSON 不是合法对象：%s" % p)
		return null

	var lv = new()
	lv.cfg = cfg
	lv.path = p
	lv.id = p.get_file().get_basename()
	# ★★ 关卡**不持有战役对象**（见 `playable` 那段注释）：只把要用的东西**抄两份**
	#    —— 战役 id（给人看的）与「哪些阵营可玩」（判定要用的）。
	lv.campaign_id = String(campaign.id) if campaign != null else ""
	lv.playable = []
	lv.faction_colors = {}
	lv.faction_names = {}
	if campaign != null:
		for fid_p in campaign.playable_ids():
			lv.playable.append(String(fid_p))
		# ★★ 阵营**颜色**与**显示名**也在这里各抄一份（顺序：先战役、后关卡 ⇒ 关卡覆盖战役）。
		#    为什么不运行时再去问那个 Campaign 对象：`Level` 不持有它（引用环，
		#    见 `playable` 那段注释）。运行时要用的东西一律在载入时抄下来。
		for e_c in campaign.faction_meta:
			var cid := String((e_c as Dictionary).get("id", ""))
			var ccol := String((e_c as Dictionary).get("color", "")).strip_edges()
			if cid != "" and ccol != "":
				lv.faction_colors[cid] = ccol
			var cname := String((e_c as Dictionary).get("name", "")).strip_edges()
			if cid != "" and cname != "":
				lv.faction_names[cid] = cname
	lv.raw = data
	lv.map_id = String((data as Dictionary).get("map", "")).strip_edges()
	lv.name = _text((data as Dictionary).get("name", ""), lv.id)
	# 模式：缺省 = 战役的 default_mode（再缺省 solo）
	var fallback_mode := MODE_SOLO
	if campaign != null:
		fallback_mode = String(campaign.default_mode)
	lv.mode = _mode((data as Dictionary).get("mode", ""), fallback_mode)
	lv.players = _read_players((data as Dictionary).get("players", null))
	lv.faction_meta = _read_level_factions((data as Dictionary).get("factions", null))
	# ★ 关卡自己的 `factions[].color` / `.name` 覆盖战役那一份（与其它字段「关卡优先」一致）
	for e_l in lv.faction_meta:
		var lid := String((e_l as Dictionary).get("id", ""))
		var lcol := String((e_l as Dictionary).get("color", "")).strip_edges()
		if lid != "" and lcol != "":
			lv.faction_colors[lid] = lcol
		var lname := String((e_l as Dictionary).get("name", "")).strip_edges()
		if lid != "" and lname != "":
			lv.faction_names[lid] = lname
	lv.allies_declared = (data as Dictionary).has("allies")
	lv.allies = _read_allies((data as Dictionary).get("allies", null))
	lv.zone_owners = _read_zone_owners((data as Dictionary).get("zones", null))
	lv.start_units = _read_start_units((data as Dictionary).get("start_units", null))
	lv.start_buildings = _read_start_buildings((data as Dictionary).get("start_buildings", null))
	lv.objectives = _read_objectives((data as Dictionary).get("objectives", null))
	lv.fail_conditions = _read_fail_conditions((data as Dictionary).get("fail_conditions", null))
	lv.briefing = _read_strings((data as Dictionary).get("briefing", null))
	lv.issues = []

	# ---- 地图 ----
	lv.map = null
	lv.map_path = ""
	if lv.map_id != "":
		lv.map_path = "%s/%s" % [MapLibraryRes.MAPS_DIR, lv.map_id]
		var found := MapLibraryRes.find_map_file(lv.map_path, lv.map_id)
		if found != "":
			lv.map_path = found
			lv.map = MapDataRes.load_from(found, cfg)
	return lv


## 把「相对战役目录的 file」解析成真实路径；campaign 为 null 时按字面路径用。
static func resolve_path(campaign, file: String) -> String:
	var f := file.strip_edges()
	if f == "":
		return ""
	if f.begins_with("res://") or f.begins_with("/") or f.contains(":/"):
		return f
	if campaign == null:
		return f
	return "%s/%s" % [String(campaign.dir_path), f]


# ------------------------------------------------------------------
# 实例：一份关卡的视图（全部字段都有确定的默认值）
# ------------------------------------------------------------------

## 关卡 id（= 文件名去扩展名；campaign.json 的 levels[].id 会覆盖它）
var id: String = ""
## 显示名（缺省 = id）
var name: String = ""
## "solo" / "coop"：决定 players[] 允许几个席位
var mode: String = MODE_SOLO
## 全局配置（`logic/config.gd`；`load_level` 时记下来 —— `merge_over_map` 要重新载入地图）
var cfg = null
## 关卡文件路径
var path: String = ""
## 地图 id（= `data/maps/<map_id>/` 的目录名）
var map_id: String = ""
## 地图 JSON 的路径（**空串 = 地图不存在**，这是校验第 1 条要拦的）
var map_path: String = ""
## 载入好的地图（MapDataRes；地图不存在时是 null）
var map = null
## 关卡 JSON 的原始字典（编辑器往返 / 排查用）
var raw: Dictionary = {}

## 玩家席位：每项 {faction: String, base: Vector2i(-1,-1) 表示没写}
## ★★ **顺序 = 席位顺序**（房主第 1 个、客机第 2 个）——见 dev_plan_7 拍板第 18 项。
var players: Array = []
## 参展阵营的 AI 指派 / 难度 / 开局资源 / 大本营 / 进攻目标。每项见 `faction_config()`。
var faction_meta: Array = []
## 盟友关系是不是**关卡显式写了**（决定用关卡还是用地图的）
var allies_declared: bool = false
## 盟友关系（关卡写了就是它；没写时这里仍是空数组，合并时才回落到地图的）
var allies: Array = []
## 开局的区块归属覆盖：区划 id → 阵营 id
var zone_owners: Dictionary = {}
## 开局就在场的单位（**追加**在地图 `units` 之后）
var start_units: Array = []
## 开局就在场的建筑（**追加**在地图 `buildings` 之后）
var start_buildings: Array = []
## 目标：**恰好 1 项**（`[{kind: "hold_zone", zone: n, hold_sec: t}]`）
var objectives: Array = []
## **额外的**失败条件（大本营被拆那条是常开的，不在这里）
var fail_conditions: Array = []
## 简报（第一版运行时一个字都不读，留给以后）
var briefing: Array = []
## 校验结果：每项 {sev: "block"/"warn", code: String, msg: String}
var issues: Array = []
## ★ 「可玩」的显式覆盖（空 = 走下面那份 `playable`）。
## 给测试与工具用：伪造一份「这一战有两个可玩阵营」来验校验第 7 条。
var playable_override: Array = []
## ★★ 这一战里**可玩**的阵营 id（从 `campaign.json` 的 `factions[].playable` 抄来的）。
##
## ⚠️⚠️ 为什么是**抄一份**而不是持有那个 `Campaign` 对象（这一条是实测踩出来的）：
##   `Campaign` 里有 `levels[]`、`Level` 又指回 `Campaign` —— 那是一个**引用环**，
##   而 Godot 4 的 `RefCounted` 环**永远不会被回收**：每建一局战役就在退出时报一堆
##   `ObjectDB instances were leaked`（实测 25 个/局，而老路径是 0）。
##   这里要用到的只有「哪几方可以玩」这一个列表，抄成字符串数组就没有环了。
var playable: Array = []
## 这一关属于哪个战役（**字符串**，不是对象引用 —— 理由同上）。
var campaign_id: String = ""
## ★★ 这一关各阵营的颜色："faction" → "#rrggbb"（**载入时抄下来的**）。
##
## 来源两处、关卡优先：`campaign.json` 的 `factions[].color` → 关卡 `factions[].color`。
##
## ⚠️ 为什么值得单独存一份：配色表 `colors.faction.*` 里只有**内置** id（p1~p8/enemy/ai），
##   而战役用的是自己的 id —— 颜色没登记的话渲染层会退到**品红**
##   （症状：「整个战场一片紫、敌我分不清」，玩家实测报过）。
##   运行时的登记在 `world._register_level_colors()`，数据来源就是这一份。
var faction_colors: Dictionary = {}
## ★★ 这一关各阵营的**显示名**："faction" → "蓝方"（**载入时抄下来的**，理由同颜色）。
##
## 来源两处、关卡优先：`campaign.json` 的 `factions[].name` → 关卡 `factions[].name`。
## ⚠️ 为什么也要抄一份：`Level` **不持有 `Campaign` 对象**（避引用环，见上面那段），
##   而关卡页要在按钮上写「蓝方 / 红方」而不是 `F1` / `F2` —— 运行时要用的东西
##   一律在载入时抄下来（与 `playable` / `faction_colors` 同一条规矩）。
var faction_names: Dictionary = {}


## 这一关的玩家席位（faction id 数组，按席位顺序）。
func seats() -> Array:
	var out: Array = []
	for p in players:
		out.append(String((p as Dictionary)["faction"]))
	return out


## 席位数量。
func seat_count() -> int:
	return players.size()


## ★★ 运行时的**出场名单**：到底哪几方在这一局里。
##
## = 玩家席位 + 参展阵营里写了 `ai != none` 的那些（**顺序稳定、去重**）。
##
## ⚠️ 与 `config.ai.factions` 的关系：那个是**全局兜底**（关卡没写 ai 的阵营照旧吃它）。
##    本函数只管「关卡显式写了什么」；全局那一份由 `world` 在装配时合并进来。
func rosters() -> Array:
	var out: Array = []
	for p in players:
		var f := String((p as Dictionary)["faction"])
		if f != "" and not out.has(f):
			out.append(f)
	for e in faction_meta:
		var fid := String((e as Dictionary)["id"])
		if fid == "" or out.has(fid):
			continue
		if String((e as Dictionary).get("ai", AI_NONE)) != AI_NONE:
			out.append(fid)
	return out


## 这一方在这一关里的参展配置（没写就返回一个「全都是缺省」的字典）。
##
## 返回 {id, ai, base: Vector2i(-1,-1), resource_mult, start_food, start_gold,
##       attack_target: Variant, faction_ai: Variant, general_ai: Variant, declared: bool}
func faction_config(fid: String) -> Dictionary:
	for e in faction_meta:
		if String((e as Dictionary)["id"]) == fid:
			var d: Dictionary = (e as Dictionary).duplicate(true)
			d["declared"] = true
			return d
	return {
		"id": fid, "ai": AI_NONE, "base": Vector2i(-1, -1), "resource_mult": 1.0,
		"start_food": 0.0, "start_gold": 0.0, "attack_target": null,
		"faction_ai": null, "general_ai": null, "declared": false,
	}


## 这一方的 `attack_target` 原始配置（没写 → null；写了 `kind` 不认识 → null）。
func attack_target_of(fid: String) -> Variant:
	for e in faction_meta:
		if String((e as Dictionary)["id"]) == fid:
			return (e as Dictionary).get("attack_target", null)
	return null


## 这一方在这一关的数据里是不是「可玩」的（= 在 `campaign.json` 的 `playable: true` 里）。
##
## ★ 可玩是**战役级**的属性（「这一战你可以选谁」），不是关卡级的 ——
##   载入时已经把那份列表抄进 `playable`（见那个字段的注释：不持有战役对象是为了断引用环）。
func is_playable(fid: String) -> bool:
	return playable.has(fid)


## 这一关**可以选来玩**的阵营（= 可玩 ∩ 本关真的在场）。
##
## ★ 「可玩」是**战役级**属性（`campaign.json` 的 `factions[].playable`）；
##   `playable_override` 是给测试 / 工具用的显式覆盖（空 = 走战役那一份）。
func playable_ids() -> Array:
	var out: Array = []
	var present := present_ids()
	if not playable_override.is_empty():
		for fid in playable_override:
			if present.has(String(fid)):
				out.append(String(fid))
		return out
	# ★ 扫的是**本关在场的全部阵营**（席位 + 关卡 factions[] + 地图 factions），
	#   而不是只扫关卡自己声明过的那几个 —— 可玩是**战役级**属性，
	#   一个只在地图里划过、关卡一个字都没提的阵营照样可以是可玩的。
	for fid2 in present:
		if is_playable(String(fid2)):
			out.append(String(fid2))
	return out


## 这一关**在场**的阵营 id（席位 + 参展阵营 + 地图 factions ∪ 关卡 factions）。
func present_ids() -> Array:
	var out: Array = []
	for f in seats():
		if not out.has(f):
			out.append(f)
	for e in _meta_ids():
		if not out.has(String(e)):
			out.append(String(e))
	if map != null:
		for m in map.factions_meta:
			if typeof(m) != TYPE_DICTIONARY:
				continue
			var fid := String((m as Dictionary).get("id", ""))
			if fid != "" and not out.has(fid):
				out.append(fid)
	return out


## 目标区划号（没有目标 / 不是守区划类 → -1）。
##
## ⚠️ 这是**向后兼容**的那一份：取 `objectives[0]`。
##    一关只有一条目标时（老数据 / 绝大多数关卡）它就是那一份，行为逐位不变。
##    ★ 一关有**两条**（选边关卡）时请用 `objective_for(fid)` 取属于某一方的那一条。
func objective_zone() -> int:
	if objectives.is_empty():
		return -1
	return int((objectives[0] as Dictionary).get("zone", -1))


## ★★ 属于 `fid` 的那一条目标（一关两个可玩阵营各打各的时候用）。
##
## 口径（顺序不能反）：
##   1. `objectives[].for` **正好等于** `fid` 的那一条 → 就是它；
##   2. 没有点名 `fid` 的，就找 `for` **为空**的那一条（= 对任何玩家都成立）；
##   3. 都没有 → `null`（**不退回「第一条」**：那样红方会拿到蓝方的目标）。
##
## @param fid 玩家席位（空串 = 只要「通用」那一条）
## @return Dictionary 或 null
func objective_for(fid: String) -> Variant:
	var generic: Variant = null
	for item in objectives:
		var d: Dictionary = item
		var who := String(d.get(OBJ_FIELD_FOR, ""))
		if who != "" and who == fid:
			return d
		if who == "" and generic == null:
			generic = d
	return generic


## `objective_for()` 的显示版：没有目标时给一份「空目标」（字段齐全，便于读）。
func objective_of(fid: String) -> Dictionary:
	var o: Variant = objective_for(fid)
	if o == null:
		return {"kind": "", "zone": -1, "hold_sec": 0.0, OBJ_FIELD_FOR: ""}
	return o


## 这一关有没有**按阵营分开**的目标（= 存在带 `for` 的目标）。
func has_per_faction_objectives() -> bool:
	for item in objectives:
		if String((item as Dictionary).get(OBJ_FIELD_FOR, "")) != "":
			return true
	return false


## 目标要守住的秒数（没有目标 → 0）
func objective_hold_sec() -> float:
	if objectives.is_empty():
		return 0.0
	return float((objectives[0] as Dictionary).get("hold_sec", 0.0))


## 这一关的目标用一句人话怎么说（界面 / 编辑器列表都要它，所以写在数据这一层）。
##
## @param fid 取**属于这一方**的目标（空串 = 第一条 / 通用那一条；老调用不受影响）
func objective_label(fid: String = "") -> String:
	var o: Dictionary = objective_of(fid) if fid != "" else (
		objectives[0] if not objectives.is_empty() else {})
	if o.is_empty():
		return "（没有目标）"
	var z := int(o.get("zone", -1))
	var kind := String(o.get("kind", ""))
	if kind == OBJ_CAPTURE_ZONE:
		return "占领 %s" % _zone_label(z)
	return "守住 %s %s 秒" % [_zone_label(z), _fmt_sec(float(o.get("hold_sec", 0.0)))]


## 关卡列表上那一行：模式 + 目标
func summary() -> String:
	return "%s · %s" % ["双人合作" if mode == MODE_COOP else "单人", objective_label()]


# ------------------------------------------------------------------
# 与地图的合并（**唯一**的一处覆盖实现）
# ------------------------------------------------------------------

## ★★ 把这一关的覆盖层合并到**一张新的地图对象**上，并返回它。
##
## 做四件事（顺序不是关键，但「谁覆盖谁」是）：
##   1. `players[].base` + `factions[].base` → `faction_bases`（**覆盖**地图的）；
##   2. `factions[]` 里**地图没写过**的阵营 → 追加进 `factions_meta`（编辑器 / 界面要显示它）；
##   3. `zones[].owner` → `zones_owners`（覆盖地图的开局归属）；
##   4. 返回合并后的 AI 名单（见 `merged_ai_factions`）挂在 `map` 对象上 ——
##      调用方从 `map._level_ai_roster` 拿不到，所以本函数**同时**把它当作返回值的一部分。
##
## ★★ 为什么返回**新对象**而不是就地改 `map`（这一条想清楚了再改）：
##   · `check()`（校验）必须在**原始**数据上跑 —— 否则同一个 Level 调两次
##     `merge_over_map()` 之后，第 8 条「目标区划开局归属」会看到被自己改写过的值，
##     校验结果变得依赖调用顺序（这类不确定性最难查）；
##   · 地图是**每局新载入一次**的，就地改其实也不会串局 —— 但「读操作会改数据」
##     是早晚要出事的那种设计。
##   代价是每关多一次 Grid 复制（`cols × rows` 两个字节数组），可忽略。
##
## @param config_ai `cfg.ai_factions()`（全局兜底那一份；关卡写了 ai 的阵营**优先**）
## @return Dictionary `{"map": MapData, "ai": Array[Dictionary]}`：
##         `map` 是合并后的地图；`ai` 是合并后的 AI 名单（每项见 `merged_ai_factions`）。
func merge_over_map(config_ai: Array = []) -> Dictionary:
	if map == null:
		return {"map": null, "ai": merged_ai_factions(config_ai)}
	var m = MapDataRes.load_from(String(map_path), cfg)
	if m == null:
		# 理论上到不了这里（load_level 已经载过一次）；兜底用原对象，别让开局整个失败。
		m = map

	# 1) 大本营（关卡写的覆盖地图的）
	for p in players:
		var fid := String((p as Dictionary)["faction"])
		var b: Vector2i = (p as Dictionary)["base"]
		if fid != "" and b.x >= 0 and b.y >= 0:
			m.set_faction_base(fid, b)
	for e in faction_meta:
		var fid2 := String((e as Dictionary)["id"])
		var b2: Vector2i = (e as Dictionary)["base"]
		if fid2 == "":
			continue
		if b2.x >= 0 and b2.y >= 0:
			m.set_faction_base(fid2, b2)
		# 2) 地图没写过的阵营 → 追加进阵营表（界面要显示它）
		if not _map_has_faction(fid2):
			m.factions_meta.append({
				"id": fid2,
				"name": _text((e as Dictionary).get("name", ""), fid2),
				"color": String((e as Dictionary).get("color", "")),
			})

	# 3) 开局的区块归属
	for zid in zone_owners.keys():
		m.zones_owners[zid] = String(zone_owners[zid])

	return {"map": m, "ai": merged_ai_factions(config_ai)}


## ★★ 合并后的 AI 名单：**关卡显式写了 `ai` 的阵营优先**，其余照旧吃 `cfg.ai_factions()`。
##
## @param config_ai `cfg.ai_factions()`（每项 {id, base, resource_mult, start_food, start_gold}）
##
## ★ 四项口径（都与 dev_plan_7 3.6 的迁移口径一致）：
##   1. 关卡没写 `ai` 的阵营：**照旧**用 config 那一套 ⇒「不做战役、直接按 test 开一局」
##      的行为逐位不变；
##   2. 关卡写了 `ai: "none"` 的阵营：**不进**这张表（明确关掉 AI，哪怕 config 里有它）；
##   3. 关卡写 `ai: "general"` 的阵营：进表但 `ai == "general"` ⇒ 不建阵营 AI
##      （那一方靠单位上的**将领性 AI** 驱动，见 `logic/general_ai.gd`）；
##   4. ★ `source` 字段标出这一条是哪来的（"level" / "map" / "config"）——
##      `world` 靠它决定「这一方要不要进这一局的名单」（见 `world._merged_ai_roster`）。
##      没有它的话，「关卡只点名了 E1，config 里的另一个 AI 阵营要不要一起进场」
##      就说不清楚了。
func merged_ai_factions(config_ai: Array = []) -> Array:
	var out: Array = []
	var seen: Dictionary = {}

	# 1) 关卡显式写了 ai 的：以关卡为准
	for e in faction_meta:
		var fid := String((e as Dictionary)["id"])
		var ai := String((e as Dictionary).get("ai", AI_NONE))
		if fid == "":
			continue
		if ai == AI_NONE:
			# ★★ 「关卡显式写了 ai: none」= 这一方这一局**就是不动** ——
			#    哪怕全局 `config.ai.factions` 里有它，也**不许**被那一份接管。
			#    ⚠️ 这里必须**记进 `seen`**：漏了这一步，第 3 段会把它当成
			#    「关卡没写的阵营」再从 config 捞回来，`ai: none` 就静默失效了
			#    （实测踩到：关卡写了 none，跑起来照样是阵营 AI）。
			seen[fid] = true
			continue
		seen[fid] = true
		var base: Vector2i = (e as Dictionary)["base"]
		if base.x < 0 or base.y < 0:
			base = _map_base(fid)
		out.append({
			"id": fid,
			"ai": ai,
			"base": base,
			"resource_mult": float((e as Dictionary).get("resource_mult", 1.0)),
			"start_food": float((e as Dictionary).get("start_food", 0.0)),
			"start_gold": float((e as Dictionary).get("start_gold", 0.0)),
			"attack_target": (e as Dictionary).get("attack_target", null),
			"faction_ai": (e as Dictionary).get("faction_ai", null),
			"general_ai": (e as Dictionary).get("general_ai", null),
			"from_level": true,
			"source": "level",
		})

	# 2) 地图自己划过的阵营（`factions_meta`）：它们是**这一局布局的一部分**，必须留。
	for m in (map.factions_meta if map != null else []):
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var mid := String((m as Dictionary).get("id", ""))
		if mid == "" or seen.has(mid):
			continue
		seen[mid] = true
		out.append({
			"id": mid,
			"ai": AI_NONE,
			"base": _map_base(mid),
			"resource_mult": 1.0, "start_food": 0.0, "start_gold": 0.0,
			"attack_target": null, "faction_ai": null, "general_ai": null,
			"from_level": false,
			"source": "map",
		})

	# 3) 其余照旧吃全局配置（关卡没写 ai 的阵营 —— 向后兼容那一条）
	for item in config_ai:
		var ce: Dictionary = item
		var cid := String(ce.get("id", ""))
		if cid == "" or seen.has(cid):
			continue
		seen[cid] = true
		out.append({
			"id": cid,
			"ai": AI_FACTION,
			"base": ce.get("base", Vector2i(-1, -1)),
			"resource_mult": float(ce.get("resource_mult", 1.0)),
			"start_food": float(ce.get("start_food", 0.0)),
			"start_gold": float(ce.get("start_gold", 0.0)),
			"attack_target": null,
			"faction_ai": null,
			"general_ai": null,
			"from_level": false,
			"source": "config",
		})
	return out


## 这一关合并之后到底给哪几方挂阵营 AI（= 名单里 `ai == "faction"` 的那些）。
func faction_ai_ids(config_ai: Array = []) -> Array:
	var out: Array = []
	for e in merged_ai_factions(config_ai):
		if String((e as Dictionary)["ai"]) == AI_FACTION:
			out.append(String((e as Dictionary)["id"]))
	return out


## `allies` 的最终取值：关卡写了就用关卡的，**一个字都没写**才用地图的。
func effective_allies() -> Array:
	if allies_declared:
		return allies
	if map != null:
		return map.allies
	return []


# ------------------------------------------------------------------
# 校验（编辑器**硬拦截**清单的模型侧；运行时开局前也过一遍兜底）
# ------------------------------------------------------------------

## 逐条跑 dev_plan_7 2.5 那张表，返回问题数组（每项 {sev, code, msg}）。
##
## ★★ 为什么校验放在数据层而不是界面层：**校验逻辑只有一份** ——
##   编辑器导出前跑它，运行时开局前也跑它（`block` 的那些会让这一局直接判负并留痕迹）。
##   界面只是它的一个消费者（把 msg 显示出来）。
##
## @param config_ai `cfg.ai_factions()`（全局兜底；不传就只按关卡自己的数据校验）
func check(config_ai: Array = []) -> Array:
	issues = []
	_ck_map_exists()
	_ck_players(config_ai)
	_ck_allies()
	_ck_objectives()
	_ck_ai_assign(config_ai)
	_ck_start_units()
	_ck_level_factions()
	return issues


## 只有 `block` 的那些（编辑器「通过才允许写文件」用的就是它）。
func blockers() -> Array:
	var out: Array = []
	for i in issues:
		if String((i as Dictionary)["sev"]) == SEV_BLOCK:
			out.append(i)
	return out


func warnings() -> Array:
	var out: Array = []
	for i in issues:
		if String((i as Dictionary)["sev"]) == SEV_WARN:
			out.append(i)
	return out


func has_blocker() -> bool:
	for i in issues:
		if String((i as Dictionary)["sev"]) == SEV_BLOCK:
			return true
	return false


# ---- 逐条检查 ----

## 1) `map` 在 `data/maps/` 里真的存在
func _ck_map_exists() -> void:
	if map_id == "":
		_add(SEV_BLOCK, "map_missing_field", "没有写 map：这一关没有地图")
		return
	if map == null:
		_add(SEV_BLOCK, "map_not_found", "地图「%s」不存在（找不到 %s/map.json）" % [map_id, map_id])
		return
	# 6) 大本营不能落在不可通行的格子上 —— 这一条要地图，所以挂在这里
	_ck_base_walkable()


## 2/3/4) 席位数、玩家不能占同一阵营、每个非玩家方都要有大本营
func _ck_players(config_ai: Array = []) -> void:
	if players.is_empty():
		_add(SEV_BLOCK, "players_empty", "一关至少要有一个玩家席位")
	if mode == MODE_SOLO and players.size() != 1:
		_add(SEV_BLOCK, "players_count_solo",
			"单人关只能有一个玩家席位（现在是 %d 个）" % players.size())
	if mode == MODE_COOP and players.size() != 2:
		_add(SEV_BLOCK, "players_count_coop",
			"合作关必须有恰好两个玩家席位（现在是 %d 个）" % players.size())
	var seen: Dictionary = {}
	var seat_ids: Dictionary = {}
	for p in players:
		var fid := String((p as Dictionary)["faction"])
		if fid == "":
			_add(SEV_BLOCK, "player_no_faction", "有玩家席位没写 faction")
			continue
		if seat_ids.has(fid):
			_add(SEV_BLOCK, "players_same_faction", "两个玩家不能占同一阵营（%s）" % fid)
		seat_ids[fid] = true
		seen[fid] = true

	# ★★ 4) 每个**会出场的非玩家方**都要有大本营。
	#
	# ⚠️ 这里判的是「这一关会出场的每一方」，所以名单是**三处的并集**：
	#    · 关卡 `factions[]`（关卡点名的）；
	#    · 地图 `factions_meta`（地图上划过的阵营，它也会有基地）；
	#    · 全局 `config.ai.factions`（关卡没写 ai 的照旧吃它 —— 向后兼容那一条）。
	#    少算任何一处都会漏掉一类「没有大本营 → 落到 (0,0) 顶掉区块中心」的坑
	#    （route.md 33.5 坑①，已实测）。
	#
	# ⚠️⚠️ **`ai: "none"` 也要大本营**（这一条是实测补上的）：
	#    `ai: none` 的语义是「这一方这一局**不动**」，不是「这一方不存在」——
	#    它照样会被建出大本营（`world` 会给名单里每一方建一座）。
	#    漏拦它的后果与「非玩家方没有大本营」完全一样：点位落到 (0,0)，
	#    把区块中心那栋中立建筑顶掉（route.md 33.5 坑①）。
	#    ★ 关卡用 `ai: none` 关掉一个**全局 config 阵营**时，随便给它一个空地
	#      （或者干脆把它从 config 里删掉）—— 校验会挡住「只写 id 不给点位」。
	var ai_list := _effective_ai_list(config_ai)
	for item in ai_list:
		var it: Dictionary = item
		var fid2 := String(it.get("id", ""))
		if fid2 == "" or seen.has(fid2):
			continue                        # 玩家席位不要求大本营（它从 players[].base 来）
		if bool(it.get("exempt_base", false)):
			continue                        # 地图划过、但**这一局不会给它建基地**的阵营
		var base: Vector2i = it.get("base", Vector2i(-1, -1))
		if base.x < 0 or base.y < 0:
			_add(SEV_BLOCK, "faction_no_base",
				"阵营「%s」没有大本营：会落到 (0,0) 顶掉区块中心" % fid2)


## 这一关**会出场的每一方** + 它的大本营（三处并集，见 `_ck_players` 的说明）。
## 每项 {id: String, ai: String, base: Vector2i, exempt_base: bool}。
func _effective_ai_list(config_ai: Array = []) -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	# 1) 关卡 `factions[]`（关卡点名的：**一律要求大本营**，见 `_ck_players`）
	for e in faction_meta:
		var fid := String((e as Dictionary)["id"])
		if fid == "" or seen.has(fid):
			continue
		seen[fid] = true
		var b: Vector2i = (e as Dictionary)["base"]
		if b.x < 0 or b.y < 0:
			b = _map_base(fid)
		out.append({"id": fid, "ai": String((e as Dictionary).get("ai", AI_NONE)),
			"base": b, "exempt_base": false})
	# 2) 地图 factions_meta（地图划过的阵营）
	#
	# ⚠️ 这一档**不强制**要求大本营：地图上的阵营表是**元信息**（给选择条 / 颜色看的），
	#    地图不一定会给每一方都划基地（比如样例地图只划了 F1 / E1）。
	#    而「没有大本营 → 落到 (0,0)」这条坑只在**这一局真的会给它建基地**时才发生 ——
	#    也就是「它进了 `world.factions`」的时候（关卡点名的、或 config 里的 AI 阵营）。
	#    所以这里只把它们**列出来**（供校验第 13 条用），不当作必须有点位的那一档。
	if map != null:
		for m in map.factions_meta:
			if typeof(m) != TYPE_DICTIONARY:
				continue
			var fid2 := String((m as Dictionary).get("id", ""))
			if fid2 == "" or seen.has(fid2):
				continue
			seen[fid2] = true
			out.append({"id": fid2, "ai": AI_NONE, "base": _map_base(fid2), "exempt_base": true})
	# 3) 全局 config.ai.factions（关卡没写 ai 的照旧吃它 —— 它们在**老路径**上会被建基地）
	for item in config_ai:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var it: Dictionary = item
		var fid3 := String(it.get("id", ""))
		if fid3 == "" or seen.has(fid3):
			continue
		seen[fid3] = true
		var b3: Vector2i = _map_base(fid3)
		if b3.x < 0:
			b3 = it.get("base", Vector2i(-1, -1))
		out.append({"id": fid3, "ai": AI_FACTION, "base": b3, "exempt_base": false})
	return out


## 6) 大本营 / 起点不能在不可通行处（山地 / 地图外）
func _ck_base_walkable() -> void:
	if map == null:
		return
	for p in players:
		_ck_point_walkable((p as Dictionary)["base"], "玩家「%s」的大本营" % String((p as Dictionary)["faction"]))
	for e in faction_meta:
		_ck_point_walkable((e as Dictionary)["base"], "阵营「%s」的大本营" % String((e as Dictionary)["id"]))
	for u in start_units:
		var t := Vector2i(int((u as Dictionary)["x"]), int((u as Dictionary)["y"]))
		_ck_point_walkable(t, "摆放单位 (%d,%d)" % [t.x, t.y])
	for b in start_buildings:
		var t2 := Vector2i(int((b as Dictionary)["x"]), int((b as Dictionary)["y"]))
		_ck_point_walkable(t2, "摆放建筑 (%d,%d)" % [t2.x, t2.y])


func _ck_point_walkable(t: Vector2i, what: String) -> void:
	if t.x < 0 or t.y < 0:
		return                              # 没写 —— 由「必须有大本营」那条管
	if map == null:
		return
	if not map.tile_exists(t.x, t.y):
		_add(SEV_BLOCK, "point_outside", "%s (%d,%d) 在地图外" % [what, t.x, t.y])
		return
	if not map.terrain_walkable(t.x, t.y):
		_add(SEV_BLOCK, "point_on_mountain", "%s (%d,%d) 是山地" % [what, t.x, t.y])
		return
	# 5) 摆放 / 大本营不许压在区划中心格上（`_spawn_zone_centers` 只在任何单位出生之前建中心，
	#    叠格会静默建不出来 —— route.md 33.5 坑①）
	for zid in map.zones_centers.keys():
		if (map.zones_centers[zid] as Vector2i) == t:
			_add(SEV_BLOCK, "point_on_zone_center",
				"%s (%d,%d) 是区块 c%d 的中心" % [what, t.x, t.y, int(zid)])
			return


## 7/8) 可玩阵营的目标；目标区划的开局归属
func _ck_allies() -> void:
	if map == null:
		return
	var pairs := effective_allies()
	FactionRes.set_allies(pairs)

	var playable := playable_ids()
	# 7) ★★ 两个口径（**按是否有「点名目标」自动切换**）：
	#
	#    (a) **普通关卡**（目标没有 `for` 字段 / 只有一个可玩阵营）：
	#        沿用老口径 —— ≥2 个可玩阵营必须**互为同方**。
	#        理由：目标只有**一份**，判定走「玩家同方」；可玩阵营如果各占一边，
	#        「选谁」就变成了两场不同的仗，而数据只描述了一场。
	#
	#    (b) ★ **选边关卡**（`objectives[]` 里有带 `for` 的目标）：
	#        两个可玩阵营**本来就是对立的**（蓝方守、红方攻），所以「互为同方」不成立、
	#        也不该成立。这时改拦**另一条**：★ **每一个可玩阵营都要有属于它的目标** ——
	#        否则玩家选了它就没目标可打（那是最难查的一类：列表上有它，点进去无事发生）。
	if has_per_faction_objectives():
		for fid in playable:
			if objective_for(String(fid)) == null:
				_add(SEV_BLOCK, "playable_no_objective",
					"可玩阵营「%s」没有属于自己的目标：它选了也没得打（objectives[] 里补一条 for=%s 的）"
					% [String(fid), String(fid)])
	elif playable.size() >= 2:
		var rep := FactionRes.side_of(String(playable[0]))
		for fid in playable:
			if FactionRes.side_of(String(fid)) != rep:
				_add(SEV_BLOCK, "playable_not_same_side",
					"%s 与 %s 是敌对关系，不能同时可玩（可玩阵营必须互为盟友）"
					% [String(playable[0]), String(fid)])
				break

	# 8) ★★ 目标区划的开局归属 —— **逐条目标**判，判据按目标种类分：
	#
	#    · `hold_zone`（守住）：区划**必须开局就归这一方**。
	#      否则「丢掉即判负」会让玩家一进关就判负（规则没错、数据写错就炸的组合）。
	#    · `capture_zone`（攻占）：区划**必须开局不归这一方**。
	#      否则一进关就判胜（同一个坑的另一面）。
	#
	#  ⚠️ 「这一方」= 目标点名的 `for`；没点名时用第一个席位（老数据的行为）。
	#  ⚠️ 这里**不再**用「玩家同方」判：选边关卡里红方与蓝方是敌对，
	#     而红方那条 `capture_zone` 恰恰要求区划在**敌方**手里。
	var seat := String(seats()[0]) if not seats().is_empty() else ""
	for item in objectives:
		var od: Dictionary = item
		var zid := int(od.get("zone", -1))
		if zid < 0 or not _zone_exists(zid):
			continue                        # 「没写 / 不存在」两档由 `_ck_objectives` 拦
		var who := String(od.get(OBJ_FIELD_FOR, ""))
		var fid_own := who if who != "" else seat
		var kind := String(od.get("kind", ""))
		var owner := _initial_zone_owner(zid)
		if kind == OBJ_CAPTURE_ZONE:
			if owner != "" and fid_own != "" and FactionRes.same_side_for_attack(owner, fid_own):
				_add(SEV_BLOCK, "objective_already_mine",
					"「占领 %s」的目标区划开局就归 %s（自己）—— 一进关就判胜；请把它划给对手"
					% [_zone_label(zid), owner])
			elif owner == "":
				_add(SEV_WARN, "objective_capture_unowned",
					"「占领 %s」的目标区划开局无主：红方走进去就算占领，可能比预期容易"
					% _zone_label(zid))
			continue
		# hold_zone（以及以后任何「守住」类）
		if owner == "":
			_add(SEV_BLOCK, "objective_unowned",
				"目标区划 %s 开局无主：玩家一进关就会判负（本版没有「先占领再守」）" % _zone_label(zid))
		elif fid_own != "" and not FactionRes.same_side_for_attack(owner, fid_own):
			_add(SEV_BLOCK, "objective_not_players",
				"目标区划 %s 开局归 %s，%s 一进关就会判负" % [_zone_label(zid), owner, fid_own])

	# ★★ 8b) **额外失败条件**的区划也必须**开局就归玩家同方**（同一个坑的第二面）。
	#
	# 为什么：`zone_lost` 的判据是「这一区不再归玩家同方 ⇒ 立刻判负」——
	#   如果它**开局就不归玩家同方**，那第一帧就成立、第一帧就判负。
	#   实测踩到过：样例战役第二关配了 `zone_lost: 6`，而 f1 那张图上是**无主**的，
	#   于是那一关**一进去就输**（探针跑出来的：`reason = zone_lost:6`，held = 0.1）。
	#   ⚠️ 与第 8 条是**两件不同的事**（目标区划 vs 额外失败区划），要各拦一次。
	for item in fail_conditions:
		var fd: Dictionary = item
		if String(fd.get("kind", "")) != FAIL_ZONE_LOST:
			continue
		var fz2 := int(fd.get("zone", -1))
		if fz2 < 0 or not _zone_exists(fz2):
			continue                        # 「没写 / 不存在」两档由 `_ck_objectives` 拦
		var fowner := _initial_zone_owner(fz2)
		if fowner == "":
			_add(SEV_BLOCK, "fail_zone_unowned",
				"额外失败条件的区划 %s 开局无主：玩家一进关就会判负" % _zone_label(fz2))
		elif seat != "" and not FactionRes.same_side_for_attack(fowner, seat):
			_add(SEV_BLOCK, "fail_zone_not_players",
				"额外失败条件的区划 %s 开局归 %s，玩家一进关就会判负" % [_zone_label(fz2), fowner])


## 9/11) 目标恰好 1 项 + 额外失败条件的区划存在且不是目标区划
func _ck_objectives() -> void:
	if objectives.is_empty():
		_add(SEV_BLOCK, "objective_empty", "这一关没有目标")
	# ★★ 一关可以有多条目标 —— 但**只在「按阵营分开」时**（每条都点名 `for`）。
	#    两条都不点名的话，运行时按谁的都说不清（`objective_for` 只会取第一条），
	#    那是「写了但没生效」的典型，必须拦。
	if objectives.size() > 1 and not has_per_faction_objectives():
		_add(SEV_BLOCK, "objective_too_many",
			"写了 %d 个目标、但一条都没点名给谁（每条加一个 for=阵营；只有一个阵营时只写一条）"
			% objectives.size())
	var seen_for: Dictionary = {}
	for o in objectives:
		var od: Dictionary = o
		var kind := String(od.get("kind", ""))
		var who := String(od.get(OBJ_FIELD_FOR, ""))
		if kind != OBJ_HOLD_ZONE and kind != OBJ_CAPTURE_ZONE:
			_add(SEV_BLOCK, "objective_kind", "目标种类「%s」不认识（支持 %s / %s）"
				% [kind, OBJ_HOLD_ZONE, OBJ_CAPTURE_ZONE])
			continue
		# 同一个阵营不能有两条目标（谁生效说不清）
		if who != "" and seen_for.has(who):
			_add(SEV_BLOCK, "objective_dup_for", "阵营「%s」配了两条目标（只能一条）" % who)
		seen_for[who] = true
		var zid := int(od.get("zone", -1))
		if zid < 0:
			_add(SEV_BLOCK, "objective_no_zone", "目标没写 zone")
		elif not _zone_exists(zid):
			_add(SEV_BLOCK, "objective_zone_missing", "目标区划 c%d 不存在" % zid)
		# ⚠️ `hold_sec` 只有「守住」类才要求 > 0：「占领即赢」那条不需要时间
		if kind == OBJ_HOLD_ZONE and float(od.get("hold_sec", 0.0)) <= 0.0:
			_add(SEV_BLOCK, "objective_hold_sec",
				"守住时间必须大于 0 秒（现在写的是 %s）" % str(od.get("hold_sec", 0.0)))

	for f in fail_conditions:
		var fd: Dictionary = f
		if String(fd.get("kind", "")) != FAIL_ZONE_LOST:
			_add(SEV_BLOCK, "fail_kind", "失败条件种类「%s」不认识（第一批只支持 %s）"
				% [String(fd.get("kind", "")), FAIL_ZONE_LOST])
			continue
		var fz := int(fd.get("zone", -1))
		if fz < 0:
			_add(SEV_BLOCK, "fail_no_zone", "「指定区划失守」这条失败条件没写 zone")
			continue
		if not _zone_exists(fz):
			_add(SEV_BLOCK, "fail_zone_missing", "失败条件的区划 c%d 不存在" % fz)
		# ⚠️ 与**任何一条**目标区划重合都算笔误（一关可能有多条目标）
		for o in objectives:
			if fz == int((o as Dictionary).get("zone", -1)):
				_add(SEV_BLOCK, "fail_zone_is_objective",
					"额外失败条件的区划不能就是目标区划（重复配置是笔误）")
				break


## 4/10/12/13/14/15) AI 指派、进攻目标、摆放里的将领性 AI
func _ck_ai_assign(config_ai: Array) -> void:
	var ai_list := merged_ai_factions(config_ai)

	# 12) 进攻目标引用的区划 / 格 / 建筑存在且可通行
	for item in ai_list:
		var it: Dictionary = item
		var fid := String(it["id"])
		var spec: Variant = it.get("attack_target", null)
		if spec == null:
			continue
		_ck_attack_target(fid, spec)

	# 15) 挂着阵营 AI 的阵营一个都没写 attack_target → 警告
	#
	# ⚠️ 只算**这一关真的会有 AI 的**那几方，两种都要排除掉：
	#    · `source == "map"`：地图 `factions_meta` 里登记的阵营只是「地图上划过它」，
	#      默认 `ai` 是 `none`（把地图登记也算进来，**任何一张划过阵营的地图**都会常驻
	#      一条假警告 —— 实测踩到）；
	#    · `source == "config"`：**有 level 的时候这些根本不进这一局**
	#      （`world._keep_level_sourced()` 会把它们丢掉，口径见 dev_plan_7 1.3.4）。
	#      ⚠️ 原来漏了这一条：样例第二关（纯合作关、一个 AI 都没有）因此常驻一条假警告。
	var faction_ais: Array = []
	for item in ai_list:
		var it2: Dictionary = item
		var src := String(it2.get("source", ""))
		if src == "map" or src == "config":
			continue
		if String(it2.get("ai", AI_NONE)) == AI_FACTION:
			faction_ais.append(it2)
	if faction_ais.size() > 0:
		var any_target := false
		for item in faction_ais:
			if (item as Dictionary).get("attack_target", null) != null:
				any_target = true
				break
		if not any_target:
			_add(SEV_WARN, "no_attack_target",
				"挂着阵营 AI 的阵营一个都没写进攻目标：它们会各自去打「离自己最近的敌方区划」")

	# 14) 某个 AI 阵营的进攻目标指向自己的地 → 警告（可能是笔误，也可能是故意的）
	for item in faction_ais:
		var it3: Dictionary = item
		var spec2: Variant = it3.get("attack_target", null)
		if spec2 == null or typeof(spec2) != TYPE_DICTIONARY:
			continue
		if String((spec2 as Dictionary).get("kind", "")) != TARGET_ZONE:
			continue
		var zid := int((spec2 as Dictionary).get("zone", -1))
		var owner := _initial_zone_owner(zid)
		if owner != "" and FactionRes.same_side_for_attack(owner, String(it3["id"])):
			_add(SEV_WARN, "attack_target_own_land",
				"%s 的进攻目标 %s 是自己占的区划，确认是有意的吗" % [String(it3["id"]), _zone_label(zid)])

	# 16) allies 里出现了不存在的 faction id → 警告
	var known := {}
	for fid2 in present_ids():
		known[String(fid2)] = true
	for pr in effective_allies():
		if typeof(pr) != TYPE_ARRAY:
			continue
		for x in (pr as Array):
			if not known.has(String(x)):
				_add(SEV_WARN, "ally_unknown", "盟友表里有未定义的阵营「%s」" % String(x))


## 12) `start_units[]` 里 `ai: "general"` 的项**都必须有** zone
func _ck_start_units() -> void:
	for u in start_units:
		var ud: Dictionary = u
		if String(ud.get("ai", AI_NONE)) == AI_GENERAL and int(ud.get("zone", -1)) < 0:
			_add(SEV_BLOCK, "unit_general_no_zone",
				"摆放的将领 (%d,%d) 挂了将领性 AI 却没有归属区划（它会原地发呆）"
				% [int(ud["x"]), int(ud["y"])])
		var fid := String(ud.get("faction", ""))
		if fid == "":
			_add(SEV_BLOCK, "unit_no_faction", "摆放单位 (%d,%d) 没写 faction" % [int(ud["x"]), int(ud["y"])])


## 13) 关卡**摆放**里用到的 faction 都必须有定义。
##
## ★ 判据是「地图 `factions` ∪ 关卡 `factions` ∪ 玩家席位」。
## ⚠️ **只管摆放**，不管玩家席位：`players[].faction` 写了一个谁都不认识的名字
##   不是「没有定义」这种数据错，而是「这一关让一个不在场的阵营来打」——
##    那是设计意图的问题，由第 8 条（目标区划开局归属）与运行时的兜底去体现。
func _ck_level_factions() -> void:
	var known := {}
	for fid in present_ids():
		known[String(fid)] = true
	for u in start_units:
		var f := String((u as Dictionary).get("faction", ""))
		if f != "" and not known.has(f):
			_add(SEV_BLOCK, "faction_unknown", "阵营「%s」没有定义" % f)
	for b in start_buildings:
		var f2 := String((b as Dictionary).get("owner", ""))
		if f2 != "" and not known.has(f2):
			_add(SEV_BLOCK, "faction_unknown", "阵营「%s」没有定义" % f2)


func _ck_attack_target(fid: String, spec: Variant) -> void:
	if typeof(spec) != TYPE_DICTIONARY:
		_add(SEV_BLOCK, "attack_target_shape", "阵营「%s」的进攻目标不是对象" % fid)
		return
	var d: Dictionary = spec
	var kind := String(d.get("kind", ""))
	if kind == TARGET_ZONE:
		var zid := int(d.get("zone", -1))
		if zid < 0 or not _zone_exists(zid):
			_add(SEV_BLOCK, "attack_target_zone", "阵营「%s」的进攻目标区划 c%d 不存在" % [fid, zid])
		return
	if kind == TARGET_POINT or kind == TARGET_BUILDING:
		var t := Vector2i(int(d.get("x", -1)), int(d.get("y", -1)))
		_ck_point_target(fid, t, kind)
		return
	if kind == TARGET_BASE:
		var bf := String(d.get("faction", ""))
		if bf == "":
			_add(SEV_BLOCK, "attack_target_base", "阵营「%s」的进攻目标是「某方的家」但没写 faction" % fid)
		elif _map_base(bf).x < 0:
			_add(SEV_BLOCK, "attack_target_base", "阵营「%s」的进攻目标指向 %s 的大本营，但那一方没有大本营" % [fid, bf])
		return
	_add(SEV_BLOCK, "attack_target_kind",
		"阵营「%s」的进攻目标种类「%s」不认识（支持 zone / point / building / base）" % [fid, kind])


func _ck_point_target(fid: String, t: Vector2i, kind: String) -> void:
	if map == null:
		return
	if t.x < 0 or t.y < 0:
		_add(SEV_BLOCK, "attack_target_point", "阵营「%s」的进攻目标没写坐标" % fid)
		return
	if not map.tile_exists(t.x, t.y):
		_add(SEV_BLOCK, "attack_target_outside",
			"阵营「%s」的进攻目标指向 (%d,%d)：地图外" % [fid, t.x, t.y])
		return
	if not map.terrain_walkable(t.x, t.y):
		_add(SEV_BLOCK, "attack_target_mountain",
			"阵营「%s」的进攻目标指向 (%d,%d)：山地走不到" % [fid, t.x, t.y])


# ------------------------------------------------------------------
# 内部小工具
# ------------------------------------------------------------------

func _add(sev: String, code: String, msg: String) -> void:
	issues.append({"sev": sev, "code": code, "msg": msg})


func _meta_ids() -> Array:
	var out: Array = []
	for e in faction_meta:
		out.append(String((e as Dictionary)["id"]))
	return out


func _map_has_faction(fid: String) -> bool:
	if map == null:
		return false
	for m in map.factions_meta:
		if typeof(m) == TYPE_DICTIONARY and String((m as Dictionary).get("id", "")) == fid:
			return true
	return false


## 地图给这一方的大本营（没有 → (-1,-1)）。关卡自己的 `base` 优先，这一份是兜底。
func _map_base(fid: String) -> Vector2i:
	if map == null:
		return Vector2i(-1, -1)
	var v: Variant = map.faction_bases.get(fid, null)
	if v == null:
		return Vector2i(-1, -1)
	return v


## 这一方在**关卡 / 战役**数据里的显示名（没写 → 退回 id）。
##
## ★ 用途：关卡页上那两颗「选谁」的按钮要显示 **蓝方 / 红方**，而不是 `F1` / `F2`。
##   查表顺序（**一处实现**，界面不自己拼名字、也不去反查战役对象）：
##     1. 关卡 `factions[].name`（载入时抄进 `faction_names`，**关卡优先**）；
##     2. 地图 `factions_meta[].name`；
##     3. 退回 id。
func faction_name(fid: String) -> String:
	var nm := String(faction_names.get(fid, "")).strip_edges()
	if nm != "":
		return nm
	if map != null:
		for m in map.factions_meta:
			if typeof(m) != TYPE_DICTIONARY:
				continue
			if String((m as Dictionary).get("id", "")) == fid:
				var nm2 := String((m as Dictionary).get("name", "")).strip_edges()
				if nm2 != "":
					return nm2
	return fid


## 这一方**关卡合并之后**的大本营：关卡写了用关卡的，没写用地图的。
func base_of(fid: String) -> Vector2i:
	# 存档在 map 上的那一份已经是合并结果（merge_over_map 写过），所以先问它
	var from_map := _map_base(fid)
	if from_map.x >= 0:
		return from_map
	for e in faction_meta:
		if String((e as Dictionary)["id"]) == fid:
			return (e as Dictionary)["base"]
	return Vector2i(-1, -1)


func _zone_exists(zid: int) -> bool:
	if map == null:
		return false
	if not map.zones_centers.has(zid):
		return false
	return _zone_tile_count(zid) > 0


## 某个区划在这张图上有没有地块（`zones_grid` 里数一遍）。
##
## ⚠️ 为什么不直接用 `zones_centers.has(zid)`：中心与「这个区划存不存在」是两件事 ——
##    手写地图可能没给某个区划中心（老图），而那个区划在地块网格里是实打实存在的。
func _zone_tile_count(zid: int) -> int:
	if map == null:
		return 0
	var n := 0
	for row in map.zones_grid:
		if typeof(row) != TYPE_ARRAY:
			continue
		for v in (row as Array):
			if int(v) == zid:
				n += 1
	return n


## 某个区划的**开局归属**（关卡覆盖 → 地图），无主 / 不认识 → ""。
func _initial_zone_owner(zid: int) -> String:
	if zone_owners.has(zid):
		return String(zone_owners[zid])
	if map != null and map.zones_owners.has(zid):
		return String(map.zones_owners[zid])
	return ""


## 区划的显示名（地图里有名字就用名字，否则 c<id>）。
func _zone_label(zid: int) -> String:
	if map != null and map.zones_names.has(zid):
		var n := String(map.zones_names[zid]).strip_edges()
		if n != "":
			return n
	return "c%d" % zid


## 秒数显示：整数就不带小数点。
static func _fmt_sec(v: float) -> String:
	if absf(v - roundf(v)) < 0.001:
		return "%d" % int(roundf(v))
	return "%.1f" % v


static func _text(v: Variant, fallback: String) -> String:
	if typeof(v) == TYPE_STRING:
		var s := String(v).strip_edges()
		if s != "":
			return s
	return fallback


static func _mode(v: Variant, fallback: String) -> String:
	var s := _text(v, "").to_lower()
	if s == MODE_SOLO or s == MODE_COOP:
		return s
	if fallback == MODE_COOP:
		return MODE_COOP
	return MODE_SOLO


static func _read_strings(v: Variant) -> Array:
	var out: Array = []
	if typeof(v) != TYPE_ARRAY:
		return out
	for item in (v as Array):
		if typeof(item) == TYPE_STRING:
			out.append(String(item))
	return out


## `players[]`：每项 {faction, base}。没有 faction 的项**丢掉**（它会污染席位顺序）。
static func _read_players(v: Variant) -> Array:
	var out: Array = []
	if typeof(v) != TYPE_ARRAY:
		return out
	for item in (v as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		var fid := String(d.get("faction", "")).strip_edges()
		if fid == "":
			continue
		out.append({"faction": fid, "base": _read_point(d.get("base", null))})
	return out


## `factions[]`：每项补齐成固定形状（缺字段有确定默认值）。
##
## ⚠️ `ai` 的默认值是 **"none"**（不挂 AI）而不是"继承 config"：
##    「关卡没写 ai」与「关卡写了 ai:none」在**运行时**是同一件事（都不进关卡 AI 名单），
##    差别只在合并时 —— 没写 → 继续吃全局 `config.ai.factions`；写了 none → 明确关掉。
##    这一层区分靠 `declared` 标记（见 `faction_config`），不靠默认值。
static func _read_level_factions(v: Variant) -> Array:
	var out: Array = []
	if typeof(v) != TYPE_ARRAY:
		return out
	for item in (v as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		var fid := String(d.get("id", "")).strip_edges()
		if fid == "":
			continue
		var entry := {
			"id": fid,
			"ai": _ai_kind(d.get("ai", null)),
			"base": _read_point(d.get("base", null)),
			# ★ 阵营颜色（`#rrggbb` / `rgba(...)`）：关卡可以给**这一关**的某一方换个颜色。
			#   缺省是空串 = 「这一关没提」，于是用 `campaign.json` 里那一份。
			"color": String(d.get("color", "")).strip_edges(),
			"resource_mult": _num(d.get("resource_mult", null), 1.0),
			"start_food": _num(d.get("start_food", null), 0.0),
			"start_gold": _num(d.get("start_gold", null), 0.0),
			"attack_target": null,
			"faction_ai": null,
			"general_ai": null,
		}
		var spec: Variant = d.get("attack_target", null)
		if typeof(spec) == TYPE_DICTIONARY:
			entry["attack_target"] = _read_attack_target(spec)
		var fa: Variant = d.get("faction_ai", null)
		if typeof(fa) == TYPE_DICTIONARY:
			entry["faction_ai"] = (fa as Dictionary).duplicate(true)
		var ga: Variant = d.get("general_ai", null)
		if typeof(ga) == TYPE_DICTIONARY:
			entry["general_ai"] = (ga as Dictionary).duplicate(true)
		out.append(entry)
	return out


## `ai` 字段：只认 faction / general / none；别的（含缺字段）→ none，并留一条痕迹。
static func _ai_kind(v: Variant) -> String:
	if typeof(v) != TYPE_STRING:
		return AI_NONE
	var s := String(v).strip_edges().to_lower()
	if s == AI_FACTION or s == AI_GENERAL or s == AI_NONE:
		return s
	return AI_NONE


## `attack_target`：把 kind 与载荷规范化（坐标 / 区划号 / 阵营 id）。
static func _read_attack_target(d: Dictionary) -> Dictionary:
	var kind := String(d.get("kind", "")).strip_edges().to_lower()
	var out := {"kind": kind, "zone": -1, "x": -1, "y": -1, "faction": ""}
	if kind == TARGET_ZONE:
		out["zone"] = int(d.get("zone", -1))
	elif kind == TARGET_POINT or kind == TARGET_BUILDING:
		out["x"] = int(d.get("x", -1))
		out["y"] = int(d.get("y", -1))
	elif kind == TARGET_BASE:
		out["faction"] = String(d.get("faction", "")).strip_edges()
	return out


## `zones[]`：开局的区块归属覆盖（每项 {id, owner}）。
##
## ★ **空串也记**（不是「跳过」）：`{"id": 4, "owner": ""}` 的语义是
##   「把这一区的开局归属**显式清空**」—— 与「没提这一区」（保持地图的）是两件事。
##   校验第 8 条要能把后者判成「目标区划无主」，所以这里不能把空串吞掉。
static func _read_zone_owners(v: Variant) -> Dictionary:
	var out: Dictionary = {}
	if typeof(v) != TYPE_ARRAY:
		return out
	for item in (v as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		var zid := int(d.get("id", -1))
		if zid < 0:
			continue
		out[zid] = String(d.get("owner", "")).strip_edges()
	return out


## `start_units[]`：每项补齐成固定形状（见 dev_plan_7 2.3 那张表）。
static func _read_start_units(v: Variant) -> Array:
	var out: Array = []
	if typeof(v) != TYPE_ARRAY:
		return out
	for item in (v as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		var kind := String(d.get("kind", "")).strip_edges()
		if kind == "":
			continue
		var gi := int(d.get("general_index", -1))
		if gi < 0:
			gi = ConfigRes.general_index_of(kind) + 1
		out.append({
			"faction": String(d.get("faction", "")).strip_edges(),
			"kind": kind,
			"general_index": maxi(1, gi),
			"unit_type": String(d.get("unit_type", "")).strip_edges(),
			"x": int(d.get("x", -1)),
			"y": int(d.get("y", -1)),
			# ⚠️ 缺省是 "none"（不挂将领性 AI）：挂了却忘了写 zone 的后果是「原地发呆」，
			#    所以「默认不挂」比「默认挂上」安全得多（校验第 12 条会拦那种组合）。
			"ai": _ai_kind(d.get("ai", null)),
			"zone": int(d.get("zone", -1)),
			"hold": bool(d.get("hold", false)),
			"name": String(d.get("name", "")).strip_edges(),
		})
	return out


## `start_buildings[]`：每项 {type, x, y, owner}（与地图 `buildings` 同构）。
static func _read_start_buildings(v: Variant) -> Array:
	var out: Array = []
	if typeof(v) != TYPE_ARRAY:
		return out
	for item in (v as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		var t := String(d.get("type", "")).strip_edges()
		if t == "":
			continue
		out.append({
			"type": t,
			"x": int(d.get("x", -1)),
			"y": int(d.get("y", -1)),
			"owner": String(d.get("owner", "")).strip_edges(),
		})
	return out


static func _read_objectives(v: Variant) -> Array:
	var out: Array = []
	if typeof(v) != TYPE_ARRAY:
		return out
	for item in (v as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		out.append({
			"kind": String(d.get("kind", "")).strip_edges().to_lower(),
			"zone": int(d.get("zone", -1)),
			"hold_sec": _num(d.get("hold_sec", null), 0.0),
			# ★★ 这一条目标是**给哪个阵营的**（空串 = 对任何玩家都成立）。
			#    一关可以有**两项**目标：一项给蓝方（守住）、一项给红方（攻占）——
			#    玩家选谁，运行时由 `objective_for()` 取对应的那一条。
			"for": String(d.get("for", "")).strip_edges(),
		})
	return out


static func _read_fail_conditions(v: Variant) -> Array:
	var out: Array = []
	if typeof(v) != TYPE_ARRAY:
		return out
	for item in (v as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		out.append({
			"kind": String(d.get("kind", "")).strip_edges().to_lower(),
			"zone": int(d.get("zone", -1)),
		})
	return out


## `allies`：与 `map_data._read_allies` **同一套宽容度**（两边必须一致，否则同一份数据
## 在「地图里」与「关卡里」会读出两种结果）。
static func _read_allies(v: Variant) -> Array:
	var out: Array = []
	if typeof(v) != TYPE_ARRAY:
		return out
	for item in (v as Array):
		if typeof(item) != TYPE_ARRAY:
			continue
		var pair: Array = item as Array
		if pair.size() < 2:
			continue
		var a := String(pair[0]).strip_edges()
		var b := String(pair[1]).strip_edges()
		if a == "" or b == "" or a == b:
			continue
		out.append([a, b])
	return out


## `[x, y]` → Vector2i；没写 / 格式不认识 → (-1, -1)（=「没写」，与「写了 (0,0)」区分开）。
static func _read_point(v: Variant) -> Vector2i:
	if typeof(v) == TYPE_ARRAY and (v as Array).size() >= 2:
		var a: Array = v as Array
		return Vector2i(int(a[0]), int(a[1]))
	if typeof(v) == TYPE_DICTIONARY:
		var d: Dictionary = v
		if d.has("x") and d.has("y"):
			return Vector2i(int(d["x"]), int(d["y"]))
	return Vector2i(-1, -1)


static func _num(v: Variant, fallback: float) -> float:
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return float(v)
	if typeof(v) == TYPE_STRING and String(v).is_valid_float():
		return float(v)
	return fallback


static func read_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	return JSON.parse_string(text)
