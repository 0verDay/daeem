## test_unit_card_icon.gd —— 命令卡「单位」页那九格里的**单位图标（金线线稿）**
##
## 需求原话（最新一轮）：「把图标改为 preview_etch 那种样子……**完全用金线**代替，
## 不要有断裂的像素；有的单位没显示出来，需要相应地移动取样点的位置」。
##
## 这套用例守五件事：
##   1. **覆盖**：`unit.types` 里每一个兵种都能拿到一张蒙版（`icon_mask`）；
##      拿不到时必须能退回矢量图形，不能出现「没图」的格子。
##   2. **资产**：`assets/ui/card_icon/` 里那批蒙版确实烘过、尺寸正确、
##      覆盖率在合理区间（空图 / 糊成一整块都会红）。★ 缺 `.import` 时
##      `ResourceLoader.exists()` 为 false，运行时会**静默退回矢量图** —— 这条是看门狗。
##   3. **几何**：矢量兜底的点都落在 0..1 内（偏出去会被 `draw_polyline` 画到格子外，
##      而那是**画得出来但不报错**的那类 bug）；每条折线至少两个点。
##   4. **出口**：`draw_into()` / `outline_count()` 真的发得出东西 —— 无头测试里
##      `_draw()` 内部出错不会让用例变红，只能靠这个可数的痕迹钉住
##      （与 view/unit_icon.gd 的 `draw_char_at` 同一条口径）。
##   5. **接线**：`command_card` 收到带 `icon_mask`（或只有 `icon_role`）的条目 ⇒
##      画图标、把名字那行**藏起来**；两个键都没有的页面（操作 / 建筑 / 科技）⇒
##      照旧只有字。★ 两件事分开断言：`cell_label()` 仍然读得到名字
##      （隐藏文字不该把语义出口一起弄没）。
extends "res://tests/test_case.gd"

const IconRes = preload("res://view/unit_card_icon.gd")
const CommandCardRes = preload("res://view/command_card.gd")
const UiLayoutRes = preload("res://view/ui_layout.gd")
const ThemeRes = preload("res://view/theme.gd")

## config 里的九种图形（少一种就说明 `paths()` 漏了一档）。
const ROLES := [
	IconRes.ROLE_SPEAR, IconRes.ROLE_BOW, IconRes.ROLE_SWORD_SHIELD,
	IconRes.ROLE_HORSE, IconRes.ROLE_HORSE_BOW, IconRes.ROLE_CART,
	IconRes.ROLE_CATAPULT, IconRes.ROLE_BALLISTA, IconRes.ROLE_CHARIOT,
]

## `assets/ui/card_icon/` 里应有的蒙版数 = config 里**唯一原画**的张数。
## ★ 加了新原画要重跑 `tools/bake_unit_card_icon.py --commit` 并把这里 +1
##   （数字对不上就说明「加了兵种但忘了烘」，那正是本用例要拦的）。
const MASK_COUNT := 15
## 覆盖率区间（%）：低于 = 空图 / 阈值抽狠了，高于 = 糊成了一整块。
const COVERAGE_MIN := 2.0
const COVERAGE_MAX := 60.0
## **金线稿**档的两个判据（`--style etch` 的产物）：
##   · RGB 恒定（纯白）—— 颜色全部交给运行时的主题金，蒙版本身不带明暗；
##   · 覆盖率落在「细线」区间（实测 15 张都在 16~25%）。
## ★ 与 `relief` / `flat`（RGB 有明暗层次）用一个「或」区分开：
##   两种产物理应都过，但**各有各的合理形态**，不能只认其中一种。
const LINE_RGB_SPAN := 0.02
const LINE_COVERAGE_MAX := 35.0

## 建筑图标的张数 = 可建造的建筑类型数（`view/building_view_3d.gd` 的 BUILDING_MODELS 去掉
## zone_center）。加建筑要重跑烘焙并把这里 +1。
const BUILDING_MASK_COUNT := 8
## 科技图标的张数 = 原生 9 条 + 王朝/帝国 13 条。
const TECH_MASK_COUNT := 22


func _initialize() -> void:
	_case_name = "test_unit_card_icon"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	IconRes.clear_mask_cache()
	_test_masks(cfg)
	_test_building_and_tech_masks(cfg)
	_test_roles(cfg)
	_test_geometry()
	_test_draw()
	_test_ink()
	_test_card_wiring(cfg)
	run_all(_noop)


func _noop() -> void:
	pass


