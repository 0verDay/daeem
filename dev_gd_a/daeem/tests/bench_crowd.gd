## bench_crowd.gd —— 1000 单位群编的性能基准（**量尺，不是断言测试**）
##
## 它不进 tools/run-tests.ps1 的断言集（文件名不是 test_*.gd）：它输出的是**数字**，
## 而数字随机器波动，写成断言只会变成随机红灯。它的用法是「改一处、跑一次、比一次」。
##
## 用法：
##   <mono Godot>_console.exe --headless --path <工程> --script res://tests/bench_crowd.gd
## 可用环境变量覆盖（方便先小规模验证再上 1000）：
##   DAEEM_BENCH_UNITS   单位数（默认 1000）
##   DAEEM_BENCH_FRAMES  推进帧数（默认 180）
##   DAEEM_BENCH_MAP     地图边长（默认 100，方格）
##
## 场景刻意选成「玩家把一大坨单位点到一个远点」——也就是用户报卡顿的那个操作：
##   · 命令帧 = N 次独立 A*（当前实现的尖峰）
##   · 之后每帧 = 索敌 O(n²) + 碰撞 O(n²)×迭代 + 逐个单位的移动/回位
##
## ⚠️ 用玩家阵营而不是敌人：敌人会走 enemy_ai 的「找不到路就全图 BFS」那条路，
##    那是另一个病（而且会让基准慢到跑不完）。这一版先把玩家群编这条路量清楚。
##
## ---------------------------------------------------------------------------
## 实测记录（1000 单位 / 100×100 图 / 60~120 帧）
##
##                            命令帧      每帧逻辑     碰撞       检查的邻居对
##   优化前（纯 GDScript）     17.0 s      614 ms      605 ms     1,498,500
##   + C# 碰撞内核             17.5 s      11.4 ms     2.82 ms    6,500
##   + C# 距离场（群编）        0.51 s      10.5 ms     2.13 ms    6,500
##   + 配置字段缓存 / 掩码      0.48 s       7.1 ms     2.07 ms    6,500
##   + 碰撞一次打包 / 视图批量化 0.48 s      ~6.3 ms     1.25 ms    6,500
##   + reachable_tiles 接内核 / 拥挤早退 0.44 s  ~6.4 ms   1.31 ms    6,500
##   + segment_clear 下沉 C#    0.24 s      ~6.3 ms     1.31 ms    6,500
##   + 索敌下沉 C# + 建筑过滤   0.24 s      ~6.3 ms     1.31 ms    6,500
##   + 队形落点（整队各走各的槽位）0.23 s     ~6.8 ms     1.31 ms    6,500
##   + 静态类型化单位参数 / 合并每单位调用 0.24 s  ~6.4 ms   1.31 ms   6,500
##   + 索敌只打包「会被问到」的单位  0.24 s  **5.9 ms**  1.31 ms   6,500
##
## 最终（干净漂移下的单场景数字）：
##   移动场景 **5.87~5.96 ms/帧**   待命场景 **5.93~5.98 ms/帧**   ← 目标 ≤6 ms
##   实机（开窗、1000 单位、100×100、关垂直同步）：**68.6 fps（p95 65.5）**
##
## ⚠️ 一处要说清楚的口径：索敌那一步只打包「本帧会被问到」的单位 —— 索敌方 +
##    **阵营与索敌方不同的**（后者可能是目标）。单阵营场景下「正在赶路的自己人」
##    两边都不占，于是整个打包都省掉了（移动场景的全部 1000 个单位）。
##    场上同时有两个阵营且双方都有人在索敌时，打包会回到原来的量级（约 +0.5 ms）。
##
## ★★ 怎么读这些数字（踩过的坑，见 docs/pitfalls.md 1.6）：
##    沙箱持续负载后会限频，同一个进程里**后跑**的场景数字会偏悲观好几倍
##    （实测参考负载 x6.35，待命场景因此从 6 ms 一路爬到 40 ms）。
##    要比大小请**一个进程只跑一个场景**：
##      DAEEM_ONLY=move <godot> --headless --script res://tests/bench_crowd.gd
##      DAEEM_ONLY=idle ...
##    脚本会在首尾各跑一次参考负载并打印漂移倍率，超过 1.3 就告警。
##
## ★★ 场景二（1000 单位**待命**，没有命令）——「常态」其实是这个：
##                            每帧逻辑     其中 units/combat
##   优化前（纯 GDScript）     285.6 ms     283.5 ms   ← 索敌 O(n²)：每个待命单位扫一遍全部单位
##   + 索敌下沉 C#             9.6 ms       6.4 ms
##   + 建筑本体配置缓存 + 格差过滤 6.8 ms     3.0 ms
##   + 索敌判定内联 cfg 字段      6.4 ms      2.5 ms
##
## 每帧细分（移动场景 ~6.3 ms / 待命场景 ~6.8 ms）：
##   units/step 2.4~2.6 ms（只在移动时有）  units/combat 0.8 / 3.0 ms
##   collision 1.3 / 0.9 ms   zones 0.6 ms   units/reclaim 0.35 ms   towers 0.26 ms
##
## 单次调用成本（同一张图，微观段落量的）：
##   find_path（A*，58 步）              17~21 ms ← 群编已改走距离场，只剩单单位/回退用
##   reachable_tiles（GDScript 全图 BFS） 107 ms  ← 敌人 AI / 点障碍时会踩到
##   reachable_tiles（C# 内核）          0.54 ms  ← 现在生产路径走这条（**200×**）
##   首次建表（改建筑后的顿卡）            14 ms  ← 原来 ~70 ms
##   smooth_path（GDScript 版）          0.21 ms  ← 生产路径已走内核 segment_clear
##
## 视图：canvas 节点数 0（旧实现是每单位一个 Node2D ＝ 1000 个）。
##
## ---------------------------------------------------------------------------
## ★★ 实机帧率（`tests/bench_fps.gd`，**开窗跑**，1000 单位 / 100×100 图 / 1920×1080 / 关垂直同步）
##
##                                    整帧      其中逻辑    其中渲染    draw call
##   优化前（也是优化后但没修渲染）     74.9 ms   14.1 ms    60.8 ms     4204
##   + zone_view 静态形状拆出去         42.7 ms    6.6 ms    36.2 ms     3194
##   + 单位本体改成贴图（描边烘进去）    14.5 ms    6.0 ms     8.6 ms     1195
##   => **68.9 fps（p95 64.1）**，60fps 预算 16.67 ms 还剩 +2.2 ms
##
## 修渲染的两刀（都在 docs/pitfalls.md 2.0 / 2.0b 记了）：
##   1. zone_view 每帧按地块重画区块形状 = 每帧 1 万次 draw_rect + 4 万次 zone_at（23 ms）；
##   2. draw_circle / draw_arc **不参与合批**（各 +997 draw call、18.4 + 10.2 ms），
##      换成同一张贴图之后 1000 个单位合成一个批次；draw_line 反而能合批（1000 条只 +1 call）。
## ---------------------------------------------------------------------------
##
## 结论：目标达成 —— 逻辑两个场景都在 6 ms 以内、实机 68.6 fps（p95 65.5）、
##       tests/ 17 个套件 1196 项全绿。
##       一路下来的七个尖峰：碰撞 605→1.3 ms、命令帧 17.0→0.23 s、
##       reachable_tiles 107→0.54 ms、建表 70→14 ms、画布节点 1000→0、
##       待命索敌 285→6 ms、render 60.8→7.8 ms。
##       还剩（都不影响 60 fps，属于「还能更好」）：
##       · 命令帧 0.23 s（每单位在 GDScript 里拼路径数组）；
##       · 两个阵营都在场时的索敌打包（约 +0.5 ms）。
## ---------------------------------------------------------------------------
extends SceneTree

