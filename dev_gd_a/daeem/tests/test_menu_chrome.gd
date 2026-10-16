## test_menu_chrome.gd —— ★★ 主界面新版式外壳（仿 nsoc）：三块面板 + 撑开 / 让路 / 返回
##
## 这一层是「版式」而不是「进入游戏的入口」，所以断言分两类：
##   · **版式**：三块面板各在哪个角、五颗侧边栏按钮的名字与顺序、右下「上排 2 + 下排 1」、
##     头像用的是不是 Godot 图标、两行字是不是来自 config；
##   · **转场**：点一下 → 那块面板撑满全屏（`屏幕 − 2×margin`）、其余块**滑出屏幕外并淡出**、
##     正中那一列也同步让路且**不吃鼠标**（否则会在撑开的面板上留一片可点的洞）、
##     撑开的是一块**只有「返回」的空面板**、按返回之后一切回到初值。
##
## ★ 转场是**时间驱动**的 Tween，所以等待按**真实秒数**轮询，而不是等固定帧数
##   （不同机器一帧多久不一样；test_map_select.gd 那种「等 30 帧」在这里不够稳）。
extends "res://tests/test_case.gd"

const ThemeRes = preload("res://view/theme.gd")
const FillButtonRes = preload("res://view/fill_button.gd")

## 等转场跑完时多给的余量（秒）—— Tween 收尾 + 一帧的排版
const SETTLE_PAD_SEC := 0.25


func _initialize() -> void:
	_case_name = "menu_chrome"
	_run()


func _run() -> void:
	# ★ 先过一帧：`--script` 模式下 `_initialize()` 里 root 还没就绪（与 test_map_select.gd 同一种写法）
	await process_frame

	var main = await _spawn_menu()
	if main == null:
		_finish()
		return
	var menu = main.start_screen
	var chrome = menu.menu_chrome()
	ok(chrome != null, "主界面上有新版式外壳（MenuChrome）")
	if chrome == null:
		main.queue_free()
		_finish()
		return

	_test_config(menu)
	_test_layout(menu, chrome)
	_test_profile(menu, chrome)
	await _test_expand(menu, chrome)
	await _test_reverse(menu, chrome)
	await _test_fill_cleared_after_reverse(menu, chrome)
	await _test_battle_entries_in_panel(menu, chrome)
	await _test_instant_when_animations_off(menu, chrome)

	main.queue_free()
	await process_frame

	# ★ 入场 → 主界面的**两段动画**要在一棵「刚开局、还停在入场页」的树上验，
	#   所以这一段单独起一个主场景（上面那棵已经过了入场）。
	await _test_intro_phases()
	_finish()


# ------------------------------------------------------------------
# config
# ------------------------------------------------------------------

func _test_config(menu) -> void:
	var cfg = menu.cfg
	near(cfg.num("menu.chrome.transition_sec", -1.0), 0.45, 0.0001,
		"menu.chrome.transition_sec 读到了（撑开 / 收回时长）")
	near(cfg.num("menu.chrome.transition_fade_sec", -1.0), 0.15, 0.0001,
		"menu.chrome.transition_fade_sec 读到了（子控件淡出时长）")
	near(cfg.num("menu.chrome.expanded_margin", -1.0), 24.0, 0.0001, "expanded_margin 读到了")
	near(cfg.num("menu.chrome.profile.w", -1.0), 320.0, 0.0001, "资料面板的宽读到了")
	near(cfg.num("menu.chrome.nav.h", -1.0), 800.0, 0.0001, "左导航的高读到了")
	near(cfg.num("menu.chrome.side.w", -1.0), 450.0, 0.0001, "右下入口的宽读到了")
	ok(cfg.num("menu.chrome.transition_fade_sec", -1.0) < cfg.num("menu.chrome.transition_sec", -1.0),
		"★ 淡出时长比转场时长短（收回时子控件才有「延迟淡回」可言）")


# ------------------------------------------------------------------
# 版式
# ------------------------------------------------------------------

