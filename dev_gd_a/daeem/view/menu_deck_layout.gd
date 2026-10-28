## menu_deck_layout.gd —— 新菜单（MenuDeck）的几何常量。
##
## 与 `view/coop_layout.gd` / `view/ui_layout.gd` 同一思路：面板脚本里不写坐标字面量。
## 所有坐标都是 1920×1080 设计空间；侧栏宽度按视口宽度夹取，高度铺满。
##
## 设计基准（1920×1080）：
##   SIDE_W = 640（1/3），WIDE_W = 1280（2/3）。
##   主菜单 / 详情 / 房间 / 准备 = 640 宽；战役地图 / 合作过渡 = 1280 宽。
extends RefCounted

const DESIGN_W := 1920.0
const DESIGN_H := 1080.0
const SIDE_W := 640.0
const WIDE_W := 1280.0
const PAD := 40.0
const TOP_PAD := 24.0

## 四角序号：面板角按钮 / 角泛光共用这一套（menu_corner_glow.gd 的 corner 参数）。
const CORNER_TOP_RIGHT := 0
const CORNER_TOP_LEFT := 1
const CORNER_BOTTOM_LEFT := 2
const CORNER_BOTTOM_RIGHT := 3

## 侧栏宽度：1920 → 640；2400 → 720；1280 → 520。
static func side_w(screen_w: float) -> float:
	return clampf(round(screen_w / 3.0), 520.0, 720.0)


static func wide_w(screen_w: float) -> float:
	return maxf(320.0, screen_w - side_w(screen_w))


# ------------------------------------------------------------------
# 公共零件
# ------------------------------------------------------------------

## 右上角返回按钮（56×56）。视觉比原来向左下各让 16px，手机上更好按。
static func back_rect(w: float) -> Rect2:
	return Rect2(w - 96.0, 40.0, 56.0, 56.0)


## 右上角泛光：以面板右上角为圆心，向左下铺开的一小块径向光。
static func corner_glow_rect(w: float) -> Rect2:
	return Rect2(w - 240.0, 0.0, 240.0, 240.0)


## 右上角的三角形命中区：180×180；再大就会盖到房间列表的刷新按钮。
static func corner_hit_rect(w: float) -> Rect2:
	return Rect2(w - 180.0, 0.0, 180.0, 180.0)


## 顶部半圆泛光：宽度固定 460、向上出一点点、向下展开。
static func glow_rect(w: float) -> Rect2:
	return Rect2((w - 460.0) * 0.5, -18.0, 460.0, 190.0)


## 半圆泛光里的标题区域（相对面板）。
static func glow_title_rect(w: float) -> Rect2:
	return Rect2((w - 460.0) * 0.5, 38.0, 460.0, 64.0)


# ------------------------------------------------------------------
# 主菜单（640×1080）
# ------------------------------------------------------------------

## 主菜单底部动作条（自定义/备战）的高度。
const MAIN_BOTTOM_H := 120.0
## 主菜单四角按钮：56×56，离面板边 40px —— 与退出 X 的 (w-96, 40) 同一圈。
const MAIN_CORNER_SIZE := 56.0
const MAIN_CORNER_INSET := 40.0
## 四角泛光贴片的边长（与上面的角重合，向面板内部铺开）。
const MAIN_CORNER_GLOW := 240.0
## 四角触发区：与返回/退出按钮同款的 180×180 方框，真正能点的只有贴角那半个三角。
const MAIN_CORNER_HIT := 180.0


static func main_exit(w: float) -> Rect2:
	return Rect2(w - 96.0, 40.0, 56.0, 56.0)


## 主菜单四角的图标按钮（载入 / 好友 / 设置）。退出 X 仍走 main_exit。
##
## ★ 上排贴面板顶边；下排贴**内容区底边** —— 也就是「不包含 自定义/备战 动作条」
##   的那块面板的左右下角（动作条顶边再往上留同样 40px 的内缩）。
static func main_corner_button(w: float, h: float, corner: int) -> Rect2:
	var s := MAIN_CORNER_SIZE
	var x_left := MAIN_CORNER_INSET
	var x_right: float = w - MAIN_CORNER_INSET - s
	var y_top := MAIN_CORNER_INSET
	var y_bottom: float = main_content_bottom(h) - MAIN_CORNER_INSET - s
	match corner:
		CORNER_TOP_LEFT:
			return Rect2(x_left, y_top, s, s)
		CORNER_BOTTOM_LEFT:
			return Rect2(x_left, y_bottom, s, s)
		CORNER_BOTTOM_RIGHT:
			return Rect2(x_right, y_bottom, s, s)
		_:
			return Rect2(x_right, y_top, s, s)


## 主菜单内容区底边：底部动作条的顶边。四角按钮与角泛光都以它作为「面板底」。
static func main_content_bottom(h: float) -> float:
	return h - MAIN_BOTTOM_H


