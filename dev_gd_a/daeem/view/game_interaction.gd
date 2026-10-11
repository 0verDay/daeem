## game_interaction.gd —— **与渲染无关**的交互核心（输入路由 / 命令转发 / HUD 接线 / 逻辑事件分发）
##
## ★★ 为什么要有这个文件（改之前必读，这是本版最重要的一次结构决定）：
##
##   2D 与 3D 两个游戏内场景**不能互相继承** —— `game_scene.gd` 是 `Node2D`、
##   `game_scene3d.gd` 是 `Node3D`，而 GDScript 只有一个基类，`Node2D` 与 `Node3D`
##   又是平级的两个分支（本轮已为此踩过一次 Parse Error，见 pitfalls 10.8）。
##
##   ⇒ 于是「场景外壳」注定有两份，但**交互逻辑绝不该有两份**。本文件就是那条分界线：
##       · **属于这里**：输入怎么路由（先问 HUD、再走地图）、命令怎么从界面转给逻辑、
##         逻辑事件怎么变成界面文案、暂停怎么同步、选中集合怎么算 —— 这些**与怎么画没有任何关系**；
##       · **不属于这里**：相机、视图节点、每帧怎么把 world 同步到画面、覆盖层怎么定位。
##
##   ★★ 判据（本项目的既有教训）：「投影一旦有两份实现，迟早会分叉」（详见 route.md 四十一节）。
##      交互逻辑更是如此 —— 两份实现的表现是「某一侧的科技格点不动 / 悬停提示不刷新」，
##      而那种 bug 极难查。所以这里**刻意**做成一个可被两个外壳共享的对象，而不是复制一份。
##
## ★ 它是 `RefCounted`，**不进场景树**（与 `logic/` 同一条口径：能不进树就不进树，
##   这样它可以在无头测试里被单独构造）。
##
## ★★ 它是**宿主驱动**的：宿主（两个场景外壳）负责
##   ① 把自己建好的 `cfg` / `world` / `input_ctrl` / `hud` / `camera_rig` 塞进来；
##   ② 每帧调用 `pump(dt)`；
##   ③ 把 `_unhandled_input` 原样转进来。
##   本文件**不主动去找**任何节点 —— 那样它就没法被单独测试了。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")


## 宿主：任何提供以下成员的节点都能当宿主
##   · `cfg` / `world` / `input_ctrl` / `hud` / `camera_rig`（字段）
##   · `fullscreen_toggled` / `return_to_menu_requested`（信号）
##   · `_sync_world_to_view()`（每帧把 world 同步到画面的那一步，由宿主实现）
var host = null

## ★ 这一局是从哪一关开的（`start()` 开的局两者都是 null；`start_level()` 会填上）
##
## 为什么放在交互核心里而不是场景里：它是**流程状态**，不是渲染状态 ——
## 两个外壳都必须一模一样地回答「这一局是不是从关卡开的」。
var level_campaign = null
var level_playing = null

## 暂停同步用的上一次取值（`_sync_pause` 的脏检查）


func setup(p_host) -> void:
	host = p_host


## 每帧推进：同步暂停状态 + 派发逻辑事件。
##
## ★ 调用时机：宿主在**推进过 world.tick 之后**调它（事件是 tick 的产物）。
## ⚠️ 本函数**不做**视图同步、也**不推进逻辑** —— 那是宿主的：
##    「怎么把 world 画出来」正是两个外壳唯一真正的差别，
##    「这一帧要不要推进逻辑」则由这里给出的 `is_running()` 决定（见下）。
func pump(events: Array) -> void:
	_sync_pause()
	consume_events(events)


## ★★ 暂停状态同步：**暂停键在输入层**（`input_ctrl.paused`），不在 `world` 里。
##
## ⚠️ 我第一版写成读 `world.paused` —— 那是**凭空猜的**：`logic/world.gd` 里
##    根本没有 `paused` 这个字段（暂停是纯界面状态，逻辑层不需要知道）。
##    猜错的后果不是报错，而是「暂停键按了没用」这类静默失效。
##    ★ 教训：写交互层时**每一处字段都回去读一遍真实实现**，别凭印象。
func _sync_pause() -> void:
	if host == null or host.input_ctrl == null:
		return
	_last_running = not bool(host.input_ctrl.paused)


