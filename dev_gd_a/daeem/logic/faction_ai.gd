## faction_ai.gd —— **阵营性 AI**：附属在某个阵营下的一整套「内政 + 出兵」经营。
##
## 需求原文（逐条对照）：
##   1. 「该类 AI 会附属在某个阵营/势力下，该类 AI 有自己的资源库，其资源会随着其占领区划
##        产出资源而增长」
##      → 资源库是 world 里**独立的一个字典**（`world.resource_pool_for(faction)`，
##        见 world.reset()）。本模块每帧只做一件事：把
##        `zones.production_of(faction) × resource_mult × dt` 加进去 ——
##        口径与玩家那一套**逐条同义**（产能来自地图 zone_list，抢区块 = 抢产能），
##        唯一的差别是 `resource_mult`（难度旋钮）。
##   2. 「该类 AI 会花费资源招募自己的将领 / 升级自己的建筑，并花费资源让将领招募单位，
##        需要有明确的资源规划」
##      → 决策顺序是**固定的四段**（见 `_decide()`）：
##        a. 将领没招满 → 招将领（区划招募，队列挂区划中心）；
##        b. 将领没补满员 → 让将领招兵（队列挂将领自己）；
##        c. 还有闲钱 → 升级自己的建筑（挑**最便宜**的那一栋，先升级后攒大招）；
##        d. 都齐了 → 出兵（见第 3 条）。
##        每一段都走**同一套已有的命令路径**（world.start_zone_recruit /
##        world.start_recruit / world.start_building_upgrade），
##        所以扣费、读条、队列上限、人口这些规则一行都不用重写。
##   3. 「该类 AI 在若干将领招募满员后会派遣这些将领行军攻击某处」
##      → 一旦「招满 generals 个将领，且每个将领都补到**它的目标编制**」，
##        就按 `min_ready` / `ready_mult` 算出一个派兵比例，
##        对**离目标最近的**那几位将领下达 `order_attack_move`（行军攻击）——
##        目标选「离自己最近的敌方区划中心」，没有敌方区划就选敌方大本营。
##        ★★ 目标编制 = **关卡 `start_units[]` 里给这位将领摆了几个附属兵**
##           （`world.escort_target_of()`）—— 本轮把全局缺省编制删掉了，
##           没摆过的将领（含运行时自己招的）目标是 **0**，见 `_decide` 里那段说明。
##   4. 「该类 AI 可为其提高资源获取倍率以调整难度」
##      → `config.ai.factions[].resource_mult`（1.0 = 与玩家同速，2.0 = 两倍）。
##
## ★★ 状态放在哪：`world.ai_factions[]`，每项一个字典（见 `setup()`）。
##   为什么不单独一个 RefCounted 类：这点状态（资源 + 两个计时器 + 一个目标）
##   不值得一个类型，而且它是**世界状态的一部分**（跟 tech.active_by_faction 同源），
##   将来进快照时就在 world 上，不用再绕一层。
##
## ★ 单机下 AI 是「另一个阵营」，玩家看不见它的资源（也不该看见）——
##   界面读的永远是 `world.resources`（玩家自己那个池子）。
##
## ⚠️ 跨文件引用只用**本文件里的 preload 常量**（`--script` 下全局 class_name 不可用，
##    见 docs/pitfalls.md 第五节）。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")
const GridRes = preload("res://logic/grid.gd")
const FactionRes = preload("res://logic/faction.gd")
const BuildingRes = preload("res://logic/building.gd")
const CommandProcessorRes = preload("res://logic/command_processor.gd")

## 一次决策里最多下几条命令（护栏）。见 `_decide()` 的说明。
const MAX_ORDERS_PER_TICK := 4


