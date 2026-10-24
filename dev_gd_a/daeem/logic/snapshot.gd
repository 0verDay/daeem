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
const ProjectileRes = preload("res://logic/projectile.gd")
const ObjectiveRes = preload("res://logic/objective.gd")


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
			# ★ 单位类型（兵种）：**必须发**，因为 kind 分不出将领的兵种 ——
			#   三个开局将领的 kind 都是 "general"，只有 ut 说得清谁是长枪兵谁是骑手。
			#   客机靠它查数值（血/速度/射程）与画图标，缺了就会把将领画成同一种兵。
			"ut": u.unit_type,
			"x": round2(u.pos.x),
			"y": round2(u.pos.y),
			"h": int(round(u.hp)),
			# ★ 血量上限（科技 / 等级加成之后的值）：客机画血条比例要用；
			#   缺字段 = 保持本地现状（老快照没有这一项）。
			"mh": int(round(u.hp_max)),
			# ★★ 士气（本轮新增）：整支部队共享的权威状态，客机不发详情栏就画不出背景板颜色。
			#    沿用「缺字段 = 保持本地现状」的规矩（见 apply 那一段）。
			"mo": int(round(u.morale)),
			"m": 1 if u.moving else 0,
			# 朝向是**向量**（八方向之后 ±1 不够用了）。
			# ⚠️ 字段名仍是最短的 "fa"，但类型从 int 变成了 [x, y] 两元数组 ——
			#    第 1 轮联机时两边必须同版本，否则客机会把数组当 int 读出 0。
			"fa": [round2(u.facing.x), round2(u.facing.y)],
			# 队长 id（空 = 自己就是队长）。客机靠它把「选中将领 = 选中整队」做出来，
			# 否则客机侧点将领时只有自己会被选中（单机与联机行为会不一致）。
			"ld": u.leader_id if u.leader_id != "" else null,
			"hk": u.hotkey if u.hotkey != "" else null,
			# ★ 招募队列（将领 = 兵营）：信息栏里那五个格子是**权威状态**画出来的，
			#   客机不发就只能是空的。三个短字段：正在读条的兵种 / 剩余秒 / 总秒数，
			#   外加排队的兵种数组（tq = train queue）。
			"tk": u.train_kind if u.train_kind != "" else null,
			"tr": round2(u.train_remaining),
			"tt": round2(u.train_total),
			"tq": (u.train_queue.duplicate() if not u.train_queue.is_empty() else null),
			# ★★ 将领濒死（本轮新增）：这是**权威状态**，客机不发就只能看到一个
			#   站在原地的将领（它会照旧被画成能打、也能被点成目标，两边就不一致了）。
			#   · nd = 是否濒死；nh = 已回复出来的血量（比例口径见 unit.nd_hp_ratio）；
			#   · nt = 离下一次回复还有几秒；nv/nvt = 再起读条的剩余 / 总秒数。
			#   ⚠️ 与 tk 那一组同一条约定：**nd 在不在**决定新旧格式，
			#      老快照没有 nd ⇒ 整组保持本地现状（不要把濒死状态静默清掉）。
			"nd": 1 if u.downed else 0,
			"nh": round2(u.nd_regen_hp),
			"nt": round2(u.nd_regen_timer),
			"nv": round2(u.revive_remaining),
			"nvt": round2(u.revive_total),
			# ★★ 中立化（大本营被拆后的停摆状态）：1 = 已中立化。
			#   缺字段 = 老快照 ⇒ 保持本地现状。
			"nz": 1 if u.neutralized else 0,
			# ★★ 将领特性（部队光环）：gt = 将领自己抽到的特性（决定属下继承谁），
			#   ga = 这个单位实际享受的光环（附属兵必然与队长相同）。两个都要发：
			#   客机重建单位的顺序不保证「队长先于附属兵」，靠查队长推导会漏。
			#   缺字段 = 老快照 ⇒ 保持本地现状（与其它字段同一条约定）。
			"gt": u.general_trait if u.general_trait != "" else null,
			"ga": u.aura_trait_id if u.aura_trait_id != "" else null,
		})

	var buildings_out: Array = []
	for b in world.building_list:
		if not b.alive:
			continue
		buildings_out.append({
			"t": b.type, "x": b.tx, "y": b.ty, "o": b.owner, "h": int(round(b.hp)),
			# ★ 本轮补：等级 / 血量上限 / 升级读条（客机要画等级、血条比例与读条）。
			#   字段短名沿用既有口径；缺字段 = 保持本地现状（见 apply 那一段）。
			"lv": int(b.level),
			"mh": int(round(b.hp_max)),
			"uk": 1 if b.is_upgrading() else 0,
			"ur": round2(b.upgrade_remaining),
			"ut": round2(b.upgrade_total),
			"nz": 1 if b.neutralized else 0,
			# ★★ 大本营的将领重生队列（客机要画同一条进度条）。
			#   非 base 建筑也会带 rq = 0（用来清掉客机可能残留的旧状态）。
			"rq": b.respawn_count(),
			"rr": round2(b.respawn_remaining if b.is_respawning() else 0.0),
			"rt": round2(b.respawn_total),
			"rn": b.respawn_current_name() if b.is_respawning() else null,
		})

	var zones_out: Array = []
	for z in world.zones.zones:
		# ★ 除了归属与进度，还要带上「这条进度条属于谁、处于什么状态」——
		#   客机只靠 o/p 画不出进度条（owner 与「谁在读条」是两回事，见 zone.update）。
		# ★ 区划人口也一起发：它在房主侧累积，客机点开中心看详情时得显示同一个数。
		zones_out.append({
			"o": String(z["owner"]),
			"p": round2(float(z["progress"])),
			"cf": String(z.get("capture_faction", "")),
			"cs": String(z.get("capture_state", "")),
			"pop": round2(float(z.get("population", 0.0))),
			# ★ 本轮补：区划特化（正在读哪一单 / 读条进度 / 已经生效的那一档）。
			#   客机点开区划中心时「操作」页要画这些；缺字段 = 保持本地现状。
			"sk": String(z.get("spec_kind", "")),
			"sr": round2(float(z.get("spec_remaining", 0.0))),
			"st": round2(float(z.get("spec_total", 0.0))),
			"sd": String(z.get("spec_done", "")),
			"sx": 1 if bool(z.get("spec_cancel", false)) else 0,
		})

	# ★★ 射箭投掷物（本轮新增）：在飞的投掷物也是**权威状态**（伤害在命中那一刻结算），
	#    所以照 units / buildings 的口径一起发。字段全用短名：
	#      sx/sy = 起点，ex/ey = 终点（目标当前位置），t = 进度，el/du = 已飞/总时长，
	#      dmg = 命中伤害；目标与来源各用「单位 id（tu/su）」或「建筑 key（tk/sk）」。
	#    ⚠️ 解析不到时置空 —— 投掷物会飞完自然消失、不造成伤害（不崩）。
	var proj_out: Array = []
	for p in world.projectiles:
		proj_out.append({
			"f": String(p.faction),
			"sx": round2(p.start.x), "sy": round2(p.start.y),
			"ex": round2(p.end.x), "ey": round2(p.end.y),
			"t": round2(p.t), "el": round2(p.elapsed), "du": round2(p.duration),
			"dmg": round2(p.damage),
			"tu": _unit_id_of(p.target), "tk": _building_key_of(p.target),
			"su": _unit_id_of(p.source), "sk": _building_key_of(p.source),
		})

	# ★★ 按席位资源（合作）：`res` 只够单机；客机必须能分清「我这一份」与「队友那一份」。
	#    只发**玩家席位**，AI 的资源池不下发（AI 没有资源库，见 resource_pool_for）。
	var pres_out: Dictionary = {}
	for f in world.player_seats:
		var pool: Variant = world.player_resources.get(String(f), null)
		if typeof(pool) == TYPE_DICTIONARY:
			pres_out[String(f)] = [
				round(float((pool as Dictionary).get("food", 0.0)) * 10.0) / 10.0,
				round(float((pool as Dictionary).get("gold", 0.0)) * 10.0) / 10.0,
			]
	# 兜底：老路径 / 测试手工建的 world 可能 player_seats 为空，至少把本机席位发出去。
	if pres_out.is_empty() and String(world.my_faction) != "":
		pres_out[String(world.my_faction)] = [
			round(float(world.resources.get("food", 0.0)) * 10.0) / 10.0,
			round(float(world.resources.get("gold", 0.0)) * 10.0) / 10.0,
		]

	# ★★ 按席位科技：客机要画科技九格高亮（真正的启用状态仍在房主那一份里）。
	var tech_out: Dictionary = {}
	for f in world.player_seats:
		tech_out[String(f)] = world.active_tech_ids(String(f)).duplicate()

	# ★★ 将领招募池 / 冷却（本轮新增）：每个玩家席位发「当前三个槽位 + 冷却剩余 / 总秒数」。
	#    客机只读它画招募页（不抽牌）；抽牌 / 起冷却只发生在权威侧。
	var gp_out: Dictionary = {}
	for f in world.player_seats:
		gp_out[String(f)] = world.general_pool_snapshot(String(f))

	# ★★ 指挥官 AI 的指令 / 资源（合作 AI 队友的面板在客机也要显示）。
	#    只发 commander 阵营；键按 faction 排序（确定性）。
	var aid_out: Dictionary = {}
	var aid_keys: Array = world.ai_directives.keys()
	aid_keys.sort()
	for f in aid_keys:
		var d: Variant = world.ai_directives[f]
		if typeof(d) != TYPE_DICTIONARY:
			continue
		var dd: Dictionary = d
		aid_out[String(f)] = {
			"k": String(dd.get("kind", "")),
			"x": round2(float(dd.get("x", -1.0))),
			"y": round2(float(dd.get("y", -1.0))),
			"s": int(dd.get("serial", 0)),
			"t": round2(float(dd.get("since", 0.0))),
		}
	var air_out: Dictionary = {}
	var air_keys: Array = world.ai_faction_resources.keys()
	air_keys.sort()
	for f2 in air_keys:
		var p: Variant = world.ai_faction_resources[f2]
		if typeof(p) != TYPE_DICTIONARY:
			continue
		air_out[String(f2)] = [
			round(float((p as Dictionary).get("food", 0.0)) * 10.0) / 10.0,
			round(float((p as Dictionary).get("gold", 0.0)) * 10.0) / 10.0,
		]

	return {
		"units": units_out,
		"buildings": buildings_out,
		"zones": zones_out,
		"projectiles": proj_out,
		"pres": pres_out,
		"obj": ObjectiveRes.to_snapshot(world.objective_state),
		"tech": tech_out,
		"gp": gp_out,
		"aid": aid_out,
		"air": air_out,
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

	# ★★ 一次性建 id → unit 索引：`world.unit_by_id()` 是线性扫描，
	#    对每个快照单位都调一次就是 O(n²)（500 单位实测是客机侧最大的一笔开销）。
	var unit_index: Dictionary = {}
	for u in world.units:
		unit_index[String(u.id)] = u

	var seen: Dictionary = {}
	for su in snap.get("units", []):
		var uid := String(su.get("i", ""))
		if uid == "":
			continue
		seen[uid] = true
		var u = unit_index.get(uid, null)
		if u == null:
			var kind := String(su.get("k", UnitRes.KIND_GENERAL))
			var fac := String(su.get("f", FactionRes.DEFAULT_FACTION))
			# ★ 单位类型：缺字段（老快照）就按 kind 推 —— 普通单位推出来就是它自己，
			#   将领推出来是默认那一个（types[0]）。别把缺字段当成空串传进去，
			#   那会让 UnitRes.create 再去推一次（结果一样，但这里写出来更清楚）。
			var utype := String(su.get("ut", ""))
			if utype == "":
				utype = cfg.unit_type_of(kind)
			u = UnitRes.create(
				cfg, uid, cfg.unit_name_of(kind),
				Vector2i(floori(float(su.get("x", 0.0))), floori(float(su.get("y", 0.0)))),
				fac, kind,
				String(su.get("hk", "")) if su.get("hk", null) != null else "",
				String(su.get("ld", "")) if su.get("ld", null) != null else "",
				utype,
				# ★ 将领序号：按 kind 认（`general` / `general_N` → 同一个序号槽位），
				#   这样重建出来的将领同样带上 unit.general.stats 里那份数值覆盖。
				ConfigRes.general_index_of(kind)
			)
			world.units.append(u)
			unit_index[uid] = u
		u.alive = true
		u.faction = String(su.get("f", u.faction))
		# ⚠️ 单位类型（ut）**只在新建时读**，不在这里覆盖已有单位：
		#    一个单位的类型当局内不会变，而 hp_max / base_hp_max / unit_class
		#    都是创建时按类型算好的 —— 单独改 unit_type 会让它与血量上限对不上。
		#    （快照里带 ut 是为了**新单位**能被正确地建出来，见上面那段。）
		if su.has("mh"):
			u.hp_max = maxf(1.0, float(su["mh"]))
		u.hp = float(su.get("h", u.hp))
		if u.hp_max > 0.0:
			u.hp = clampf(u.hp, 0.0, u.hp_max)
		# ★ 士气：缺字段（老快照）就保持本地现状；有就夹到本地上限里写回。
		if su.has("mo"):
			u.morale = clampf(float(su["mo"]), 0.0, u.morale_max)
		if su.has("nz"):
			u.neutralized = int(su["nz"]) != 0
		u.moving = bool(su.get("m", 0))
		# 队长 id：缺字段就保持本地现状（同上，别把「没有队长」当成默认值覆盖掉）
		var ld: Variant = su.get("ld", null)
		if typeof(ld) == TYPE_STRING:
			u.leader_id = ld
		# ★★ 将领特性：有 gt ⇒ 这是将领本人，连同自己的光环一起恢复；
		#   否则有 ga ⇒ 附属兵 / 客机侧直接恢复它享受的那条光环。
		#   两个都缺 = 老快照 ⇒ 保持本地现状（不把已有光环清掉）。
		var gt: Variant = su.get("gt", null)
		if typeof(gt) == TYPE_STRING:
			u.set_general_trait(cfg, String(gt))
		else:
			var ga: Variant = su.get("ga", null)
			if typeof(ga) == TYPE_STRING:
				u.apply_aura_trait(cfg, String(ga))
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
		# ★ 没挪动就不重算 tile：30Hz 下大量单位是站定的，sync_tile 是白花的。
		var nx := float(su.get("x", u.pos.x))
		var ny := float(su.get("y", u.pos.y))
		if nx != u.pos.x or ny != u.pos.y:
			u.pos = Vector2(nx, ny)
			u.sync_tile(world.map)
		# ★ 招募队列：一整组字段，按 **tk 在不在** 判断新旧格式（与 ld / fa 同一条约定：
		#   老快照没有 tk → 整组保持本地现状，不要把队列清空）。
		#   ⚠️ 2026.10.24 起招募**不再把将领钉在原地**，客机侧也就没有
		#   「train_anchor 钉位置」这件事了；`train_anchor` 只作为历史字段保留。
		if su.has("tk"):
			var tk: Variant = su["tk"]
			u.train_kind = String(tk) if tk != null else ""
			u.train_total = float(su.get("tt", u.train_total))
			u.train_remaining = float(su.get("tr", u.train_remaining))
			u.train_queue.clear()
			var tq: Variant = su.get("tq", null)
			if typeof(tq) == TYPE_ARRAY:
				for k in (tq as Array):
					u.train_queue.append(String(k))
			u.train_anchor = u.pos
		# ★★ 将领濒死：与 tk 那一组同一条约定 —— **nd 在不在**决定新旧格式。
		#    ⚠️ 回复进度**不要**在这里按比例重算：权威侧给的就是已经写进 hp 的那个数
		#      （见 unit.nd_regen_hp），而比例口径 `nd_hp_ratio` 由这里反推，
		#      两处算两份的话「科技改过上限」的场面会对不上。
		if su.has("nd"):
			u.downed = int(su.get("nd", 0)) != 0
			u.nd_regen_hp = float(su.get("nh", u.nd_regen_hp))
			u.nd_regen_timer = float(su.get("nt", u.nd_regen_timer))
			u.revive_remaining = float(su.get("nv", u.revive_remaining))
			u.revive_total = float(su.get("nvt", u.revive_total))
			# ★★ 「正在读条」这个开关**从倒计时推出来**（权威侧也是同一个语义：
			#    见 unit.revive_pending 的说明）。快照里不单发一个布尔字段 ——
			#    多发一个就多一处要与 nv 对齐的状态，而两者本来就是同一件事。
			u.revive_pending = u.downed and u.revive_remaining > 0.0
			u.nd_hp_ratio = u.hp / u.hp_max if u.hp_max > 0.0 else 0.0
			# ★ 倒下点：濒死期间位置被 `world._pin_downed_leaders()` 钉在它上面，
			#   所以客机必须跟着权威位置更新 —— 缺了它，客机会把这个将领拖回
			#   本地那份旧的 downed_anchor（画面上一抖一抖）。
			if u.downed:
				u.downed_anchor = u.pos

	# 快照里没有的单位 = 已经阵亡（客机上的世界完全以快照为准）
	var keep: Array = []
	for u in world.units:
		if seen.has(u.id):
			keep.append(u)
	world.units = keep
	# 重建索引（去掉本帧阵亡的），投掷物解析目标 / 来源时复用同一份。
	unit_index.clear()
	for u in world.units:
		unit_index[String(u.id)] = u

	# 建筑：整表替换（数量少、结构简单，比按 id 对齐更不容易出错）
	_world_sync_buildings(world, cfg, snap.get("buildings", []))

	# ★★ 客机侧没有 faction_neutralized 事件：从对象上的 nz 反推「哪些阵营已中立化」。
	#    只增不清 —— 房主那边可能已经没有任何残余对象了（那时客机也无需再限制什么）。
	for u in world.units:
		if u.neutralized and String(u.faction) != "":
			world.neutralized_factions[String(u.faction)] = true
	for b in world.building_list:
		if b.neutralized and String(b.owner) != "":
			world.neutralized_factions[String(b.owner)] = true

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
		# 区划人口：老快照没有 pop → 保持本地现状（同上，别用 0 覆盖）
		if sz.has("pop"):
			z["population"] = float(sz["pop"])
		# ★ 区划特化：整组按字段存在与否写，缺字段保持本地现状（与 pop 同一条约定）。
		if sz.has("sk"):
			z["spec_kind"] = String(sz["sk"])
		if sz.has("sr"):
			z["spec_remaining"] = float(sz["sr"])
		if sz.has("st"):
			z["spec_total"] = float(sz["st"])
		if sz.has("sd"):
			z["spec_done"] = String(sz["sd"])
		if sz.has("sx"):
			z["spec_cancel"] = bool(sz["sx"])

	# ★★ 目标状态：客机只读，不自己 tick（见 world.refresh_after_snapshot / client_session）。
	if snap.has("obj"):
		var obj: Variant = snap["obj"]
		if typeof(obj) == TYPE_DICTIONARY:
			ObjectiveRes.apply_snapshot(world.objective_state, obj)

	# ★★ 按席位资源：有 pres 就按席位写；没有才回落到旧的单份 res。
	#    ⚠️ 不要用 `res` 覆盖 `pres` —— 合作时 `res` 只是房主自己那一份。
	if snap.has("pres"):
		var pres: Variant = snap["pres"]
		if typeof(pres) == TYPE_DICTIONARY:
			for f in (pres as Dictionary).keys():
				var arr: Variant = (pres as Dictionary)[f]
				if typeof(arr) != TYPE_ARRAY or (arr as Array).size() < 2:
					continue
				var target: Variant = world.player_resources.get(String(f), null)
				if typeof(target) != TYPE_DICTIONARY:
					continue          # 不是本局玩家席位（AI 的资源不下发）
				(target as Dictionary)["food"] = float((arr as Array)[0])
				(target as Dictionary)["gold"] = float((arr as Array)[1])
	elif snap.has("res") and world.player_seats.size() <= 1:
		# ★ 只有单席位（单机 / 老快照）才回落到单份 `res`。
		#   合作局（两个席位）的 pres 缺失属于「坏快照」—— 按缺字段铁律保持本地现状，
		#   否则客机会把房主的那份钱覆盖到自己头上（实测踩到：F2 变成 F1 的 111）。
		var res: Array = snap["res"]
		if res.size() >= 2:
			world.resources["food"] = float(res[0])
			world.resources["gold"] = float(res[1])

	# ★★ 按席位科技：客机只读，用来画九格高亮。
	if snap.has("tech"):
		var tech_in: Variant = snap["tech"]
		if typeof(tech_in) == TYPE_DICTIONARY and world.tech != null:
			for f in (tech_in as Dictionary).keys():
				var ids: Variant = (tech_in as Dictionary)[f]
				if typeof(ids) != TYPE_ARRAY:
					continue
				world.tech.active_by_faction[String(f)] = (ids as Array).duplicate()
			world.tech_effects = world.tech.effects_of(world.my_faction)

	# ★★ 将领招募池 / 冷却（本轮新增）：客机只更新显示状态。
	#    ⚠️ 缺字段（老快照）→ 保持本地现状（与 res / owned / time 同一条约定）。
	if snap.has("gp"):
		var gp_in: Variant = snap["gp"]
		if typeof(gp_in) == TYPE_DICTIONARY:
			for f in (gp_in as Dictionary).keys():
				world.apply_general_pool_snapshot(String(f), (gp_in as Dictionary)[f])

	# ★★ 指挥官 AI 的指令 / 资源（客机只读；缺字段 = 保持本地现状）。
	if snap.has("aid"):
		var aid_in: Variant = snap["aid"]
		if typeof(aid_in) == TYPE_DICTIONARY:
			var next: Dictionary = {}
			for f in (aid_in as Dictionary).keys():
				var dv: Variant = (aid_in as Dictionary)[f]
				if typeof(dv) != TYPE_DICTIONARY:
					continue
				var dd: Dictionary = dv
				next[String(f)] = {
					"kind": String(dd.get("k", "")),
					"x": float(dd.get("x", -1.0)),
					"y": float(dd.get("y", -1.0)),
					"serial": int(dd.get("s", 0)),
					"since": float(dd.get("t", 0.0)),
					"state": "running",
					"reason": "",
				}
			world.ai_directives = next
	if snap.has("air"):
		var air_in: Variant = snap["air"]
		if typeof(air_in) == TYPE_DICTIONARY:
			var next2: Dictionary = {}
			for f in (air_in as Dictionary).keys():
				var av: Variant = (air_in as Dictionary)[f]
				if typeof(av) != TYPE_ARRAY or (av as Array).size() < 2:
					continue
				next2[String(f)] = {
					"food": float((av as Array)[0]),
					"gold": float((av as Array)[1]),
				}
			world.ai_faction_resources = next2

	if snap.has("owned"):
		world.owned_tiles = int(snap["owned"])
	if snap.has("time"):
		world.time = float(snap["time"])
	# ★★ 投掷物（本轮新增）：整表重建。
	#    ⚠️ 缺字段（老快照）→ **保持本地现状**（与 res / owned / time 同一条约定）。
	if snap.has("projectiles"):
		_sync_projectiles(world, snap["projectiles"], unit_index)


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
			_apply_building_state(b, sb)
			b.alive = true
			out.append(b)
		else:
			var z = world.zones.zone_at(int(sb.get("x", -1)), int(sb.get("y", -1)))
			var nb := BuildingRes.create(
				cfg, String(sb.get("t", "wall")), int(sb.get("x", -1)), int(sb.get("y", -1)),
				String(sb.get("o", FactionRes.DEFAULT_FACTION)), int(z["id"]) if z != null else -1
			)
			_apply_building_state(nb, sb)
			out.append(nb)
	world.building_list = out
	world.rebuild_building_index()
	# ★ 归属缓存 / 迷雾靠这个版本号知道「建筑表换过了」；`rebuild_building_index()` 不涨版本。
	world.building_revision += 1


## 把快照里的一栋建筑状态写进本地对象（**缺字段 = 保持本地现状**）。
static func _apply_building_state(b, sb: Dictionary) -> void:
	var mh: Variant = sb.get("mh", null)
	if mh != null:
		b.hp_max = maxf(1.0, float(mh))
	if sb.has("lv"):
		b.level = int(sb["lv"])
	b.hp = float(sb.get("h", b.hp))
	if b.hp_max > 0.0:
		b.hp = clampf(b.hp, 0.0, b.hp_max)
	if sb.has("ur"):
		b.upgrade_remaining = float(sb["ur"])
	if sb.has("ut"):
		b.upgrade_total = float(sb["ut"])
	if sb.has("nz"):
		b.neutralized = int(sb["nz"]) != 0
	# ★ 大本营重生队列：客机只保存展示字段（没有死将对象，也不 tick）。
	if sb.has("rq"):
		var rn := ""
		if sb.get("rn", null) != null:
			rn = String(sb["rn"])
		b.apply_respawn_snapshot(int(sb.get("rq", 0)),
			float(sb.get("rr", 0.0)), float(sb.get("rt", 0.0)), rn)


# ------------------------------------------------------------------
# 投掷物往返用的「引用编码」：单位 → id；建筑 → "type:tx:ty:owner"
# ------------------------------------------------------------------

## 一个对象是不是单位（单位有 `id`）。⚠️ 用 `has_method("center")` 区分：
## 只有建筑有 `center()`（单位只有 `pos` 字段），所以它是最稳的判据。
static func _unit_id_of(o) -> String:
	if o == null or o.has_method("center"):
		return ""
	return String(o.id)


static func _building_key_of(o) -> String:
	if o == null or not o.has_method("center"):
		return ""
	return "%s:%d:%d:%s" % [String(o.type), int(o.tx), int(o.ty), String(o.owner)]


static func _building_by_key(world, key: String):
	var parts: PackedStringArray = key.split(":")
	if parts.size() < 4:
		return null
	return world.building_at(int(parts[1]), int(parts[2]))


## 客机 / 读档：按快照重建在飞的投掷物（整表替换）。
## ⚠️ 目标 / 来源解析不到就置空 —— 投掷物照飞、飞完自然消失、不造成伤害（不崩）。
static func _sync_projectiles(world, list: Array, unit_index: Dictionary) -> void:
	var out: Array = []
	for sp in list:
		var p = ProjectileRes.new()
		p.faction = String(sp.get("f", ""))
		p.start = Vector2(float(sp.get("sx", 0.0)), float(sp.get("sy", 0.0)))
		p.end = Vector2(float(sp.get("ex", p.start.x)), float(sp.get("ey", p.start.y)))
		p.t = clampf(float(sp.get("t", 0.0)), 0.0, 1.0)
		p.pos = p.start.lerp(p.end, p.t)
		p.elapsed = float(sp.get("el", 0.0))
		p.duration = float(sp.get("du", 0.001))
		p.damage = float(sp.get("dmg", 0.0))
		var tu := String(sp.get("tu", ""))
		var tk := String(sp.get("tk", ""))
		if tu != "":
			p.target = unit_index.get(tu, null)
			p.target_is_building = false
		elif tk != "":
			p.target = _building_by_key(world, tk)
			p.target_is_building = true
		var su := String(sp.get("su", ""))
		var sk := String(sp.get("sk", ""))
		if su != "":
			p.source = unit_index.get(su, null)
		elif sk != "":
			p.source = _building_by_key(world, sk)
		p.alive = true
		out.append(p)
	world.projectiles = out
