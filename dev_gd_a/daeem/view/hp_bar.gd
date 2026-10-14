## hp_bar.gd —— 详细信息面板里**图标底部那条血量条**（网格格子 / 右栏头像共用）
##
## ★ 需求原话：「所有单位图标底部都需要增加一个水平长度等于单位图标、竖直长度很小的
##   血量条，该血量条需要绑定该单位的血量」。
##
## ★ 几何（宽度 = 图标宽度、贴图标内部底边）在 `view/ui_layout.gd` 的 `hp_bar_rect()`；
##   配色（按血量比例绿→黄→红 + 深底）在 `view/ui_style.gd`。本文件只把两者拼成一次绘制，
##   所以网格（view/troop_grid.gd）与头像（view/detail_panel.gd）画出来的是同一条东西。
##
## ★ 纯画：不读 world、不碰任何状态 —— 调用方把「图标矩形 + 血量比例」递进来即可。
extends RefCounted

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")


## 在 `ci` 上画一条血量条。
##   @param icon 图标的矩形（控件局部坐标；血条取它的底边、与它同宽）
##   @param ratio 血量比例（0..1；越界会被夹住）
static func draw(ci: CanvasItem, icon: Rect2, ratio: float) -> void:
	var r: Rect2 = UiLayoutRes.hp_bar_rect(icon)
	ci.draw_rect(r, UiStyleRes.hp_bar_bg(), true)
	var w: float = r.size.x * clampf(ratio, 0.0, 1.0)
	if w > 0.0:
		ci.draw_rect(Rect2(r.position, Vector2(w, r.size.y)), UiStyleRes.hp_bar_color(ratio), true)


## 血量比例 → 填充色（转发给 ui_style，给不画图只验色的地方用）。
static func color_for(ratio: float) -> Color:
	return UiStyleRes.hp_bar_color(ratio)