## ★★ 建出这一局该跑的阵营 AI（由 `world.reset()` 在所有单位就位之后调一次）。
##
## @return Array[Dictionary]，每项：
##   {faction, mult, general_index, recruit_timer, upgrade_timer, attack_timer, params}
##
## ★ 名单从哪来（本轮改过，别改回去）：**`world.ai_roster_cfg`** —— 它是
##   「关卡显式写了 `ai` 的阵营优先 + `config.json` 的 `ai.factions` 兜底」合并出来的
##   那一份（唯一实现在 `logic/level.gd` 的 `merged_ai_factions()`）。
##
##   ⚠️ 以前这里是**直接遍历 `cfg.ai_factions()`** 的 —— 那条路在加战役之后会漏掉
##   「关卡点名的阵营」（地图与 config 里都没有它）。而且 `world._setup_ai_factions()`
##   已经按同一份名单建过资源池了，**两处判据必须同源**，否则会出现
##   「状态表里有这一方、资源池里没有」，而 `_income()` 会直接把 null 当 Dictionary 用
##   （`pool["food"] = ...`）当场报错。这种「两处判据漂开」的错最难查。
##
## ★ 为什么在这里就把 `general_index` 定下来：将领是**按序号招**的
##   （general_1 / general_2 / …，见 config 的 recruit.zone.list 与
##   `ConfigRes.general_index_of`），而「已经招了几个」是**只增不减**的 ——
##   看当前场上有几个将领也不行（死掉的会重招、序号会撞车）。
##
## ★★ 为什么 `ai != "faction"` 的阵营**不进这张表**（本轮新增）：
##   · `ai: "general"` 的那些靠**单位上的**将领性 AI 驱动（`garrison_zone_id`），
##     这里再建一份会让两边同时指挥同一批单位 —— route.md 33.3 那条「判据必须互斥」
##     就是这么踩出来的；
##   · `ai: "none"` 的那些这一局**就是不动**（用户明确要的「不动」）。
static func setup(world, cfg: ConfigRes) -> Array:
	var out: Array = []
	for item in world.ai_roster_cfg:
		var entry: Dictionary = item
		var fid := String(entry.get("id", ""))
		if fid == "":
			continue
		# ⚠️ 玩家席位不许被 AI 接管（玩家自己那一方的资源池与命令流都是本地输入在写）。
		#    ★★ 这一条就是「**玩家选中哪一方，运行时就把那一方的 AI 摘掉**」
		#    （dev_plan_7 拍板第 13 项）的落点 —— 关卡给它配了 AI 也不建。
		if world.player_factions.has(fid):
			continue
		if String(entry.get("ai", "faction")) != "faction":
			continue
		# ⚠️ 资源池必须已经开好（见 world._setup_ai_factions）——没开就说明名单没对齐，
		#    这一条排在上面那些 continue 之后，所以正常配置永远不会命中。
		if world.resource_pool_for(fid) == null:
			push_warning("AI 名单里的「%s」没有资源池，已跳过（名单没对齐？）" % fid)
			continue
		out.append({
			"faction": fid,
			"mult": float(entry.get("resource_mult", 1.0)),
			# ★★ 这一方自己的 AI 参数（关卡按阵营覆盖；缺省 = config.json 的 ai.faction）
			#    在这里**算一次存下来** —— 它每帧要用（招兵节奏 / 出兵间隔），
			#    不该每帧重算一遍合并（那是白花花的字典复制）。
			"params": world.faction_ai_cfg(fid),
			# 下一个要招的将领序号（0 起）。招满 params.generals 个就停。
			"general_index": 0,
			"recruit_timer": 0.0,
			"upgrade_timer": 0.0,
			"attack_timer": 0.0,
		})
	return out


## 每帧：先让资源涨（资源增长），再跑决策（花钱 / 出兵）。
static func update(world, cfg: ConfigRes, dt: float) -> void:
	if dt <= 0.0 or world.ai_factions.is_empty():
		return
	for st in world.ai_factions:
		var faction := String(st["faction"])
		_income(world, st, faction, dt)
		_decide(world, cfg, _params_of(world, st), st, faction, dt)


## 某一方这一局实际生效的 AI 参数（setup 时算好存在状态里；老状态没有 → 现算一份兜底）。
static func _params_of(world, st: Dictionary) -> Dictionary:
	var p: Variant = st.get("params", null)
	if typeof(p) == TYPE_DICTIONARY:
		return p
	return world.faction_ai_cfg(String(st["faction"]))


## ★★ 资源增长：**占领的区划** 的（产能 × 地块数）× `resource_mult` × dt。
##
## 口径与 `world._refresh_production()` 里玩家那一份**逐条同义**：
##   · 走 `zones.production_of(faction)` —— 它已经把区划特化（粮食 / 黄金 +0.5/地块/秒）
##     算进去了，所以 AI 抢到一块特化过的地也一样吃加成；
##   · **不含**科技加成（科技是玩家的那九条，NPC 不启科技 —— 要给它加成请调 resource_mult）。
##
## ★ 难度旋钮只乘在这里：它放大的是「同样几块地，AI 攒钱更快」，
##   而不是「凭空多出地块」——所以地图平衡（谁的地好）仍然是决定性的。
static func _income(world, st: Dictionary, faction: String, dt: float) -> void:
	if world.zones == null:
		return
	var rates: Dictionary = world.zones.production_of(faction)
	var mult: float = float(st.get("mult", 1.0))
	var pool: Dictionary = world.resource_pool_for(faction)
	pool["food"] = float(pool.get("food", 0.0)) + float(rates.get("food", 0.0)) * mult * dt
	pool["gold"] = float(pool.get("gold", 0.0)) + float(rates.get("gold", 0.0)) * mult * dt


