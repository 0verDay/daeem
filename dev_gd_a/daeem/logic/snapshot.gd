## snapshot.gd —— 世界 ↔ 数据（对应 HTML 版 js/net.js 的 makeSnapshot / applySnapshot）
##
## 本轮**只用于调试 / 回放 / 存档的雏形**，不做网络。但字段格式就是按第 1 轮的
## 网络包体设计的，所以现在就满足：
##   - 字段名用短名（i/f/k/x/y/h）—— 省带宽，且迫使自己只同步必要字段
##   - **只发结果，不发路径**：单位发位置与朝向，不发 path
##     （HTML 版的经验：路径由房主算，否则会出现路径欺骗，而且只有房主知道最新的城墙位置）
##   - 坐标保留 2 位小数（round2）
##   - **缺字段要容忍**：缺字段 = 保持本地现状不变，而不是当成 false / 0。
##     HTML 版踩过：一条不含 match 字段的旧快照把已经结算的画面打回进行中
##     （见 docs/pitfalls.md 3.6）
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")
const FactionRes = preload("res://logic/faction.gd")
const BuildingRes = preload("res://logic/building.gd")
const UnitRes = preload("res://logic/unit.gd")


static func round2(v: float) -> float:
	return roundf(v * 100.0) / 100.0


## 建面板快照。
## ★ 刻意**不**同步：terrain / 相机 / 视口 / 日志 / path —— 那些是本地的东西，
##   或者属于「过程」而不是「结果」。
static func to_snapshot(world) -> Dictionary:
	var units_out: Array = []
	for u in world.units:
		if not u.alive:
			continue                 # 阵亡的单位不发 —— 客机上看它就「消失了」，复活后再出现
		units_out.append({
			"i": u.id,
			"f": u.faction,
			"k": u.kind,
			"x": round2(u.pos.x),
			"y": round2(u.pos.y),
			"h": int(round(u.hp)),
			"m": 1 if u.moving else 0,
			# 朝向是**向量**（八方向之后 ±1 不够用了）。
			# ⚠️ 字段名仍是最短的 "fa"，但类型从 int 变成了 [x, y] 两元数组 ——
			#    第 1 轮联机时两边必须同版本，否则客机会把数组当 int 读出 0。
			"fa": [round2(u.facing.x), round2(u.facing.y)],
			# 队长 id（空 = 自己就是队长）。客机靠它把「选中将领 = 选中整队」做出来，
			# 否则客机侧点将领时只有自己会被选中（单机与联机行为会不一致）。
			"ld": u.leader_id if u.leader_id != "" else null,
			"hk": u.hotkey if u.hotkey != "" else null,
		})

	var buildings_out: Array = []
	for b in world.building_list:
		if not b.alive:
			continue
		buildings_out.append({
			"t": b.type, "x": b.tx, "y": b.ty, "o": b.owner, "h": int(round(b.hp)),
		})

	var zones_out: Array = []
	for z in world.zones.zones:
		# ★ 除了归属与进度，还要带上「这条进度条属于谁、处于什么状态」——
		#   客机只靠 o/p 画不出进度条（owner 与「谁在读条」是两回事，见 zone.update）。
		zones_out.append({
			"o": String(z["owner"]),
			"p": round2(float(z["progress"])),
			"cf": String(z.get("capture_faction", "")),
			"cs": String(z.get("capture_state", "")),
		})

	return {
		"units": units_out,
		"buildings": buildings_out,
		"zones": zones_out,
		"res": [round(float(world.resources["food"]) * 10.0) / 10.0, round(float(world.resources["gold"]) * 10.0) / 10.0],
		"owned": world.owned_tiles,
		"time": round2(world.time),
	}


