## zone.gd —— 区块（领地）系统【占位逻辑】（对应 HTML 版 js/zone.js）
##
## 需求原话：「一大片的地块会归属在一个『区块』下，己方单位站在区块内持续一段时间后，
##            这个区块会转为己方。具体的区块划分后续在地图编辑时给出，现在自由写占位逻辑。」
##
## ★★ 现在有**两套**来源，按地图里有没有 zones 网格自动选：
##   1. 地图带 `zones` 网格（地图编辑器 tools/map_editor 导出的地图）→ **读网格**：
##      每格一个区块 id（-1 = 不属于任何区块），区块名在 `zone_list` 里。
##      地块可以任意形状（不必是矩形），所以这里的 x0/y0/x1/y1 是**由地块算出来的最小包围盒**
##      —— 只给渲染画底色用（view/zone_view.gd 照旧按矩形画）。
##   2. 地图没有 zones 网格（手写的老地图）→ 照旧横竖均分成
##      config.zone_cols × config.zone_rows 个矩形区块，名字 A1 / A2 …
##      ★ 这条路必须**一字不改**地留着：老地图的行为、以及钉在老行为上的测试都靠它。
##
## 区块状态：owner = ""（无主）| 阵营字符串（'player' / 'p1' / 'p2' …）
## 占领规则（**手玩定的完整版**，见 update() 的注释）：
##   只一方在场才读条；双方同场 → 停住；人在场但不能读 → 冻住；人走了/被打光 → 缓慢回落。
## 资源：每秒 = 己方区块的「地块数量」× 每秒产出（见 economy.gd）
##
## ★★ 为什么进度仍然是**每阵营独立**存 progress_by：
##    旧实现只有一个全局 progress，两方同时站进同一区块会互相抵消（一个加、一个减，
##    谁也占不下来）—— 见 docs/pitfalls.md 3.11。
##    现在每阵营各存一份；但**谁能涨**由 update() 的规则决定
##    （2026.9 手玩改版之后：同一时刻最多只有一方在涨，另一方冻住或回落）。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")
const FactionRes = preload("res://logic/faction.gd")
## ★ 特化的产能倍率在 logic/upgrade.gd 里（那份实现是**唯一**判据，见 `_spec_mult()`）。
##   ⚠️ 方向是 zone → upgrade，**不能反过来**：upgrade.gd 的 `tick()` 要读 zone 的字段。
const UpgradeRes = preload("res://logic/upgrade.gd")

const ROW_LETTERS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

## ★★ 区块人口的默认上限（地图编辑器里没填时的值）。
##
## 用户需求原话：「每个区块都需要有人口上限，如果没有填人口上限则默认为 1」。
## 编辑器那边只在「不等于 1」时才把 `population_cap` 写进地图 JSON，
## 所以**缺字段 = 1** 这条判据在两侧是同一套（map_data 不登记 → 这里补默认值）。
const DEFAULT_POPULATION_CAP := 1.0

var zones: Array = []
## 地块索引 → 区块 id（-1 = 不属于任何区块）
var lookup: Array = []
## ★ 地块索引 → 「这一格是哪个区块的中心」（-1 = 不是任何区块的中心）。
##
## 与 `lookup`（归属）是两张不同的表：中心格仍然**归属**它所在的区块，
## 只是多了一个「这里是这个区块的中心」的标记（游戏里落成一栋中立障碍建筑）。
## 为什么要单独一张表：点一格要 O(1) 问出「这是哪个区块的中心」，
## 而遍历 24 个区块的 tiles 在每次点选 / 每帧渲染里都嫌浪费。
var center_lookup: Array = []
var cols: int = 0
var rows: int = 0
## 建这一份区划时用的配置（只读）。`production_of()` 要它来查「特化的产能倍率是多少」。
## ⚠️ 不缓存成静态 / 不跨实例复用：测试会在同一进程里换配置建好几个世界。
var cfg: ConfigRes = null


static func build_from_map(map, cfg: ConfigRes, factions: Array) -> RefCounted:
	var zs = new()
	zs.cfg = cfg
	zs.cols = map.terrain.cols
	zs.rows = map.terrain.rows
	var flist := _capture_factions(factions)

	# 地图编辑器给的区块网格 / 名字表（老地图没有 → 走均分那条路）
	var grid: Variant = map.get("zones_grid")
	var names: Variant = map.get("zones_names")
	if typeof(grid) == TYPE_ARRAY and not (grid as Array).is_empty():
		zs._build_from_grid(map, grid, names if typeof(names) == TYPE_DICTIONARY else {}, flist)
	else:
		zs._build_even(cfg, flist)
	# ★ 中心与产能（地图给的，老地图没有 → 保持 0 / 无中心）
	zs._apply_map_centers(map)
	zs._apply_map_production(map)
	# ★ 人口上限（地图给的；缺字段的区块保持默认 1）
	zs._apply_map_population_caps(map)
	return zs


