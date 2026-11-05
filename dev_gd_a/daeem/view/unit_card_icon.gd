## unit_card_icon.gd —— 右下 3×3 命令卡 / 科技格里画的**金线图标**（兵种 / 建筑 / 科技）
##
## 需求原话：「将右下角命令卡中的招募单位的按钮内的文字改为图标，其风格需要是类似于
## 主菜单左侧轮播动画的金线勾勒风格，尝试程序化生成/渲染出当前所有单位（小兵）的图标并应用」。
##
## ------------------------------------------------------------------
## 本版：**三套图标、同一套画法**
## ------------------------------------------------------------------
## 需求原话（最新一轮）：「把图标改为 preview_etch 那种样子……**完全用金线**代替，
## 不要有断裂的像素；有的单位没显示出来，需要相应地移动取样点的位置」；
## 之后又追加：「建筑渲染和配图标」、「科技也要配（按文字描述渲染一版占位的）」，
## 以及**格子排版统一成「图标 + 一行名字，描述进悬停面板」**（兵种 / 建筑 / 科技都一样）。
##
## ① 兵种：`assets/ui/card_icon/<原画文件名>.png` 那 15 张**离线烘**的线稿蒙版
##   （tools/bake_unit_card_icon.py 的 `--style etch`）。命名 = **原画文件名**，
##   所以多个兵种复用同一张原画时（dg_champion→knight、dy_ranger→horse_archer …）天然共用一张。
##   · RGB = **纯白**，A = **线的覆盖率** ⇒ 运行时 `ink`（主题金）乘上去就是纯金线；
##   · 运行时只做 `draw_texture_rect(tex, r, false, ink)` —— 换皮肤不用重烘，
##     锁灰档与悬停压金翻面也自动继承（见 `ink()`）。
##   · 蒙版怎么挑兵种：`mask_for_unit(cfg, unit_type)`（hud 在条目里塞 `icon_mask`）。
##   · ★★ **组合条目**（协防军一次 2 人 / 御林军一次 3 人）有自己一张蒙版：
##     `combo_<招募条目 kind>.png`，小人已经按「o o」/「o + o o」摆在图里，
##     每个小人按自己的格子取线宽（更细一档）—— 运行时不需要知道怎么排。
##     入口：`mask_for_combo(kind)`（hud 先问它，没有才退回单兵那张）。
## ② 建筑：`building_<建筑类型>.png`。**没有 2D 原画**，是烘图脚本直接读
##   `view/building_view_3d.gd` 的 `BUILDING_MODELS`，从 .glb 抽折角边、做 z-buffer
##   消隐，再按等轴测投影画出来的线稿（不是描 3D 渲染图）。入口：`mask_for_building(type)`。
## ③ 科技：`tech_<科技 id>.png`。**一条原画都没有**，是按名字手画的**占位**图形
##   （麦穗 / 钱堆 / 城墙盾 / 头盔 / 房与人 / 箭头 / 盾勾 / 钟 / 王冠 / 军阵 / 田垄 /
##    犁 / 枪旗 / 栅栏 / 旗与路 / 马蹄铁 / 镐与钱 / 楔与墙），右下角点数 = 阶数。
##   入口：`mask_for_tech(id)`。等以后有真正的科技原画，换掉这张 png 即可。
##
## ★ 三套都走同一个 `IconView`：**铺满整格**（图标不考虑文字的位置），
##   名字叠在最下面那条**略黑底条**上（`ui_style.name_bar()`，金色填充扫上来时底条
##   跟着淡出，字翻成压金暗色）。`mask_rect()` 永远返回**正方形** —— 蒙版是 384×384，
##   塞进扁矩形会被拉伸成「扁图标」（踩过）。
##
## ------------------------------------------------------------------
## 为什么上一版否掉了「从原画抽线」，这一版又能抽（别再按旧结论推翻自己）
## ------------------------------------------------------------------
## 上一版试的是「**边线检测**（DoG 高反差）→ 描金」：这套立绘是「平涂 + 一圈占
##   30~40% 面积的粗黑描边」，勾出来的是**描边的两侧**（两条平行线），且低反差处会断。
##   缩到 87px 后：双线并成一根粗块、断口变成一截一截 —— 就是 preview_etch 那张图
##   （它当时还有预览贴图的 bug，见 tools/README-tools.md）里看到的样子。
## ⇒ 现在换成**细化（Zhang-Suen）**：把那条粗黑描边压成**一根中线**再加粗。
##   一根就是一根，缩小后仍然是一条；而黑描边在原画里本来就是**连续闭合**的，
##   所以「连续」是免费的 —— 前提是连通域判断用 **8 连通**
##   （4 连通会把斜着走的骨架判成一地碎点，然后被当噪点整条删掉）。
##   ⚠️ 这也解释了为什么「粗黑边占 30~40%」不再是问题：我们不再勾它的边，而是取它的芯。
##
## ------------------------------------------------------------------
## 兜底：九种**职能图形**（矢量）
## ------------------------------------------------------------------
## 格子的用途是「一眼认出这是哪一类兵」，所以按**手里拿什么 / 怎么打**分九种图形：
##   长枪 / 弓 / 剑盾 / 马蹄铁（骑兵）/ 马蹄铁 + 弓（骑射）/ 粮车 / 投石车 / 弩炮 / 战车。
##   · 21 个兵种按 `ROLE_BY_TYPE` 落到这九种；表里没有的新兵种按**兵种大类 + 是否远程**
##     兜底（见 `role_of`）⇒ **以后加兵种不用改这个文件**，也永远不会「没图」。
##   · 同一派系的重复（比如披甲剑士与御林剑盾）本来长得就像，共用一张图不算失真；
##     具体数值 / 名字 / 人口那些都由**悬停详情面板**给（见 hud._hover_detail）。
##   · 组合条目（协防军 2 人 / 御林军 3 人）取**第一个生成兵种**的图形当作这一包的「脸」，
##     整包内容同样在悬停面板里。
##
## ------------------------------------------------------------------
## 不画外圈
## ------------------------------------------------------------------
## 主菜单的徽记有一圈四段弧，好看；但命令卡每一格**自己已经有 1px 边框**（ui_style.card_normal），
## 再套一个圆环就是两层框套在一起。所以这里只画里面的图形，边框交给格子。
##
## ⚠️ 纯静态：不读 world、不碰状态；`paths()` 只吃一个 role 字符串，测试可以对着点集断言。
extends RefCounted

