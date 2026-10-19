## event_codec.gd —— 把 `world.tick()` 的事件翻成**可 JSON 序列化**的形状，再翻回来。
##
## 为什么需要它：逻辑层的事件里带**对象引用**（`unit` / `leader` / `building` / `target` /
## `source`），JSON.stringify 不能直接发。这里只把「引用」换成 id / 建筑 key，
## 其余字段原样带过去；客机收到后按本地世界把引用查回来。
##
## ★ 只处理**已知的对象字段**；未知字段原样放行（数组 / 字典 / 数字 / 字符串）。
##   遇到查不回来的对象就置 null —— 事件是播报，不该因为一个单位刚死就崩。
extends RefCounted


static func encode_items(world, events: Array) -> Array:
	var out: Array = []
	for ev in events:
		if typeof(ev) == TYPE_DICTIONARY:
			out.append(encode_event(world, ev))
	return out


static func encode_event(_world, ev: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in ev.keys():
		var key := String(k)
		var v: Variant = ev[k]
		match key:
			"unit", "leader":
				if v != null:
					out[key + "_id"] = String(v.id)
			"building":
				if v != null:
					out["building_key"] = _building_key(v)
			"target":
				_encode_ref(out, "target", v)
			"source":
				_encode_ref(out, "source", v)
			_:
				_encode_value(out, key, v)
	return out


static func decode_items(world, items: Array) -> Array:
	var out: Array = []
	for item in items:
		if typeof(item) == TYPE_DICTIONARY:
			out.append(decode_event(world, item))
	return out


static func decode_event(world, data: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in data.keys():
		var key := String(k)
		var v: Variant = data[k]
		match key:
			"unit_id":
				out["unit"] = world.unit_by_id(String(v))
			"leader_id":
				out["leader"] = world.unit_by_id(String(v))
			"building_key":
				out["building"] = _building_by_key(world, String(v))
			"target_unit":
				out["target"] = world.unit_by_id(String(v))
			"target_building":
				out["target"] = _building_by_key(world, String(v))
			"source_unit":
				out["source"] = world.unit_by_id(String(v))
			"source_building":
				out["source"] = _building_by_key(world, String(v))
			"tile":
				if typeof(v) == TYPE_ARRAY and (v as Array).size() >= 2:
					out["tile"] = Vector2i(int((v as Array)[0]), int((v as Array)[1]))
				else:
					out["tile"] = v
			_:
				_decode_value(out, key, v)
	return out


# ------------------------------------------------------------------
# 内部
# ------------------------------------------------------------------

static func _encode_ref(out: Dictionary, prefix: String, v: Variant) -> void:
	if v == null:
		return
	if v.has_method("center"):
		out[prefix + "_building"] = _building_key(v)
	else:
		out[prefix + "_unit"] = String(v.id)


static func _encode_value(out: Dictionary, key: String, v: Variant) -> void:
	match typeof(v):
		TYPE_VECTOR2I:
			out[key] = [int(v.x), int(v.y)]
		TYPE_VECTOR2:
			out[key] = [float(v.x), float(v.y)]
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			out[key] = v
		TYPE_ARRAY:
			out[key] = (v as Array).duplicate(true)
		TYPE_DICTIONARY:
			out[key] = (v as Dictionary).duplicate(true)
		_:
			# 未知对象：不冒险序列化（丢字段比发一个坏 JSON 好）
			pass


static func _decode_value(out: Dictionary, key: String, v: Variant) -> void:
	out[key] = v


static func _building_key(b) -> String:
	return "%s:%d:%d:%s" % [String(b.type), int(b.tx), int(b.ty), String(b.owner)]


static func _building_by_key(world, key: String):
	var parts: PackedStringArray = key.split(":")
	if parts.size() < 4:
		return null
	return world.building_at(int(parts[1]), int(parts[2]))
