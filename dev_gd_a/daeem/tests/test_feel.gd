## test_feel.gd —— 2026.11 手感改动的纯逻辑 / 表现层断言
##
## 覆盖：
##   · C1/C2/C4 的配置与「无头默认关闭缓动」；
##   · F1 光标状态机（纯静态函数）；
##   · F2 拒绝红环的生命周期 + 拒绝文案；
##   · M1 行走微动（纯静态函数）；
##   · M3 死亡烟尘（对象池 spawn / sync / clear）；
##   · P1 桌面默认 60Hz 的配置值；
##   · P2 `_settled_index` 的「排除本次队伍」与 `tile_key` 一致性。
extends "res://tests/test_case.gd"

const Game3DRes = preload("res://view/game_scene3d.gd")
const Overlay3DRes = preload("res://view/overlay_view_3d.gd")
const HudRes = preload("res://view/hud.gd")
const DeathFxRes = preload("res://view/death_fx_view_3d.gd")
const UnitViewRes = preload("res://view/unit_view_3d.gd")
const SpriteRes = preload("res://view/unit_sprite_3d.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const UnitRes = preload("res://logic/unit.gd")


func _initialize() -> void:
	_case_name = "test_feel"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	var world = require_world(cfg)
	if world == null:
		quit(1)
		return
	await process_frame

	_test_config(cfg)
	_test_cursor()
	_test_walk_bob(cfg)
	_test_reject_fx()
	_test_death_fx(cfg, world)
	_test_settled_index(world)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 0) 配置 / 平台
# ------------------------------------------------------------------
func _test_config(cfg) -> void:
	near(cfg.sim_step_sec, 1.0 / 60.0, 1e-6, "★ P1：桌面默认 60Hz（sim.step_sec = 1/60）")
	ok(cfg.cam_jump_sec > 0.0, "★ C2：程序性跳转缓动开着（camera.jump_sec = %.3f）" % cfg.cam_jump_sec)
	ok(cfg.cam_zoom_lerp_sec > 0.0, "★ C4：缩放缓动开着（camera.zoom_lerp_sec = %.3f）" % cfg.cam_zoom_lerp_sec)
	ok(cfg.custom_cursor_enabled, "★ F1：自绘光标默认开着")
	ok(Game3DRes._is_headless(), "★ 测试在无头下运行（缓动会退回立即版）")


# ------------------------------------------------------------------
# 1) F1 光标状态机
# ------------------------------------------------------------------
func _test_cursor() -> void:
	eq(Game3DRes.cursor_mode_of(true, "", false, "", false), "ui", "★ 光标：压在 UI 上 = ui")
	eq(Game3DRes.cursor_mode_of(false, "wall", true, "", false), "build", "★ 光标：建造模式且可建 = build")
	eq(Game3DRes.cursor_mode_of(false, "wall", false, "", false), "invalid", "★ 光标：建造模式但不可建 = invalid")
	eq(Game3DRes.cursor_mode_of(false, "", false, "attack", true), "attack", "★ 光标：攻击模式 + 悬停敌人 = attack")
	eq(Game3DRes.cursor_mode_of(false, "", false, "attack", false), "order", "★ 光标：攻击模式但没敌人 = order")
	eq(Game3DRes.cursor_mode_of(false, "", false, "", true), "attack", "★ 光标：普通模式悬停敌人 = attack")
	eq(Game3DRes.cursor_mode_of(false, "", false, "", false), "normal", "★ 光标：普通空地 = normal")


# ------------------------------------------------------------------
# 2) M1 行走微动
# ------------------------------------------------------------------
func _test_walk_bob(cfg) -> void:
	eq(UnitViewRes.walk_scale("a", false, 1.0, 0.02, 2.0), 1.0, "★ M1：停下的单位不呼吸")
	eq(UnitViewRes.walk_scale("a", true, 1.0, 0.0, 2.0), 1.0, "★ M1：ratio = 0 = 关掉")
	var lo := 1.0
	var hi := 1.0
	for i in 20:
		var s: float = UnitViewRes.walk_scale("a", true, float(i) * 0.05, 0.02, 2.0)
		lo = minf(lo, s)
		hi = maxf(hi, s)
	ok(lo < 1.0 and hi > 1.0, "★ M1：行走时在 1.0 上下起伏（%.4f ~ %.4f）" % [lo, hi])
	ok(lo >= 0.98 - 1e-6 and hi <= 1.02 + 1e-6, "★ M1：起伏不超过配置幅度")
	var different := false
	for i in 8:
		var tt: float = float(i) * 0.17
		if absf(UnitViewRes.walk_scale("unit-a", true, tt, 0.02, 2.0)
				- UnitViewRes.walk_scale("unit-b", true, tt, 0.02, 2.0)) > 1e-4:
			different = true
			break
	ok(different, "★ M1：不同单位的相位不同（不会整齐划一）")


