## ui_layout.gd —— ★ 新 UI 的全部几何（逐像素抄自参考图，1920×1080 基准）
##
## 为什么单开一份常量：
##   参考图给的是**像素稿**（还专门标了「详细信息 1030×240」），把数字集中在这里之后，
##   改布局只动一个文件；测试也能直接对着参考图钉断言（见 tests/test_ui.gd）。
##   view/ 里其它文件**不写坐标字面量**，一律走这里的函数。
##   ⚠️ 2026.10.20 按用户要求改了底栏：右下整组按 13/12 放大到 260 高、顶边抬到 820；
##      详细信息宽度 1030 → 988（右缘左移给放大的阵营列让位），高度保持 260。
##
## ⚠️ 全部是 1920×1080 设计空间里的坐标。工程用 viewport + expand 拉伸，
##    窗口比例一变，设计空间就会向一侧变长 —— 所以每块面板都要说明自己「贴哪条边」
##    （见 apply_rect 的 anchor_right / anchor_bottom），多出来的空白留在中间。
##    ★ 详细信息面板是**固定 988×260**（贴左、贴底），不跟着视口横向拉伸。
##
## 参考图实测（1920×1080；★ = 2026.10.20 改后的值）：
##   设置    x 1840..1919, y 0..159        → 80×160
##   部队列表 x 1680..1919, y 180..739      → 右侧 240 宽，10 行 × 56（★ 紧贴右缘）
##   小地图  x 0..399,    y 680..1079      → 400×400（view/minimap.gd 自己画内容）
##   底栏    y 820..1079                   → 高 260（★）
##   详细信息 x 400..1387                   → 988×260（★ 右缘 1388）
##   阵营    x 1389.17..1551.67             → 宽 162.5（★ 13/12 放大）
##   命令卡  x 1551.67..1811.67            → 3×3，每格 86.67（★）
##   页签    x 1811.67..1920              → 宽 108.33，3 个 86.67 高的按钮（★）
extends RefCounted

const DESIGN_W := 1920.0
const DESIGN_H := 1080.0

## ------------------------------------------------------------------
## 目标条（战役 / 合作）：屏幕**左上角**，两行文字（※目标 / - 描述）。
##
## ★ 需求（2026.10.20 修订）：位置移到左上角；格式固定两行，描述是自由文本，
##   进度信息由描述自己携带（不再单独画进度条）。
## ★ 只有「这一局有目标」时才显示（老路径 / 自由对战没有 objective_state ⇒ 整块隐藏）。
## ★ 它**不**进 `interactive_rects`：整块只有字、点不动，鼠标停上去照样允许边缘滚屏。
## ------------------------------------------------------------------
const OBJECTIVE_RECT := Rect2(20.0, 16.0, 560.0, 96.0)
const OBJECTIVE_PAD := 12.0


# ------------------------------------------------------------------
# 几何常量
# ------------------------------------------------------------------

## 右侧「部队 1 ~ 6」整块面板（**紧贴屏幕右边缘**）
## ★ 槽数 = 6：与大本营 3 级的将领上限（config 的 max_generals 2/5/6）对上，
##   数字键也只到 6（见 input_controller.handle_key）。
const SQUAD_SLOTS := 6
## ★ 行高 = 手机端的**触摸命中高度**：整行都是按钮，56 在手机上太难点中，
##   加高到 88（6 行合计 528，面板底 708，仍与底栏 820 留出 112 的间隙）。
##   数字块 / 分隔线 / 两行文字都按行高居中（见 troop_row.gd），改这一个数即可整体伸缩。
const SQUAD_ROW_H := 88.0
const SQUAD_RECT := Rect2(1680.0, 180.0, 240.0, SQUAD_SLOTS * SQUAD_ROW_H)
## 单行内部（相对行自身）：
##   数字块 44×44 贴右；最右竖线 = 泛光起点；数字左边的灰线 = 分隔线；
##   左侧文字两行 = 将领名 / 当前编制。
const SQUAD_NUM_SIZE := 44.0
const SQUAD_NUM_X := 186.0
const SQUAD_DIVIDER_X := 178.0
const SQUAD_EDGE_X := 238.0
const SQUAD_TEXT_X := 8.0
const SQUAD_TEXT_W := 164.0

## 左下小地图（x 0..399、贴屏幕下沿）。里面的地图按比例缩放并居中，见 view/minimap.gd。
const MAP_RECT := Rect2(0.0, 680.0, 400.0, 400.0)

## 底栏（详细信息 / 阵营 / 命令卡 / 页签都住在这一条里）
## ★ 2026.10.20：右下整组按 13/12 等比放大到 260 高，顶边从 840 抬到 820；
##   详细信息保持 260 高、宽度从 1030 缩到 988（右缘左移，给放大后的阵营列让位）。
const BAR_TOP := 820.0
const BAR_H := 260.0

## 详细信息面板：参考图标的是 1030×240；★★ 本版按需求**加高到 260**。
##
## ★ 为什么加高（用户原话：「能否强制让所有文本都挤进详细信息栏（在竖直方向上可以适当
##   缩放）……也可以适当扩大详细信息面板的竖直方向长度」）：
##   区划详情在最坏情况（有特化状态 + 三行产能 + 人口 / 人口上限）是 **7 行 13 号字**
##   = 7×14 = 98px，而右栏原有的数值框可视高只有 88px ⇒ 最后一行必然被裁
##   （表现就是「最后一行跑到面板外 / 看不见了」）。加高 20px 之后可视高 = 112px，
##   7 行**原字号**就装得下，不用缩字（缩放只是兜底，见 detail_panel._fit_body_text）。
##
## ★ 底栏贴屏幕下沿（`apply_rect(..., anchor_bottom=true)`）⇒ 面板变高是**向上长**：
##   底边仍钉在屏幕底部，顶边从 y=840 抬到 y=820，不会掉出屏幕。
## ★ 2026.10.20 修订：右下整组放大到 260 高、左缘从 1430 左移到 1389.1667；
##   详细信息保持 260 高，宽度 1030 → 988（右缘 1388），给放大的阵营列让出约 1.17px 缝。
## ★★ 本版：阵营盾徽移到**详细信息栏左侧、紧贴地图**（见 FACTION_RECT）——
##   盾徽占 x 400..562.5，详细信息整体右移到 x=562.5（宽度仍 988），
##   右缘 1550.5 与命令卡（1551.6667）之间仍是约 1.17px 的缝。
const DETAIL_RECT := Rect2(562.5, 820.0, 988.0, 260.0)
const DETAIL_PAD := 10.0
## 右栏内容高 = 面板高 − 上下边距（260 − 2×10 = 240）。
## ⚠️ 这个数以前是**各处写死的 220**（`right_column_rect()`、提示带下沿、测试断言里都有），
##    现在只留这一处；改面板高就只改上面那个 260。
const DETAIL_CONTENT_H := DETAIL_RECT.size.y - 2.0 * DETAIL_PAD
## ★ 第三轮改版（照新参考图）：面板内一刀切成左右两栏 ——
##   左栏 = 「当前展开的那支部队」+ 下方「其余选中部队的将领头像网格」
##          （点一格 = 换展开哪一支；**展开中的那一支不出现在网格里**）
##   右栏 = 「选中单位的头像 + 名称 + buff 图标 + 详细信息（数值）」
##
## ★★ 两栏比例**按参考图逐像素量出来的**（参考图 1920×1080，就是设计空间 1:1）。
##   面板 x 400..1429（宽 1030）、y 840..1079（高 240）；
##   ★ 2026.10.20 面板改为 988×260（内容区 968×240），左右比例不变。
##   两栏之间那条竖直分隔线落在 **x = 787**（它在 y 850..1075 整段都有 225px 的深色，
##   而 x=905 只有 102px ⇒ 那是格子的边缘，不是分隔线）。
##   ⇒ 左栏（含边距）= 787 - 400 = **387**；右栏 = 1429 - 787 = **642**，约 **37.5 : 62.5**。
##   本工程原内容区 1010px 按这个比例 ⇒ 左 **350** / 右 **645**，加上 15px 的缝：
##     左栏 350 + 缝 15 + 右栏 645 = 1010 = 原内容宽
##     （★ 现在内容宽 968 = 350 + 15 + 603；比例仍是 36.2 : 62.3）
##   ⚠️ GDScript 常量不许互相推算，所以这三个数是**算好写死的**，改一个就要改另一个。
##   ⚠️ 之前四版凭感觉 / 量错写成 605/395、420/575、290/705、260/735 ——
##      手玩四次指出「左侧明显大了」。以后改这三个数，只认这条注释里的量法。
const DETAIL_GAP := 15.0
const DETAIL_LEFT_W := 350.0
## 右栏 = 968 − 350 − 15 = 603（968 = 988 − 2×10）。
const DETAIL_RIGHT_W := 603.0

