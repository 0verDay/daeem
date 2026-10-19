## level_brief.gd —— ★ 关卡「简报」的**唯一整理处**（过渡画面 / 阵营选择 / 测试共用）
##
## 为什么单独一份、而且放在 logic/：
##   过渡画面要显示的东西（战役名 / 关卡名 / 简报 / 可玩阵营 / 各自目标）全部是**数据**，
##   把它们拼成字符串的规则只该有一份 —— 否则「蓝方守住 c1 150 秒」会在
##   画面、卡牌、测试里各写一遍，改一个数就对不上。
##   ★ 这里**不碰节点、不读配置颜色**：颜色只把 `level.faction_colors` 里的字符串带出去，
##     由 view 层解析（与 `Level` 那条「载入时抄一份」的规矩一致）。
##
## ★ `briefing` 字段**本来就有**（`logic/level.gd` 的 `var briefing: Array`，一直没人读）；
##   这次直接用它：关卡 JSON 里写一段/几段中文，缺省时由这里按「目标 + 可玩阵营」自动兜底。
extends RefCounted

## 目标种类（与 `logic/level.gd` 的同名常量为同一套字符串，避免 view 反向 preload logic）。
const OBJ_HOLD_ZONE := "hold_zone"
const OBJ_CAPTURE_ZONE := "capture_zone"


## 标题：战役名 · 关卡名（战役名缺失时只留关卡名）。
static func title(campaign, level) -> String:
	var cname := campaign_name(campaign)
	var lname := level_name(level)
	if cname == "":
		return lname
	if lname == "":
		return cname
	return "%s · %s" % [cname, lname]


static func campaign_name(campaign) -> String:
	if campaign == null:
		return ""
	return String(campaign.name).strip_edges()


static func level_name(level) -> String:
	if level == null:
		return ""
	return String(level.name).strip_edges()


## 简报正文：关卡 JSON 的 `briefing[]` 逐段换行；没写就自动生成。
static func briefing_text(level) -> String:
	if level == null:
		return ""
	var lines: Array = level.briefing if level.briefing != null else []
	var out: Array = []
	for line in lines:
		var s := String(line).strip_edges()
		if s != "":
			out.append(s)
	if not out.is_empty():
		return "\n".join(out)
	return auto_briefing(level)


## 自动兜底：每一方可玩阵营一行「名字：目标」。
static func auto_briefing(level) -> String:
	var entries: Array = playable_entries(level)
	if entries.is_empty():
		return "这一关没有登记可玩阵营。"
	var lines: Array = ["本关目标："]
	for e in entries:
		var d: Dictionary = e
		lines.append("· %s：%s" % [String(d["name"]), String(d["goal"])])
	return "\n".join(lines)


## 可玩阵营（顺序 = `level.playable_ids()`，即战役数据里的顺序）。
## 每项：{id, name, color(字符串，可能是空), goal}
static func playable_entries(level) -> Array:
	var out: Array = []
	if level == null:
		return out
	for raw in level.playable_ids():
		var fid := String(raw)
		out.append({
			"id": fid,
			"name": faction_name(level, fid),
			"color": faction_color(level, fid),
			"goal": goal_text(level, fid),
		})
	return out


static func faction_name(level, fid: String) -> String:
	if level == null:
		return fid
	var n := String(level.faction_names.get(fid, "")).strip_edges()
	return n if n != "" else fid


## `level.faction_colors` 里那份 `"#rrggbb"`；没写就空串（由 view 用主题的兜底色）。
static func faction_color(level, fid: String) -> String:
	if level == null:
		return ""
	return String(level.faction_colors.get(fid, "")).strip_edges()


## 这一方可玩阵营的目标，一句话（给卡牌 / 自动简报用）。
static func goal_text(level, fid: String) -> String:
	if level == null:
		return "自由作战"
	var obj = level.objective_for(fid)
	if obj == null or typeof(obj) != TYPE_DICTIONARY:
		return "自由作战"
	var d: Dictionary = obj
	var kind := String(d.get("kind", "")).strip_edges().to_lower()
	var zone := int(d.get("zone", -1))
	match kind:
		OBJ_HOLD_ZONE:
			var sec := int(round(float(d.get("hold_sec", 0.0))))
			if sec > 0:
				return "守住%s %d 秒" % [zone_label(level, zone), sec]
			return "守住%s" % zone_label(level, zone)
		OBJ_CAPTURE_ZONE:
			return "攻占%s" % zone_label(level, zone)
		"":
			return "自由作战"
		_:
			return "目标：%s" % kind


## 目标区划的显示名（`c1` / `区划 4`）；带一个前置空格，供上面的句子直接拼。
static func zone_label(level, zone: int) -> String:
	if zone < 0:
		return "目标区"
	if level != null and level.map != null:
		var n := String(level.map.zones_names.get(zone, "")).strip_edges()
		if n != "":
			return "「%s」" % n
	return "区划 %d" % zone


## 目标涉及到的区划 id（给缩略图高亮用；去重、保持出现顺序）。
static func objective_zone_ids(level) -> Array:
	var out: Array = []
	if level == null:
		return out
	for raw in level.objectives:
		var d: Dictionary = raw
		var z := int(d.get("zone", -1))
		if z >= 0 and not out.has(z):
			out.append(z)
	return out


## 「单人 / 合作」文案（过渡画面右上角的小字）。
static func mode_text(level) -> String:
	if level == null:
		return ""
	return "合作" if String(level.mode) == "coop" else "单人"
