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
##   2. 地图没有 zones 网格（老的 map_01.json）→ 照旧横竖均分成
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

const ROW_LETTERS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

var zones: Array = []
## 地块索引 → 区块 id（-1 = 不属于任何区块）
var lookup: Array = []
var cols: int = 0
var rows: int = 0


static func build_from_map(map, cfg: ConfigRes, factions: Array) -> RefCounted:
	var zs = new()
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
	}


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
##      （每秒 +1/capture_time_sec），读满 → 归属翻给它、其余阵营进度清零。
##   2. 区块里有**两个及以上**阵营的活单位 → **谁都不涨**：
##      正在读的那条**冻住**（不涨、不降、不清零）—— UI 会给它加一圈白描边。
##   3. 有进度、但那一方**不在场**（全移出区块 / 被打光）→ 按 decay_per_sec **缓慢回落**。
##      「A 正在占、B 进来把 A 杀光 → A 的条慢慢退回 0」就走这一条。
##   4. ★ **严格阻塞**：区块里只要还有别人没归零的进度，新来的这一方**不开读**
##      —— 也就是「A 归零之后才轮到读 B 的条」。这条保证了**同一时刻最多只有一条进度条**，
##      也是 UI 只画一条的前提（手玩明确要求）。
##   5. 主人在自己的地里什么都不读（它只负责「挡住别人」）。
##
## ⚠️ 与旧实现的区别：旧版是双方**各涨各的**、谁先满谁拿走。现在双方同场时谁都涨不了，
##    所以「带一队兵站在别人家里」不再能靠人多抢先，必须先把对方清出场。
## 注意：**同一阵营的多个单位不会叠加加速**（原话是「持续一段时间」）。
func update(cfg: ConfigRes, dt: float, units: Array, factions: Array) -> void:
	var capture_time: float = maxf(0.001, cfg.capture_time_sec)
	var decay: float = maxf(0.0, cfg.decay_per_sec)
	var flist := _capture_factions(factions)

	# 1) 每个区块里现在站着哪些阵营的活单位（阵亡的不算）
	var present_by: Dictionary = {}
	for z in zones:
		present_by[int(z["id"])] = {}
	for u in units:
		if not u.alive:
			continue
		var z = zone_at(u.tx, u.ty)
		if z == null:
			continue
		(present_by[int(z["id"])] as Dictionary)[u.faction] = true

	# 2) 逐区块推进
	for z in zones:
		_advance_zone(z, present_by[int(z["id"])], flist, capture_time, decay, dt)


## 推进一个区块一帧（抽出来只是为了让上面那段读起来像规则本身）
func _advance_zone(z: Dictionary, present: Dictionary, flist: Array, capture_time: float, decay: float, dt: float) -> void:
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
		by[reader] = clampf(float(by[reader]) + dt / capture_time, 0.0, 1.0)
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
				if state == "":
					state = "frozen"
					bar_faction = f
					bar_value = float(by[f])
			else:
				# 人不在场（移出 / 被打光）→ 缓慢回落
				# ⚠️ 只有**回落之后还有值**才标成 decaying：退到 0 的那一帧就没什么可画了
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