func _test_layout(menu, chrome) -> void:
	var cfg = menu.cfg
	var host: Vector2 = chrome.size
	var profile: Control = chrome.profile_panel()
	var nav: Control = chrome.left_nav_panel()
	var side: Control = chrome.right_side_panel()
	ok(profile != null and nav != null and side != null, "三块面板都建出来了")
	if profile == null or nav == null or side == null:
		return
	eq(profile.name, "ProfilePnl", "左上那块叫 ProfilePnl（与 nsoc 同名）")
	eq(nav.name, "LeftNavPnl", "左侧那块叫 LeftNavPnl（与 nsoc 同名）")
	eq(side.name, "RightSidePnl", "右下那块叫 RightSidePnl（与 nsoc 同名）")

	var p_rect := profile.get_global_rect()
	var n_rect := nav.get_global_rect()
	var s_rect := side.get_global_rect()
	ok(p_rect.position.x < 100.0 and p_rect.position.y < 100.0, "资料面板在左上角")
	ok(n_rect.position.x < 100.0, "左导航贴着左边")
	near(n_rect.get_center().y, host.y * 0.5, 2.0,
		"★★ 左导航**竖直居中**（中心 y %.1f = 屏高一半）" % n_rect.get_center().y)
	ok(s_rect.end.x > host.x - 120.0, "右下入口贴着右边")
	ok(s_rect.end.y > host.y - 120.0, "右下入口贴着下边")
	ok(not _overlap(p_rect, n_rect), "资料与左导航不重叠")
	ok(not _overlap(p_rect, s_rect), "资料与右下入口不重叠")
	ok(not _overlap(n_rect, s_rect), "左导航与右下入口不重叠")

	# ---- 左侧五颗：文字与顺序 = config 的 items ----
	var items: Array = _as_array(cfg.get_path_value("menu.chrome.nav.items"))
	var nav_btns: Array = chrome.nav_buttons()
	ok(items.size() >= 5, "（前提）config 里侧边栏至少五条（%d 条）" % items.size())
	eq(nav_btns.size(), items.size(), "★ 侧边栏按钮条数 = config 里 items 的条数")
	for i in mini(nav_btns.size(), items.size()):
		var b: Button = nav_btns[i]
		eq(_flat(b.text), String(items[i]),
			"★ 第 %d 颗是「%s」（顺序就是 config 里的顺序）" % [i, String(items[i])])
	if nav_btns.size() > 0:
		ok(String((nav_btns[0] as Button).text).contains("\n"),
			"★★ 文字**竖排**（一个字一行 —— nsoc 侧边栏的排法）")
	# 从上到下：每颗都比上一颗低
	var order_ok := true
	for i in range(1, nav_btns.size()):
		var y_now: float = (nav_btns[i] as Control).get_global_rect().position.y
		var y_prev: float = (nav_btns[i - 1] as Control).get_global_rect().position.y
		if y_now < y_prev - 1.0:
			order_ok = false
	ok(order_ok, "★ 按钮在竖直方向**从上到下**按数组顺序排")

	# ---- 右下三颗：上排 2 + 下排 1 ----
	var side_btns: Array = chrome.side_buttons()
	eq(side_btns.size(), 3, "右下三颗按钮")
	if side_btns.size() < 3:
		return
	var b0: Control = side_btns[0]
	var b1: Control = side_btns[1]
	var b2: Control = side_btns[2]
	eq(b0.text, "战役", "上排第一颗是「战役」")
	eq(b1.text, "演义", "上排第二颗是「演义」")
	eq(b2.text, "合作模式", "下排那颗是「合作模式」")
	near(b0.get_global_rect().position.y, b1.get_global_rect().position.y, 2.0,
		"★★ 上排两颗在**同一行**")
	ok(b1.get_global_rect().position.x >= b0.get_global_rect().end.x - 1.0,
		"★★ 上排两颗**并排**（第二颗在第一颗右边）")
	ok(b2.get_global_rect().position.y >= b0.get_global_rect().end.y - 1.0,
		"★★ 下排那颗在它们**下方**")
	ok(b2.get_global_rect().size.x > b0.get_global_rect().size.x * 1.5,
		"★ 下排那颗是**通栏**（%.0f 宽 > 上排一颗的 %.0f）"
		% [b2.get_global_rect().size.x, b0.get_global_rect().size.x])


