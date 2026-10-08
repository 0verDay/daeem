## test_projectile.gd —— 射箭投掷物：**飞行 + 命中结算**（本轮新增）
##
## ★★ 这个文件存在的理由：投掷物把「开火」与「造成伤害」**拆成了两帧**，
##   而那是最容易**静默错**的一类改动 —— 它不会报错，只会让「掉血晚了一点」
##   或「某些单位永远打不中」。所以这里用**可数的痕迹**（`world.projectiles` 的数量、
##   命中帧数）与**可复算的结果**（掉血量）来钉：
##     · 远程开火 ⇒ 生成 1 枚投掷物、目标**当帧不掉血**、飞行后掉 `combat_damage`；
##     · 必中：目标中途移动也照样掉血；
##     · 近战**逐位不变**（不生成投掷物、伤害即时）；
##     · 箭塔（可攻击建筑）同样走投掷物；
##     · 目标中途消失 ⇒ 投掷物飞完自然消失（不崩）；
##     · `reset()` 清空；同一配置两次运行命中帧数一致（确定性）；
##     · 视图侧留下可数痕迹（`projectile_count` / 拖尾线段数）。
##
## ⚠️ 挂节点必须在 `await process_frame` 之后（pitfalls 1.2）。
extends "res://tests/test_case.gd"

const ConfigRes = preload("res://logic/config.gd")
const ProjectileRes = preload("res://logic/projectile.gd")
const CombatRes = preload("res://logic/combat.gd")
const ProjectileViewRes = preload("res://view/projectile_view_3d.gd")

const DT := 1.0 / 60.0


func _initialize() -> void:
	_case_name = "test_projectile"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	_test_config(cfg)
	_test_ranged_delayed_hit(cfg)
	_test_guaranteed_hit_moving(cfg)
	_test_melee_instant(cfg)
	_test_tower_projectile(cfg)
	_test_target_dies_midflight(cfg)
	_test_reset_clears(cfg)
	_test_determinism(cfg)
	await process_frame
	_test_view(cfg)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 配置：投掷物参数读得到、且合法
# ------------------------------------------------------------------
func _test_config(cfg) -> void:
	ok(cfg.projectile_speed > 0.0, "投掷物速度 > 0（%.1f 格/秒）" % cfg.projectile_speed)
	ok(cfg.projectile_max_sec >= cfg.projectile_min_sec, "飞行时长上限 ≥ 下限")
	ok(cfg.num("render.projectile_size", 0.0) > 0.0, "小方块尺寸配了（render.projectile_size）")
	ok(int(cfg.num("render.projectile_trail_len", 0.0)) >= 2, "拖尾点数 ≥ 2")


# ------------------------------------------------------------------
# 一、远程开火：**当帧不掉血**，飞行后结算
# ------------------------------------------------------------------
func _test_ranged_delayed_hit(cfg) -> void:
	var w = require_world(cfg)
	var shooter = _ranged_of(w)
	ok(shooter != null, "（前提）p1 有一个远程单位（长弓）")
	if shooter == null:
		return
	var e = w.spawn_enemy()
	ok(e != null, "（前提）刷出一个敌人")
	if e == null:
		return
	e.hp = 100000.0
	_place(w, e, shooter.pos + Vector2(3.0, 0.0))
	var hp0: float = e.hp

	CombatRes.attack_unit(w, cfg, shooter, e)
	eq(w.projectiles.size(), 1, "★ 远程开火生成 1 枚投掷物")
	ok(e.hp == hp0, "★ 命中之前目标不掉血（伤害延迟到命中）")
	if w.projectiles.size() == 1:
		var p = w.projectiles[0]
		ok(p.target == e and not p.target_is_building, "投掷物锁定这个敌人")
		ok(p.duration > 0.0, "飞行时长 > 0（%.3f 秒）" % p.duration)
		ok(p.faction == String(shooter.faction), "投掷物带开火方阵营（视图上色用）")

	var frames := _advance_until_landed(w, cfg, 900)
	ok(frames > 0, "投掷物真的飞了几帧（%d）" % frames)
	eq(w.projectiles.size(), 0, "★ 命中后投掷物消失")
	near(e.hp, hp0 - shooter.combat_damage(cfg), 1e-6, "★ 命中后扣 combat_damage")


