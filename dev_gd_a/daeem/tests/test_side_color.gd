## test_side_color.gd —— 局内「敌 / 友 / 己」统一配色（本轮新增）。
##
## 需求：「所有的敌人在我视角下红、友军黄、己方蓝」。
## 这一份钉住三件事：
##   1. **关系判据**（`view/side_color.gd` 的唯一实现）：己方 / 友军 / 敌人 / 中立；
##   2. 三色真的接到了各个显示层（小地图 / 区划轮廓 / 占领触发区 / 选中圈）；
##   3. ★ 合作队友算「友军（黄）」而不是「己方（蓝）」（用户口径）。
extends "res://tests/test_case.gd"

const LevelRes = preload("res://logic/level.gd")
const WorldRes = preload("res://logic/world.gd")
const ConfigRes = preload("res://logic/config.gd")
const SideColorRes = preload("res://view/side_color.gd")
const GroundRes = preload("res://view/ground_view.gd")
const MinimapRes = preload("res://view/minimap.gd")
const OverlayRes = preload("res://view/overlay_view_3d.gd")
const UnitViewRes = preload("res://view/unit_view_3d.gd")


func _initialize() -> void:
	_case_name = "test_side_color"
	run_all(Callable(self, "_run"))


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	var w = _world(cfg, {
		"name": "side color probe",
		"players": [{"faction": "p1"}],
		"factions": [
			{"id": "A1", "ai": "garrison", "base": [5, 18]},
			{"id": "E1", "ai": "garrison", "base": [18, 18]},
		],
		"allies": [["p1", "A1"]],
		"zones": [{"id": 0, "owner": "p1"}, {"id": 1, "owner": "A1"},
			{"id": 2, "owner": "E1"}],
		"objectives": [],
	})
	if w == null:
		return

	# ---- 1) 关系判据（唯一实现）----
	eq(SideColorRes.relation(w, "p1"), SideColorRes.SELF, "★ 本机操作的一方 = 己方")
	eq(SideColorRes.relation(w, "A1"), SideColorRes.ALLY, "★ 盟友 = 友军")
	eq(SideColorRes.relation(w, "E1"), SideColorRes.ENEMY, "★ 非盟友 = 敌人")
	eq(SideColorRes.relation(w, ""), SideColorRes.NEUTRAL, "无主 = 中立（不套三色）")

	# ---- 2) 三色值 ----
	eq(SideColorRes.color(cfg, w, "p1"), cfg.side_color_self, "★ 己方 = 蓝")
	eq(SideColorRes.color(cfg, w, "A1"), cfg.side_color_ally, "★ 友军 = 黄")
	eq(SideColorRes.color(cfg, w, "E1"), cfg.side_color_enemy, "★ 敌人 = 红")
	eq(SideColorRes.color(cfg, w, ""), cfg.side_color_neutral, "★ 无主 / 未知 = 灰")

	# ---- 2b) 过渡画面用「不带 world」的那套（盟友表直接来自关卡数据）----
	eq(SideColorRes.relation_with_allies("", "F1", []), SideColorRes.NEUTRAL,
		"过渡画面：未选可玩阵营 ⇒ 中立（灰）")
	eq(SideColorRes.relation_with_allies("F2", "F2", []), SideColorRes.SELF,
		"过渡画面：选中的那一方 = 己方")
	eq(SideColorRes.relation_with_allies("F2", "dgj", [["F2", "dgj"]]), SideColorRes.ALLY,
		"过渡画面：盟友 = 友军")
	eq(SideColorRes.relation_with_allies("F2", "F1", [["F2", "dgj"]]), SideColorRes.ENEMY,
		"过渡画面：非盟友 = 敌人")
	eq(SideColorRes.color_with_allies(cfg, "", "F1", []), cfg.side_color_neutral,
		"过渡画面：未选时标识用灰色")
	eq(SideColorRes.color_with_allies(cfg, "F2", "dgj", [["F2", "dgj"]]),
		cfg.side_color_ally, "过渡画面：友军标识 = 黄")
	ok(cfg.side_color_self.is_equal_approx(ConfigRes.parse_color("#5ac8ff")),
		"蓝 = #5ac8ff（沿用现有配色）")
	ok(cfg.side_color_ally.is_equal_approx(ConfigRes.parse_color("#ffd166")),
		"黄 = #ffd166（沿用现有配色）")
	ok(cfg.side_color_enemy.is_equal_approx(ConfigRes.parse_color("#e05a5a")),
		"红 = #e05a5a（沿用现有配色）")
	ok(cfg.faction_color("p1", "main") != cfg.side_color_self,
		"★ 阵营**身份色**（菜单 / 过渡画面）没有被三色覆盖（p1 仍是黄色）")

	# ---- 3) 区划轮廓（ground_view）----
	var gv = GroundRes.new()
	gv.cfg = cfg
	gv.world = w
	var z0: Variant = w.zone_by_id(0)
	var z1: Variant = w.zone_by_id(1)
	var z2: Variant = w.zone_by_id(2)
	ok(z0 != null and z1 != null and z2 != null, "（前提）三块测试区划都在")
	if z0 != null and z1 != null and z2 != null:
		eq(gv.zone_outline_color(z0), cfg.side_color_self, "★ 己方区划轮廓 = 蓝")
		eq(gv.zone_outline_color(z1), cfg.side_color_ally, "★ 友军区划轮廓 = 黄")
		eq(gv.zone_outline_color(z2), cfg.side_color_enemy, "★ 敌方区划轮廓 = 红")
		eq(gv.zone_outline_color({"owner": ""}), cfg.color("zone_stroke"),
			"★ 无主区划保留中性线色（不套三色）")
	gv.free()

	# ---- 4) 小地图（单位点 / 建筑块）----
	var mm = MinimapRes.new()
	mm.cfg = cfg
	mm.world = w
	eq(mm._faction_color("p1"), cfg.side_color_self, "★ 小地图上的己方 = 蓝")
	eq(mm._faction_color("A1"), cfg.side_color_ally, "★ 小地图上的友军 = 黄")
	eq(mm._faction_color("E1"), cfg.side_color_enemy, "★ 小地图上的敌人 = 红")
	mm.free()

	# ---- 5) 占领触发区 + 选中圈 ----
	var ov = OverlayRes.new()
	ov.cfg = cfg
	ov.world = w
	eq(ov._capture_area_color("p1"), cfg.side_color_self, "★ 己方占领触发区 = 蓝")
	eq(ov._capture_area_color("A1"), cfg.side_color_ally, "★ 友军占领触发区 = 黄")
	eq(ov._capture_area_color("E1"), cfg.side_color_enemy, "★ 敌方占领触发区 = 红")
	eq(ov._capture_area_color(""), OverlayRes.CAPTURE_AREA_NEUTRAL,
		"★ 中立占领触发区仍是白灰")
	ov.free()

	var uv = UnitViewRes.new()
	uv.cfg = cfg
	eq(uv._selection_ring_color(SideColorRes.SELF), cfg.side_color_self,
		"★ 选中圈：己方 = 蓝")
	eq(uv._selection_ring_color(SideColorRes.ALLY), cfg.side_color_ally,
		"★ 选中圈：友军 = 黄")
	eq(uv._selection_ring_color(SideColorRes.ENEMY), cfg.side_color_enemy,
		"★ 选中圈：敌人 = 红")
	uv.free()

	# ---- 6) 合作模式：队友算「友军（黄）」（用户口径）----
	#     ⚠️ 放在最后：`FactionRes.set_allies()` 是全局表，建第二个世界会换掉它。
	var w2 = _world(cfg, {
		"name": "side color coop probe",
		"mode": "coop",
		"players": [{"faction": "p1"}, {"faction": "p2"}],
		"factions": [{"id": "E1", "ai": "garrison", "base": [18, 18]}],
		"allies": [["p1", "p2"]],
		"objectives": [],
	}, ["p1", "p2"])
	if w2 != null:
		eq(SideColorRes.relation(w2, "p2"), SideColorRes.ALLY,
			"★★ 合作队友算**友军**（黄），不是己方（蓝）")
		eq(SideColorRes.color(cfg, w2, "p2"), cfg.side_color_ally, "★ 队友显示为黄色")
		eq(SideColorRes.color(cfg, w2, "p1"), cfg.side_color_self, "★ 自己仍是蓝色")


## 造一局合成关卡（`frontier` 图）；`roster` 省略 = 单席位 [p1]。
func _world(cfg, patch: Dictionary, roster: Array = ["p1"]):
	var raw := {
		"map": "frontier",
		"players": [{"faction": "p1"}],
		"factions": [],
		"objectives": [],
		"start_units": [],
	}
	for k in patch.keys():
		raw[k] = patch[k]
	var lv = LevelRes.from_data(raw, cfg, null, "side_color_probe", "")
	ok(lv != null, "（前提）合成关卡能载入（%s）" % String(patch.get("name", "")))
	if lv == null:
		return null
	var w = WorldRes.create_from_level(cfg, lv, "p1", roster, true)
	ok(w != null, "（前提）合成世界能建出来（%s）" % String(patch.get("name", "")))
	return w
