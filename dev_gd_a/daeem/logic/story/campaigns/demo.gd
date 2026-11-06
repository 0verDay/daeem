## demo.gd —— 样例战役「东征」的演出剧本。
##
## ★★ 本轮只放**骨架**：不接任何具体关卡内容（用户口径：先做前置系统）。
##   需要内容时，把下面注释里的示例取消注释 / 改字即可。
##
## 剧本约定：
##   · `static func build(director, world)` 在**关卡开局**调用一次；
##   · 用 `director.on_start / on_time / on_event / on_zone_owner / on_condition`
##     注册触发器；
##   · 触发器命中后跑一段步骤数组（见 docs/dev_plan_15.md 第 4.3 节）。
##
## ⚠️ 这里**不要**读输入、不要改视图；剧本只描述「发生什么」。
extends RefCounted


static func build(_director, _world) -> void:
	# 示例（当前不启用）：
	#
	# _director.on_start([
	#     {"kind": "lock_input", "allow": ["camera", "dialogue", "skip"]},
	#     {"kind": "camera_move", "target": {"base": "F1"}, "sec": 1.2, "zoom": 0.24},
	#     {"kind": "dialogue", "text": "敌军正在渡口集结。守住这里，别让他们过河。"},
	#     {"kind": "unlock_input"},
	# ])
	#
	# _director.on_time(90.0, [
	#     {"kind": "dialogue", "text": "斥候来报：北面的山路开了。"},
	#     {"kind": "map_boundary", "rect": [0, 0, 27, 16]},
	# ])
	#
	# _director.on_event("building_down", {"tag": "north_gate"}, [
	#     {"kind": "dialogue", "text": "北门破了！"},
	# ])
	pass