func _test_profile(menu, chrome) -> void:
	var cfg = menu.cfg
	var av: TextureRect = chrome.avatar()
	ok(av != null, "资料面板里有头像")
	if av != null:
		ok(av.texture != null, "头像有贴图")
		if av.texture != null:
			eq(av.texture.resource_path, "res://icon.svg",
				"★★ 头像就是 **Godot 图标**（res://icon.svg —— 用户指定的占位）")
	var nl: Label = chrome.name_label()
	var ml: Label = chrome.money_label()
	ok(nl != null and ml != null, "名字 / 资金两行都在")
	if nl != null:
		eq(nl.text, cfg.str_val("menu.chrome.profile.name", ""),
			"★ 第一行 = config 的 profile.name")
		ok(nl.text.length() > 0, "第一行不是空的")
	if ml != null:
		eq(ml.text, cfg.str_val("menu.chrome.profile.money", ""),
			"★ 第二行 = config 的 profile.money")
		if nl != null:
			ok(ml.get_global_rect().position.y > nl.get_global_rect().position.y,
				"★ 资金那行在名字**下面**")


# ------------------------------------------------------------------
# 转场
# ------------------------------------------------------------------

func _test_expand(menu, chrome) -> void:
	var cfg = menu.cfg
	var engine = chrome.expand_engine()
	var nav: Control = chrome.left_nav_panel()
	var profile: Control = chrome.profile_panel()
	var side: Control = chrome.right_side_panel()
	var host: Vector2 = chrome.size
	var margin: float = cfg.num("menu.chrome.expanded_margin", 24.0)
	var sec: float = cfg.num("menu.chrome.transition_sec", 0.45)

	var nav_btns: Array = chrome.nav_buttons()
	if nav_btns.is_empty():
		return
	var first: Button = nav_btns[0]
	var small_size: Vector2 = nav.get_global_rect().size

	await _click_at(first.get_global_rect().get_center())
	ok(engine.is_busy() or engine.is_expanded(), "★ 点侧边栏按钮触发了撑开")

	await _wait_sec(sec + SETTLE_PAD_SEC)
	ok(engine.is_expanded(), "★★ 转场跑完 → 进入展开态")
	if not engine.is_expanded():
		return

	# ---- 撑开：尺寸与位置 ----
	var expanded := nav.get_global_rect()
	v2_near(expanded.size, host - Vector2(margin * 2.0, margin * 2.0), 2.0,
		"★★ 那块面板撑到「屏幕 − 2×margin」（%.0f×%.0f）" % [expanded.size.x, expanded.size.y])
	v2_near(expanded.position, Vector2(margin, margin), 2.0, "★★ 并且落在 (margin, margin)")
	ok(expanded.size.x > small_size.x * 3.0,
		"★ 确实撑开了（原宽 %.0f → %.0f）" % [small_size.x, expanded.size.x])

	# ---- 二级面板：只有一颗「返回」的空面板 ----
	var panel = engine.secondary_panel()
	ok(panel != null, "撑开之后挂上了二级面板")
	if panel != null:
		eq(panel.get_child_count(), 1,
			"★★ 面板里**只有一颗按钮**（用户要求「面板中不需要有任何东西」）")
		var back: Button = panel.back_button()
		ok(back != null, "那颗就是「返回」")
		if back != null:
			eq(back.text, cfg.str_val("menu.chrome.back_text", "返回"), "文案来自 config")
			eq(back.disabled, false, "现在可以点（撑开态下它是唯一的出口）")
			var br := back.get_global_rect()
			ok(br.position.x > host.x * 0.5 and br.position.y < host.y * 0.5,
				"★ 「返回」在**右上角**")

	# ---- 其他块让路：淡出 + 滑出屏外 ----
	ok(profile.modulate.a < 0.02, "★ 资料面板让路（alpha → %.2f）" % profile.modulate.a)
	ok(side.modulate.a < 0.02, "★ 右下入口让路（alpha → %.2f）" % side.modulate.a)
	ok(profile.get_global_rect().end.x < 0.0,
		"★★ 左侧那两块**滑出屏幕左边**（右缘 x %.0f < 0）" % profile.get_global_rect().end.x)
	ok(side.get_global_rect().position.x > host.x,
		"★★ 右下那一块**滑出屏幕右边**（左缘 x %.0f > 屏宽 %.0f）"
		% [side.get_global_rect().position.x, host.x])

	# ---- 撑开面板里原来的按钮不再吃鼠标（否则它们飘在上面 = 一片可点的洞）----
	for b in nav_btns:
		eq((b as Control).mouse_filter, Control.MOUSE_FILTER_IGNORE,
			"★ 撑开之后原按钮不吃鼠标")

	# ---- ★ 正中那一列也同步让路 ----
	var old_col: Control = menu.get_node_or_null("StartRoot/MainMenu")
	ok(old_col != null, "（前提）找得到正中那一列（StartRoot/MainMenu）")
	if old_col != null:
		ok(old_col.modulate.a < 0.02,
			"★★ 正中那一列**同步让路**（alpha → %.2f）——「其他 ui 同步避让」" % old_col.modulate.a)
	# ⚠️ 它现在**只剩标题条**（地图选择条 / test / campaign_test 都搬进「战役」面板了，
	#    见 view/battle_entries.gd）—— 所以这里没有「它上面那些按钮不吃鼠标」可断言了。


