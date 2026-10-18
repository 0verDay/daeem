## panel_expand.gd —— 「点一颗按钮 → 它所在的面板撑满全屏、其余面板让开」的引擎
##
## 机制照搬 nsoc（`scripts/app/main_menu.gd` 的转场 + `scripts/ui/secondary_panel.gd` 的面板），
## 只把版式与配色换成本作的：版式在 `view/menu_chrome.gd`，配色在 `view/theme.gd`。
##
## 一次完整转场（正向）的四步 —— 每一步都有它非这么写不可的理由：
##   1. **拍平锚点**：先把参与转场的面板的锚点改成 TOP_LEFT、把当前位置 / 尺寸抄下来。
##      之后全靠 Tween 直接写 `position/size`；锚点要是还挂着，父布局会在动画中途把位置拽回去。
##   2. **钉住原点面板的子控件**：Button / Label / TextureRect 先 `top_level = true` 脱离父布局，
##      再把 `global_position/size` 钉死，然后才淡出 —— 不钉住的话，面板一放大它们会被
##      VBox/HBox 拉着一起跑（观感是「按钮在面板里乱窜」）。
##   3. **其余面板水平滑出屏幕外 + 淡出**，同时**立刻禁掉它们的鼠标输入**：
##      滑到一半时它们的矩形还压在屏幕里，鼠标过滤器还是 STOP 的话，
##      就会在撑开的面板上留一片「点得到旧按钮」的洞。
##   4. **撑开原点面板**：用 `size` / `position` / `pivot_offset` 扩到 `屏幕 − 2×margin`、位置 `(margin, margin)`。
##      ⚠️ 不能改 `scale`：缩放会把 1px 金线拉粗、把圆角拉成椭圆（nsoc 的实测结论）。
##
## 反向就是把上面每一步 Tween 回记下来的初值；面板内的按钮**延迟**到
## 「总时长 − 淡出时长」才开始淡回（与正向对称：撑开没走完之前它们不出现）。
##
## ★ `dir = 0` 的一档 = **只淡出、不移位**：给「没有『外面』可滑」的目标用
##   （本作里是主界面正中那一列 —— 它整页居中，往哪边滑都别扭）。
##
## ★ 动效总开关（`view/theme.gd` 的 `animations_enabled()`）关掉时**直接呈现终态**：
##   与 `view/fill_button.gd` 同一条口径 —— 关掉动效是「立刻到位」，不是「没有转场」。
##   （nsoc 里对应 `_apply_expanded_instant()`。）
##
## ⚠️ 与 nsoc 的一处**有意不同**：nsoc 靠 `move_to_front()` 让撑开的面板盖住中间那几颗按钮；
##   本作要求「旧列叠在菜单上层」，所以旧列是靠**淡出 + 期间禁输入**让路的（`dir = 0` 那一档）。
extends Node

const ThemeRes = preload("res://view/theme.gd")

## 二级面板挂上来了（撑开动画已跑完）
signal expanded
## 已回到初始状态（收回动画已跑完）
signal reversed

## 兜底时长（与 config.json 的 menu.chrome.transition_* / expanded_margin 一致）。
const DEFAULT_TRANSITION_SEC := 0.45
const DEFAULT_FADE_SEC := 0.15
const DEFAULT_MARGIN := 24.0
## 「主菜单整体滑入」（首次进主界面那一下）的兜底时长，与 menu.chrome.intro_sec 一致。
const DEFAULT_INTRO_SEC := 0.55
## `dir != 0` 的面板往**左**滑出时，比屏幕左边再多推这么多（免得尺寸算小了露出一个角）
const OFFSCREEN_PAD := 40.0

var transition_sec: float = DEFAULT_TRANSITION_SEC
var fade_sec: float = DEFAULT_FADE_SEC
var margin: float = DEFAULT_MARGIN
## 首次进主界面时各面板**滑入**的时长（见 `play_intro()`）。
var intro_sec: float = DEFAULT_INTRO_SEC

