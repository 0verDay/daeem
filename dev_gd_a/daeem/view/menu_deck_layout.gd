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

## 侧栏宽度：1920 → 640；2400 → 720；1280 → 520。
static func side_w(screen_w: float) -> float:
	return clampf(round(screen_w / 3.0), 520.0, 720.0)


static func wide_w(screen_w: float) -> float:
	return maxf(320.0, screen_w - side_w(screen_w))


# ------------------------------------------------------------------
# 公共零件
# ------------------------------------------------------------------

## 右上角返回按钮（56×56）。
static func back_rect(w: float) -> Rect2:
	return Rect2(w - TOP_PAD - 56.0, TOP_PAD, 56.0, 56.0)


## 右上角泛光：以面板右上角为圆心，向左下铺开的一小块径向光。
static func corner_glow_rect(w: float) -> Rect2:
	return Rect2(w - 240.0, 0.0, 240.0, 240.0)


## 右上角的三角形命中区（视觉按钮仍只有 56×56）。
static func corner_hit_rect(w: float) -> Rect2:
	return Rect2(w - 140.0, 0.0, 140.0, 140.0)


## 顶部半圆泛光：宽度固定 460、向上出一点点、向下展开。
static func glow_rect(w: float) -> Rect2:
	return Rect2((w - 460.0) * 0.5, -18.0, 460.0, 190.0)


## 半圆泛光里的标题区域（相对面板）。
static func glow_title_rect(w: float) -> Rect2:
	return Rect2((w - 460.0) * 0.5, 38.0, 460.0, 64.0)


# ------------------------------------------------------------------
# 主菜单（640×1080）
# ------------------------------------------------------------------

static func main_exit(w: float) -> Rect2:
	return Rect2(w - TOP_PAD - 56.0, TOP_PAD, 56.0, 56.0)


static func main_logo(w: float) -> Rect2:
	return Rect2((w - 200.0) * 0.5, 72.0, 200.0, 200.0)


static func main_name(w: float) -> Rect2:
	return Rect2((w - 240.0) * 0.5, 304.0, 240.0, 52.0)


static func main_button(w: float, index: int) -> Rect2:
	return Rect2((w - 400.0) * 0.5, 440.0 + 160.0 * float(index), 400.0, 84.0)


static func main_bottom(w: float, h: float) -> Rect2:
	return Rect2(0.0, h - 120.0, w, 120.0)


static func main_bottom_half(w: float, h: float, index: int) -> Rect2:
	return Rect2(w * 0.5 * float(index), h - 120.0, w * 0.5, 120.0)


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
	return 220.0


static func coop_flag(w: float, h: float, index: int) -> Rect2:
	var fw := 340.0
	var fh := 560.0
	var total: float = fw * 2.0 + coop_flag_gap()
	var x0: float = (w - total) * 0.5
	return Rect2(x0 + float(index) * (fw + coop_flag_gap()), 230.0, fw, fh)


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


# 房间输入块内部（相对输入块）。
static func room_code_display(w: float) -> Rect2:
	return Rect2(20.0, 58.0, w - 40.0, 64.0)


static func room_key_rect(w: float, index: int) -> Rect2:
	# index 0..11：1..9 / 0、清空、留空；3 列 4 行。
	var gap := 10.0
	var cell_w: float = (w - 40.0 - gap * 2.0) / 3.0
	var cell_h := 56.0
	var col: int = index % 3
	var row: int = int(index / 3)
	return Rect2(20.0 + float(col) * (cell_w + gap), 140.0 + float(row) * (cell_h + 8.0),
		cell_w, cell_h)


static func room_action(w: float) -> Rect2:
	return Rect2(20.0, 388.0, w - 40.0, 56.0)


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