## 阵营 / 盾徽 / 旗帜：**贴在详细信息栏左侧、紧贴地图**（用户本版需求）。
## ★ 左缘 = 地图占位右缘 400，右缘 562.5 = 详细信息左缘；两块严丝合缝。
## ★ 尺寸沿用 13/12 等比放大那版（162.5×260），只换位置。
const FACTION_RECT := Rect2(400.0, 820.0, 162.5, 260.0)

## ------------------------------------------------------------------
## 资源面板（粮食 / 黄金）—— 按需求新增
##
## 需求原话（第一版）：「在详细信息界面上方紧贴地图的地方加上资源显示面板，
##                     只需要显示粮食和黄金两个资源，横着显示」；
## 需求原话（第二版，本版）：「面板不需要那么长，粮食和黄金栏改为竖着排列」。
##
## ★ 落在哪：详细信息面板**左段的正上方**，下缘与面板顶边（820）齐平 —— 「紧贴」就是
##   这一条边，不叠 1px；左边缘与面板对齐（x = 400，也就是地图占位的右缘），
##   所以它既不压住左下小地图那 400px，也不往右伸长。
## ★ 尺寸 200×56：两行**竖着排**（每行 20 高 + 行距 6 + 上下各 5 的留白），
##   再不用横着铺 1030 —— 「不需要那么长」就是这一条。
## ★★ 本版：宽度从 200 **缩到 162.5**，与右侧阵营盾徽旗帜**左右平齐**
##   （同左缘 x=400、同宽 162.5 ⇒ 右缘都在 562.5）。文字可写宽同步收窄到 128。
## ★ 每行 = 色块（20×20）+ 右边一行字（15 号，实测行高 16）。
##   ⚠️ 子控件的 size **必须在 add_child 之后设**（进树前继承不到中文字体，
##      Label 会按兜底字体算一次最小高度并把 set_size 夹掉 —— 实测踩过）。
##   ⚠️ 它**不进** `interactive_rects`（见那个函数）：整块只有字和色块、点不动，
##      鼠标停上去照样允许边缘滚屏 —— 与「详细信息面板只有文字的地方让路」同一条规矩。
const RES_BAR_RECT := Rect2(400.0, 764.0, 162.5, 56.0)
## 色块（粮食 / 黄金各一个 20×20）边长
const RES_ICON := 20.0
## 两行的 y（相对资源面板自身）：第一行 5、行距 26 ⇒ 第二行 31，下缘 31+20 = 51 ≤ 56
const RES_ROW_Y := 5.0
const RES_ROW2_Y := 31.0
## 颜色那一行字：左边（= 色块 20 + 缝 6）与可写宽（「粮食 1234」15 号字实测 78px）。
## ★ 资源条宽度锁死在 162.5（与右侧阵营盾徽左右平齐，见上面那条），所以文字区
##   26 + 134 = 160，右侧只留 2.5px 边距 —— **这是硬上限，别再往上加**。
## ★★ 2026.10.29：数字后面多了一段「(+n)」每秒净增长，于是这一行改成 13 号字
##   （见 view/hud.gd 的 `_build_resource_bar`）。实测（SimHei 13px）：
##   「粮食 12345(+3.2)」≈122px、「黄金 12345(-12.3)」≈130px ≤ 134 ✓；
##   15 号字时 5 位数要 149px，装不下。
const RES_TEXT_X := 26.0
const RES_TEXT_W := 134.0

## 命令卡：3×3，每格 260/3 ≈ 86.6667 —— 内容随右侧页签实时切换
## ★ 按 13/12 等比放大：240×240 → 260×260，左缘 1580 → 1551.6667。
const CARD_RECT := Rect2(1551.6667, 820.0, 260.0, 260.0)
const CARD_COLS := 3
const CARD_ROWS := 3
const CARD_SLOTS := CARD_COLS * CARD_ROWS
## 九个格子的键位：按参考图排（上排 QWE / 中排 ASD / 下排 ZXC）
const CARD_KEYS := ["Q", "W", "E", "A", "S", "D", "Z", "X", "C"]
## ★ 键位 → **视觉格子序号**（0..8）。命令卡与科技九格共用同一套。
const CARD_KEY_TO_SLOT := {
	KEY_Q: 0, KEY_W: 1, KEY_E: 2,
	KEY_A: 3, KEY_S: 4, KEY_D: 5,
	KEY_Z: 6, KEY_X: 7, KEY_C: 8,
}

