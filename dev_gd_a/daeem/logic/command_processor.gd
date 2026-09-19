## command_processor.gd —— ★ 命令的唯一入口（对应 HTML 版 main.js 的 orderMove / tryBuildAt）
##
## 逻辑层**永远不读鼠标**。所有玩家意图都先变成一个可序列化的字典，再进这里执行：
##
##   命令 kind      载荷                 说明
##   move           ids, x, y            移动到世界坐标（点到哪走到哪）
##   attack         ids, target_id / tx,ty  优先攻击某个敌对单位或建筑（右键点敌人/建筑）
##   attack_move    ids, x, y            行军攻击：走到该点，路上遇敌就停下来打（SC2 的 A 键）
##   build          kind(build_type), tx, ty, faction   在格子上建造
##   demolish       tx, ty               拆除建筑
##   recruit        unit_kind, leader_id, faction       把单位招到某个将领名下（UI 改版新增）
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
		"build":
			return apply_build(world, cfg, cmd)
		"demolish":
			return apply_demolish(world, cfg, cmd)
		"recruit":
			return apply_recruit(world, cfg, cmd)
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
	var any := false
	for id in ids:
		var u = world.unit_by_id(String(id))
		if u == null or not u.alive:
			continue
		if not FactionRes.same_side(u.faction, owner_faction):
			continue                      # ★ 防冒充：只能命令自己这一方的单位
		if u.order_move(world, cfg, pt):
			any = true
	return any


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

	var any := false
	for id in (cmd.get("ids", []) as Array):
		var u = world.unit_by_id(String(id))
		if u == null or not u.alive:
			continue
		if not FactionRes.same_side(u.faction, owner_faction):
			continue                      # ★ 防冒充
		var accepted: bool
		if target_unit != null:
			accepted = u.order_attack_unit(world, cfg, target_unit)
		else:
			accepted = u.order_attack_building(world, cfg, target_building)
		if accepted:
			any = true
	return any


## 行军攻击命令（右键双击，等价于 SC2 的按 A 攻击到某点）：
## 走到 (x, y)，**路上遇到敌人就停下来打，打完了继续走**。
## 与 move 的区别只有这一条：move 是明确命令，遇敌不停。
static func apply_attack_move(world, cfg: ConfigRes, cmd: Dictionary) -> bool:
	var owner_faction := String(cmd.get("faction", world.my_faction))
	var pt := Vector2(float(cmd.get("x", 0.0)), float(cmd.get("y", 0.0)))
	var any := false
	for id in (cmd.get("ids", []) as Array):
		var u = world.unit_by_id(String(id))
		if u == null or not u.alive:
			continue
		if not FactionRes.same_side(u.faction, owner_faction):
			continue                      # ★ 防冒充
		if u.order_attack_move(world, cfg, pt):
			any = true
	return any


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
	world.remove_building(b, false)
	world.push_event({"type": "building_demolished", "building": b})
	return true


## 招募命令：把 unit_kind 兵种招到 leader_id 那个将领名下（UI 改版：单位页的命令卡走这条路）。
##
## ★ 命令里只有**兵种与队长 id，没有坐标**：站位由权威侧算
##   （第 1 轮联机时，客机自己挑格子就是作弊，而且它也不知道最新的城墙在哪）。
## ★ 顺序：先校验 → 再扣钱 → 最后生成。反了会出现「钱扣了、兵没出来」。
static func apply_recruit(world, cfg: ConfigRes, cmd: Dictionary) -> bool:
	var owner := String(cmd.get("faction", world.my_faction))
	var kind := String(cmd.get("unit_kind", ""))
	var leader_id := String(cmd.get("leader_id", ""))
	var reason: String = world.can_recruit(kind, leader_id, owner)
	if reason != "":
		world.push_event({"type": "recruit_rejected", "reason": reason, "kind": kind})
		return false
	if not EconomyRes.try_spend(cfg, world.resources, world.recruit_cost(kind)):
		world.push_event({"type": "recruit_rejected", "reason": "cost", "kind": kind})
		return false
	return world.recruit_unit(kind, leader_id, owner) != null


## 调试刷兵命令
static func apply_spawn_enemy(world, _cmd: Dictionary) -> bool:
	return world.spawn_enemy() != null
