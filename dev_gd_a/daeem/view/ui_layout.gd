## ui_layout.gd —— ★ 新 UI 的全部几何（逐像素抄自参考图，1920×1080 基准）
##
## 为什么单开一份常量：
##   参考图给的是**像素稿**（还专门标了「详细信息 1030×240」），把数字集中在这里之后，
##   改布局只动一个文件；测试也能直接对着参考图钉断言（见 tests/test_ui.gd）。
##   view/ 里其它文件**不写坐标字面量**，一律走这里的函数。
##
## ⚠️ 全部是 1920×1080 设计空间里的坐标。工程用 canvas_items + expand 拉伸，
##    窗口比例一变，设计空间就会向一侧变长 —— 所以每块面板都要说明自己「贴哪条边」
##    （见 apply_rect 的 anchor_right / anchor_bottom），多出来的空白留在中间。
##
## 参考图实测（1920×1080）：
##   设置    x 1840..1919, y 0..159        → 80×160
##   部队列表 x 0..119,   y 40..639        → 宽 120，10 行 × 60
##   地图    x 0..399,    y 680..1079      → 400×400（占位）
##   底栏    y 840..1079                   → 高 240
##   详细信息 x 400..1429                  → 1030×240（参考图上直接标了）
##   阵营    x 1430..1579                  → 宽 150
##   命令卡  x 1580..1819                  → 3×3，每格 80
##   页签    x 1820..1919                  → 宽 100，3 个 80 高的按钮
extends RefCounted

const DESIGN_W := 1920.0
const DESIGN_H := 1080.0


# ------------------------------------------------------------------
# 几何常量
# ------------------------------------------------------------------

## 左侧「部队1 ~ 部队10」整块面板
const SQUAD_RECT := Rect2(0.0, 40.0, 120.0, 600.0)
const SQUAD_SLOTS := 10
const SQUAD_ROW_H := 60.0

## 左下「地图」占位（参考图里是灰块 + 两个大字）
const MAP_RECT := Rect2(0.0, 680.0, 400.0, 400.0)

## 底栏（详细信息 / 阵营 / 命令卡 / 页签都住在这一条里）
const BAR_TOP := 840.0
const BAR_H := 240.0

## 详细信息面板：1030×240 是参考图标的数字
const DETAIL_RECT := Rect2(400.0, 840.0, 1030.0, 240.0)
const DETAIL_PAD := 10.0
const DETAIL_RIGHT_W := 350.0        # 右栏（资源 + 日志）固定宽度，左栏吃掉剩下的

## 阵营 / 盾徽 / 旗帜（本轮不做，只留位置）
const FACTION_RECT := Rect2(1430.0, 840.0, 150.0, 240.0)

## 命令卡：3×3，每格 80 —— 内容随右侧页签实时切换
const CARD_RECT := Rect2(1580.0, 840.0, 240.0, 240.0)
const CARD_COLS := 3
const CARD_ROWS := 3
const CARD_SLOTS := CARD_COLS * CARD_ROWS
## 九个格子的键位：按参考图排（上排 QWE / 中排 ASD / 下排 ZXC）
const CARD_KEYS := ["Q", "W", "E", "A", "S", "D", "Z", "X", "C"]

## 页签列（单位 / 建筑 / 科技）
const TABS_RECT := Rect2(1820.0, 840.0, 100.0, 240.0)
const TABS_COUNT := 3

## 设置按钮
const SETTINGS_RECT := Rect2(1840.0, 0.0, 80.0, 160.0)

## 招募队列的五个格子（星际争霸那套：1 个大格 + 4 个小格）
##
## ★ 画在「详细信息」面板**左栏的右侧**，只有选中的将领正在招募时才出现。
##   下面是**队列控件自身**的局部坐标 —— 控件本身由 detail_panel 摆进左栏。
const QUEUE_BIG := 64.0              # 正在读条的那个（大格子）
const QUEUE_SMALL := 30.0            # 排队的四个（小格子）
const QUEUE_GAP := 4.0
const QUEUE_SLOTS := 5               # 1 大 + 4 小 = 最多 5 个（与 recruit.queue_max 对应）
const QUEUE_W := QUEUE_BIG + QUEUE_GAP + QUEUE_SMALL * 2.0 + QUEUE_GAP
const QUEUE_H := QUEUE_BIG


# ------------------------------------------------------------------
# 局部矩形（面板内的相对坐标，给子控件用）
# ------------------------------------------------------------------

## 部队列表第 i 槽（相对面板）
static func squad_slot_local(i: int) -> Rect2:
	return Rect2(0.0, float(i) * SQUAD_ROW_H, SQUAD_RECT.size.x, SQUAD_ROW_H)


## 部队列表第 i 槽（设计空间，给边缘滚屏的判定用）
static func squad_slot_rect(i: int) -> Rect2:
	var r := squad_slot_local(i)
	r.position += SQUAD_RECT.position
	return r


## 命令卡第 i 格（相对面板）：行优先 —— 0..2 是 Q/W/E
static func card_cell_local(i: int) -> Rect2:
	var cell := CARD_RECT.size.x / float(CARD_COLS)
	var cx: int = i % CARD_COLS
	var cy: int = int(i / CARD_COLS)
	return Rect2(float(cx) * cell, float(cy) * cell, cell, cell)


