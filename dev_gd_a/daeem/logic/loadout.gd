## loadout.gd —— 备战页的「出战配置」（每个派系各一套）。
##
## ★★ 2026.11 用户口径：
##   · 玩家可以在**任意派系**里选：零阶 1 位、一阶 3 位、二阶 3 位、三阶 3 位；
##   · 名额按**派系各算一套**（王朝 / 帝国互不影响）；当前选中的派系 = 出战派系；
##   · 某一阶已满时再选一位 ⇒ **顶掉该阶最早选中的那一位**（FIFO）；
##   · 合作模式里：零阶那位 = 开局将领，一 / 二 / 三阶选中的 9 位 = 区划招募九宫格；
##   · ★★ 2026.11：主菜单 ai_test 也读这一份 —— 玩家席位用选中的派系 / 将领，
##     敌方从王朝 / 帝国独立随机，并用 `random_payload_for()` 抽一套对手配置；
##   · 只在本次运行内保存（项目没有存档系统，关掉游戏回到默认）。
##
## ★★ 为什么是 static var 而不是 autoload：
##   · 工程里没有 autoload（project.godot 只有主场景），加一个会动到启动链；
##   · 训练/测试用 `--script` 跑，静态状态在同一进程里就能读写（见 reset()）。
##
## ★ 这个文件**不碰 UI、不碰 world**：只回答「谁被选中 / 顶掉谁 / 合作里带哪几位」，
##   以及 `apply_to_level()` 这一处「把配置写进关卡数据」的落点。
##   UI 的动画 / 倒三角在 view/prepare_roster_list.gd。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")

## 每一阶的名额（下标 = 阶，0~3）。用户口径：1 / 3 / 3 / 3。
const QUOTA := [1, 3, 3, 3]

## 备战页只有这两个派系按钮（原生没有按钮，不在出战体系里）。
const FACTIONS := ["dynasty", "empire"]
const DEFAULT_FACTION := "empire"

## `派系 → [将领序号...]`（**按选中顺序**排队；FIFO 顶掉要靠这个顺序）。
static var _sel: Dictionary = {}
## 当前选中的出战派系。
static var _faction: String = DEFAULT_FACTION
## 客机从房主那里收到的「另一个席位」的出战配置（`apply_to_level` 用）。
static var _remote: Dictionary = {}


# ------------------------------------------------------------------
# 基础状态
# ------------------------------------------------------------------

static func reset() -> void:
	_sel = {}
	_faction = DEFAULT_FACTION
	_remote = {}


static func faction() -> String:
	return _faction


static func set_faction(id: String) -> void:
	_faction = id if FACTIONS.has(id) else DEFAULT_FACTION


static func quota(tier: int) -> int:
	if tier < 0 or tier >= QUOTA.size():
		return 0
	return int(QUOTA[tier])


## 某个派系当前选中的将领序号（副本；顺序 = 选中顺序）。
static func selected(faction_id: String) -> Array:
	var a: Variant = _sel.get(faction_id, null)
	return (a as Array).duplicate() if typeof(a) == TYPE_ARRAY else []


static func is_selected(faction_id: String, index: int) -> bool:
	return selected(faction_id).has(index)


## 某一阶现在选了几位。
static func tier_count(faction_id: String, tier: int, cfg) -> int:
	var n := 0
	for i in selected(faction_id):
		if cfg != null and cfg.general_tier_at(int(i)) == tier:
			n += 1
	return n


# ------------------------------------------------------------------
# 默认勾选
# ------------------------------------------------------------------

## 第一次进入 / 从未改过：按名册顺序把每一阶勾到名额上限。
##
## ★ 默认 = 现在这 10 位（零阶 1 + 每阶前 3），因此**不改任何东西时合作模式行为不变**；
##   新加的 4 位初始不选，长按它就会按 FIFO 顶掉该阶最早的那位。
static func ensure_defaults(cfg) -> void:
	if cfg == null:
		return
	for fid in FACTIONS:
		if _sel.has(fid):
			continue
		var picked: Array = []
		var per_tier: Dictionary = {}
		for idx in cfg.general_count():
			if not cfg.general_in_faction(idx, fid):
				continue
			var t: int = cfg.general_tier_at(idx)
			var used: int = int(per_tier.get(t, 0))
			if used >= quota(t):
				continue
			per_tier[t] = used + 1
			picked.append(idx)
		_sel[fid] = picked


# ------------------------------------------------------------------
# 选中 / 取消（长按磁贴的唯一落点）
# ------------------------------------------------------------------