# ------------------------------------------------------------------
# 3) F2 拒绝红环 + 文案
# ------------------------------------------------------------------
func _test_reject_fx() -> void:
	var ov = Overlay3DRes.new()
	root.add_child(ov)
	ov.add_reject(Vector2(3.5, 4.5))
	eq(ov.reject_marks.size(), 1, "★ F2：拒绝红环进队")
	ov.tick_rejects(0.1)
	eq(ov.reject_marks.size(), 1, "★ F2：寿命没到还在")
	ov.tick_rejects(1.0)
	eq(ov.reject_marks.size(), 0, "★ F2：寿命到了自动清掉")
	ov.queue_free()

	var hud = HudRes.new()
	root.add_child(hud)
	ok(hud.build_reject_text("cost").contains("资源"), "★ F2：建造被拒（cost）有明确文案")
	ok(hud.build_reject_text("not_in_zone").contains("己方区划"), "★ F2：建造被拒（not_in_zone）有明确文案")
	hud.flash_reject()
	ok(hud.reject_flash_active(), "★ F2：命令卡闪红开始")
	hud._tick_reject_flash(1.0)
	ok(not hud.reject_flash_active(), "★ F2：命令卡闪红会自己结束")
	hud.queue_free()


# ------------------------------------------------------------------
# 4) M3 死亡烟尘
# ------------------------------------------------------------------
func _test_death_fx(cfg, world) -> void:
	var cam := make_test_camera(cfg, int(world.map.cols), int(world.map.rows))
	var palette := make_test_palette(cfg, cam)
	ok(palette != null, "（前提）测试投影助手可用")
	var tex = SpriteRes.soft_circle_texture()
	ok(tex != null and tex.get_width() > 0, "★ M3：软圆烟尘贴图能生成")
	var fx = DeathFxRes.new()
	root.add_child(fx)
	fx.setup(cfg, palette)
	eq(fx.spawn_count, 0, "★ M3：初始没有烟尘")
	fx.spawn(Vector2(4.5, 4.5), Color(0.8, 0.2, 0.2))
	eq(fx.spawn_count, 1, "★ M3：spawn 计数")
	fx.sync(0.1)
	ok(fx.active_count >= 1, "★ M3：烟尘在推进")
	fx.sync(1.0)
	eq(fx.active_count, 0, "★ M3：寿命到了自动收掉")
	fx.clear()
	fx.queue_free()


# ------------------------------------------------------------------
# 5) P2 空间索引
# ------------------------------------------------------------------
func _test_settled_index(world) -> void:
	var alive: Array = []
	for u in world.units:
		if u.alive:
			alive.append(u)
		if alive.size() >= 2:
			break
	if alive.size() < 2:
		ok(true, "（跳过）场上不足两个单位")
		return
	var a = alive[0]
	var b = alive[1]
	eq(UnitRes.tile_key(a.tx, a.ty), a.tx * 4096 + a.ty,
		"★ P2：tile_key 公式与 command_processor 的索引一致")
	var idx: Dictionary = CommandRes._settled_index(world, [a])
	var k: int = UnitRes.tile_key(b.tx, b.ty)
	var arr: Array = idx.get(k, [])
	ok(arr.has(b), "★ P2：不在本次命令里的单位被收进索引")
	var ka: int = UnitRes.tile_key(a.tx, a.ty)
	var ar2: Array = idx.get(ka, [])
	ok(not ar2.has(a), "★ P2：本次命令里的单位被排除（它们马上要走）")
