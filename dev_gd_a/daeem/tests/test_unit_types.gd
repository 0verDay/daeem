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
const UnitViewRes = preload("res://view/unit_view.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")
const SnapshotRes = preload("res://logic/snapshot.gd")

const DT := 1.0 / 60.0


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
	# ★ 关键：先等一帧，root.add_child() 才会真的生效（见 pitfalls 1.2）
	await process_frame
	await _test_view_uses_icons(cfg)

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

	# 测试敌人也在表里（老代码把它拆在 debug / combat 三处，本轮并进来）
	ok(cfg.has_unit_type(UnitRes.KIND_ENEMY), "测试敌人也是表里的一个类型")
	near(cfg.unit_hp_of(UnitRes.KIND_ENEMY), cfg.enemy_hp, 1e-6, "测试敌人的血量与老字段同源")

	# 未知类型退回兜底（而不是崩、也不是悄悄变成敌人）
	eq(cfg.unit_class_of("no_such_type"), ConfigRes.CLASS_INFANTRY, "未知类型的大类是步兵（兜底）")
	ok(not cfg.unit_is_ranged("no_such_type"), "未知类型当成近战（兜底）")
	near(cfg.unit_hp_of("no_such_type"), cfg.unit_hp_max, 1e-6, "未知类型退回兜底血量")
	ok(cfg.unit_name_of("no_such_type") != "", "未知类型也有个显示名（不返回空串）")


