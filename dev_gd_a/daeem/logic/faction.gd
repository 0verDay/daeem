## faction.gd —— 阵营模型（对应 HTML 版 js/faction.js）
##
## 为什么要有单独一个模块：原来阵营是散落各处的字符串字面量 'player' / 'enemy'，
## 两个玩家都会是 'player'，于是永远不会互相索敌，「互相看到 + 能打」根本无法达成。
## 这里把阵营语义收敛到一处。
##
## 阵营取值：
##   'p1'      玩家一（房主）；★ **单机也用它** —— 不再有 'player' 这个别名
##   'p2'      玩家二（客机）
##   'p3'…'p8' 预留，最多 8 个玩家席位
##   'enemy'   NPC / 调试用的测试敌人
##
## ★★ 两条对称规则，方向相反，**别搞混**：
##   is_player_faction(f) —— 这个阵营是不是「玩家控制的一方」？决定它是否索敌 / 占区块 / 回血
##   same_side(a, b)      —— 这两者是不是「同一方」？决定是否互相攻击、城墙是否放行
##
## ★ 为什么没有 'player' 了（改过一版）：原来单机用 'player'、联机用 'p1'…'p8'，
##   于是「地图里写的大本营属于谁」要对两套名字 —— 地图编辑器划出来的是 p1/p2，
##   而单机引擎找的是 'player'，两边对不上（症状：地图里明明给 p1 划了大本营，
##   单机跑起来却用默认点位）。现在**只有一套 id**：单机 / 房主就是 p1。
##   ⚠️ 老地图里写的 "player" 因此**不再被识别**（地图导入不看这个标签了）。
##
## 本模块不依赖任何其它 logic 模块 —— 保持它在依赖图最底层。
##
## ⚠️ 跨文件引用规则见 logic/config.gd 顶部：`--script` 模式下全局 class_name 不可用，
##    所以本文件不写 class_name，调用方用 preload 常量。
extends RefCounted

## 默认阵营 = P1：单机（没有联机名单）与联机的房主都用它
const DEFAULT_FACTION := "p1"

## NPC 阵营（测试敌人）
const NPC_FACTION := "enemy"

## ★★ 阵营 AI 的默认阵营 id（本轮新增，见 logic/red_dot_ai.gd 与 config.ai.factions）。
##
## ★ 为什么需要一个新的 id、而不是复用 'enemy'：
##   'enemy' 是**地图上那批测试敌人**（守军 + 巡逻兵）的阵营，它们跑的是
##   `enemy_ai.gd` 的推进逻辑；而「阵营 AI」是一条**完全不同的**玩法
##   （有自己的资源库、招将、升级、出兵）。两者同属 NPC，但行为与状态互不相干 ——
##   挤在同一个 id 上会让「这张图有几个 AI 在经营」说不清楚。
## ★ 它**不是玩家席位**（不在 FACTION_ROSTER 里）⇒ 不被玩家指挥、不会自动索敌占区块、
##   也不吃科技加成 —— 正是需求里「附属在某个阵营/势力下」的那个「势力」。
## ★ 真正的 AI 名单在 `config.ai.factions`（可以挂好几个，也可以一个都不挂）；
##   这个常量只是**默认值**与「配置读不出来时的兜底」。
const AI_FACTION := "ai"

## 联机时的玩家席位顺序：第一个连上的是房主
const FACTION_ROSTER: Array[String] = ["p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8"]

## 单机模式（没有联机）下使用的阵营表
const SINGLE_PLAYER_ROSTER: Array[String] = [DEFAULT_FACTION]


