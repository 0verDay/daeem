## story_actions.gd —— 演出系统的**目标解析 + 世界效果**（纯逻辑，不碰视图）。
##
## ★★ 为什么目标解析单独一份：
##   「按 tag 找单位 / 按类型+坐标+阵营找建筑」会在镜头、击杀、摧毁、边界、测试里
##   反复出现；各写一遍迟早会出现「镜头找得到、击杀找不到」这种半失效。
##   这里只依赖 `world.units` / `world.building_list` / `world.zones`，不做任何表现。
##
## ⚠️ 跨文件引用只用 preload 常量（`--script` 下全局 class_name 不可用）。
extends RefCounted

const MapDataRes = preload("res://logic/map_data.gd")
const UnitRes = preload("res://logic/unit.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")
const CommandProcessorRes = preload("res://logic/command_processor.gd")
const RedDotAiRes = preload("res://logic/red_dot_ai.gd")
const StoryGlowRes = preload("res://logic/story/story_glow.gd")


# ------------------------------------------------------------------
# 目标解析
# ------------------------------------------------------------------

## 把 `targets` 归一成数组：传单个字典也认。
static func target_list(v: Variant) -> Array:
	if typeof(v) == TYPE_ARRAY:
		return v
	if typeof(v) == TYPE_DICTIONARY:
		return [v]
	return []


## 解析一个**点**（逻辑格坐标，浮点）。找不到返回 Vector2(-1, -1)。
static func resolve_point(world, spec: Variant) -> Vector2:
	if world == null or typeof(spec) != TYPE_DICTIONARY:
		return Vector2(-1.0, -1.0)
	var d: Dictionary = spec

	# 1) 单位（tag / id / 阵营+类型+序号 / 坐标 / 区域）
	if d.has("tag") or d.has("unit") or d.has("unit_id") or d.has("unit_type") or d.has("kind") \
			or (d.has("faction") and not d.has("base")):
		var us: Array = resolve_units(world, d)
		if not us.is_empty():
			return (us[0] as Object).pos

	# 2) 建筑（tag / type+owner+tile / 坐标 / 大本营）
	if d.has("building") or d.has("type") or d.has("owner") or d.has("building_tile") \
			or d.has("base"):
		var bs: Array = resolve_buildings(world, d)
		if not bs.is_empty():
			var b = bs[0]
			return Vector2(float(b.tx) + 0.5, float(b.ty) + 0.5)

	# 3) 区划中心
	if d.has("zone"):
		var z = world.zone_by_id(int(d.get("zone", -1)))
		if z != null and z.get("center", null) != null:
			var c: Vector2i = z["center"]
			return Vector2(float(c.x) + 0.5, float(c.y) + 0.5)

	# 4) 直接格坐标
	if d.has("tile"):
		var t := _point_of(d["tile"])
		if t.x >= 0 and t.y >= 0:
			return Vector2(float(t.x) + 0.5, float(t.y) + 0.5)
	if d.has("x") and d.has("y"):
		var tx := int(d.get("x", -1))
		var ty := int(d.get("y", -1))
		if tx >= 0 and ty >= 0:
			return Vector2(float(tx) + 0.5, float(ty) + 0.5)
	return Vector2(-1.0, -1.0)