## ② 建筑 / 科技的图标：这两批**不是**从兵种原画来的 ——
##   建筑是烘图脚本从 `.glb` 抽边线画出来的等轴测线稿，科技是按下名字画的占位图形。
##   所以它们各自有自己的一张表，按 id 逐条点名（缺一张就红）。
##   ★ 建筑的类型表在 `view/building_view_3d.gd` 的 BUILDING_MODELS；这里只列**可建造**
##     的那 8 种（zone_center 不进建筑页，烘焙脚本也跳过它）。
func _test_building_and_tech_masks(cfg) -> void:
	var buildings := ["wall", "tower", "farm", "stone_wall", "watch_tower", "house", "mine"]
	for b in buildings:
		var p := IconRes.mask_for_building(String(b))
		ok(p != "", "★ 建筑 %s 有图标蒙版（%s）" % [b, p])
		ok(p == "" or ResourceLoader.exists(p), "★ %s 的建筑蒙版真的导入过" % b)
	eq(IconRes.mask_for_building(""), "", "空建筑类型没有蒙版")
	eq(IconRes.mask_for_building("no_such_building"), "",
		"未知建筑类型没有蒙版（新增建筑不会静默画错图）")

	var tech_ids := []
	for item in cfg.tech_list():
		tech_ids.append(String((item as Dictionary).get("id", "")))
	# 派系科技：`tech.clan_list` 里那 13 条（王朝 6 / 帝国 7），它们在
	# `cfg.tech_list_for(clan)` 的九格里出现，但 `tech_list()` 拿不到 —— 单独点名几条。
	for t in ["dy_liyue", "dy_grace", "dg_chivalry", "dg_breakthrough"]:
		if not tech_ids.has(t):
			tech_ids.append(t)
	for t in tech_ids:
		var p2 := IconRes.mask_for_tech(String(t))
		ok(p2 != "", "★ 科技 %s 有图标蒙版（%s）" % [t, p2])
		ok(p2 == "" or ResourceLoader.exists(p2), "★ %s 的科技蒙版真的导入过" % t)
	# 全部科技的图标张数 = 原生 9 + 王朝/帝国 13（少了说明「加了科技忘了重烘」）
	eq(_count_files("res://assets/ui/card_icon/", "tech_"), TECH_MASK_COUNT,
		"★ 科技图标张数 = %d（原生 9 + 派系 13）" % TECH_MASK_COUNT)
	eq(_count_files("res://assets/ui/card_icon/", "building_"), BUILDING_MASK_COUNT,
		"★ 建筑图标张数 = %d（可建造的那些）" % BUILDING_MASK_COUNT)
	eq(IconRes.mask_for_tech(""), "", "空科技 id 没有蒙版")
	eq(IconRes.mask_for_tech("no_such_tech"), "",
		"未知科技 id 没有蒙版（新增科技不会静默画错图）")


## `assets/ui/card_icon/` 里以 `prefix` 开头的 png 张数（`.import` 不算）。
func _count_files(dir_path: String, prefix: String) -> int:
	var n := 0
	var d := DirAccess.open(dir_path)
	if d == null:
		return -1
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not d.current_is_dir() and f.begins_with(prefix) and f.ends_with(".png"):
			n += 1
		f = d.get_next()
	d.list_dir_end()
	return n


