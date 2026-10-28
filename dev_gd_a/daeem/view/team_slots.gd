## team_slots.gd —— **稳定的编队槽位**（1..6）：将领阵亡 / 复活后编号不变。
##
## ★★ 为什么需要这一层（本版口径）：
##   · 旧版地图 / 右栏 / 数字键都按「存活顺序」现数，将领一阵亡后面的编号全部前移；
##   · 现在要求「阵亡将仍占位、编号不前移、复活回原号」，所以槽位必须**记住**，
##     而不是每帧数出来。
##
## ★★ 为什么放在 view/ 而不是 logic/：
##   槽位只是**本机界面的编号**（地图键帽 / 右栏行 / 数字键），不参与玩法判定，
##   也不需要进快照；它按「第一次看见这位将领」分配，之后按 id 记住。
##   `world` 只提供单位列表与存活状态，不持有任何 UI 概念。
##
## ★ 分配规则（用户口径）：
##   · 开局第一次同步时，按 `world.units` 里「同方 + 将领」的顺序分配 1..6
##     ⇒ 与旧版开局编号逐位一致（不会改动已有将领的序号）；
##   · 之后永远按 **id** 复用同一个槽位；新将领补**最小空槽**（阵亡占着的不算空）；
##   · 阵亡将的对象由大本营重生队列持有，槽位继续指向它；复活（同一对象）自动复用；
##   · 观察者模式仍按被观战方登记槽位（右栏 / 详情可用），但地图键帽只写敌 / 友、不显示编号。
##
## ★ 只做纯数据：不读场景、不画图、不发命令。
extends RefCounted

const FactionRes = preload("res://logic/faction.gd")

## 最多 6 个编队槽（与右栏 `SQUAD_SLOTS` / 数字键 1..6 同口径）。
const MAX_SLOTS := 6

## unit id → 槽位（1..6）。**永不删除**：阵亡也占着，只有新一局 `reset()` 才清。
var _slot_by_id: Dictionary = {}
## 对象实例 id → 槽位：防止「同一个对象换了 id」被当成新将重复占槽
## （测试里会把 general-0 就地改名成 general-1；正常玩法 id 不会变）。
var _slot_by_instance: Dictionary = {}
## 槽位 → 单位对象（持有引用：阵亡后对象还在重生队列里，复活是同一个对象）。
var _owner_by_slot: Dictionary = {}
## 槽位 → 名字 / 阵营的缓存（对象真的被释放时，右栏还能显示灰行）。
var _name_by_slot: Dictionary = {}
var _faction_by_slot: Dictionary = {}


## 新一局（切换世界 / reset）时清空；调用方通常是 `game_scene3d._assemble()`。
func reset() -> void:
	_slot_by_id.clear()
	_slot_by_instance.clear()
	_owner_by_slot.clear()
	_name_by_slot.clear()
	_faction_by_slot.clear()


## 把 `world.units` 里还没登记过的**同方将领**补进槽位。
##
## ★ 可重复调用（每帧 / 每个调用点都可以调）：已登记的 id 只更新对象引用与缓存。
## ★ 不处理敌人：地图上敌人的键帽写「敌」，不需要编号。
func sync(world) -> void:
	if world == null:
		return
	var my := String(world.my_faction)
	if my == "":
		return
	for u in world.units:
		if u == null or not u.is_general():
			continue
		if not FactionRes.same_side(String(u.faction), my):
			continue
		var id := String(u.id)
		var iid := int(u.get_instance_id())
		var slot := 0
		if _slot_by_instance.has(iid):
			# 同一个对象（含「测试里就地改名」）→ 永远回原槽。
			slot = int(_slot_by_instance[iid])
			_slot_by_id[id] = slot
		elif _slot_by_id.has(id):
			# 同一 id 换了一个对象（快照 / 重生重建）→ 沿用原槽。
			slot = int(_slot_by_id[id])
			_slot_by_instance[iid] = slot
		else:
			slot = _lowest_free()
			if slot <= 0:
				continue                   # 6 个槽都占着（含阵亡）→ 新将没有编号
			_slot_by_id[id] = slot
			_slot_by_instance[iid] = slot
		_owner_by_slot[slot] = u
		_name_by_slot[slot] = String(u.name)
		_faction_by_slot[slot] = String(u.faction)


## 单位 id → 槽位；没登记返回 0。
func slot_of(u) -> int:
	if u == null:
		return 0
	var iid := int(u.get_instance_id())
	if _slot_by_instance.has(iid):
		return int(_slot_by_instance[iid])
	return int(_slot_by_id.get(String(u.id), 0))


## 槽位 → 单位对象；空槽 / 对象已释放返回 null。
func unit_in_slot(slot: int) -> Variant:
	if not _owner_by_slot.has(slot):
		return null
	var u: Variant = _owner_by_slot[slot]
	if u == null or not is_instance_valid(u):
		return null
	return u


## 这个槽位有没有主人（**包括阵亡 / 对象已释放**）—— 右栏判「空槽」用它，
## 不能用 `unit_in_slot() == null`（那会把阵亡行误判成空行）。
func has_slot(slot: int) -> bool:
	return _owner_by_slot.has(slot)


## 槽位上的将是不是阵亡（对象失效 / `alive == false`）。
func slot_is_dead(slot: int) -> bool:
	if not has_slot(slot):
		return false
	var u: Variant = _owner_by_slot[slot]
	if u == null or not is_instance_valid(u):
		return true
	return not bool(u.alive)


## 槽位上的名字（阵亡 / 对象失效时读缓存）。
func slot_name(slot: int) -> String:
	var u: Variant = _owner_by_slot.get(slot, null)
	if u != null and is_instance_valid(u):
		return String(u.name)
	return String(_name_by_slot.get(slot, ""))


## 槽位上的阵营 id（阵亡 / 对象失效时读缓存）。
func slot_faction(slot: int) -> String:
	var u: Variant = _owner_by_slot.get(slot, null)
	if u != null and is_instance_valid(u):
		return String(u.faction)
	return String(_faction_by_slot.get(slot, ""))


## 阵亡行第二行的状态字：`重生 12 秒` / `阵亡`；活着的返回空串。
func slot_status_text(slot: int) -> String:
	if not slot_is_dead(slot):
		return ""
	var u: Variant = _owner_by_slot.get(slot, null)
	if u != null and is_instance_valid(u) and u.has_method("awaiting_respawn") \
			and bool(u.awaiting_respawn()):
		return "重生 %d 秒" % int(ceil(maxf(0.0, float(u.death_timer))))
	return "阵亡"


## 最小空槽（1..6）；满了返回 0。
func _lowest_free() -> int:
	for slot in range(1, MAX_SLOTS + 1):
		if not _owner_by_slot.has(slot):
			return slot
	return 0
