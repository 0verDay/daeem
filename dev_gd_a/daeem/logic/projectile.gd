## projectile.gd —— 射箭投掷物：**权威飞行 + 命中结算**（远程单位 / 可攻击建筑）
##
## ★★ 为什么它在 `logic/` 而不是 `view/`（本轮最重要的取舍）：
##   用户口径是「伤害延迟到投掷物**接触目标那一刻**」。伤害是**权威状态**，
##   所以投掷物必须是逻辑层的状态（`world.projectiles`）—— 它参与 `world.tick()`
##   与快照；视图只读它，只负责把它画成一个方块 + 一条拖尾。
##
## ★★ 轨迹：逻辑只走**地面直线 + 进度**：`pos = start.lerp(end, t)`，
##   而 `end` 每帧刷新为目标的**当前位置** ⇒ 这就是「索敌（homing）」。
##   ★ 抛物线的高度是**纯表现**（`view/projectile_view_3d.gd` 按**同一个 `t`** 叠在 y 上）——
##     逻辑里没有高度、没有相机（那是 `logic/` 的两条铁律）。
##     「看到的命中」与「逻辑的命中」因此**同帧**。
##
## ★ 必中：`t` 到 1 就一定结算；除非目标中途消失 —— 那时飞完自然消失、**不造成伤害**。
##
## ⚠️ 本文件**不 preload unit.gd / building.gd**：只用鸭子类型读目标的
##    `alive` / `pos` / `center()` / `take_damage()`。preload 会与 combat.gd 形成
##    循环依赖（Godot 直接报 Could not resolve script）。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")


## 生成一枚投掷物并挂到世界上（由 combat.gd 的三处开火调用）。
##
## @param faction           开火方阵营（视图上色 + 迷雾可见性用它）
## @param source            开火者（单位或建筑；命中时作为伤害来源传给 take_damage）
## @param start_pos         起点（逻辑格；单位 = 它的 pos，建筑 = center()）
## @param target            目标（单位或建筑；索敌就是每帧读它的当前位置）
## @param target_is_building 目标是不是建筑（决定取 pos 还是 center()）
static func spawn(world, cfg: ConfigRes, faction: String, source, start_pos: Vector2,
		target, target_is_building: bool, damage: float) -> RefCounted:
	var p = new()
	p.faction = faction
	p.source = source
	p.start = start_pos
	p.target = target
	p.target_is_building = target_is_building
	p.damage = damage
	p.end = _target_pos(target, target_is_building, start_pos)
	p.pos = start_pos
	p.t = 0.0
	p.elapsed = 0.0
	# 飞行时长 = 距离 / 速度，夹在 [min, max] 之间
	# （贴脸也看得见飞一下；远距离也别飞太久）。
	var dist: float = start_pos.distance_to(p.end)
	p.duration = clampf(dist / maxf(0.1, cfg.projectile_speed),
		cfg.projectile_min_sec, cfg.projectile_max_sec)
	p.alive = true
	world.projectiles.append(p)
	return p


## 每帧推进所有投掷物（`world.tick` 里、单位与箭塔都开完火之后调用）。
static func update(world, cfg: ConfigRes, dt: float) -> void:
	if world.projectiles.is_empty():
		return
	var kept: Array = []
	for p in world.projectiles:
		if p.alive and dt > 0.0:
			p.elapsed += dt
			# ★ 索敌：目标还在就跟着它走（这就是 homing；也是「必中」的来源）。
			if _target_valid(p):
				p.end = _target_pos(p.target, p.target_is_building, p.end)
			p.t = clampf(p.elapsed / maxf(0.0001, p.duration), 0.0, 1.0)
			p.pos = p.start.lerp(p.end, p.t)
			if p.t >= 1.0:
				_impact(world, cfg, p)
				p.alive = false
		if p.alive:
			kept.append(p)
	world.projectiles = kept


## 目标还“在场且可打”吗？（单位与建筑都有 `alive`）
static func _target_valid(p) -> bool:
	var t = p.target
	return t != null and bool(t.alive)


## 目标当前位置（逻辑格）：单位取 `pos`，建筑取 `center()`；目标为空时退回旧值。
static func _target_pos(target, is_building: bool, fallback: Vector2) -> Vector2:
	if target == null:
		return fallback
	if is_building:
		return target.center()
	return target.pos


## 命中结算。⚠️ 目标已消失 ⇒ 什么都不做（飞完自然消失）。
##
## ★ 拆建筑那一下要沿用 combat.attack_building 的口径：`take_damage` 返回
##   「**本击是否造成摧毁**」，只在**首次**摧毁时广播 `building_down`，
##   否则同一帧几枚投掷物砸同一栋会广播出好几条重复事件。
static func _impact(world, cfg: ConfigRes, p) -> void:
	if not _target_valid(p):
		return
	if p.target_is_building:
		if p.target.take_damage(cfg, p.damage, p.source):
			world.push_event({"type": "building_down", "building": p.target, "source": p.source})
	else:
		p.target.take_damage(cfg, world, p.damage, p.source)


# ------------------------------------------------------------------
# 状态（公开字段：视图与快照直接读，本工程不给自持状态套 getter）
# ------------------------------------------------------------------
## 开火方阵营
var faction: String = ""
## 开火者（单位或建筑）
var source = null
## 目标（单位或建筑）—— 索敌就是每帧读它的位置
var target = null
## 目标是不是建筑
var target_is_building: bool = false
## 起点（逻辑格，生成时固定）
var start: Vector2 = Vector2.ZERO
## 终点（逻辑格；目标还在时每帧刷新为它的当前位置）
var end: Vector2 = Vector2.ZERO
## 当前地面位置（逻辑格 = start.lerp(end, t)）
var pos: Vector2 = Vector2.ZERO
## 进度 0..1（视图按它叠抛物线高度，与逻辑同帧）
var t: float = 0.0
## 已飞行的秒数 / 总时长（秒）
var elapsed: float = 0.0
var duration: float = 0.0
## 命中时结算的伤害
var damage: float = 0.0
## 还在飞（false = 本帧被移除）
var alive: bool = true
