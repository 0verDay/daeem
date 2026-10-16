## fade_in.gd —— 入场淡入：挂上就干活
##
## ★ 用法：把它挂在一页界面的**根 Control** 上，`_ready()` 里自动把 `modulate.a`
##   从 0 抬到 1（`TRANS_CUBIC` / `EASE_OUT`：起步快、收尾稳，不会"啪"一下亮）。
##   页面自己的 `_ready()` 要写逻辑时，按普通 Godot 规矩先 `super._ready()`
##   （或者干脆别挂本脚本，自己调 `fade_in_self()`）。
##
## ★ 时长来自 `data/config.json` 的 `ui.fade_in_sec`（见 logic/config.gd），
##   想单独指定某一页的时长就调 `fade_in_self(秒数)`。
##
## ★ 动效总开关（`view/theme.gd` 的 `animations_enabled()`）关掉时**直接置 1**：
##   关掉动效是「立刻到位」，而不是「先黑着再出现」。
extends Control

const ConfigRes = preload("res://logic/config.gd")
const ThemeRes = preload("res://view/theme.gd")

## 兜底值（与 config.json 的 ui.fade_in_sec 一致）。
const DEFAULT_FADE_IN_SEC := 0.4

var _sec: float = DEFAULT_FADE_IN_SEC


func _ready() -> void:
	_sec = _read_sec()
	fade_in_self()


## 把自身 `modulate.a` 从 0 抬到 1。
## @param duration 秒数；**负数 = 用 `ui.fade_in_sec`**（默认就是这条）。
func fade_in_self(duration: float = -1.0) -> void:
	var sec := duration if duration >= 0.0 else _sec
	if sec <= 0.0 or not ThemeRes.animations_enabled():
		modulate.a = 1.0
		return
	modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, sec) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


## 本次入场用的时长（秒）—— 测试与排查用。
func fade_in_sec() -> float:
	return _sec


func _read_sec() -> float:
	var cfg = ConfigRes.load_default()
	if cfg == null:
		# 配置读不出来（ConfigRes 自己已经 push_error 过了）：用与 JSON 一致的兜底值。
		return DEFAULT_FADE_IN_SEC
	return cfg.fade_in_sec
