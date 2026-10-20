## coop_catalog.gd —— 合作大厅的「地图目录」。
##
## 约定（2026.10.20 用户确认）：**一个 `mode="coop"` 的关卡 = 一张合作地图**。
## 所以这里不新建地图元数据，直接扫所有战役里的 coop 关卡：
##   · 地图 id / 缩略图来自关卡引用的 `data/maps/<map_id>/`；
##   · 地图名优先读地图 JSON 的 `name`；
##   · 描述用关卡 `briefing`（多行拼接），没有就退回 `Level.summary()`。
##
## 选地图 = 选这个 coop 关卡；开局仍走 `main.gd` 的 start_coop_host(campaign, level)。
##
## ⚠️ 跨文件引用只用 preload（命令行 `--script` 下全局 class_name 不可用）。
extends RefCounted

const CampaignLibraryRes = preload("res://logic/campaign_library.gd")
const CampaignRes = preload("res://logic/campaign.gd")
const MapLibraryRes = preload("res://logic/map_library.gd")
const MapDataRes = preload("res://logic/map_data.gd")


## 扫出所有 coop 关卡（= 合作地图），按 map_id / 关卡 id 稳定排序。
##
## @return Array[Dictionary] 每项：
##   {campaign, level, level_obj, map_id, map_path, map_name, desc}
static func entries(cfg) -> Array:
	var out: Array = []
	var options: Array = CampaignLibraryRes.coop_campaigns(cfg)
	for option in options:
		var c = CampaignLibraryRes.load_campaign_by_option(option as Dictionary, cfg)
		if c == null:
			continue
		for lv in c.levels:
			if lv == null or String(lv.mode) != "coop":
				continue
			var map_id := String(lv.map_id).strip_edges()
			if map_id == "":
				continue
			var map_path := MapLibraryRes.find_map_file(
				"%s/%s" % [MapLibraryRes.MAPS_DIR, map_id], map_id)
			if map_path == "":
				continue
			out.append({
				"campaign": String(c.id),
				"level": String(lv.id),
				"level_name": String(lv.name),
				"level_obj": lv,
				"map_id": map_id,
				"map_path": map_path,
				"map_name": MapLibraryRes.display_name(map_path, map_id),
				"desc": _desc_of(lv),
			})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ka := "%s/%s" % [String(a["map_id"]), String(a["level"])]
		var kb := "%s/%s" % [String(b["map_id"]), String(b["level"])]
		return ka < kb)
	return out


static func _desc_of(lv) -> String:
	var lines: Array = []
	for raw in lv.briefing:
		var line := String(raw).strip_edges()
		if line != "":
			lines.append(line)
	if not lines.is_empty():
		return "\n".join(lines)
	return String(lv.summary())


## 按 `campaign/level` 找一项（找不到返回空字典）。
static func find_entry(entries: Array, campaign_id: String, level_id: String) -> Dictionary:
	for item in entries:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		if String(d.get("campaign", "")) == campaign_id and String(d.get("level", "")) == level_id:
			return d
	return {}


## 载入一张地图的 `MapData`（缩略图用）。失败返回 null。
## ★ 调用方自己按路径缓存；这里不做全局缓存，避免测试之间串数据。
static func load_map(path: String, cfg):
	return MapDataRes.load_from(path, cfg)


## 关卡文件里写的 `briefing` / 地图名等只用于显示；真正的 level 数据由
## `game_scene3d.start_coop_host()` 从 `level_obj` 里取。
