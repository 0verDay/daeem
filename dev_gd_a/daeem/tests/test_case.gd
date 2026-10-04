## 无头测试脚手架（对应 docs/architecture.md 第六节）。
##
## 用法：一个测试文件 = 一个 `extends "res://tests/test_case.gd"` 的脚本，
##       `_initialize()` 里调 `run_all(自己的一组断言)`，靠**退出码**表达成败。
##       runner（tools/run-tests.ps1）只看退出码，不解析输出文本。
##
## ⚠️ 为什么退出码这么重要：一旦它永远返回 0，整套测试就变成「永远绿灯」的摆设 ——
##    那比没有测试更糟，因为它会让人相信测试通过。
##
## ⚠️ GDScript **没有** Python 那种 `a if cond else b` 三元表达式。
##    写成 `quit(1 if _fail > 0 else 0)` 不报错，但语义不对（见 docs/architecture.md 6.1）。别抄。
##
## ⚠️ 输出只用 ASCII 的 OK / FAIL，不用 ✔ ✘ —— 中文 Windows 的 GBK 控制台会因此整个崩掉
##    （HTML 版的 runner 真崩过，见 docs/pitfalls.md 4.2）。
##
## ★★ 已实测的引用约定（改了会满屏 Parse Error，先读 docs/pitfalls.md 第五节）：
##   命令行 `--script` 启动时**全局 class_name 表不可用**（没有编辑器生成缓存），所以：
##     1. 跨文件只用**自己文件里的 preload 常量**，绝不用别人文件的 class_name 作类型
##        （`func take(h: ProbeHelperA)` 会直接 Parse Error）
##     2. 子类不要重复声明父类已有的 const（会报 "already exists in parent class"）
##     3. 调用返回值是 Variant 时不要用 `:=`，用 `=`（否则 "Cannot infer the type"）
##     4. 本文件刻意不写 class_name，依赖一律用字符串路径在运行时 load()
extends SceneTree

const PATH_CONFIG := "res://logic/config.gd"
const PATH_MAP_DATA := "res://logic/map_data.gd"
const PATH_GRID := "res://logic/grid.gd"

## 随游戏发布的那张地图（`data/maps/<id>/map.json`，一个地图一个目录 —— 见 docs）。
##
## ★ 写死这一串而不是去读 `logic/map_library.gd`：默认参数必须是**编译期常量**，
##   而且这里刻意钉住「测试用的到底是哪个文件」—— 地图再搬家时应该在这里失败，
##   而不是跟着一起改、把「地图搬错了」测成永远通过。
const DEFAULT_MAP_PATH := "res://data/maps/frontier/map.json"

var _pass: int = 0
var _fail: int = 0
var _case_name: String = "unnamed"
var _failed_names: Array[String] = []


## 这个文件是脚手架基类，不是测试用例。真被人直接跑时要说清楚，并给出失败退出码
## （返回 0 会被 runner 当成「通过」，那就变成假绿灯了）。
func _initialize() -> void:
	printerr("test_case.gd 是脚手架基类，不直接运行；请跑 tests/test_*.gd")
	quit(1)


## 子类在 _initialize() 里调它：跑完所有断言并退出，退出码反映成败
##
## ★ `cases.call()` **不能 await**（实测 4.7）：调用一个 async 函数而不 await 是
##   运行时错误（"Trying to call an async function without await"），包一层
##   `Callable.call()` 也一样报。所以这里**只支持同步用例** —— 用例是协程的话，
##   `call()` 一返回就会执行下面的 `quit()`，表现是「通过 N 项 / 失败 0 / 退出码 1」
##   或者干脆挂住（runner 看上去像引擎卡死）。
##   ⇒ 要等帧的用例请**不要**写 `await`，改成手动推进
##     （例：`tests/test_fill_button.gd` 直接喂 `animator._process(dt)`，
##      进度是纯数学，不需要真帧 —— 快、稳、与渲染无关）。
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


## ---- 帧预算换算 ----
## ★ config.json 顶部那次调整把格宽放大到 128px、单位速度降到**基线的 1/4**
##   （unit.speed 2.4 → 0.6，debug.enemy_speed 1.8 → 0.45）。
##   测试里那些「跑 N 帧等它走到」的上限，是按**基线速度**留的余量：
##   速度一变，同样的路程就要 4 倍的帧数 —— 不换算的话，挂掉的会是这些用例，
##   而它们真正想验的东西（到达 / 不抖 / 不吸附格心）根本没被验到。
##   所以统一走这个换算：以后谁再调速度，帧预算自动跟着走。
##   ⚠️ 只用它放大「等移动收敛」的循环；纯观察窗口（跑固定 N 帧看闪不闪、抖不抖）不要用，
##      那些量的本来就是秒数而不是路程。
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


