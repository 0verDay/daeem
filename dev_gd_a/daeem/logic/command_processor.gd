## command_processor.gd —— ★ 命令的唯一入口（对应 HTML 版 main.js 的 orderMove / tryBuildAt）
##
## 逻辑层**永远不读鼠标**。所有玩家意图都先变成一个可序列化的字典，再进这里执行：
##
##   命令 kind      载荷                 说明
##   move           ids, x, y            移动到世界坐标（点到哪走到哪）
##   attack         ids, target_id / tx,ty  优先攻击某个敌对单位或建筑（右键点敌人/建筑）
##   attack_move    ids, x, y            行军攻击：走到该点，路上遇敌就停下来打（SC2 的 A 键）
##   stop           ids                  就地停止（清掉移动 / 攻击 / 行军攻击；操作页的「停止」格）
##   build          kind(build_type), tx, ty, faction   在格子上建造
##   demolish       tx, ty               拆除建筑
##   recruit        unit_kind, leader_id, faction       把单位排进某个将领的招募队列
##                                                      （入队即扣 50 粮 / 50 金 / 1 人口，读条 10 秒）
##   recruit_cancel leader_id, slot, faction            取消招募队列里的某一格并退款
##                                                      （slot 0 = 正在读条的大格子，1..4 = 排队的小格子）
##   zone_recruit   unit_kind, zone_id, faction         ★ 把将领排进某个**区划**的招募队列
##                                                      （点区划中心 → 右下「招募」页签）
##   zone_recruit_cancel zone_id, slot, faction         取消区划招募队列里的某一格并退款
##   tech_toggle    tech_id, on, faction               ★ 启用 / 弃用一条科技
##                                                      （右下「科技」页签的三×三九格）
##   building_upgrade        tx, ty, faction           ★ 升级一栋建筑（读条，可取消退款）
##                                                      （右下「操作」页签里那一格）
##   building_upgrade_cancel tx, ty, faction           取消读条中的那次建筑升级并退款
##   zone_specialize         zone_id, spec, faction    ★ 给一个区划做特化（读条；
##                                                      粮食 / 黄金 / 人口，只能选一个）
##   zone_spec_cancel        zone_id, faction          取消已完成的特化（**也要读条**，读完退款）
##   zone_spec_bar_cancel    zone_id, faction          撤掉**读条中**的那一单特化并退款
##   spawn_enemy    tx, ty               调试刷兵
##
## ★ 关键约束：**命令里只放意图，不放结果**。
##   HTML 版的快照不发路径（客机只说「哪些单位、走到哪个格坐标点」，路径由房主算），
##   这条要继承 —— 否则会出现路径欺骗，而且只有房主才知道最新的城墙位置。
##
## 第 1 轮联机时，唯一的改动是：view/ 把命令交给网络层，网络层绕一圈服务器回来再进这里，
## **本文件一行都不用改**。这就是现在花力气分边界的全部回报。
##
## ⚠️ 本文件也不读输入、不碰场景树，因此可以在无头测试里直接调。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")
const GridRes = preload("res://logic/grid.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")
const BuildingRes = preload("res://logic/building.gd")
const EconomyRes = preload("res://logic/economy.gd")
const FactionRes = preload("res://logic/faction.gd")