## 参与转场的面板的共同父节点（撑开后的尺寸以它为准 —— 它是铺满整页的那一层）
var _host: Control = null
## 造二级面板的工厂（返回一个带 `attach()` / `back_pressed` 的节点）
var _panel_factory: Callable = Callable()
## `[{node: Control, dir: int}]`
var _targets: Array = []
## Control -> {position, size, scale, modulate, pivot}（拍平锚点之后抄下来的初值）
var _initial: Dictionary = {}
## 被钉住的子控件：`[{node: Control, filter: int, modulate: Color}]`
var _frozen: Array = []
## 被压成 IGNORE 的节点：Control -> 原来的 mouse_filter
var _blocked: Dictionary = {}

var _tween: Tween = null
var _busy: bool = false
var _is_expanded: bool = false
var _panel = null
var _origin: Control = null


func setup(host: Control, panel_factory: Callable, p_transition_sec: float,
		p_fade_sec: float, p_margin: float) -> void:
	_host = host
	_panel_factory = panel_factory
	transition_sec = maxf(0.01, p_transition_sec)
	fade_sec = maxf(0.0, p_fade_sec)
	margin = maxf(0.0, p_margin)


## 登记一个参与转场的面板。
## @param dir < 0 向左滑出屏外；> 0 向右滑出屏外；**0 = 只淡出不移位**（见文件头）
func add_target(node: Control, dir: int = 0) -> void:
	if node == null:
		return
	_targets.append({"node": node, "dir": dir})


## 抄下所有目标的初始状态。★ 必须**等一帧**再抄：
##   面板的 `position/size` 要等 Godot 跑完这次 layout pass 才定下来，
##   在 `_ready()` 里当场抄到的会是 (0, 0) 与零尺寸 —— 反向时就全部「归位」到左上角去了。
func attach() -> void:
	await get_tree().process_frame
	if not is_instance_valid(self) or _host == null:
		return
	_record_all()


func is_busy() -> bool:
	return _busy


func is_expanded() -> bool:
	return _is_expanded


## 当前被撑开的那块面板（没展开时是 null）。
func expanded_panel() -> Control:
	return _origin if _is_expanded else null


## 展开出来的二级面板（空面板那一块）。
func secondary_panel():
	return _panel


# ------------------------------------------------------------------
# 正向
# ------------------------------------------------------------------

## 从 `origin` 撑开。`clicked` 只记录「是哪颗按钮触发的」（不参与动画，留给排查用）。
func expand(origin: Control, clicked: Control = null) -> void:
	if origin == null or _busy or _is_expanded:
		return
	if _initial.is_empty():
		# attach() 等的那一帧还没到就被点了（正常点不到，兜一手）
		_record_all()
	if _initial.is_empty():
		return
	_origin = origin
	_kill_tween()
	_busy = true

	if not ThemeRes.animations_enabled():
		_apply_expanded_instant(origin)
		return

	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.set_trans(Tween.TRANS_CUBIC)
	_tween.set_ease(Tween.EASE_IN_OUT)

	# 1) 原点面板自己的子控件：先钉住，再淡出
	_frozen.clear()
	for c in _collect_visuals(origin):
		_freeze(c)
		_tween.tween_property(c, "modulate:a", 0.0, fade_sec)

	# 2) 其余面板：让路（滑出 + 淡出 + 立刻禁输入）
	for entry in _targets:
		var node: Control = entry["node"]
		if node == null or not is_instance_valid(node) or node == origin:
			continue
		var init: Dictionary = _initial.get(node, {})
		if init.is_empty():
			continue
		_block_subtree(node)
		var dir: int = int(entry["dir"])
		if dir != 0:
			var from: Vector2 = init["position"]
			var off_x: float = _screen_size().x if dir > 0 else (-node.size.x - OFFSCREEN_PAD)
			_tween.tween_property(node, "position", Vector2(from.x + off_x, from.y), transition_sec)
		_tween.tween_property(node, "modulate:a", 0.0, transition_sec)

	# 3) 撑开原点面板
	var target_size: Vector2 = _expanded_size()
	_tween.tween_property(origin, "size", target_size, transition_sec)
	_tween.tween_property(origin, "position", Vector2(margin, margin), transition_sec)
	_tween.tween_property(origin, "pivot_offset", target_size * 0.5, transition_sec)
	# 提到同级最前：其余面板正在滑走，它得盖在上面（不是靠它们让开，而是双保险）
	origin.move_to_front()

	await _tween.finished
	if not is_instance_valid(self):
		return
	_busy = false
	_is_expanded = true
	_spawn_panel(origin)
	expanded.emit()