func _test_reverse(menu, chrome) -> void:
	var cfg = menu.cfg
	var engine = chrome.expand_engine()
	var sec: float = cfg.num("menu.chrome.transition_sec", 0.45)
	var nav: Control = chrome.left_nav_panel()
	if not engine.is_expanded():
		return
	var expanded_width: float = nav.get_global_rect().size.x

	var panel = engine.secondary_panel()
	var back: Button = panel.back_button() if panel != null else null
	if back == null:
		ok(false, "（前提）撑开态里应该有「返回」")
		return

	await _click_at(back.get_global_rect().get_center())
	await _wait_sec(sec + SETTLE_PAD_SEC)

	ok(not engine.is_expanded(), "★★ 按「返回」之后回到未展开态")
	ok(engine.secondary_panel() == null, "★ 二级面板已被销毁")
	ok(not engine.is_busy(), "★ 也不在转场中途")

	# 三块面板都回到初值
	for pair in [[chrome.profile_panel(), "资料"], [nav, "左导航"], [chrome.right_side_panel(), "右下入口"]]:
		var c: Control = pair[0]
		ok(c.modulate.a > 0.98, "★ %s 的透明度回来了（%.2f）" % [pair[1], c.modulate.a])
		ok(c.get_global_rect().size.x > 1.0 and c.get_global_rect().size.y > 1.0,
			"★ %s 有尺寸（没被缩成 0）" % pair[1])
	ok(nav.get_global_rect().size.x < expanded_width * 0.5,
		"★★ 左导航从撑开态收缩回窄条（%.0f → %.0f）"
		% [expanded_width, nav.get_global_rect().size.x])
	ok(nav.get_global_rect().position.x < 100.0, "★ 而且回到了屏幕左边")

	# 撑开面板里的按钮重新吃鼠标了
	for b in chrome.nav_buttons():
		eq((b as Control).mouse_filter, Control.MOUSE_FILTER_STOP,
			"★ 收回去之后原按钮重新吃鼠标")

	# 正中那一列也回来了（★ 它现在只剩标题条：那几个测试控件已搬进「战役」面板）
	var old_col: Control = menu.get_node_or_null("StartRoot/MainMenu")
	if old_col != null:
		ok(old_col.modulate.a > 0.98, "★★ 正中那一列也回来了（alpha %.2f）" % old_col.modulate.a)