## 统一入口。返回 true = 命令被接受（不代表效果已达成）。
##
## 第 1 轮联机时，房主在收到客机的 cmd 之前会先做一次「按发送者阵营过滤」，
## 现在把那个语义写进 _allowed_owner()，接口不用变。
static func apply(world, cfg: ConfigRes, cmd: Dictionary) -> bool:
	match String(cmd.get("kind", "")):
		"move":
			return apply_move(world, cfg, cmd)
		"attack":
			return apply_attack(world, cfg, cmd)
		"attack_move":
			return apply_attack_move(world, cfg, cmd)
		"stop":
			return apply_stop(world, cfg, cmd)
		"build":
			return apply_build(world, cfg, cmd)
		"demolish":
			return apply_demolish(world, cfg, cmd)
		"recruit":
			return apply_recruit(world, cfg, cmd)
		"recruit_cancel":
			return apply_recruit_cancel(world, cfg, cmd)
		"zone_recruit":
			return apply_zone_recruit(world, cfg, cmd)
		"zone_recruit_cancel":
			return apply_zone_recruit_cancel(world, cfg, cmd)
		"tech_toggle":
			return apply_tech_toggle(world, cfg, cmd)
		"building_upgrade":
			return world.start_building_upgrade(
				int(cmd.get("tx", -1)), int(cmd.get("ty", -1)),
				String(cmd.get("faction", world.my_faction)))
		"building_upgrade_cancel":
			return world.cancel_building_upgrade(
				int(cmd.get("tx", -1)), int(cmd.get("ty", -1)),
				String(cmd.get("faction", world.my_faction)))
		"zone_specialize":
			return world.start_zone_specialize(
				int(cmd.get("zone_id", -1)), String(cmd.get("spec", "")),
				String(cmd.get("faction", world.my_faction)))
		"zone_spec_cancel":
			return world.cancel_zone_specialize(
				int(cmd.get("zone_id", -1)), String(cmd.get("faction", world.my_faction)))
		"zone_spec_bar_cancel":
			return world.cancel_zone_spec_bar(
				int(cmd.get("zone_id", -1)), String(cmd.get("faction", world.my_faction)))
		"spawn_enemy":
			return apply_spawn_enemy(world, cmd)
		"select":
			# 选中是**纯本地**的（不进命令流、不上网），这里只为调试句柄保留一个空实现
			return true
	return false


## 移动命令：ids 里的单位都走到世界坐标点 (x, y)。
##
## ★ 命令里带 faction（联机时由服务器盖章）：房主据此过滤，
##   否则客机可以拿房主的单位 id 下达命令（HTML 版专门测过这条「防冒充」）。
static func apply_move(world, cfg: ConfigRes, cmd: Dictionary) -> bool:
	var owner_faction := String(cmd.get("faction", world.my_faction))
	var ids: Array = cmd.get("ids", [])
	var pt := Vector2(float(cmd.get("x", 0.0)), float(cmd.get("y", 0.0)))
	# 队形：整队走到点击点周围各自的槽位上（少于 formation.min_units 个就不排阵）
	var group := _collect_units(world, ids, owner_faction)
	var accepted := false
	if group.size() >= cfg.formation_min_units:
		accepted = order_group_formation(world, cfg, group, pt)
	else:
		for u in group:
			if u.order_move(world, cfg, pt):
				accepted = true
	if not accepted:
		note_order_rejected(world, ids, owner_faction)
	return accepted


## 一条指令**一个单位都没接受**时，回头看看是不是「被招募锁住了」，
## 是的话留一条事件给界面。
##
## ★ 为什么要有它：招募期间将领与它辖下的部队都不接受指令（用户需求），
##   而玩家右键点下去**什么都没发生**看起来就是功能坏了 ——
##   与「招募被拒」同一个通道（world.push_event → game_scene → 左栏红字）。
## ★ 只在**一个都没接受**时报：整队里有一半能动的时候，界面上的表现已经够清楚了。
static func note_order_rejected(world, ids: Array, owner_faction: String) -> void:
	for id in ids:
		var u = world.unit_by_id(String(id))
		if u == null or not u.alive:
			continue
		if not FactionRes.same_side(u.faction, owner_faction):
			continue
		if world.is_order_locked(u):
			world.push_event({"type": "order_rejected", "reason": "recruiting", "unit_id": u.id})
			return


## 把 ids 翻成「真的能下命令的」单位（去重、在场上、属于自己这一方）。
## 顺序保持 ids 的顺序 —— 队形的槽位分配要靠它保持可预测。
##
## ★ 正在招募的将领**连同它辖下的部队**一起被排除（`world.is_order_locked`）：
##   需求原话「玩家无法为正在招募单位的将领及其附属队列发布任何指令（移动/攻击），
##   其附属单位只会执行警戒逻辑」。⚠️ 是**整队**，不是只有将领本人 ——
##   否则玩家可以用「选中整队右键」把护卫派走，将领身边就空了。
static func _collect_units(world, ids: Array, owner_faction: String) -> Array:
	var out: Array = []
	for id in ids:
		var u = world.unit_by_id(String(id))
		if u == null or not u.alive:
			continue
		if world.is_order_locked(u):
			continue
		if not FactionRes.same_side(u.faction, owner_faction):
			continue                      # ★ 防冒充：只能命令自己这一方的单位
		out.append(u)
	return out


