## test_fog_revision.gd —— 迷雾**版本号闸门**（2026.10.28）的回归。
##
## 钉住三件事：
##   1. 闸门真的生效：什么都没变时连续 `refresh_needed` 都为 false（0.45ms 的采集被跳过）；
##   2. 每条「视野来源变了」的路径都推进 `map.vision_revision`：
##      单位换格 / 出场 / 阵亡 / 建筑增删 / 客机删单位 / `reset_cache`；
##   3. **双路校验**：同一世界放两个 `FogRes`，A 走生产路径（闸门 + update），
##      B 每帧强制全量重建；300 帧逐方掩码**逐字节相等** ——
##      这是「漏钩子 ⇒ 迷雾静默冻结」唯一靠得住的护栏。
##
## ⚠️ 本测试**不改** config.json 的默认值：闸门开关在 cfg 对象上临时改，跑完恢复。
extends "res://tests/test_case.gd"

const FogRes = preload("res://logic/fog.gd")
const GridRes = preload("res://logic/grid.gd")

const DT := 1.0 / 30.0
const SOAK_FRAMES := 300

var _gate_default: bool = true
var _verify_default: bool = false


func _initialize() -> void:
	_case_name = "test_fog_revision"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	# 只测 C# 扁平表这条路（GDScript 后端没有闸门，保持原样）。
	cfg.fog_backend = "csharp"
	_gate_default = bool(cfg.fog_revision_gate)
	_verify_default = bool(cfg.fog_verify_revision)
	cfg.fog_revision_gate = true
	cfg.fog_verify_revision = false
	ok(cfg.fog_revision_gate, "config：fog.revision_gate 默认开着")
	ok(not cfg.fog_verify_revision, "config：fog.verify_revision 默认关着（不做双倍采集）")

	var w = require_world(cfg)
	if w == null:
		_restore(cfg)
		quit(1)
		return
	var fog = w.fog
	ok(fog != null, "世界带迷雾对象")
	if fog == null:
		_restore(cfg)
		quit(1)
		return
	ok(fog.kernel != null, "C# 内核可用（没有它就没有扁平表与闸门）")
	if fog.kernel == null:
		_restore(cfg)
		quit(0)
		return

	_test_idle_gate(w, fog)
	_test_tile_change(w, cfg, fog)
	_test_spawn_drop(w, cfg, fog)
	_test_buildings(w, cfg, fog)
	_test_reset_cache(w, cfg, fog)
	_test_gate_off_fallback(w, cfg, fog)
	_test_death(w, cfg, fog)
	_test_dual_path_soak(w, cfg, fog)

	_restore(cfg)
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _restore(cfg) -> void:
	cfg.fog_revision_gate = _gate_default
	cfg.fog_verify_revision = _verify_default


## 1) 静止时闸门必须一直说「没变」。
func _test_idle_gate(w, fog) -> void:
	fog.update(w)
	ok(not fog.refresh_needed(w), "静止：第一次 refresh_needed = false（没有白采集）")
	ok(not fog.refresh_needed(w), "静止：连续第二次仍然是 false")
	# 再走一个空逻辑步（没有任何人换格）——闸门必须继续挡住。
	w.tick(DT)
	ok(not fog.refresh_needed(w), "空跑一步之后仍然 false（版本号没动）")


## 2) 单位换格 —— 位置写入的公共出口自己推进版本号。
func _test_tile_change(w, cfg, fog) -> void:
	var u = _first_mobile(w)
	if u == null:
		ok(false, "世界里有可移动的单位")
		return
	fog.update(w)
	var rev0 := int(w.map.vision_revision)
	var tx0 := int(u.tx)
	var ty0 := int(u.ty)
	# 挪两格（确保跨格）；用 sync_tile（碰撞 / 传送用同一条路）。
	var nx := mini(int(w.map.cols) - 1, tx0 + 2)
	u.pos = GridRes.center_of(Vector2i(nx, ty0))
	u.sync_tile(w.map)
	ok(int(w.map.vision_revision) > rev0, "换格 ⇒ map.vision_revision 前进")
	ok(fog.refresh_needed(w), "换格 ⇒ 需要重建掩码")
	fog.update(w)
	ok(not fog.refresh_needed(w), "重建之后恢复「没变」")

	# ★ 没换格（只挪了 0.01 格）不该推进版本号 —— 否则碰撞每帧推挤会让闸门失效。
	var rev1 := int(w.map.vision_revision)
	u.pos += Vector2(0.01, 0.01)
	u.sync_tile(w.map)
	eq(int(w.map.vision_revision), rev1, "同格内微调不推进版本号（闸门不会被推挤搞脏）")
	ok(not fog.refresh_needed(w), "同格内微调不算「视野变了」")


## 3) 单位出场 / 客机删单位。
func _test_spawn_drop(w, cfg, fog) -> void:
	fog.update(w)
	var cx := int(w.map.cols) / 2
	var cy := int(w.map.rows) / 2
	var e = w.spawn_enemy(cx, cy)
	if e == null:
		ok(false, "能刷出一个调试敌人（用的格 (x=%d,y=%d)）" % [cx, cy])
		return
	ok(fog.refresh_needed(w), "新单位 ⇒ 需要重建（多了一个视野来源）")
	fog.update(w)
	w.drop_unit_ids([String(e.id)])
	ok(fog.refresh_needed(w), "drop_unit_ids ⇒ 需要重建（客机删掉出视野的单位）")
	fog.update(w)
	ok(not fog.refresh_needed(w), "删掉之后重建完，再次「没变」")