## ------------------------------------------------------------------
## ★★ 悬停详情面板（右下角命令卡**正上方**）—— 本版新增
##
## 需求原话：「为右下角面板中的按钮添加悬停显示，悬停显示显示在右下角面板上方，
##           宽度与右下角面板宽度相同，竖直方向距离你自己定，需要根据悬停详细
##           信息文本动态缩放」。
## ★★ 需求补充（用户原话）：「**水平距离上要把旁边的页签栏也对齐上**」——
##   于是面板的水平范围 = **命令卡 + 右边那一列页签**整段：
##     左缘 = `CARD_RECT.position.x`（1580，命令卡左缘）
##     右缘 = `TABS_RECT` 的右缘（1920，页签列右缘 = 屏幕右缘）
##     ⇒ 宽度 = `HOVER_W` = **340**（= 命令卡 240 + 页签列 100）
##   ⚠️ 第一版只对齐了命令卡（240 宽），右缘停在 1820 —— 页签列那 100px 露在外面，
##      用户看着那一条没对齐。现在两侧分别与「命令卡左缘 / 页签列右缘」拉齐。
##
## ★ 「右下角面板」里的按钮 = **命令卡**那 3×3（`CARD_RECT`：x 1580..1819、y 840..1079）；
##   科技页那九格与它**逐像素重合**（换页时看不出换了控件，见 view/tech_grid.gd 的文件头），
##   所以两者共用这同一块悬停面板。
##   ⚠️ 页签本身**没有**悬停详情（它是「换页」用的，不是命令卡里的按钮）——
##      本版只给四类**格子内容**配了文案，见 hud._hover_detail；
##      面板盖住那一条只是**水平对齐**，不影响页签可点。
##
## ★ 竖直方向：面板**下缘**与命令卡顶边留 `HOVER_GAP`（8px，需求说「自己定」），
##   高度由调用方按文本算好传给 `hover_rect(h)` ⇒ 文字越多、面板**向上越长**：
##   底边钉住不动，所以既不会压住命令卡，也不会掉出屏幕（与详细信息面板
##   「贴下沿、向上长」是同一条思路）。
##
## ★ 贴右下角：`apply_rect(..., anchor_right = true, anchor_bottom = true)` ——
##   窗口变宽 / 变高时它跟着命令卡走，永远停在命令卡**正上方**、右缘永远与页签列齐平。
## ------------------------------------------------------------------
## 368.3333：命令卡左缘 → 页签列右缘（= 屏幕右缘）那一整段。⚠️ 写成 `DESIGN_W − 左缘`
## 而不是 `CARD_RECT.size.x`：右缘钉的是**页签列的右缘**，不是命令卡右缘。
const HOVER_W := DESIGN_W - CARD_RECT.position.x
const HOVER_GAP := 8.0                          # 与命令卡顶边的竖直距离（需求里说「自己定」）
const HOVER_PAD := 8.0                          # 文字离面板四边的留白
const HOVER_TITLE_GAP := 5.0                    # 标题与正文之间的缝
## 812：命令卡顶边 820 − 8。右下组放大后浮窗整体上移 20px。
const HOVER_BOTTOM := CARD_RECT.position.y - HOVER_GAP
const HOVER_MIN_H := 32.0                       # 兜底下限（只有一行标题时也不会薄成一条线）
## 兜底上限：面板再高也不许顶出屏幕上沿（文案长到离谱时裁掉，而不是画到看不见的地方）
const HOVER_MAX_H := HOVER_BOTTOM - 16.0


## 悬停面板的矩形：宽度恒定 `HOVER_W`，下缘钉在 `HOVER_BOTTOM`，高度按文本算（h）。
## ★ 只在这里算「向上长」这件事：调用方（view/hover_tip.gd）只报**内容需要多高**。
static func hover_rect(h: float) -> Rect2:
	var hh: float = clampf(h, HOVER_MIN_H, HOVER_MAX_H)
	return Rect2(CARD_RECT.position.x, HOVER_BOTTOM - hh, HOVER_W, hh)

## 页签列（宽 108.333、高 260）。★ 现在是**动态页签**：自己的部队 2 颗（操作 / 单位）、
## 自己的区划中心 1 颗（招募）、自己的大本营 2 颗（操作 / 科技）、
## 无操作建筑 / 敌方 / 友方任何建筑单位时**页签与命令卡一起隐藏**、
## 什么都没选中时 2 颗（建筑 / 科技）—— 见 view/page_tabs.gd 的文件头。
## TABS_COUNT 只是「最多可能建几颗」（那一列最多放得下 3 颗 86.67 高的按钮）。
## ★ 按 13/12 等比放大：100×240 → 108.3333×260，左缘 1820 → 1811.6667。
const TABS_RECT := Rect2(1811.6667, 820.0, 108.3333, 260.0)
const TABS_COUNT := 3

## 设置按钮
const SETTINGS_RECT := Rect2(1840.0, 0.0, 80.0, 160.0)

## ★★ 选项页是**居中的模态 overlay**（view/options_panel.gd），不再有「贴按钮下方」的
##   下拉菜单，所以这里不再有 SETTINGS_MENU_RECT / ITEM_H / GAP / SLOTS。

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
##     · **选中多支部队**：左上第 1 格 = 被聚焦那支部队的**序号图标**；
##       下面 3×3 = 其余选中部队的序号图标（点一格 = 换聚焦哪一支）。
##     · **只选中一支部队**：左上第 1 格 = 那支部队的**序号图标**；
##       下面 3×3 = 这支部队的**单位**（点一格 = 右栏切到那个单位）；
##       单位超过 9 个时可**左右滑动**（拖动 / 滚轮按页）。
##     · **选中建筑**：左上第 1 格 = 主选中建筑；下面 3×3 = 其余建筑，超过 3 列同样可滑。
##
##   ★★ 下方 3×3 是「3 行 × 3 列」的**可见窗口**，内容按**列**向右延伸
##      （列优先，见 `troop_cell_rect`）；一列 = 3 个格子。
##   ★★ 部队图标 = **序号**（1..9、第 10 个写 0）+ 士气填充；
##      单个单位 / 建筑没有纯色背景，只画图标 + 底部血条（见 view/icon_badge.gd）。
##
## ⚠️ 单位编制上限（手玩原话：「y 是该将领的编制上限，目前所有将领的编制上限都暂时为 11」）
## ------------------------------------------------------------------
const UNIT_CAP := 11

