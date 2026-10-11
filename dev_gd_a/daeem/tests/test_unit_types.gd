## test_unit_types.gd —— 单位类型（兵种）与「步兵 / 骑兵」标签，以及地图上的 2D 图标
##
## 需求原话（本轮）：
##   1. 「游戏中的单位和将领做出区分……分为两类，步兵和骑兵，这两个需要为相应的单位打上标签，
##       后续会根据这两个做额外伤害属性」；
##   2. 「弓箭手算作远程步兵，马弓手算作远程骑兵（但目前还没有专注于做这两个）」；
##   3. 「将『亲兵』这个单位去除，向游戏中加入『长枪兵』『长弓兵』『骑手』三个单位」；
##   4. 「为游戏中的这些单位绘制在地图上显示的 2D 图标（简单用线条绘制成预制体即可）」；
##   5. 「将领也暂时用这三个单位类型做出区分……同时将将领的描边变粗一点」。
##
## 这个文件盯四件事（队伍模型本身在 test_retinue.gd，别在这里重复）：
##   一、标签本身：每个类型是步兵还是骑兵、远不远、显示名对不对；
##   二、将领 ↔ 类型的对应：三个将领各一种、附属兵与它同类、数值完全按类型；
##   三、可招募的三个兵种都是「能招、能生成、类型正确」；
##   四、图标：每个类型烘得出一张图、将领那一档的描边**真的更粗**、未知类型有兜底。
##
## ⚠️ 最后一节要真的把 UnitView 挂进场景树（`_initialize()` 阶段 add_child 会静默失效），
##    所以这个文件走 test_minimap 那套 **async** 写法：自己打印汇总并 quit。
extends "res://tests/test_case.gd"

const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const UnitIconRes = preload("res://view/unit_icon.gd")
const SnapshotRes = preload("res://logic/snapshot.gd")

const DT := 1.0 / 60.0

## ★★ 本轮口径：开局附属兵**只来自关卡摆放**（`config.json` 的 `unit.general.escort`
## 全局缺省已删除）⇒ 「将领带几个同类型的兵」这条断言必须靠
## `require_world_with_escorts()` 造的探针关卡，而不是 config。见 test_case.gd。
const ESCORTS_PER_GENERAL := 3