## 解析单位目标。支持：
##   {"tag": "..."} / {"unit_id": "..."} / {"faction": "...", "kind": "...", "index": 0}
##   {"faction": "...", "unit_type": "...", "index": 1}
##   {"tile": [x, y]} / {"faction": "...", "zone": 3}
## @return Array[Unit]（可能为空）
static func resolve_units(world, spec: Variant) -> Array:
	var out: Array = []
	if world == null or typeof(spec) != TYPE_DICTIONARY:
		return out
	var d: Dictionary = spec
	var index := int(d.get("index", -1))
	var has_index: bool = d.has("index")
	var want_tag := String(d.get("tag", d.get("unit", ""))).strip_edges()
	var want_id := String(d.get("unit_id", "")).strip_edges()
	var want_faction := String(d.get("faction", "")).strip_edges()
	var want_kind := String(d.get("kind", "")).strip_edges()
	var want_type := String(d.get("unit_type", "")).strip_edges()
	var want_zone := int(d.get("zone", -1))
	var want_tile := _point_of(d.get("tile", null)) if d.has("tile") else Vector2i(-1, -1)

	for u in world.units:
		if u == null or not u.alive:
			continue
		if want_tag != "" and String(u.tag) != want_tag:
			continue
		if want_id != "" and String(u.id) != want_id:
			continue
		if want_faction != "" and String(u.faction) != want_faction:
			continue
		if want_kind != "" and String(u.kind) != want_kind:
			continue
		if want_type != "" and String(u.unit_type) != want_type:
			continue
		if want_tile.x >= 0:
			if Vector2i(int(u.tx), int(u.ty)) != want_tile:
				continue
		if want_zone >= 0:
			var z = world.zones.zone_at(int(u.tx), int(u.ty)) if world.zones != null else null
			if z == null or int(z.get("id", -1)) != want_zone:
				continue
		out.append(u)

	if has_index and not out.is_empty():
		var i := clampi(index, 0, out.size() - 1)
		return [out[i]]
	return out


## 解析建筑目标。支持：
##   {"tag": "..."} / {"type": "tower", "owner": "F1"} / {"type": "tower", "tile": [x,y]}
##   {"tile": [x,y]} / {"base": "F1"}
## @return Array[Building]（可能为空）
static func resolve_buildings(world, spec: Variant) -> Array:
	var out: Array = []
	if world == null or typeof(spec) != TYPE_DICTIONARY:
		return out
	var d: Dictionary = spec
	var want_tag := String(d.get("tag", d.get("building", ""))).strip_edges()
	var want_type := String(d.get("type", "")).strip_edges()
	var want_owner := String(d.get("owner", "")).strip_edges()
	var want_base := String(d.get("base", "")).strip_edges()
	var have_tile: bool = d.has("tile") or d.has("building_tile")
	var want_tile := _point_of(d.get("tile", d.get("building_tile", null))) if have_tile else Vector2i(-1, -1)

	for b in world.building_list:
		if b == null or not b.alive:
			continue
		if want_tag != "" and String(b.tag) != want_tag:
			continue
		if want_type != "" and String(b.type) != want_type:
			continue
		if want_owner != "" and String(b.owner) != want_owner:
			continue
		if want_base != "":
			if String(b.type) != "base" or String(b.owner) != want_base:
				continue
		if have_tile and Vector2i(int(b.tx), int(b.ty)) != want_tile:
			continue
		out.append(b)
	return out


# ------------------------------------------------------------------
# 世界效果
# ------------------------------------------------------------------

## 强制击杀。`silent` 的语义见 `world.story_kill_unit()`。
## @return 实际处理的数量
static func kill_units(world, targets: Variant, silent: bool = false) -> int:
	if world == null:
		return 0
	var n := 0
	for spec in target_list(targets):
		var us: Array = resolve_units(world, spec)
		if us.is_empty():
			push_warning("演出：击杀目标没有命中：%s" % str(spec))
			continue
		for u in us:
			if bool(world.story_kill_unit(u, silent)):
				n += 1
	return n


## 强制摧毁建筑。大本营会被 `world.story_destroy_building()` 拒绝。
## @return 实际处理的数量
static func destroy_buildings(world, targets: Variant, silent: bool = false) -> int:
	if world == null:
		return 0
	var n := 0
	for spec in target_list(targets):
		var bs: Array = resolve_buildings(world, spec)
		if bs.is_empty():
			push_warning("演出：摧毁目标没有命中：%s" % str(spec))
			continue
		for b in bs:
			if bool(world.story_destroy_building(b, silent)):
				n += 1
	return n


# ------------------------------------------------------------------
# 生成单位 / 建筑 / 红点
# ------------------------------------------------------------------