# ------------------------------------------------------------------
# 二、必中：目标中途移动也照样命中
# ------------------------------------------------------------------
func _test_guaranteed_hit_moving(cfg) -> void:
	var w = require_world(cfg)
	var shooter = _ranged_of(w)
	var e = w.spawn_enemy()
	if shooter == null or e == null:
		ok(false, "（前提）远程单位与敌人都在")
		return
	e.hp = 100000.0
	_place(w, e, shooter.pos + Vector2(4.0, 0.0))
	var hp0: float = e.hp

	CombatRes.attack_unit(w, cfg, shooter, e)
	# 飞两帧后把目标挪到别处（模拟敌人在投掷物飞行途中逃跑）
	ProjectileRes.update(w, cfg, DT)
	ProjectileRes.update(w, cfg, DT)
	_place(w, e, shooter.pos + Vector2(6.0, 3.0))
	var frames := _advance_until_landed(w, cfg, 1200)
	ok(frames > 0, "目标移动后投掷物仍在飞（%d 帧）" % frames)
	eq(w.projectiles.size(), 0, "★ 投掷物一定到达（必中）")
	near(e.hp, hp0 - shooter.combat_damage(cfg), 1e-6, "★ 目标真的掉血了（必中 = 命中即结算）")


# ------------------------------------------------------------------
# 三、近战逐位不变：不生成投掷物、伤害即时
# ------------------------------------------------------------------
func _test_melee_instant(cfg) -> void:
	var w = require_world(cfg)
	var m = _melee_of(w)
	ok(m != null, "（前提）p1 有一个近战单位（长枪 / 骑手）")
	if m == null:
		return
	var e = w.spawn_enemy()
	if e == null:
		return
	e.hp = 100000.0
	_place(w, e, m.pos + Vector2(1.0, 0.0))
	var hp0: float = e.hp
	CombatRes.attack_unit(w, cfg, m, e)
	eq(w.projectiles.size(), 0, "★ 近战不生成投掷物（老行为逐位不变）")
	near(e.hp, hp0 - m.combat_damage(cfg), 1e-6, "★ 近战伤害即时结算")


# ------------------------------------------------------------------
# 四、箭塔（可攻击建筑）也走投掷物
# ------------------------------------------------------------------
func _test_tower_projectile(cfg) -> void:
	var w = require_world(cfg)
	_remove_towers(w)
	var base_b = w.find_base_of(w.my_faction)
	ok(base_b != null, "（前提）己方大本营在")
	if base_b == null:
		return
	var tile: Vector2i = _free_tile_near(w, int(base_b.tx) + 4, int(base_b.ty))
	ok(tile.x >= 0, "（前提）找得到建塔的空格")
	if tile.x < 0:
		return
	# 末尾 true = instant（跳过建造读条，本节验的是开火）
	var tower = w.add_building("tower", tile.x, tile.y, w.my_faction, false, true)
	ok(tower != null, "（前提）箭塔建好了")
	if tower == null:
		return
	var e = w.spawn_enemy()
	if e == null:
		return
	e.hp = 100000.0
	_place(w, e, tower.center() + Vector2(2.0, 0.0))
	var hp0: float = e.hp

	CombatRes.update_towers(w, cfg, DT)
	ok(w.projectiles.size() >= 1, "★ 箭塔开火生成投掷物")
	ok(e.hp == hp0, "★ 命中前不掉血")
	_advance_until_landed(w, cfg, 900)
	eq(w.projectiles.size(), 0, "箭塔的投掷物命中后消失")
	near(e.hp, hp0 - tower.attack_damage(cfg), 1e-6, "★ 箭塔伤害在命中时结算")


# ------------------------------------------------------------------
# 五、目标中途消失：飞完自然消失、不崩、不造成伤害
# ------------------------------------------------------------------
func _test_target_dies_midflight(cfg) -> void:
	var w = require_world(cfg)
	var shooter = _ranged_of(w)
	var e = w.spawn_enemy()
	if shooter == null or e == null:
		ok(false, "（前提）远程单位与敌人都在")
		return
	_place(w, e, shooter.pos + Vector2(4.0, 0.0))
	CombatRes.attack_unit(w, cfg, shooter, e)
	eq(w.projectiles.size(), 1, "（前提）投掷物在飞")
	e.alive = false                       # 目标在半路没了
	var frames := _advance_until_landed(w, cfg, 900)
	ok(frames > 0, "目标消失后投掷物照飞（%d 帧）" % frames)
	eq(w.projectiles.size(), 0, "★ 投掷物飞完自然消失（不崩、不报错）")