## 一帧的决策：资源规划的四段，**按优先级**依次尝试。
##
## ★★ 为什么是「按优先级依次尝试」而不是「每段都跑一遍」：
##   AI 的钱是有限的，四段都要钱。全跑一遍的结果是「每样都买一点、每样都不成形」
##   （典型症状：将领一个没招出来，钱全花在升级上了）。
##   所以这里用 `return` 收口：**这一帧只做最高优先级那件还做得起的事**，
##   剩下的钱留到下一帧继续按优先级花。这就是「明确的资源规划」。
##
## ⚠️ `MAX_ORDERS_PER_TICK` 是护栏：万一某一段的条件恒真（配置写错），
##    也不会在一帧里下几百条命令。
## ★★ 为什么招将会 `return`，而升级**不** `return`（这条路第一版写错过，记在这）：
##
##   「一事一帧」这条规矩要**看对象**：
##     · 招将 / 招兵是**长期动作**（一单读条 10 秒，队列里排着的也算数）——
##       同一帧连下几单会瞬间堆满队列，而且第二单的钱本来是下一帧才该花的；
##     · 升级也占钱，但它**与出兵并不冲突**：一支满员的部队该出发就出发，
##       不会因为「城里正在修墙」就原地等。第一版让升级也 `return` 了，
##       结果是**只要有闲钱，AI 永远在升级、永远不出兵**（实测：attack_timer 一直在被刷）。
##
##   所以这里的收口是：a / b 命中就收工（一帧一件事），c 与 d 都可以在同一帧发生。
static func _decide(world, cfg: ConfigRes, fc: Dictionary, st: Dictionary,
		faction: String, dt: float) -> void:
	# 大本营没了（被打掉）→ 什么都不做，资源照旧攒（以后可以拿它做「投降 / 重建」）。
	if world.find_base_of(faction) == null:
		return
	st["recruit_timer"] = maxf(0.0, float(st.get("recruit_timer", 0.0)) - dt)
	st["upgrade_timer"] = maxf(0.0, float(st.get("upgrade_timer", 0.0)) - dt)
	st["attack_timer"] = maxf(0.0, float(st.get("attack_timer", 0.0)) - dt)

	var max_generals: int = int(fc["generals"])
	var min_retinue: int = int(fc["min_retinue"])
	var generals: Array = _generals_of(world, faction)

	# ---- 编制上限：★★ 新口径 = **关卡里给这位将领摆了几个附属兵** ----
	#
	# 本轮把「全局缺省编制」整个删掉了（`config.json` 的 `unit.general.escort`
	# 与 `Config.general_escort_at()` 都没了），理由「所见即所得」：
	#   开局场上有多少兵，必须完全等于关卡 `start_units[]` 里摆出来的那些。
	#
	# ★★ `fc["min_retinue"]` 在新口径下的作用（**别再把它删掉**，实测回归过）：
	#   目标编制按「这一方有没有在关卡里摆过附属部队」分两条路（实现只有一处：
	#   `world.escort_target_of()`）：
	#     · **摆过** → 关卡摆几个就是几个（作者摆 0 个 = 明确指令「别给我补兵」），
	#       `min_retinue` 在这条路上不参与；
	#     · **没摆过**（自由对战的自动生成将领、只摆了将领的关卡）→ 退到 `min_retinue`。
	#   ⚠️⚠️ 少了第二条的后果（手玩实测报回来：「红方的将领没有招满单位就向目标点
	#      行军攻击了」）：没摆附属兵的一方目标恒为 0 ⇒ 下面「闲着的将领都满员了吗」
	#      当场成立 ⇒ **AI 一个兵都不招、开局第 1 帧就出征**。
	#   ★ `min_retinue` 仍然兼任「这一方要不要做 b 段（补员）」的开关：
	#     它 `<= 0` 时整段跳过（见下面 b 段的 `if min_retinue > 0`）。
	var target_retinue := func(g) -> int:
		return world.escort_target_of(faction, int(g.general_index))

	# ---- 哪些将领**已经在场**（按序号）----
	#   ★★ 这一条修的是一个实测 bug：原来判「将领招够没有」看的是自己那个
	#      **只增不减的计数器** `st["general_index"]`，而世界初始化时**已经**给每一方
	#      建好了将领（`world.create_generals`，一建就是 3 位）。
	#      于是「计数器说我只招了 2 个」与「场上已经有 3 个」两件事同时成立 ⇒
	#      实际将领数 = 初始那几位 + `generals`，比配置多；而派兵比例
	#      `want = ceil(将领数 × ready_mult)` 是拿**场上人数**算的 ⇒
	#      多出来的将领直接把「派几成」算歪（实测：配置 2 位、场上 5 位、
	#      有时派 1 位有时派 2 位）。
	#   ★ 现在按**序号占位**判断：第 i 个槽位上有活着的将领就不招它。
	#      这比计数器更准，而且顺带修好「某位将领阵亡 → 它的槽位会被补招回来」
	#      （计数器只增不减，阵亡的永远不会补）。
	var occupied: Dictionary = {}
	for g in generals:
		var gi: int = int(g.general_index)
		if gi >= 0:
			occupied[gi] = true
	var next_slot := 0
	while occupied.has(next_slot):
		next_slot += 1
	# ★ 状态里的计数器仍然参与判断，但只当**下限**（`max`）：它是「我招到第几号了」的
	#   记忆，而上面那个是从**世界状态**现算出来的真相。
	#   为什么还要留着它：① 快照 / 测试会直接写它来「跳过招将」（见 tests/test_ai.gd）；
	#   ② 招募单在**区划队列**里读条时，那位将领还没进 `world.units` ——
	#      只看世界会以为槽位空着而重复下单，计数器记住了那一步。
	#   ⚠️ 反过来「只看计数器」就是这一轮修掉的那个 bug：
	#      世界初始化白建的将领它看不到（实测：配置 2 位、场上有 3 位）。
	next_slot = maxi(next_slot, int(st.get("general_index", 0)))

	# ---- a) 招将领（有空槽位、且不在读条）----
	if next_slot < max_generals and float(st["recruit_timer"]) <= 0.0:
		var zone = _recruit_zone(world, faction)
		if zone != null:
			var kind := _general_kind_for(next_slot)
			if kind != "" and world.can_recruit_zone(kind, int((zone as Dictionary)["id"]), faction) == "" \
					and world.can_afford_zone_recruit(kind, int((zone as Dictionary)["id"])) == "":
				if world.start_zone_recruit(kind, int((zone as Dictionary)["id"]), faction):
					# ★ 计数器 = **下一个**要招的槽位（+1），与原来「招了几个」是同一个读法：
					#   `>= max_generals` 就等于「招满了」。
					st["general_index"] = next_slot + 1
					st["recruit_timer"] = float(fc["recruit_cooldown_sec"])
					return

	# ---- b) 让将领招兵（每个将领补到**它自己**的编制上限）----
	if min_retinue > 0 and float(st["recruit_timer"]) <= 0.0:
		var orders := 0
		for g in generals:
			if orders >= MAX_ORDERS_PER_TICK:
				break
			if g.is_training():
				continue                      # 它已经在造了（队列里排着的也算）
			# ★★ 濒死的将领**不招兵**（本轮新增）：它倒在原地，招出来的兵只会
			#    堆在它身上，而它是全队最不该吸引火力的那个位置。
			#    ⚠️ 它**照样占槽位**（那是 `_generals_of` 的事，与这一句无关）——
			#      这一句只是「不让一个躺着的人读条」。
			if g.is_downed():
				continue
			if g.retinue_size(world) >= int(target_retinue.call(g)):
				continue
			var kind2 := _unit_kind_for(world, g)
			if kind2 == "":
				continue
			if world.can_recruit(kind2, String(g.id), faction) != "":
				continue
			if world.can_afford_recruit(kind2, String(g.id)) != "":
				continue
			if world.start_recruit(kind2, String(g.id), faction):
				orders += 1
		if orders > 0:
			st["recruit_timer"] = float(fc["recruit_cooldown_sec"])
			return

	# ---- 0) ★★ 让**濒死的**将领再起（本轮新增）----
	#
	# 需求原话：「ai 在将领濒死后可在符合条件时使用资源让其再起」。
	#
	# ★★ 为什么排在「招将领 / 招兵」**之后**、升级 / 出兵**之前**（次序是本轮定的）：
	#   · 招将（a 段）是**填空槽位**——濒死的将领虽然占着槽位，但那一方若本来就还有
	#     空位（编制 3 位只招出来 2 位），先补满编制比救一个倒下的更划算；
	#   · 再起排在升级（c 段）**之前**：一位能打的将领比一堵更厚的墙值钱，
	#     而升级正是「任何时候只要有闲钱就会一直做」的那一件（见 c 段那段说明）。
	#
	# ★ 「没有更高优先级开支」的实际口径 = **这一帧 a / b 两段都没有下单**：
	#   那两段一命中就 `return`，所以能走到这里的帧本来就已经「把兵源安排好了」。
	#   这不是新加的闸门，而是既有的优先级链条自然给出的位置。
	if _try_revive(world, cfg, fc, faction):
		return

	# ---- c) 升级建筑（挑最便宜的那一栋；留出 reserve 不花光）----
	#      ★ 这一段**不 return**：升级与出兵可以同一帧发生（理由见上面那段注释）。
	if float(st["upgrade_timer"]) <= 0.0:
		var b = _pick_upgrade(world, cfg, faction, float(fc["upgrade_reserve_food"]),
			float(fc["upgrade_reserve_gold"]))
		if b != null:
			# ★★ 无论成不成，都要把冷却记上（实测报回来的 bug）：
			#   原来只有**成功**才写 `upgrade_timer`，于是 `start_building_upgrade`
			#   被拒（`busy` / 钱不够）时冷却保持 0 ⇒ **下一帧立刻再试一次**，
			#   每帧推一条 `upgrade_rejected`。玩家看到的是别人的拒因刷屏。
			world.start_building_upgrade(b.tx, b.ty, faction)
			st["upgrade_timer"] = float(fc["upgrade_cooldown_sec"])

	# ---- d) 出兵：**闲着的**可进攻将领都补满员 → 派一批行军攻击 ----
	#
	# ★★ 「可进攻的将领」= 全部将领 **减去驻防的**（`is_garrison()`，判据是
	#   `unit.garrison_zone_id >= 0`：地图给了 zone、或出生在某个区划里的将领）。
	#   为什么要减（实测踩到）：原来 `_generals_of()` 把**所有**将领都算进来，
	#   于是地图上守点的将领也会被派出去打 —— 它一走，守的那个点就空了，
	#   而且「派几成」的分母里混进了本来不该动的人。
	#   ★ 驻防将领与玩家那边的驻防将领是同一套规则（`logic/general_ai.gd` 驱动它们
	#     巡逻与警戒），所以这里只是「不把它们编进攻势」。
	#   ★★ 濒死的将领也**不进攻势**（本轮新增）：它连动都动不了，编进去只会让
	#      「派几位」的分母虚高、把真正能打的那几位挤掉。它由上面 0 段负责救。
	var field: Array = []
	for g in generals:
		if g.is_garrison():
			continue
		if g.is_downed():
			continue
		field.append(g)
	if next_slot < max_generals:
		return                                # 还有空槽位没招满，不谈出兵
	# ★★ 只等**闲着的**那些人满员，而且只等「正在补**编外将领**」的那种读条。
	#
	# 修的是实测报回来的两条（同一处 gate 造成的）：
	#   · **「骑兵将领一直不出兵」**：它那一档编制最大（`[4,5,6]` 里的 6），
	#     永远是最后一个补满的 ⇒ 每次都卡在这一句上；而 `_launch_attack` 里
	#     那句 `if g.is_training(): continue` 又会跳过它 ⇒ **永远不派它**。
	#     ⇒ 判据从「`g.is_training()`（在读条就跳过）」改成
	#       「**只在它正在招编外将领时才跳过**」：补自己兵的那种读条**不该**挡出征
	#       （兵账在 `retinue_size()` 里已经算上了，它们会跟着走）。
	#   · **「一个将领死了就再也不出兵」**：原来 gate 是「**全员**满员」，
	#     死一个就永远补不齐 ⇒ 出兵被永久卡死。
	#     ⇒ 已经在打的（`target != null`）不再算进 gate：它们本来就不该被重派，
	#       也就没资格拦住整批人。
	for g in field:
		if g.target != null or g.target_building != null:
			continue                          # 正在交战的：不重派、也不拦别人
		if _is_recruiting_general(cfg, g):
			return                            # 它自己正在招一位新将领：等它
		# ★★ 「满员」不能只看**兵账**（`retinue_size()` 把**还在读条**的那几个也算上了）。
		#
		# 实测报回来的原文：「第一波时骑兵将领还是不会行军攻击过来，但第二波却和
		#                   新招募的将领一起行军过来了」。
		# 根因就在这一句的**旧写法**上：编制最大的那位（骑兵，`[4,5,6]` 里的 6）
		# 在发起那一波时第 6 个兵**还在读条** —— 兵账已经算成 6（gate 放行），
		# 但它自己被「招募期间钉在原地」那条规则锁在家里（`is_training()` 为真），
		# 于是：
		#   · 同队的另外两位（兵少、早就出完了）已经出发；
		#   · 它要等读完条才动 —— 玩家看到的是「骑兵将领没跟着来」，
		#     而下一波（它读完了）它就跟着来了。
		# ⇒ 判据加上「**不能有在读条的东西**」：发兵那一刻全队都必须真的能走。
		#   ⚠️ 这一条**不会**死锁：AI 的兵全是它自己招的（开局附属兵由关卡摆放决定，
		#      而 AI 自己招的那些将领目标编制是 0 ⇒ 它们立刻就是「满员」），
		#      读条一定会读完（有资源/人口就继续招，没有就等产出）——
		#      它只是把「发兵」推迟到全队真的站在场上那一刻。
		if g.is_training():
			return                            # 它还有兵在读条：等一下，别把它落下
		if g.retinue_size(world) < int(target_retinue.call(g)):
			return                            # 闲着的还没满员，不谈出兵
	if float(st["attack_timer"]) > 0.0:
		return
	# ★ 「至少 min_ready 位」这条只在**凑得出来**的时候才拦：`generals` 是这一方编制里
	#   的将领数，`field` 是现在真能动的。打光之后 `field` 会长期小于配置那个常数，
	#   那时**不该**永久卡死 —— 让剩下的将领继续出击，同时（见上面 a 段）把死掉的槽位补回来。
	#   ⚠️ `field` 里还含着「正在打的那几位」，它们不可能被重派 ⇒ 能派的上限是
	#      `field.size() - 1`。所以门槛取 `min(min_ready, max_generals - 1)`：
	#      编制 3 位 / min_ready 3 时门槛是 2（1 个在打 + 1 个闲着的就能再派），
	#      编制 5 位 / min_ready 3 时门槛仍是 3（不会变成「一个就敢冲」）。
	if field.size() < mini(int(fc["min_ready"]), maxi(1, max_generals - 1)):
		return
	_launch_attack(world, cfg, fc, field, faction)
	st["attack_timer"] = _attack_repeat(fc)