## 载入某脚本（运行时 load，绕开「全局 class_name 表不可用」这件事）
func script_at(path: String) -> GDScript:
	var s := load(path)
	if s == null:
		ok(false, "脚本能载入：%s" % path)
		return null
	return s


## 载入全局配置，失败即记一条失败断言（不静默用默认值 —— 静默默认值会让
## 「JSON 写错了」表现为「手感莫名不对」，那是最难查的一类问题）
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


## 建一个**不带阵营 AI** 的干净世界（绝大多数测试要的就是它）。
##
## ★★ 为什么不直接 `World.create(cfg)`：默认那个是**开了 AI 的**（单机游戏要的），
##   而开了 AI 之后世界上会多出**一整个阵营**（三个将领 + 大本营 + 资源池）——
##   于是「开局 3 个将领」「场上有 22 个单位」「对家的守军看不见」这类
##   与 AI 无关的断言会集体变红，而它们本来验的东西（移动 / 碰撞 / 迷雾）一个字都没错。
##
## ★ 要验 AI 本身的测试（tests/test_ai.gd）当然用 `World.create(cfg)`
##   （或者显式传 `with_ai = true`）—— 那条路一眼就能看出「这个用例依赖 AI 存在」。
##
## @param world_path World 脚本的 res:// 路径（默认 `res://logic/world.gd`）；
##        调用方自己 preload 了的话传进来就省一次 load。
func require_world(cfg, world_path: String = "res://logic/world.gd",
		map_path: String = DEFAULT_MAP_PATH) -> RefCounted:
	var cls := script_at(world_path)
	if cls == null:
		return null
	var w = cls.create(cfg, map_path, false)
	ok(w != null, "世界能建出来（不带阵营 AI）")
	return w


## ★★ 建一个**开局就带附属兵**的干净世界（不带阵营 AI）—— 本轮口径的测试入口。
##
## 为什么需要它（本轮口径变更）：`config.json` 的 `unit.general.escort` 全局缺省
## **已经删除**，开局有几个附属兵**完全等于关卡 `start_units[]` 里摆出来的那些**
## （`escort_of` 指向同阵营第几位将领）。于是「开局就有附属兵」这类老用例
## 不能再靠 config —— 必须像关卡作者那样**在探针关卡里把兵摆出来**。
##
## ★★ 摆在哪：**围着各自的将领一圈**（`ESCORT_RING`，与老 `create_escort` 的
##    「出生在队长旁边」同一个手感）。为什么不能摆到地图角落去：
##      · 本文件的好几个用例验的是**拥挤**（一整队人点到同一点），
##        兵要是从地图另一头出发，那条路会把「拥挤收敛」验成「长途寻路」；
##      · 关卡作者摆兵也是摆在将领身边的（样例战役就是这么摆的）。
##    ⇒ 先在**没有摆放**的情况下造一次世界，取到这一方将领的真实出生格，
##      再把附属兵摆到它周围那些格子上（那些格子由 `spawn_layout_for` 保证可通行）。
##
## 于是对这一局而言：
##   · `general-1` 名下有 `per_general` 个兵（`retinue_of` 数得出来）；
##   · p1 **不再自动生成将领**，但 `escort_of` 点名的 1/2/3 位会被补出来，
##     id 正好是 `general-1` / `general-2` / `general-3`（与自动生成的那套一致）；
##   · `world.units` 里**每位将领都排在它自己的兵前面**（见 world 的分批规则）。
##
## @param per_general 每位将领摆几个（≤ 0 = 一个都不摆 ⇒ 与 `require_world()` 等价：
##        将领光杆，但**不会**触发「整方由关卡接管」那条路）。
## @param faction     摆给哪一方（默认 `p1`；`p1` 是默认阵营，所以 id 不带后缀）。
## @return World（`level != null`，可当普通世界用）；失败时返回 null 并记一条断言。
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
	# ① 先造一次「没有任何摆放」的世界：只为拿到这一方将领的真实出生格
	#    （`spawn_layout_for` 已经把它们落在可通行格上了）。
	var probe = wcls.create(cfg, map_path, false)
	if probe == null:
		ok(false, "探针世界能建出来（%s）" % map_path)
		return null
	var spawns: Array = probe.faction_spawns.get(faction, [])
	# ② 把附属兵摆到那些出生格的四周（绕圈取格子；不够就换外圈）。
	var ccls := script_at(PATH_CONFIG)
	var c = ccls.load_default() if ccls != null else null
	var units: Array = []
	for gi in 3:
		var gt: String = String(c.general_type_at(gi)) if c != null else "spearman"
		var anchor := Vector2i(-1, -1)
		if gi < spawns.size():
			anchor = spawns[gi]
		if anchor.x < 0:
			anchor = Vector2i(int(probe.map.base.x), int(probe.map.base.y))
		for i in per_general:
			var off: Vector2i = ESCORT_RING[i % ESCORT_RING.size()]
			var ring := i / ESCORT_RING.size()          # 第几圈（整数除法：0 = 内圈）
			units.append({
				"faction": faction, "kind": gt, "unit_type": gt,
				# ★ 附属兵的**类型 = 队长的类型**（口径：长枪兵将领带长枪兵）。
				#   显式写 `unit_type` 更贴近编辑器导出的样子。
				"x": anchor.x + off.x * (ring + 1),
				"y": anchor.y + off.y * (ring + 1),
				"hold": true, "escort_of": gi + 1,
			})
	# ③ 写探针关卡 → 用它造真正的世界
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