func _initialize() -> void:
	_case_name = "test_unit_types"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	_test_class_tags(cfg)
	_test_general_types(cfg)
	_test_recruit_all_three(cfg)
	_test_icons(cfg)
	_test_icon_chars(cfg)
	cleanup_escort_scaffold()

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 一、标签：步兵 / 骑兵 + 远程
# ------------------------------------------------------------------
## ★★ 这一节是需求第 1、2 条的**判据**：标签必须落在单位身上（后面算额外伤害要用它），
##    而且「弓箭手 = 远程步兵」这种组合必须是**两个正交字段**拼出来的 ——
##    不然「马弓手 = 远程骑兵」就没地方放（需求明说以后要做）。
func _test_class_tags(cfg) -> void:
	# 三种兵的标签
	eq(cfg.unit_class_of(UnitRes.UNIT_TYPE_SPEARMAN), ConfigRes.CLASS_INFANTRY, "长枪兵属于步兵")
	eq(cfg.unit_class_of(UnitRes.UNIT_TYPE_LONGBOWMAN), ConfigRes.CLASS_INFANTRY, "长弓兵属于步兵")
	eq(cfg.unit_class_of(UnitRes.UNIT_TYPE_RIDER), ConfigRes.CLASS_CAVALRY, "骑手属于骑兵")
	ok(not cfg.unit_is_ranged(UnitRes.UNIT_TYPE_SPEARMAN), "长枪兵是近战")
	ok(cfg.unit_is_ranged(UnitRes.UNIT_TYPE_LONGBOWMAN), "★ 长弓兵是远程（需求：弓箭手算作远程步兵）")
	ok(not cfg.unit_is_ranged(UnitRes.UNIT_TYPE_RIDER), "骑手是近战骑兵")

	# 显示名：不带远近 / 带远近两套（HUD 用的是后者）
	eq(cfg.unit_class_name(UnitRes.UNIT_TYPE_RIDER), "骑兵", "大类显示名 = 骑兵")
	eq(cfg.unit_class_line(UnitRes.UNIT_TYPE_SPEARMAN), "步兵", "近战步兵的标签就是「步兵」")
	eq(cfg.unit_class_line(UnitRes.UNIT_TYPE_LONGBOWMAN), "远程步兵", "★ 长弓兵的标签 = 远程步兵")
	eq(cfg.unit_class_line(UnitRes.UNIT_TYPE_RIDER), "骑兵", "骑手的标签 = 骑兵")

	# ★ 两个维度是正交的：骑兵那一档也备着「远程骑兵」这个名字 ——
	#   将来的马弓手（骑兵 + ranged）直接就能显示出来，代码一行不用改。
	eq(String(cfg.get_path_value("unit.classes.cavalry.ranged_name")), "远程骑兵",
		"★ 骑兵那一档也备着「远程骑兵」（马弓手的标签有地方放）")
	eq(String(cfg.get_path_value("unit.classes.infantry.ranged_name")), "远程步兵",
		"步兵那一档备着「远程步兵」")

	# 每个类型都必须有完整的标签字段（漏一个就会在渲染 / 伤害判定里退化成默认值）
	for id in cfg.unit_type_ids():
		var t := String(id)
		var entry: Dictionary = cfg.unit_type_entry(t)
		ok(entry.has("class") and String(entry["class"]) != "", "%s 有兵种大类" % t)
		ok(typeof(entry.get("ranged")) == TYPE_BOOL, "%s 的 ranged 是布尔量" % t)
		ok(cfg.unit_class_name(t) != "", "%s 的大类有显示名" % t)
		ok(String(entry.get("name", "")) != "", "%s 有显示名" % t)

	# ★★ 本次：「测试敌人」（enemy）已从 unit.types 删除（用户口径：「把所有的『敌』
	#   这个具体单位变成『长枪兵』，同时将『敌』从 editor 工具中移除」）。
	#   这一条**反着钉**：谁把那个类型加回来，这里立刻变红。
	ok(not cfg.has_unit_type("enemy"),
		"★★ unit.types 里不再有「测试敌人」（已并入长枪兵）")

	# 未知类型退回兜底（而不是崩、也不是悄悄变成敌人）
	eq(cfg.unit_class_of("no_such_type"), ConfigRes.CLASS_INFANTRY, "未知类型的大类是步兵（兜底）")
	ok(not cfg.unit_is_ranged("no_such_type"), "未知类型当成近战（兜底）")
	near(cfg.unit_hp_of("no_such_type"), cfg.unit_hp_max, 1e-6, "未知类型退回兜底血量")
	ok(cfg.unit_name_of("no_such_type") != "", "未知类型也有个显示名（不返回空串）")