## `ai.faction.attack_repeat_sec` 的安全版（读一次、夹一次）。
## ★ 参数是**这一方自己那一份**（关卡可按阵营覆盖），不是全局那一份。
static func _attack_repeat(fc: Dictionary) -> float:
	return maxf(0.1, float(fc.get("attack_repeat_sec", 6.0)))


## 派兵：按 `ready_mult` 决定这次派几个将领（至少 min_ready 个），
## 挑**离目标最近的**那几位，对它们下达行军攻击命令。
##
## 目标：**先问关卡数据**（`attack_target`），没写 → 离这个 AI 最近的**敌方区划中心**，
## 没有敌方区划 → 敌方大本营。
##
## ★ 为什么挑「离目标最近」而不是「全部一起上」：需求要的是「派遣这些将领行军攻击某处」——
##   分兵去打最近的那块地才叫「攻击某处」；全员扑同一个点会让它自己的地盘没人守。
## ★ 用 `order_attack_move`（行军攻击）而不是 `order_move`：
##   路上遇到守军会停下来打（那是 A 键的语义），打完继续走 —— 这正是「行军攻击某处」。
##
## ★★ 末尾那一条 `ai_attack_launched` 事件是本文为「波次播报」保留的**唯一一处新代码**
##   （dev_plan_7 1.3.5）：用户嘴里的「一波红点」= 这里的一次派兵。
##   逻辑层**只给参数**（哪一方 / 派了几位 / 目标是什么），文案在 `view/` 一处翻译。
static func _launch_attack(world, cfg: ConfigRes, fc: Dictionary, generals: Array,
		faction: String) -> void:
	var goal: Variant = _attack_target(world, faction)
	if goal == null:
		return
	var goal_tile: Vector2i = goal
	var goal_pt: Vector2 = GridRes.center_of(goal_tile)

	# 派几个：ready_mult 是「准备好的人里派出去几成」，至少 min_ready 个，最多全派。
	var want: int = int(ceil(float(generals.size()) * clampf(float(fc["ready_mult"]), 0.0, 1.0)))
	want = maxi(1, want)
	want = maxi(int(fc["min_ready"]), want)
	want = mini(want, generals.size())

	# 按「离目标近」排序（近的打头，也就先被选中）——不引入随机：AI 要可复现。
	var sorted: Array = generals.duplicate()
	sorted.sort_custom(func(a, b):
		return a.pos.distance_squared_to(goal_pt) < b.pos.distance_squared_to(goal_pt))

	var sent := 0
	for g in sorted:
		if sent >= want:
			break
		# 已经在打的将领不打断（它可能正被玩家的兵缠住）。
		if g.target != null or g.target_building != null:
			continue
		# ★ 只有「正在招**编外将领**」时才跳过（补自己兵的那种读条不挡出征）。
		#   原来这里是无条件 `g.is_training(): continue`，而编制最大的那位
		#   （骑兵将领）永远是最后一个补满的 ⇒ 每次都被这一句跳过、**永远不出征**。
		if _is_recruiting_general(cfg, g):
			continue
		# ★★ 整队出动：将领 + 它辖下的**全部**部队一起行军攻击。
		#
		# 需求原话：「当敌方将领招募满兵时，只有将领会行军攻击，我要的是他的
		#           整个部队都行军攻击」。
		# ⚠️ 原来只对 `g` 自己下一句 `order_attack_move` —— 部队一动不动地留在原地
		#   （它们没有 `leader_id` 之外的任何「跟着队长走」的机制：玩家那边是
		#    `world.expand_to_groups()` 展开成一整队再逐个下令，见 input_controller）。
		#   ⇒ 这里走**与玩家同一条**路：`order_group_attack_move`（队形 + 逐单位下令）。
		if CommandProcessorRes.order_group_attack_move(world, cfg, world.group_of(g), goal_pt):
			sent += 1

	# ★★ 「红点来袭」的体感就靠这一条：哪一方出兵了、派了几位、往哪打。
	#    ⚠️ 一位都没派出去时不发（那不是「一波」）—— 免得播报与画面不一致。
	if sent > 0:
		world.push_event({
			"type": "ai_attack_launched",
			"faction": faction,
			"leaders": sent,
			"target": _target_label(world, goal_tile),
			"x": goal_tile.x,
			"y": goal_tile.y,
		})