const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const UnitRes = preload("res://logic/unit.gd")
const GridRes = preload("res://logic/grid.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")
const UnitViewRes = preload("res://view/unit_view.gd")
const CombatRes = preload("res://logic/combat.gd")

const DT := 1.0 / 60.0
## ★★ 可覆盖的仿真步长（`DAEEM_BENCH_DT`）。
##    为什么需要：实机走的是**真实帧 dt**（帧一慢 dt 就大，夹在 cfg.sim_max_dt = 0.05），
##    而无头基准一直用 1/60。两者的差别不是「快慢」而是**同一帧里到期的活变多**
##    （重寻路 / 认账 / 拐点都按 dt 走），实机行军攻击的 20 fps 必须先能用
##    无头复现出来，否则只能对着带渲染的窗口猜。
var dt_step: float = DT
## 并行冲突 / 地形生成用固定种子，保证每次跑的是同一张图、同一批人
const SEED := 20240920
## 单位方阵：32 列 × 32 行 ≈ 1024 个位置（够 1000 个）；间距 0.35 格 > 最小圆心距 0.252
const BLOCK_COLS := 32
const BLOCK_SPACING := 0.35
## 方阵左上角与走廊（y 在这个区间内不生成山，保证这条路是通的）
const BLOCK_ORIGIN := Vector2(14.0, 36.0)
const LANE_Y0 := 34
const LANE_Y1 := 66