# ------------------------------------------------------------------
# 二、将领 ↔ 类型
# ------------------------------------------------------------------
func _test_general_types(cfg) -> void:
	var w = require_world_with_escorts(cfg, ESCORTS_PER_GENERAL)
	# ★ 这一节只读逻辑字段（类型 / 数值 / 队伍），**不看屏幕位置** ——
	#   所以不需要任何投影初始化。
	#
	# ⚠️ 这里本来有一行 `setup_projection(cfg, w.map.cols, w.map.rows)`：
	#    它是 2D 仿射投影时代测试脚手架的辅助函数（把视口尺寸与
	#    `proj_offset` 一起喂给 cfg）。3D 版之后投影由**真实的 Camera3D**
	#    决定（`view/palette.gd` 的实例 API），脚手架的 `setup_projection`
	#    已经删除，于是这一行变成 "Function not found" 的 **Parse Error**
	#    —— 整个文件都载不进来（37 个文件一起红的那个坑）。
	#    它在这里本来就**没有任何断言依赖**（这个用例一个字都没算屏幕坐标），
	#    所以直接删掉；真要看位置请像 test_view 那样用
	#    `make_test_camera()` + `make_test_palette()`。
	var types: Array = cfg.general_types()
	eq(types.size(), 3, "配置里给了三个将领类型")

	var expect: Array = [UnitRes.UNIT_TYPE_SPEARMAN, UnitRes.UNIT_TYPE_LONGBOWMAN, UnitRes.UNIT_TYPE_RIDER]
	eq(types, expect, "★ 三个将领依次是长枪兵 / 长弓兵 / 骑手")

	for i in 3:
		var g = w.unit_by_id("general-%d" % (i + 1))
		ok(g != null, "有 general-%d" % (i + 1))
		if g == null:
			continue
		var want := String(types[i])
		eq(g.kind, UnitRes.KIND_GENERAL, "将领的 kind 仍是 general（队伍 / 招募都按它判）")
		eq(String(g.unit_type), want, "★ general-%d 的类型是 %s" % [i + 1, want])
		ok(g.is_general(), "★ is_general() 为真（描边加粗与将领科技共用这条判据）")
		# 数值完全等于所属类型那一套（用户确认的口径）
		near(g.hp_max, cfg.unit_hp_of(want), 1e-6, "将领血量 = 类型血量")
		near(g.combat_damage(cfg), float(cfg.unit_combat_of(want)["damage"]), 1e-6, "将领伤害 = 类型伤害")
		near(g.combat_range(cfg), float(cfg.unit_combat_of(want)["range"]), 1e-6, "将领射程 = 类型射程")
		near(g.combat_cooldown(cfg), float(cfg.unit_combat_of(want)["cooldown_sec"]), 1e-6,
			"将领间隔 = 类型间隔")
		# 兵种标签也挂在将领身上（将领同样要能算「按兵种额外伤害」）
		eq(g.unit_class, cfg.unit_class_of(want), "将领的兵种大类")
		eq(g.ranged, cfg.unit_is_ranged(want), "将领的远近标记")

	# 附属兵与队长同一类型（需求：「将领带一批同类型的兵」）
	# ★★ 「几位」现在的来源是**关卡摆放**（本轮把 `unit.general.escort` 全局缺省删掉了）：
	#    这个探针给每位将领摆了 `ESCORTS_PER_GENERAL` 个，所以每个人都是这个数。
	for i in 3:
		var g2 = w.unit_by_id("general-%d" % (i + 1))
		var want_n: int = ESCORTS_PER_GENERAL
		var ret = w.retinue_of(g2.id)
		eq(ret.size(), want_n, "general-%d 带 %d 个附属兵（关卡摆的）" % [i + 1, want_n])
		for s in ret:
			eq(String(s.unit_type), String(g2.unit_type), "★ 附属兵与将领同类型")
			eq(s.kind, String(g2.unit_type), "附属兵的 kind 就是它的类型")
			ok(not s.is_general(), "附属兵不是将领")

	# 长弓兵将领真的是远程：射程 > 1 格（这是「按类型区分」最直观的一条）
	var g2b = w.unit_by_id("general-2")
	ok(g2b.combat_range(cfg) > 1.0, "★ 长弓兵将领是远程（射程 %.1f 格）" % g2b.combat_range(cfg))
	# 骑手将领真的更快（比的是 config 里的类型速度：森林减速是另一回事）
	ok(cfg.unit_speed_of(UnitRes.UNIT_TYPE_RIDER) > cfg.unit_speed_of(UnitRes.UNIT_TYPE_SPEARMAN),
		"★ 骑手比长枪兵快（%.2f > %.2f）" % [
			cfg.unit_speed_of(UnitRes.UNIT_TYPE_RIDER), cfg.unit_speed_of(UnitRes.UNIT_TYPE_SPEARMAN)])
	var g3 = w.unit_by_id("general-3")
	eq(String(g3.unit_type), UnitRes.UNIT_TYPE_RIDER, "★ general-3 是骑手（所以它跑得比将领 1 快）")

	# 区划招募出来的 general_N 也按同一张类型表
	for i in 3:
		eq(cfg.unit_type_of("general_%d" % (i + 1)), String(types[i]),
			"general_%d 的类型与第 %d 个开局将领一致" % [i + 1, i + 1])


