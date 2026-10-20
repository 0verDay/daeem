## coop_layout.gd —— 合作大厅三态（大厅 / 房间 / 地图选择）的几何常量。
##
## 与 `view/ui_layout.gd` 同一条思路：`view/coop_lobby.gd` 不写坐标字面量。
## 全部是 1920×1080 设计空间；根节点铺满撑开的二级面板（约 24..1896）。
##
## 三个状态：
##   LOBBY       左 / 中席位 + 右侧大厅面板（房间列表 / 房间码 / 键盘）
##   ROOM        席位不动；大厅面板右滑出，房间配置面板左滑入
##   MAP_SELECT  席位左滑出；房间配置面板滑到左侧，地图面板从右侧滑入
extends RefCounted

const DESIGN_W := 1920.0
const DESIGN_H := 1080.0

## 返回按钮（由 menu_secondary_panel 创建，coop_lobby 托管位置）
const BACK_RIGHT := Rect2(1712.0, 48.0, 160.0, 80.0)
const BACK_LEFT := Rect2(60.0, 48.0, 160.0, 80.0)

## 两侧席位
const SELF_SEAT := Rect2(120.0, 180.0, 360.0, 700.0)
const MATE_SEAT := Rect2(640.0, 180.0, 360.0, 700.0)
const SEAT_OFFSCREEN := -800.0

## 三块面板
const LOBBY_PANEL := Rect2(1300.0, 140.0, 500.0, 800.0)
const ROOM_PANEL := Rect2(1140.0, 140.0, 660.0, 800.0)
const ROOM_PANEL_MAP := Rect2(60.0, 140.0, 660.0, 800.0)
const MAP_PANEL := Rect2(760.0, 140.0, 600.0, 800.0)
const OFFSCREEN_RIGHT := Rect2(1920.0, 140.0, 660.0, 800.0)
const OFFSCREEN_LEFT := Rect2(-660.0, 140.0, 660.0, 800.0)

const PANEL_PAD := 24.0
const INNER_W := 612.0

## 大厅面板内部（2026.10.20 第三轮：面板再缩到 500 宽，内部 452）
const LOBBY_INNER_W := 452.0
const LOBBY_HEADER := Rect2(24.0, 24.0, 452.0, 56.0)
const LOBBY_REFRESH := Rect2(360.0, 10.0, 80.0, 36.0)
## 房间列表单独一块**带边框的面板**；内部再留 8px 给滚动条 / 触摸拖动。
const LOBBY_LIST := Rect2(24.0, 88.0, 452.0, 292.0)
const LOBBY_LIST_PAD := 8.0
const LOBBY_STATUS := Rect2(24.0, 396.0, 452.0, 20.0)
const LOBBY_CODE_LABEL := Rect2(24.0, 420.0, 452.0, 20.0)
const LOBBY_CODE_EDIT := Rect2(24.0, 444.0, 452.0, 64.0)
const LOBBY_CODE_CLEAR := Rect2(428.0, 452.0, 40.0, 48.0)
const LOBBY_KEYPAD_Y := 524.0
const LOBBY_KEY_W := 142.6667
const LOBBY_KEY_H := 56.0
const LOBBY_KEY_GAP := 12.0
const LOBBY_KEY_ROW_GAP := 8.0
const LOBBY_ACTION := Rect2(24.0 + LOBBY_KEY_W + LOBBY_KEY_GAP,
	LOBBY_KEYPAD_Y + 3.0 * (LOBBY_KEY_H + LOBBY_KEY_ROW_GAP),
	452.0 - LOBBY_KEY_W - LOBBY_KEY_GAP, LOBBY_KEY_H)

## 房间面板内部
const ROOM_PREVIEW := Rect2(24.0, 24.0, 612.0, 440.0)
const ROOM_DESC := Rect2(24.0, 480.0, 612.0, 180.0)
const ROOM_ACTION := Rect2(24.0, 680.0, 612.0, 72.0)

## 地图选择面板内部
const MAP_HEADER := Rect2(24.0, 16.0, 552.0, 40.0)
const MAP_SCROLL := Rect2(24.0, 72.0, 552.0, 704.0)

## 席位卡片内部
const SEAT_AVATAR := Rect2(120.0, 90.0, 120.0, 120.0)
const SEAT_NAME_Y := 250.0
const SEAT_ROLE_Y := 292.0
const SEAT_STATUS_Y := 360.0


## 某个状态下大厅面板 / 房间面板 / 地图面板的目标矩形。
static func lobby_rect(state: String) -> Rect2:
	return LOBBY_PANEL if state == "lobby" else OFFSCREEN_RIGHT


static func room_rect(state: String) -> Rect2:
	match state:
		"lobby":
			return OFFSCREEN_RIGHT
		"map":
			return ROOM_PANEL_MAP
		_:
			return ROOM_PANEL


static func map_rect(state: String) -> Rect2:
	return MAP_PANEL if state == "map" else OFFSCREEN_RIGHT


static func back_rect(state: String) -> Rect2:
	return BACK_LEFT if state == "map" else BACK_RIGHT


static func seat_target(state: String, base: Rect2) -> Rect2:
	if state == "map":
		return Rect2(base.position + Vector2(SEAT_OFFSCREEN, 0.0), base.size)
	return base


## 键盘第 i 个数字键（i=0..9；1..9 排前三行，0 在第四行第一列）。
static func key_rect(i: int) -> Rect2:
	var idx: int = i - 1
	if i == 0:
		return Rect2(24.0, LOBBY_KEYPAD_Y + 3.0 * (LOBBY_KEY_H + LOBBY_KEY_ROW_GAP),
			LOBBY_KEY_W, LOBBY_KEY_H)
	var col: int = idx % 3
	var row: int = int(idx / 3)
	return Rect2(24.0 + float(col) * (LOBBY_KEY_W + LOBBY_KEY_GAP),
		LOBBY_KEYPAD_Y + float(row) * (LOBBY_KEY_H + LOBBY_KEY_ROW_GAP),
		LOBBY_KEY_W, LOBBY_KEY_H)


## 房间列表行高（刘海下面的列表）
const ROOM_ROW_H := 44.0
## 地图卡片（3 列）
const MAP_CARD_W := 170.0
const MAP_CARD_H := 200.0
const MAP_CARD_GAP := 12.0
const MAP_CARD_COLS := 3