## 一个区块字典（两条建法共用，字段集中在这里，免得漏一个）
func _new_zone(zid: int, name: String, flist: Array) -> Dictionary:
	var progress_by: Dictionary = {}
	for f in flist:
		progress_by[f] = 0.0
	return {
		"id": zid,
		"name": name,
		"x0": 0, "y0": 0, "x1": -1, "y1": -1,
		"owner": "",
		"progress": 0.0,        # ★ 当前那条进度条的进度（没有条时 0）
		"progress_by": progress_by,   # ★ 每阵营各自的占领进度
		"capture_faction": "",  # ★ 这条条属于哪一方（见 update / capture_bar）
		"capture_state": "",    # ★ "" | reading | frozen | decaying
		"tile_count": 0,        # ★ 真实地块数（资源产出按它算）
		"tiles": [],            # ★ 地块明细（渲染画底色用；均分那条路在建的时候一起填）
		# ★★ 区划中心与产能（地图编辑器给的；老地图没有 → null / 0）
		#   · center 是**地块坐标**（Vector2i），也是「这一格上要落一栋中立障碍建筑」的位置；
		#   · production 是**每地块每秒**的产能（food / gold / population）。
		"center": null,
		"production": {"food": 0.0, "gold": 0.0, "population": 0.0},
		# ★ 区划人口：**每个区划各算各的**累积值，按时间涨、会被招募消耗（用户需求）。
		#   它**不进 HUD 的资源**（那是各阵营的粮食 / 黄金），也不快照给客机（见 snapshot.gd）。
		"population": 0.0,
		# ★★ 人口**上限**（用户需求：「每个区块都需要有人口上限，如果没有填人口上限则默认为 1；
		#    当人口自然增长至上限时停止增长」）。地图编辑器里没填 → 这里的默认 1。
		#    它和产能一样是**地图给的静态数据**，进游戏之后不会变，所以不进快照。
		"population_cap": DEFAULT_POPULATION_CAP,
		# ★★ 区划的**招募队列**（点区划中心 → 右下「招募」页签 → 招将领）。
		#
		# ★ 为什么挂在区划字典上（而不是像将领那样挂在单位上）：
		#   「这块地现在在造什么」天然属于这块地 —— 它不是某个单位的能力。
		#   权威列表 world.zones.zones 已经存在，另开一张「区划 id → 队列」的表
		#   就多出一份要对齐、要快照、要清理的状态（与 unit.gd 那条理由同源）。
		# · train_kind / train_remaining / train_total = 正在读条的那一单（空串 = 没在读条）
		# · train_queue      = 排队的那几单（最多 config.recruit.zone.queue_max - 1）
		# · train_faction    = **这一单开始时**的招募方：读条读完按它出兵，
		#                      免得中途区划易主就把将领出给了别人
		# · train_cost_*     = 已扣掉的钱 / 人口（取消时按记账值**全额**退款）
		"train_kind": "",
		"train_remaining": 0.0,
		"train_total": 0.0,
		"train_queue": [],
		"train_faction": "",
		"train_cost_food": 0.0,
		"train_cost_gold": 0.0,
		"train_cost_pop": 0.0,
		# ★★ 区划**特化**（见 logic/upgrade.gd 与 config.json 的 zone_spec 段）。
		#
		#   需求原话：「区划中心有三个特化选项……这三个特化玩家只能选一个升级……
		#   特化后的区块无法再次特化，但选中特化后的区块可以在操作面板中选择
		#   『取消特化』去除其特化，同理，特化也需要读条，取消特化也需要读条」。
		#
		# · spec_done   = **已经生效**的特化 id（"" = 没特化过）。★ 它跟着地块走：
		#                 区划易主时**保留**（谁占谁吃这个加成）。
		# · spec_kind   = **正在读条**的那一单：做特化时 = 那个特化 id，
		#                 取消特化时 = 固定的 "__cancel__"（见 upgrade.gd）
		# · spec_cancel = 这条读条是不是「取消特化」（读完要清掉 spec_done 并退款）
		# · spec_remaining / spec_total = 读条进度（total <= 0 = 没在读条）
		# · spec_cost_food / gold = **当初特化扣掉的**资源（取消特化读完时按它退款）。
		#   ⚠️ 特化**完成时不清零** —— 要留着给后来的「取消特化」退款用。
		"spec_done": "",
		"spec_kind": "",
		"spec_cancel": false,
		"spec_remaining": 0.0,
		"spec_total": 0.0,
		"spec_cost_food": 0.0,
		"spec_cost_gold": 0.0,
		# ⚠️ 这两组**目前都不进快照**（`snapshot.gd` 只发 owner / 进度 / 人口）：
		#    单机里本地就是权威，界面直接读它。第 1 轮联机时要像 `unit.train_*`
		#    那样补进快照，否则客机点开区划中心看不到「这个区划在造什么 / 特化成什么」。
	}