# ------------------------------------------------------------------
# 三、三个可招募兵种
# ------------------------------------------------------------------
func _test_recruit_all_three(cfg) -> void:
	cfg.combat_enabled = false
	var w = require_world(cfg)
	# 只留己方单位（地图上的巡逻兵会来搅局）
	var kept: Array = []
	for u in w.units:
		if u.faction == w.my_faction:
			kept.append(u)
	w.units = kept

	var g1 = w.unit_by_id("general-1")
	w.resources["food"] = 5000.0
	w.resources["gold"] = 5000.0
	w.zones.zone_at(g1.tx, g1.ty)["population"] = 100.0

	var types: Array = cfg.general_types()
	eq(types.size(), 3, "三个可招募兵种")
	for t in types:
		var tt := String(t)
		ok(w.is_recruitable(tt), "★ %s 在 config.recruit.list 里" % tt)
		ok(w.recruit_short_of(tt) != "", "%s 有短名（信息栏格子要写）" % tt)
		ok(w.recruit_label_of(tt) != tt, "%s 有显示名" % tt)
		ok(w.recruit_train_sec(tt) > 0.0, "%s 有读条时间" % tt)

	# 依次把三个兵种排进同一个将领的队列（一单 10 秒，三单串行）
	var before: int = w.retinue_of(g1.id).size()
	for t2 in types:
		ok(w.start_recruit(String(t2), g1.id, "p1"), "排 %s 进队列" % t2)
	for _i in int(ceil(32.0 / DT)):
		w.tick(DT)
	eq(w.retinue_of(g1.id).size(), before + 3, "★ 三单都读完了（名下多 3 个）")

	# 三单生成出来的类型 = 三个兵种（顺序就是入队顺序）
	var got: Array = []
	var all_ret: Array = w.retinue_of(g1.id)
	for i in range(all_ret.size() - 3, all_ret.size()):
		got.append(String(all_ret[i].unit_type))
	eq(got, [String(types[0]), String(types[1]), String(types[2])],
		"★ 招出来的三个单位类型就是三个兵种（一个不多一个不少）")

	# 招出来的兵**挂在将领名下**（队伍模型不变），而且数值走自己那一档
	var fresh = all_ret[all_ret.size() - 1]
	eq(fresh.leader_id, g1.id, "新兵挂在招它的将领名下")
	near(fresh.hp_max, cfg.unit_hp_of(String(fresh.unit_type)), 1e-6, "新兵血量走自己的类型")
	ok(fresh.alive and w.map.terrain_walkable(fresh.tx, fresh.ty), "新兵站在可通行格上")
	cfg.combat_enabled = true