const ThemeRes = preload("res://view/theme.gd")

## 剪影蒙版目录（`tools/bake_unit_card_icon.py --commit` 的产物）。
## ★ 文件名 = **原画文件名**（不含扩展名），不是兵种 id —— 复用同一张原画的兵种共用一张图。
const MASK_DIR := "res://assets/ui/card_icon/"
## 蒙版画布边长（bake 时定的）。测试拿它断言「没烘错尺寸」。
const MASK_SIZE := 384
## 蒙版外面再留一圈（相对格子短边）。蒙版自己已经有 6% 内边距 + 底对齐，
## 这里只补一点，别让图贴上格子的 1px 边框。
const MASK_INSET_RATIO := 0.03

## 兵种 → 蒙版路径的缓存（`""` 也是有效结果：已知没有蒙版，走矢量兜底）。
static var _mask_cache: Dictionary = {}

## 图形坐标空间：0..1（左下角原点无意义，统一 **左上角原点、y 向下**，与屏幕一致）。
const BOX := 1.0
## 整圆 / 整段弧的采样数。64 段在 60~80px 的格子上一段约 3~4px，肉眼看不出折线。
const ARC_SEG := 64

## 九种职能图形（`role_of` 的返回值）。
const ROLE_SPEAR := "spear"
const ROLE_BOW := "bow"
const ROLE_SWORD_SHIELD := "sword_shield"
const ROLE_HORSE := "horse"
const ROLE_HORSE_BOW := "horse_bow"
const ROLE_CART := "cart"
const ROLE_CATAPULT := "catapult"
const ROLE_BALLISTA := "ballista"
const ROLE_CHARIOT := "chariot"