## 切换某一位的出战状态。
##
## @return `{"on": bool, "evicted": int}` —— `evicted` = 被 FIFO 顶掉的将领序号（没有 = -1），
##         界面用它做「旧的那位倒三角消失」的反馈（不做额外动画，下一帧自然消失）。
##
## ★ 规则（用户原话）：「若玩家当前阶将领已满，则会取消选中该阶第一个选中的将领」。
##   所以顺序是：**先顶掉最早的，再加入新的**；顶掉的那位可能正是刚点的那位吗？
##   不可能 —— 点之前它没被选中，不会在队列里。
static func toggle(faction_id: String, index: int, cfg) -> Dictionary:
	if cfg == null or index < 0 or index >= cfg.general_count():
		return {"on": false, "evicted": -1}
	var cur := selected(faction_id)
	if cur.has(index):
		cur.erase(index)
		_sel[faction_id] = cur
		return {"on": false, "evicted": -1}
	var tier: int = cfg.general_tier_at(index)
	var evicted := -1
	# 该阶已满 ⇒ 顶掉**这一阶最先被选中**的那一位。
	if tier >= 0 and tier < QUOTA.size():
		while _count_tier(cur, tier, cfg) >= quota(tier):
			var victim := _first_of_tier(cur, tier, cfg)
			if victim < 0:
				break
			cur.erase(victim)
			evicted = victim
	cur.append(index)
	_sel[faction_id] = cur
	return {"on": true, "evicted": evicted}


static func _count_tier(list: Array, tier: int, cfg) -> int:
	var n := 0
	for i in list:
		if int(cfg.general_tier_at(int(i))) == tier:
			n += 1
	return n


static func _first_of_tier(list: Array, tier: int, cfg) -> int:
	for i in list:
		if int(cfg.general_tier_at(int(i))) == tier:
			return int(i)
	return -1


# ------------------------------------------------------------------
# 合作模式要用的东西
# ------------------------------------------------------------------

## 出战派系要带进合作的**九宫格将领**（一/二/三阶，按阶排序、阶内按选中顺序）。
##
## ★ 零阶那位不进九宫格（它是开局将领），与现有「开局将领 #0 不参与区划招募」一致。
static func recruit_kinds(faction_id: String, cfg) -> Array:
	var out: Array = []
	if cfg == null:
		return out
	var picked := selected(faction_id)
	for tier in [1, 2, 3]:
		for i in picked:
			if cfg.general_tier_at(int(i)) != tier:
				continue
			out.append(kind_of(int(i)))
	return out


## 零阶那位的 kind（没选 = "" ⇒ 关卡原来的开局将领不动）。
static func starter_kind(faction_id: String, cfg) -> String:
	if cfg == null:
		return ""
	for i in selected(faction_id):
		if cfg.general_tier_at(int(i)) == 0:
			return kind_of(int(i))
	return ""


## 名册序号 → kind（第 10 档 = general_0；其余 = 下标 + 1）。与 roster 列表同一套规则。
static func kind_of(index: int) -> String:
	if index == ConfigRes.GENERAL_START_INDEX:
		return "general_0"
	return "general_%d" % (index + 1)


## 一份**可联网传输 / 可写进关卡**的出战配置。
##   `clan` = 派系 id；`starter` = 零阶 kinds（可能 ""）；`pool` = 九宫格的 kind 列表。
static func payload_for(faction_id: String, cfg) -> Dictionary:
	return {
		"clan": faction_id,
		"starter": starter_kind(faction_id, cfg),
		"pool": recruit_kinds(faction_id, cfg),
	}


## ★★ 2026.11：为某一派系**随机抽一套出战配置**（ai_test 的敌方 AI 用）。
##
## 形状与 `payload_for()` 完全一致，因此可以直接走 `apply_to_level()`。
## 规则与备战页的默认名额相同：零阶 1 位、一 / 二 / 三阶各最多 3 位；
## 只从**这个派系能用的将领**里抽（`general_in_faction`），抽中哪几位完全随机。
##
## @param seed_value ≥0 时固定随机种子（测试 / 复现用）；<0 = 每次重新播种。
## ★ 为什么单独一个纯函数：它**不改** `_sel`（玩家自己的备战选择），
##   否则开一局 ai_test 会把玩家在备战页勾好的阵容洗掉。
static func random_payload_for(faction_id: String, cfg, seed_value: int = -1) -> Dictionary:
	var fid := faction_id if FACTIONS.has(faction_id) else DEFAULT_FACTION
	if cfg == null:
		return {"clan": fid, "starter": "", "pool": []}
	var rng := RandomNumberGenerator.new()
	if seed_value >= 0:
		rng.seed = seed_value
	else:
		rng.randomize()
	var starters: Array = []
	var by_tier: Dictionary = {1: [], 2: [], 3: []}
	for idx in cfg.general_count():
		if not cfg.general_in_faction(idx, fid):
			continue
		var t: int = cfg.general_tier_at(idx)
		if t == 0:
			starters.append(idx)
		elif by_tier.has(t):
			(by_tier[t] as Array).append(idx)
	_shuffle(starters, rng)
	var starter := kind_of(int(starters[0])) if not starters.is_empty() else ""
	var pool: Array = []
	for t2 in [1, 2, 3]:
		var cand: Array = by_tier[t2]
		_shuffle(cand, rng)
		var take: int = mini(quota(t2), cand.size())
		for i in take:
			pool.append(kind_of(int(cand[i])))
	return {"clan": fid, "starter": starter, "pool": pool}


