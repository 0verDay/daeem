## test_team_slots.gd —— **稳定编队槽位**的纯逻辑（阵亡不改号 / 新将补空槽 / 复活回原号）。
##
## 不建场景、不读配置：用两个最小假对象把 `view/team_slots.gd` 的规则钉住。
extends "res://tests/test_case.gd"

const TeamSlotsRes = preload("res://view/team_slots.gd")


class FakeUnit:
	var id: String = ""
	var faction: String = "p1"
	var name: String = "将领"
	var alive: bool = true
	var death_timer: float = 0.0
	var general_index: int = 0

	func is_general() -> bool:
		return true

	func awaiting_respawn() -> bool:
		return (not alive) and death_timer > 0.0


class FakeWorld:
	var units: Array = []
	var my_faction: String = "p1"
	var observer_mode: bool = false


func _initialize() -> void:
	_case_name = "test_team_slots"
	run_all(_cases)


func _u(id: String, faction: String = "p1") -> FakeUnit:
	var u := FakeUnit.new()
	u.id = id
	u.faction = faction
	u.name = "将领 " + id
	return u


func _cases() -> void:
	# ① 开局按 world.units 顺序分配 1..N（与旧版编号一致）。
	var w := FakeWorld.new()
	var u1 := _u("a")
	var u2 := _u("b")
	var u3 := _u("c")
	var enemy := _u("e", "p2")
	w.units = [u1, u2, u3, enemy]
	var slots := TeamSlotsRes.new()
	slots.sync(w)
	eq(slots.slot_of(u1), 1, "★ 第 1 位将领 → 槽 1")
	eq(slots.slot_of(u2), 2, "★ 第 2 位将领 → 槽 2")
	eq(slots.slot_of(u3), 3, "★ 第 3 位将领 → 槽 3")
	eq(slots.slot_of(enemy), 0, "★ 敌人不占编队槽（地图键帽只写「敌」）")

	# ② 阵亡：对象离开 world.units（重生队列持有）→ 槽位仍占着、置灰。
	u2.alive = false
	u2.death_timer = 12.0
	w.units = [u1, u3]
	slots.sync(w)
	ok(slots.has_slot(2), "★★ 阵亡将仍占槽 2（右栏置灰行）")
	ok(slots.slot_is_dead(2), "★★ 槽 2 判为阵亡")
	eq(slots.slot_status_text(2), "重生 12 秒", "★★ 阵亡行显示重生倒计时")
	eq(slots.slot_of(u1), 1, "★ 前面阵亡不影响槽 1")
	eq(slots.slot_of(u3), 3, "★★ 后面将领的编号不前移（仍是 3）")

	# ③ 新将补最小空槽：槽 2 被阵亡将占着，新将拿 4（不是 2）。
	var u4 := _u("d")
	w.units.append(u4)
	slots.sync(w)
	eq(slots.slot_of(u4), 4, "★★ 新将补最小空槽（阵亡占着的 2 不算空）")

	# ④ 复活：同一对象回到 world.units → 回原槽 2，取消置灰。
	u2.alive = true
	u2.death_timer = 0.0
	w.units.append(u2)
	slots.sync(w)
	eq(slots.slot_of(u2), 2, "★★ 复活回原槽 2")
	ok(not slots.slot_is_dead(2), "★★ 复活后槽 2 取消置灰")
	eq(slots.slot_of(u3), 3, "★ 复活不改变别人的编号")

	# ⑤ 同一对象换 id（测试里会把 general-0 就地改名）：不能重复占槽。
	u1.id = "a_renamed"
	slots.sync(w)
	eq(slots.slot_of(u1), 1, "★★ 换 id 后仍回原槽 1（按对象实例记住）")
	var u5 := _u("f")
	w.units.append(u5)
	slots.sync(w)
	eq(slots.slot_of(u5), 5, "★★ 换 id 没有额外占槽：新将拿 5")