func _initialize() -> void:
	var n_units := _env_int("DAEEM_BENCH_UNITS", 1000)
	var n_frames := _env_int("DAEEM_BENCH_FRAMES", 180)
	var map_size := _env_int("DAEEM_BENCH_MAP", 100)
	dt_step = float(_env_int("DAEEM_BENCH_DT_MS", 17)) / 1000.0

	print("[BENCH] DAEEM crowd benchmark")
	print("[BENCH]   units=%d frames=%d map=%dx%d dt=%.4f" % [n_units, n_frames, map_size, map_size, dt_step])

	var cfg = ConfigRes.load_default()
	if cfg == null:
		printerr("[BENCH] config.json 载入失败")
		quit(1)
		return

	var map_path := _write_bench_map(map_size, map_size)
	if map_path == "":
		printerr("[BENCH] 基准地图写不出来（临时目录不可写）")
		quit(1)
		return

	var w = WorldRes.create(cfg, map_path)
	if w == null:
		printerr("[BENCH] world 建不起来（地图载入失败：%s）" % map_path)
		quit(1)
		return

	_place_units(w, cfg, n_units)

	var goal := Vector2(float(map_size) * 0.72, float(map_size) * 0.5)
	print("[BENCH]   block=%dx%d origin=(%.1f,%.1f) goal=(%.1f,%.1f)"
		% [BLOCK_COLS, int(ceil(float(n_units) / float(BLOCK_COLS))), BLOCK_ORIGIN.x, BLOCK_ORIGIN.y, goal.x, goal.y])

	_bench_micro(w, cfg)
	# 参考负载（第一遍）：确认这台机器此刻有多快
	var ref0 := _calibrate()

	# ★★ DAEEM_ONLY=move|idle|cmd：只跑一个场景。
	#    为什么需要它：沙箱持续跑十几秒之后 CPU 会被限频（实测参考负载 **x6.35**），
	#    同一个进程里后跑的场景数字会偏悲观好几倍。要比大小就一个进程只跑一个场景。
	var only := OS.get_environment("DAEEM_ONLY")
	if only == "idle":
		_bench_idle(w, n_frames)
	elif only == "am":
		_bench_attack_move(w, cfg, n_units, n_frames)
	elif only == "move":
		_bench_command(w, cfg, n_units, goal)
		_bench_frames(w, n_frames)
	elif only == "cmd":
		_bench_command(w, cfg, n_units, goal)
	else:
		_bench_command(w, cfg, n_units, goal)
		_bench_frames(w, n_frames)
		_bench_idle(w, n_frames)
	_bench_view(w, n_units)

	# 参考负载（第二遍）：和第一遍比 —— 差得多说明环境变慢了，别把锅扣在游戏上
	var ref1 := _calibrate()
	print("[BENCH] -- machine drift check --")
	print("[BENCH]   reference workload: %.0f us -> %.0f us  (x%.2f)"
		% [ref0, ref1, ref1 / maxf(1.0, ref0)])
	if ref1 > ref0 * 1.3:
		print("[BENCH]   WARN: 这台机器在本次运行里慢了 %.0f%%，后半段的数字偏悲观；"
			% ((ref1 / maxf(1.0, ref0) - 1.0) * 100.0))
		print("[BENCH]         不要把「越跑越慢」当成游戏的问题（实测踩过：待命 6→40 ms）。")
		print("[BENCH]         要比大小就用 DAEEM_ONLY=move / idle 单开一个进程跑。")

	quit(0)