## 就地洗牌（Fisher–Yates）—— 用传进来的 rng，保证 seed 能复现。
static func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


static func set_remote(faction_id: String, payload: Dictionary) -> void:
	if faction_id == "":
		return
	_remote[faction_id] = payload.duplicate(true)


static func remote_for(faction_id: String) -> Dictionary:
	var v: Variant = _remote.get(faction_id, null)
	return (v as Dictionary).duplicate(true) if typeof(v) == TYPE_DICTIONARY else {}


# ------------------------------------------------------------------
# 写进关卡数据（合作模式开局前调用）
# ------------------------------------------------------------------

## 把一份出战配置写进 `level`（**同时改解析后的字段和 `raw`**）。
##
## @param seat_faction 这一份配置属于哪个席位（关卡里 `players[].faction` 的 id）
## @param payload      `payload_for()` 的形状；空字典 = 什么都不做
##
## ★ 为什么两份都要改：`world` 读的是解析后的 `level.faction_meta` / `level.start_units`，
##   而房主发给客机的 `start` 用的是 `level.raw`（见 host_session.start_game）。
##   只改一份就会出现「房主是王朝、客机是原生」这种最难查的分裂。
##
## ★ 派系：写 `factions[].clan`。空串 / 不认识的 id 不写（保持关卡原样）。
## ★ 开局将领：只替换**这个席位**的将领条目：
##   · 保留第一条将领的坐标 / 名字 / 附属单位规格（关卡作者的平衡与风味）；
##   · 把它换成 `general_0` 并**删掉 `unit_type`**（否则会被按兵种重新造一遍，
##     变成「骑手数值 + 将领 0 的名字」）；
##   · 其余将领条目删除（它们都在「九宫格 / 后续招募」里，不白送）。
##   ⚠️ `starter` 为空 ⇒ 这一整段跳过（关卡原样，玩家没选零阶就保留作者摆的将领）。
static func apply_to_level(level, seat_faction: String, payload: Dictionary) -> void:
	if level == null or seat_faction == "" or payload.is_empty():
		return
	var clan_id := String(payload.get("clan", "")).strip_edges()
	if clan_id != "":
		_apply_clan(level, seat_faction, clan_id)
	var starter := String(payload.get("starter", "")).strip_edges()
	if starter != "":
		_apply_starter(level, seat_faction, starter)


static func _apply_clan(level, seat_faction: String, clan_id: String) -> void:
	for e in level.faction_meta:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = e
		if String(d.get("id", "")) != seat_faction:
			continue
		d["clan"] = clan_id
	var raw: Variant = level.raw
	if typeof(raw) == TYPE_DICTIONARY:
		var arr: Variant = (raw as Dictionary).get("factions", null)
		if typeof(arr) == TYPE_ARRAY:
			for e2 in (arr as Array):
				if typeof(e2) == TYPE_DICTIONARY \
						and String((e2 as Dictionary).get("id", "")) == seat_faction:
					(e2 as Dictionary)["clan"] = clan_id


static func _apply_starter(level, seat_faction: String, starter: String) -> void:
	var units: Array = level.start_units
	var first: Dictionary = {}
	var kept: Array = []
	var inserted := false
	for u in units:
		if typeof(u) != TYPE_DICTIONARY:
			kept.append(u)
			continue
		var d: Dictionary = u
		if String(d.get("faction", "")) != seat_faction \
				or ConfigRes.general_index_of(String(d.get("kind", ""))) < 0:
			kept.append(d)
			continue
		if first.is_empty():
			first = d.duplicate(true)
			kept.append(_starter_entry(seat_faction, starter, first))
			inserted = true
		# 其余将领条目直接丢掉。
	if not inserted:
		return
	level.start_units = kept
	var raw: Variant = level.raw
	if typeof(raw) == TYPE_DICTIONARY:
		(raw as Dictionary)["start_units"] = kept.duplicate(true)


static func _starter_entry(seat_faction: String, starter: String, first: Dictionary) -> Dictionary:
	var entry: Dictionary = {
		"faction": seat_faction,
		"kind": starter,
		"x": first.get("x", 0),
		"y": first.get("y", 0),
	}
	# 保留作者写的名字 / 附属单位规格 / 驻守等（数值档由 kind 决定）。
	# ⚠️ 故意**不抄 unit_type**：抄了会被 `_place_faction_units` 按那个兵种重造一遍，
	#    结果就是「骑手数值 + 将领 0 的名字」，与「零阶将领」不再是同一个人。
	for k in ["name", "escort_count", "escort_types", "hold", "zone", "ai"]:
		if first.has(k):
			entry[k] = first[k]
	return entry
