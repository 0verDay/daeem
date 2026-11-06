## story_triggers.gd —— 演出触发器的**匹配函数**（纯逻辑）。
##
## ★ 导演只负责「什么时候调用它」；这里只回答「这条事件 / 这个对象符不符合 filter」。
##   分开写是为了让触发条件可以被单测直接覆盖，不必造一整段演出。
##
## ⚠️ 跨文件引用只用 preload 常量（`--script` 下全局 class_name 不可用）。
extends RefCounted

const Consts = preload("res://logic/story/story_consts.gd")


## 一条 world 事件是否匹配 `type` + `filter`。
##
## filter 支持：
##   · 事件本身的字段：{"kind": "building_upgrade", "faction": "F1", "reason": "..."}
##   · 事件带 `unit`：{"tag","unit_id","faction","kind","unit_type","tile","zone"}
##   · 事件带 `building`：{"tag","type","owner","tile","base"}
static func event_matches(world, event: Variant, type_filter: String, filter: Variant) -> bool:
	if typeof(event) != TYPE_DICTIONARY:
		return false
	var ev: Dictionary = event
	if type_filter != "" and String(ev.get("type", "")) != type_filter:
		return false
	if typeof(filter) != TYPE_DICTIONARY or (filter as Dictionary).is_empty():
		return true
	var f: Dictionary = filter

	# 对象型过滤：事件里带 unit / building 时交给对象匹配（同时保留事件字段匹配）。
	var u: Variant = ev.get("unit", null)
	if u != null and not unit_matches(u, f):
		return false
	var b: Variant = ev.get("building", null)
	if b != null and not building_matches(b, f):
		return false

	# 事件字段匹配：只检查 filter 里出现了、且事件自己也有 / 对象上也没有的键。
	# ★ 不要求 filter 的每个键都在事件里（例如 filter 同时写 tag 与 reason 时，
	#   tag 在 unit 上、reason 在事件上）；但不认识的键会让这一条**不匹配**，
	#   避免「写错字段名 → 条件永远成立」这种静默过宽。
	for k in f.keys():
		var key := String(k)
		if ev.has(key):
			if not _same(ev[key], f[k]):
				return false
			continue
		# ★ `kind` / `faction` 这类键既是事件字段、也可能在对象上：
		#   事件自己没带时才交给对象匹配（上面已经做过一次）。
		if _is_object_key(key):
			continue
		# 事件里没有这个键，且对象上也没有 → 这条过滤条件无法成立。
		if (u == null and b == null) or not _object_has_key(u, b, key):
			return false
	return true


## 单位是否符合 filter。
static func unit_matches(u, filter: Dictionary) -> bool:
	if u == null:
		return false
	for k in filter.keys():
		var key := String(k)
		var want: Variant = filter[k]
		match key:
			"tag", "unit":
				if String(u.tag) != String(want):
					return false
			"unit_id", "id":
				if String(u.id) != String(want):
					return false
			"faction":
				if String(u.faction) != String(want):
					return false
			"kind":
				if String(u.kind) != String(want):
					return false
			"unit_type":
				if String(u.unit_type) != String(want):
					return false
			"tile":
				var t := _point_of(want)
				if Vector2i(int(u.tx), int(u.ty)) != t:
					return false
			"zone":
				# 这里只做「事件对象自己的 zone 字段」匹配；要按区划归属请看导演的
				# `on_zone_owner` / `on_condition`（它们能拿到 world）。
				if int(u.garrison_zone_id) != int(want):
					return false
			_:
				# 事件字段（reason / secs…）不归对象匹配管：交给 event_matches 的表层循环。
				continue
	return true


## 建筑是否符合 filter。
static func building_matches(b, filter: Dictionary) -> bool:
	if b == null:
		return false
	for k in filter.keys():
		var key := String(k)
		var want: Variant = filter[k]
		match key:
			"tag", "building":
				if String(b.tag) != String(want):
					return false
			"type":
				if String(b.type) != String(want):
					return false
			"owner":
				if String(b.owner) != String(want):
					return false
			"base":
				if String(b.type) != "base" or String(b.owner) != String(want):
					return false
			"tile", "building_tile":
				var t := _point_of(want)
				if Vector2i(int(b.tx), int(b.ty)) != t:
					return false
			_:
				continue
	return true


# ------------------------------------------------------------------
# 内部
# ------------------------------------------------------------------

static func _is_object_key(key: String) -> bool:
	return key in [
		"tag", "unit", "unit_id", "id", "faction", "kind", "unit_type",
		"building", "type", "owner", "tile", "building_tile", "base", "zone",
	]


static func _object_has_key(u: Variant, b: Variant, key: String) -> bool:
	if u != null and key in ["tag", "unit", "unit_id", "id", "faction", "kind", "unit_type", "tile", "zone"]:
		return true
	if b != null and key in ["tag", "building", "type", "owner", "tile", "building_tile", "base"]:
		return true
	return false


static func _same(a: Variant, b: Variant) -> bool:
	if typeof(a) == TYPE_INT or typeof(a) == TYPE_FLOAT:
		if typeof(b) == TYPE_INT or typeof(b) == TYPE_FLOAT:
			return absf(float(a) - float(b)) <= 1e-6
	return a == b


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