## 场景三：行军攻击（整队 A 过去，路上有一片敌人）。
##
## ★★ 为什么必须单独量：行军攻击下**每个锁定了目标的单位**每 `combat.repath_sec` 秒
##    都要重新寻路一次（`update_combat` 里的 `u.move_to(world, cfg, t.pos)`）。
##    1000 个单位同时追击就是每帧几十次完整寻路 —— 「全都在走」那个场景里
##    没有任何目标，所以这一项从来没被量到过。
func _bench_attack_move(w, cfg, n_units: int, n_frames: int) -> void:
	print("[BENCH] -- scenario 3: attack-move with %d enemies --" % 60)
	var goal := Vector2(float(w.map.cols) * 0.72, float(w.map.rows) * 0.5)

	# 在队伍与目标之间的走廊上横着摆一片敌人（这样会持续交战，而不是只在终点打一下）
	# ⚠️ 位置要按**这个基准里单位方阵的真实起点**（BLOCK_ORIGIN=(14,36)，不是地图中心）
	#    来定 —— 第一版照着地图比例摆，结果敌人落在 27 格以外，180 帧根本走不到，
	#    量出来的是「没人交战」的行军攻击（`engaged units: 0` 就是那个信号）。
	#
	# ★★ 但「走得到」还不够：默认位置（ex=32）在方阵前方 18 格，1/60 的步长下
	#    180 帧只走 3 秒，敌人还没接触 —— 于是量出来的仍是**没有交战**的行军攻击
	#    （实测 engaged = 5、repath 0.4 次/帧），跟实机 20 fps 的场景完全不是一回事。
	#    `DAEEM_BENCH_FOE_DX` 用来把敌人拉近到方阵前沿，让它几帧内就打起来。
	var foe_dx: float = float(_env_int("DAEEM_BENCH_FOE_DX", 6)) * 0.1
	var ex := BLOCK_ORIGIN.x + 11.0 + foe_dx
	var ey := float(w.map.rows) * 0.5 - 2.0
	var foes: Array = []
	for i in 60:
		var col := i % 20
		var row := i / 20
		var e = UnitRes.create(cfg, "am-foe-%d" % i, "foe %d" % i,
			Vector2i(0, 0), "enemy", UnitRes.KIND_ENEMY)
		e.pos = Vector2(ex + float(col) * 0.35, ey + float(row) * 0.35)
		e.sync_tile(w.map)
		foes.append(e)
	w.units.append_array(foes)

	var ids: Array = []
	for u in w.units:
		if u.faction == w.my_faction:
			ids.append(u.id)
	var t_cmd := Time.get_ticks_usec()
	CommandRes.apply(w, cfg, {"kind": "attack_move", "ids": ids,
		"faction": w.my_faction, "x": goal.x, "y": goal.y})
	print("[BENCH]   attack-move order: %.1f ms" % (float(Time.get_ticks_usec() - t_cmd) / 1000.0))

	# 生产路径（关剖析）
	w.profile_on = false
	CombatRes.repath_calls = 0
	UnitRes.move_to_calls = 0
	var t_all := Time.get_ticks_usec()
	for _i in n_frames:
		w.tick(dt_step)
	var avg_ms := float(Time.get_ticks_usec() - t_all) / 1000.0 / float(n_frames)
	var calls_total: int = UnitRes.move_to_calls

	# 细分（开剖析，只作参考）
	w.profile_on = true
	w.profile_reset()
	for _i in n_frames:
		w.tick(dt_step)
	w.profile_on = false
	for key in ["units", "units/combat", "units/step", "collision", "zones", "enemy_ai", "towers"]:
		print("[BENCH]   %-14s %8.3f ms/frame"
			% [key, float(int(w.profile_us.get(key, 0))) / 1000.0 / float(n_frames)])
	var engaged := 0
	for u in w.units:
		if u.target != null:
			engaged += 1
	# 诊断：为什么（没）打起来 —— 距离、攻击命令状态、索敌结果
	var probe = w.units[0]
	var nearest := 999.0
	for e in w.units:
		if e.faction == "enemy":
			nearest = minf(nearest, probe.pos.distance_to(e.pos))
	print("[BENCH]   diag: probe.pos=%s has_attack_move=%s aggro=%.1f nearest_foe=%.2f kernel_target=%s"
		% [str(probe.pos), str(probe.has_attack_move), cfg.aggro_range, nearest,
			str(w.crowd.target_at(w, 0))])
	print("[BENCH]   engaged units: %d    ATK TOTAL %8.3f ms/frame (=> max %.0f fps logic only)"
		% [engaged, avg_ms, 1000.0 / maxf(0.001, avg_ms)])
	# ★ 追击寻路的两个分量：次数（CombatRes.repath_calls）和真正进 move_to 的次数。
	#   实测实机 20 fps 时先用这两个数分清「次数太多」还是「单次太贵」。
	print("[BENCH]   repath calls/frame: %.1f    move_to calls/frame: %.1f    us per move_to: %.1f"
		% [float(CombatRes.repath_calls) / float(n_frames),
			float(UnitRes.move_to_calls) / float(n_frames),
			(avg_ms * 1000.0) / maxf(1.0, float(UnitRes.move_to_calls))])


