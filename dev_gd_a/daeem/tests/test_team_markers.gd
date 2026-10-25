## test_team_markers.gd —— 头顶编队标识的**纯函数**（键帽文案 / 尺寸）。
##
## ★ 为什么只测这两件事：绘制本身要靠窗口截图，无头下不能跑 `_draw()`；
##   但「第 10 支写 0」和「键帽跟着立牌高度走」都是纯函数，可以直接钉住。
##   画法（键帽 / 名牌 / 倒地 / 避让）由 `overlay_view_3d.gd` 的注释与截图验收。
extends "res://tests/test_case.gd"

const OverlayRes = preload("res://view/overlay_view_3d.gd")


func _initialize() -> void:
	_case_name = "test_team_markers"
	run_all(_cases)


func _cases() -> void:
	# 1..9 原样；第 10 支写 0（与数字键 / 左栏同一口径）。
	eq(OverlayRes.badge_text(1), "1", "★ 第 1 支写 1")
	eq(OverlayRes.badge_text(9), "9", "★ 第 9 支写 9")
	eq(OverlayRes.badge_text(10), "0", "★ 第 10 支写 0（与数字键一致）")
	eq(OverlayRes.badge_text(0), "", "★ 没有编号 → 空串")
	eq(OverlayRes.badge_text(-1), "", "★ 非法编号 → 空串")

	# 键帽边长跟着立牌屏幕高度浮动，并夹在 [16, 26]。
	near(OverlayRes.badge_size_for(20.0), 16.0, 0.001, "★ 立牌很小 → 夹到下限 16")
	near(OverlayRes.badge_size_for(40.0), 24.8, 0.001, "★ 立牌 40px → 键帽 24.8")
	near(OverlayRes.badge_size_for(100.0), 26.0, 0.001, "★ 立牌很大 → 夹到上限 26")