## 左栏上半：左上那一格（= 当前展开的部队 / 唯一选中的部队的将领格）
## ★ 参考图实测：方框 40×40 在 x 415..454、y 860..899；它右边**两行**字 ——
##   「将领名称」在 y 885..899、「1/11」在 y 902..911（量出来的像素段）。
const ROSTER_CELL_AVATAR := 40.0
const ROSTER_CELL_TEXT_X := 48.0     # 文字那两行的左边（= 方框 40 + 缝 8）
## ★ 56 → 60：与网格里那一格**同一个宽度**（那一套断言盯着这两条相等）——
##   建筑那一行的「1000/1000」实测 13 号字下 59px，56 装不下。
const ROSTER_ID_W := 60.0            # 第一行（名字）能写到哪
## 文字那两行的基线（相对**方框顶边**）——
##   ★ 手玩原话：「对齐其对应左侧头像居中」⇒ 两行合起来作为一块，与 40 高的方框**垂直居中**。
##   算法：块高 = 2×FS_SMALL(13) + 行间隙(5) = 31 ⇒ 块顶 = (40-31)/2 ≈ 4.5
##         第一行基线 = 4.5 + 13(cap) = 17.5 ≈ 18；第二行 = 18 + 13 + 5 = 36。
##   （参考图上第一行落在 y 880..891、方框 y 880..919，也基本就是居中偏上。）
const ROSTER_ID_Y := 18.0
const ROSTER_COUNT_Y := 36.0
## 「1/11」与名字**同一个左边**（参考图上这两行的左边缘是对齐的）
const ROSTER_COUNT_X := 48.0
## ★ 56 → 60：与网格里那一格同一个理由（建筑那一行是「1000/1000」，实测 59px；
##   左上这一行右边整段都是空的，加宽 4px 不碰任何东西）。
const ROSTER_COUNT_W := 60.0
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
##     按同样的比例压成：格 116（40 方框 + 8 缝 + 60 文字 + 8 到下一格）。
## ⚠️ 文字可写宽度**必须**在 56~60 这一段：写 24 会把「将领名称」截成两个字（手玩报过
##   「左栏的字太小」），写 64 又会盖到右边那格的方框上（手玩报过「后两列没字」）。
## ★★ 56 → **60**（选中建筑那一轮）：建筑格的第二行是「血量 x/y」，而大本营是
##   **1000/1000** —— 实测 13 号字下宽 **59px**，56 会把它截成「1000/10…」。
##   60 之后文字右缘 = 48 + 60 = 108 ≤ 每格可用宽 112（`TROOP_CELL_W − 4`），
##   离下一格的方框（x = 116）还有 8px —— 实测过，不会串列。
const TROOP_GRID_COLS := 3
const TROOP_GRID_ROWS := 3
const TROOP_GRID_SLOTS := TROOP_GRID_COLS * TROOP_GRID_ROWS
## 一页 = 9 格（单选时滚轮翻页的单位数 / 多选建筑时翻页的建筑数）
const GRID_PAGE := TROOP_GRID_SLOTS
const TROOP_CELL_W := 116.0          # (350 - 2) / 3
## ★★ 每行 55 高（手玩报的「左栏 3×3 网格也太挤」之后改的：原来是 44）。
##   ⚠️ 这个数被**这一整段的竖直余量**锁死，不是随手调大的：
##     左栏整段 = 上半 40 + 缝 15 + 3×55 = 220，在内容高（240）里**居中**，
##     上下各留 10px（见 DETAIL_LEFT_Y）。要再加大就得同时压缩上半
##     （ROSTER_DETAIL_H）或缝（TROOP_ROW_GAP）。
##   方框仍是 40×40、字号不变 —— 松的是**行与行之间**（每行多出 11px 的空白），
##   所以不需要动文字的位置（那两行仍以方框顶边为准、与方框垂直居中）。
const TROOP_CELL_H := 55.0
const TROOP_CELL_GAP := 0.0
const TROOP_AVATAR := 40.0
## 格子里的文字：左边（= 方框 40 + 缝 8）、可写宽、两行的基线
const TROOP_NAME_X := 48.0
## ★ 56 → 60：见上面 TROOP_CELL_W 那一段（建筑格的「1000/1000」实测 59px 装不下 56）
const TROOP_NAME_W := 60.0
## 两行文字的基线（相对**方框顶边**）：两行作为一块与 40 高的方框垂直居中
## （算法同 ROSTER_ID_Y 那一段：块高 31、块顶 4.5）
const TROOP_NAME_Y := 18.0           # 第一行（单位 / 将领名）
const TROOP_NAME2_Y := 36.0          # 第二行（「x/y」或血量）
## 左栏上半与下半之间的缝（左栏整段 220 = 40 + 15 + 3×55，在内容高 240 里居中）
const TROOP_ROW_GAP := 15.0
## 网格控件的固定高度 = 3 行（不高随内容变，免得选中 1 支时整块跳一下）
const TROOP_GRID_H := 3.0 * TROOP_CELL_H