## 动效总开关关掉时：**一帧**就该到位（与 fill_button / 徽记同一条口径）。
func _test_instant_when_animations_off(menu, chrome) -> void:
	var cfg = menu.cfg
	var engine = chrome.expand_engine()
	var side: Control = chrome.right_side_panel()
	var host: Vector2 = chrome.size
	var margin: float = cfg.num("menu.chrome.expanded_margin", 24.0)
	var side_btns: Array = chrome.side_buttons()
	if side_btns.is_empty():
		return

	ThemeRes.set_animations_enabled(false)

	await _click_at((side_btns[side_btns.size() - 1] as Control).get_global_rect().get_center())
	ok(engine.is_expanded(), "★★ 关掉动效 → **一帧内**就到展开态（不播过渡）")
	v2_near(side.get_global_rect().size, host - Vector2(margin * 2.0, margin * 2.0), 2.0,
		"★ 终态尺寸与走动画那条路一致")
	v2_near(side.get_global_rect().position, Vector2(margin, margin), 2.0, "★ 位置也一致")

	var panel = engine.secondary_panel()
	ok(panel != null, "★ 空面板照样挂上了（关动效 ≠ 不做事）")
	var back: Button = panel.back_button() if panel != null else null
	if back != null:
		await _click_at(back.get_global_rect().get_center())
	ok(not engine.is_expanded(), "★★ 收回也是**一帧到位**")
	ok(side.modulate.a > 0.98, "★ 右下那一块也立刻回来了")

	ThemeRes.set_animations_enabled(true)