## 四角触发区：一块贴着对应角的 180×180 方框。能点的是框里靠近那个角的三角形
## （形状判定见 `corner_has_point`），和右上角退出/返回那只一样。
static func main_corner_hit(w: float, h: float, corner: int) -> Rect2:
	var s := MAIN_CORNER_HIT
	var x_left := 0.0
	var x_right: float = w - s
	var y_top := 0.0
	var y_bottom: float = main_content_bottom(h) - s
	match corner:
		CORNER_TOP_LEFT:
			return Rect2(x_left, y_top, s, s)
		CORNER_BOTTOM_LEFT:
			return Rect2(x_left, y_bottom, s, s)
		CORNER_BOTTOM_RIGHT:
			return Rect2(x_right, y_bottom, s, s)
		_:
			return Rect2(x_right, y_top, s, s)


## 三角命中：方框里只有靠近该角的那一半算点中，另一半留给面板正文。
##
## 与 menu_corner_hit 原来的 `x >= y` 等价（那是右上角、方框的情形），这里只是
## 归一化后推广到四个角，让四角的按钮和返回/退出走同一份判定。
##
## ★ 先卡一次方框：半平面判定本身不受方框约束，不卡的话底角那颗的三角会
##   一路延伸到底部动作条上，把「自定义/备战」的点击吞掉。
static func corner_has_point(box_size: Vector2, corner: int, p: Vector2) -> bool:
	var w: float = maxf(1.0, box_size.x)
	var h: float = maxf(1.0, box_size.y)
	if p.x < 0.0 or p.y < 0.0 or p.x > w or p.y > h:
		return false
	var u: float = p.x / w
	var v: float = p.y / h
	match corner:
		CORNER_TOP_LEFT:
			return u + v <= 1.0
		CORNER_BOTTOM_LEFT:
			return v >= u
		CORNER_BOTTOM_RIGHT:
			return u + v >= 1.0
		_:
			return u >= v


## 四角泛光：以对应角为圆心、240×240 向面板内部铺开的一小块径向光。
static func main_corner_glow(w: float, h: float, corner: int) -> Rect2:
	var g := MAIN_CORNER_GLOW
	var bottom: float = main_content_bottom(h)
	match corner:
		CORNER_TOP_LEFT:
			return Rect2(0.0, 0.0, g, g)
		CORNER_BOTTOM_LEFT:
			return Rect2(0.0, bottom - g, g, g)
		CORNER_BOTTOM_RIGHT:
			return Rect2(w - g, bottom - g, g, g)
		_:
			return Rect2(w - g, 0.0, g, g)


static func main_logo(w: float) -> Rect2:
	return Rect2((w - 200.0) * 0.5, 72.0, 200.0, 200.0)


static func main_name(w: float) -> Rect2:
	return Rect2((w - 240.0) * 0.5, 304.0, 240.0, 52.0)


## 主菜单标题与下方按钮之间的分隔线（左右两端渐隐）。
static func main_rule(w: float) -> Rect2:
	return Rect2((w - 320.0) * 0.5, 396.0, 320.0, 1.0)


static func main_button(w: float, index: int) -> Rect2:
	return Rect2((w - 400.0) * 0.5, 440.0 + 160.0 * float(index), 400.0, 84.0)


## 屏幕左上角的 ai_test 测试入口（260×56）。只在主菜单页显示。
##
## ★ 原来钉在**屏幕正中**（400×64）：主菜单左侧现在是那幅程序化的塔，
##   正中间正好压在塔身上，一条调试按钮横在画的腰上很难看。
##   挪到左上角 —— 那块是空的（缆索从 y≈0.16H 才进来），谁都不挡。
static func screen_test_button(w: float, h: float) -> Rect2:
	return Rect2(40.0, 36.0, 260.0, 56.0)


static func main_bottom(w: float, h: float) -> Rect2:
	return Rect2(0.0, h - MAIN_BOTTOM_H, w, MAIN_BOTTOM_H)


static func main_bottom_half(w: float, h: float, index: int) -> Rect2:
	return Rect2(w * 0.5 * float(index), h - MAIN_BOTTOM_H, w * 0.5, MAIN_BOTTOM_H)


# ------------------------------------------------------------------
# 战役地图（宽栏 1280×1080）
# ------------------------------------------------------------------

static func campaign_rail(w: float, h: float) -> Rect2:
	var rail_h: float = minf(800.0, h - 280.0)
	return Rect2(w - 48.0 - 100.0, (h - rail_h) * 0.5, 100.0, rail_h)