# ------------------------------------------------------------------
# 反向
# ------------------------------------------------------------------

## 收回：所有目标 Tween 回初值，二级面板同步淡出销毁。
func reverse() -> void:
	if not _is_expanded:
		return                      # 还没展开（或正向还没跑完）—— 忽略
	_kill_tween()
	_busy = true
	_is_expanded = false

	if _panel != null and is_instance_valid(_panel):
		_panel.detach_with_fade(transition_sec)
		_panel = null
	_unfreeze_all()
	_restore_blocked()

	if not ThemeRes.animations_enabled():
		_apply_initial_instant()
		_busy = false
		reversed.emit()
		return

	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.set_trans(Tween.TRANS_CUBIC)
	_tween.set_ease(Tween.EASE_IN_OUT)
	_restore_initial(_tween)
	# 面板内的按钮**延迟**淡回：面板还没收缩完就把字亮出来会很突兀
	var delay: float = maxf(0.0, transition_sec - fade_sec)
	for c in _collect_visuals_all():
		c.modulate.a = 0.0
		_tween.tween_property(c, "modulate:a", 1.0, fade_sec).set_delay(delay)

	await _tween.finished
	if not is_instance_valid(self):
		return
	_busy = false
	reversed.emit()


## ★★ 立刻收回初始态（不播动画、不等转场）。
##
## 与 `reverse()` 的区别只有「有没有过程」：这里杀掉在跑的 Tween、直接销毁二级面板、
## 把各面板按初值摆回去。给**离开菜单**那条路用（进游戏时整层已 `hide()`，
## 收回动画没人看得见；而「返回主菜单」时必须已经是收好的状态）。
## ★ 即使正处在撑开动画中途（`_busy`）也能调用 —— 那一下的终点同样该是「收好」。
func collapse_instant() -> void:
	if not _busy and not _is_expanded:
		return
	_kill_tween()
	if _panel != null and is_instance_valid(_panel):
		# ★ 立刻摘下来再销毁：`queue_free` 要到帧末才真的走，而「回主菜单」在同一帧就会
		#   把菜单显示出来 —— 不摘的话会闪一帧「面板还盖在上面」。
		var parent: Node = _panel.get_parent()
		if parent != null:
			parent.remove_child(_panel)
		_panel.queue_free()
	_panel = null
	_unfreeze_all()
	_restore_blocked()
	_apply_initial_instant()
	_busy = false
	_is_expanded = false
	reversed.emit()


# ------------------------------------------------------------------
# 首次进入：整体滑入
# ------------------------------------------------------------------

