## sfx.gd —— 游戏音效（菜单点击 / 菜单悬停 / 玩家建造）
##
## 目前三档：
##   · `play_click()` —— 菜单页面按钮**按下**：`click_button/down.wav`；
##   · `play_hover()` —— 鼠标**移入**菜单按钮：`click_button/hover.wav`
##     （触屏没有悬停，`ThemeRes.hover_enabled()` = false 时不播）；
##   · `play_build()` —— 本机阵营造好一栋建筑（`assets/sound/build/`）。
##
## ★ 为什么是「静态工具 + 全局组标记」，而不是一条 autoload：
##   本作没有 autoload（见 quit_confirm.gd 文件头那条口径），而音效又必须跨页面
##   一直可用（菜单面板随时会被重建 / 切页、游戏场景也会被拆掉重进），所以音频
##   播放器挂在**场景树根**上，由本文件的静态变量记着；调用方不持有播放器，
##   也不认识音频总线。
##
## ★★ 怎么判断「这是菜单按钮」：
##   按钮挂接是**统一**的 —— `fill_button.attach()` 会给每颗按钮都挂上（包含游戏内
##   HUD 的科技格 / 命令卡）。但点击音只给**菜单页面**，所以：
##     · 菜单 / 选项页 / 退出确认 / 过渡页在 setup 时 `mark_menu(self)`；
##     · 点击时沿父链找 GROUP（见 `in_menu()`），找得到才播。
##   ⇒ HUD 按钮照旧一声不响，将来给 HUD 加音效也不用改这里（把它也 mark 即可）。
##
## ★ 每一档都是**一组**路径（`*_PATHS`）：现在每档只有一段（down / hover / build），
##   但播放接口一律「在组里随机挑一段」——以后同一档想放多段素材只需往数组里加一行，
##   调用点不用改。
extends RefCounted

const ThemeRes = preload("res://view/theme.gd")
const ConfigRes = preload("res://logic/config.gd")

## 各档音量（dB；0 = 原始音量）。★ 可在 `data/config.json` 的 `ui.sfx_*_db` 覆盖。
## 默认值按素材实测峰值定：down 峰值 0.154 / hover 0.345 ⇒ 点击 +3、悬停 −8，
## 听感上点击仍压过悬停（素材本身的响度是 hover 更高，不能直接用原始音量）。
const DEFAULT_CLICK_DB := 3.0
const DEFAULT_HOVER_DB := -8.0
const DEFAULT_BUILD_DB := 0.0

## config 只读一次（与 press_fx.gd 同一种写法：运行中不改盘上的 config）。
static var _cfg: ConfigRes = null

## 菜单子树标记（`add_to_group`）。
const GROUP := "ui_menu_sound"
## 已经挂过音效的控件（避免 fill_button 与控件自己各挂一遍 → 播两声）。
const META := "sfx_attached"

const CLICK_PATHS := [
	"res://assets/sound/click_button/down.wav",
]
const HOVER_PATHS := [
	"res://assets/sound/click_button/hover.wav",
]
const BUILD_PATHS := [
	"res://assets/sound/build/build.wav",
]

## 播放器数量：连点 / 快速切页时不让后一声把前一声掐掉。
const VOICE_COUNT := 6

static var _click: Array = []
static var _hover: Array = []
static var _build: Array = []
static var _loaded: bool = false
static var _voices: Array = []
static var _voice_index: int = 0
## 真正播出去的次数（只有测试 / 排查读；`attach()` 挂上但不在菜单里时它不该动）。
static var click_play_count: int = 0
static var hover_play_count: int = 0
static var build_play_count: int = 0


# ------------------------------------------------------------------
# 菜单标记 / 挂接
# ------------------------------------------------------------------

