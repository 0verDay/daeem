## 无头测试脚手架（对应 docs/architecture.md 第六节）。
extends SceneTree

const _PaletteRes = preload("res://view/palette.gd")

const PATH_CONFIG := "res://logic/config.gd"
const PATH_MAP_DATA := "res://logic/map_data.gd"
const PATH_GRID := "res://logic/grid.gd"

const DEFAULT_MAP_PATH := "res://data/maps/frontier/map.json"

var _pass: int = 0
var _fail: int = 0
var _case_name: String = "unnamed"
var _failed_names: Array[String] = []

func _initialize() -> void:
	printerr("test_case.gd 是脚手架基类，不直接运行；请跑 tests/test_*.gd")
	quit(1)

func run_all(cases: Callable) -> void:
	print("[CASE] %s" % _case_name)
	cases.call()
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)

const SPEED_BASELINE := 2.4

func frames_at_baseline(cfg, base_frames: int) -> int:
	var spd: float = maxf(0.01, float(cfg.unit_speed))
	return int(ceil(float(base_frames) * maxf(1.0, SPEED_BASELINE / spd)))

func ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		_failed_names.append(what)
		printerr("  [FAIL] %s" % what)

func eq(actual: Variant, expected: Variant, what: String) -> void:
	if actual == expected:
		_pass += 1
	else:
		_fail += 1
		_failed_names.append(what)
		printerr("  [FAIL] %s（实际 %s，期望 %s）" % [what, str(actual), str(expected)])

func near(actual: float, expected: float, tol: float, what: String) -> void:
	if absf(actual - expected) <= tol:
		_pass += 1
	else:
		_fail += 1
		_failed_names.append(what)
		printerr("  [FAIL] %s（实际 %f，期望 %f ± %f）" % [what, actual, expected, tol])

func v2_near(actual: Vector2, expected: Vector2, tol: float, what: String) -> void:
	if actual.distance_to(expected) <= tol:
		_pass += 1
	else:
		_fail += 1
		_failed_names.append(what)
		printerr("  [FAIL] %s（实际 %s，期望 %s）" % [what, str(actual), str(expected)])

func v2i_eq(actual: Vector2i, expected: Vector2i, what: String) -> void:
	if actual == expected:
		_pass += 1
	else:
		_fail += 1
		_failed_names.append(what)
		printerr("  [FAIL] %s（实际 %s，期望 %s）" % [what, str(actual), str(expected)])

## 打开「战役」按钮撑开的那块面板，并返回里面那块**战役菜单**（`view/campaign_menu.gd`）。
##
## ★★ 战役菜单现在住在**那块面板里**（左侧轮播 / 顶部关卡圆点 / 右侧描述 / 长按进入）：
##   凡是与「战役菜单」有关的用例，都要先走这一步。
## ★ 用**发信号**等价于点「战役」（不依赖鼠标落在哪），并等转场真的撑开
##   （转场是时间驱动的 Tween，按帧数赌不够）。
## @return 那块战役菜单控件；拿不到时返回 null —— 调用方自己 ok() 断一下再往下走。
func open_campaign_panel(menu) -> Variant:
	if menu == null:
		return null
	var chrome = menu.menu_chrome()
	if chrome == null:
		return null
	return await _open_panel(chrome, func(): return menu.campaign_menu())


## 只把「战役」面板撑开，不要内容（给只关心面板开合 / 返回按钮的用例）。
## @return true = 面板已处于撑开态
func open_panel(menu) -> bool:
	if menu == null:
		return false
	var chrome = menu.menu_chrome()
	if chrome == null:
		return false
	var got = await _open_panel(chrome, func(): return true)
	return got == true


func _open_panel(chrome, getter: Callable) -> Variant:
	var engine = chrome.expand_engine()
	# ★ 先等引擎空下来：**入场那一下的「滑入」也是它跑的**（`play_intro()`），
	#   它忙的时候 `expand()` 会被直接忽略 —— 不等的话这里会白等到超时再返回 null。
	var deadline: int = Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline and engine.is_busy():
		await process_frame
	if not engine.is_expanded():
		var side: Array = chrome.side_buttons()
		if side.is_empty():
			return null
		(side[0] as Button).pressed.emit()
		# 转场是**时间驱动**的 Tween：等它真的撑开（按帧数赌不够）
		var open_deadline: int = Time.get_ticks_msec() + 8000
		while Time.get_ticks_msec() < open_deadline and not engine.is_expanded():
			await process_frame
		await process_frame
	return getter.call()


func script_at(path: String) -> GDScript:
	var s := load(path)
	if s == null:
		ok(false, "脚本能载入：%s" % path)
		return null
	return s

