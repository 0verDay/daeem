## icon_badge.gd —— 详细信息栏里**一个图标方块**的统一画法
##
## ★ 三处调用点：左栏上半那一格（view/unit_roster.gd）、左栏下半网格
##   （view/troop_grid.gd）、右栏头像（view/detail_panel.gd）。
##   它们的方块尺寸不同（40×40 / 72×72），但「里面画什么」必须一致，
##   否则同一个兵在左栏和右栏会长得不一样。
##
## ★★ 本版按需求定下的两种画法（别再混）：
##   · **部队**（kind = "troop"）：图标 = **序号**（1..9、第 10 个写 0），
##     背后是**士气填充**（view/morale_fill.gd：自下而上、越低越矮、绿→红）；
##   · **单个单位 / 建筑 / 区划**（其它 kind）：**没有纯色背景填充**，
##     只有图标字 + 底部血条（血条由 `show_hp` 决定画不画）。
##
## ★ 纯画：不读 world、不碰状态。边框颜色 / 线宽由调用方给（悬停 / 交战要换色）。
extends RefCounted

const UiStyleRes = preload("res://view/ui_style.gd")
const HpBarRes = preload("res://view/hp_bar.gd")
const MoraleFillRes = preload("res://view/morale_fill.gd")


## 部队序号怎么写：1..9 原样，第 10 支写 0（与右侧部队列表 `squad_panel` 同一口径）。
## 编号 <= 0（拿不到编号）→ 空串，由调用方退回别的图标字。
static func troop_number_text(number: int) -> String:
	if number <= 0:
		return ""
	return str(number % 10)


## 画一个图标方块。
##   @param kind      "troop" = 部队（序号 + 士气填充）；其它 = 单位 / 建筑（无填充）
##   @param text      方块里那个字（部队 = 序号；单位 / 建筑 = 名字首字）
##   @param morale    士气比例（只有 kind == "troop" 时用）
##   @param hp_ratio  血量比例（`show_hp` 为 true 时画在图标底部）
##   @param show_hp   要不要画底部血条
##   @param font_size 方块里那个字的字号
##   @param border    边框色（悬停 / 交战由调用方换成强调色 / 红）
static func draw(ci: CanvasItem, f: Font, icon: Rect2, kind: String, text: String,
		morale: float, hp_ratio: float, show_hp: bool, font_size: int,
		border: Color, border_w: float = 1.0) -> void:
	if kind == "troop":
		MoraleFillRes.draw(ci, icon, morale)
	# ★ 单个单位 / 建筑 / 区划：这里**什么都不填**（需求：没有纯色背景填充）
	ci.draw_rect(icon, border, false, border_w)
	if text != "" and f != null:
		_draw_centered(ci, f, text, icon, UiStyleRes.text(), font_size)
	if show_hp:
		HpBarRes.draw(ci, icon, hp_ratio)


## 在一个矩形里居中画一行字（`draw_string` 的 pos 是基线，垂直居中要按字号推）。
static func _draw_centered(ci: CanvasItem, f: Font, text: String, r: Rect2,
		color: Color, size: int) -> void:
	if text == "":
		return
	var w: float = f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var baseline: float = r.position.y + r.size.y * 0.5 + float(size) * 0.5 - 2.0
	ci.draw_string(f, Vector2(r.position.x + (r.size.x - w) * 0.5, baseline), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