## 玩家席位集合（给 is_player_faction 做 O(1) 查表用）。
## ★ 为什么要字典而不是 `f in FACTION_ROSTER`：后者是**数组线性查找 + 字符串比较**，
##   而 is_player_faction 在「每帧每单位」的路径上（回血判定、索敌分支）。
##   1000 单位下就是每秒 6 万次最多 8 个字符串的比较。
## ⚠️ 必须是 `static var`：下面的 is_player_faction 是静态函数，读不了实例变量。
static var _PLAYER_SET: Dictionary = {
	"p1": true, "p2": true, "p3": true, "p4": true,
	"p5": true, "p6": true, "p7": true, "p8": true,
}


## 这个阵营是不是玩家控制的一方？
##
## 两种「玩家方」的区分（别搞混）：
##   DEFAULT_FACTION（'p1'）+ FACTION_ROSTER（'p1'..'p8'）→ 是玩家方
##   NPC_FACTION（'enemy'）→ 不是
## 只有玩家方才会自动索敌、占区块、在自家领地回血。
static func is_player_faction(f: String) -> bool:
	return _PLAYER_SET.has(f)


## 两者是否同一方（用于索敌与城墙通行）
static func same_side(a: String, b: String) -> bool:
	return a == b


# ------------------------------------------------------------------
# ★★ 阵营归属（盟友）—— 哪些阵营是「一方人」
#
# 需求原话：「为游戏添加阵营归属，让『边关』地图中的两个 ai 的阵营关系变为友善，
#            不再相互攻击」+「不相互攻击，且不争夺同一区划」。
#
# 设计（★ 先读这一段再改）：
#   · 关系是**地图数据**（`map.json` 的 `allies` 字段），不是全局配置 ——
#     这样「只有边关友善、别的图照旧」是天然成立的，也正是需求要的。
#     解析在 `logic/map_data.gd`，注入在 `world.reset()`（都在本文件之后）。
#   · 关系**互相**：写成 `[["enemy","ai"]]` 就是两边都友善（没有单向盟友这种东西）；
#     同一方里三个以上阵营也支持（每两个都互为盟友）。
#   · ★★ 它只影响三件事 —— **不**影响「建筑挡不挡自己人」：
#       1. 索敌 / 攻击（不再互相选为目标、不再互相开火）；
#       2. 占领：同一方的兵算**一方**（不会互相抵消读条、也不会抢盟友的地）；
#       3. 没有第 3 件。
#     为什么**不**把 `same_side` 本身改成「含盟友」：那个函数同时管着**建筑通行**
#     （城墙 / 箭塔 / 大本营挡不挡路，见 building.blocks / body_blocks）与寻路惩罚。
#     把它改宽会让盟友的城墙对彼此的军队形同虚设 —— 那是另一条需求，用户没要。
#     所以这里**另开**一组函数，语义写在名字里，谁都不会用错。
# ------------------------------------------------------------------

## 盟友表：单向对（每对**双向**登记，查询时只需一次查表）。
## ⚠️ `static var` —— 下面的查询函数是静态的，读不了实例变量。
static var _ALLY: Dictionary = {}
## 登记过的盟友**对**（形如 `[["enemy","ai"]]`，已去重）。
## ★ 为什么还留一份原始的对：`side_of()` / `side_members()` 要沿关系做连通搜索
##   （一方里可能有 3 个以上阵营），遍历「对」比反解 `_ALLY` 的复合键干净得多。
static var _ALLY_PAIRS: Array = []