func make_test_camera(cfg, cols: int = 27, rows: int = 22,
		vw: float = 1920.0, vh: float = 1080.0) -> Camera3D:
	if cfg == null:
		return null
	cfg.set_viewport_size(vw, vh)
	var cam: Camera3D = root.get_node_or_null("TestCamera3D")
	if cam == null:
		cam = Camera3D.new()
		cam.name = "TestCamera3D"
		root.add_child(cam)
	cam.fov = rad_to_deg(cfg.cam_fov)
	var center := Vector3(float(cols) * cfg.cell_px * 0.5, 0.0, float(rows) * cfg.cell_px * 0.5)
	var up := Vector3(0.0, sin(cfg.cam_pitch), cos(cfg.cam_pitch)).normalized()
	var d: float = cfg.cam_height
	cam.near = 1.0
	cam.far = d * 4.0 + 1000.0
	cam.position = center + up * d
	cam.look_at(center, Vector3.UP)
	cam.fov = rad_to_deg(cfg.cam_fov)
	return cam

func make_test_palette(cfg, cam: Camera3D) -> RefCounted:
	if cfg == null or cam == null:
		return null
	return _PaletteRes.create(cfg, cam)

func require_config() -> RefCounted:
	var cls := script_at(PATH_CONFIG)
	if cls == null:
		return null
	var cfg = cls.load_default()
	ok(cfg != null, "config.json 能载入（%s）" % cls.last_error)
	return cfg

func require_map(cfg, path: String = DEFAULT_MAP_PATH) -> RefCounted:
	var cls := script_at(PATH_MAP_DATA)
	if cls == null:
		return null
	var m = cls.load_from(path, cfg)
	ok(m != null, "map json 能载入：%s" % path)
	return m

func require_world(cfg, world_path: String = "res://logic/world.gd",
		map_path: String = DEFAULT_MAP_PATH) -> RefCounted:
	var cls := script_at(world_path)
	if cls == null:
		return null
	var w = cls.create(cfg, map_path, false)
	ok(w != null, "世界能建出来（不带阵营 AI）")
	return w

func require_world_with_escorts(cfg, per_general: int = 3, faction: String = "p1",
		map_path: String = DEFAULT_MAP_PATH) -> RefCounted:
	if per_general <= 0:
		return require_world(cfg, "res://logic/world.gd", map_path)
	var world_path := "res://logic/world.gd"
	var level_path := "res://logic/level.gd"
	var wcls := script_at(world_path)
	var lcls := script_at(level_path)
	if wcls == null or lcls == null:
		return null
	var probe = wcls.create(cfg, map_path, false)
	if probe == null:
		ok(false, "探针世界能建出来（%s）" % map_path)
		return null
	var spawns: Array = probe.faction_spawns.get(faction, [])
	var ccls := script_at(PATH_CONFIG)
	var c = ccls.load_default() if ccls != null else null
	var units: Array = []
	for gi in 3:
		var gt: String = String(c.general_type_at(gi)) if c != null else "spearman"
		var tile := Vector2i(-1, -1)
		if gi < spawns.size():
			tile = spawns[gi]
		if tile.x < 0:
			tile = Vector2i(int(probe.map.base.x), int(probe.map.base.y))
		units.append({
			"faction": faction,
			"kind": "general" if gi == 0 else "general_%d" % (gi + 1),
			"unit_type": gt,
			"general_index": gi + 1,
			"x": tile.x, "y": tile.y,
			"escort_count": per_general,
			"escort_types": [{"type": gt, "weight": 1}],
		})
	var text := JSON.stringify({
		"map": "frontier",
		"name": "escort scaffold",
		"players": [{"faction": "p1"}],
		"factions": [{"id": faction}],
		"start_units": units,
	})
	var path := "res://.tmp_test_case/escort_scaffold.json"
	DirAccess.make_dir_recursive_absolute("res://.tmp_test_case")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		ok(false, "能写探针关卡：%s" % path)
		return null
	f.store_string(text)
	f.close()
	var lv = lcls.load_level(null, path, cfg)
	if lv == null:
		ok(false, "探针关卡能载入：%s" % path)
		return null
	var w = wcls.create_from_level(cfg, lv, faction, [faction], false)
	ok(w != null, "世界能建出来（带关卡摆放的附属兵）")
	return w

func cleanup_escort_scaffold() -> void:
	var path := "res://.tmp_test_case/escort_scaffold.json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	if DirAccess.dir_exists_absolute("res://.tmp_test_case"):
		DirAccess.remove_absolute("res://.tmp_test_case")

func kill_unit_now(cfg, w, u, dt: float = 1.0 / 60.0) -> void:
	if u == null or not u.alive:
		return
	while u.train_queue_size() > 0:
		if not w.cancel_recruit(String(u.id), 0, String(u.faction)):
			break
	for m in w.retinue_of(String(u.id), true):
		m.take_damage(cfg, w, m.hp + 999999.0, null)
	w.tick(dt)
	u.take_damage(cfg, w, u.hp + 999999.0, null)
