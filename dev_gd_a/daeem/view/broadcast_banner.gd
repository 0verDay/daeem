## broadcast_banner.gd —— 兼容入口：左下角小地图正上方的播报横幅。
##
## ★★ 本文件现在只是 `view/notice_stack.gd` 的薄子类：
##   播报与对话共用同一套栈（对话出现时播报上移，见 notice_stack.gd 的文件头）。
##   保留这个文件名 / 类名是为了现有 HUD、测试与 `preload("res://view/broadcast_banner.gd")`
##   一处都不用改。
extends "res://view/notice_stack.gd"