# ------------------------------------------------------------------
# 四、地图上的 2D 图标 = **阵营色圆盘底 + 一个字**
# ------------------------------------------------------------------
## ★★ 这一节不验「好不好看」（那是手玩的事），只验五件会**静默出错**的事：
##    1. 每个单位在地图上都有**正好一个字**可画（漏一个 → 那个兵在地图上是个空白）；
##    2. 不同兵种的字**不一样**（否则三种兵长得一样，图标就白设了）；
##    3. 圆盘底烘得出来、且**将领那一档的描边真的更粗**（用深色像素数**量**出来，
##       不是只看常量 —— 常量对但没画进去是最容易发生的那种错）；
##    4. 字的字号能跟着半径走且装得进圆盘（需求是「圆盘底 + 字」，字不能比盘还大）；
##    5. 未知类型有兜底（老快照 / 手写地图里的怪 kind 不能把渲染搞崩）。
func _test_icons(cfg) -> void:
	ok(UnitIconRes.EXTENT > UnitIconRes.DISC_R, "贴图半宽装得下圆盘")
	ok(UnitIconRes.EXTENT >= UnitIconRes.DISC_R + UnitIconRes.OUTLINE_W_LEADER,
		"★ 最粗的那一圈描边也不会被贴图边缘切掉（%.2f + %.2f <= %.2f）"
			% [UnitIconRes.DISC_R, UnitIconRes.OUTLINE_W_LEADER, UnitIconRes.EXTENT])
	ok(UnitIconRes.OUTLINE_W_LEADER > UnitIconRes.OUTLINE_W,
		"★ 将领那一档的描边**常量**更粗（%.2f > %.2f）"
			% [UnitIconRes.OUTLINE_W_LEADER, UnitIconRes.OUTLINE_W])
	ok(UnitIconRes.OUTLINE_W > 0.0, "★ 普通单位也有描边（圆盘要有边，不然在浅色地形上看不清）")
	ok(UnitIconRes.outline_w(true) > UnitIconRes.outline_w(false), "outline_w() 与常量一致")

	# ---- 圆盘底：两张贴图，烘得出来、且将领那张的深色圈更宽 ----
	var troop_tex: ImageTexture = UnitIconRes.bake(false)
	var leader_tex: ImageTexture = UnitIconRes.bake(true)
	ok(troop_tex != null and leader_tex != null, "普通 / 将领两张圆盘都烘得出来")
	if troop_tex != null and leader_tex != null:
		ok(troop_tex != leader_tex, "★ 将领的圆盘与普通单位**不是同一张**")
		var troop_img := troop_tex.get_image()
		var leader_img := leader_tex.get_image()
		ok(_count_pixels(troop_img, true) > 0, "圆盘底真的画了东西（不透明像素 %d）"
			% _count_pixels(troop_img, true))
		var dark_troop := _count_pixels(troop_img, false)
		var dark_leader := _count_pixels(leader_img, false)
		ok(dark_leader > dark_troop,
			"★★ 将领那圈的深色像素**明显更多**（%d > %d）—— 描边真的画粗了"
				% [dark_leader, dark_troop])
		# 圆盘是**白**的（运行时被阵营色乘），不是已经染好色的
		var center := troop_img.get_pixel(troop_img.get_width() / 2, troop_img.get_height() / 2)
		ok(center.a > 0.9 and center.r > 0.9 and center.g > 0.9 and center.b > 0.9,
			"★ 圆盘中心是**白色**（阵营色是运行时 modulate 上去的）")
	eq(UnitIconRes.bake(false), troop_tex, "同一档圆盘走缓存（同一个对象）")

	# ---- 那个字：每个类型一个字，互不相同（本次只剩三个兵种）----
	var distinct: Dictionary = {}
	for id in [UnitRes.UNIT_TYPE_SPEARMAN, UnitRes.UNIT_TYPE_LONGBOWMAN,
			UnitRes.UNIT_TYPE_RIDER]:
		var t := String(id)
		# ⚠️ `cfg` 是无类型的（测试脚手架里 require_config() 返回 Variant），
		#    所以这里不能写 `:=` —— 推断不出来会直接 Parse Error。
		var ch: String = cfg.unit_icon_of(t)
		eq(ch.length(), 1, "%s 的地图图标**正好一个字**（实际 %r）" % [t, ch])
		ok(ch != "?" and ch != "", "%s 的字不是兜底占位（%r）" % [t, ch])
		distinct[ch] = true
	eq(distinct.size(), 3, "★ 三个兵种各是一个不同的字")

	# 字是**数据**：改 config 里的 icon → 游戏读到的字跟着变（编辑器改的就是这个键）
	eq(cfg.unit_icon_of(UnitRes.UNIT_TYPE_SPEARMAN), "枪", "长枪兵的字来自 config（枪）")
	eq(cfg.unit_icon_of(UnitRes.UNIT_TYPE_LONGBOWMAN), "弓", "长弓兵（弓）")
	eq(cfg.unit_icon_of(UnitRes.UNIT_TYPE_RIDER), "骑", "骑手（骑）")

	# 将领（kind = general / general_N）用的是**所属兵种**那个字
	eq(cfg.unit_icon_of("general"), cfg.unit_icon_of(UnitRes.UNIT_TYPE_SPEARMAN),
		"★ 将领 1 画长枪兵那个字")
	eq(cfg.unit_icon_of("general_3"), cfg.unit_icon_of(UnitRes.UNIT_TYPE_RIDER),
		"★ basic general_3（区划招募的骑手将领）也画骑手那个字")

	# 没写 icon → 退成**名字的第一个字**；名字也没有 → "?"
	var cfg2 = require_config()
	cfg2.data["unit"]["types"]["spearman"].erase("icon")
	var cfg3 = _reload_cfg(cfg2)
	eq(cfg3.unit_icon_of(UnitRes.UNIT_TYPE_SPEARMAN), "长",
		"★ 没写 icon → 用名字的第一个字（长枪兵 → 长）")
	cfg3.data["unit"]["types"]["ghost"] = {"name": "", "class": "infantry"}
	eq(_reload_cfg(cfg3).unit_icon_of("ghost"), "?",
		"★ 名字也是空的 → 兜底成 ? （不崩、不留空白）")
	# 表里**根本没有**这个类型 → 走 unit_name_of 的兜底名「单位」→ 第一个字「单」
	eq(cfg3.unit_icon_of("no_such_type"), "单",
		"★ 认不出来的类型用兜底名「单位」的第一个字（总有字可画）")

	# 手改配置写了两个字：只画第一个（防御性，不让它变成两个字挤在一起）
	var cfg4 = require_config()
	cfg4.data["unit"]["types"]["rider"]["icon"] = "骑手"
	eq(_reload_cfg(cfg4).unit_icon_of(UnitRes.UNIT_TYPE_RIDER), "骑",
		"★ 手改写了两个字也只取第一个")

	# 字号：半径越大字越大，有下限，而且**装得进圆盘**（需求是「圆盘底 + 字」）
	ok(UnitIconRes.font_size_for(13.44) > UnitIconRes.font_size_for(8.0), "半径越大字号越大")
	ok(UnitIconRes.font_size_for(0.0) >= UnitIconRes.MIN_FONT_SIZE, "字号有下限（不缩成 0）")
	for radius_px in [8.0, 11.52, 13.44, 20.0]:
		var fsize: float = float(UnitIconRes.font_size_for(radius_px))
		var disc_d: float = 2.0 * UnitIconRes.DISC_R * radius_px
		ok(fsize <= disc_d,
			"★ 半径 %.1fpx 时字号 %.0f 装得进圆盘（盘直径 %.1fpx）" % [radius_px, fsize, disc_d])