## ★★ 队形落点：整队各自领一个槽位，而不是全挤向同一个坐标。
##
## 为什么要有它（两个理由，第二个是性能）：
##   1. 手感：所有人抢同一个点时，谁先到谁占住，后面的人被挤开、再由「拥挤认账」
##      在附近乱找空位 —— 就是玩家看到的「到达后互相挤着转」。
##   2. 性能：拥挤判定是 O(n²) 的（每个单位都要看一遍全部单位谁占着落点）。
##      各走各的槽位之后，这条几乎不会被触发。
##
## 寻路仍然只算**一次**：整队共用一张「到点击格」的距离场，
## 每个单位的路线 = 顺场下降到点击格 + 从点击格走出去到自己的槽位（见 crowd_bridge.tile_path_via）。
##
## @return 是否至少有一个单位接受了命令
static func order_group_formation(world, cfg: ConfigRes, group: Array, click: Vector2) -> bool:
	var slots := formation_slots(world, cfg, group, click)
	if slots.is_empty():
		# 排不出阵（比如点击点在地图外）→ 退回「所有人都走到点击点」
		var any_fallback := false
		for u in group:
			if u.order_move(world, cfg, click):
				any_fallback = true
		return any_fallback

	var anchor := Vector2i(floori(click.x), floori(click.y))

	# 点击格不可通行时（点到山/建筑）**不排阵**：每个单位的落点会被
	# move_to 各自改成「贴边最近的可达点」，那张共用的场就覆盖不到它们了。
	# 退回逐个 order_move —— 与队形之前的行为一致。
	if not PathfinderRes.passable(world.map, world.buildings, cfg, anchor.x, anchor.y, group[0].faction):
		var any2 := false
		for u in group:
			if u.order_move(world, cfg, click):
				any2 = true
		return any2

	var any := false
	for i in group.size():
		var u = group[i]
		if u.order_move_via_field(world, cfg, slots[i], anchor):
			any = true
	return any


## 给一群单位排槽位：返回与 group **一一对应**的落点数组（格坐标点）。
##
## 做法：以点击点为中心、按「前进方向」为轴铺一层方格，然后
## **按同一个键把单位和槽位各自排序**再配对 —— 这样编队左边的单位拿左边的槽位，
## 整队不会互相穿过（否则队形会自己打结，看着比不排阵还乱）。
##
## ⚠️ 槽位必须落在可通行格上：落在山/墙里的会被往旁边挪一格（找不到就退回点击点）。
static func formation_slots(world, cfg: ConfigRes, group: Array, click: Vector2) -> Array[Vector2]:
	var n := group.size()
	var out: Array[Vector2] = []
	if n <= 0:
		return out

	# 阵型朝向：从队伍重心指向点击点（队伍朝目标方向列阵）
	var centroid := Vector2.ZERO
	for u in group:
		centroid += u.pos
	centroid /= float(n)
	var fwd := click - centroid
	if fwd.length() < 1e-3:
		fwd = Vector2.RIGHT
	fwd = fwd.normalized()
	var side := Vector2(-fwd.y, fwd.x)

	var spacing: float = maxf(0.02, cfg.unit_collision_radius * 2.0
		* clampf(cfg.unit_overlap_allowance, 0.0, 1.0) * cfg.formation_spacing_scale)
	var slot_count: int = n
	if cfg.formation_max_slots > 0:
		slot_count = mini(n, cfg.formation_max_slots)

	var cols: int = maxi(1, int(ceil(sqrt(float(slot_count) * cfg.formation_aspect))))
	var rows: int = int(ceil(float(slot_count) / float(cols)))
	var half_c := (float(cols) - 1.0) * 0.5
	var half_r := (float(rows) - 1.0) * 0.5

	# 槽位偏移（相对点击点），行优先
	var offs: Array[Vector2] = []
	for r in rows:
		for c in cols:
			if offs.size() >= slot_count:
				break
			offs.append(side * ((float(c) - half_c) * spacing) + fwd * ((float(r) - half_r) * spacing))

	# 排序键：先横向、再纵深（单位与槽位用同一个键，保证配对不交叉）
	var slots_sorted := offs.duplicate()
	slots_sorted.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		var ka: float = a.dot(side) * 1000.0 + a.dot(fwd)
		var kb: float = b.dot(side) * 1000.0 + b.dot(fwd)
		return ka < kb)

	var order: Array = []
	for i in n:
		order.append(i)
	var unit_keys := PackedFloat64Array()
	for u in group:
		var rel: Vector2 = (u.pos as Vector2) - click
		unit_keys.append(rel.dot(side) * 1000.0 + rel.dot(fwd))
	var keys := unit_keys
	order.sort_custom(func(a: int, b: int) -> bool: return keys[a] < keys[b])

	# 配对：第 k 个「队伍里的位置顺序」拿第 k 个槽位
	var result: Array[Vector2] = []
	result.resize(n)
	for k in n:
		var slot: Vector2 = click + slots_sorted[k] if k < slots_sorted.size() else click
		result[order[k]] = _snap_slot(world, cfg, slot, group[0].faction, click)
	return result