## ★★ 首次进入主界面那一下：各目标先摆到**屏幕外**（按各自的 `dir`）+ 透明，再一起 Tween 回初值。
##   这是「入场页的 logo 缓动落位之后，主菜单的各个面板再滑出」的第二段（对应 nsoc 的
##   `_play_intro_animation()`：左/上那两块从屏左滑入、右下那块从屏右滑入）。
##
## ★ 与 `reverse()` 共用同一套「回初值 + 延迟淡入子控件」的写法，**差别只在起点**：
##   这里是「屏幕外 + 透明」，反向是「撑开态 + 透明」。
## ★ `dir = 0` 的目标（正中那一列）没有「屏幕外」可放，就在原地淡入。
## ★ 缓动用 `EASE_OUT`（而反向是 `EASE_IN_OUT`）：入场要「减速落位」，收回要「两头都软」。
func play_intro() -> void:
	if _initial.is_empty():
		_record_all()
	if _initial.is_empty():
		return
	_kill_tween()
	_busy = true

	var screen_w: float = _screen_size().x
	for node in _initial.keys():
		if not is_instance_valid(node):
			continue
		var init: Dictionary = _initial[node]
		var c: Control = node
		var dir: int = _target_dir(node)
		if dir != 0:
			c.position = (init["position"] as Vector2) + Vector2(float(dir) * screen_w, 0.0)
			c.modulate.a = 0.0
		else:
			# ★★ `dir = 0` 的目标（正中那一列）**原地不动、也不淡**：
			#   它上面的标题条正是入场页落位动画的终点 —— 让它从 0 淡入，logo 会在切页那一刻
			#   **眨一下眼**（实测截图看得到：落位刚结束是亮的，切页后暗一下再亮回来）。
			#   它里面那些控件（地图标签 / test / campaign 那几颗）仍然会被下面那段延迟淡入照顾到。
			c.modulate.a = (init["modulate"] as Color).a
	var widgets: Array = _collect_visuals_all()
	for w in widgets:
		w.modulate.a = 0.0

	if not ThemeRes.animations_enabled() or intro_sec <= 0.0:
		for node in _initial.keys():
			if is_instance_valid(node):
				(node as Control).position = _initial[node]["position"]
				(node as Control).modulate = _initial[node]["modulate"]
		for w in widgets:
			w.modulate.a = 1.0
		_busy = false
		reversed.emit()
		return

	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.set_trans(Tween.TRANS_CUBIC)
	_tween.set_ease(Tween.EASE_OUT)
	for node in _initial.keys():
		if not is_instance_valid(node):
			continue
		var init: Dictionary = _initial[node]
		if _target_dir(node) == 0:
			continue                       # 不移位也不淡（见上面那段 ★★）
		_tween.tween_property(node, "position", init["position"], intro_sec)
		_tween.tween_property(node, "modulate", init["modulate"], intro_sec)
	# 面板里的子控件**错后半拍**淡入：面板先滑到位，字再亮起来
	var delay: float = maxf(0.0, intro_sec - fade_sec)
	for w in widgets:
		_tween.tween_property(w, "modulate:a", 1.0, fade_sec).set_delay(delay)

	await _tween.finished
	if not is_instance_valid(self):
		return
	_busy = false
	reversed.emit()


## 某个目标是往哪个方向滑的（没登记过 = 0 = 不移位）。
func _target_dir(node: Control) -> int:
	for entry in _targets:
		if entry["node"] == node:
			return int(entry["dir"])
	return 0


# ------------------------------------------------------------------
# 初值：抄下来 / 还原
# ------------------------------------------------------------------

func _record_all() -> void:
	_initial.clear()
	for entry in _targets:
		_record_initial(entry["node"])


## 拍平锚点为 TOP_LEFT 并把初值抄进 `_initial`（见文件头第 1 步）。
func _record_initial(ctrl: Control) -> void:
	if ctrl == null or not is_instance_valid(ctrl):
		return
	var pos: Vector2 = ctrl.position
	var sz: Vector2 = ctrl.size
	ctrl.set_anchors_preset(Control.PRESET_TOP_LEFT, false)
	ctrl.position = pos
	ctrl.size = sz
	ctrl.pivot_offset = sz * 0.5
	_initial[ctrl] = {
		"position": pos,
		"size": sz,
		"scale": ctrl.scale,
		"modulate": ctrl.modulate,
		"pivot": ctrl.pivot_offset,
	}


func _restore_initial(tw: Tween) -> void:
	for node in _initial.keys():
		if not is_instance_valid(node):
			continue
		var init: Dictionary = _initial[node]
		tw.tween_property(node, "position", init["position"], transition_sec)
		tw.tween_property(node, "size", init["size"], transition_sec)
		tw.tween_property(node, "scale", init["scale"], transition_sec)
		tw.tween_property(node, "pivot_offset", init["pivot"], transition_sec)
		tw.tween_property(node, "modulate", init["modulate"], transition_sec)


## 不走动画、直接回到初值（动效关掉时走这条）。
func _apply_initial_instant() -> void:
	for node in _initial.keys():
		if not is_instance_valid(node):
			continue
		var init: Dictionary = _initial[node]
		var c: Control = node
		c.position = init["position"]
		c.size = init["size"]
		c.scale = init["scale"]
		c.pivot_offset = init["pivot"]
		c.modulate = init["modulate"]
	for c in _collect_visuals_all():
		c.modulate.a = 1.0