## 数一张图里「不透明」或「深色」的像素。
## @param opaque true = 数 alpha 明显的；false = 数又深又不透明的（= 圆盘那一圈描边）
func _count_pixels(img: Image, opaque: bool) -> int:
	if img == null:
		return 0
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a < 0.05:
				continue
			if opaque:
				n += 1
			elif c.r < 0.5 and c.g < 0.5 and c.b < 0.5:
				n += 1
	return n


## 改完 config 的 data 之后要重新整理一遍缓存才看得到（与「编辑器改完文件再开一局」同理）
func _reload_cfg(src) -> RefCounted:
	var cfg = ConfigRes.new()
	cfg.data = src.data
	cfg._cache_scalars()
	return cfg


# ------------------------------------------------------------------
# 五、图标字：真的按类型取到了那个字（渲染层接线）
# ------------------------------------------------------------------
## ★ 只验「接线」：单位类型 → 那个字，取得到、且随类型走 ——
##   至于画出来什么样，是手玩验收的事（与 test_view.gd 的分工一致）。
##
## ★★ 这一节原来还钉了 2D `unit_view.gd` 的**分桶 / `_draw()` 计数**（圆盘张数、字数）——
##   那些 API（`_bucket_by_size` / `_bucket_by_tex` / `icon_disc_count` / `icon_draw_count`）
##   已随 2D 栈删除。3D 版的等价覆盖是 `tests/test_view3d.gd` 的
##   `instance_count`（实例数 = 可见单位数）与 `mesh_batch_count`（批次数）。
func _test_icon_chars(cfg) -> void:
	# ★ 要有**附属兵**才能拿一个普通单位当样本（本轮：附属兵来自关卡摆放）
	var w = require_world_with_escorts(cfg, ESCORTS_PER_GENERAL)
	var g1 = w.unit_by_id("general-1")
	var g3 = w.unit_by_id("general-3")      # 骑手将领
	ok(g1 != null and g3 != null, "有长枪兵将领 general-1 与骑手将领 general-3")
	if g1 != null and g3 != null:
		eq(UnitIconRes.char_of(cfg, String(g3.unit_type)), "骑", "★ general-3 画的是「骑」")
		eq(UnitIconRes.char_of(cfg, String(g1.unit_type)), "枪", "★ general-1 画的是「枪」")

	# 快照往返之后，类型仍然对（客机画图标靠它）
	var snap = SnapshotRes.to_snapshot(w)
	var w2 = require_world(cfg)
	SnapshotRes.apply_snapshot(w2, cfg, snap)
	var remote3 = w2.unit_by_id("general-3")
	ok(remote3 != null, "快照重建出了 general-3")
	if remote3 != null:
		eq(String(remote3.unit_type), UnitRes.UNIT_TYPE_RIDER, "★ 快照往返后骑手将领还是骑手")
		eq(remote3.unit_class, ConfigRes.CLASS_CAVALRY, "客机侧的兵种大类也对")