## 目标点的**人话标签**（给播报用）：那一格落在某个区划里就用区划名，否则用坐标。
##
## ★ 只做「格 → 区划」这一层翻译，不判断「这是谁的区划」—— 那属于界面文案，
##   而逻辑层只给参数（见 dev_plan_7 3.9）。
static func _target_label(world, tile: Vector2i) -> String:
	if world == null or world.zones == null:
		return "(%d,%d)" % [tile.x, tile.y]
	var z = world.zones.zone_at(tile.x, tile.y)
	if z != null:
		var zid := int((z as Dictionary).get("id", -1))
		var nm := String((z as Dictionary).get("name", ""))
		if nm != "":
			return nm
		if zid >= 0:
			return "c%d" % zid
	return "(%d,%d)" % [tile.x, tile.y]


## ★★ 攻击目标：**先问关卡数据，没有就退回现状挑选逻辑**（dev_plan_7 3.3 改动①）。
##
## 关卡数据里的 `attack_target`（四种 kind，见 `world.level_attack_target`）就是
## 用户嘴里「规定其行军攻击的目标点」那件事的落点 —— **「波次」在这个数据格式里没有独立字段**，
## 它就是「这一方挂着阵营 AI」+「它的 attack_target 指着哪」这两件事的组合。
##
## ⚠️ 三条不能破（写进断言）：
##   1. **缺省必须逐位不变**：没写 `attack_target` 的关卡 / 不做战役的老路径，
##      走的还是下面 `_attack_target_default()` —— 一个字都没改；
##   2. 关卡给的目标**不可达时要退回现状挑选**（`world.level_attack_target` 已经过了一遍
##      `nearest_reachable` 过滤）：否则会出现「AI 对着一个走不到的点原地发呆」
##      —— 这类症状在 HTML 版出现过；
##   3. 出兵仍然走现成的 `order_attack_move`（行军攻击），**不新写一套命令**。
static func _attack_target(world, faction: String) -> Variant:
	if world != null and world.has_method("level_attack_target"):
		var t: Variant = world.level_attack_target(faction)
		if t != null:
			return t
	return _attack_target_default(world, faction)


