## morale_fill.gd —— **部队图标**背后的士气填充（自下而上，随士气下降而降低 + 变色）
##
## ★ 需求原话：「任何部队，其图标均为其序号，有纯色填充背景代表该部队士气，
##   士气背景显示会随着士气数值减少而下降 + 变色」。
##
## ★ 画法（与 hp_bar.gd 同一条思路：几何与配色都在别处，这里只拼一次绘制）：
##   · **底**：图标整块先铺一层很淡的暗色（`bg_empty`）—— 未填充的部分也要能看见
##     「这里有一个图标」，否则士气见底时数字会直接浮在地图上；
##   · **填充**：从图标**底边向上**长，高度 = 图标高 × 士气比例；
##     比例越低，填充的顶边越往下（= 「下降」），同时颜色由绿（高）→ 红（低）
##     （`ui_style.morale_plate` 的两个端点色）。
##
## ★ 纯画：不读 world、不碰任何状态 —— 调用方把「图标矩形 + 士气比例」递进来即可。
##   只有**部队**图标走这里；单个单位 / 建筑按需求「没有纯色背景填充」，不走。
extends RefCounted

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")


## 在 `ci` 上画一块部队图标的士气背景。
##   @param icon  图标矩形（控件局部坐标）
##   @param ratio 士气比例（0..1；越界会被夹住）
##
## ★ 填充区**避开图标底部那条血条**（`HP_BAR_H`）：两者都贴底，叠在一起时
##   士气见底那一点点红会被绿血条盖掉（实测 20% 士气只剩 3px 可见）。
##   现在血条仍是图标底部的一条，士气填充长在它**上方**那段里。
static func draw(ci: CanvasItem, icon: Rect2, ratio: float) -> void:
	var r: float = clampf(ratio, 0.0, 1.0)
	# 暗底：未填充那一段的「槽」—— 与血条的深底同一套观感
	ci.draw_rect(icon, UiStyleRes.bg_empty(), true)
	if r <= 0.0:
		return
	var usable: float = maxf(1.0, icon.size.y - UiLayoutRes.HP_BAR_H)
	var h: float = usable * r
	ci.draw_rect(
		Rect2(icon.position.x, icon.position.y + usable - h, icon.size.x, h),
		UiStyleRes.morale_plate(r, true), true)


## 士气比例 → 填充色（给不画图只验色的地方用）。
static func color_for(ratio: float) -> Color:
	return UiStyleRes.morale_plate(clampf(ratio, 0.0, 1.0), true)