## ★ 设置这一局的盟友关系（由 `world.reset()` 从地图数据调）。
##
## @param pairs 形如 `[["enemy", "ai"], ...]`（每个元素是两个阵营 id；空值 / 非数组会被跳过）
##
## ★ 幂等：每次都**先清空**再写 —— 换一张图（或者重开一局）必须把上一张图的关系丢掉，
##   否则「边关的盟友」会悄悄跟到别的图上（那是最难查的一类错）。
## ★ 传空数组 = 这一局没有任何盟友（默认行为，与加这个功能之前逐位一致）。
static func set_allies(pairs: Array) -> void:
	_ALLY = {}
	_ALLY_PAIRS = []
	for pr in pairs:
		if typeof(pr) != TYPE_ARRAY:
			continue
		var list: Array = pr as Array
		if list.size() < 2:
			continue
		var a := String(list[0]).strip_edges()
		var b := String(list[1]).strip_edges()
		if a == "" or b == "" or a == b:
			continue
		var key := _pair_key(a, b)
		if _ALLY.has(key):
			continue
		_ALLY[key] = true
		_ALLY_PAIRS.append([a, b])
	# ★★ 传递闭包：`a-b` + `b-c` ⇒ 三边全登记（a 与 c 也直接成为盟友）。
	#   为什么需要：`same_side_for_attack` 只查一次表（它在每帧每单位的路径上），
	#   所以「隔着 b 算不算一边人」必须在**登记时**就展开好，不能靠查询时走图。
	_expand_transitively()


## 清空盟友关系（`world.reset()` 开头调一次，保证重开一局绝对干净）。
static func clear_allies() -> void:
	_ALLY = {}
	_ALLY_PAIRS = []


## 这一局登记了哪些盟友对（只读，给测试与调试用）。
static func ally_pairs() -> Array:
	return _ALLY_PAIRS.duplicate()


## 把盟友关系展开成**传递闭包**：同一方里的任意两个成员都直接在表里（见 `set_allies`）。
##
## ★ 只有 `set_allies` 会调它（关系变化时一次），查询函数一个字都不改 ——
##   `same_side_for_attack` 仍然是一次字典查表（每帧每单位都在跑）。
static func _expand_transitively() -> void:
	var members: Dictionary = {}
	for pr in _ALLY_PAIRS:
		var list: Array = pr as Array
		if list.size() != 2:
			continue
		members[String(list[0])] = true
		members[String(list[1])] = true
	for a in members.keys():
		var group := _collect_side(String(a))
		for b in group:
			if String(b) == String(a):
				continue
			_ALLY[_pair_key(String(a), String(b))] = true


## 这两个阵营是不是盟友（**不含**「同一个阵营」那一档）。
##
## ⚠️ `a == b` 返回 **false**：本函数只回答「结盟关系」，判「是不是一边人」请用
##    `same_side()`（同一个阵营）或 `same_side_for_attack()`（同一个阵营 **或**盟友）。
static func allied(a: String, b: String) -> bool:
	if a == "" or b == "" or a == b:
		return false
	return _ALLY.has(_pair_key(a, b))


## ★★ 攻击 / 索敌口径的「一边人」：**同一个阵营 或 盟友**。
##
## ★ 三处必须走它（改之前它们都是 `same_side`）：
##   · `combat.acquire_target` / `combat.nearest_enemy_building` —— 警戒索敌；
##   · `combat.update_towers` —— 箭塔开火（文件里本来就写着「一旦引入结盟/组队就会变成
##     箭塔打队友」，这一行就是那句话的落点，见 docs/pitfalls.md 3.7）；
##   · `unit.order_attack_unit` / `order_attack_building` 与 `command_processor`
##     —— 玩家**手动**点名时也不该能指挥盟友互相打。
##
## ⚠️ 与 `same_side` 的分工（别互换）：`same_side` 还负责**建筑通行 / 寻路**，
##    盟友之间照样互相挡路、互相挡箭塔本体（用户只要求「不互相攻击」，没要求拆墙）。
static func same_side_for_attack(a: String, b: String) -> bool:
	return a == b or _ALLY.has(_pair_key(a, b))


## ★★ 「同一方」的**代表阵营**（canonical id）—— 用于「敌我双方」这类计数。
##
## 用途只有一处：`logic/zone.gd` 的占领判定要问「区块里站着几方人」。
## 把盟友折叠成同一个代表之后，两个 AI 的兵站在同一块地上会被算成**一方**
## （不互相抵消读条），而且在盟友的地上不会被判成「外来者」。
##
## 代表怎么选：**字典序最小的那个 id** —— 与「谁先被发现」无关，只与名字有关，
## 所以同一局里跑一百帧、或者联机两端各算一次，结果都一样（可复现）。
## 没有盟友时返回它自己 ⇒ 行为与加这个功能之前**逐位一致**。
static func side_of(f: String) -> String:
	return _side_rep(f)