## 应用权威快照。
## 按 id 对齐单位：有的就地更新，没有的新建（别人刚刷出来的），快照里没有的删掉。
##
## ⚠️ 本轮不调用它跑真实对局（没有联机），但**它的语义是第 1 轮的地基**，
##    所以现在就把「缺字段容忍」写对，并用测试盯住。
static func apply_snapshot(world, cfg: ConfigRes, snap: Dictionary) -> void:
	if snap.is_empty():
		return

	var seen: Dictionary = {}
	for su in snap.get("units", []):
		var uid := String(su.get("i", ""))
		if uid == "":
			continue
		seen[uid] = true
		var u = world.unit_by_id(uid)
		if u == null:
			var kind := String(su.get("k", UnitRes.KIND_GENERAL))
			var fac := String(su.get("f", FactionRes.DEFAULT_FACTION))
			u = UnitRes.create(
				cfg, uid, cfg.unit_name_of(kind),
				Vector2i(floori(float(su.get("x", 0.0))), floori(float(su.get("y", 0.0)))),
				fac, kind,
				String(su.get("hk", "")) if su.get("hk", null) != null else "",
				String(su.get("ld", "")) if su.get("ld", null) != null else ""
			)
			world.units.append(u)
		u.alive = true
		u.faction = String(su.get("f", u.faction))
		u.hp = float(su.get("h", u.hp))
		u.moving = bool(su.get("m", 0))
		# 队长 id：缺字段就保持本地现状（同上，别把「没有队长」当成默认值覆盖掉）
		var ld: Variant = su.get("ld", null)
		if typeof(ld) == TYPE_STRING:
			u.leader_id = ld
		# 朝向：新格式是 [x, y]；**缺字段就保持本地现状**（不要把数组默认成 0，
		# 那会让所有远端单位突然朝向零向量，见 docs/pitfalls.md 3.6 的同类教训）
		var fa: Variant = su.get("fa", null)
		if typeof(fa) == TYPE_ARRAY and (fa as Array).size() >= 2:
			var faa := fa as Array
			var fv := Vector2(float(faa[0]), float(faa[1]))
			if fv.length() > 1e-6:
				u.facing = fv.normalized()
		if su.get("hk", null) != null:
			u.hotkey = String(su["hk"])
		# ★ 权威位置：必须同时写回 pos 与 tx/ty。
		#   只写插值用的临时字段是不够的 —— 渲染看起来正常，但逻辑里的
		#   pos / tx / ty 会一直是旧值，于是点选判定、射程判定、HUD 全都是错的。
		u.pos = Vector2(float(su.get("x", u.pos.x)), float(su.get("y", u.pos.y)))
		u.sync_tile(world.map)

	# 快照里没有的单位 = 已经阵亡（客机上的世界完全以快照为准）
	var keep: Array = []
	for u in world.units:
		if seen.has(u.id):
			keep.append(u)
	world.units = keep

	# 建筑：整表替换（数量少、结构简单，比按 id 对齐更不容易出错）
	_world_sync_buildings(world, cfg, snap.get("buildings", []))

	# 区块归属（按序号对齐 —— 区块划分由地图决定，两边必然同序）
	var zone_in: Array = snap.get("zones", [])
	for i in mini(world.zones.zones.size(), zone_in.size()):
		var z: Dictionary = world.zones.zones[i]
		var sz: Dictionary = zone_in[i]
		z["owner"] = String(sz.get("o", z["owner"]))
		z["progress"] = float(sz.get("p", z["progress"]))
		# ★ 缺字段要容忍：老快照没有 cf/cs 时保持本地现状（见 pitfalls 3.6）
		if sz.has("cf"):
			z["capture_faction"] = String(sz["cf"])
		if sz.has("cs"):
			z["capture_state"] = String(sz["cs"])

	if snap.has("res"):
		var res: Array = snap["res"]
		if res.size() >= 2:
			world.resources["food"] = float(res[0])
			world.resources["gold"] = float(res[1])
	if snap.has("owned"):
		world.owned_tiles = int(snap["owned"])
	if snap.has("time"):
		world.time = float(snap["time"])


## 客机：让本地建筑表与快照一致（按 (type,tx,ty,owner) 对齐，保留现有对象以减少闪烁）
static func _world_sync_buildings(world, cfg: ConfigRes, list: Array) -> void:
	var existing: Dictionary = {}
	for b in world.building_list:
		existing["%s:%d:%d:%s" % [b.type, b.tx, b.ty, b.owner]] = b

	var out: Array = []
	for sb in list:
		var key := "%s:%d:%d:%s" % [String(sb.get("t", "")), int(sb.get("x", -1)), int(sb.get("y", -1)), String(sb.get("o", ""))]
		var b = existing.get(key, null)
		if b != null:
			existing.erase(key)
			b.hp = float(sb.get("h", b.hp))
			b.alive = true
			out.append(b)
		else:
			var z = world.zones.zone_at(int(sb.get("x", -1)), int(sb.get("y", -1)))
			var nb := BuildingRes.create(
				cfg, String(sb.get("t", "wall")), int(sb.get("x", -1)), int(sb.get("y", -1)),
				String(sb.get("o", FactionRes.DEFAULT_FACTION)), int(z["id"]) if z != null else -1
			)
			nb.hp = float(sb.get("h", nb.hp))
			out.append(nb)
	world.building_list = out
	world.rebuild_building_index()