## 槽位落点微调：那一格不可通行时，往周围挪到最近的可通行格；实在没有就退回点击点。
static func _snap_slot(world, cfg: ConfigRes, slot: Vector2, faction: String, click: Vector2) -> Vector2:
	var t := Vector2i(floori(slot.x), floori(slot.y))
	if PathfinderRes.passable(world.map, world.buildings, cfg, t.x, t.y, faction):
		return slot
	for ring in range(1, 4):
		for d in GridRes.DIRS8:
			var c := Vector2i(t.x + d.x * ring, t.y + d.y * ring)
			if PathfinderRes.passable(world.map, world.buildings, cfg, c.x, c.y, faction):
				return GridRes.center_of(c)
	return click


## 攻击命令（右键单击敌人 / 建筑）：把 ids 里的单位派去**优先攻击**那个目标。
##
## 载荷二选一（**都不带对象引用** —— 命令必须可序列化，第 1 轮要过网络）：
##   · target_id    敌对**单位**的 id
##   · tx, ty       敌对**建筑**所在的地块
##
## 与 move 一样带 faction 防冒充；目标必须真的是敌对的一方（不能拿自己人当靶子）。
static func apply_attack(world, cfg: ConfigRes, cmd: Dictionary) -> bool:
	var owner_faction := String(cmd.get("faction", world.my_faction))
	var target_unit = null
	var target_building = null
	if cmd.has("target_id"):
		target_unit = world.unit_by_id(String(cmd.get("target_id", "")))
		if target_unit == null or not target_unit.alive:
			return false
		if FactionRes.same_side(target_unit.faction, owner_faction):
			return false
	else:
		target_building = world.building_at(int(cmd.get("tx", -1)), int(cmd.get("ty", -1)))
		if target_building == null or not target_building.alive:
			return false
		if FactionRes.same_side(target_building.owner, owner_faction):
			return false
		# ★ 无敌建筑（区划中心）连命令都不该被接受 —— 它不是「敌方建筑」，是中立障碍。
		#   这里挡一道，`unit.order_attack_building()` 里再挡一道：命令层与逻辑层各管各的，
		#   缺任何一道都会退化成「对着打不掉的柱子一直敲」。
		if target_building.is_invulnerable():
			return false

	var any := false
	for id in (cmd.get("ids", []) as Array):
		var u = world.unit_by_id(String(id))
		if u == null or not u.alive:
			continue
		if world.is_order_locked(u):
			continue                      # ★ 招募中：将领与它辖下的部队都不接指令
		if not FactionRes.same_side(u.faction, owner_faction):
			continue                      # ★ 防冒充
		var accepted: bool
		if target_unit != null:
			accepted = u.order_attack_unit(world, cfg, target_unit)
		else:
			accepted = u.order_attack_building(world, cfg, target_building)
		if accepted:
			any = true
	if not any:
		note_order_rejected(world, cmd.get("ids", []), owner_faction)
	return any