## 4) 阵亡（`unit._die` + 清理段）。
func _test_death(w, cfg, fog) -> void:
	fog.update(w)
	var victim = null
	for u in w.units:
		if u.alive and not u.is_general():
			victim = u
			break
	# 只有将领的世界也要测（阵亡入口 `unit._die` 是同一条）。
	if victim == null:
		for u in w.units:
			if u.alive:
				victim = u
				break
	if victim == null:
		ok(false, "世界里有可击杀的单位")
		return
	var rev0 := int(w.map.vision_revision)
	kill_unit_now(cfg, w, victim)
	ok(int(w.map.vision_revision) > rev0, "阵亡 / 清理推进 vision_revision")
	fog.update(w)
	ok(not fog.refresh_needed(w), "阵亡重建之后「没变」")


## 5) 建筑增删（建筑也是视野来源）。
func _test_buildings(w, cfg, fog) -> void:
	fog.update(w)
	var spot := _free_tile(w)
	if spot == Vector2i(-1, -1):
		ok(false, "地图上有一格能放墙")
		return
	var rev0 := int(w.map.vision_revision)
	var b = w.add_building("wall", spot.x, spot.y, "p1", true, true)
	ok(b != null, "能在 (x=%d,y=%d) 建一堵墙" % [spot.x, spot.y])
	if b == null:
		return
	ok(int(w.map.vision_revision) > rev0, "建建筑推进 vision_revision")
	ok(fog.refresh_needed(w), "建建筑 ⇒ 需要重建（新视野来源）")
	fog.update(w)
	var rev1 := int(w.map.vision_revision)
	w.remove_building(b, true)
	ok(int(w.map.vision_revision) > rev1, "拆建筑推进 vision_revision")
	ok(fog.refresh_needed(w), "拆建筑 ⇒ 需要重建")
	fog.update(w)


## 6) 换地图 / 重开一局：reset_cache 之后第一帧必须重建。
func _test_reset_cache(w, cfg, fog) -> void:
	fog.reset_cache()
	ok(fog.refresh_needed(w), "reset_cache 之后第一帧必须重建（版本号基线被清掉）")
	fog.update(w)
	ok(not fog.refresh_needed(w), "重建之后「没变」")


## 7) 关掉闸门 = 旧行为：直接改 tx（绕过 sync_tile、不推进版本号）也要能发现。
func _test_gate_off_fallback(w, cfg, fog) -> void:
	cfg.fog_revision_gate = false
	fog.update(w)
	var u = _first_mobile(w)
	if u == null:
		# 前序用例可能已经把单位耗光（阵亡用例是最后跑的，但这里仍要稳）。
		u = w.spawn_enemy(int(w.map.cols) / 2, int(w.map.rows) / 2)
	if u == null:
		cfg.fog_revision_gate = true
		ok(false, "闸门回退用例需要至少一个单位")
		return
	var nx := int(w.map.cols) - 1 if int(u.tx) < 2 else 0
	u.tx = nx
	u.ty = clampi(int(u.ty), 0, int(w.map.rows) - 1)
	ok(fog.refresh_needed(w), "闸门关闭 ⇒ 退回全量比较（直接改 tx 也发现得了）")
	fog.update(w)
	ok(not fog.refresh_needed(w), "闸门关闭时重建之后也回到「没变」")
	cfg.fog_revision_gate = true


## 8) 双路校验：生产路径 vs 每帧强制全量，掩码必须逐字节相等。
func _test_dual_path_soak(w, cfg, fog) -> void:
	var ref = FogRes.create()
	ok(ref != null and ref.kernel != null, "第二个 FogRes（参考实现）能建出来")
	if ref == null or ref.kernel == null:
		return
	var mismatches := 0
	var first_bad := ""
	for i in SOAK_FRAMES:
		# A 走生产路径：world.tick 里 refresh_needed → update
		w.tick(DT)
		# B 强制全量：update() 单独调用时一定自己采集
		ref.update(w)
		for side in fog.sight.keys():
			if not ref.sight.has(side):
				mismatches += 1
				first_bad = "第 %d 帧缺方 %s" % [i, String(side)]
				continue
			if fog.sight[side] != ref.sight[side]:
				mismatches += 1
				if first_bad == "":
					first_bad = "第 %d 帧方 %s 掩码不同" % [i, String(side)]
		if mismatches > 0:
			break
	ok(mismatches == 0,
		"★ 双路校验：%d 帧逐方掩码逐字节相等%s" % [SOAK_FRAMES,
			"" if mismatches == 0 else "（%s，共 %d 处）" % [first_bad, mismatches]])


func _first_mobile(w):
	for u in w.units:
		if u != null and u.alive and not u.is_downed():
			return u
	return null


func _free_tile(w) -> Vector2i:
	for y in int(w.map.rows):
		for x in int(w.map.cols):
			if not w.map.terrain.has(x, y):
				continue
			if w.buildings.get_cell(x, y) != null:
				continue
			if not w.map.terrain_walkable(x, y):
				continue
			return Vector2i(x, y)
	return Vector2i(-1, -1)