## ★ 把地图里各区块的「区划中心」登记进来（同时建好反查表 `center_lookup`）。
##
## 中心是**地块坐标**；它必须落在自己的区块里（编辑器导出前已经保证，这里再防一手：
## 落点不属于这个区块 / 在界外 / 落在山上 → 当作没设，免得游戏里在一个怪地方立一栋障碍）。
func _apply_map_centers(map) -> void:
	center_lookup = []
	center_lookup.resize(cols * rows)
	center_lookup.fill(-1)
	var raw: Variant = map.get("zones_centers")
	if typeof(raw) != TYPE_DICTIONARY:
		return
	var d: Dictionary = raw
	for z in zones:
		var zid := int(z["id"])
		if not d.has(zid):
			continue
		var p: Vector2i = d[zid]
		if not map.terrain.has(p.x, p.y):
			continue
		if not map.terrain_walkable(p.x, p.y):
			continue                    # 山上 / 地图外：中心立不起来
		if lookup[map.terrain.idx(p.x, p.y)] != zid:
			continue                    # 那一格不归这个区块（地图被手改过）
		z["center"] = p
		center_lookup[map.terrain.idx(p.x, p.y)] = zid


## ★ 把地图里各区块的「产能」读进来（每地块每秒）。
## 缺字段的档算 0 —— 与编辑器侧的容错一致（缺的档不写进 JSON）。
func _apply_map_production(map) -> void:
	var raw: Variant = map.get("zones_production")
	if typeof(raw) != TYPE_DICTIONARY:
		return
	var d: Dictionary = raw
	for z in zones:
		var zid := int(z["id"])
		if not d.has(zid):
			continue
		var p: Dictionary = d[zid]
		(z["production"] as Dictionary)["food"] = float(p.get("food", 0.0))
		(z["production"] as Dictionary)["gold"] = float(p.get("gold", 0.0))
		(z["production"] as Dictionary)["population"] = float(p.get("population", 0.0))


## ★ 把地图里各区块的「人口上限」读进来（缺字段 → 保持默认 1，不是 0）。
##
## 与产能那条的区别：产能缺档算 0（「没配就是没有产出」），而上限**缺字段算 1**
## —— 因为用户要的是「每个区块都必须有上限」。编辑器只在「不等于 1」时才写这个字段，
## 所以「没写」与「写了 1」在这里必须落到同一个值上。
func _apply_map_population_caps(map) -> void:
	var raw: Variant = map.get("zones_population_caps")
	if typeof(raw) != TYPE_DICTIONARY:
		return
	var d: Dictionary = raw
	for z in zones:
		var zid := int(z["id"])
		if not d.has(zid):
			continue
		# 负数当 0（那个区块永远没有人口），上限本身不设别的夹法 ——
		# 编辑器里的 0~999 只是挡误输入，游戏侧照单全收。
		z["population_cap"] = maxf(0.0, float(d[zid]))


## 这一格的**区划中心**属于哪个区块（返回区块字典；不是任何中心 → null）。
##
## ★ 与 `zone_at()` 的分工：`zone_at` 回答「这一格归谁」（用于占领 / 资源），
##   本函数回答「这一格上是不是立着某个区块的中心」（用于点选看详情）。
func center_zone_at(x: int, y: int) -> Variant:
	var z = center_zone_at_id(x, y)
	if z < 0:
		return null
	for zone in zones:
		if int(zone["id"]) == z:
			return zone
	return null


## 同上的 id 版（-1 = 不是任何区块的中心）
func center_zone_at_id(x: int, y: int) -> int:
	if x < 0 or y < 0 or x >= cols or y >= rows:
		return -1
	if center_lookup.size() != cols * rows:
		return -1
	return int(center_lookup[y * cols + x])