## ★ 生成普通单位 / 将领。返回实际生成的单位数组。
##
## 步骤字段：
##   faction      必填
##   count        生成几个（默认 1；普通单位会排在附近空格）
##   spawn        出生点：`{"tile":[x,y]}` / `[[x,y],...]` / `{"rect":[x,y,w,h]}` /
##                `{"zone": n}` / 任意镜头目标（单位 / 建筑 / 区划中心 / 大本营）
##   general      1 起：生成将领（将领档）；不写 / 0 = 普通单位
##   unit_type    兵种 id（将领缺省用该档的兵种；普通单位必填）
##   name         显示名（缺省按兵种 / 将领档）
##   tag          可选作者标签
##   escort_count / escort_types  将领的附属兵（缺省 0）
##   hotkey       快捷键（教程用 "1" 表示「部队 1」）
##   locked       true = 玩家暂时不能选中 / 指挥（见 `Unit.story_locked`）
##   attack_move  可选目标描述：生成后整队向该点行军攻击
##   red_dot_wave true = 推一条 `red_dot_wave`（小地图红点生成动效）
##   announce     true = 推一条 `unit_recruited`（默认静默）
static func spawn_units(world, step: Dictionary) -> Array:
	var out: Array = []
	if world == null:
		return out
	var faction := String(step.get("faction", "")).strip_edges()
	if faction == "":
		push_warning("演出 spawn_unit：缺少 faction")
		return out
	var count := maxi(1, int(step.get("count", 1)))
	var announce := bool(step.get("announce", false))
	var spawn_spec: Variant = step.get("spawn", step.get("at", step.get("tile", null)))
	var order_spec: Variant = step.get("attack_move", null)
	for i in count:
		var tile := _pick_spawn_tile(world, spawn_spec, faction, i)
		if tile.x < 0:
			push_warning("演出 spawn_unit：找不到可站格（index=%d）" % i)
			continue
		var u = _create_story_unit(world, faction, step, tile, i)
		if u == null:
			continue
		u.story_locked = bool(step.get("locked", false))
		out.append(u)
		if announce:
			world.push_event({"type": "unit_recruited", "unit": u,
				"leader": null, "faction": faction})
	# 生成后立刻下「行军攻击」命令：教程用它让红点「出生后原地不动」。
	if order_spec != null and not out.is_empty():
		var pt := resolve_point(world, order_spec)
		if pt.x >= 0.0:
			for u2 in out:
				CommandProcessorRes.order_group_attack_move(
					world, world.cfg, world.group_of(u2), pt)
		else:
			push_warning("演出 spawn_unit：attack_move 目标解析失败")
	if bool(step.get("red_dot_wave", false)) and not out.is_empty():
		var spawns: Array = []
		for u3 in out:
			spawns.append({"x": int(u3.tx), "y": int(u3.ty)})
		world.push_event({
			"type": "red_dot_wave",
			"faction": faction,
			"wave": int(step.get("wave", 0)),
			"leaders": out.size(),
			"x": int((out[0] as Object).tx),
			"y": int((out[0] as Object).ty),
			"spawns": spawns,
		})
	return out