## ------------------------------------------------------------------
## 右栏（选中单位）：头像 / 名称 / buff / 数值
##
## ★★ 参考图实测（逐像素扫出来的线段）：
##   单位头像方框 100×100 x 806..905、y 860..959 ⇒ 内容区 (6,10)..(106,110)；
##   单位名称 x 924..1034、buff 三格 y 930..959、「详细信息」方框 606×90 y 975..1064。
##
## ★★★ **本轮重排（手玩报的「详细信息 ui 有些拥挤」）** —— 参考图那套尺寸照抄下来是挤的，
##   实测过症结，所以这一版有意偏离参考图，改了三处：
##     ① 头像 100×100 **只是「大而空」**：里面只有一个汉字（没有头像素材），
##        却把右栏上半整块占掉、把名称挤到右上角、buff 只能吊在它下半段。
##        ⇒ 收到 **72×72**，名称与 buff 全部挪到同一行（头像右边）。
##     ② 名称右边原来空着 307px（645 宽的右栏只用到 340），而数值方框又只有 90 高、
##        正文实际有 7 行（11 号字 + 行距 -1 硬塞，最后 1~2 行被 clip 掉）。
##        ⇒ 数值框**加高到 116**，正文改成 **两列表格**（左 = 血量/攻击，右 = 移速/防御），
##          字号 11 → 13、行距回正 —— 这才真的装得下、且不糊。
##         （两列表格见 view/detail_rows.gd 与 hud._unit_detail_rows()）
##     ③ 招募队列原来右边缘在 605 > 右栏宽 645？**不，是越出了面板**：
##        队列控件右边缘 = 左栏 350 + 缝 15 + 493 + 132 = 990 > 内容宽 1010 - … 实测越界 9px。
##        ⇒ QUEUE_X 收到 **513**，正好贴住右栏右边缘、整个落在面板里（test_ui 有断言）。
##
## ⚠️ 手玩报过两次「头像不对」，都别改回去：
##   ① 方框里那个字用的是 `FS_BIG(44)`，而方框只有 40×40 —— 字装不下、被裁成右下角一块；
##   ② 方框画成 40×40，参考图上它是 100×100。现在是 72（本轮重排定的），
##      字号仍按方框现算（`detail_panel._avatar_font_size()`），不写死。
## ⚠️ 这几条约束被 tests/test_ui.gd 钉住（改了要一起改）：
##   `UNIT_AVATAR_Y + UNIT_AVATAR < DETAIL_BODY_Y`（头像整块在数值框上面，不重叠）、
##   `BUFF_X + 3×(BUFF_SIZE+BUFF_GAP) ≤ DETAIL_RIGHT_W`（buff 不越出右栏）、
##   `UNIT_NAME_X + UNIT_NAME_W ≤ QUEUE_X`（名称不顶到招募队列）。
##
## ★★ **本版右栏再排一次：队列搬下来，与收窄后的详情框并排。**
##   需求：「详情框向左缩小、与第三个 buff 右缘对齐；招募面板下移与详情框对齐；
##   去掉三个 buff 占位，改成动态 buff」。手玩确认详情框保留最小可用宽（约 300）。
##
##   现在右栏（603×240）：
##     y   0 ..  96   顶带：头像（72×72）+ 名称 + 一行**动态 buff**（40×40）
##     y 100 .. 216   下半：**详情框 282×116 + 4px 缝 + 招募队列 313×116** 并排
##                    两者上/下缘完全齐平（QUEUE_Y = DETAIL_BODY_Y，QUEUE_H = DETAIL_BODY_H）
##     y 220 .. 240   提示带（红字一行，横跨两者）
##
##   ⚠️ 这几条被 tests/test_ui.gd 钉住（改了要一起改）：
##     `UNIT_AVATAR_Y + UNIT_AVATAR < DETAIL_BODY_Y`（头像整块在详情框上面）、
##     `BUFF_X + (BUFF_SLOTS−1)×(BUFF_SIZE+BUFF_GAP) + BUFF_SIZE ≤ detail_buff_w()`、
##     `UNIT_NAME_X + UNIT_NAME_W ≤ QUEUE_X`（名称不顶到右侧；队列虽在下方，这条仍成立）、
##     `DETAIL_BODY_W + QUEUE_MARGIN ≤ QUEUE_X`、`QUEUE_H == DETAIL_BODY_H`。
## ------------------------------------------------------------------
const UNIT_AVATAR := 72.0            # 选中单位的头像方框（正方形；第五轮 100 → 72）
const UNIT_AVATAR_X := 0.0           # 贴右栏左边
## 顶带（头像 / 名称 / 动态 buff）：y 8..96。
## ★ 顶边**不取 0**：贴 0 会让描边落在右栏裁剪线（y=0）上被切掉。
const UNIT_BAND_Y := 8.0
const UNIT_BAND_H := 88.0
## ★ 头像在顶带里**垂直居中**：8 + (88−72)/2 = 16。
const UNIT_AVATAR_Y := 16.0
const UNIT_NAME_X := 84.0            # 名字的左边（= 头像 72 + 缝 12）
## ★ 本轮 0 → 16：贴着头像上缘那一带（29 号字的字面从 16 起，与抬头对齐）。
const UNIT_NAME_Y := 16.0
## 名称最多写到哪：194（84..278）。队列本版已搬到下方，这条宽度沿用旧版以免动版式；
## 它仍然落在 QUEUE_X（286）之前，测试继续钉着这条。实测最长的名字「亲兵 11」才 102px。
const UNIT_NAME_W := 194.0
## buff 槽位：**动态**（由 view/buff_bar.gd 画，HUD 每帧喂条目）。
## ★ 本版去掉了原来三个写死的「buff1/2/3」；槽位宽 40×40（与左栏图标格同号），
##   格距 12 —— 基线宽 198 里正好放 4 个（4×40 + 3×12 = 196）。
const BUFF_SIZE := 40.0
const BUFF_GAP := 12.0
## buff 行与名称**共用同一个左边缘**（84），挂在头像下半段（46..86）。
const BUFF_X := 84.0
const BUFF_Y := 46.0
## 基线宽下最多摆得下几个（超出部分由 buff_bar 的 clip_contents 裁掉）。
const BUFF_SLOTS := 4
## buff 悬停浮窗：贴在 buff 方块**下缘**往下长（上方是名称/头像，没地方）。
## 宽度固定 230；高度由内容算（见 view/buff_tip.gd），和命令卡的悬停面板同一套底板。
const BUFF_TIP_W := 230.0
const BUFF_TIP_GAP := 6.0
const BUFF_TIP_PAD := 8.0
## 「详细信息」方框：**本版向左收窄到 282**（不再横跨整个右栏）。
##
## ★ 需求：「与第三个占位 buff 的右侧边对齐」。第三个 buff 的右缘是 232，
##   但那样两列各只剩约 100px、长增益行放不下；手玩随后确认「保留最小可用宽度（约 300）」。
##   ⇒ 取 **282**：右缘 = 招募队列左缘（286）− 4px 缝 —— 这是「详情框 + 队列并排」
##   能给出的最大整块宽度，也最接近需求里的 300。
## ★ y 仍然是 100..216（116 高）。右栏顶带（头像 / 名称 / buff）在 y 0..96，互不重叠。
const DETAIL_BODY_X := 0.0
const DETAIL_BODY_W := 282.0
const DETAIL_BODY_Y := 100.0
const DETAIL_BODY_H := 116.0
## 提示带的局部矩形（相对右栏）：**数值框下面那一条 20px**（100+116=216 .. 240）。
## ★★ 它曾经是面板 VBox 里的第二行 —— 一出现就把两栏各压掉 20px，
##    而左栏那 3×3 网格是**正好铺满内容高**的（40 + 15 + 3×55），于是最下面一截被裁。
##    现在它是右栏里的一个**绝对定位浮层**：出现与消失都不改任何一块的几何。
## ★ 20 高 / 正文 15 号字（行高 16）刚好一行 —— 长文案实测最长 405px ≤ 599，一行放得下。
const NOTICE_Y := 220.0
const NOTICE_H := 20.0
## ------------------------------------------------------------------
## 「详细信息」方框里的**两列**（左 = 血量/攻击，右 = 移速/防御；区划中心另算）
##
## ★ 宽度：282 − 左右各 8 内边距 − 中间 8 缝 = 258 ⇒ 每列 129。
##   13 号字下约 9 个汉字；较长的增益行由 view/detail_rows.gd **逐行缩字号**
##   （最小 9 号）再截断，所以不会顶出列外。
## ------------------------------------------------------------------
const DETAIL_BODY_PAD := 8.0         # 正文离方框左边 / 上边的内边距
const DETAIL_BODY_TEXT_Y := 8.0      # 两列文字的顶边（相对数值框）
const DETAIL_BODY_COL_GAP := 8.0     # 两列之间的缝
const DETAIL_BODY_COL_W := (DETAIL_BODY_W - 2.0 * DETAIL_BODY_PAD - DETAIL_BODY_COL_GAP) * 0.5
const DETAIL_BODY_COL2_X := DETAIL_BODY_PAD + DETAIL_BODY_COL_W + DETAIL_BODY_COL_GAP
const DETAIL_BODY_COL2_W := DETAIL_BODY_COL_W
## 一行的高度（13 号字放得下；116 高的框里正好 6 行 = 102）。
const DETAIL_ROW_H := 17.0
## 两列文字控件的可视高（底边留 6px，免得最后一行贴着方框下缘）。
const DETAIL_BODY_ROWS_H := DETAIL_BODY_H - DETAIL_BODY_TEXT_Y - 6.0
## ★★ 右栏所有方块的**公共右缘**，也是它们离右栏右边缘的留白。
##
## ★ 为什么必须有这个留白（手玩报的「上方被裁剪了」的真根因）：
##   `draw_rect(..., false, 1.0)` 画的 1px 描边是**以矩形边界为中心**的 ——
##   矩形一旦贴着右栏的上/右边缘，就有一半描边落在 `right.clip_contents` 之外被切掉，
##   画面上表现成「上边框整条不见了」。留 4px 之后四边都完整。
## ★ 数值框、招募队列、提示行都用它 ⇒ 右栏右侧是一条对齐的直线。
const QUEUE_MARGIN := 4.0
const UNIT_CONTENT_RIGHT := DETAIL_RIGHT_W - QUEUE_MARGIN


# ------------------------------------------------------------------
# ★★ 详细信息面板：**固定尺寸**（不再做手机端横向拉伸）
#
# 历史：曾经把面板左缘钉 400、右缘钉到阵营列左缘，视口宽于 16:9 时把多出来的宽
#   全部灌进右栏，好让「详细信息栏」与右侧阵营 / 页签**连起来**。
# 本版需求：手机端不需要相连，**尺寸恰好即可**。拉伸会把面板拉得很长，
#   右栏里还会空出一大片（详情框固定 282、队列固定 313），所以删掉拉伸。
#   ⇒ 固定 `DETAIL_RECT`（988×260，贴左、贴底），右侧留白。
# ⚠️ 下面几个 detail_* 函数仍然按传入的右栏宽度算，但正常只会收到 603。
# ------------------------------------------------------------------