## 每帧推进各区块的人口（自然增长，涨到**上限**就停）。
##
## ★ 与占领**无关**：每个区块都按自己的人口产能涨（用户明确「不计入占领方的经济」）。
##   速率 = population 产能 × 该区块的地块数（「n 资源/地块/秒」的口径）。
## ★★ 上限（用户需求：「当人口自然增长至上限时停止增长」）：
##   涨到 `population_cap` 就**不再涨**；上限由地图编辑器给，没填则默认 1。
## ★ 上限**不会把已经超过它的现值拉回来**：这里只夹「这一帧的增长」。
##   为什么不做 `population = min(cap, population + gain)`：
##     · 招募退款（将领阵亡时按记账把人口退回原区划）有可能把现值顶到上限之上；
##     · 测试也会直接给区划塞一个大的人口值。
##   两者都不该在下一帧被悄悄削掉 —— 上限的语义是「自然增长到此为止」，
##   不是「现值永远不许超过它」。
##
## ★★ 科技「区划人口产量 +10%」（本轮新增）：
##   加的是**增长速度**，只对 `owner` 这一方**占领的**区划生效（需求原文
##   「玩家占领的区划人口产量 +10%」，用户确认口径 = production.population × 地块数）。
##   ⚠️ 上限 `population_cap` **不受科技影响** —— 加的是「涨得多快」，不是「能涨多高」。
##   ⚠️ 阵营比较走 `FactionRes.same_side`（与占领 / 资源那几处的口径一致）：
##      无主区划的 owner 是空串，`same_side(任何, "")` 恒为 false ⇒ 不加成。
##
## @param owner  享受加成的那一方（"" = 谁都不加成；单机 = world.my_faction）
## @param owner_mult 该方占领区划的增长倍率（1.0 = 没加成）
func update_population(dt: float, owner: String = "", owner_mult: float = 1.0) -> void:
	var boost: float = maxf(0.0, owner_mult)
	for z in zones:
		var rate := float((z["production"] as Dictionary).get("population", 0.0))
		# ★ 区划特化（本区块自己的倍率）先乘进来，再看科技的全局倍率 ——
		#   两者是**不同作用域**的加成，所以相乘叠加（需求：与科技加成叠加）。
		rate *= float(_spec_mult(z)["population"])
		if rate <= 0.0:
			continue
		if owner != "" and boost != 1.0 and FactionRes.same_side(String(z["owner"]), owner):
			rate *= boost
		var cap := population_cap_of(z)
		var pop := float(z["population"])
		if pop >= cap:
			continue
		z["population"] = minf(cap, pop + rate * float(z["tile_count"]) * dt)


## 这个区划的人口上限（缺字段 / 老地图 → 默认 1；负数当 0，不让它变成「负增长」）。
func population_cap_of(z: Dictionary) -> float:
	return maxf(0.0, float(z.get("population_cap", DEFAULT_POPULATION_CAP)))


## 这个区划现在的人口（浮点，权威值）。
## ⚠️ 要显示给人看的一律走 `population_floor()` —— 用户要求「ui 里显示的人口数量
##    需要始终为整数（显示上向下取整）」。
func population_of(z: Dictionary) -> float:
	return float(z.get("population", 0.0))


## 显示用的人口：**向下取整**（显示永远是整数，见用户需求）。
func population_floor(z: Dictionary) -> int:
	return floori(population_of(z))


## 某方每秒的粮食 / 黄金产出 = 它拥有的各区划的（产能 × 该区划地块数）之和。
##
## ★ 这是经济从「全局按占领地块数 × 固定值」改成「按区划聚合」的落点：
##   抢区块 = 抢产能（见 docs/route.md 第十五节）。
## ★★ 区划**特化**（本轮）在这里生效：特化是**本区块自己的产能倍率**
##   （粮食 / 黄金 / 人口各自 +10%，见 `UpgradeRes.zone_spec_mult`），
##   乘在「产能 × 地块数」上 —— 与科技那套**全局每地块加产量**叠加（那边在 world 里加）。
## @return {"food": float, "gold": float}
func production_of(owner: String) -> Dictionary:
	var food := 0.0
	var gold := 0.0
	if owner == "":
		return {"food": 0.0, "gold": 0.0}
	for z in zones:
		if String(z["owner"]) != owner:
			continue
		var p: Dictionary = z["production"]
		var n := float(z["tile_count"])
		var mult := _spec_mult(z)
		food += float(p.get("food", 0.0)) * n * float(mult["food"])
		gold += float(p.get("gold", 0.0)) * n * float(mult["gold"])
	return {"food": food, "gold": gold}