## 行军攻击命令（右键双击，等价于 SC2 的按 A 攻击到某点）：
## 走到 (x, y)，**路上遇到敌人就停下来打，打完了继续走**。
## 与 move 的区别只有这一条：move 是明确命令，遇敌不停。
static func apply_attack_move(world, cfg: ConfigRes, cmd: Dictionary) -> bool:
	var owner_faction := String(cmd.get("faction", world.my_faction))
	var ids: Array = cmd.get("ids", [])
	var pt := Vector2(float(cmd.get("x", 0.0)), float(cmd.get("y", 0.0)))
	var group := _collect_units(world, ids, owner_faction)
	var accepted := false
	# 行军攻击同样排阵：整队各自走到自己的槽位，路上遇敌照样停下来打。
	# ⚠️ 与 move 的区别只有「路上打不打」，「走到哪」这件事两边一致 —— 否则
	#    A 过去和右键过去会落在两片不同的地方，玩家会以为其中一个坏了。
	if group.size() >= cfg.formation_min_units:
		var anchor_ok: bool = PathfinderRes.passable(world.map, world.buildings, cfg,
			floori(pt.x), floori(pt.y), group[0].faction)
		var slots := formation_slots(world, cfg, group, pt) if anchor_ok else [] as Array[Vector2]
		if not slots.is_empty():
			var anchor := Vector2i(floori(pt.x), floori(pt.y))
			for i in group.size():
				if group[i].order_attack_move_at(world, cfg, slots[i], anchor):
					accepted = true
			return accepted
	for u in group:
		if u.order_attack_move(world, cfg, pt):
			accepted = true
	if not accepted:
		note_order_rejected(world, ids, owner_faction)
	return accepted


## 建造命令：owner 缺省时用本地阵营
static func apply_build(world, cfg: ConfigRes, cmd: Dictionary) -> bool:
	var owner := String(cmd.get("faction", world.my_faction))
	var type := String(cmd.get("build_type", cmd.get("build", "")))
	if type == "" or not BuildingRes.DEFS.has(type):
		return false
	if not world.can_build_at(int(cmd.get("tx", -1)), int(cmd.get("ty", -1))):
		world.push_event({"type": "build_rejected", "tile": Vector2i(int(cmd.get("tx", -1)), int(cmd.get("ty", -1))), "reason": "occupied_or_terrain"})
		return false
	var def_v = cfg.get_path_value("building.%s" % type)
	var def: Dictionary = def_v if typeof(def_v) == TYPE_DICTIONARY else {}
	var cost: Dictionary = def.get("cost", {})
	if not EconomyRes.try_spend(cfg, world.resources, cost):
		world.push_event({"type": "build_rejected", "tile": Vector2i(int(cmd.get("tx", -1)), int(cmd.get("ty", -1))), "reason": "cost"})
		return false
	return world.add_building(type, int(cmd.get("tx", -1)), int(cmd.get("ty", -1)), owner) != null


## 拆除命令：按**地块**定位，而不是传对象引用。
## 命令必须可序列化（第 1 轮要走网络），传对象引用会立刻破功。
static func apply_demolish(world, cfg: ConfigRes, cmd: Dictionary) -> bool:
	var owner := String(cmd.get("faction", world.my_faction))
	var b = world.building_at(int(cmd.get("tx", -1)), int(cmd.get("ty", -1)))
	if b == null or not b.alive:
		return false
	if not FactionRes.same_side(b.owner, owner):
		return false                      # 只能拆自己这一方的
	if b.type == BuildingRes.TYPE_BASE:
		return false                      # 大本营不可拆除（只能被打掉）
	# ★ 区划中心是不可拆的**中立障碍**（无敌、无血量）：owner 是空字符串，
	#   上面那条 same_side 已经会拦住「玩家拆自家/别家」；这里显式写一条，
	#   免得以后有人把中心改成「归属某方」时它突然变成可拆的。
	if b.is_invulnerable():
		return false
	world.remove_building(b, false)
	world.push_event({"type": "building_demolished", "building": b})
	return true


## 招募命令：把 unit_kind 兵种排到 leader_id 那个将领的招募队列里
## （单位页的命令卡走这条路）。
##
## ★ 命令里只有**兵种与队长 id，没有坐标**：站位（将领所在格的**中心**）由权威侧算
##   （第 1 轮联机时，客机自己挑格子就是作弊，而且它也不知道最新的城墙在哪）。
## ★ 校验 → 扣费（粮食 / 黄金 / 区划人口）→ 入队 → 读条，全在
##   `world.start_recruit()` 里，**命令层不再自己判一遍** —— 两处各判一套迟早会漂开
##   （旧版这里先 can_recruit 再 try_spend，第三次加规则时就要改两个地方）。
## ★ 命令被拒时 world 会写一条 `recruit_rejected` 事件（带拒因），
##   界面靠它显示红字原因（见 view/game_scene.gd → hud.show_notice）。
static func apply_recruit(world, _cfg: ConfigRes, cmd: Dictionary) -> bool:
	var owner := String(cmd.get("faction", world.my_faction))
	var kind := String(cmd.get("unit_kind", ""))
	var leader_id := String(cmd.get("leader_id", ""))
	return world.start_recruit(kind, leader_id, owner)