# ------------------------------------------------------------------
# 二、将领 ↔ 类型
# ------------------------------------------------------------------
func _test_general_types(cfg) -> void:
	var w = require_world(cfg)
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
	for i in 3:
		var g2 = w.unit_by_id("general-%d" % (i + 1))
		var ret = w.retinue_of(g2.id)
		eq(ret.size(), cfg.general_escort_count(),
			"general-%d 带 %d 个附属兵" % [i + 1, cfg.general_escort_count()])
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

	# ---- 那个字：每个类型一个字，互不相同 ----
	var distinct: Dictionary = {}
	for id in [UnitRes.UNIT_TYPE_SPEARMAN, UnitRes.UNIT_TYPE_LONGBOWMAN,
			UnitRes.UNIT_TYPE_RIDER, UnitRes.KIND_ENEMY]:
		var t := String(id)
		# ⚠️ `cfg` 是无类型的（测试脚手架里 require_config() 返回 Variant），
		#    所以这里不能写 `:=` —— 推断不出来会直接 Parse Error。
		var ch: String = cfg.unit_icon_of(t)
		eq(ch.length(), 1, "%s 的地图图标**正好一个字**（实际 %r）" % [t, ch])
		ok(ch != "?" and ch != "", "%s 的字不是兜底占位（%r）" % [t, ch])
		distinct[ch] = true
	eq(distinct.size(), 4, "★ 四个类型各是一个不同的字")

	# 字是**数据**：改 config 里的 icon → 游戏读到的字跟着变（编辑器改的就是这个键）
	eq(cfg.unit_icon_of(UnitRes.UNIT_TYPE_SPEARMAN), "枪", "长枪兵的字来自 config（枪）")
	eq(cfg.unit_icon_of(UnitRes.UNIT_TYPE_LONGBOWMAN), "弓", "长弓兵（弓）")
	eq(cfg.unit_icon_of(UnitRes.UNIT_TYPE_RIDER), "骑", "骑手（骑）")
	eq(cfg.unit_icon_of(UnitRes.KIND_ENEMY), "敌", "测试敌人（敌）")

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
# 五、渲染真的把这个字画了出去
# ------------------------------------------------------------------
## ★ 只验「接线」：UnitView 在这些类型上跑得通、字确实随类型走 ——
##   至于画出来什么样，是手玩验收的事（与 test_view.gd 的分工一致）。
func _test_view_uses_icons(cfg) -> void:
	var w = require_world(cfg)
	var view = UnitViewRes.new()
	# ★ 用**真字体**建 view：无头下引擎兜底字体没有中文字形，但断言只看「画了几笔」，
	#   所以两者都能过；这里传真字体是为了走与游戏完全一致的那条路。
	view.setup(cfg, w, FontLoaderRes.load_font(cfg))
	root.add_child(view)
	await process_frame

	view._draw()                     # 真跑一遍：字取不到 / 字段拼错都会在这里炸
	ok(true, "UnitView._draw() 跑通了")

	# ★★ 回归（上一轮真踩过）：**图标那两遍到底画了没有**。
	#    症状是「所有单位在地图上只剩一根朝向线」—— 不报错、也不改任何状态，
	#    根因是分桶用了值语义的 `PackedInt32Array`（`(bucket as PackedInt32Array).append()`
	#    写不进字典），于是每个桶都是空的、一次绘制都没发出去。
	#    所以这里既钉**两个分桶函数**（纯函数），也钉**_draw 真的画了几个圆盘 / 几个字**。
	var probe := PackedFloat32Array([12.0, 12.0, 9.0, 15.0, 12.0])
	var buckets: Dictionary = UnitViewRes._bucket_by_size(probe, probe.size())
	eq(buckets.size(), 3, "★ 同一字号的合成一个桶（12/12/9/15/12 → 12、9、15 三桶）")
	var total := 0
	var all_arrays := true
	for k in buckets.keys():
		if not (buckets[k] is Array):
			all_arrays = false
		total += (buckets[k] as Array).size()
	ok(all_arrays, "★ 桶是 Array（引用语义）—— 换成 PackedInt32Array 会静默变成空桶")
	eq(total, probe.size(), "★ 5 个单位一个不漏地分进桶里（空桶 = 地图上一个字都看不到）")

	var tex_a: ImageTexture = UnitIconRes.bake(false)
	var tex_b: ImageTexture = UnitIconRes.bake(true)
	var tex_buckets: Dictionary = UnitViewRes._bucket_by_tex([tex_a, tex_a, tex_b, tex_b, tex_a], 5)
	eq(tex_buckets.size(), 2, "★ 圆盘按贴图分桶：普通 / 将领两桶")
	eq((tex_buckets[tex_a] as Array).size(), 3, "普通那一桶 3 个")
	eq((tex_buckets[tex_b] as Array).size(), 2, "将领那一桶 2 个")

	# 先挑一个**普通兵**（附属兵）出来备用：它要用来验「普通兵用普通那张圆盘」
	var plain = null
	for u in w.units:
		if not u.is_general() and String(u.unit_type) == UnitRes.UNIT_TYPE_SPEARMAN:
			plain = u
			break
	ok(plain != null, "队里有一个长枪兵附属兵（拿它当普通单位的样本）")

	# 让世界只剩两个**挪到镜头里**的单位：骑手将领 + 长枪兵将领
	var g1 = w.unit_by_id("general-1")
	var g3 = w.unit_by_id("general-3")      # 骑手将领
	ok(g1 != null and g3 != null, "有长枪兵将领 general-1 与骑手将领 general-3")
	if g1 != null and g3 != null:
		g1.pos = Vector2(3.5, 3.5)
		g1.sync_tile(w.map)
		g3.pos = Vector2(5.5, 3.5)
		g3.sync_tile(w.map)
		w.units = [g1, g3]
		view._draw()
		eq(view.icon_disc_count, 2, "★ _draw() 真的把这两个单位的**圆盘底**画了出去（实际 %d 张）"
			% view.icon_disc_count)
		eq(view.icon_draw_count, 2, "★ 同时把两个字也画了出去（实际 %d 个）"
			% view.icon_draw_count)
		eq(UnitIconRes.char_of(cfg, String(g3.unit_type)), "骑", "★ general-3 画的是「骑」")
		eq(UnitIconRes.char_of(cfg, String(g1.unit_type)), "枪", "★ general-1 画的是「枪」")

		# 普通兵：同一个字、同一套画法，只是**圆盘那张贴图不同**（描边细）
		if plain != null:
			plain.pos = Vector2(7.5, 3.5)
			plain.sync_tile(w.map)
			w.units = [g1, plain]
			view._draw()
			eq(view.icon_disc_count, 2, "将领 + 普通兵：两个圆盘都画了")
			eq(view.icon_draw_count, 2, "将领 + 普通兵：两个字都画了")
			eq(UnitIconRes.char_of(cfg, String(plain.unit_type)), "枪",
				"★ 附属兵与它的将领画同一个字（靠圆盘描边区分）")
		# ⚠️ 还原成原来那两个单位：下面那一节要拿 w 做快照往返，
		#    少一个单位会让「快照重建出了 general-3」假失败（实测踩到）。
		w.units = [g1, g3]

	view.queue_free()

	# 快照往返之后，类型仍然对（客机画图标靠它）
	var snap = SnapshotRes.to_snapshot(w)
	var w2 = require_world(cfg)
	SnapshotRes.apply_snapshot(w2, cfg, snap)
	var remote3 = w2.unit_by_id("general-3")
	ok(remote3 != null, "快照重建出了 general-3")
	if remote3 != null:
		eq(String(remote3.unit_type), UnitRes.UNIT_TYPE_RIDER, "★ 快照往返后骑手将领还是骑手")
		eq(remote3.unit_class, ConfigRes.CLASS_CAVALRY, "客机侧的兵种大类也对")