## 这一帧要不要推进逻辑（= 没暂停）。
##
## ★★ 为什么这个门必须存在（本轮实测踩到）：2D 版把 `world.tick()` **夹在
##    `if _running:` 里** —— 暂停时**逻辑冻结，但渲染与相机照旧**。
##    我的 3D 主循环一开始漏了这个门，表现为「暂停之后世界还在跑」；
##    而在测试里它是另一种样子：同一条操作被记了两次
##    （实测 `test_ui` 报 `entries=["zone_specialize", "zone_specialize"]`）。
##    ★ 判据：`_process` 里凡是要改逻辑状态的调用，都必须在这个门后面。
func is_running() -> bool:
	return _last_running


## 暂停标志的上一次取值（`_sync_pause` 的结果；默认 true = 开局不暂停）
var _last_running: bool = true


## 逻辑事件 → 界面提示。**这是 2D / 3D 共用的一份**（口径必须逐字一致）。
##
## ★★ 两条**犯过三次**的教训，写在这里以免再犯（原实现见 `game_scene.gd` 的历史注释）：
##   ① 拒因类事件（`recruit_rejected` / `order_rejected` / `tech_rejected` /
##      `upgrade_rejected` / `revive_rejected`）**必须先按阵营过滤**。
##      为什么：阵营 AI 每帧重试，被拒后推事件 ⇒ 不过滤的话玩家会一直看到
##      「只能在己方区划内招募…」这种**别人的**红字，而且 AI 每帧重试 ⇒
##      提示被反复续期、**永远不消失**（实测报回来的正是这个）。
##   ② 文案本身**不在这一层拼**：交给 `hud.*_reject_text()`。
##      为什么：那些句子依赖界面自己的口径（比如「最多 3 条」里的 3、
##      `busy` 那条要点名是哪个对象），放在这里会变成第二份口径。
##      ★ 本文件只负责「哪条事件该给谁看」，不负责措辞。
func consume_events(events: Array) -> void:
	if host == null or host.hud == null or events.is_empty():
		return
	var hud = host.hud
	for evt in events:
		match String(evt.get("type", "")):
			"recruit_rejected":
				# ★ max 来自事件（区划招募的队列上限可能与「将领招募」那条不同）；
				#   没带（0）时由 hud 用它自己那张表的上限。
				if _is_my_event(evt):
					hud.show_notice(hud.recruit_reject_text(
						String(evt.get("reason", "")), String(evt.get("kind", "")),
						int(evt.get("max", 0))))
			"order_rejected":
				if _is_my_event(evt):
					hud.show_notice(hud.order_reject_text(String(evt.get("reason", ""))))
			"tech_rejected":
				if _is_my_event(evt):
					hud.show_notice(hud.tech_reject_text(String(evt.get("reason", ""))))
			"upgrade_rejected":
				# ★ 整个事件传进去：`busy` 那条文案要点名是哪个对象
				if _is_my_event(evt):
					hud.show_notice(hud.upgrade_reject_text(String(evt.get("reason", "")), evt))
			"revive_rejected":
				if _is_my_event(evt):
					hud.show_notice(hud.revive_reject_text(String(evt.get("reason", ""))))
			"unit_recruited":
				# ★ 这条**不过滤阵营**：`notify_unit_recruited` 自己按将领归属判断，
				#   而且它要更新的是编队面板的「谁已就位」，AI 的招募同样会改变名册。
				if host.input_ctrl != null:
					host.input_ctrl.notify_unit_recruited(
						evt.get("leader", null), evt.get("unit", null))


## ★★ 这条事件是**本机玩家这一方**产生的吗？
##
## 判据（与 2D 版逐字相同，别改）：
##   · 事件带 `faction`：== 本机阵营才算我的；
##   · 不带：**保守地认为是我这边**（宁可多一句提示，也不要漏掉玩家自己的报错）——
##     这类事件都是「有人下了命令、被拒了」，而目前只有命令与 AI 两条来源。
##
## ⚠️ 逻辑层**不知道谁是本机**（它是权威、要同时服务多个席位），
##    所以这个判断只能在视图侧做 —— 这也正是它属于交互核心的理由。
func _is_my_event(evt: Dictionary) -> bool:
	if host == null or host.world == null:
		return false
	var f: String = String(evt.get("faction", ""))
	if f == "":
		return true
	return f == String(host.world.my_faction)