## 把 `node` 的整棵子树标成「菜单」（它自己以及后来加进来的子节点都算）。
static func mark_menu(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	node.add_to_group(GROUP)


## `node` 是不是菜单里的东西（沿父链找 GROUP）。
static func in_menu(node: Node) -> bool:
	var n: Node = node
	while n != null:
		if n.is_in_group(GROUP):
			return true
		n = n.get_parent()
	return false


## 给一个可点控件挂上「按下播一声」（+ 可选「悬停播一声」）。
##
## ★ 幂等：`fill_button.attach()` 与控件自己的 setup 可能都会调到这里，
##   靠 META 挡住第二遍 —— 重复连接的表现是**一声点击播两遍**（相位错开，很难听）。
## ★★ 按下那一刻出声，所以 `BaseButton` 接的是 `button_down`（`pressed` 要等松手，
##   按住不放 / 拖走时就没有声音了）。自绘控件（menu_text_button / menu_banner /
##   menu_corner_hit）本来就是在 `_gui_input` 的**按下**分支里发 `pressed`，照旧接它。
## ★★ `connect_hover = false`：这把控件已经有**自己的** `mouse_entered` 消费者
##   （`fill_button` 的动画器就是那样接的）。再连一条就成了同一帧两条悬停回调，
##   而且 `tests/test_fill_button.gd` 用「mouse_entered 只连一次」钉住那条口径 ——
##   那条情形由调用方在自己的悬停回调里调 `on_hover()`，见 `fill_button`。
static func attach(control: Object, connect_hover: bool = true) -> void:
	if control == null or not is_instance_valid(control):
		return
	var node := control as Node
	if node == null or not node.has_signal("pressed"):
		return
	# 音量档要读 config：在这里预热（attach 都发生在界面搭建期），
	# 别把第一次 JSON 解析留到第一次点击那一帧。
	_config()
	if node.has_meta(META):
		return
	node.set_meta(META, true)
	if node is BaseButton:
		(node as BaseButton).button_down.connect(_on_click.bind(node))
	else:
		node.pressed.connect(_on_click.bind(node))
	var c := control as Control
	if connect_hover and c != null:
		c.mouse_entered.connect(_on_hover.bind(node))


static func _on_click(node: Node) -> void:
	# ⚠️ 禁用按钮在引擎里本来就不会发 `button_down`；这道判断是挡住「程序里手动 emit」
	#   那一类情况（测试 / 上层模拟点击），别让不可点的按钮出声。
	if node is BaseButton and (node as BaseButton).disabled:
		return
	if in_menu(node):
		play_click()


static func _on_hover(node: Node) -> void:
	on_hover(node)


## 鼠标移入：只在桌面（有悬停）且是菜单里可交互的按钮时响。
##
## ★ 公开给「自己已经接了 mouse_entered」的控件用（`fill_button` 的动画器）——
##   它们不该再连一条监听，直接在自己的回调里调这里。
## ⚠️ 禁用按钮不响：它本来就不能点（悬停填灰是**看**的反馈，不该配「可按」的声音）。
static func on_hover(node: Node) -> void:
	if not ThemeRes.hover_enabled():
		return
	if not in_menu(node):
		return
	if node is BaseButton and (node as BaseButton).disabled:
		return
	play_hover()


# ------------------------------------------------------------------
# 播放
# ------------------------------------------------------------------

## 菜单按钮按下（没有可用音频 / 不在场景树里时安静地什么都不做）。
static func play_click() -> void:
	if _play_random(_click, click_db()):
		click_play_count += 1


## 菜单按钮悬停（触屏 / 没有悬停的平台不播）。
static func play_hover() -> void:
	if _play_random(_hover, hover_db()):
		hover_play_count += 1


## 建造：本机阵营的建筑落成（调用方负责过滤阵营，见 game_scene3d._feed_build_sfx）。
static func play_build() -> void:
	if _play_random(_build, build_db()):
		build_play_count += 1


## 点击音量（dB）。默认 +3，配置键 `ui.sfx_click_db`；夹在 −30..+12 免得写坏。
static func click_db() -> float:
	return clampf(_num("ui.sfx_click_db", DEFAULT_CLICK_DB), -30.0, 12.0)


## 悬停音量（dB）。默认 −8，配置键 `ui.sfx_hover_db`。
static func hover_db() -> float:
	return clampf(_num("ui.sfx_hover_db", DEFAULT_HOVER_DB), -30.0, 12.0)


## 建造音量（dB）。默认 0，配置键 `ui.sfx_build_db`。
static func build_db() -> float:
	return clampf(_num("ui.sfx_build_db", DEFAULT_BUILD_DB), -30.0, 12.0)


static func _config() -> ConfigRes:
	if _cfg == null:
		_cfg = ConfigRes.load_default()
	return _cfg


static func _num(path: String, fallback: float) -> float:
	var c := _config()
	if c == null:
		return fallback
	return c.num(path, fallback)


## 从 `pool` 里随机挑一段，用轮转的播放器按 `volume_db` 播出去。@return 真的播了没有。
static func _play_random(pool: Array, volume_db: float) -> bool:
	_ensure_streams()
	if pool.is_empty():
		return false
	_ensure_voices()
	if _voices.is_empty():
		return false
	var voice: AudioStreamPlayer = _voices[_voice_index]
	_voice_index = (_voice_index + 1) % _voices.size()
	if voice == null or not is_instance_valid(voice):
		return false
	voice.stream = _pick(pool)
	voice.volume_db = volume_db
	voice.play()
	return true


## 从组里随机挑一段（单独拆出来是为了让测试能直接验「同一档的多段素材都会被挑到」）。
static func _pick(pool: Array) -> AudioStream:
	return pool[randi() % pool.size()]


## 懒载入（只在第一次播放时读盘；缺文件 / 还没导入时静默跳过，不打断游戏）。
static func _ensure_streams() -> void:
	if _loaded:
		return
	_loaded = true
	_load_into(_click, CLICK_PATHS)
	_load_into(_hover, HOVER_PATHS)
	_load_into(_build, BUILD_PATHS)


static func _load_into(pool: Array, paths: Array) -> void:
	for path in paths:
		if not ResourceLoader.exists(path):
			continue
		var s: Resource = load(path)
		if s is AudioStream:
			pool.append(s)


## 懒建播放器（挂在根 Window 下：跨页面 / 跨对局不会被回收）。
static func _ensure_voices() -> void:
	if not _voices.is_empty():
		return
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		return
	var root: Window = (loop as SceneTree).root
	if root == null:
		return
	for i in VOICE_COUNT:
		var p := AudioStreamPlayer.new()
		p.name = "SfxVoice%d" % i
		root.add_child(p)
		_voices.append(p)