static func _create_story_unit(world, faction: String, step: Dictionary,
		tile: Vector2i, index: int):
	var cfg = world.cfg
	var profile := int(step.get("general", 0)) - 1
	var is_leader := profile >= 0
	if is_leader and not cfg.general_types().is_empty():
		profile = clampi(profile, 0, cfg.general_types().size() - 1)
	var unit_type := String(step.get("unit_type", "")).strip_edges()
	if unit_type == "":
		unit_type = cfg.general_type_at(profile) if is_leader else ""
	if unit_type == "":
		push_warning("演出 spawn_unit：普通单位缺少 unit_type")
		return null
	world.story_serial += 1
	var serial: int = int(world.story_serial)
	var uid := "story-%s-%d-%d" % [faction, serial, index]
	var uname := String(step.get("name", "")).strip_edges()
	if uname == "":
		uname = cfg.general_name_at(profile) if is_leader else cfg.unit_name_of(unit_type)
	if uname == "":
		uname = unit_type
	var hotkey := String(step.get("hotkey", "")).strip_edges()
	var u = null
	if is_leader:
		u = UnitRes.create(cfg, uid, uname, tile, faction, UnitRes.KIND_GENERAL,
			hotkey, "", unit_type, profile)
		if u != null:
			u.set_general_traits(cfg, cfg.general_traits_at(profile))
			u.apply_general_growth(cfg, world.base_level_of(faction))
	else:
		u = UnitRes.create(cfg, uid, uname, tile, faction, unit_type,
			hotkey, "", unit_type, -1)
	if u == null:
		return null
	u.tag = String(step.get("tag", "")).strip_edges()
	world.units.append(u)
	world.mark_vision_dirty()
	if is_leader:
		var ec := maxi(0, int(step.get("escort_count", 0)))
		var etypes: Variant = step.get("escort_types", [])
		u.retinue_target = ec
		u.retinue_types = etypes if typeof(etypes) == TYPE_ARRAY else []
		if ec > 0:
			world.fill_general_retinue(u, ec, u.retinue_types)
	return u


## ★ 生成一栋建筑（默认瞬间完成、跳过建造读条）。返回 Building 或 null。
##
## 步骤字段：faction / type / spawn(必须能解析成格) / tag / announce。
static func spawn_building(world, step: Dictionary):
	if world == null:
		return null
	var faction := String(step.get("faction", step.get("owner", ""))).strip_edges()
	var type := String(step.get("type", "")).strip_edges()
	if faction == "" or type == "":
		push_warning("演出 spawn_building：缺少 faction / type")
		return null
	var spawn_spec: Variant = step.get("spawn", step.get("at", step.get("tile", null)))
	var wanted := _point_of(spawn_spec)
	if wanted.x < 0 and typeof(spawn_spec) == TYPE_DICTIONARY:
		var p: Vector2 = resolve_point(world, spawn_spec)
		if p.x >= 0.0:
			wanted = Vector2i(int(floor(p.x)), int(floor(p.y)))
	var tile := _free_build_tile_near(world, wanted, 12)
	if tile.x < 0:
		push_warning("演出 spawn_building：找不到可放置格")
		return null
	var announce := bool(step.get("announce", false))
	var b = world.add_building(type, tile.x, tile.y, faction,
		not announce, true, String(step.get("tag", "")))
	if b == null:
		push_warning("演出 spawn_building：add_building 被拒（%s @ %s）" % [type, str(tile)])
		return null
	# 大本营即便 instant=true 也会走建造读条（add_building 的既有规则）：
	# 演出生成要的是「立刻出现」，这里直接收口。
	if String(b.type) == "base":
		b.finish_construction()
	return b