## 数值框（正文背景板）的宽：**固定 282**，不再跟着右栏拉宽（需求：向左收窄）。
## ★ 兜底：右栏极窄时（还没布局 / 手机异常宽度）不超过 `right_w − QUEUE_MARGIN`。
static func detail_body_w(right_w: float) -> float:
	return minf(DETAIL_BODY_W, maxf(0.0, right_w - QUEUE_MARGIN))


## 两列文字控件的宽（方框内边距之内）。
static func detail_rows_w(right_w: float) -> float:
	return maxf(0.0, detail_body_w(right_w) - 2.0 * DETAIL_BODY_PAD)


## 动态 buff 槽位那一行的可用宽（左起 BUFF_X，右到招募队列左缘前 4px）。
static func detail_buff_w(right_w: float) -> float:
	return maxf(0.0, detail_queue_x(right_w) - BUFF_X - 4.0)


## 提示行（红字）的宽：它在下半区最底下、横跨详情框 + 队列，不跟着详情框收窄。
static func detail_notice_w(right_w: float) -> float:
	return maxf(0.0, right_w - QUEUE_MARGIN)


## 招募队列控件的 x（右缘钉在 `right_w − QUEUE_MARGIN`）。
static func detail_queue_x(right_w: float) -> float:
	return right_w - QUEUE_MARGIN - QUEUE_W


## 单位名称可写宽：右缘让开招募队列（留 8px 缝）。
static func detail_name_w(right_w: float) -> float:
	return detail_queue_x(right_w) - UNIT_NAME_X - 8.0


## 正文**右列**的宽（与左列等宽）。
static func detail_body_col2_w(_right_w: float) -> float:
	return DETAIL_BODY_COL2_W


# ------------------------------------------------------------------
# 局部矩形（面板内的相对坐标，给子控件用）
# ------------------------------------------------------------------

## 左栏整段的高度（上半 40 + 缝 15 + 网格 165）—— 它**不随面板长高**：
## 那 10 个格子是照参考图逐像素量出来的，位置一动就全乱了。
const DETAIL_LEFT_H := ROSTER_DETAIL_H + TROOP_ROW_GAP + 3.0 * TROOP_CELL_H
## 左栏那一段在更高的面板里**垂直居中**：上面空 (240−220)/2 = 10px。
const DETAIL_LEFT_Y := (DETAIL_CONTENT_H - DETAIL_LEFT_H) * 0.5

## 左栏上半那一段的局部矩形（相对 panel_content()）
static func roster_detail_rect() -> Rect2:
	return Rect2(0.0, DETAIL_LEFT_Y, DETAIL_LEFT_W, ROSTER_DETAIL_H)


## 左栏下半那个网格的局部矩形（相对 panel_content()）
## ★ 高度 = 3 行 × TROOP_CELL_H（= 165），加上上半 40 + 缝 15 = 220；
##   整段在内容高（240）里**居中** ⇒ 起点是 `DETAIL_LEFT_Y`（= 10）。
static func troop_grid_rect() -> Rect2:
	return Rect2(0.0, DETAIL_LEFT_Y + ROSTER_DETAIL_H + TROOP_ROW_GAP, DETAIL_LEFT_W, TROOP_GRID_H)


## 右栏的局部矩形（相对 panel_content()）
static func unit_detail_rect() -> Rect2:
	return Rect2(DETAIL_LEFT_W + DETAIL_GAP, 0.0, DETAIL_RIGHT_W, DETAIL_CONTENT_H)


## 网格第 i 格（相对**网格控件自身**）—— 3 行 × 3 列**可见**，**列优先**。
##
## ★★ 本版改成列优先（原来是行优先）：下方 3×3 现在是一个可以**左右滑动**的条带 ——
##   一「列」= 3 个格子（3+3+3 里的那个「3」），往右一列就是接着的 3 个单位。
##   行优先的话「滑动一列」会把同一行的 3 个不相邻单位挪进来，语义就散了。
##   于是索引 i → 列 col = i / 3、行 row = i % 3：
##     i = 0,1,2 → 第 1 列（从上到下）；i = 3,4,5 → 第 2 列 …… 以此类推。
static func troop_cell_rect(i: int) -> Rect2:
	var col: int = int(i / TROOP_GRID_ROWS)
	var row: int = i % TROOP_GRID_ROWS
	return Rect2(
		float(col) * TROOP_CELL_W,
		float(row) * TROOP_CELL_H,
		TROOP_CELL_W - 4.0, TROOP_CELL_H)


## 网格**可见区**的宽（3 列）——横向滚动时「一屏」就是它。
const TROOP_GRID_VIEW_W := TROOP_GRID_COLS * TROOP_CELL_W


## 网格内容的总宽：一共几列 × 每列宽（列数 = ceil(格子数 / 3)）。
## ★ total <= 0 → 0（没东西时没有可滚的内容）。
static func troop_grid_content_w(total: int) -> float:
	if total <= 0:
		return 0.0
	var cols: int = int(ceil(float(total) / float(TROOP_GRID_ROWS)))
	return float(cols) * TROOP_CELL_W


## 横向滚动的最大值（内容宽 - 可见宽；装得下时是 0 = 不能滚）。
static func troop_grid_max_scroll(total: int) -> float:
	return maxf(0.0, troop_grid_content_w(total) - TROOP_GRID_VIEW_W)


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


# ------------------------------------------------------------------
## 图标底部的**血量条**（详细信息面板里的单位 / 建筑图标，画法见 view/hp_bar.gd）
##
## ★ 需求原话：「所有单位图标底部都需要增加一个水平长度等于单位图标、竖直长度很小的
##   血量条，该血量条需要绑定该单位的血量」。
## ★ 宽度 = 图标宽度、贴在图标**内部底边** —— 这样套用同一个函数就能覆盖两种尺寸
##   （40×40 的网格方块 / 72×72 的右栏头像），且**不动任何现有版式常量**。
## ★ 高度 5px 是「竖直长度很小」那一档：它不参与布局，只是压在图标下缘的一条带。
## ------------------------------------------------------------------
const HP_BAR_H := 5.0


## 一个图标矩形 → 它底部那条血量条的矩形（宽度 = 图标宽度，贴图标内部底边）。
static func hp_bar_rect(icon: Rect2) -> Rect2:
	return Rect2(icon.position.x, icon.position.y + icon.size.y - HP_BAR_H,
		icon.size.x, HP_BAR_H)


## 设计空间里的「详细信息面板内容区」左上角（面板本身在 DETAIL_RECT，内有 DETAIL_PAD 的边距）
static func panel_content_pos() -> Vector2:
	return DETAIL_RECT.position + Vector2(DETAIL_PAD, DETAIL_PAD)


## 设计空间里的网格第 i 格（给 interactive_rects 用）
static func troop_cell_global_rect(i: int) -> Rect2:
	var r := troop_cell_rect(i)
	r.position += panel_content_pos() + troop_grid_rect().position
	return r


# ------------------------------------------------------------------
# 招募队列（1 大 + 4 小 + 左边一段汇总文字）
# ------------------------------------------------------------------