## 不走动画、直接进入撑开态（动效关掉时走这条）。
func _apply_expanded_instant(origin: Control) -> void:
	_frozen.clear()
	for c in _collect_visuals(origin):
		_freeze(c)
		c.modulate.a = 0.0
	for entry in _targets:
		var node: Control = entry["node"]
		if node == null or not is_instance_valid(node) or node == origin:
			continue
		var init: Dictionary = _initial.get(node, {})
		_block_subtree(node)
		node.modulate.a = 0.0
		var dir: int = int(entry["dir"])
		if dir != 0 and not init.is_empty():
			var from: Vector2 = init["position"]
			var off_x: float = _screen_size().x if dir > 0 else (-node.size.x - OFFSCREEN_PAD)
			node.position = Vector2(from.x + off_x, from.y)
	var target_size: Vector2 = _expanded_size()
	origin.size = target_size
	origin.position = Vector2(margin, margin)
	origin.pivot_offset = target_size * 0.5
	origin.move_to_front()
	_busy = false
	_is_expanded = true
	_spawn_panel(origin)
	expanded.emit()


# ------------------------------------------------------------------
# 钉住 / 让路 / 挂面板
# ------------------------------------------------------------------

## 收集一块面板里「要随转场淡出」的视觉元素（Button / Label / TextureRect）。
## ★ 排除带 `transition_skip` 元数据的节点及其整棵子树 —— 二级面板用它标记
##   「我自己的淡入淡出归我自己管」。
func _collect_visuals(root: Node) -> Array:
	var out: Array = []
	if root == null or not is_instance_valid(root):
		return out
	if root.has_meta("transition_skip"):
		return out
	if root is Button or root is Label or root is TextureRect:
		out.append(root)
		return out
	for child in root.get_children():
		if child is Node and child.has_meta("transition_skip"):
			continue
		out.append_array(_collect_visuals(child))
	return out


func _collect_visuals_all() -> Array:
	var out: Array = []
	for entry in _targets:
		out.append_array(_collect_visuals(entry["node"]))
	return out


## 把一颗子控件从父布局里解放出来、位置钉死，并记下鼠标过滤器 / 透明度原值（反向要逐项还原）。
func _freeze(c: Control) -> void:
	var gpos: Vector2 = c.global_position
	var csize: Vector2 = c.size
	_frozen.append({"node": c, "filter": c.mouse_filter, "modulate": c.modulate})
	c.top_level = true
	c.global_position = gpos
	c.size = csize
	# ★ 立刻禁掉输入（nsoc 是撑开动画跑完才禁的）：转场期间本来就不该点到任何旧控件，
	#   而且 freeze 之后它们**飘在撑开的面板之上**，不禁就是一片可点的洞。
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _unfreeze_all() -> void:
	for rec in _frozen:
		var c: Control = rec["node"]
		if not is_instance_valid(c):
			continue
		c.top_level = false
		c.mouse_filter = rec["filter"]
		c.modulate = rec["modulate"]
	_frozen.clear()


## 递归把一棵子树的鼠标过滤器压成 IGNORE，记下原值（反向时逐项还原）。
func _block_subtree(root: Control) -> void:
	if root == null or not is_instance_valid(root):
		return
	if root.has_meta("transition_skip"):
		return
	_blocked[root] = root.mouse_filter
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in root.get_children():
		if child is Control:
			_block_subtree(child)


func _restore_blocked() -> void:
	for node in _blocked.keys():
		if is_instance_valid(node):
			(node as Control).mouse_filter = _blocked[node]
	_blocked.clear()


func _spawn_panel(origin: Control) -> void:
	if _panel != null and is_instance_valid(_panel):
		_panel.queue_free()
	_panel = null
	if not _panel_factory.is_valid():
		return
	var made = _panel_factory.call()
	if made == null:
		return
	_panel = made
	if _panel.has_signal("back_pressed"):
		_panel.back_pressed.connect(reverse)
	if _panel.has_method("attach"):
		_panel.attach(origin)


func _screen_size() -> Vector2:
	if _host != null and is_instance_valid(_host) and _host.size.x > 1.0:
		return _host.size
	return get_viewport().get_visible_rect().size


func _expanded_size() -> Vector2:
	return _screen_size() - Vector2(margin * 2.0, margin * 2.0)


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