## 兵种 id → 职能图形。
##
## ★ 这张表是**唯一的逐兵种映射**：加兵种时要么在这里加一行，要么什么都不用做
##   （`role_of` 会按大类兜底）。⚠️ 不要在这里写「看起来差不多」的重复项 ——
##   同一个 role 只该出现一次含义。
const ROLE_BY_TYPE := {
	# 原生
	"spearman": ROLE_SPEAR,
	"longbowman": ROLE_BOW,
	"rider": ROLE_HORSE,
	"grain_cart": ROLE_CART,
	"knight": ROLE_HORSE,
	"horse_archer": ROLE_HORSE_BOW,
	"catapult": ROLE_CATAPULT,
	# 王朝
	"dy_spear_guard": ROLE_SPEAR,
	"dy_archer_guard": ROLE_BOW,
	"dy_ranger": ROLE_HORSE_BOW,
	"dy_royal_sword": ROLE_SWORD_SHIELD,
	"dy_royal_archer": ROLE_BOW,
	"dy_royal_cavalry": ROLE_HORSE,
	"dy_chariot": ROLE_CHARIOT,
	"dy_catapult": ROLE_CATAPULT,
	# 帝国
	"dg_swordsman": ROLE_SWORD_SHIELD,
	"dg_archer": ROLE_BOW,
	"dg_rider": ROLE_HORSE,
	"dg_champion": ROLE_HORSE,
	"dg_bolt": ROLE_BALLISTA,
}

## 线宽（**格子的设计像素**；格子 86.7px，HUD 整体缩放时跟着放大）。
## ★ 2.0 与主菜单雕版图那道的观感接近（那道是 1.4，但画面大得多）。
const LINE_W := 2.0
## 图形在格子里的留白比例（相对短边）。留白是为了不贴到格子的 1px 边框上。
const INSET_RATIO := 0.075
## 图形整体下移（相对短边）：左上角压着快捷键字母（Q/W/E…），别让图形顶上去。
const NUDGE_Y := 0.03
## **锁住的格子**（这一行还没解锁）的线色不透明度 —— 与「灰字」同一个观感档位。
const LOCKED_ALPHA := 0.45


# ------------------------------------------------------------------
# 兵种 → 图形
# ------------------------------------------------------------------

## 某个兵种用哪张图形。
##
## ★ 表里有就用表；没有就按**兵种大类 + 是否远程**兜底 ——
##   于是「以后新加的兵种」自动有图形（步兵近战 = 长枪、步兵远程 = 弓、
##   骑兵近战 = 马蹄铁、骑兵远程 = 马蹄铁 + 弓、器械 = 投石车），不用改这个文件。
static func role_of(cfg, unit_type: String) -> String:
	var t := String(unit_type)
	if ROLE_BY_TYPE.has(t):
		return String(ROLE_BY_TYPE[t])
	if cfg == null:
		return ROLE_SPEAR
	if String(cfg.unit_class_of(t)) == "siege":
		return ROLE_CATAPULT
	if String(cfg.unit_class_of(t)) == "cavalry":
		return ROLE_HORSE_BOW if bool(cfg.unit_is_ranged(t)) else ROLE_HORSE
	return ROLE_BOW if bool(cfg.unit_is_ranged(t)) else ROLE_SPEAR


## 这个兵种有没有图形（永远有：兜底也在，所以只用于调试 / 测试）。
static func has_role(role: String) -> bool:
	return not paths(role).is_empty()


# ------------------------------------------------------------------
# 剪影蒙版（主路径）
# ------------------------------------------------------------------

## 原画路径 → 蒙版路径（**只算路径，不判断存不存在**）。
## ★ 约定：`res://assets/test_units/Rider/rider.png` → `res://assets/ui/card_icon/rider.png`。
static func mask_path_for_sprite(sprite_path: String) -> String:
	var base := String(sprite_path).get_file().get_basename()
	if base == "":
		return ""
	return MASK_DIR + base + ".png"


## 某个兵种用哪张**剪影蒙版**。`""` = 没有（调用方退回矢量图形）。
##
## ★ 结果缓存进 `_mask_cache`（含 `""`）：命令卡每次换页都要问九次，
##   不缓存就是每次换页九下 `ResourceLoader.exists`。理由同 view/unit_sprite_3d.gd
##   的 `_load_asset_image`（那边缓存的是 `false` 哨兵）。
## ★ 素材缺失时返回 `""` 而**不报错**：症状是「这一格画回矢量图形」，
##   而不是「空格子」—— 空槽在本项目里是有语义的（行没满的那几格）。
static func mask_for_unit(cfg, unit_type: String) -> String:
	var t := String(unit_type)
	if t == "":
		return ""
	if _mask_cache.has(t):
		return String(_mask_cache[t])
	var path := ""
	if cfg != null:
		path = mask_path_for_sprite(String(cfg.unit_sprite_of(t)))
		if path != "" and not ResourceLoader.exists(path):
			path = ""
	_mask_cache[t] = path
	return path