## 攻击目标（**现状**）：离自己最近的**敌方区划中心**（没有中心格的区划跳过），
## 全都没有 → 敌方大本营。
##
## ★ 判据用 `FactionRes.same_side_for_attack(z.owner, faction)` 取反，而不是写
##   `z.owner != faction`：
##   · 空 owner（无主区划）不是「敌方」—— 去打一片没人的地毫无意义（额外判 `owner != ""`）；
##   · ★★ **盟友的地也不是敌方**（阵营归属）：这一条决定了「两个 AI 友善」在
##     AI 这一侧真的成立 —— 不改成「同阵营或盟友」的话，阵营 AI 照样会
##     把盟友的区划当成进攻目标，一路推过去把友军打死（自动索敌只是不主动开火，
##     但行军攻击的目标点是 AI 自己挑的）。
##
## ⚠️ 这段逻辑是**缺省**（第 1 条）：加战役时它被**原样**搬进这个函数，一个字都没改
##   —— 所以「不做战役」的行为与从前逐位一致（tests/test_ai.gd 的 150 项是回归）。
static func _attack_target_default(world, faction: String) -> Variant:
	if world.zones == null:
		return null
	var home: Vector2i = world.home_base_of(faction)
	var best: Variant = null
	var best_d := INF
	for z in world.zones.zones:
		var owner := String((z as Dictionary)["owner"])
		if owner == "" or FactionRes.same_side_for_attack(owner, faction):
			continue
		var c: Variant = (z as Dictionary).get("center", null)
		if c == null:
			continue
		var d: float = GridRes.octile_distance((c as Vector2i).x - home.x, (c as Vector2i).y - home.y)
		if d < best_d:
			best_d = d
			best = c
	if best != null:
		return best
	# 没有敌方区划中心 → 找一个敌方大本营
	for b in world.building_list:
		if not b.alive or b.type != BuildingRes.TYPE_BASE:
			continue
		if FactionRes.same_side_for_attack(String(b.owner), faction):
			continue
		var d2: float = GridRes.octile_distance(b.tx - home.x, b.ty - home.y)
		if d2 < best_d:
			best_d = d2
			best = Vector2i(b.tx, b.ty)
	return best