## ★ 生成一波红点（将领 + 可选满编附属兵）并向 target 行军攻击。
##
## 步骤字段：faction / spawn / target / count / general / general_weights /
##          escort_count / escort_types / name / tag / wave。
## @return 实际生成的将领数
static func spawn_red_dot(world, step: Dictionary) -> int:
	if world == null:
		return 0
	var faction := String(step.get("faction", "")).strip_edges()
	if faction == "":
		push_warning("演出 spawn_red_dot：缺少 faction")
		return 0
	var target_pt := Vector2(-1.0, -1.0)
	if step.has("target"):
		target_pt = resolve_point(world, step.get("target"))
	if target_pt.x < 0.0:
		push_warning("演出 spawn_red_dot：target 解析失败")
		return 0
	var count := maxi(1, int(step.get("count", 1)))
	var red_cfg: Dictionary = world.reddot_ai_cfg(faction)
	var weights_v: Variant = step.get("general_weights", red_cfg.get("general_weights", []))
	var weights: Array = weights_v if typeof(weights_v) == TYPE_ARRAY else []
	var escort_count := int(step.get("escort_count", red_cfg.get("escort_count", 0)))
	var etypes_v: Variant = step.get("escort_types", red_cfg.get("escort_types", []))
	var escort_types: Array = etypes_v if typeof(etypes_v) == TYPE_ARRAY else []
	var spawn_spec: Variant = step.get("spawn", null)
	world.story_serial += 1
	var serial: int = int(world.story_serial)
	var sent := 0
	var spawns: Array = []
	for n in count:
		var tile := _pick_spawn_tile(world, spawn_spec, faction, n)
		if tile.x < 0:
			continue
		var gi := int(step.get("general", 0)) - 1
		if gi < 0:
			gi = RedDotAiRes._pick_general_index(world, weights, serial, n)
		if not world.cfg.general_types().is_empty():
			gi = clampi(gi, 0, world.cfg.general_types().size() - 1)
		var g = RedDotAiRes._spawn_general(world, world.cfg, faction, gi, serial, n, tile)
		if g == null:
			continue
		var gname := String(step.get("name", "")).strip_edges()
		if gname != "":
			g.name = gname
		g.tag = String(step.get("tag", "")).strip_edges()
		if escort_count > 0:
			g.retinue_target = escort_count
			g.retinue_types = escort_types
			world.fill_general_retinue(g, escort_count, escort_types)
		CommandProcessorRes.order_group_attack_move(world, world.cfg, world.group_of(g), target_pt)
		spawns.append({"x": tile.x, "y": tile.y})
		sent += 1
	if not spawns.is_empty():
		world.push_event({
			"type": "red_dot_wave",
			"faction": faction,
			"wave": int(step.get("wave", 0)),
			"leaders": sent,
			"x": int(target_pt.x),
			"y": int(target_pt.y),
			"spawns": spawns,
		})
	return sent


# ------------------------------------------------------------------
# 呼吸泛光
# ------------------------------------------------------------------

## 给一组单位**补上**某个 id 的呼吸泛光：已经带着同一个 id 的单位不重置（波纹继续走）。
## 教程的「没选中部队时高亮己方部队」每帧调用它，新招出来的兵也能自动亮起来。
static func ensure_unit_glow(world, units: Array, gid: String, period: float = 1.2,
		strength: float = 1.0, color: String = "") -> int:
	if world == null or units.is_empty():
		return 0
	var n := 0
	for u in units:
		if u == null or not u.alive:
			continue
		var g: Dictionary = u.story_glow
		if String(g.get("id", "")) == gid and not g.is_empty():
			continue
		u.story_glow = {
			"color": color,
			"period": maxf(0.1, period),
			"start": float(world.time),
			"until": 0.0,
			"strength": clampf(strength, 0.0, 1.0),
			"id": gid,
		}
		n += 1
	if n > 0:
		world.story_glow_active = true
	return n


## 给目标加 / 覆盖呼吸泛光。返回命中的对象数。
static func glow_objects(world, step: Dictionary) -> int:
	if world == null:
		return 0
	var targets: Array = resolve_glow_targets(world, step.get("targets", step.get("target", null)))
	if targets.is_empty():
		push_warning("演出 glow_object：目标没有命中")
		return 0
	var period := maxf(0.1, float(step.get("period", 1.6)))
	var duration := maxf(0.0, float(step.get("duration", 0.0)))
	var strength := clampf(float(step.get("strength", 0.8)), 0.0, 1.0)
	var color := String(step.get("color", "")).strip_edges()
	var gid := String(step.get("id", "")).strip_edges()
	for obj in targets:
		obj.story_glow = {
			"color": color,
			"period": period,
			"start": float(world.time),
			"until": float(world.time) + duration if duration > 0.0 else 0.0,
			"strength": strength,
			"id": gid,
		}
	if not targets.is_empty():
		world.story_glow_active = true
	return targets.size()