## **建筑**图标的蒙版路径：`building_<建筑类型>.png`（从 .glb 抽边线的等轴测线稿）。
## ★ 建筑没有原画，烘焙脚本直接读 `view/building_view_3d.gd` 的 `BUILDING_MODELS`。
static func mask_for_building(btype: String) -> String:
	var k := String(btype)
	if k == "":
		return ""
	var key := "building:" + k
	if _mask_cache.has(key):
		return String(_mask_cache[key])
	var path := MASK_DIR + "building_" + k + ".png"
	if not ResourceLoader.exists(path):
		path = ""
	_mask_cache[key] = path
	return path


## **科技**图标的蒙版路径：`tech_<科技 id>.png`。
## ★ 科技一条原画都没有，这批是烘焙脚本按名字画的**占位**图形（见 TECH_SHAPES）。
static func mask_for_tech(tech_id: String) -> String:
	var k := String(tech_id)
	if k == "":
		return ""
	var key := "tech:" + k
	if _mask_cache.has(key):
		return String(_mask_cache[key])
	var path := MASK_DIR + "tech_" + k + ".png"
	if not ResourceLoader.exists(path):
		path = ""
	_mask_cache[key] = path
	return path


## 清空蒙版路径缓存（测试用；换 config 之后要清，否则读到上一份的结果）。
static func clear_mask_cache() -> void:
	_mask_cache.clear()


## **组合条目**（招募一次出多个兵，比如协防军 2 人 / 御林军 3 人）的蒙版路径。
##
## ★ 命名 = `combo_<招募条目的 kind>.png`（bake 脚本按 config 里带 `spawn` 的条目自动生成），
##   所以这里只认「条目 kind」，不需要知道它由哪几个兵种组成 —— 排布已经烘在图里了。
## ★ 为什么组合要单独烘一张、而不是运行时摆两三张单兵图标：
##   单兵蒙版是 384px、靠 mipmap 缩到格子里；再在运行时把它缩到 1/2 或 1/3，
##   线会细到 0.5px 以下，糊成灰影。烘一张的时候每个小人按**自己的格子**取线宽（更细一档），
##   缩到 87px 之后仍然是干净的线。
## @return 路径；这不是组合条目（或没烘过）时返回 ""（调用方退回单兵蒙版）。
static func mask_for_combo(kind: String) -> String:
	var k := String(kind)
	if k == "":
		return ""
	var key := "combo:" + k
	if _mask_cache.has(key):
		return String(_mask_cache[key])
	var path := MASK_DIR + "combo_" + k + ".png"
	if not ResourceLoader.exists(path):
		path = ""
	_mask_cache[key] = path
	return path


# ------------------------------------------------------------------
# 几何（0..1 空间，y 向下）
# ------------------------------------------------------------------

## 一张图形的所有折线（每条都是一条 `draw_polyline` 的输入）。
##
## ★ 认不出的 role **退回长枪**（永远画得出东西）：这样「条目里塞了一个拼错的 role」
##   在屏幕上表现为「画错了一张图」，而不是「那一格突然空了」——
##   空槽在本项目里是有语义的（行没满的那几格），不能让它和「拼错」撞在一起。
## ★ 纯函数：不读配置、不碰节点 —— 测试直接对着点集断言（见 tests/test_unit_card_icon.gd）。
static func paths(role: String) -> Array:
	var r := String(role)
	if r == ROLE_BOW:
		return _bow()
	if r == ROLE_SWORD_SHIELD:
		return _sword_shield()
	if r == ROLE_HORSE:
		return _horse()
	if r == ROLE_HORSE_BOW:
		return _horse_bow()
	if r == ROLE_CART:
		return _cart()
	if r == ROLE_CATAPULT:
		return _catapult()
	if r == ROLE_BALLISTA:
		return _ballista()
	if r == ROLE_CHARIOT:
		return _chariot()
	return _spear()