## 这个区划的产能倍率（特化给的；没特化 → 全 1.0）。
##
## ★ 走 logic/upgrade.gd 的那一份实现（**唯一**判据在那儿：spec_done 才生效、
##   读条中不算），这里只做转发 —— 与「视图不许自己发明判定」同一条规矩，
##   逻辑层也不该有第二份「特化到底生不生效」。
func _spec_mult(z: Dictionary) -> Dictionary:
	if cfg == null:
		return {"food": 1.0, "gold": 1.0, "population": 1.0}
	return UpgradeRes.zone_spec_mult(z, cfg)


## ---- 路线 1：读地图里的区块网格（地图编辑器导出的地图）----
##
## 网格里 -1（或地图外的虚线格）→ 不属于任何区块。
## 名字表缺项 → 叫「区块N号」（与编辑器里的默认名同一套）。
## 没有任何地块的区块也会建出来：地图作者可能「先建区块、后划地块」，
## 这样它的归属 / 读条状态在游戏里与地图上看到的一致。
func _build_from_grid(map, grid: Array, names: Dictionary, flist: Array) -> void:
	zones = []
	lookup = []
	lookup.resize(cols * rows)
	lookup.fill(-1)
	center_lookup = []
	center_lookup.resize(cols * rows)
	center_lookup.fill(-1)

	var by_id: Dictionary = {}
	for y in mini(rows, grid.size()):
		var row_v: Variant = grid[y]
		for x in cols:
			var zid := -1
			if typeof(row_v) == TYPE_ARRAY:
				var row_arr: Array = row_v
				if x < row_arr.size():
					zid = int(row_arr[x])
			elif typeof(row_v) == TYPE_STRING:
				# 手写地图可能用 "0 1 1 -1" 这种写法
				var parts := String(row_v).replace(",", " ").split(" ", false)
				if x < parts.size():
					zid = int(parts[x])
			if zid < 0:
				continue
			if not _tile_exists(map, x, y):
				continue
			var z: Dictionary = by_id.get(zid, {})
			if z.is_empty():
				z = _new_zone(zid, String(names.get(zid, "区块%d号" % (zid + 1))), flist)
				by_id[zid] = z
				zones.append(z)
			(z["tiles"] as Array).append(Vector2i(x, y))
			lookup[y * cols + x] = zid

	# 一行都没划到、但名字表里登记过的区块也要在（否则地图作者建的空区块会凭空消失）
	for key in names.keys():
		var zid2 := int(key)
		if by_id.has(zid2):
			continue
		var z2 := _new_zone(zid2, String(names[key]), flist)
		by_id[zid2] = z2
		zones.append(z2)

	zones.sort_custom(func(a, b): return int(a["id"]) < int(b["id"]))
	_finish_zones()


## ---- 路线 2：老地图的「横竖均分」占位区块（行为必须与原实现逐位一致）----
func _build_even(cfg: ConfigRes, flist: Array) -> void:
	zones = []
	lookup = []
	lookup.resize(cols * rows)
	lookup.fill(-1)
	center_lookup = []
	center_lookup.resize(cols * rows)
	center_lookup.fill(-1)

	var zone_cols: int = cfg.zone_cols
	var zone_rows: int = cfg.zone_rows
	for zy in zone_rows:
		for zx in zone_cols:
			var x0: int = (zx * cols) / zone_cols
			var x1: int = (((zx + 1) * cols) / zone_cols) - 1
			var y0: int = (zy * rows) / zone_rows
			var y1: int = (((zy + 1) * rows) / zone_rows) - 1
			var z := _new_zone(zy * zone_cols + zx, "%s%d" % [ROW_LETTERS.substr(zy, 1), zx + 1], flist)
			z["x0"] = x0
			z["y0"] = y0
			z["x1"] = x1
			z["y1"] = y1
			z["tile_count"] = (x1 - x0 + 1) * (y1 - y0 + 1)
			for y in range(y0, y1 + 1):
				for x in range(x0, x1 + 1):
					(z["tiles"] as Array).append(Vector2i(x, y))
					lookup[y * cols + x] = int(z["id"])
			zones.append(z)


## 地块在不在（地图外的虚线格不属于任何区块）
func _tile_exists(map, x: int, y: int) -> bool:
	if map == null or not map.has_method("tile_exists"):
		return true
	return bool(map.tile_exists(x, y))


## 按地块明细算包围盒与地块数（渲染画底色用包围盒，资源产出按真实地块数）
func _finish_zones() -> void:
	for z in zones:
		var tiles: Array = z["tiles"]
		z["tile_count"] = tiles.size()
		if tiles.is_empty():
			z["x0"] = 0
			z["y0"] = 0
			z["x1"] = -1
			z["y1"] = -1
			continue
		var min_x: int = int((tiles[0] as Vector2i).x)
		var max_x: int = min_x
		var min_y: int = int((tiles[0] as Vector2i).y)
		var max_y: int = min_y
		for t in tiles:
			var tile: Vector2i = t
			min_x = mini(min_x, tile.x)
			max_x = maxi(max_x, tile.x)
			min_y = mini(min_y, tile.y)
			max_y = maxi(max_y, tile.y)
		z["x0"] = min_x
		z["y0"] = min_y
		z["x1"] = max_x
		z["y1"] = max_y