## 一段固定的纯计算，用来探测「这台机器在本次运行里有没有变慢」。
##
## ★★ 为什么必须有它（实测踩到）：沙箱里持续跑十几秒之后 CPU 会被限频，
##    同一个场景的分段计时会从 6 ms 一路爬到 40 ms —— 看起来像「游戏越来越卡」，
##    其实是环境在变慢。没有这个参照就会去优化一个根本不存在的问题。
func _calibrate() -> float:
	var t0 := Time.get_ticks_usec()
	var acc := 0.0
	for i in 300000:
		acc += sqrt(float(i))
	if acc < 0.0:
		printerr("impossible")          # 防止编译器把整个循环优化掉
	return float(Time.get_ticks_usec() - t0)


# ------------------------------------------------------------------
# 场景二：1000 个单位**待命**（没有移动命令）
#
# ★★ 为什么必须单独量：待命单位每帧都会跑警戒索敌（combat.acquire_target），
#    而它是 **O(n²)** —— 每个待命单位都要扫一遍 world.units。
#    「1000 单位常态」在真实玩法里绝大部分时间就是待命（站着守点、集结待命），
#    只量「全都在走」那个场景等于把最常发生的情况漏掉了。
# ------------------------------------------------------------------

func _bench_idle(w, n_frames: int) -> void:
	print("[BENCH] -- scenario 2: %d units IDLE (no orders) --" % w.units.size())
	for u in w.units:
		u.stop()                        # 停下去：这一步之后它们每帧都会索敌

	# ★ 与移动场景同样的两遍量法：先关剖析量**生产路径**的总时长，
	#   再开剖析拿细分（剖析本身每单位要多 7 次调用，开着它量的总时长是虚高的）。
	w.profile_on = false
	var chunks: Array[float] = []
	var per := maxi(1, n_frames / 4)
	for _c in 4:
		var t0 := Time.get_ticks_usec()
		for _i in per:
			w.tick(DT)
		chunks.append(float(Time.get_ticks_usec() - t0) / 1000.0 / float(per))
		print("[BENCH]   chunk%d: %.2f ms | obj=%d mem=%.1fMB moving=%d settle=%d ev=%d"
			% [_c + 1, chunks[chunks.size() - 1],
				int(Performance.get_monitor(Performance.OBJECT_COUNT)),
				Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
				_count_if(w.units, "moving"), _count_if(w.units, "settling"), w._events.size()])
	var avg_ms: float = 0.0
	for c in chunks:
		avg_ms += c
	avg_ms /= float(chunks.size())
	print("[BENCH]   分段（各 %d 帧）：%s" % [per, str(chunks.map(func(x): return "%.2f" % x))])

	w.profile_on = true
	w.profile_reset()
	for _i in n_frames:
		w.tick(DT)
	w.profile_on = false

	var order := ["units", "units/combat", "units/reclaim", "units/step",
		"collision", "zones", "enemy_ai", "towers"]
	for key in order:
		print("[BENCH]   %-14s %8.3f ms/frame"
			% [key, float(int(w.profile_us.get(key, 0))) / 1000.0 / float(n_frames)])
	print("[BENCH]   %-14s %8.3f ms/frame  (=> max %.0f fps logic only)"
		% ["IDLE TOTAL", avg_ms, 1000.0 / maxf(0.001, avg_ms)])