## 长枪兵 / 协防军（枪）：**鸢形盾 + 斜挑的长枪**。
static func _spear() -> Array:
	return [
		# 盾：上缘一条平边、下面收成尖（鸢形盾 —— 比纯椭圆更像“盾”，不会读成叶子）
		_poly([_v(0.17, 0.22), _v(0.43, 0.22), _v(0.43, 0.50),
			_v(0.30, 0.86), _v(0.17, 0.50)]),
		_line(_v(0.30, 0.26), _v(0.30, 0.68)),          # 盾脊
		_line(_v(0.54, 0.96), _v(0.86, 0.12)),          # 枪杆
		_poly([_v(0.86, 0.02), _v(0.80, 0.13), _v(0.86, 0.24), _v(0.92, 0.13)]),  # 菱形枪头
	]


## 弓手：**弓身 + 弦 + 一支穿过弓的箭**。
static func _bow() -> Array:
	return [
		_arc(_v(0.26, 0.50), 0.34, -56.0, 56.0),        # 弓身（向左凸）
		_line(_v(0.45, 0.22), _v(0.45, 0.78)),          # 弦
		_line(_v(0.20, 0.50), _v(0.86, 0.50)),          # 箭杆
		_poly([_v(0.92, 0.50), _v(0.76, 0.43), _v(0.76, 0.57)]),   # 箭头
		_line(_v(0.20, 0.50), _v(0.10, 0.41)),          # 尾羽
		_line(_v(0.20, 0.50), _v(0.10, 0.59)),
	]


## 剑盾兵：**左边的圆盾 + 右边斜举的剑**（两者分开摆，60px 下才读得出是两件东西）。
static func _sword_shield() -> Array:
	return [
		_circle(_v(0.32, 0.56), 0.24),
		_circle(_v(0.32, 0.56), 0.09),                  # 盾心
		_line(_v(0.58, 0.96), _v(0.82, 0.20)),          # 剑身
		_line(_v(0.68, 0.29), _v(0.85, 0.35)),          # 护手（垂直于剑身）
		_circle(_v(0.58, 0.96), 0.035),                 # 剑首
	]


## 骑兵：**马蹄铁 + 三颗钉孔**（比画马头稳：60px 下马头会被读成一个钩子）。
static func _horse() -> Array:
	return [
		_arc(_v(0.50, 0.44), 0.34, 200.0, 340.0),       # 蹄铁（开口朝下）
		_line(_v(0.19, 0.57), _v(0.19, 0.76)),          # 两只铁角
		_line(_v(0.81, 0.57), _v(0.81, 0.76)),
		_circle(_v(0.33, 0.29), 0.025),                 # 钉孔
		_circle(_v(0.67, 0.29), 0.025),
		_circle(_v(0.50, 0.15), 0.025),
	]


## 骑射：**蹄铁 + 弓**。
static func _horse_bow() -> Array:
	return [
		_arc(_v(0.31, 0.40), 0.24, 200.0, 340.0),
		_line(_v(0.09, 0.50), _v(0.09, 0.64)),
		_line(_v(0.53, 0.50), _v(0.53, 0.64)),
		_circle(_v(0.41, 0.21), 0.022),
		_arc(_v(0.70, 0.56), 0.24, -60.0, 60.0),
		_line(_v(0.82, 0.34), _v(0.82, 0.78)),
	]


## 粮车：**车厢 + 两个轮子 + 车辕 + 车顶的粮袋**。
static func _cart() -> Array:
	return [
		_poly([_v(0.12, 0.30), _v(0.64, 0.30), _v(0.64, 0.56), _v(0.12, 0.56)]),
		_line(_v(0.12, 0.46), _v(0.64, 0.46)),          # 车厢板缝
		_circle(_v(0.26, 0.72), 0.13),
		_circle(_v(0.54, 0.72), 0.13),
		_line(_v(0.64, 0.36), _v(0.88, 0.30)),          # 车辕
		_arc(_v(0.38, 0.18), 0.16, 200.0, 340.0),       # 粮袋
	]


## 投石车：**轮 + 横梁 + 抛臂 + 兜囊**。
static func _catapult() -> Array:
	return [
		_circle(_v(0.26, 0.72), 0.14),
		_line(_v(0.12, 0.58), _v(0.52, 0.58)),
		_line(_v(0.26, 0.58), _v(0.74, 0.18)),          # 抛臂
		_line(_v(0.74, 0.18), _v(0.90, 0.36)),          # 兜囊拉索
		_circle(_v(0.90, 0.36), 0.04),                  # 石弹
		_line(_v(0.42, 0.58), _v(0.54, 0.86)),
		_line(_v(0.26, 0.58), _v(0.26, 0.72)),
	]