## 招募队列的五个格子（星际争霸那套：1 个大格 + 4 个小格）
##
## ★ 它画在**详细信息右栏的下半区**（详情框右边），只有选中的将领正在招募时才出现。
##   下面是**队列控件自身**的局部坐标 —— 控件本身由 detail_panel 摆进右栏。
##
## ★★ 第七轮：控件先加了左边一条 129px 汇总带，随后又按手玩反馈**整块放大**：
##   大格 64 → **84**、小格 30 → **40**、字号 13/11 → **15/13**、控件 261×64 → **313×116**
##   （本版高度跟着详情框 92 → 116），并且**离右栏右侧 4px**（`QUEUE_MARGIN`）——
##   贴边时 1px 描边会被右栏的 `clip_contents` 切掉一半（画面上就是「上边框不见了」）。
##
##     286 ───────── 427 ─────────── 599     ← 599 = DETAIL_RIGHT_W − QUEUE_MARGIN（603 − 4）
##     │  汇总带 141 │  五个格子 172  │
##     └─ QUEUE_X = DETAIL_RIGHT_W − QUEUE_MARGIN − QUEUE_W = 603 − 4 − 313 = 286
##
## ★★ 本版：招募面板**从顶带搬下来**，与详细信息框**上下对齐**：
##   x 仍然钉右（QUEUE_X），y = `DETAIL_BODY_Y`，高 = `DETAIL_BODY_H`（116）。
##   于是右栏下半是「详情框 282 + 4px 缝 + 队列 313」并排，顶/底边齐平。
##   格子尺寸（大 84 / 小 40）不变，只把多出来的 28px 变成上下留白（各 16）。
const QUEUE_BIG := 84.0              # 正在读条的那个（大格子）
const QUEUE_SMALL := 40.0            # 排队的四个（小格子）
const QUEUE_GAP := 4.0
const QUEUE_SLOTS := 5               # 1 大 + 4 小 = 最多 5 个（与 recruit.queue_max 对应）
const QUEUE_CELLS_W := QUEUE_BIG + QUEUE_GAP + QUEUE_SMALL * 2.0 + QUEUE_GAP   # 172：五个格子那一段
const QUEUE_INFO_W := 141.0          # 左边汇总文字那一段（两行小字）
const QUEUE_INFO_PAD := 8.0          # 汇总文字离控件左边 / 上边的内边距
const QUEUE_W := QUEUE_INFO_W + QUEUE_CELLS_W                                  # 313：控件总宽
const QUEUE_H := DETAIL_BODY_H       # 116：与详情框同高
## 格子在这个控件里的上下留白：(116 − 84) / 2 = 16。
const QUEUE_CELL_PAD := (QUEUE_H - QUEUE_BIG) * 0.5
## 控件左上角：右缘钉在 `UNIT_CONTENT_RIGHT`（= 599）上，上缘 = 详情框顶边。
const QUEUE_X := UNIT_CONTENT_RIGHT - QUEUE_W
const QUEUE_Y := DETAIL_BODY_Y



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


## 页签第 i 个按钮（相对面板）。
##
## ★ 页签**个数是变的**（选中部队 2 颗 / 选中区划中心 1 颗 / 选中建筑 0 颗 ——
##   见 view/page_tabs.gd 的文件头），所以高度 = 260 ÷ 当前页数；
##   `count` 缺省取满列 3 颗（那是「最多可能有几颗」，interactive_rects 与老测试用它）。
static func tab_button_local(i: int, count: int = TABS_COUNT) -> Rect2:
	var n: int = maxi(1, mini(count, TABS_COUNT))
	var h := TABS_RECT.size.y / float(n)
	return Rect2(0.0, float(i) * h, TABS_RECT.size.x, h)


## 页签第 i 个按钮（设计空间）
static func tab_button_rect(i: int, count: int = TABS_COUNT) -> Rect2:
	var r := tab_button_local(i, count)
	r.position += TABS_RECT.position
	return r


## 招募队列第 i 个格子（0 = 正在读条的大格，1..4 = 排队的四个小格）。
## 坐标相对**队列控件自身**（2×2 的小格排在右边，上下刚好与大格对齐）。
## ★ 左边先让开 `QUEUE_INFO_W` 那段汇总文字；上下各让开 `QUEUE_CELL_PAD`（= 4）。
static func queue_cell_rect(i: int) -> Rect2:
	var y := QUEUE_CELL_PAD
	if i <= 0:
		return Rect2(QUEUE_INFO_W, y, QUEUE_BIG, QUEUE_BIG)
	var k := i - 1
	var col := k % 2
	var row := int(k / 2)
	return Rect2(
		QUEUE_INFO_W + QUEUE_BIG + QUEUE_GAP + float(col) * (QUEUE_SMALL + QUEUE_GAP),
		y + float(row) * (QUEUE_SMALL + QUEUE_GAP),
		QUEUE_SMALL, QUEUE_SMALL)


## 汇总文字那一段的矩形（相对队列控件自身）：控件左边那条 `QUEUE_INFO_W` 宽的带子。
static func queue_info_rect() -> Rect2:
	return Rect2(0.0, 0.0, QUEUE_INFO_W, QUEUE_H)


## 汇总带里第 i 行文字的矩形（0 = 「招募队列 3/5」，1 = 「共 22s」）。
##
## ★ 两行作为一个文字块在 116 高的带子里**垂直居中**：
##   块高 = 18(第一行) + 4(缝) + 16(第二行) = 38 ⇒ 上下各留 (116−38)/2 = 39。
static func queue_info_line_rect(i: int) -> Rect2:
	var w := QUEUE_INFO_W - 2.0 * QUEUE_INFO_PAD
	var top: float = (QUEUE_H - 38.0) * 0.5
	if i <= 0:
		return Rect2(QUEUE_INFO_PAD, top, w, 18.0)
	return Rect2(QUEUE_INFO_PAD, top + 22.0, w, 16.0)


## 鼠标停在某一格上时，那一格右上角那个「×」的边长与内边距（第七轮加的）。
##
## ★ 它是**两条短线画出来的记号**（不是字）：不依赖字体，所以中文字体没装好时
##   也不会变成方框（`view/recruit_queue.gd` 的 `_draw` 用它）。
## ★ 放在这里而不是 view/ 里：全工程的「像素坐标」只认这一个文件
##   （与其它 view 文件同规矩，见本文件开头）。
const QUEUE_HOVER_X_SIZE := 8.0
const QUEUE_HOVER_X_PAD := 4.0


# ------------------------------------------------------------------
# 摆放
# ------------------------------------------------------------------

## 把「设计空间矩形」贴到控件上。
##
## anchor_right / anchor_bottom 说明这块面板贴的是右/下边还是左/上边：
##   右上的东西（部队列表、设置）贴右上；底栏与右侧那一列贴右下 ——
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


## 顶部居中（目标条）：左右锚点都钉在 50%，只按设计矩形相对**屏幕中心**算偏移。
## ★ 与 apply_rect 的区别：apply_rect 只支持「贴左 / 贴右」，居中要用这一条；
##   否则窗口变宽时目标条会停在 1920 设计空间的中心、而不是真实屏幕中心。
static func apply_top_center(c: Control, r: Rect2) -> void:
	c.anchor_left = 0.5
	c.anchor_right = 0.5
	c.offset_left = r.position.x - DESIGN_W * 0.5
	c.offset_right = c.offset_left + r.size.x
	c.anchor_top = 0.0
	c.anchor_bottom = 0.0
	c.offset_top = r.position.y
	c.offset_bottom = r.position.y + r.size.y