## 这个阵营的将领列表（`kind` 是将领类、还活着）。
##
## ★ 判据走 `unit.is_general()`（= `ConfigRes.general_index_of(kind) >= 0`）：
##   与渲染（描边更粗）、科技血量加成用的是**同一个**判据 —— 不另写一份前缀判断。
##
## ★★ **濒死的将领也算在这一份里**（本轮确认的口径）：需求原话「濒死的将领也会
##   占用 ai 的将领槽位暂时阻止招募新将领，直到该将领真正死亡」——
##   而 `alive` 在濒死期间仍然是 true（见 unit.downed 的说明），所以这一句
##   `not u.alive` 天然就把「濒死者照旧占位」表达出来了。
##   ⚠️ 别在这里加 `and not u.is_downed()`：那会变成「将领一倒下 AI 就立刻补招一位」，
##      槽位被绕过，而且白花一份招将的钱。
static func _generals_of(world, faction: String) -> Array:
	var out: Array = []
	for u in world.units:
		if not u.alive or u.faction != faction:
			continue
		if u.is_general():
			out.append(u)
	return out


## ★★ AI 让濒死的将领再起（本轮新增）。
##
## 条件（逐条对应需求 + 用户拍板）：
##   1. 血量已经回到 `revive.ready_ratio`（默认 10%）—— 与玩家**同一个门槛**
##      （`world.revive_reject_reason` 里判的，AI 不另写一份）；
##   2. 这一方**付得起** `revive.cost` + `ai.faction.revive_reserve_*`（预留部分
##      默认 0 = 只要付得起就再起）；
##   3. 没有人正在读条再起（一帧最多下一单，`MAX_ORDERS_PER_TICK` 那条护栏的同类）。
##
## ★ 走 `world.start_revive()` —— 与玩家点「再起」那一格**完全同一条**路：
##   扣费、读条、事件、取消退款全都在那边，AI 这边不复制任何规则。
## ★ 已经因「部队全灭」而死的将领不在 `_generals_of` 里（它 alive == false），
##   所以 AI 不会对着一个死人反复下单。
##
## @return true = 这一帧确实下了一单再起（调用方据此收工）
static func _try_revive(world, cfg: ConfigRes, fc: Dictionary, faction: String) -> bool:
	var reserve_food := float(fc.get("revive_reserve_food", 0.0))
	var reserve_gold := float(fc.get("revive_reserve_gold", 0.0))
	var cost: Dictionary = world.revive_cost()
	var pool: Variant = world.resource_pool_for(faction)
	for g in _generals_of(world, faction):
		if not g.is_downed():
			continue
		if g.revive_remaining > 0.0:
			continue                          # 已经在读条了（这一单正在走）
		if not g.revive_ready(cfg):
			continue                          # 还没回到 10%
		# ★ 预留：`can_afford` 只看「够不够 cost」，预留要自己加上去比。
		#   ⚠️ 池子是 null（这一方没有资源库 = 资源无限）时直接放行 ——
		#      与 `EconomyRes.can_afford` 对 null 的语义一致。
		if pool != null:
			if float((pool as Dictionary).get("food", 0.0)) < float(cost.get("food", 0.0)) + reserve_food:
				continue
			if float((pool as Dictionary).get("gold", 0.0)) < float(cost.get("gold", 0.0)) + reserve_gold:
				continue
		if world.start_revive(String(g.id), faction):
			return true
	return false