## ① 资产：每个兵种都有蒙版，且蒙版本身是烘过的（不是 404）
func _test_masks(cfg) -> void:
	var types: Array = cfg.unit_type_ids()
	var seen: Dictionary = {}
	for t in types:
		var id := String(t)
		var path := IconRes.mask_for_unit(cfg, id)
		ok(path != "", "★ %s 有剪影蒙版（%s）" % [id, path])
		if path == "":
			continue
		ok(ResourceLoader.exists(path), "★ %s 的蒙版真的导入过（%s）" % [id, path])
		seen[path] = true
	eq(seen.size(), MASK_COUNT,
		"★ 唯一蒙版数 = %d（复用同一张原画的兵种共用一张图）" % MASK_COUNT)

	# ★★ 组合条目（一次出 2 / 3 个兵）：**自己一张蒙版**，小人已经排好
	#    （协防军「o o」/ 御林军「o + o o」，见 tools/bake_unit_card_icon.py 的 combo_boxes）。
	for k in ["dy_guard", "dy_royal"]:
		var combo_path := IconRes.mask_for_combo(String(k))
		ok(combo_path != "", "★ 组合条目 %s 有专用蒙版（%s）" % [k, combo_path])
		ok(combo_path == "" or ResourceLoader.exists(combo_path),
			"★ %s 的组合蒙版真的导入过" % k)
	eq(IconRes.mask_for_combo(""), "", "空 kind 没有组合蒙版")
	eq(IconRes.mask_for_combo("spearman"), "",
		"★ 单兵条目没有组合蒙版（退回单兵那张，不会画错）")

	# 兜底：没有原画的兵种 / 未知 id ⇒ 空串（命令卡会退回矢量图），不报错、不空白
	eq(IconRes.mask_for_unit(cfg, ""), "", "空兵种 id 没有蒙版（走矢量兜底）")
	eq(IconRes.mask_for_unit(cfg, "no_such_unit_type"), "",
		"★ 未知兵种 id 没有蒙版（以后加兵种不会突然空白）")

	# 蒙版本身：尺寸 + 覆盖率 + 明暗层次（逐张看，15 张都要过）
	for path_v in seen.keys():
		var path := String(path_v)
		var tex: Variant = load(path)
		ok(tex is Texture2D, "%s 能载成贴图" % path.get_file())
		if not (tex is Texture2D):
			continue
		var img: Image = (tex as Texture2D).get_image()
		eq(img.get_width(), IconRes.MASK_SIZE, "%s 宽 = %d" % [path.get_file(), IconRes.MASK_SIZE])
		eq(img.get_height(), IconRes.MASK_SIZE, "%s 高 = %d" % [path.get_file(), IconRes.MASK_SIZE])
		var cov := _coverage(img)
		ok(cov > COVERAGE_MIN and cov < COVERAGE_MAX,
			"★ %s 覆盖率 %.1f%% 在 %.0f..%.0f 之间" % [path.get_file(), cov, COVERAGE_MIN, COVERAGE_MAX])
		var span := _shade_span(img)
		# 两种合法形态：
		#   · 金线稿（当前采用）：RGB 纯白 ⇒ span≈0，但覆盖率必须落在**细线**区间；
		#   · 浮雕 / 剪影：RGB 有明暗层次（span 大）。
		# ⚠️ 只断言「有明暗」会把线稿判死，只断言「是线」会把另外两档判死 —— 用「或」。
		var is_line := span <= LINE_RGB_SPAN and cov <= LINE_COVERAGE_MAX
		ok(span > 0.10 or is_line,
			"★ %s 要么有明暗层次（%.2f > 0.10），要么是细金线稿（覆盖率 %.1f%% ≤ %.0f%%）"
			% [path.get_file(), span, cov, LINE_COVERAGE_MAX])


## 蒙版 alpha 覆盖率（%）。抽样步长 2：15 张 × 384² 全量在 GDScript 里太慢。
func _coverage(img: Image) -> float:
	var data: PackedByteArray = img.get_data()
	var total: int = img.get_width() * img.get_height()
	var hits := 0
	var n := 0
	var i := 0
	while i < total:
		if data[i * 4 + 3] > 24:
			hits += 1
		n += 1
		i += 2
	return 100.0 * float(hits) / maxf(1.0, float(n))


## 剪影内部的明暗跨度（RGB 亮度 max-min）。relief 档的凹槽靠它撑起来。
func _shade_span(img: Image) -> float:
	var data: PackedByteArray = img.get_data()
	var total: int = img.get_width() * img.get_height()
	var lo := 1.0
	var hi := 0.0
	var i := 0
	while i < total:
		if data[i * 4 + 3] > 200:
			var l := (0.2126 * data[i * 4] + 0.7152 * data[i * 4 + 1] + 0.0722 * data[i * 4 + 2]) / 255.0
			lo = minf(lo, l)
			hi = maxf(hi, l)
		i += 2
	return hi - lo


## ① 每个兵种都得有图形
func _test_roles(cfg) -> void:
	var seen: Dictionary = {}
	var types: Array = cfg.unit_type_ids()
	ok(types.size() >= 20, "（前提）config 里有足够多的兵种（%d）" % types.size())
	for t in types:
		var id := String(t)
		var role := IconRes.role_of(cfg, id)
		ok(role != "", "★ %s 有图标角色" % id)
		ok(not IconRes.paths(role).is_empty(), "★ %s 的图标（%s）画得出来" % [id, role])
		seen[role] = true
	ok(seen.size() >= 8, "★ 用到的图形至少 8 种（实际 %d）" % seen.size())
	# 兜底：表里没有的兵种按「兵种大类 + 是否远程」落，不能空
	ok(IconRes.role_of(cfg, "") != "", "★ 空兵种 id 也有兜底图形（不会「没图」）")
	ok(IconRes.role_of(cfg, "no_such_unit_type") != "",
		"★ 未知兵种 id 也有兜底图形（以后加兵种不用改 unit_card_icon.gd）")