## 弩炮：**大弩箭 + 弩臂 + 支架**。
static func _ballista() -> Array:
	return [
		_line(_v(0.08, 0.62), _v(0.80, 0.36)),          # 弩箭
		_poly([_v(0.94, 0.32), _v(0.76, 0.30), _v(0.80, 0.46)]),
		_line(_v(0.12, 0.56), _v(0.26, 0.68)),          # 尾羽
		_line(_v(0.12, 0.62), _v(0.26, 0.68)),
		_poly([_v(0.62, 0.12), _v(0.54, 0.50), _v(0.62, 0.88)], false),   # 弩臂
		_line(_v(0.36, 0.60), _v(0.30, 0.90)),          # 支架
		_line(_v(0.46, 0.58), _v(0.52, 0.90)),
	]


## 战车：**车箱 + 两个大轮 + 帅旗 + 两侧冲角**。
static func _chariot() -> Array:
	return [
		_poly([_v(0.32, 0.26), _v(0.68, 0.26), _v(0.68, 0.50), _v(0.32, 0.50)]),
		_circle(_v(0.22, 0.68), 0.15),
		_circle(_v(0.78, 0.68), 0.15),
		_line(_v(0.50, 0.26), _v(0.50, 0.10)),          # 旗杆
		_poly([_v(0.50, 0.10), _v(0.72, 0.04), _v(0.72, 0.20)]),   # 旗
		_line(_v(0.22, 0.53), _v(0.10, 0.40)),          # 冲角
		_line(_v(0.78, 0.53), _v(0.90, 0.40)),
	]


# ------------------------------------------------------------------
# 绘制
# ------------------------------------------------------------------

## 一支图形的线宽（设计像素）。给测试与调用方一个统一出口。
static func line_width(_rect: Rect2) -> float:
	return LINE_W


## 一支图形**会画出多少条折线**（纯计算，不碰 `draw_*`）。
## ★ 给测试与「这一格有没有内容」的判断用：`draw_into()` 只能在 `_draw()` 里调，
##   从外面调会踩引擎的 "Drawing is only allowed inside this node's `_draw()`"
##   （与 view/fill_button.gd 的 `draw_fill` 同一条约束），所以需要一个纯的出口来断言。
static func outline_count(role: String) -> int:
	var n := 0
	for pts in paths(role):
		if (pts as PackedVector2Array).size() >= 2:
			n += 1
	return n


## 把图形画进 `rect`。
## @param role  `role_of()` 的结果
## @param ink   线色（`ink()` 给的：正常金 / 压金暗色 / 锁住的半透明金）
## @return 本次发出的 `draw_polyline` 条数（0 = 没画）。
##   ★ 返回值不是装饰：无头测试里 `_draw()` 内部的错误**不会**让测试失败，
##     「一条线都没画」既不报错也不改状态 —— 留一个可数的痕迹才钉得住
##     （与 view/unit_icon.gd 的 `draw_char_at` 同一条口径）。
static func draw_into(ci: CanvasItem, rect: Rect2, role: String, ink: Color) -> int:
	if ci == null or rect.size.x < 4.0 or rect.size.y < 4.0:
		return 0
	var short: float = minf(rect.size.x, rect.size.y)
	var inset: float = short * INSET_RATIO
	var area := Rect2(
		rect.position + Vector2(inset, inset + short * NUDGE_Y),
		rect.size - Vector2(inset * 2.0, inset * 2.0))
	var w: float = line_width(rect)
	var n := 0
	for pts in paths(role):
		var arr: PackedVector2Array = pts
		if arr.size() < 2:
			continue
		var mapped := PackedVector2Array()
		mapped.resize(arr.size())
		for i in arr.size():
			mapped[i] = area.position + Vector2(arr[i].x * area.size.x, arr[i].y * area.size.y)
		# `antialiased = true`：细线在非整数缩放（手机）下不开抗锯齿会断成虚线。
		ci.draw_polyline(mapped, ink, w, true)
		n += 1
	return n


