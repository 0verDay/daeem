## story_registry.gd —— **战役 id → 剧本脚本** 的唯一登记处。
##
## ★★ 为什么是显式 preload 表，而不是按 id 拼路径 `load("res://…/%s.gd")`：
##   Godot 导出时只会把**被引用到**的脚本打进 PCK；一个只靠运行时拼路径的剧本
##   在编辑器里能跑、导出后却「读不到」，而且不报错（静默缺少演出）。
##   显式 preload 同时让「有哪些战役有剧本」在一处可读。
##
## ★ 新增一个战役剧本 = 新建 `logic/story/campaigns/<id>.gd` + 在下面加一行。
##
## ⚠️ 跨文件引用只用 preload 常量（`--script` 下全局 class_name 不可用）。
extends RefCounted

const DemoScript = preload("res://logic/story/campaigns/demo.gd")
const TutorialScript = preload("res://logic/story/campaigns/tutorial.gd")


## 返回一个剧本脚本（GDScript），没有则 null。
## 剧本脚本约定：`static func build(director, world) -> void`。
static func script_for(campaign_id: String) -> GDScript:
	match campaign_id:
		"demo":
			return DemoScript
		"tutorial":
			return TutorialScript
	return null


## 这个战役有没有写剧本。
static func has_script(campaign_id: String) -> bool:
	return script_for(campaign_id) != null