## 给**区划**加 / 覆盖呼吸泛光（占领范围 + 区划中心）。
##
## 步骤字段：`zone` / `zones`（id / 数组）、`color`、`period`、`duration`、
##          `strength`、`id`。区划中心那份也写 `story_glow`，所以中心会同时呼吸。
static func glow_zones(world, step: Dictionary) -> int:
	if world == null:
		return 0
	var ids: Array = []
	var raw: Variant = step.get("zones", step.get("zone", null))
	if typeof(raw) == TYPE_ARRAY:
		ids = raw
	elif raw != null:
		ids = [raw]
	var period := maxf(0.1, float(step.get("period", 1.6)))
	var duration := maxf(0.0, float(step.get("duration", 0.0)))
	var strength := clampf(float(step.get("strength", 0.8)), 0.0, 1.0)
	var color := String(step.get("color", "")).strip_edges()
	var gid := String(step.get("id", "")).strip_edges()
	var n := 0
	for zid_v in ids:
		var zid := int(zid_v)
		if world.zones == null or not world.zones.zones_by_id.has(zid):
			continue
		var state := {
			"color": color,
			"period": period,
			"start": float(world.time),
			"until": float(world.time) + duration if duration > 0.0 else 0.0,
			"strength": strength,
			"id": gid,
		}
		world.story_zone_glow[zid] = state
		var center_b = _zone_center_building(world, zid)
		if center_b != null:
			center_b.story_glow = state.duplicate(true)
		n += 1
	if n > 0:
		world.story_glow_active = true
	return n


## 停止呼吸泛光。`id` / `targets` / `zones` 都不写 = 清掉全场。
static func stop_glow(world, step: Dictionary) -> int:
	if world == null:
		return 0
	var gid := String(step.get("id", "")).strip_edges()
	var has_target := step.has("targets") or step.has("target")
	var has_zone := step.has("zones") or step.has("zone")
	var targets: Array = resolve_glow_targets(world, step.get("targets", step.get("target", null))) if has_target else []
	var n := 0
	if has_target:
		for obj in targets:
			if gid != "" and String((obj.story_glow as Dictionary).get("id", "")) != gid:
				continue
			if not (obj.story_glow as Dictionary).is_empty():
				obj.story_glow = {}
				n += 1
	if has_zone:
		var raw: Variant = step.get("zones", step.get("zone", null))
		var ids: Array = raw if typeof(raw) == TYPE_ARRAY else ([raw] if raw != null else [])
		for zid_v in ids:
			var zid := int(zid_v)
			if not world.story_zone_glow.has(zid):
				continue
			var g: Dictionary = world.story_zone_glow[zid]
			if gid != "" and String(g.get("id", "")) != gid:
				continue
			world.story_zone_glow.erase(zid)
			var center_b = _zone_center_building(world, zid)
			if center_b != null and (gid == "" or String((center_b.story_glow as Dictionary).get("id", "")) == gid):
				center_b.story_glow = {}
			n += 1
	if has_target or has_zone:
		return n
	for u in world.units:
		if u == null or (u.story_glow as Dictionary).is_empty():
			continue
		if gid != "" and String((u.story_glow as Dictionary).get("id", "")) != gid:
			continue
		u.story_glow = {}
		n += 1
	for b in world.building_list:
		if b == null or (b.story_glow as Dictionary).is_empty():
			continue
		if gid != "" and String((b.story_glow as Dictionary).get("id", "")) != gid:
			continue
		b.story_glow = {}
		n += 1
	for zid2 in world.story_zone_glow.keys():
		var g2: Dictionary = world.story_zone_glow[zid2]
		if gid != "" and String(g2.get("id", "")) != gid:
			continue
		world.story_zone_glow.erase(zid2)
		var cb = _zone_center_building(world, int(zid2))
		if cb != null and (gid == "" or String((cb.story_glow as Dictionary).get("id", "")) == gid):
			cb.story_glow = {}
		n += 1
	if gid == "" and n > 0:
		world.story_glow_active = false
	return n


static func _zone_center_building(world, zid: int):
	if world == null:
		return null
	for b in world.building_list:
		if b == null or not b.alive or String(b.type) != "zone_center":
			continue
		var z = world.zone_of_center_building(b)
		if z != null and int(z.get("id", -1)) == zid:
			return b
	return null


# ------------------------------------------------------------------
# 剧情目标 / 输入策略 / 控制权 / 变量
# ------------------------------------------------------------------