# ------------------------------------------------------------------
# 六、reset() 清空
# ------------------------------------------------------------------
func _test_reset_clears(cfg) -> void:
	var w = require_world(cfg)
	var shooter = _ranged_of(w)
	var e = w.spawn_enemy()
	if shooter == null or e == null:
		ok(false, "（前提）远程单位与敌人都在")
		return
	_place(w, e, shooter.pos + Vector2(4.0, 0.0))
	CombatRes.attack_unit(w, cfg, shooter, e)
	eq(w.projectiles.size(), 1, "（前提）有投掷物在飞")
	w.reset()
	eq(w.projectiles.size(), 0, "★ reset() 清空投掷物")


# ------------------------------------------------------------------
# 七、确定性：同一配置两次运行，命中帧数一致
# ------------------------------------------------------------------
func _test_determinism(cfg) -> void:
	var f1 := _ranged_hit_frames(cfg)
	var f2 := _ranged_hit_frames(cfg)
	ok(f1 > 0, "命中帧数 > 0（%d）" % f1)
	eq(f1, f2, "★ 同一配置两次运行的命中帧数一致（确定性）")


func _ranged_hit_frames(cfg) -> int:
	var w = require_world(cfg)
	var shooter = _ranged_of(w)
	var e = w.spawn_enemy()
	if shooter == null or e == null:
		return -1
	e.hp = 100000.0
	_place(w, e, shooter.pos + Vector2(3.0, 0.0))
	CombatRes.attack_unit(w, cfg, shooter, e)
	return _advance_until_landed(w, cfg, 900)


# ------------------------------------------------------------------
# 八、视图：读得到、画得出（留下可数痕迹）
# ------------------------------------------------------------------
func _test_view(cfg) -> void:
	var w = require_world(cfg)
	var shooter = _ranged_of(w)
	var e = w.spawn_enemy()
	if shooter == null or e == null:
		ok(false, "（前提）远程单位与敌人都在")
		return
	_place(w, e, shooter.pos + Vector2(3.0, 0.0))
	CombatRes.attack_unit(w, cfg, shooter, e)

	var cam: Camera3D = make_test_camera(cfg)
	var pal = make_test_palette(cfg, cam)
	ok(cam != null and pal != null, "（前提）测试相机 / palette 可用")
	if pal == null:
		return
	var pv = ProjectileViewRes.new()
	root.add_child(pv)
	pv.setup(cfg, w, pal)
	pv.sync()
	eq(pv.projectile_count, 1, "★ 视图看到 1 枚投掷物")
	eq(pv.visible_projectile_count, 1, "★ 己方投掷物对玩家可见")
	ok(pv.slots_created >= 1, "对象池为它建了一个 slot")
	# 第二次 sync 之后历史里就有两个点 ⇒ 拖尾才画得出线段
	pv.sync()
	ok(pv.trail_segments_last_frame >= 1,
		"★ 拖尾画出了线段（%d 段）" % pv.trail_segments_last_frame)
	pv.queue_free()


# ------------------------------------------------------------------
# 帮助函数
# ------------------------------------------------------------------
func _ranged_of(w):
	for u in w.units:
		if u.ranged:
			return u
	return null


func _melee_of(w):
	for u in w.units:
		if not u.ranged:
			return u
	return null


## 把单位摆到一个逻辑位置（直接改 pos，不走寻路 —— 本节验的是投掷物，不是移动）。
func _place(w, u, pos: Vector2) -> void:
	u.pos = pos
	u.sync_tile(w.map)
	u.stop()


## 反复推进投掷物直到全部落地（或超过上限）；返回推进了几帧。
## ★ 直接调 `ProjectileRes.update`（不跑 world.tick）⇒ **确定性**：
##   世界里别的单位不会在本用例中途行动。
func _advance_until_landed(w, cfg, max_frames: int) -> int:
	var frames := 0
	while not w.projectiles.is_empty() and frames < max_frames:
		ProjectileRes.update(w, cfg, DT)
		frames += 1
	return frames


func _free_tile_near(w, cx: int, cy: int) -> Vector2i:
	for r in range(0, 9):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				if absi(dx) != r and absi(dy) != r:
					continue
				var t := Vector2i(cx + dx, cy + dy)
				if w.can_build_at(t.x, t.y):
					return t
	return Vector2i(-1, -1)


func _remove_towers(w) -> void:
	for b in w.building_list.duplicate():
		if String(b.type) == "tower":
			w.remove_building(b, false)
