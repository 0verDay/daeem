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
##   小地图  x 0..399,    y 680..1079      → 400×400（view/minimap.gd 自己画内容）
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

## 左下小地图（x 0..399、贴屏幕下沿）。里面的地图按比例缩放并居中，见 view/minimap.gd。
const MAP_RECT := Rect2(0.0, 680.0, 400.0, 400.0)

## 底栏（详细信息 / 阵营 / 命令卡 / 页签都住在这一条里）
const BAR_TOP := 840.0
const BAR_H := 240.0

## 详细信息面板：1030×240 是参考图标的数字
const DETAIL_RECT := Rect2(400.0, 840.0, 1030.0, 240.0)
const DETAIL_PAD := 10.0
## ★ 第三轮改版（照新参考图）：面板内一刀切成左右两栏 ——
##   左栏 = 「当前展开的那支部队」+ 下方「其余选中部队的将领头像网格」
##          （点一格 = 换展开哪一支；**展开中的那一支不出现在网格里**）
##   右栏 = 「选中单位的头像 + 名称 + buff 图标 + 详细信息（数值）」
##
## ★★ 两栏比例**按参考图逐像素量出来的**（参考图 1920×1080，就是设计空间 1:1）。
##   面板 x 400..1429（宽 1030）、y 840..1079（高 240）；
##   两栏之间那条竖直分隔线落在 **x = 787**（它在 y 850..1075 整段都有 225px 的深色，
##   而 x=905 只有 102px ⇒ 那是格子的边缘，不是分隔线）。
##   ⇒ 左栏（含边距）= 787 - 400 = **387**；右栏 = 1429 - 787 = **642**，约 **37.5 : 62.5**。
##   本工程内容区 1010px 按这个比例 ⇒ 左 **350** / 右 **645**，加上 15px 的缝：
##     左栏 350 + 缝 15 + 右栏 645 = 1010 = 内容宽
##     （分隔线因此落在内容区 x=350，与参考图量出来的 377/1010 ≈ 37.3% 对齐）
##   ⚠️ GDScript 常量不许互相推算，所以这三个数是**算好写死的**，改一个就要改另一个。
##   ⚠️ 之前四版凭感觉 / 量错写成 605/395、420/575、290/705、260/735 ——
##      手玩四次指出「左侧明显大了」。以后改这三个数，只认这条注释里的量法。
const DETAIL_GAP := 15.0
const DETAIL_LEFT_W := 350.0
const DETAIL_RIGHT_W := 645.0

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

## ------------------------------------------------------------------
## 详细信息**左栏**（见 view/unit_roster.gd 与 view/troop_grid.gd）
##
## ★★ 第四轮改版（照新参考图逐像素重量的）：左栏就是 **1 + 3×3 = 10 个格子**，
##    和「玩家部队上限 10 支」一一对应。参考图 1920×1080 实测（用像素扫描量出来的）：
##
##      y=860 起：左上**第 1 格** —— x 415..454 是 40×40 方框，它右边是
##                「将领名称 1/11」那一行（方框 + 一行字）
##      y=915 / 970 / 1025 起：下面 **3 列 × 3 行 = 9 格**，列 x 415 / 536 / 662、
##                每格又是「40×40 方框 + 右边一行字」，共 10 个方框。
##
##   两种语义共用这 10 个格子（由 hud 决定画什么，见 view/troop_grid.gd 的 mode）：
##     · **选中多支部队**：左上第 1 格 = 当前展开那支部队的将领；
##       下面 3×3 = 其余选中部队的将领（点一格 = 换展开哪一支）。
##     · **只选中一支部队**：左上第 1 格 = 那支部队的将领；
##       下面 3×3 = 这支部队的**单位**（点一格 = 右栏切到那个单位）；
##       单位超过 9 个时靠**滚轮翻页**（一次一页 9 格，见 GRID_PAGE）。
##
## ⚠️ 单位编制上限（手玩原话：「y 是该将领的编制上限，目前所有将领的编制上限都暂时为 11」）
## ------------------------------------------------------------------
const UNIT_CAP := 11