## 设置左上角目标面板显示的**剧情目标**。
## 字段：`title`、`desc`、`state`（缺省 running）、`zone`（缺省 0，仅占位）。
static func set_story_objective(world, step: Dictionary) -> void:
	if world == null:
		return
	if bool(step.get("clear", false)):
		world.story_objective = {}
		return
	world.story_objective = {
		"kind": "story",
		"zone": int(step.get("zone", 0)),
		"title": String(step.get("title", "")).strip_edges(),
		"desc": String(step.get("desc", "")).strip_edges(),
		"state": String(step.get("state", "running")).strip_edges(),
	}


## 当前剧情目标标记为「已完成」（保留文案，等下一步覆盖）。
static func finish_story_objective(world) -> void:
	if world == null or (world.story_objective as Dictionary).is_empty():
		return
	world.story_objective["state"] = "won"


## 演出期输入策略（目前只有一个键：`block_single_right_click`）。
static func set_input_policy(world, step: Dictionary) -> void:
	if world == null:
		return
	if step.has("block_single_right_click"):
		world.story_input["block_single_right_click"] = bool(step["block_single_right_click"])


## 暂时锁住 / 放开玩家对某些单位的控制（`Unit.story_locked`）。
## 字段：`targets`、`locked`（缺省 true）。
static func set_unit_control(world, step: Dictionary) -> int:
	if world == null:
		return 0
	var locked := bool(step.get("locked", true))
	var n := 0
	for spec in target_list(step.get("targets", step.get("target", null))):
		for u in resolve_units(world, spec):
			u.story_locked = locked
			n += 1
	return n


## 写一个剧本临时变量（条件触发器读 `world.story_vars`）。
static func set_story_var(world, step: Dictionary) -> void:
	if world == null:
		return
	var key := String(step.get("key", "")).strip_edges()
	if key == "":
		return
	world.story_vars[key] = step.get("value", true)


## 解析泛光目标：单位 + 建筑都试一遍（同一个 tag / 坐标可能同时命中）。
static func resolve_glow_targets(world, specs: Variant) -> Array:
	var out: Array = []
	if world == null:
		return out
	for spec in target_list(specs):
		for u in resolve_units(world, spec):
			if not out.has(u):
				out.append(u)
		for b in resolve_buildings(world, spec):
			if not out.has(b):
				out.append(b)
	return out


# ------------------------------------------------------------------
# 小工具
# ------------------------------------------------------------------

## 出生格：优先用脚本给的 spec；被占 / 不可站时找最近的可站格。
static func _pick_spawn_tile(world, spec: Variant, faction: String, index: int) -> Vector2i:
	var wanted := Vector2i(-1, -1)
	if typeof(spec) == TYPE_ARRAY and not (spec as Array).is_empty():
		var arr: Array = spec
		wanted = _point_of(arr[index % arr.size()])
	elif typeof(spec) == TYPE_DICTIONARY:
		var d: Dictionary = spec
		if d.has("rect") or d.has("zone"):
			var tiles: Array = _tiles_in_spec(world, d, faction)
			if not tiles.is_empty():
				wanted = tiles[index % tiles.size()]
		else:
			var p := resolve_point(world, d)
			if p.x >= 0.0:
				wanted = Vector2i(int(floor(p.x)), int(floor(p.y)))
	if wanted.x < 0:
		wanted = world.home_base_of(faction)
	return _free_unit_tile_near(world, faction, wanted, 12)


## `rect` / `zone` 里的可站格（按确定顺序：先 y 后 x）。
static func _tiles_in_spec(world, d: Dictionary, faction: String) -> Array:
	var out: Array = []
	if d.has("zone"):
		var z = world.zone_by_id(int(d.get("zone", -1)))
		if z != null:
			for t in (z.get("tiles", []) as Array):
				var tt: Vector2i = t
				if _unit_tile_ok(world, faction, tt):
					out.append(tt)
		return out
	if d.has("rect"):
		var r: Rect2i = parse_rect(d.get("rect"))
		for y in range(r.position.y, r.position.y + r.size.y):
			for x in range(r.position.x, r.position.x + r.size.x):
				var tt2 := Vector2i(x, y)
				if _unit_tile_ok(world, faction, tt2):
					out.append(tt2)
	return out


