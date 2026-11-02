## test_unit_art.gd —— **派系兵种的立牌素材**：换了图之后还能不能用、糊不糊、会不会又退回占位
##
## 背景（2026.11）：王朝 / 帝国那 14 个派系兵种一开始全是**占位**（`sprite` 留空 +
## `sprite_tint = faction` ⇒ 3D 立牌退回程序化剪影 / 单字）。本轮把其中八个换成了
## `art_draft/units/` 里的**真原画**，落到 `assets/units/<兵种 id>.png`。
##
## 这套用例守的就是那一步的**验收口径**（都是「一眼能看出坏没坏」的硬条件）：
##   1. `sprite` 非空、**资源真的被导入过**（`ResourceLoader.exists`）——
##      只写路径不导入是好不了的：Godot 那头拿到的是 null，渲染层会静默退回剪影，
##      症状是「改了 config 但画面没变」，最难查；
##   2. `sprite_tint = art`（否则原画会被阵营色刷成一坨色块）；
##   3. **文件名 = 兵种 id**（本轮定的约定：config 里看路径就知道是哪张图，
##      也防止两张兵种不小心指到同一个 png —— 那正是「换了素材还是长得一样」的来源）；
##   4. 立牌比例与该兵种大类一致（步兵 1×1 / 骑兵 1×1.5 / 器械 2×1）——
##      比例和原画宽高比对不上就会把人拉变形；
##   5. 烘出来的贴图**有实质像素**且**两两不同**。
##
## ⚠️ 这里不写死任何数值（血量 / 攻速都不碰），只碰「素材接线」——
##   调平衡时这套不该跟着改。
extends "res://tests/test_case.gd"

const ConfigRes = preload("res://logic/config.gd")
const SpriteRes = preload("res://view/unit_sprite_3d.gd")

## 本轮换成真原画的八个派系兵种（顺序 = config 里的定义顺序）。
const CLAN_ART_TYPES := [
	"dy_spear_guard", "dy_archer_guard", "dy_royal_sword",
	"dy_royal_archer", "dy_royal_cavalry", "dy_chariot",
	"dg_archer", "dg_bolt",
]
const ART_DIR := "res://assets/units/"

## 兵种自己的 `sprite_ratio` **覆盖**了大类默认值的（其余一律按兵种大类走）。
## 战车 = 2×1.5：原画 512×384 正好 4:3，装进 2:1.5 的牌面刚好占满、左右不留空档。
const RATIO_OVERRIDES := {
	"dy_chariot": Vector2(2.0, 1.5),
}

func _initialize() -> void:
	_case_name = "test_unit_art"
	_run()

func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	_test_clan_art_wiring(cfg)
	_test_clan_art_bakes(cfg)
	_test_native_art_untouched(cfg)
	run_all(_noop)

func _noop() -> void:
	pass

## ① 接线：路径 / 导入 / 上色口径 / 文件名约定 / 立牌比例
func _test_clan_art_wiring(cfg) -> void:
	for t in CLAN_ART_TYPES:
		var id := String(t)
		var path: String = cfg.unit_sprite_of(id)
		ok(path != "", "★ %s 配了 sprite 路径" % id)
		ok(path == ART_DIR + id + ".png",
			"★ %s 的素材按约定落在 assets/units/<兵种 id>.png（实际 %s）" % [id, path])
		ok(ResourceLoader.exists(path),
			"★★ %s 的素材被导入过（%s）—— 只写路径不导入 = 静默退回剪影" % [id, path])
		eq(cfg.unit_sprite_tint_of(id), "art",
			"★★ %s 是 art 档（保留原画；faction 档会把原画刷成色块）" % id)
		# 立牌比例：默认与兵种大类一致（步兵 1×1 / 骑兵 1×1.5 / 器械 2×1）；
		# `sprite_ratio` 显式覆盖的按覆盖值（战车 2×1.5）。
		var box: Vector2 = cfg.unit_sprite_ratio_of(id)
		var cls: String = cfg.unit_class_of(id)
		var want: Vector2 = RATIO_OVERRIDES.get(id, Vector2.ZERO)
		if want == Vector2.ZERO:
			want = Vector2(1.0, 1.0)
			if cls == ConfigRes.CLASS_CAVALRY:
				want = Vector2(1.0, 1.5)
			elif cls == ConfigRes.CLASS_SIEGE:
				want = Vector2(2.0, 1.0)
		v2_near(box, want, 1e-6, "★ %s（%s）的立牌比例 = %.2f×%.2f" % [id, cls, want.x, want.y])

## ② 烘图：有实质像素、两两不同（否则还是「长得一样」）
func _test_clan_art_bakes(cfg) -> void:
	SpriteRes.clear_cache()
	var images: Dictionary = {}
	var faction := Color(0.949, 0.710, 0.267)     # p1 主题金（只影响描边）
	for t in CLAN_ART_TYPES:
		var id := String(t)
		var path: String = cfg.unit_sprite_of(id)
		ok(SpriteRes.has_sprite(path), "★ %s 的素材能被读成 Image" % id)
		var tex: ImageTexture = SpriteRes.bake_asset(path, faction, false, faction,
			cfg.unit_sprite_tint_of(id), false, faction, false, Color(1, 1, 1, 1),
			cfg.unit_sprite_ratio_of(id))
		ok(tex != null, "%s 的立牌贴图烘得出来" % id)
		if tex == null:
			continue
		var img: Image = tex.get_image()
		ok(img != null, "%s 的贴图能取回 Image" % id)
		if img == null:
			continue
		var opaque := _count_opaque(img)
		ok(opaque > 100, "★ %s 的剪影有实质像素（不透明 %d）" % [id, opaque])
		# 画布必须和立牌比例同形 —— 不同形就该被拉变形了
		var box: Vector2 = cfg.unit_sprite_ratio_of(id)
		near(float(img.get_width()), 64.0 * box.x, 1.0,
			"★ %s 贴图宽 = 64 × 比例（%d）" % [id, img.get_width()])
		near(float(img.get_height()), 64.0 * box.y, 1.0,
			"★ %s 贴图高 = 64 × 比例（%d）" % [id, img.get_height()])
		images[id] = img
	eq(images.size(), CLAN_ART_TYPES.size(), "八个派系兵种都烘出了贴图")
	var ids: Array = images.keys()
	var same := 0
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			if (images[ids[i]] as Image).get_data() == (images[ids[j]] as Image).get_data():
				same += 1
				printerr("  [FAIL] %s 与 %s 的贴图完全相同" % [ids[i], ids[j]])
	eq(same, 0, "★★ 八个派系兵种的贴图两两不同（否则等于没换素材）")

## ③ 原生七个兵种的素材别被这轮改动带歪（老口径仍然成立）
func _test_native_art_untouched(cfg) -> void:
	for t in ["spearman", "longbowman", "rider", "grain_cart", "knight",
			"horse_archer", "catapult"]:
		var id := String(t)
		var path: String = cfg.unit_sprite_of(id)
		ok(ResourceLoader.exists(path), "原生 %s 的素材仍在且被导入（%s）" % [id, path])
		eq(cfg.unit_sprite_tint_of(id), "art", "原生 %s 仍是 art 档" % id)
		ok(path.begins_with("res://assets/test_units/"),
			"原生 %s 仍走 assets/test_units（不跟派系兵种混目录）" % id)

func _count_opaque(img: Image) -> int:
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.5:
				n += 1
	return n