## ★★ 入场 → 主界面的**两段动画**：
##   ① 徽记 / 标题 / 金线**落位**到主界面标题条里各自的位置（此时还在入场页）；
##   ② 落位之后才切页，并让主菜单的三块面板**从屏幕外滑入**。
func _test_intro_phases() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var menu = main.start_screen
	var chrome = menu.menu_chrome()
	ok(chrome != null, "（前提）外壳建出来了")
	if chrome == null:
		main.queue_free()
		return
	eq(int(menu.page()), 0, "（前提）新起的这一棵停在入场页")

	var intro_emblem: Control = menu.get_node_or_null("StartRoot/Intro/Emblem")
	var intro_title = menu.intro_title()
	var orn: Control = menu.menu_ornaments()
	ok(intro_emblem != null and intro_title != null and orn != null,
		"（前提）入场页那三块与主界面标题条都在")
	if intro_emblem == null or intro_title == null or orn == null:
		main.queue_free()
		return
	var dst_emblem: Control = orn.get_node_or_null("MenuEmblemWrap/MenuEmblem")
	var dst_word: Control = orn.get_node_or_null("MenuWordmark")
	ok(dst_emblem != null and dst_word != null, "（前提）主界面那一列里有对应的徽记与字标")
	if dst_emblem == null or dst_word == null:
		main.queue_free()
		return

	var sec: float = menu.cfg.num("menu.intro_morph_sec", 0.5)
	var slide_sec: float = menu.cfg.num("menu.chrome.intro_sec", 0.55)
	near(sec, 0.5, 0.0001, "menu.intro_morph_sec 读到了（落位时长）")
	near(slide_sec, 0.55, 0.0001, "menu.chrome.intro_sec 读到了（滑入时长）")

	var from_size: Vector2 = intro_emblem.size
	var from_font: int = int(intro_title.font_size)
	var dst_size: Vector2 = dst_emblem.size
	ok(from_size.x > dst_size.x + 1.0,
		"（前提）入场页那枚比主界面那枚大（%.0f → %.0f）" % [from_size.x, dst_size.x])

	ok(menu.dismiss_intro(), "点一下：这次点击受理了")

	# ---- ① 落位中：页面还是入场页，但三块已经在动 ----
	await _wait_sec(sec * 0.45)
	eq(int(menu.page()), 0, "★★ 落位动画跑完之前**还在入场页**（主菜单还没滑入）")
	var mid_size: Vector2 = intro_emblem.size
	ok(mid_size.x < from_size.x - 1.0 and mid_size.x > dst_size.x - 1.0,
		"★★ 徽记正在缩向目标尺寸（%.0f → %.0f → %.0f）" % [from_size.x, mid_size.x, dst_size.x])
	ok(int(intro_title.font_size) < from_font,
		"★★ 标题的**字号**也在过渡（%d → %d）—— 不然只有外框在缩、字是「跳」的"
		% [from_font, int(intro_title.font_size)])

	# ---- ② 落位完成那一刻切页：此时量到的三块**已经落在主界面标题条的位置上** ----
	await _wait_page(menu, 1, false)
	eq(int(menu.page()), 1, "★★ 落位跑完 → 真的切到主界面了")
	# ★★ 三对**都要**断言，**包括那条只有 1px 高的金线**：
	#    上一版只断言了徽记的位置与标题的字号，于是「金线被守卫整条跳过、一动不动」
	#    这个 bug 从测试里溜过去了（用户先看到）。
	var intro_rule: Control = menu.get_node_or_null("StartRoot/Intro/TitleRule")
	var dst_rule: Control = orn.get_node_or_null("MenuRuleWrap/MenuRule")
	for pair in [[intro_emblem, dst_emblem, "徽记"], [intro_title, dst_word, "标题"],
			[intro_rule, dst_rule, "金线"]]:
		var src: Control = pair[0]
		var dst: Control = pair[1]
		ok(src != null and dst != null, "（前提）%s 在两边都存在" % pair[2])
		if src == null or dst == null:
			continue
		var dst_rect: Rect2 = dst.get_global_rect()
		v2_near(src.get_global_rect().position, dst_rect.position, 2.0,
			"★★ %s 落位后的**位置** = 主界面那一块（%s）" % [pair[2], str(dst_rect.position)])
		v2_near(src.get_global_rect().size, dst_rect.size, 2.0,
			"★★ %s 落位后的**尺寸** = 主界面那一块（%s）" % [pair[2], str(dst_rect.size)])
	near(float(intro_title.font_size), float(dst_word.font_size), 1.0,
		"★★ 标题的字号落到了主界面那一档（%d → %d）" % [from_font, int(intro_title.font_size)])
	# ★ 转速对齐：入场页那枚从入场起一直在转，主界面那枚若从 0 开始，切页会「跳」一个角度
	near(dst_emblem.arc_angle(), intro_emblem.arc_angle(), 0.05,
		"★★ 切页时把转速接过去了（角度差 %.3f rad）"
		% absf(dst_emblem.arc_angle() - intro_emblem.arc_angle()))

	# ---- ③ 滑入：刚切页那一刻三块还在屏幕外，之后滑回原位 ----
	var nav: Control = chrome.left_nav_panel()
	var side: Control = chrome.right_side_panel()
	ok(chrome.expand_engine().is_busy(), "★★ 刚切页时外壳正在**滑入**（引擎在跑）")
	var nav_now: Rect2 = nav.get_global_rect()
	ok(nav_now.position.x < 0.0 or nav.modulate.a < 0.99,
		"★★ 那一刻左导航还在**屏幕外 / 半透明**（它是「滑」进来的，不是直接出现）")
	await _wait_sec(slide_sec + SETTLE_PAD_SEC)
	nav_now = nav.get_global_rect()
	ok(nav_now.position.x > 0.0 and nav_now.size.x > 1.0,
		"★★ 滑入结束：左导航回到屏幕左边（x %.0f）" % nav_now.position.x)
	ok(nav.modulate.a > 0.98, "★ 它不透明了")
	ok(side.modulate.a > 0.98, "★ 右下那一块也归位了")
	ok(side.get_global_rect().position.x > 0.0, "★ 而且回到屏幕内（不是停在屏外）")
	ok(not chrome.expand_engine().is_busy(), "★ 滑入跑完引擎不忙 —— 不会挡着接下来的点击")

	main.queue_free()
	await process_frame


