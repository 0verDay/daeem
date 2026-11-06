## story_glow.gd —— 演出「呼吸泛光」的**共享状态读取**（纯逻辑，不碰视图）。
##
## ★ 状态存在 `Unit.story_glow` / `Building.story_glow` / `world.story_zone_glow`（字典）：
##     {color, period, start, until, strength, id}
##   · color：`#rrggbb` 或 `"faction"`（视图自己解析成颜色）；
##   · period：呼吸周期（秒）；start/until：世界时间；until <= 0 = 永久；
##   · strength：0..1；id：可选分组，用于 `stop_glow`。
##
## ★★ 为什么把曲线放在逻辑层：单位层（unit_flash shader 的 `.a`）、
##   `view/story_glow_view.gd`（地面光环 / 建筑外壳）和覆盖层的区划高亮必须用
##   **同一条曲线**；几处各写一份 `sin()` 迟早会漂开（一边亮一边暗）。
extends RefCounted

const FADE_SEC := 0.25


## 这个对象现在有没有泛光（已过期 / 空字典 → false）。
static func is_active(obj, now: float) -> bool:
	if obj == null:
		return false
	return dict_active(obj.story_glow, now)


## 状态字典版：给区划高亮这种没有对象的状态用。
static func dict_active(g: Dictionary, now: float) -> bool:
	if g.is_empty():
		return false
	var until := float(g.get("until", 0.0))
	return until <= 0.0 or now < until


## 0..1 的呼吸强度（含 0.25s 淡入 / 淡出；已过期 → 0）。
static func value(obj, now: float) -> float:
	if obj == null:
		return 0.0
	return dict_value(obj.story_glow, now)


## 状态字典版。
static func dict_value(g: Dictionary, now: float) -> float:
	if not dict_active(g, now):
		return 0.0
	var start := float(g.get("start", now))
	var until := float(g.get("until", 0.0))
	var period := maxf(0.05, float(g.get("period", 1.6)))
	var strength := clampf(float(g.get("strength", 0.8)), 0.0, 1.0)
	var age := maxf(0.0, now - start)
	var fade_in := clampf(age / FADE_SEC, 0.0, 1.0)
	var fade_out := 1.0
	if until > 0.0:
		fade_out = clampf((until - now) / FADE_SEC, 0.0, 1.0)
	var phase := fmod(age / period, 1.0)
	# 0.35 是暗端、1.0 是亮端（纯 sin 会从 0 开始，看起来像闪一下）。
	var pulse := 0.35 + 0.65 * (0.5 - 0.5 * cos(phase * TAU))
	return strength * fade_in * fade_out * pulse


## 解析颜色：空 / 缺省 → config 的金色；`"faction"` → 该对象所属阵营色。
static func color_hex(obj, world) -> String:
	if obj == null or world == null:
		return "#ffd166"
	return dict_color(obj.story_glow, world, _faction_of(obj))


## 状态字典版；`fid` 是 `color == "faction"` 时要用的阵营 id。
static func dict_color(g: Dictionary, world, fid: String = "") -> String:
	if world == null:
		return "#ffd166"
	var c := String(g.get("color", "")).strip_edges()
	if c == "":
		return String(world.cfg.str_val("render.story_glow_color", "#ffd166"))
	if c.to_lower() == "faction":
		if fid != "":
			return world.cfg.faction_color(fid).to_html(false)
		return String(world.cfg.str_val("render.story_glow_color", "#ffd166"))
	return c


static func _faction_of(obj) -> String:
	# 单位有 is_general()；建筑有 def()。用 duck typing 避免 logic 内互相 preload 的环。
	if obj.has_method("is_general"):
		return String(obj.faction)
	if obj.has_method("def"):
		return String(obj.owner)
	return ""