## 与 `f` 同方的所有阵营（含它自己）；顺序稳定（字典序）。
## 没有盟友时就是 `[f]` —— 调用方不必自己判「有没有结盟」。
static func side_members(f: String) -> Array:
	var out: Array = _collect_side(f)
	out.sort()
	return out


## 一对阵营的查表键。★ 两个名字**排序后**拼接：`allied(a,b)` 与 `allied(b,a)` 命中同一条，
## 所以登记时只要写一次、查询时也不用两个方向都试。
##
## ⚠️ 分隔符用 `|` 而不是 `\0`：阵营 id 是配置 / 地图里的普通字符串（字母数字），
##    而 `\0` 让这个键在调试输出与日志里都是不可见字符，排查时很难认。
static func _pair_key(a: String, b: String) -> String:
	if a < b:
		return "%s|%s" % [a, b]
	return "%s|%s" % [b, a]


## 同一方的代表：把这一方的人收全，取**字典序最小**的那个。
static func _side_rep(f: String) -> String:
	var members := _collect_side(f)
	if members.is_empty():
		return f
	members.sort()
	return String(members[0])


## 从 f 出发、沿盟友关系做一次连通搜索（一方里可能不止两个阵营）。
static func _collect_side(f: String) -> Array:
	var seen := {f: true}
	if f == "":
		return []
	var queue: Array = [f]
	var head := 0
	while head < queue.size():
		var cur := String(queue[head])
		head += 1
		for pr in _ALLY_PAIRS:
			var list: Array = pr as Array
			if list.size() != 2:
				continue
			var a := String(list[0])
			var b := String(list[1])
			var other := ""
			if a == cur:
				other = b
			elif b == cur:
				other = a
			else:
				continue
			if not seen.has(other):
				seen[other] = true
				queue.append(other)
	return seen.keys()


## 是不是某条名单里的玩家阵营
static func is_player_side(f: String) -> bool:
	return is_player_faction(f)


## 阵营显示名（事件日志用，如「己方」「敌方」）
static func faction_label(f: String) -> String:
	if f == DEFAULT_FACTION:
		return "己方"
	if f == NPC_FACTION:
		return "敌方"
	if is_player_faction(f):
		return "玩家%s" % f.substr(1)
	return f


## 阵营显示名（对局文案用，不预设「我」是谁，如「P1」「P2」「敌人」）
static func faction_name(f: String) -> String:
	if f == NPC_FACTION:
		return "敌人"
	if f == DEFAULT_FACTION:
		return "P1"
	if is_player_faction(f):
		return f.to_upper()
	return f


## ★ 这个阵营是不是「由 AI 接管」的？
##
## ★★ 与 `is_player_faction` 的分工（别混起来）：
##   · `is_player_faction` —— 决定「谁受玩家控制 / 谁自动索敌占区块 / 谁吃科技」；
##     它**不读配置**（联机名单与阵营表都是常量），所以它认不出 AI 阵营。
##   · 本函数 —— 决定「谁由 AI 驱动」；名单与行为参数来自 `config.ai.factions`。
##     所以它是**数据驱动**的，换一张图 / 改一次配置就能换一批 AI 阵营。
##   ⚠️ 逻辑层真正的判据是 `cfg.is_ai_faction()`（它才知道配置）；
##      这里这一份只作常量兜底 —— 两者判据必须一致（同一个 AI 阵营 id）。
static func is_ai_faction(f: String) -> bool:
	return AI_FACTION == f


## 单机模式（没有联机）下的阵营表
static func make_single_player_roster() -> Array[String]:
	return SINGLE_PLAYER_ROSTER.duplicate()