## 该状态里所有会参与占领的阵营（玩家方 + NPC）
static func _capture_factions(factions: Array) -> Array:
	var out: Array = []
	if factions.is_empty():
		out.append(FactionRes.DEFAULT_FACTION)
	else:
		for f in factions:
			out.append(f)
	if not out.has(FactionRes.NPC_FACTION):
		out.append(FactionRes.NPC_FACTION)
	return out


## 取得某个地块所属区块（越界返回 null）
func zone_at(x: int, y: int) -> Variant:
	if x < 0 or y < 0 or x >= cols or y >= rows:
		return null
	var id: int = lookup[y * cols + x]
	if id < 0:
		return null
	return zones[id]


## 区块内是否存在某方建筑
func _zone_has_building(building_list: Array, zone_id: int, owner: String) -> bool:
	for b in building_list:
		if b.zone_id == zone_id and b.owner == owner and b.alive:
			return true
	return false


## 重算建筑带给区块的归属（建筑建成 / 被毁时调用，不每帧跑）。
##
## 任意玩家阵营的建筑都能把区块直接收归自己 —— 旧实现只认 'player'。
## ⚠️ 副作用（照搬 HTML 版，可玩性后议）：一个大本营会让**整个区块瞬间**归己方，
##    于是出生区的「站 4 秒占领」玩法在那个区块里失效。开关在 config.zone.zone_owned_by_building。
##
## 与 HTML 版的一处刻意差异：只在「该区块当前无主」时收归，而不是每个玩家阵营都无条件改写。
## 否则两个阵营在同一区块都有建筑时，归属会每帧翻转（单机下两者等价）。
func refresh_building_ownership(cfg: ConfigRes, building_list: Array, factions: Array) -> void:
	if not cfg.zone_owned_by_building:
		return
	var flist := _capture_factions(factions)
	for z in zones:
		if z["owner"] != "":
			continue
		for f in flist:
			if not FactionRes.is_player_faction(f):
				continue
			if _zone_has_building(building_list, z["id"], f):
				z["owner"] = f
				z["progress_by"][f] = 1.0
				z["progress"] = 1.0
				z["claimed_by"] = "building"
				break


## 每帧推进区块占领。
##
## ★★ 规则（手玩定的完整版 —— 与「逐阵营各涨各的」完全不同，改之前先读完）：
##
##   1. 区块里**只有一个阵营**的活单位、且它不是这块地的主人 → **只有它**读条
##      （每秒 +1/capture_time_sec × `speed_multiplier(在场人数)`），读满 → 归属翻给它、
##      其余阵营进度清零。
##   2. 区块里有**两个及以上**阵营的活单位 → **谁都不涨**：
##      正在读的那条**冻住**（不涨、不降、不清零）—— UI 会给它加一圈白描边。
##   3. 有进度、但那一方**不在场**（全移出区块 / 被打光）→ 按 decay_per_sec **缓慢回落**。
##      「A 正在占、B 进来把 A 杀光 → A 的条慢慢退回 0」就走这一条。
##   4. ★ **严格阻塞**：区块里只要还有别人没归零的进度，新来的这一方**不开读**
##      —— 也就是「A 归零之后才轮到读 B 的条」。这条保证了**同一时刻最多只有一条进度条**，
##      也是 UI 只画一条的前提（手玩明确要求）。
##   5. 主人在自己的地里什么都不读（它只负责「挡住别人」）。
##
## ★★ 人数加成（本轮需求，改掉了原来「同阵营多单位不叠加」那条）：
##   同一个区块里**同一方**的单位越多，读条越快；曲线与上限见 `speed_multiplier()`。
##   只有 1 个单位时倍率正好是 1.0 —— 所以「占领速度缩小为 1/8」那条需求
##   说的是**单兵基准速度**，两条需求互不冲突。
##
## ⚠️ 与更早的旧实现的区别：旧版是双方**各涨各的**、谁先满谁拿走。
##    现在双方同场时谁都涨不了，所以「带一队兵站在别人家里」不再能靠人多抢先，
##    必须先把对方清出场 —— 人多只让**读条更快**，不能让对方读不动。
func update(cfg: ConfigRes, dt: float, units: Array, factions: Array) -> void:
	var capture_time: float = maxf(0.001, cfg.capture_time_sec)
	var decay: float = maxf(0.0, cfg.decay_per_sec)
	var max_mult: float = maxf(1.0, cfg.zone_speed_max_mult)
	var curve_k: float = maxf(0.0, cfg.zone_speed_curve_k)
	var curve_p: float = maxf(0.01, cfg.zone_speed_curve_power)
	var flist := _capture_factions(factions)

	# 1) 逐区块清点「站着哪些阵营、各几个活单位」
	#    ⚠️ 这里必须存**数目**（不是布尔）：人数加成要它。原来的 bool 集合会让
	#       「10 个兵」和「1 个兵」看起来一模一样。
	var present_by: Dictionary = {}
	for z in zones:
		present_by[int(z["id"])] = {}
	for u in units:
		if not u.alive:
			continue
		var z = zone_at(u.tx, u.ty)
		if z == null:
			continue
		var counts: Dictionary = present_by[int(z["id"])]
		counts[u.faction] = int(counts.get(u.faction, 0)) + 1

	# 2) 逐区块推进
	for z in zones:
		_advance_zone(z, present_by[int(z["id"])], flist,
			capture_time, decay, max_mult, curve_k, curve_p, dt)