static func campaign_rail_button(rail: Rect2, index: int) -> Rect2:
	var size := 84.0
	var gap := 16.0
	var total: float = size * 3.0 + gap * 2.0
	var y0: float = rail.position.y + (rail.size.y - total) * 0.5
	return Rect2(rail.position.x + (rail.size.x - size) * 0.5,
		y0 + float(index) * (size + gap), size, size)


static func campaign_flag(w: float, h: float) -> Rect2:
	return Rect2(w * 0.5 - 85.0, h * 0.5 - 105.0, 170.0, 210.0)


# ------------------------------------------------------------------
# 战役详情 / 合作准备（640×1080）
# ------------------------------------------------------------------

static func detail_thumb(w: float) -> Rect2:
	return Rect2((w - 400.0) * 0.5, 150.0, 400.0, 400.0)


static func detail_desc(w: float) -> Rect2:
	return Rect2(PAD, 570.0, w - PAD * 2.0, 200.0)


static func detail_faction_rect(w: float, index: int, count: int) -> Rect2:
	var area_w: float = w - PAD * 2.0
	var gap := 20.0
	if count <= 1:
		return Rect2(PAD, 790.0, area_w, 100.0)
	var cell_w: float = (area_w - gap) * 0.5
	var col: int = index % 2
	var row: int = int(index / 2)
	return Rect2(PAD + float(col) * (cell_w + gap), 790.0 + float(row) * 120.0,
		cell_w, 100.0)


static func ready_status(w: float) -> Rect2:
	return Rect2(PAD, 787.0, w - PAD * 2.0, 24.0)


static func ready_action(w: float) -> Rect2:
	return Rect2(PAD, 825.0, w - PAD * 2.0, 88.0)


# ------------------------------------------------------------------
# 合作过渡（宽栏 1280×1080）
# ------------------------------------------------------------------

static func coop_flag_gap() -> float:
	return 180.0


static func coop_flag(w: float, h: float, index: int) -> Rect2:
	var fw := 380.0
	var fh := 620.0
	var total: float = fw * 2.0 + coop_flag_gap()
	var x0: float = (w - total) * 0.5
	return Rect2(x0 + float(index) * (fw + coop_flag_gap()), 210.0, fw, fh)


static func coop_hint(w: float, h: float) -> Rect2:
	return Rect2(PAD, h - 110.0, w - PAD * 2.0, 40.0)


# ------------------------------------------------------------------
# 合作房间（640×1080）
# ------------------------------------------------------------------

static func room_list(w: float) -> Rect2:
	return Rect2(24.0, 150.0, w - 48.0, 420.0)


static func room_status(w: float) -> Rect2:
	return Rect2(24.0, 582.0, w - 48.0, 24.0)


static func room_input(w: float) -> Rect2:
	return Rect2(24.0, 610.0, w - 48.0, 460.0)


## 房间码输入区（相对输入面板）。输入框上移，键盘同步上移 38px。
const ROOM_KEY_TOP := 102.0
const ROOM_KEY_H := 80.0
const ROOM_KEY_GAP_X := 10.0
const ROOM_KEY_GAP_Y := 8.0


static func room_code_display(w: float) -> Rect2:
	return Rect2(20.0, 20.0, w - 40.0, 64.0)


static func room_key_rect(w: float, index: int) -> Rect2:
	var cell_w: float = (w - 40.0 - ROOM_KEY_GAP_X * 2.0) / 3.0
	var col: int = index % 3
	var row: int = int(index / 3)
	return Rect2(20.0 + float(col) * (cell_w + ROOM_KEY_GAP_X),
		ROOM_KEY_TOP + float(row) * (ROOM_KEY_H + ROOM_KEY_GAP_Y),
		cell_w, ROOM_KEY_H)


## 加入 / 创建房间按钮：与数字 0 同一行，占第 2、3 格（两个按钮的宽度）。
static func room_action(w: float) -> Rect2:
	var cell_w: float = (w - 40.0 - ROOM_KEY_GAP_X * 2.0) / 3.0
	return Rect2(20.0 + cell_w + ROOM_KEY_GAP_X,
		ROOM_KEY_TOP + 3.0 * (ROOM_KEY_H + ROOM_KEY_GAP_Y),
		cell_w * 2.0 + ROOM_KEY_GAP_X, ROOM_KEY_H)


# ------------------------------------------------------------------
# 合作地图选择（右侧 640×1080）
# ------------------------------------------------------------------

static func map_grid(w: float) -> Rect2:
	return Rect2(24.0, 160.0, w - 48.0, 740.0)


static func map_card_size() -> Vector2:
	return Vector2(176.0, 200.0)


static func map_card_gap() -> float:
	return 12.0


static func map_picker_buttons(w: float) -> Array:
	var y := 930.0
	var gap := 16.0
	var bw: float = (w - 48.0 - gap) * 0.5
	return [Rect2(24.0, y, bw, 72.0), Rect2(24.0 + bw + gap, y, bw, 72.0)]