## 左栏上半：左上那一格（= 当前展开的部队 / 唯一选中的部队的将领格）
## ★ 参考图实测：方框 40×40 在 x 415..454、y 860..899；它右边**两行**字 ——
##   「将领名称」在 y 885..899、「1/11」在 y 902..911（量出来的像素段）。
const ROSTER_CELL_AVATAR := 40.0
const ROSTER_CELL_TEXT_X := 48.0     # 文字那两行的左边（= 方框 40 + 缝 8）
const ROSTER_ID_W := 56.0            # 第一行（名字）能写到哪
## 文字那两行的基线（相对**方框顶边**）——
##   ★ 手玩原话：「对齐其对应左侧头像居中」⇒ 两行合起来作为一块，与 40 高的方框**垂直居中**。
##   算法：块高 = 2×FS_SMALL(13) + 行间隙(5) = 31 ⇒ 块顶 = (40-31)/2 ≈ 4.5
##         第一行基线 = 4.5 + 13(cap) = 17.5 ≈ 18；第二行 = 18 + 13 + 5 = 36。
##   （参考图上第一行落在 y 880..891、方框 y 880..919，也基本就是居中偏上。）
const ROSTER_ID_Y := 18.0
const ROSTER_COUNT_Y := 36.0
## 「1/11」与名字**同一个左边**（参考图上这两行的左边缘是对齐的）
const ROSTER_COUNT_X := 48.0
const ROSTER_COUNT_W := 56.0
## 左栏上半那一段的总高度
const ROSTER_DETAIL_H := 40.0

## 左栏下半那 9 格的网格（3 列 × 3 行）
##
## ★★ 参考图实测（逐像素扫出来的，别再凭感觉改）：
##   3 列 × 3 行，方框 40×40 在 x 415 / 536 / 662，行 y 915 / 970 / 1025；
##   每格 = 「方框 + 右边**两行**字」：
##     第一行「将领名称」x 467..512、y 920..931
##     第二行「1/11」   x 467..481、y 942..948
##   ⇒ 文字左边 = 方框右边缘 + 13px；两行都与方框**垂直居中**（不是只在左上角）。
##   ⇒ 格子列距 = 121px，其中 40 是方框、剩下 81 给文字 —— 本工程左栏只有 350，
##     按同样的比例压成：格 116（40 方框 + 8 缝 + 56 文字 + 12 到下一格）。
## ⚠️ 文字可写宽度**必须**是 56：写 24 会把「将领名称」截成两个字（手玩报过
##   「左栏的字太小」），写 64 又会盖到右边那格的方框上（手玩报过「后两列没字」）。
const TROOP_GRID_COLS := 3
const TROOP_GRID_ROWS := 3
const TROOP_GRID_SLOTS := TROOP_GRID_COLS * TROOP_GRID_ROWS
## 一页 = 9 格（单选时滚轮翻页的单位数）
const GRID_PAGE := TROOP_GRID_SLOTS
const TROOP_CELL_W := 116.0          # (350 - 2) / 3
const TROOP_CELL_H := 44.0           # 每行 44 高（40 的方框 + 4 的缝）
const TROOP_CELL_GAP := 0.0
const TROOP_AVATAR := 40.0
## 格子里的文字：左边（= 方框 40 + 缝 8）、可写宽、两行的基线
const TROOP_NAME_X := 48.0
const TROOP_NAME_W := 56.0
## 两行文字的基线（相对**方框顶边**）：两行作为一块与 40 高的方框垂直居中
## （算法同 ROSTER_ID_Y 那一段：块高 31、块顶 4.5）
const TROOP_NAME_Y := 18.0           # 第一行（单位 / 将领名）
const TROOP_NAME2_Y := 36.0          # 第二行（「x/y」或血量）
## 左栏上半与下半之间的缝（内容高 220 = 40 + 15 + 3×44 + 剩 33）
const TROOP_ROW_GAP := 15.0
## 网格控件的固定高度 = 3 行（不高随内容变，免得选中 1 支时整块跳一下）
const TROOP_GRID_H := 3.0 * TROOP_CELL_H