## ★★ 回归：**点过的按钮在返回之后不该还留着那片填充金**（用户报的 bug）。
##
## 场景还原：点一颗侧边栏按钮 → 面板撑开（这期间外壳把它那一批按钮的 `mouse_filter`
## 压成 IGNORE，见 view/panel_expand.gd 的让路逻辑）→ 鼠标挪到右上角去点「返回」→ 收回。
##
## 为什么以前会卡住：吃不到鼠标就收不到 `mouse_exited` ⇒ 那颗被点过的按钮的 `_hovered`
## 一直是 true；收回时把过滤器还原成 STOP 之后**没有人补发 enter/exit**，于是那片金又填回来了。
## 修法在 `view/fill_button.gd` 的 `_sync_hover_filter()`。
func _test_fill_cleared_after_reverse(menu, chrome) -> void:
	var btns: Array = chrome.nav_buttons()
	if btns.is_empty():
		return
	var b: Button = btns[0]
	var sec: float = menu.cfg.num("menu.chrome.transition_sec", 0.45)

	# ① 鼠标**移到**这颗按钮上 —— 必须走 motion 事件：只推按下 / 抬起不会有 hover，
	#    也就不会填（填充动效认的是 `mouse_entered`）。
	await _move_mouse(b.get_global_rect().get_center())
	await _wait_sec(0.3)
	ok(FillButtonRes.fill_progress(b) > 0.9,
		"（前提）鼠标停上去之后它填满了（%.2f）" % FillButtonRes.fill_progress(b))

	# ② 点它：面板撑开（撑开期间外壳会把这一批按钮的 mouse_filter 压成 IGNORE）
	await _click_at(b.get_global_rect().get_center())
	await _wait_sec(sec + SETTLE_PAD_SEC)
	var panel = chrome.expand_engine().secondary_panel()
	var back: Button = panel.back_button() if panel != null else null
	if back == null:
		ok(false, "（前提）撑开之后应该有「返回」")
		return

	# ③ 鼠标挪到右上角（已经离那颗按钮很远）再点「返回」—— 真实操作就是这样
	await _click_at(back.get_global_rect().get_center())
	await _wait_sec(sec + 0.8)

	ok(FillButtonRes.fill_progress(b) < 0.05,
		"★★ 返回之后那颗按钮**不该还留着填充金**（%.2f）—— 鼠标早就挪开了，"
		% FillButtonRes.fill_progress(b)
		+ "它却吃不到 `mouse_exited`，卡在悬停态")
	eq(FillButtonRes.fill_progress(b), 0.0, "★ 而且最终是完全空的（不是残留一点点）")


## ★★ 「战役」那颗按钮撑开的面板里，装的是**从主界面正中那一列搬过来的三个测试入口**
##   （地图选择条 + test + campaign_test，见 view/battle_entries.gd）；
##   其余各块（资料 / 侧边栏五键 / 演义 / 合作模式）撑开的仍然是**空面板**。
func _test_battle_entries_in_panel(menu, chrome) -> void:
	var engine = chrome.expand_engine()
	var sec: float = menu.cfg.num("menu.chrome.transition_sec", 0.45)

	# ① 没展开时：主界面上**没有**这些控件了（它们已经不在那一列里）
	ok(menu.battle_entries() == null, "（前提）没展开面板时拿不到那些入口")
	ok(menu.get_node_or_null("StartRoot/MainMenu/MenuPad/MenuOuter/MenuColumn") == null,
		"★★ 主界面那一列里**不再有** MenuColumn（地图选择条与那两颗按钮已搬走）")

	# ② 展开「战役」（右下上排第一颗）
	var side: Array = chrome.side_buttons()
	if side.is_empty():
		return
	await _click_at((side[0] as Control).get_global_rect().get_center())
	await _wait_sec(sec + SETTLE_PAD_SEC)
	var entries = menu.battle_entries()
	ok(entries != null, "★★ 「战役」面板里挂上了那三个测试入口（view/battle_entries.gd）")
	if entries == null:
		return
	ok(entries.test_button() != null, "★ 里面有 test 按钮")
	ok(entries.campaign_test_button() != null, "★ 里面有 campaign_test 按钮")
	ok(entries.map_select_button() != null, "★ 里面有地图选择条")
	ok(entries.map_options().size() > 0,
		"★ 选择条的选项还是**扫目录**扫出来的（%d 张）" % entries.map_options().size())
	ok(engine.expanded_panel() != null and engine.expanded_panel().is_ancestor_of(entries),
		"★★ 它确实挂在**撑开的那块面板**里（不是浮在别处）")
	ok(entries.test_pressed.get_connections().size() >= 1,
		"★ test 的信号接上了（面板 → 外壳 → 开场页 → main.gd）")
	ok(entries.campaign_test_pressed.get_connections().size() >= 1, "★ campaign_test 的信号也接上了")

	# ③ 收起 → 拿不到了；再展开一颗侧边栏按钮 → 那块是空面板
	await _click_at(engine.secondary_panel().back_button().get_global_rect().get_center())
	await _wait_sec(sec + SETTLE_PAD_SEC)
	ok(menu.battle_entries() == null, "★ 收起之后拿不到了（面板连同内容一起销毁）")
	var nav: Array = chrome.nav_buttons()
	if nav.is_empty():
		return
	await _click_at((nav[0] as Control).get_global_rect().get_center())
	await _wait_sec(sec + SETTLE_PAD_SEC)
	var p = engine.secondary_panel()
	ok(p != null, "（前提）侧边栏那一次也撑开了面板")
	if p != null:
		ok(p.entries() == null, "★★ 侧边栏那几块撑开的仍然是**空面板**（只有一颗「返回」）")
		await _click_at(p.back_button().get_global_rect().get_center())
		await _wait_sec(sec + SETTLE_PAD_SEC)
	ok(menu.battle_entries() == null, "★ 再收起，仍然没有入口（它们只属于「战役」那一块）")


