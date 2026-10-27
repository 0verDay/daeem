## campaign_menu_brief.gd —— 把 `campaigns_menu.json` 的一章解析成「界面能直接显示」的数据。
##
## 输出统一形状，战役地图 / 详情 / 测试都从这里取，避免各写一份：
##   {
##     "placeholder": bool,
##     "chapter": Dictionary,
##     "campaign": Campaign|null,
##     "level": Level|null,
##     "entries": Array,          # LevelBrief.playable_entries()
##     "map": MapData|null,
##     "title": String,
##     "description": String,
##   }
##
## ★ 这是**只读数据整理**，不建节点、不碰 world。
extends RefCounted

const CampaignLibraryRes = preload("res://logic/campaign_library.gd")
const LevelBriefRes = preload("res://logic/level_brief.gd")


static func resolve(cfg, chapter: Dictionary) -> Dictionary:
	var cid := String(chapter.get("campaign_id", "")).strip_edges()
	var lid := String(chapter.get("level_id", "")).strip_edges()
	var title := String(chapter.get("name", "")).strip_edges()
	var desc := String(chapter.get("description", "")).strip_edges()
	if cid == "" or lid == "":
		return {
			"placeholder": true,
			"chapter": chapter,
			"campaign": null,
			"level": null,
			"entries": [],
			"map": null,
			"title": title,
			"description": desc if desc != "" else "该关卡尚未开放。",
		}

	var option := {}
	for item in CampaignLibraryRes.list_campaigns(cfg):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		if String((item as Dictionary).get("id", "")) == cid:
			option = item
			break
	if option.is_empty():
		return _placeholder(chapter, title, desc)

	var campaign = CampaignLibraryRes.load_campaign_by_option(option, cfg)
	var level = campaign.level(lid) if campaign != null and campaign.has_method("level") else null
	if level == null:
		return _placeholder(chapter, title, desc)

	if title == "":
		title = String(level.name)
	if desc == "":
		desc = LevelBriefRes.briefing_text(level)
	return {
		"placeholder": false,
		"chapter": chapter,
		"campaign": campaign,
		"level": level,
		"entries": LevelBriefRes.playable_entries(level),
		"map": level.map,
		"title": title,
		"description": desc,
	}


static func _placeholder(chapter: Dictionary, title: String, desc: String) -> Dictionary:
	return {
		"placeholder": true,
		"chapter": chapter,
		"campaign": null,
		"level": null,
		"entries": [],
		"map": null,
		"title": title,
		"description": desc if desc != "" else "该关卡尚未开放。",
	}