## 附属兵围着将领摆的那一圈方向（与 `world.ring_offsets()` 同一套手感：
## 先正交、再斜角 —— 正交邻格比斜角更不容易被墙 / 山挤掉）。
## ★ 只用于**测试探针**的摆放，所以留在测试侧（玩法逻辑里那一份仍是权威）。
const ESCORT_RING: Array = [
	Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(-1, 1), Vector2i(-1, -1), Vector2i(1, -1),
]


## 删掉上面那个探针关卡留下的临时文件（测试末尾调一次；工程内不能留垃圾）。
func cleanup_escort_scaffold() -> void:
	var path := "res://.tmp_test_case/escort_scaffold.json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	if DirAccess.dir_exists_absolute("res://.tmp_test_case"):
		DirAccess.remove_absolute("res://.tmp_test_case")


## ★★ 让某个单位**当场死亡**（本轮新增，因为「将领濒死保护」把 `take_damage` 的语义改了）。
##
## 为什么需要这个帮助函数：加了濒死保护之后，**旗下还有部队的将领不会被打死**，
## 而是进入濒死（见 logic/unit.gd 与 data/config.json 的 revive 段）。
## 于是「打死一个将领，看世界怎么收尾」这类老用例会集体变红 ——
## 而它们验的本来是**阵亡之后的收尾**（退款 / 清场 / 补招槽位），不是濒死。
##
## 这个函数按权威规则把三件事按顺序做掉：
##   1. 撤掉它**队列里还没出来的兵**（`cancel_recruit`，全额退款）——
##      ⚠️ 这一步是必须的：**在读条 / 排队的兵也算「旗下还有部队」**
##      （`world.has_living_retinue()` 的口径与 `unit.retinue_size()` 一致），
##      不撤的话它照样会进濒死（实测：`kill_unit_now` 送不走一个正在招兵的将领，
##      而那看起来像「濒死规则坏了」）；
##   2. 把它旗下的活兵全部打死（走 `take_damage`，所以死因、事件都是真的）；
##   3. tick 一帧让世界收尸，再给它自己那一下 —— 此时它「旗下没有部队」，
##      于是**直接死亡**（用户拍板：「无附属部队时直接死亡，不进濒死」）。
##
## ⚠️ 它**不是**「绕过濒死」的后门：任何一步都在濒死规则之内，只是把
##    「先撤单、再打光部队、最后打将领」这个必然过程写成了一个调用。
##    要验濒死本身请用 tests/test_downed.gd（那里直接 `take_damage` 将领）。
func kill_unit_now(cfg, w, u, dt: float = 1.0 / 60.0) -> void:
	if u == null or not u.alive:
		return
	while u.train_queue_size() > 0:
		if not w.cancel_recruit(String(u.id), 0, String(u.faction)):
			break
	for m in w.retinue_of(String(u.id), true):
		m.take_damage(cfg, w, m.hp + 999999.0, null)
	w.tick(dt)
	# ⚠️ 伤害必须写成 `hp + 大数`（**不能**只写一个固定的「99999」）：地图预置的
	#    守军 / 测试单位血量可能是 1000+，固定值在某些用例里恰好打不死它 ——
	#    那种失败看起来像「濒死规则又坏了」，其实是这一行算错了（实测踩到）。
	u.take_damage(cfg, w, u.hp + 999999.0, null)