## ② 几何：九种图形都要有点、且点都在 0..1 内
func _test_geometry() -> void:
	for role in ROLES:
		var paths: Array = IconRes.paths(role)
		ok(not paths.is_empty(), "%s 有折线" % role)
		var total := 0
		var out_of_box := 0
		for pts in paths:
			var arr: PackedVector2Array = pts
			ok(arr.size() >= 2, "%s 的每条折线至少两个点（实际 %d）" % [role, arr.size()])
			total += arr.size()
			for p in arr:
				if p.x < -0.001 or p.x > 1.001 or p.y < -0.001 or p.y > 1.001:
					out_of_box += 1
		ok(total >= 6, "%s 的线足够多（%d 个点）" % [role, total])
		eq(out_of_box, 0, "★ %s 的所有点都在 0..1 内（偏出去会被画到格子外）" % role)


## ③ 「画得出东西」的纯断言
##
## ⚠️ 这里**不能**直接调 `IconRes.draw_into()`：`draw_polyline` 只允许在
##   `_draw()` 里调用，从外面调会刷一片引擎错误（与 view/fill_button.gd 的
##   `draw_fill` 同一条约束）。所以断言走纯计算的 `outline_count()`
##   —— 它和 `draw_into()` 用的是同一张 `paths()`。
func _test_draw() -> void:
	for role in ROLES:
		var n: int = IconRes.outline_count(role)
		var want: int = (IconRes.paths(role) as Array).size()
		eq(n, want, "★ %s 的折线条数 = %d" % [role, want])
		ok(n > 0, "★ %s 至少有一条折线要画" % role)
	eq(IconRes.outline_count("no_such_role"), IconRes.outline_count(IconRes.ROLE_SPEAR),
		"未知 role 退到长枪（永远有东西可画）")


## ④ 线色：正常 = 主题金；压金时更暗（否则金线压金底 = 消失）
func _test_ink() -> void:
	var normal: Color = IconRes.ink(false)
	eq(normal, ThemeRes.accent(), "正常档的线色 = 主题金（与主菜单那道路线同一个色）")
	var covered: Color = IconRes.ink(true)
	ok(covered.get_luminance() < normal.get_luminance(),
		"★ 压金档比正常档暗（%.3f < %.3f）" % [covered.get_luminance(), normal.get_luminance()])