## 取消某一格上的招募（点信息栏里那五个格子）。
##
## ★ 命令里只有 **队长 id + 格号**：格号是界面的序号（0 = 正在读条的大格子，
##   1..4 = 排队的四个小格子），由权威侧按同一个序号解释 —— 退多少钱、
##   后方的队列怎么前移，全在 `world.cancel_recruit()` 里算。
static func apply_recruit_cancel(world, _cfg: ConfigRes, cmd: Dictionary) -> bool:
	return world.cancel_recruit(
		String(cmd.get("leader_id", "")),
		int(cmd.get("slot", -1)),
		String(cmd.get("faction", world.my_faction)))


## ★ 停止命令（右下「操作」页的「停止」格）：就地停下并清掉移动 / 攻击 / 行军攻击。
##
## 与 move / attack 走完全同一条路（`_collect_units` 那套判据复用）：
## 正在招募的将领与它辖下的部队照样**不接受**这条命令（`world.is_order_locked`），
## 一条都没接受时同样留一条 `order_rejected` 给界面。
static func apply_stop(world, _cfg: ConfigRes, cmd: Dictionary) -> bool:
	var owner_faction := String(cmd.get("faction", world.my_faction))
	var ids: Array = cmd.get("ids", [])
	var any := false
	for id in ids:
		var u = world.unit_by_id(String(id))
		if u == null or not u.alive:
			continue
		if world.is_order_locked(u):
			continue
		if not FactionRes.same_side(u.faction, owner_faction):
			continue                      # ★ 防冒充：只能命令自己这一方的单位
		u.stop()
		any = true
	if not any:
		note_order_rejected(world, ids, owner_faction)
	return any


## ★ 区划招募命令：把 unit_kind 这名将领排到 zone_id 那个区划的招募队列里
## （点区划中心 → 右下「招募」页签 → 点某一格）。
##
## ★ 与 `recruit` 一模一样的形状：命令里只有**兵种 + 区划 id**，没有坐标 ——
##   出兵位置（区划中心旁的空地）、扣费、退款全在 `world.start_zone_recruit()` 里算。
static func apply_zone_recruit(world, _cfg: ConfigRes, cmd: Dictionary) -> bool:
	return world.start_zone_recruit(
		String(cmd.get("unit_kind", "")),
		int(cmd.get("zone_id", -1)),
		String(cmd.get("faction", world.my_faction)))


## 取消区划招募队列里的某一格（点信息栏那五个格子）。
## ★ 格号语义与 `recruit_cancel` 完全一致（0 = 大格子，1..4 = 小格子）。
static func apply_zone_recruit_cancel(world, _cfg: ConfigRes, cmd: Dictionary) -> bool:
	return world.cancel_zone_recruit(
		int(cmd.get("zone_id", -1)),
		int(cmd.get("slot", -1)),
		String(cmd.get("faction", world.my_faction)))


## 调试刷兵命令
static func apply_spawn_enemy(world, _cmd: Dictionary) -> bool:
	return world.spawn_enemy() != null


## ★ 科技启用 / 弃用命令（右下「科技」页签的九格 → `tech_toggle`）。
##
## 载荷只有三项：**科技 id + 目标状态 + 阵营** —— 命令里没有效果数值、没有对象引用。
## 「最多同时启用 3 个」「这一条的效果是什么」全在 `world.set_tech_active()` 里算
## （权威侧），命令层只转发。
##
## `on` 缺省时按「切换」处理（玩家点一下格子的语义就是切换）——
## 这样界面既能发明确的 on/off（将来的研究完成、读档），也能发一次点击。
##
## ⚠️ 被拒时不在这里给提示：`world.set_tech_active` 会写一条 `tech_rejected` 事件，
##    由 view/game_scene 翻成左栏那行红字（与招募 / 指令被拒同一条通道）。
static func apply_tech_toggle(world, _cfg: ConfigRes, cmd: Dictionary) -> bool:
	var id := String(cmd.get("tech_id", cmd.get("id", "")))
	if id == "" or world.tech == null:
		return false
	var faction := String(cmd.get("faction", world.my_faction))
	if cmd.has("on"):
		return world.set_tech_active(id, bool(cmd.get("on", false)), faction)
	return world.toggle_tech(id, faction)