## 蒙版的绘制区：**正方形**、在 `rect` 里居中，四周留 `MASK_INSET_RATIO` 的边。
## ★★ 必须是正方形：蒙版本身是 384×384 的正方形，`draw_texture_rect` 会把图**拉伸**
##    铺满给定的矩形。以前这里直接把 `rect` 缩一圈就往回传 —— 于是只要调用方给的
##    是「上面一截」那种扁矩形，图标就被压扁（用户报的「图标有点扁」就是这个）。
static func mask_rect(rect: Rect2) -> Rect2:
	var short: float = minf(rect.size.x, rect.size.y)
	var inset: float = short * MASK_INSET_RATIO
	var side: float = maxf(1.0, short - inset * 2.0)
	var pos := rect.position + (rect.size - Vector2(side, side)) * 0.5
	return Rect2(pos, Vector2(side, side))


## 把一张图标蒙版画进 `rect`。
## @param ink 线色 / 乘色（`ink()` 给的：正常金 / 压金暗色 / 锁住的半透明金）
## @return 本次发出的 `draw_texture_rect` 条数（0 = 没画）。
##   ★ 与 `draw_into()` 同一个道理：留一个可数的痕迹，测试才钉得住
##     「画了」这件事（`_draw()` 里的错误在无头测试中不会让用例变红）。
static func draw_mask(ci: CanvasItem, tex: Texture2D, rect: Rect2, ink: Color) -> int:
	if ci == null or tex == null or rect.size.x < 4.0 or rect.size.y < 4.0:
		return 0
	# 线稿蒙版的 RGB 是**纯白**、A 是线覆盖率 ⇒ `ink` 乘上去就是「主题金画的线」，
	# 不需要 shader，换主题也不用重烘（relief / flat 两档的 RGB 是明暗，同一条乘法也成立）。
	ci.draw_texture_rect(tex, mask_rect(rect), false, ink)
	return 1


## 线色。
## @param covered 金色填充已经盖过图形中心（此时要换成**压金那一档**）
## @param ready   这一格现在能不能招（不能 = 与大本营等级一起锁着的那几行）
##
## ★ 与按钮文字**同一条规则**（见 view/fill_button.gd 的 `_sync_text`）：
##   金扫上来就把前景翻到「金底上那一档」，否则金色线压在金色底上等于消失。
## ★ 与文字**同一档明暗**：锁住的格子（`ready == false`）原本是 `text_faint()` 那种
##   灰字，图标也不能还是亮金 —— 否则「看着能点、点了没反应」那个老毛病会从文字
##   搬到图标上（同一屏里其它格是暗的，只有它亮着）。
static func ink(covered: bool, ready: bool = true) -> Color:
	var gold: Color = ThemeRes.accent()
	if not ready:
		gold = ThemeRes.with_alpha(gold, LOCKED_ALPHA)
	if not covered:
		return gold
	return ThemeRes.text_on_fill(false, gold)


# ------------------------------------------------------------------
# 图元（0..1 空间）
# ------------------------------------------------------------------

static func _v(x: float, y: float) -> Vector2:
	return Vector2(x * BOX, y * BOX)


## 开放折线（不回到起点）。
static func _line(a: Vector2, b: Vector2) -> PackedVector2Array:
	return PackedVector2Array([a, b])


## 闭合折线（首点重复一次，因为 `draw_polyline` 不会自己闭合）。
static func _poly(pts: Array, closed: bool = true) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts:
		out.append(p)
	if closed and out.size() >= 2:
		out.append(out[0])
	return out


## 圆弧（角度制，0° = 正右，正角度往**下**转 = 屏幕上的顺时针）。
static func _arc(c: Vector2, r: float, a0: float, a1: float) -> PackedVector2Array:
	var seg: int = maxi(6, int(ceil(ARC_SEG * absf(a1 - a0) / 360.0)))
	var out := PackedVector2Array()
	out.resize(seg + 1)
	for i in seg + 1:
		var a := deg_to_rad(lerpf(a0, a1, float(i) / float(seg)))
		out[i] = c + Vector2(cos(a), sin(a)) * r * BOX
	return out


static func _circle(c: Vector2, r: float) -> PackedVector2Array:
	return _arc(c, r, 0.0, 360.0)


# ------------------------------------------------------------------
# 格子里的那颗控件
# ------------------------------------------------------------------