## ------------------------------------------------------------------
## 右栏（选中单位）：头像 / 名称 / buff / 数值
##
## ★★ 参考图实测（逐像素扫出来的线段，别再凭感觉改）：
##   单位头像方框 **100×100**，x 806..905、y 860..959
##     ⇒ 内容区坐标 (6, 10)..(106, 110)（面板内容区左上 = (796, 850)）
##   单位名称 「单位名称」四个字 x 924..1034、y 881..908（字高约 28 ⇒ 字号 ~29）
##   buff 三格 **30×30**，x 924..953 / 972..1001 / 1020..1049，y 930..959（格距 48）
##   「详细信息」方框 **606×90**，x 806..1411、y 975..1064 ⇒ 内容区 (6, 115) 起
##
## ⚠️ 手玩报过两次「头像不对」：
##   ① 方框里那个字用的是 `FS_BIG(44)`，而方框只有 40×40 —— 字装不下、被裁成右下角一块；
##   ② 方框本身就画小了（40×40），参考图上它是 **100×100**。这一版按参考图改成 100。
## ------------------------------------------------------------------
const UNIT_AVATAR := 100.0           # 选中单位的头像方框（正方形，参考图 100×100）
const UNIT_AVATAR_X := 0.0           # 贴右栏左边（参考图里就在内容区左边缘）
const UNIT_AVATAR_Y := 8.0           # 上面留一点（参考图 10）
const UNIT_NAME_X := 118.0           # 名字的左边（参考图：头像右边 18px）
const UNIT_NAME_Y := 26.0
## 名称最多写到哪：与右栏右边缘留一点缝
const UNIT_NAME_W := 220.0
const BUFF_SIZE := 30.0              # buff 图标一格（参考图 30×30）
const BUFF_GAP := 18.0               # 格距 48 = 30 + 18
const BUFF_X := 136.0                # 三个 buff 从这一列开始排（头像右边 36）
const BUFF_Y := 76.0                 # 与头像**下半**同一水平线（76+30 = 106 ≤ 头像下缘 108）
## buff 先做几个**无效占位**（手玩原话：「可以先做几个无效果的 buff 凑数」）
const BUFF_SLOTS := 3
## 「详细信息」方框：**横跨整个右栏**（参考图 606 宽、90 高，左边缘与头像对齐）
## ⚠️ DETAIL_BODY_Y + DETAIL_BODY_H 必须 ≤ 220（本栏内容高）。
const DETAIL_BODY_X := 0.0
const DETAIL_BODY_W := 606.0
const DETAIL_BODY_Y := 115.0
const DETAIL_BODY_H := 90.0
## 招募队列（1 大 + 4 小）在右栏里的位置：贴右栏**右上角**（别越过右栏右边缘）
const QUEUE_X := 493.0
const QUEUE_Y := 0.0


# ------------------------------------------------------------------
# 局部矩形（面板内的相对坐标，给子控件用）
# ------------------------------------------------------------------

## 左栏上半那一段的局部矩形（相对 panel_content()）
static func roster_detail_rect() -> Rect2:
	return Rect2(0.0, 0.0, DETAIL_LEFT_W, ROSTER_DETAIL_H)


## 左栏下半那个网格的局部矩形（相对 panel_content()）
static func troop_grid_rect() -> Rect2:
	return Rect2(0.0, ROSTER_DETAIL_H + TROOP_ROW_GAP, DETAIL_LEFT_W, TROOP_GRID_H)


## 右栏的局部矩形（相对 panel_content()）
static func unit_detail_rect() -> Rect2:
	return Rect2(DETAIL_LEFT_W + DETAIL_GAP, 0.0, DETAIL_RIGHT_W, 220.0)


## 网格第 i 格（相对**网格控件自身**）—— 3 列 × 3 行，行优先
static func troop_cell_rect(i: int) -> Rect2:
	var col: int = i % TROOP_GRID_COLS
	var row: int = int(i / TROOP_GRID_COLS)
	return Rect2(
		float(col) * TROOP_CELL_W,
		float(row) * TROOP_CELL_H,
		TROOP_CELL_W - 4.0, TROOP_CELL_H)


## 网格第 i 格里的方框（相对**网格控件自身**）：40×40，贴格子左上角
static func troop_avatar_rect(i: int) -> Rect2:
	var c := troop_cell_rect(i)
	return Rect2(c.position.x, c.position.y, TROOP_AVATAR, TROOP_AVATAR)


## 网格第 i 格右边那**两行文字**所在的那一块（相对**网格控件自身**）：
## 左边 = 这一格自己的左边 + TROOP_NAME_X，顶边 = 这一格自己的顶边；高按方框算（40）。
##
## ★★ 这个函数是**补 bug 补出来的**（手玩报的：「选中多个单位或将领时，第二、三列的文字
##    会挤到第一列去」）：`TROOP_NAME_X / TROOP_NAME_Y` 是**格子内**的相对量，
##    画的时候必须先加上「第几列 / 第几行」的偏移（`troop_cell_rect(i).position`）。
##    原来 `_draw_cell()` 里只写了 `Vector2(TROOP_NAME_X, av.position.y + TROOP_NAME_Y)`
##    —— y 加了格子偏移、x 没加 ⇒ 三列的名字全画在第 1 列的位置上
##    （只有 1 格时看着是对的，所以「选中一个单位」看不出来，多选才暴露）。
## ⛔ 以后要在格子里画字，一律走这个函数，别自己拼 TROOP_NAME_X。
static func troop_name_rect(i: int) -> Rect2:
	var av := troop_avatar_rect(i)
	return Rect2(av.position.x + TROOP_NAME_X, av.position.y, TROOP_NAME_W, TROOP_AVATAR)