## ★ 人数加成曲线：n 个同阵营单位在场时的读条倍率。
##
## 需求原话：「当 1 个单位占领某个区域时，速率为 x1，随着进入的友方单位增加，
##            速率会逐渐增加，到 10 人时速率趋近于最大值 x2」。
## 已确认的实现口径：
##   · 1 人 = **基准速度**（也就是 capture_time_sec 定义的那个速率）= x1；
##     10 人趋近 x2 = 2 倍 —— 所以「占领速度缩小为 1/8」与这条互不冲突。
##   · 曲线形状：**先慢后快** —— 前几个人收益小，人越多每多一个的收益越大。
##   · 只作用于**读条增长**；进度回落（decay_per_sec）与人数无关。
##   · k = 2.5，指数 p 见 cfg.zone_speed_curve_power。
##
## 公式：先归一化 `t = (n-1) / (n-1 + k)`，再取幂：
##   `倍率 = 1 + (max_mult - 1) × t^p`
##
## ★★ 为什么是 `t^p`（p > 1）而不是 smoothstep —— 本轮返工**两次**才定下来，
##    两版错法的共同点是「先快后慢」，与需求正好相反（数字都是引擎实算的）：
##      第 1 版 `1 + (max-1)·t`（等价于 p=1）：第 2 个人就 +0.286，之后一路变小；
##      第 2 版 smoothstep `t²(3-2t)`：t 的凹性太强，smoothstep 只把拐点压到 t≈0.42，
##              在 n=1..10 这段（t 只走到 0.78）里它**仍然是凹的** ⇒ 最大增量仍在最前面。
##    在 n=1..10 上要「先慢后快」，f(t) 必须在这段区间上**凸**（f''>0），
##    也就是 p > 1：`t^p` 的导数 p·t^(p-1) 随 t 单调递增 ⇒ 前几个人最慢。
##
## 性质（都有断言钉住）：
##   · n = 1 → t = 0 → 正好 1.0（无论 k / p 取多少）；
##   · 单调不减，且 t^p ≤ t < 1 ⇒ 倍率**永远不超过 max_mult**（10 人只是趋近）；
##   · k 在分母上 ⇒ **k 越大曲线越平缓**（要更多人才能接近上限）；
##     p 越大 ⇒ 前期越慢、越「憋着」（p=1 就是「先快后慢」的错形状）。
## 默认参数（k=2.5、p=1.7）引擎实算：2人 1.119　3人 1.252　4人 1.357　7人 1.553　10人 1.659；
##   每多一人的增量：+0.119　+0.133　+0.105　+0.081　+0.064…（峰值在第 2~3 人之间）。
static func speed_multiplier(n: int, max_mult: float, curve_k: float, curve_power: float = 1.7) -> float:
	if n <= 1:
		return 1.0
	var cap: float = maxf(1.0, max_mult)
	var k: float = maxf(0.0, curve_k)
	var p: float = maxf(0.01, curve_power)
	var t: float = float(n - 1) / (float(n - 1) + k)
	return 1.0 + (cap - 1.0) * pow(t, p)