## ★★ 详细信息面板：**固定贴左、贴底**（988×260）。
## 不再做「右缘钉到阵营列」的拉伸 —— 手机端不需要和右侧页签相连，尺寸恰好即可。
static func apply_fixed_detail(c: Control) -> void:
	apply_rect(c, DETAIL_RECT, false, true)


# ------------------------------------------------------------------
# 鼠标：哪些地方要「让路」
# ------------------------------------------------------------------

## 可交互控件的矩形（设计空间，已按当前设计空间大小做了贴边修正）。
##
## ★ 只有**真正能点**的控件才让路（右侧部队行 / 命令卡格 / 页签 / 设置 / 小地图 /
##   详细信息左栏下方的**将领头像网格**）。
##   详细信息面板的其余部分只有文字与方块，鼠标停在上面照样允许边缘滚屏 ——
##   否则底栏把屏幕下沿整个盖住，鼠标永远滚不到地图下方（这条是踩过的坑）。
##
## ★★ 小地图是**后加进这份名单**的（它现在真的能点：左键点击 = 移动镜头、按住拖动 = 视角跟手）。
##   为什么必须加：它在屏幕最左下角，贴着左边缘与下边缘 ——
##   鼠标停在小地图上时若还允许边缘滚屏，镜头会一边跟着点击跳、一边被边缘推走。
##   ⚠️ 但它照样逃不过 `in_edge_band` 那条例外：最外圈 44px 内仍然允许滚屏
##   （那是所有贴边控件的共同规则，见 in_edge_band 的说明）。
##   ★ 拖动那一段由 camera_rig.set_ui_dragging() 额外压住（例外区里的那次抖动）——
##     见 view/minimap.gd 文件末尾与 docs/route.md 19.4。
##
## ★★ 网格是**能点 / 能拖动**的：整块（可见 3×3）都进「可点控件」名单。
##   本版下方 3×3 改成可左右滑动后，不能再按 9 个固定格子登记 ——
##   滚动之后「第 i 个格子现在在哪」是控件自己的事（见 view/troop_grid.gd），
##   这里只登记**可见区**那一个矩形。
##   它整块都在详细信息面板里，所以「让路」的副作用是把面板中间那一大片也拦掉了 ——
##   这是有意的：鼠标停在能点的格子上时不该同时被边缘推着滚屏（与小地图同一条理由）。
##   面板**其余**的地方（右栏、左栏上半）仍然是「只有文字 → 照样滚屏」。
## @param detail_visible 详细信息面板是否可见。隐藏时它那块区域**不再算 UI**
##        （左栏网格与面板矩形都不拦输入 → 恢复地图滚轮 / 边缘滚屏 / 触摸手势）。
## @param command_ui_visible 右下角「命令卡 + 页签」是否可见。选中无操作建筑 /
##        敌方 / 友方任何建筑单位时它们**整块隐藏**（见 view/page_tabs.gd 的文件头），
##        此时那块区域不该继续吞掉地图手势 / 边缘滚屏 —— 屏幕上根本没有东西可点。
static func interactive_rects(view_size: Vector2, detail_visible: bool = true,
		command_ui_visible: bool = true) -> Array[Rect2]:
	var shift := Vector2(maxf(0.0, view_size.x - DESIGN_W), maxf(0.0, view_size.y - DESIGN_H))
	var out: Array[Rect2] = []
	for i in SQUAD_SLOTS:
		var sr := squad_slot_rect(i)                        # 贴右上：跟着视口右边走
		sr.position += shift
		out.append(sr)
	out.append(MAP_RECT)                                        # 左下小地图，贴左下
	if command_ui_visible:
		for i in CARD_SLOTS:
			var r := card_cell_rect(i)                      # 贴右下
			r.position += shift
			out.append(r)
		for i in TABS_COUNT:
			var r2 := tab_button_rect(i)                    # 贴右下
			r2.position += shift
			out.append(r2)
	if detail_visible:
		var gr := troop_grid_rect()                         # 详细信息左栏，贴左下
		gr.position += panel_content_pos()
		out.append(gr)
	var s := SETTINGS_RECT
	s.position.x += shift.x                                     # 贴右上
	out.append(s)
	return out


## 底栏那几块面板的矩形（设计空间，贴边修正与 interactive_rects 同一套口径）：
## 详细信息 / 阵营 / 命令卡 / 页签。
##
## ★★ 这是**另一份名单**，别和 interactive_rects 合并 —— 两者判的是两件事：
##   · `interactive_rects` = 「**能点的**控件」→ 用来拦**边缘滚屏**。只能收能点的东西：
##     详细信息面板全是文字，让它也让路的话底栏会盖住屏幕下沿，鼠标永远滚不到地图下方。
##   · 本名单 = 「**底栏本身**」→ 用来拦**滚轮缩放**（用户需求：「当鼠标位于下方除地图外的
##     ui 栏时，应当禁用鼠标滚轮缩放地图，当鼠标移出下边栏，需要恢复」）。
##     玩家正在看底栏的时候，那一下滚动不该把地图拉走 —— 与那一块能不能点无关。
##
## ★ 左下小地图**不在**名单里：它是地图本身（不是 ui 栏），鼠标停在上面时滚轮照旧缩放地图。
## ★ 贴边：详细信息 / 阵营盾徽都贴**左**（只跟 y 走）；命令卡 / 页签贴右下（x/y 都跟）。
## @param detail_visible 详细信息是否可见。隐藏时只去掉它那一块 —— 盾徽 / 命令卡 / 页签
##       仍然算底栏（它们还在屏幕上）。
## @param command_ui_visible 右下角「命令卡 + 页签」是否可见。整块隐藏时它那一块
##        也**不再算底栏**（见 `interactive_rects` 的同一参数）。
static func bottom_bar_rects(view_size: Vector2, detail_visible: bool = true,
		command_ui_visible: bool = true) -> Array[Rect2]:
	var shift := Vector2(maxf(0.0, view_size.x - DESIGN_W), maxf(0.0, view_size.y - DESIGN_H))
	var out: Array[Rect2] = []
	if detail_visible:
		var d := DETAIL_RECT
		d.position.y += shift.y
		out.append(d)
	var f := FACTION_RECT
	f.position.y += shift.y
	out.append(f)
	if command_ui_visible:
		var card := CARD_RECT             # 贴右下：右下都修正
		card.position += shift
		out.append(card)
		var tabs := TABS_RECT
		tabs.position += shift
		out.append(tabs)
	return out


## 某个点是否落在任一可交互控件上
static func point_hits_any(rects: Array[Rect2], p: Vector2) -> bool:
	for r in rects:
		if r.has_point(p):
			return true
	return false


## 这个点是不是落在**屏幕最外圈**（edge_size 像素之内）。
##
## ★ 为什么需要这条规则（手玩报的 bug）：右下「部队 1~10」（将领按钮那一列）是
##   x 1680..1919 的控件，它整条压着屏幕右边缘 —— 于是鼠标推到右边缘那一段永远被
##   判成「在控件上，别滚屏」，右边缘那一片地图永远滚不到。
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
