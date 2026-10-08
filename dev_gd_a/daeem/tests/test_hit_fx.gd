## test_hit_fx.gd —— 受击动效：**闪白 + 左右振动**（本轮新增）
##
## ★★ 这个文件存在的理由：受击反应是「逻辑置一个计时位 → 三个视图层各自画」，
##   而这条链最容易**静默断掉**（置位了没人衰减 / 画的时候漏了一层 / 迷雾里也画了），
##   都不报错。所以用可数的痕迹（`hit_flash` 的值、`shake_applied_last_frame`、
##   `hit_flash_count`）与可复算的数学（`HitFxRes.shake_tiles`）来钉。
##
## ⚠️ 挂节点必须在 `await process_frame` 之后（pitfalls 1.2）。
extends "res://tests/test_case.gd"

const CombatRes = preload("res://logic/combat.gd")
const HitFxRes = preload("res://view/hit_fx.gd")
const UnitViewRes = preload("res://view/unit_view_3d.gd")
const BuildingViewRes = preload("res://view/building_view_3d.gd")

const DT := 1.0 / 60.0


func _initialize() -> void:
	_case_name = "test_hit_fx"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	_test_config(cfg)
	_test_shake_math(cfg)
	_test_unit_hit(cfg)
	_test_building_hit(cfg)
	await process_frame
	_test_views(cfg)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 配置
# ------------------------------------------------------------------
func _test_config(cfg) -> void:
	ok(cfg.hit_flash_sec > 0.0, "受击动效时长 > 0（%.2f 秒）" % cfg.hit_flash_sec)
	near(cfg.hit_flash_sec_safe, maxf(0.01, cfg.hit_flash_sec), 1e-9, "预计算的除数一致")
	ok(cfg.num("render.hit_shake_cells", 0.0) > 0.0, "振动幅度配了")
	ok(cfg.num("render.hit_flash_alpha", 0.0) > 0.0, "闪白不透明度配了")


# ------------------------------------------------------------------
# 振动的数学：flash = 0 不抖；有 flash 时幅度不超过振幅；能来回摆
# ------------------------------------------------------------------
func _test_shake_math(cfg) -> void:
	var amp: float = cfg.num("render.hit_shake_cells", 0.06)
	var freq: float = cfg.num("render.hit_shake_freq", 26.0)
	eq(HitFxRes.shake_tiles(0.0, amp, freq), 0.0, "flash = 0 ⇒ 不振动")
	var saw_nonzero := false
	var max_seen := 0.0
	for k in range(1, 20):
		var f: float = float(k) / 20.0
		var v: float = HitFxRes.shake_tiles(f, amp, freq)
		max_seen = maxf(max_seen, absf(v))
		if absf(v) > 1e-6:
			saw_nonzero = true
		ok(absf(v) <= amp + 1e-9, "位移不超过振幅（flash=%.2f → %.4f）" % [f, v])
	ok(saw_nonzero, "★ 有 flash 时会真的振动（位移非零）")
	ok(max_seen > amp * 0.2, "★ 振幅用得上（峰值 %.4f 格）" % max_seen)


# ------------------------------------------------------------------
# 单位：被打中置 1、按 hit_flash_sec 衰减；免疫的单位不吃
# ------------------------------------------------------------------
func _test_unit_hit(cfg) -> void:
	var w = require_world(cfg)
	var u = w.units[0]
	u.hp = 100000.0
	eq(u.hit_flash, 0.0, "（前提）开局没有受击闪光")
	u.take_damage(cfg, w, 10.0, null)
	eq(u.hit_flash, 1.0, "★ 被打中 ⇒ hit_flash = 1.0")

	# 直接推 unit 的每帧逻辑（不跑 world.tick ⇒ 别的单位不会中途干预）
	var steps: int = int(ceil(cfg.hit_flash_sec / DT)) + 2
	for i in steps:
		CombatRes.update_unit(w, cfg, u, DT, -1)
	eq(u.hit_flash, 0.0, "★ 受击闪光在 hit_flash_sec 内衰减到 0")

	# 濒死 / 免疫的单位不吃伤害 ⇒ 也不该有受击反应
	var u2 = null
	if w.units.size() > 1:
		u2 = w.units[1]
	if u2 != null:
		u2.hit_flash = 0.0
		u2.downed = true
		u2.take_damage(cfg, w, 10.0, null)
		eq(u2.hit_flash, 0.0, "★ 濒死（免疫）的单位不吃受击反应")


# ------------------------------------------------------------------
# 建筑：被打中置 1；无敌建筑（区划中心）不受击
# ------------------------------------------------------------------
func _test_building_hit(cfg) -> void:
	var w = require_world(cfg)
	var b = w.find_base_of(w.my_faction)
	ok(b != null, "（前提）己方大本营在")
	if b != null:
		eq(b.hit_flash, 0.0, "（前提）建筑开局没有受击闪光")
		b.take_damage(cfg, 10.0, null)
		eq(b.hit_flash, 1.0, "★ 建筑被打中 ⇒ hit_flash = 1.0")

	var zc = null
	for bb in w.building_list:
		if bb.is_invulnerable():
			zc = bb
			break
	if zc != null:
		zc.take_damage(cfg, 10.0, null)
		eq(zc.hit_flash, 0.0, "★ 无敌建筑（区划中心）不受击、不闪白")
	else:
		ok(true, "（跳过）这张图没有无敌建筑")


# ------------------------------------------------------------------
# 视图：闪白（逐像素 shader，走每实例自定义数据）+ 振动都留下可数痕迹
# ------------------------------------------------------------------
func _test_views(cfg) -> void:
	var w = require_world(cfg)
	var cam: Camera3D = make_test_camera(cfg)
	var pal = make_test_palette(cfg, cam)
	ok(cam != null and pal != null, "（前提）测试相机 / palette 可用")
	if pal == null:
		return

	var uv = UnitViewRes.new()
	root.add_child(uv)
	uv.setup(cfg, w, pal)
	var u = w.units[0]
	u.hit_flash = 0.5
	uv.sync()
	ok(uv.shake_applied_last_frame >= 1,
		"★ 单位层对受击单位施加了振动（%d 个）" % uv.shake_applied_last_frame)
	ok(uv.flash_written_last_frame >= 1,
		"★ 单位层把闪白写进了每实例自定义数据（shader 读它：%d 次）" % uv.flash_written_last_frame)
	# 脏检查：值没变就不该重写（否则每帧几百次引擎调用）
	uv.sync()
	eq(uv.flash_written_last_frame, 0, "闪白值没变就不重写（脏检查）")
	u.hit_flash = 0.0
	uv.sync()
	eq(uv.shake_applied_last_frame, 0, "没受击时不振动")

	var bv = BuildingViewRes.new()
	root.add_child(bv)
	bv.setup(cfg, w, pal)
	var b = w.find_base_of(w.my_faction)
	if b != null:
		b.hit_flash = 0.5
		bv.sync()
		ok(bv.shake_applied_last_frame >= 1,
			"★ 建筑层对受击建筑施加了振动（%d 栋）" % bv.shake_applied_last_frame)
		ok(bv.flash_written_last_frame >= 1,
			"★ 建筑层把闪白写进了每实例自定义数据（%d 栋）" % bv.flash_written_last_frame)

	uv.queue_free()
	bv.queue_free()
