## campaign_library.gd —— ★ 扫描 `data/campaigns/`，给界面出选项。
##
## ★★ 扫描规则（**照抄** `logic/map_library.gd` 那四条，一个字都不改口径）：
##   1. 只认 `CAMPAIGNS_DIR`（`res://data/campaigns`）下的**一级子目录**，目录名 = 战役 id；
##   2. 每个目录里找一份元信息 JSON，候选顺序：`campaign.json` → `<目录名>.json` → 任一 `*.json`；
##   3. 解析失败（不是合法 JSON / 不是对象 / 一关都读不出来）→ **跳过、不冒泡**：
##      一个战役写坏了不该让整条选择条空掉，更不该让主界面开不出来；
##   4. 显示名优先读 `name` 字段，没有 / 空串 → 退回目录名。
##   于是「加一个战役」= 往 `data/campaigns/` 下放一个新目录，**不改任何代码、不改配置**。
##
## ★ 选项顺序按**目录名**（不区分大小写）排，稳定可预期。
##
## ★ 每项的形状（view/campaign_select.gd 直接拿去建选项）：
##     { "id": String, "name": String, "dir": String, "path": String,
##       "description": String, "default_mode": String, "levels": int }
##
## ⚠️ 跨文件引用只用**本文件里的 preload 常量**（`--script` 下全局 class_name 不可用）。
extends RefCounted

const CampaignRes = preload("res://logic/campaign.gd")

## 战役根目录（= `campaign.gd` 的同名常量；这里再写一份是因为本文件要独立扫目录）。
const CAMPAIGNS_DIR := "res://data/campaigns"


## 扫描战役目录，返回按目录名排序的选项表。
##
## @param cfg 全局配置（`logic/config.gd` 的 Config）。★ 建议显式传：
##        关卡里要载入地图，而地图需要 config（网格尺寸 / 阵营表 / 地形代价）。
##        省略时由本文件按 `res://data/config.json` 载入一份（只为列个表也能用）。
## @return Array[Dictionary]；一个都没有时返回**空数组**（调用方自己决定怎么兜底）
static func list_campaigns(cfg = null) -> Array:
	var out: Array = []
	var use = cfg
	if use == null:
		use = _load_default_config()
		if use == null:
			return out
	var dir := DirAccess.open(CAMPAIGNS_DIR)
	if dir == null:
		# 目录不存在 / 打不开：不是错误路径（比如还没建任何战役），安静返回空表。
		return out

	var names: Array = []
	for sub in dir.get_directories():
		names.append(String(sub))
	names.sort_custom(func(a: String, b: String) -> bool:
		return a.to_lower() < b.to_lower())

	for sub in names:
		var folder := "%s/%s" % [CAMPAIGNS_DIR, sub]
		var c = CampaignRes.load_campaign(folder, use)
		if c == null:
			continue                        # 坏数据跳过，不冒泡（见文件头第 3 条）
		out.append({
			"id": String(c.id),
			"name": String(c.name),
			"dir": String(c.dir_path),
			"path": String(c.path),
			"description": String(c.description),
			"default_mode": String(c.default_mode),
			"levels": int(c.level_count()),
		})
	return out


## 不传 cfg 时兜底载入工程里那一份配置。
static func _load_default_config():
	var cls := load("res://logic/config.gd")
	if cls == null:
		return null
	return cls.load_default()


## ★★ 哪些关卡**可点**（顺序解锁）。
##
## ★ 为什么这是一个**纯函数**（而不是「去问存档」）：
##   用户明确说「目前不做进度存档，但要留出可扩展的部分」（dev_plan_7 3.10）。
##   留口子的方式不是先写一半存档代码，而是把「哪些关可点」写成
##   `unlocked_levels(campaign, progress)` —— 将来把 `progress` 从「本会话内存」
##   换成「读文件」，界面一行都不用改。
##
## @param progress `{campaign_id: [已通关 level_id, ...]}`；传空字典 = 只解锁第一关
## @return Array[Level]（可点的那些，按关卡顺序）
static func unlocked_levels(campaign, progress: Dictionary = {}) -> Array:
	var out: Array = []
	if campaign == null:
		return out
	if String(campaign.unlock) != CampaignRes.UNLOCK_IN_ORDER:
		# 以后会有别的解锁方式；第一版一律按顺序。
		pass
	var done: Array = []
	var table: Variant = progress.get(String(campaign.id), null)
	if typeof(table) == TYPE_ARRAY:
		done = table
	for i in campaign.level_count():
		var lv = campaign.level_at(i)
		if lv == null:
			continue
		# 第一关永远可点；之后的每一关要求**上一关**已经通关（严格顺序）
		if i == 0 or done.has(String(campaign.level_at(i - 1).id)):
			out.append(lv)
		else:
			break                           # 顺序解锁：一旦断档，后面的都不可点
	return out


## 这一关通没通关（界面画「已通关」标记用）。
static func is_cleared(progress: Dictionary, campaign_id: String, level_id: String) -> bool:
	var table: Variant = progress.get(campaign_id, null)
	if typeof(table) != TYPE_ARRAY:
		return false
	return (table as Array).has(level_id)


## 把「通关了某一关」记进进度字典（**原地改**；内存版的存档）。
static func mark_cleared(progress: Dictionary, campaign_id: String, level_id: String) -> void:
	var table: Array = []
	var cur: Variant = progress.get(campaign_id, null)
	if typeof(cur) == TYPE_ARRAY:
		table = cur
	if not table.has(level_id):
		table.append(level_id)
	progress[campaign_id] = table


## 按 `list_campaigns()` 给出的一项，把**那份战役真的载入出来**（`Campaign`；读不出来 → null）。
##
## ★ 为什么要有它：选项表里只有 `id` / `name` / `dir` 这些**给人看**的东西，
##   而界面按下某一项时需要的是**关卡与阵营**（那是 `Campaign` 才有的）。
##   ⚠️ 载入必须与扫描用**同一条路**（`Campaign.load_campaign`）——
##      界面自己拼路径再读一遍的话，两份数据迟早会漂
##      （典型症状：列表上有这一项，点进去说「读不出来」）。
static func load_campaign_by_option(option: Dictionary, cfg = null):
	var dir := String(option.get("dir", ""))
	if dir == "":
		dir = String(option.get("path", ""))
	if dir == "":
		return null
	return CampaignRes.load_campaign(dir, cfg)


## 扫出来的战役里，**有合作关**的那些（合作大厅建房时只列得出来的战役）。
static func coop_campaigns(cfg = null) -> Array:
	var out: Array = []
	for it in list_campaigns(cfg):
		var c = CampaignRes.load_campaign(String((it as Dictionary)["dir"]), cfg)
		if c == null:
			continue
		for lv in c.levels:
			if String((lv as RefCounted).mode) == "coop":
				out.append(it)
				break
	return out