## 推进一个区块一帧（抽出来只是为了让上面那段读起来像规则本身）
func _advance_zone(z: Dictionary, present: Dictionary, flist: Array,
		capture_time: float, decay: float, max_mult: float, curve_k: float,
		curve_p: float, dt: float) -> void:
	if not z.has("progress_by"):
		z["progress_by"] = {}
	var by: Dictionary = z["progress_by"]
	for f in flist:
		if not by.has(f):
			by[f] = 0.0
	var owner := String(z["owner"])

	# 「谁手上还有没走完的进度」——**跳过主人**：主人那份 1.0 只表示「这块地是我的」，
	# 不该被当成「还有人在抢占」而卡住后来者。
	var holder := ""
	var holder_v := 0.0
	for f in flist:
		if FactionRes.same_side(owner, f):
			continue
		if float(by[f]) > holder_v:
			holder_v = float(by[f])
			holder = f

	# 这一帧谁有资格读条：区块里**恰好只有一个阵营**的兵，且它不是主人
	var reader := ""
	if present.size() == 1:
		var only := String(present.keys()[0])
		if not FactionRes.same_side(owner, only):
			reader = only
	# ★ 规则 4：别人还有进度没归零 → 这一方不开读（等它退完）
	if reader != "" and holder != "" and holder != reader:
		reader = ""

	var state := ""
	var bar_faction := ""
	var bar_value := 0.0

	if reader != "":
		# ★ 人数加成：读条方在这个区块里有几个活单位（present 存的就是数目）
		var n: int = int(present.get(reader, 0))
		var mult: float = speed_multiplier(n, max_mult, curve_k, curve_p)
		by[reader] = clampf(float(by[reader]) + dt / capture_time * mult, 0.0, 1.0)
		if float(by[reader]) >= 1.0:
			# 读满：易主 + 其余清零（主人那份留 1.0 作为「这是我的地」的标记）
			z["owner"] = reader
			z["claimed_by"] = "unit"
			for f in flist:
				by[f] = 0.0
			by[reader] = 1.0
			state = ""                 # 已经是它的地：不画条（底色表示归属）
		else:
			state = "reading"
			bar_faction = reader
			bar_value = float(by[reader])
	else:
		# 没人在读：凡是「有进度」的，按它的人还在不在场分成两种状态
		for f in flist:
			if FactionRes.same_side(owner, f):
				continue
			if float(by[f]) <= 0.0:
				continue
			if present.has(f):
				# 人在场却读不了（区块里还有别人）→ **冻住**：值一动不动
				#
				# ⚠️ 冻住的是「读条增长」，不是「人数加成」：人数只影响读条快慢，
				#    而这里根本没在读（区块里有多方），所以没有倍率可乘。
				if state == "":
					state = "frozen"
					bar_faction = f
					bar_value = float(by[f])
			else:
				# 人不在场（移出 / 被打光）→ 缓慢回落
				# ⚠️ 回落**不乘人数倍率**（需求确认：加成只管读条增长）。
				#    只有**回落之后还有值**才标成 decaying：退到 0 的那一帧就没什么可画了
				#    （标成 decaying + value 0 会让 UI 以为「还有条」，也会拖住后来者多一帧）
				var next_v := clampf(float(by[f]) - decay * dt, 0.0, 1.0)
				by[f] = next_v
				if next_v > 0.0 and state == "":
					state = "decaying"
					bar_faction = f
					bar_value = next_v

	z["capture_state"] = state
	z["capture_faction"] = bar_faction
	z["progress"] = bar_value


## 给渲染用：这一块现在该画哪一条进度条（逻辑层每帧算好，视图只取色与状态）。
##
## ★ 严格阻塞（规则 4）保证了**同一时刻最多只有一条** —— 所以视图只画一条就够，
##   不需要（也不该）自己去比较几方的进度（那是 5.20 记过的坑）。
##
## @return {"faction": String, "value": float, "state": String}
##   state：""         不用画（没人占 / 已经是某方的地）
##          "reading"  在涨
##          "frozen"   人在场但区块里还有别人 → 冻住（UI 加白描边）
##          "decaying" 人不在场（移出 / 被打光）→ 缓慢回落
func capture_bar(z: Dictionary) -> Dictionary:
	return {
		"faction": String(z.get("capture_faction", "")),
		"value": float(z.get("progress", 0.0)),
		"state": String(z.get("capture_state", "")),
	}


## 统计某方拥有的地块数（资源产出依据）
func owned_tile_count(owner: String) -> int:
	var n := 0
	for z in zones:
		if z["owner"] == owner:
			n += int(z["tile_count"])
	return n


## 某方拥有的区块名列表（事件日志用）
func owned_zone_names(owner: String) -> Array[String]:
	var out: Array[String] = []
	for z in zones:
		if z["owner"] == owner:
			out.append(String(z["name"]))
	return out