## 命令卡第 i 格（设计空间）
static func card_cell_rect(i: int) -> Rect2:
	var r := card_cell_local(i)
	r.position += CARD_RECT.position
	return r


## 页签第 i 个按钮（相对面板）
static func tab_button_local(i: int) -> Rect2:
	var h := TABS_RECT.size.y / float(TABS_COUNT)
	return Rect2(0.0, float(i) * h, TABS_RECT.size.x, h)


## 页签第 i 个按钮（设计空间）
static func tab_button_rect(i: int) -> Rect2:
	var r := tab_button_local(i)
	r.position += TABS_RECT.position
	return r


## 招募队列第 i 个格子（0 = 正在读条的大格，1..4 = 排队的四个小格）。
## 坐标相对**队列控件自身**（2×2 的小格排在右边，上下刚好与大格对齐）。
static func queue_cell_rect(i: int) -> Rect2:
	if i <= 0:
		return Rect2(0.0, 0.0, QUEUE_BIG, QUEUE_BIG)
	var k := i - 1
	var col := k % 2
	var row := int(k / 2)
	return Rect2(
		QUEUE_BIG + QUEUE_GAP + float(col) * (QUEUE_SMALL + QUEUE_GAP),
		float(row) * (QUEUE_SMALL + QUEUE_GAP),
		QUEUE_SMALL, QUEUE_SMALL)


# ------------------------------------------------------------------
# 摆放
# ------------------------------------------------------------------

## 把「设计空间矩形」贴到控件上。
##
## anchor_right / anchor_bottom 说明这块面板贴的是右/下边还是左/上边：
##   左上的东西（部队列表、设置）贴左上；底栏与右侧那一列贴右下 ——
##   这样窗口变成非 16:9 时，底栏仍然贴着屏幕底部，不会被拉走。
static func apply_rect(c: Control, r: Rect2, anchor_right: bool = false, anchor_bottom: bool = false) -> void:
	if anchor_right:
		c.anchor_left = 1.0
		c.anchor_right = 1.0
		c.offset_left = r.position.x - DESIGN_W
		c.offset_right = r.position.x - DESIGN_W + r.size.x
	else:
		c.anchor_left = 0.0
		c.anchor_right = 0.0
		c.offset_left = r.position.x
		c.offset_right = r.position.x + r.size.x
	if anchor_bottom:
		c.anchor_top = 1.0
		c.anchor_bottom = 1.0
		c.offset_top = r.position.y - DESIGN_H
		c.offset_bottom = r.position.y - DESIGN_H + r.size.y
	else:
		c.anchor_top = 0.0
		c.anchor_bottom = 0.0
		c.offset_top = r.position.y
		c.offset_bottom = r.position.y + r.size.y


# ------------------------------------------------------------------
# 鼠标：哪些地方要「让路」
# ------------------------------------------------------------------

## 可交互控件的矩形（设计空间，已按当前设计空间大小做了贴边修正）。
##
## ★ 只有**真正能点**的控件才让路（部队行 / 命令卡格 / 页签 / 设置）。
##   详细信息与阵营面板只有文字，鼠标停在上面照样允许边缘滚屏 ——
##   否则底栏把屏幕下沿整个盖住，鼠标永远滚不到地图下方（这条是踩过的坑）。
static func interactive_rects(view_size: Vector2) -> Array[Rect2]:
	var shift := Vector2(maxf(0.0, view_size.x - DESIGN_W), maxf(0.0, view_size.y - DESIGN_H))
	var out: Array[Rect2] = []
	for i in SQUAD_SLOTS:
		out.append(squad_slot_rect(i))                      # 贴左上，不修正
	for i in CARD_SLOTS:
		var r := card_cell_rect(i)                          # 贴右下
		r.position += shift
		out.append(r)
	for i in TABS_COUNT:
		var r2 := tab_button_rect(i)                        # 贴右下
		r2.position += shift
		out.append(r2)
	var s := SETTINGS_RECT
	s.position.x += shift.x                                     # 贴右上
	out.append(s)
	return out


## 某个点是否落在任一可交互控件上
static func point_hits_any(rects: Array[Rect2], p: Vector2) -> bool:
	for r in rects:
		if r.has_point(p):
			return true
	return false


## 这个点是不是落在**屏幕最外圈**（edge_size 像素之内）。
##
## ★ 为什么需要这条规则（手玩报的 bug）：左侧「部队 1~10」（将领按钮那一列）是
##   x 0..119 的控件，它整条压着屏幕左边缘 —— 于是鼠标推到左边缘那一段永远被
##   判成「在控件上，别滚屏」，左边缘那一片地图永远滚不到。
##   凡「贴到屏幕边缘的控件」都有这个毛病（命令卡压下边缘、设置压上边缘）。
## ★ 判据与 camera_rig._edge_scroll 的 margin **同源**（config.camera.edge_size）：
##   滚屏的触发区与「不许拦」的区域必须是同一个，否则就会出现
##   「鼠标明明在边缘却滚不动」（小于）或者「控件明明在那儿却滚走了」（大于）。
static func in_edge_band(view_size: Vector2, p: Vector2, margin: float) -> bool:
	if margin <= 0.0:
		return false
	if p.x < margin or p.y < margin:
		return true
	if p.x > view_size.x - margin or p.y > view_size.y - margin:
		return true
	return false