## ⑤ 命令卡接线
func _test_card_wiring(cfg) -> void:
	var bow_mask := IconRes.mask_for_unit(cfg, "longbowman")
	var spear_mask := IconRes.mask_for_unit(cfg, "spearman")
	var catapult_mask := IconRes.mask_for_unit(cfg, "catapult")
	ok(bow_mask != "" and spear_mask != "" and catapult_mask != "",
		"（前提）三个代表兵种都取到了蒙版")

	var card = CommandCardRes.new()
	root.add_child(card)
	card.setup()
	# 带图标的两格 + 不带图标的一格 + 两格空
	card.set_entries([
		{"type": "recruit", "name": "长弓兵", "icon_role": IconRes.ROLE_BOW, "icon_mask": bow_mask},
		{"type": "recruit", "name": "长枪兵", "icon_role": IconRes.ROLE_SPEAR, "icon_mask": spear_mask},
		{"type": "order", "name": "移动"},
		{"type": "recruit", "name": "投石车", "icon_role": IconRes.ROLE_CATAPULT, "icon_mask": catapult_mask},
	])
	eq(card.cell_icon_path(0), bow_mask, "★ 第 1 格画「长弓兵」的剪影蒙版")
	eq(card.cell_icon_path(1), spear_mask, "★ 第 2 格画「长枪兵」的剪影蒙版")
	eq(card.cell_icon_path(2), "", "★ 没有 icon_mask 的条目（操作页那种）不画图标")
	eq(card.cell_icon_path(3), catapult_mask, "★ 第 4 格画「投石车」的剪影蒙版")
	eq(card.cell_icon_path(4), "", "空格子没有图标")
	# role 仍然照原样转发（蒙版缺失时它是唯一的画法）
	eq(card.cell_icon_role(0), IconRes.ROLE_BOW, "兜底的 role 也照旧传进来了")
	eq(card.cell_icon_role(2), "", "没有 icon_role 的条目没有兜底图形")

	# 名字：**显示**在最下面那一行（需求改成「图标 + 一行名字，描述进悬停面板」）。
	#   ★ 这条与旧版相反：旧版是「有图就把名字藏起来」。两件事仍分开断言：
	#     可见性 + 文字内容（`cell_label` 是语义出口）。
	ok(card.cell_label_visible(0), "★ 有图标的格子**照样显示名字**（图标 + 一行名字）")
	eq(card.cell_label(0), "长弓兵", "★★ 名字仍然读得到（cell_label 是语义出口）")
	ok(card.cell_label_visible(2), "★ 没有图标的格子照旧显示名字（操作页不受影响）")
	eq(card.cell_label(2), "移动", "没有图标那一格的名字还是「移动」")

	# ★★ 几何：图标**铺满整格**（需求：图标不考虑文字的位置），
	#    而 `mask_rect` 永远返回**正方形** —— 蒙版是 384×384，塞进扁矩形会被拉伸，
	#    那就是用户报的「图标有点扁」。这两条一起钉住。
	var iv = card.cell_at(0).get_node_or_null("CardIcon1")
	ok(iv != null, "（前提）第 1 格有图标层")
	if iv != null:
		# ★ 用**锚点**断言「铺满整格」：无头测试里没有布局帧，`size` 还是 0，
		#   但锚点 0/1 已经决定了它最终会铺满 —— 这条才是真正要钉住的形状。
		var full := (iv as Control).anchor_left == 0.0 and (iv as Control).anchor_top == 0.0 \
			and is_equal_approx((iv as Control).anchor_right, 1.0) \
			and is_equal_approx((iv as Control).anchor_bottom, 1.0)
		ok(full, "★★ 图标层铺满整格（锚点 0..1，不再只占上面一截）")
	var sq := IconRes.mask_rect(Rect2(0.0, 0.0, 86.67, 64.0))
	ok(is_equal_approx(sq.size.x, sq.size.y),
		"★★ mask_rect 对扁矩形也返回正方形（%.2f×%.2f）" % [sq.size.x, sq.size.y])
	ok(sq.size.x < 86.67, "★ 正方形还留了内边距（不贴格子边）")

	# ★★ 名字底条：有图标的格子垫一条、纯文字格子不垫。
	var bar0 = card.cell_at(0).get_node_or_null("CardNameBar1")
	var bar2 = card.cell_at(2).get_node_or_null("CardNameBar3")
	ok(bar0 != null, "（前提）第 1 格有名字底条")
	if bar0 != null:
		ok((bar0 as ColorRect).visible, "★ 有图标 ⇒ 名字底条显示")
		ok((bar0 as ColorRect).size.x > 10.0 and (bar0 as ColorRect).size.y > 4.0,
			"★ 底条有实际尺寸")
	if bar2 != null:
		ok(not (bar2 as ColorRect).visible, "★ 没有图标（操作页）⇒ 不垫底条")

	# 只有 icon_role（蒙版缺失 / 旧条目）也要能画、名字同样显示 → 走矢量兜底那条路
	card.set_entries([{"type": "recruit", "name": "长弓兵", "icon_role": IconRes.ROLE_BOW}])
	eq(card.cell_icon_path(0), "", "只给 role 的条目：没有蒙版")
	eq(card.cell_icon_role(0), IconRes.ROLE_BOW, "★ 只给 role 的条目：照旧画矢量金线")
	ok(card.cell_label_visible(0), "★ 只给 role 的条目：名字同样显示")

	# 换页：图标要能被清掉（回到只有字的页面不能留上一个兵的图）
	card.set_entries([{"type": "order", "name": "移动"}])
	eq(card.cell_icon_path(0), "", "★ 换页后旧蒙版被清掉")
	eq(card.cell_icon_role(0), "", "★ 换页后旧图形被清掉")
	ok(card.cell_label_visible(0), "★ 换页后名字重新显示")

	# 锁定态：图标要跟着**画暗一档**（与大本营等级一起锁着的那几行）
	var locked = card.cell_at(0).get_node_or_null("CardIcon1")
	ok(locked != null, "★ 格子里挂上了图标层（节点 CardIcon1）")
	if locked != null:
		card.set_entries([
			{"type": "recruit", "name": "长弓兵", "icon_mask": bow_mask, "ready": true},
			{"type": "recruit", "name": "骑手", "icon_mask": spear_mask, "ready": false},
		])
		eq(locked.ink_color(), IconRes.ink(false, true), "可以招的格子：亮金")
		var locked2 = card.cell_at(1).get_node_or_null("CardIcon2")
		ok(locked2 != null, "★ 第 2 格也有图标层")
		if locked2 != null:
			eq(locked2.ink_color(), IconRes.ink(false, false), "★ 锁住的格子：图标画暗一档")
			ok(locked2.ink_color().a < locked.ink_color().a,
				"★ 锁定档透明度更低（%.2f < %.2f）"
				% [locked2.ink_color().a, locked.ink_color().a])
	card.queue_free()