# ------------------------------------------------------------------
# 脚手架
# ------------------------------------------------------------------

## 起一个主场景（停在入场页）。★ 多等两帧：外壳的转场引擎要等 layout 稳定才抄初始状态
## （见 view/panel_expand.gd 的 attach()）。
func _spawn_main() -> Node:
	var packed = load("res://view/main.tscn")
	ok(packed != null, "能载入 main.tscn")
	if packed == null:
		return null
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	return main


## 起一个主场景并**等它真的切到主界面**（外壳只在那一页上）。
## ⚠️ `dismiss_intro()` 现在只是「受理了」—— 切页发生在落位动画之后（见 start_screen.gd），
##   所以这里必须等页面就位并等外壳滑入跑完，否则后面量到的是「正在动」的中间态。
func _spawn_menu() -> Node:
	var main = await _spawn_main()
	if main == null:
		return null
	main.start_screen.dismiss_intro()
	await _wait_page(main.start_screen, 1)
	return main


## 等某一页真正就位。
## @param settle_slide 是否再把外壳的滑入动画等完（要抓「刚切页那一刻」时传 false）
func _wait_page(menu, want: int, settle_slide: bool = true) -> void:
	var deadline: int = Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline and int(menu.page()) != want:
		await process_frame
	if settle_slide:
		await _wait_sec(menu.cfg.num("menu.chrome.intro_sec", 0.55) + SETTLE_PAD_SEC)


## 等够 `sec` 秒（按**真实时间**轮询）—— 转场是时间驱动的 Tween，等固定帧数在不同机器上不等价。
func _wait_sec(sec: float) -> void:
	var deadline: int = Time.get_ticks_msec() + int(maxf(0.0, sec) * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


## 在屏幕坐标处点一下（走引擎自己的输入派发，与玩家真点一样）。
func _click_at(pos: Vector2) -> void:
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = pos
	root.push_input(down, true)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = pos
	root.push_input(up, true)
	await process_frame
	await process_frame


## 把鼠标挪到某个屏幕位置（走引擎自己的输入派发 ⇒ 该来的 `mouse_entered/exited` 都会来）。
func _move_mouse(pos: Vector2) -> void:
	var mm := InputEventMouseMotion.new()
	mm.position = pos
	mm.global_position = pos
	root.push_input(mm, true)
	await process_frame
	await process_frame


func _overlap(a: Rect2, b: Rect2) -> bool:
	return a.intersects(b)


func _as_array(v: Variant) -> Array:
	return v if typeof(v) == TYPE_ARRAY else []


## 去掉换行（侧边栏的文字是竖排的，比对文案时要先摊平）。
func _flat(s: String) -> String:
	return s.replace("\n", "")


func _finish() -> void:
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)