# ------------------------------------------------------------------
# 渲染：这里**量不到**真实绘制（Godot 不允许在 _draw() 之外调 draw_*，
# 而无头模式也没有 GPU），所以只陈述结构事实 + 排出重画的次数。
#
# ★ 真正的差别在结构上：旧实现是「每单位一个 Node2D + 每帧每单位一次 queue_redraw」，
#   1000 单位 = 1000 个画布节点、1000 次 _draw 回调；现在是**一个** CanvasItem
#   一次 _draw，外加屏幕外剔除。实机帧率要在游戏里看。
# ------------------------------------------------------------------

func _bench_view(w, n_units: int) -> void:
	var view = UnitViewRes.new()
	view.setup(w.cfg, w)
	view.sync(0.0)
	print("[BENCH] -- view --")
	print("[BENCH]   canvas nodes for %d units: %d   (旧实现：每单位一个 Node2D)"
		% [n_units, view.get_child_count()])
	print("[BENCH]   alive units: %d" % w.units.size())
	view.free()


# ------------------------------------------------------------------
# 单次调用的成本分解
#
# 命令帧那 17 ms/单位 到底是 A* 还是别的？不量清楚就会优化错地方。
# 这一段在群编之前跑，只量「一次调用」，与单位数无关。
# ------------------------------------------------------------------

func _bench_micro(w, cfg) -> void:
	print("[BENCH] -- micro: single-call cost on this map --")
	var map = w.map
	var from := Vector2i(14, 40)
	var to := Vector2i(72, 50)

	var t0 := Time.get_ticks_usec()
	var tile_path = PathfinderRes.find_path(map, w.buildings, cfg, from, to, w.my_faction)
	var us_astar := Time.get_ticks_usec() - t0
	ok_path(tile_path != null, "微观测试：A* 找得到路")

	t0 = Time.get_ticks_usec()
	# 不传 crowd → 强制走 GDScript 参考实现（用来量「接内核之前」的成本）
	var region = PathfinderRes.reachable_tiles(map, w.buildings, cfg, from, w.my_faction)
	var us_bfs := Time.get_ticks_usec() - t0

	t0 = Time.get_ticks_usec()
	# 传 crowd → 走 C# 内核（现在生产路径走的就是这条）
	# 第一次包含**建表**（地形 + 按阵营的格级阻挡 + 建筑本体），所以量两次：
	# 第一次 = 「改完建筑之后的顿卡」，第二次 = 稳态 BFS。
	var mask = PathfinderRes.reachable_tiles(map, w.buildings, cfg, from, w.my_faction, w.crowd)
	var us_warm := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	mask = PathfinderRes.reachable_tiles(map, w.buildings, cfg, from, w.my_faction, w.crowd)
	var us_bfs_cs := Time.get_ticks_usec() - t0

	var raw: Array[Vector2] = [GridRes.center_of(from)]
	if tile_path != null:
		for n in tile_path:
			raw.append(GridRes.center_of(n))
	t0 = Time.get_ticks_usec()
	var pts = PathfinderRes.smooth_path(map, w.buildings, cfg, raw, w.my_faction)
	var us_smooth := Time.get_ticks_usec() - t0

	t0 = Time.get_ticks_usec()
	pts = PathfinderRes.round_corners(map, w.buildings, cfg, pts, w.my_faction)
	var us_round := Time.get_ticks_usec() - t0

	t0 = Time.get_ticks_usec()
	var slot = PathfinderRes.nearest_reachable(map, w.buildings, cfg, from, to, w.my_faction)
	var us_near := Time.get_ticks_usec() - t0

	print("[BENCH]   find_path (A*, %d steps)  %8.3f ms" % [0 if tile_path == null else (tile_path as Array).size(), float(us_astar) / 1000.0])
	print("[BENCH]   reachable_tiles (GDScript BFS) %8.3f ms   (%d tiles)" % [float(us_bfs) / 1000.0, region.size()])
	print("[BENCH]   reachable_tiles (C# kernel)    %8.3f ms   (mask %d bytes)" % [float(us_bfs_cs) / 1000.0, (mask as PackedByteArray).size()])
	print("[BENCH]     其中首次建表（改建筑后的顿卡） %8.3f ms" % [float(us_warm - us_bfs_cs) / 1000.0])
	print("[BENCH]   smooth_path                 %8.3f ms" % [float(us_smooth) / 1000.0])
	print("[BENCH]   round_corners               %8.3f ms" % [float(us_round) / 1000.0])
	print("[BENCH]   nearest_reachable           %8.3f ms" % [float(us_near) / 1000.0])