## 左栏上半：本段第 1 个方块（展开那支部队的将领格）—— 40×40，贴在左上角。
## ★ 这**不是**「额外画的『将』大方块」：它就是参考图上那一段最左边的那个方块
##   （x 415..454），也是整段里唯一一个方块；它的右边是「将领名称 1/11」那一行文字。
static func roster_cell_avatar_rect() -> Rect2:
	return Rect2(0.0, 0.0, ROSTER_CELL_AVATAR, ROSTER_CELL_AVATAR)


## 设计空间里的「详细信息面板内容区」左上角（面板本身在 DETAIL_RECT，内有 DETAIL_PAD 的边距）
static func panel_content_pos() -> Vector2:
	return DETAIL_RECT.position + Vector2(DETAIL_PAD, DETAIL_PAD)


## 设计空间里的网格第 i 格（给 interactive_rects 用）
static func troop_cell_global_rect(i: int) -> Rect2:
	var r := troop_cell_rect(i)
	r.position += panel_content_pos() + troop_grid_rect().position
	return r


# ------------------------------------------------------------------
# 旧的几何常量（招募队列 / 命令卡 / 页签仍在用）
# ------------------------------------------------------------------

## 招募队列的五个格子（星际争霸那套：1 个大格 + 4 个小格）
##
## ★ 本轮改版后它画在**详细信息右栏的右上角**（盖在单位名称那一行右边），
##   只有选中的将领正在招募时才出现。
##   下面是**队列控件自身**的局部坐标 —— 控件本身由 detail_panel 摆进右栏。
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
## ★ 只有**真正能点**的控件才让路（部队行 / 命令卡格 / 页签 / 设置 / 小地图 /
##   详细信息左栏下方的**将领头像网格**）。
##   详细信息面板的其余部分只有文字与方块，鼠标停在上面照样允许边缘滚屏 ——
##   否则底栏把屏幕下沿整个盖住，鼠标永远滚不到地图下方（这条是踩过的坑）。
##
## ★★ 小地图是**后加进这份名单**的（它现在真的能点了：左键点击 = 移动镜头）。
##   为什么必须加：它在屏幕最左下角，贴着左边缘与下边缘 ——
##   鼠标停在小地图上时若还允许边缘滚屏，镜头会一边跟着点击跳、一边被边缘推走。
##   ⚠️ 但它照样逃不过 `in_edge_band` 那条例外：最外圈 44px 内仍然允许滚屏
##   （那是所有贴边控件的共同规则，见 in_edge_band 的说明）。
##
## ★★ 网格（TROOP_GRID_SLOTS 格）是**第三轮改版**加进来的：点一格 = 换左栏展开哪支部队。
##   它整块都在详细信息面板里，所以「让路」的副作用是把面板中间那一大片也拦掉了 ——
##   这是有意的：鼠标停在能点的格子上时不该同时被边缘推着滚屏（与小地图同一条理由）。
##   面板**其余**的地方（右栏、左栏上半）仍然是「只有文字 → 照样滚屏」。
static func interactive_rects(view_size: Vector2) -> Array[Rect2]:
	var shift := Vector2(maxf(0.0, view_size.x - DESIGN_W), maxf(0.0, view_size.y - DESIGN_H))
	var out: Array[Rect2] = []
	for i in SQUAD_SLOTS:
		out.append(squad_slot_rect(i))                      # 贴左上，不修正
	out.append(MAP_RECT)                                        # 左下小地图，贴左下
	for i in CARD_SLOTS:
		var r := card_cell_rect(i)                          # 贴右下
		r.position += shift
		out.append(r)
	for i in TABS_COUNT:
		var r2 := tab_button_rect(i)                        # 贴右下
		r2.position += shift
		out.append(r2)
	for i in TROOP_GRID_SLOTS:
		out.append(troop_cell_global_rect(i))               # 详细信息左栏，贴左下
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