## 这个将领现在是不是「正在招**另一位将领**」（编外将领）。
##
## ★★ 为什么要区分「招将领」与「招自己的兵」：两者都会让 `is_training()` 为真，
##   但只有前者意味着「这个将领还没成形」。原来出兵那一段用的是无条件的
##   `is_training()`，于是**编制最大的那位**（`[4,5,6]` 里的骑兵将领，要 6 个兵）
##   永远是最后一个补满的 ⇒ 每次都在读条中被跳过 ⇒ **永远不出征**（实测报回来的
##   「骑兵将领招募满单位后不会行军攻击」）。
##
## 判据只认一个地方：`unit.train_kind` 是不是将领类（`ConfigRes.is_general_kind`）——
## 与 `general_index_of` / 招募表用的是同一套编号，不另写前缀判断。
static func _is_recruiting_general(cfg: ConfigRes, g) -> bool:
	if g == null:
		return false
	if not g.is_training():
		return false
	var kind := String(g.train_kind)
	if kind == "":
		# 只在排队、没在读条：队列里排的是将领也算（`train_queue` 里存的是 kind 字符串）
		for k in g.train_queue:
			if cfg.is_general_kind(String(k)):
				return true
		return false
	return cfg.is_general_kind(kind)


## 招将领用的 kind：`general_1` / `general_2` / …（序号 1 起，与 config 的
## `recruit.zone.list` 与 `ConfigRes.general_index_of` 同一套编号）。
static func _general_kind_for(index: int) -> String:
	return "general_%d" % (index + 1)


## 让某个将领招什么兵：**与它自己同类型**的兵（将领 1 是长枪兵就补长枪兵）。
## 表里没有这个 kind 时退回招募表第一条（免得地图改了兵种之后 AI 彻底不招兵）。
static func _unit_kind_for(world, g) -> String:
	var kind := String(g.unit_type)
	if world.is_unit_recruitable(kind):
		return kind
	var lst: Array = world.recruit_list()
	if lst.is_empty():
		return ""
	return String((lst[0] as Dictionary).get("kind", ""))


## 找一个「可以招将领」的区划：优先自己的区划中心，其次自己的任何区划。
##
## ★ 需求里将领是在**区划**里招的（区划 = 兵营，见 config 的 recruit.zone）——
##   所以 AI 也必须先有地才能招将；没地就先靠单位去占（这是有意的先后关系）。
static func _recruit_zone(world, faction: String) -> Variant:
	if world.zones == null:
		return null
	var with_center: Variant = null
	for z in world.zones.zones:
		if String((z as Dictionary)["owner"]) != faction:
			continue
		if (z as Dictionary).get("center", null) != null:
			return z                       # 有中心的优先
		if with_center == null:
			with_center = z
	return with_center


## 挑一栋最值得升级的建筑：**能升级 + 钱够（扣掉 reserve）+ 最便宜**。
##
## @return Building 或 null
##
## ★ 为什么挑最便宜的那一栋：AI 的钱是慢慢攒的，先升级一栋便宜的就是
##   「先形成战斗力再攒大招」；挑最贵的会让它一直攒着不花钱（看起来像坏了）。
## ★ reserve 的语义是「留给招兵 / 招将的钱，不许被升级吃掉」——
##   `ai.faction.upgrade_reserve_*` 默认 0（不预留），调大就是「优先保证兵源」。
static func _pick_upgrade(world, cfg: ConfigRes, faction: String,
		reserve_food: float, reserve_gold: float) -> Variant:
	var pool: Dictionary = world.resource_pool_for(faction)
	var best = null
	var best_cost := INF
	for b in world.building_list:
		if not b.alive or String(b.owner) != faction:
			continue
		if not world.building_can_upgrade(b.type):
			continue
		# ★★ 在读条的那一栋**跳过**（实测报回来的 bug）。
		# 不加这一句会怎样：这里每秒重挑中同一栋（它的升级代价仍然算得出来），
		# 于是每秒下一次单 → 被 `can_upgrade` 拒（`busy`）→ 推一条
		# `upgrade_rejected`。玩家那边看到的就是「城墙正在读条…」这种
		# **别人的**消息刷屏（60 秒实测几百条）。
		# ⚠️ 这类事件本来只该由**玩家的**命令产生，所以它同时暴露了界面漏过滤
		#    （见 view/game_scene.gd 的 `_is_my_event`）——**两处都要修**：
		#    这里治「不该产生的报错」，那里治「别人的报错别显示给我」。
		if b.is_upgrading():
			continue
		var cost: Dictionary = world.building_upgrade_cost(b)
		if cost.is_empty():
			continue                      # 满级
		var need_food := float(cost.get("food", 0.0)) + reserve_food
		var need_gold := float(cost.get("gold", 0.0)) + reserve_gold
		if float(pool.get("food", 0.0)) < need_food or float(pool.get("gold", 0.0)) < need_gold:
			continue
		var weight := float(cost.get("food", 0.0)) + float(cost.get("gold", 0.0))
		if weight < best_cost:
			best_cost = weight
			best = b
	return best