static func _unit_tile_ok(world, faction: String, t: Vector2i) -> bool:
	if not world.map.tile_exists(t.x, t.y):
		return false
	if not world.tile_in_boundary(t.x, t.y):
		return false
	if world.building_at(t.x, t.y) != null:
		return false
	return PathfinderRes.passable(world.map, world.buildings, world.cfg, t.x, t.y, faction)


static func _free_unit_tile_near(world, faction: String, wanted: Vector2i, max_radius: int) -> Vector2i:
	if wanted.x >= 0 and _unit_tile_ok(world, faction, wanted):
		return wanted
	for r in range(1, max_radius + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var t := Vector2i(wanted.x + dx, wanted.y + dy)
				if _unit_tile_ok(world, faction, t):
					return t
	return Vector2i(-1, -1)


static func _free_build_tile_near(world, wanted: Vector2i, max_radius: int) -> Vector2i:
	if wanted.x >= 0 and _build_tile_ok(world, wanted):
		return wanted
	for r in range(1, max_radius + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var t := Vector2i(wanted.x + dx, wanted.y + dy)
				if _build_tile_ok(world, t):
					return t
	return Vector2i(-1, -1)


static func _build_tile_ok(world, t: Vector2i) -> bool:
	if not world.map.tile_exists(t.x, t.y):
		return false
	if not world.tile_in_boundary(t.x, t.y):
		return false
	if not world.map.terrain_walkable(t.x, t.y):
		return false
	return world.building_at(t.x, t.y) == null

## 把 `[x, y]` / `{"x":…,"y":…}` / Vector2i 归一成 Vector2i；认不出 → (-1,-1)。
static func _point_of(v: Variant) -> Vector2i:
	if typeof(v) == TYPE_VECTOR2I:
		return v
	if typeof(v) == TYPE_VECTOR2:
		return Vector2i(int(floor((v as Vector2).x)), int(floor((v as Vector2).y)))
	if typeof(v) == TYPE_ARRAY:
		var a: Array = v
		if a.size() >= 2:
			return Vector2i(int(a[0]), int(a[1]))
	if typeof(v) == TYPE_DICTIONARY:
		var d: Dictionary = v
		return Vector2i(int(d.get("x", -1)), int(d.get("y", -1)))
	return Vector2i(-1, -1)


## 把 `[x, y, w, h]` / `{"x","y","w","h"}` / Rect2i / Rect2 归一成 Rect2i。
## 认不出 → 空矩形（宽/高为 0）。
static func parse_rect(v: Variant) -> Rect2i:
	if typeof(v) == TYPE_RECT2I:
		return v
	if typeof(v) == TYPE_RECT2:
		var r: Rect2 = v
		return Rect2i(int(r.position.x), int(r.position.y), int(r.size.x), int(r.size.y))
	if typeof(v) == TYPE_ARRAY:
		var a: Array = v
		if a.size() >= 4:
			return Rect2i(int(a[0]), int(a[1]), int(a[2]), int(a[3]))
	if typeof(v) == TYPE_DICTIONARY:
		var d: Dictionary = v
		if d.has("x") and d.has("y"):
			return Rect2i(int(d.get("x", 0)), int(d.get("y", 0)),
				int(d.get("w", d.get("width", 0))), int(d.get("h", d.get("height", 0))))
	return Rect2i(0, 0, 0, 0)


## 新矩形是否**包含**旧矩形（`map_boundary_expand` 只允许扩大）。
static func rect_contains(outer: Rect2i, inner: Rect2i) -> bool:
	if inner.size.x <= 0 or inner.size.y <= 0:
		return true
	return inner.position.x >= outer.position.x \
		and inner.position.y >= outer.position.y \
		and inner.position.x + inner.size.x <= outer.position.x + outer.size.x \
		and inner.position.y + inner.size.y <= outer.position.y + outer.size.y