## 微观段落里只用它报一条「确实找到了路」——不是断言测试，所以不靠它判成败
func ok_path(cond: bool, what: String) -> void:
	if not cond:
		printerr("[BENCH]   WARN: %s" % what)


## 数一数有多少个单位的某个布尔字段为真（诊断用）
func _count_if(units: Array, field: String) -> int:
	var n := 0
	for u in units:
		if bool(u.get(field)):
			n += 1
	return n


# ------------------------------------------------------------------
# 场景搭建
# ------------------------------------------------------------------

## 生成一张 map_size × map_size 的基准地图，写到**系统临时目录**（不往仓库里塞文件）。
##
## 为什么要有这张图而不是直接用 data/test_map.json：那张图是 24×16 = 384 格，
## 而 A* 的代价随格数增长（当前还是线性扫 open list，最坏 O(N²)）——
## 在小图上量出来的寻路开销会把问题**严重低估**。用户的预期地图是 100×100。
func _write_bench_map(cols: int, rows: int) -> String:
	var path := OS.get_temp_dir().path_join("daeem_bench_map.json")
	var lines: Array = []
	for y in rows:
		var line := ""
		for x in cols:
			line += _terrain_char(x, y)
		lines.append(line)
	var data := {
		"cols": cols,
		"rows": rows,
		"layout": lines,
		# 两个大本营：p1 在左下、enemy 在右上。房主阵营必须叫 p1（faction.gd 的默认）
		"faction_bases": {"p1": [8, rows - 10], "enemy": [cols - 9, 9]},
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(JSON.stringify(data))
	f.close()
	return path


func _terrain_char(x: int, y: int) -> String:
	# 走廊留空：群编那条路必须真的走得通，否则量到的是「绕路/不可达」而不是移动本身
	if y >= LANE_Y0 and y <= LANE_Y1:
		return "." if _hash01(x, y) > 0.18 else "^"
	# 3×3 一档的山块：成片才需要真的绕路（零散单格对 A* 几乎没影响）
	if _hash01(int(x / 3) + 101, int(y / 3) + 101) < 0.10:
		return "#"
	if _hash01(int(x / 2) + 977, int(y / 2) + 977) < 0.28:
		return "^"
	return "."


## 确定性哈希（不用 RandomNumberGenerator：基准要每次跑出同一张图）
func _hash01(x: int, y: int) -> float:
	var h: int = (x * 73856093 + SEED) ^ (y * 19349663 + SEED)
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(absi(h) % 100000) / 100000.0


## 把 world 里原有的 12 个单位（3 将领 + 亲兵）换成 n 个玩家单位，排成一个方阵。
func _place_units(w, cfg, n: int) -> void:
	var fresh: Array = []
	for i in n:
		var col := i % BLOCK_COLS
		var row := i / BLOCK_COLS
		var u = UnitRes.create(
			cfg, "bench-%d" % i, "bench %d" % i,
			Vector2i(0, 0), w.my_faction, UnitRes.KIND_SUBORDINATE
		)
		u.pos = BLOCK_ORIGIN + Vector2(float(col) * BLOCK_SPACING, float(row) * BLOCK_SPACING)
		u.sync_tile(w.map)
		fresh.append(u)
	w.units = fresh


# ------------------------------------------------------------------
# 阶段 1：命令帧（N 次独立寻路的那一下）
# ------------------------------------------------------------------

## 分批下命令：每批一次真实的 command_processor.apply（含 id→unit 查找），
## 这样既能拿到真实的命令总耗时，又能打印进度（1000 单位时这一下可能几十秒）。
func _bench_command(w, cfg, n: int, goal: Vector2) -> void:
	var ids: Array = []
	for u in w.units:
		ids.append(u.id)

	var chunk := 100
	var t_all := Time.get_ticks_usec()
	print("[BENCH] -- command phase (group move, %d units) --" % n)
	var done := 0
	while done < ids.size():
		var part: Array = ids.slice(done, mini(done + chunk, ids.size()))
		var cmd := {
			"kind": "move", "ids": part, "faction": w.my_faction,
			"x": goal.x, "y": goal.y,
		}
		var t0 := Time.get_ticks_usec()
		CommandRes.apply(w, cfg, cmd)
		var us := Time.get_ticks_usec() - t0
		done += part.size()
		print("[BENCH]   %4d/%d  %8.1f ms  (%.3f ms/unit)"
			% [done, n, float(us) / 1000.0, float(us) / 1000.0 / float(part.size())])
	var total_ms := float(Time.get_ticks_usec() - t_all) / 1000.0
	var with_path := 0
	for u in w.units:
		if not u.path.is_empty():
			with_path += 1
	print("[BENCH]   TOTAL %.1f ms  (%.3f ms/unit) ; %d/%d got a path"
		% [total_ms, total_ms / float(n), with_path, n])


# ------------------------------------------------------------------
# 阶段 2：逐帧推进（索敌 + 碰撞 + 移动）
# ------------------------------------------------------------------

func _bench_frames(w, n_frames: int) -> void:
	print("[BENCH] -- per-frame (tick) --")
	# 跑的是哪一套碰撞后端（否则「快了」可能只是碰巧）
	if w.crowd != null and w.crowd.available():
		print("[BENCH]   collision backend: csharp kernel")
	elif w.crowd != null:
		print("[BENCH]   collision backend: gdscript (C# 内核不可用 —— 普通版引擎？)")
	else:
		print("[BENCH]   collision backend: gdscript (no bridge)")

	# ★★ 第一遍：**关掉剖析**量总时长 —— 这才是生产路径的数字。
	#    分段计时每单位要多 7 次方法调用（4 次时钟 + 3 次累加），
	#    开着剖析量出来的总时长是虚高的（实测 6.8 → 7.4 ms）。别再把它当总时长用。
	w.profile_on = false
	var worst_us := 0
	var t_all := Time.get_ticks_usec()
	for _i in n_frames:
		var t0 := Time.get_ticks_usec()
		w.tick(DT)
		var us := Time.get_ticks_usec() - t0
		if us > worst_us:
			worst_us = us
	var avg_us := float(Time.get_ticks_usec() - t_all) / float(n_frames)

	# 第二遍：开着剖析拿分段（它的总时长只作参考，不要当基准）
	w.profile_on = true
	w.profile_reset()
	for _i in n_frames:
		w.tick(DT)
	w.profile_on = false

	# 阶段名 → 每帧平均毫秒。顺序按 tick() 里执行的先后排
	# （"units/*" 是 units 的细分，算 total 差额时不能重复计入）
	var order := ["zones", "economy", "recruit", "units", "units/combat", "units/reclaim", "units/step",
		"towers", "enemy_ai", "collect", "collision"]
	var top_level := ["zones", "economy", "recruit", "units", "towers", "enemy_ai", "collect", "collision"]
	var accounted := 0.0
	for key in order:
		var ms := float(int(w.profile_us.get(key, 0))) / 1000.0 / float(n_frames)
		if top_level.has(key):
			accounted += ms
		print("[BENCH]   %-14s %8.3f ms/frame" % [key, ms])
	var total_ms := avg_us / 1000.0
	print("[BENCH]   %-14s %8.3f ms/frame   <-- 未计入的零碎（清场/胜负/事件收口）" % ["other", total_ms - accounted])
	print("[BENCH]   %-14s %8.3f ms/frame  (worst frame %.1f ms)"
		% ["TOTAL", total_ms, float(worst_us) / 1000.0])
	if total_ms > 0.0:
		print("[BENCH]   logic budget: %.1f ms of 16.67 ms  => max %.0f fps (logic only)"
			% [total_ms, 1000.0 / total_ms])

	# 结束时还剩多少人在赶路（判断「挤成一团走不动」还是「都到了」）
	var moving := 0
	for u in w.units:
		if u.moving:
			moving += 1
	print("[BENCH]   still moving after %d frames: %d/%d" % [n_frames, moving, w.units.size()])
	# 分桶到底省了多少：旧实现每帧固定 n(n-1)/2 × iterations 对
	if w.crowd != null and w.crowd.available() and w.crowd.kernel != null:
		var n: int = w.units.size()
		var brute: int = n * (n - 1) / 2 * 3
		print("[BENCH]   neighbor pairs: %d (brute force would be %d)" % [w.crowd.kernel.StatsExamined, brute])


func _env_int(name: String, fallback: int) -> int:
	var v := OS.get_environment(name)
	if v.is_valid_int():
		return maxi(1, int(v))
	return fallback
