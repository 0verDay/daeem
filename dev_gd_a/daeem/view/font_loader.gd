## font_loader.gd —— 中文字体的载入（Godot 默认字体没有 CJK 字形）
##
## 症状：不装字体，HUD 与事件日志里的中文全是方框（tofu）。
## 做法：按「最省事 → 最保险」的顺序找一份中文字体，做成 Theme 给 HUD 用。
##
## 为什么这么啰嗦（三条路依次退，都是实测出来的）：
##   1. `res://assets/fonts/*.ttf` —— 字体被 Godot 导入过（.import 存在）时最省事。
##      ⚠️ 但「把字体拷进 assets/ 就能用」这件事**不成立**：新文件必须先被导入
##      （跑一次 `--headless --import`，或用编辑器打开一次工程）。所以要往下退。
##   2. `FontFile.load_dynamic_font(绝对路径)` —— **绕开导入系统**，直接从磁盘读。
##      实测可行（4.7.2）：载进来的 FontFile `get_font_name() == "SimHei"`、
##      `has_char('军') == true`。这条让「拷了字体就能跑」真的成立。
##   3. 都失败 → 返回 null，用引擎默认字体：中文变方框，但**游戏照常能玩**。
##
## ⚠️ 返回类型是 `Font`（基类）而不是 `FontFile`：
##    .ttc 这类字体集合可能载成别的 Font 子类，写死 FontFile 会漏。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")

## 系统字体目录的兜底候选（对应 tools/setup-font.ps1 的默认候选顺序）
const SYSTEM_FONT_DIRS: Array[String] = ["C:/Windows/Fonts"]


## @return Theme 或 null（null = 用引擎默认字体，中文会变方框）
static func build_theme(cfg: ConfigRes, base_size: int = 15) -> Theme:
	var font := load_font(cfg)
	if font == null:
		return null
	var theme := Theme.new()
	theme.default_font = font
	theme.default_font_size = base_size
	return theme


## @return Font 或 null
static func load_font(cfg: ConfigRes) -> Font:
	var names := _candidate_names(cfg)

	# 1) 已经被导入的 res:// 资源
	for n in names:
		var path := "res://assets/fonts/%s" % n
		if ResourceLoader.exists(path):
			var res := ResourceLoader.load(path)
			if res is Font:
				return res as Font

	# 2) 绕开导入：直接从磁盘读（拷了字体就能用，不必先跑一次导入）
	for n in names:
		for dir in SYSTEM_FONT_DIRS:
			var abs_path := "%s/%s" % [dir, n]
			if not FileAccess.file_exists(abs_path):
				continue
			var ff := FontFile.new()
			if ff.load_dynamic_font(abs_path) == OK:
				return ff

	push_warning("没找到中文字体：跑一次 tools/setup-font.ps1，否则中文会显示成方框。")
	return null


## 候选字体文件名：优先用 config.json 里写的，取不到就用一串常见中文字体名
static func _candidate_names(cfg: ConfigRes) -> Array[String]:
	var out: Array[String] = []
	var candidates: Variant = cfg.get_path_value("font.asset_path")
	if typeof(candidates) == TYPE_ARRAY:
		for v in (candidates as Array):
			out.append(String(v).get_file())
	if out.is_empty():
		out = ["simhei.ttf", "msyh.ttc", "Deng.ttf", "simsun.ttc"]
	return out