## 命令卡某一格里的图标层。
##
## ★ 它自己**不存玩法状态**：`role` 由 `set_role()` 灌进来（条目 → hud → 这里），
##   线色则每帧问一下宿主按钮的填充进度 —— 于是「金扫到哪儿、图标就翻到哪儿」
##   与文字的翻面是同一条时间线，不用改 `fill_button` 一行。
class IconView extends Control:
	const IconRes = preload("res://view/unit_card_icon.gd")
	const FillButtonRes = preload("res://view/fill_button.gd")

	## 宿主格子（读它的填充进度用）。
	var _cell: Button = null
	## 当前矢量图形（空串 = 这一层不画矢量图）。
	var _role: String = ""
	## 当前剪影蒙版（非空 = **主路径**：画这张图，矢量图整条路都不走）。
	var _mask_path: String = ""
	var _tex: Texture2D = null
	## 这一格现在能不能点（锁住的行画暗一档，见 `IconRes.ink`）。
	var _ready: bool = true
	## 这一帧用的线色（只在换档时 `queue_redraw()`）。
	var _ink: Color = Color(1, 1, 1, 1)
	## 上一帧的「压金」判定（换档才重画）。
	var _covered: bool = false

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		# ★ 蒙版是 384px 缩到 86px 画的：必须走 mipmap，否则凹槽那几根细线会闪。
		texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		set_process(false)

	## 绑到某一格。
	## @param area 只占这一块（格内坐标）；不给 = 铺满整格。
	## ★★ 为什么不是「先 PRESET_FULL_RECT 再改 size」：那样锚点是「非等对立锚点」，
	##    Godot 会在 `_ready()` 之后把 size 覆盖回铺满（控制台那条
	##    "Nodes with non-equal opposite anchors will have their size overridden"），
	##    表现就是图标画到了名字那一行上。给 area 时走**左上角锚点 + 绝对尺寸**。
	func bind(cell: Button, area: Rect2 = Rect2()) -> void:
		_cell = cell
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		if area.size.x <= 0.0 or area.size.y <= 0.0:
			set_anchors_preset(Control.PRESET_FULL_RECT)
			set_offsets_preset(Control.PRESET_FULL_RECT)
			return
		set_anchors_preset(Control.PRESET_TOP_LEFT)
		position = area.position
		size = area.size

	## 换成另一个矢量图形（空串 = 这一层不画矢量图）。
	func set_role(role: String) -> void:
		var r := String(role)
		if r == _role:
			return
		_role = r
		_covered = false
		_ink = IconRes.ink(false, _ready)
		# ★ 只有真有东西可画时才每帧跑 `_process`：九个格子全空 / 全是有字的页时
		#   （操作页 / 建筑页 / 科技页）一颗都不该空转。
		set_process(r != "" or _tex != null)
		queue_redraw()

	## 换成另一张剪影蒙版（空串 / 载不到 = 退回矢量图形）。
	func set_mask(path: String) -> void:
		var p := String(path)
		if p == _mask_path:
			return
		_mask_path = p
		_tex = null
		if p != "" and ResourceLoader.exists(p):
			var res: Variant = load(p)
			if res is Texture2D:
				_tex = res as Texture2D
		_covered = false
		_ink = IconRes.ink(false, _ready)
		set_process(_tex != null or _role != "")
		queue_redraw()

	## 这一格能不能招（锁住的行画暗一档）。
	func set_ready(v: bool) -> void:
		if v == _ready:
			return
		_ready = v
		_ink = IconRes.ink(_covered, _ready)
		queue_redraw()

	func role() -> String:
		return _role

	## 当前剪影蒙版路径（空串 = 这一格走矢量兜底）。测试用。
	func mask_path() -> String:
		return _mask_path

	## 当前线色（测试用）。
	func ink_color() -> Color:
		return _ink

	func _process(_dt: float) -> void:
		if _cell == null or (_role == "" and _tex == null):
			return
		var a = FillButtonRes.animator_of(_cell)
		var fill: float = a.fill() if a != null else 0.0
		# 图形是居中的：金盖过格子一半就是「盖过图形中心」。
		var covered: bool = fill >= 0.5
		if covered == _covered:
			return
		_covered = covered
		_ink = IconRes.ink(covered, _ready)
		queue_redraw()

	func _draw() -> void:
		var rect := Rect2(Vector2.ZERO, size)
		if _tex != null:
			IconRes.draw_mask(self, _tex, rect, _ink)
			return
		if _role == "":
			return
		IconRes.draw_into(self, rect, _role, _ink)
