## test_sfx.gd —— 音效模块（view/sfx.gd）：菜单按下 / 菜单悬停 / 建造
##
## 盯这些事：
##   1. 所有档位（down / hover / build / 攻击 4 档 / recruit）素材都能载入，
##      且都是**有效音频**（时长 > 0）—— 能抓到「导入缓存还是旧内容 / 文件坏了」；
##   2. `attach()` 幂等（fill_button 与控件自己各挂一次也只播一声）；
##   3. 只有菜单子树里的按钮会出声（HUD 按钮挂上也是静的）；
##   4. 按下接 `button_down`（按下去就响，不等松手）；禁用 / 无悬停平台不响；
##   5. fill_button 的按钮悬停音复用动画器那条 `mouse_entered`（不多连一条）；
##   6. 没有 `pressed` 信号的普通控件挂上去不报错；
##   7. 音量档位：点击高于悬停（素材本身 hover 更响，靠这里的 dB 拉回来）；
##   8. 攻击 / 受击四档各自有 0.2 秒闸门；招募不节流（一批只由调用方播一次）。
extends "res://tests/test_case.gd"

const SfxRes = preload("res://view/sfx.gd")
const ThemeRes = preload("res://view/theme.gd")
const FillButtonRes = preload("res://view/fill_button.gd")


func _initialize() -> void:
	_case_name = "sfx"
	run_all(_cases)


func _cases() -> void:
	_test_streams_loaded()
	_test_random_pick_covers_pool()
	_test_attach_and_menu_gate()
	_test_fill_button_hover_path()
	_test_disabled_and_hover_off()
	_test_attach_without_pressed_signal()
	_test_build_and_recruit_sound()
	_test_combat_throttle()
	_test_volume_levels()


func _test_streams_loaded() -> void:
	SfxRes._ensure_streams()
	var expected := {
		"点击": [SfxRes._click, 1],
		"悬停": [SfxRes._hover, 1],
		"建造": [SfxRes._build, 1],
		"远程攻击": [SfxRes._bow_attack, 2],
		"远程受击": [SfxRes._bow_hit, 3],
		"近战攻击": [SfxRes._sword_attack, 3],
		"近战受击": [SfxRes._sword_hit, 3],
		"招募": [SfxRes._recruit, 2],
	}
	for label in expected.keys():
		var pair: Array = expected[label]
		var pool: Array = pair[0]
		eq(pool.size(), int(pair[1]), "%s音 %d 段都能载入" % [label, int(pair[1])])
		for s in pool:
			_check_audio(s, "%s音" % label)


## ★ 用户要求「同一音效随机播其多段素材」：验一个多段池确实每段都会被挑到。
func _test_random_pick_covers_pool() -> void:
	var seen: Dictionary = {}
	for _i in 300:
		var s = SfxRes._pick(SfxRes._sword_hit)
		if s != null:
			seen[s.get_instance_id()] = true
	eq(seen.size(), SfxRes._sword_hit.size(), "★ 近战受击三段素材都会被随机挑到")


## ★ 素材换过同名文件 / 导入缓存过期时，这一项会掉。
func _check_audio(s, what: String) -> void:
	ok(s is AudioStreamWAV, "%s 是 AudioStreamWAV" % what)
	if not (s is AudioStreamWAV):
		return
	var sec: float = (s as AudioStreamWAV).get_length()
	ok(sec > 0.05, "%s 是有效音频（时长 %.3fs）" % [what, sec])


func _test_attach_and_menu_gate() -> void:
	ThemeRes.set_hover_enabled(true)
	var holder := Control.new()
	holder.name = "MenuHolder"
	root.add_child(holder)
	var b := Button.new()
	b.name = "MenuButton"
	holder.add_child(b)

	SfxRes.attach(b)
	SfxRes.attach(b)
	ok(b.has_meta(SfxRes.META), "attach() 记下了「已挂接」标记")

	var c0 := SfxRes.click_play_count
	var h0 := SfxRes.hover_play_count
	b.button_down.emit()
	b.mouse_entered.emit()
	eq(SfxRes.click_play_count, c0, "★ 非菜单按钮：按下不出声")
	eq(SfxRes.hover_play_count, h0, "★ 非菜单按钮：悬停不出声")

	SfxRes.mark_menu(holder)
	ok(SfxRes.in_menu(b), "标记父节点后，子按钮被认成菜单按钮")
	b.button_down.emit()
	eq(SfxRes.click_play_count, c0 + 1, "★ 菜单按钮按下播一声（重复 attach 不会播两声）")
	b.mouse_entered.emit()
	eq(SfxRes.hover_play_count, h0 + 1, "★ 菜单按钮悬停播一声")

	holder.queue_free()


## ★ 绝大多数菜单按钮走 fill_button：悬停音由**已有的** mouse_entered 回调带出来，
##   不能因此给宿主多连一条（test_fill_button 钉着「mouse_entered 只连一次」）。
func _test_fill_button_hover_path() -> void:
	ThemeRes.set_hover_enabled(true)
	var holder := Control.new()
	root.add_child(holder)
	SfxRes.mark_menu(holder)
	var b := Button.new()
	holder.add_child(b)
	FillButtonRes.attach_text(b)
	eq(b.mouse_entered.get_connections().size(), 1,
		"★ fill_button 的按钮：mouse_entered 仍然只连一次（悬停音复用动画器那条）")
	var h0 := SfxRes.hover_play_count
	b.mouse_entered.emit()
	eq(SfxRes.hover_play_count, h0 + 1, "★ fill_button 的菜单按钮悬停也会出声")
	holder.queue_free()


func _test_disabled_and_hover_off() -> void:
	var holder := Control.new()
	root.add_child(holder)
	SfxRes.mark_menu(holder)
	var b := Button.new()
	holder.add_child(b)
	SfxRes.attach(b)

	var c0 := SfxRes.click_play_count
	var h0 := SfxRes.hover_play_count
	b.disabled = true
	b.button_down.emit()
	b.mouse_entered.emit()
	eq(SfxRes.click_play_count, c0, "★ 禁用按钮不出声（即使手动 emit）")
	eq(SfxRes.hover_play_count, h0, "★ 禁用按钮悬停也不出声")

	b.disabled = false
	ThemeRes.set_hover_enabled(false)
	b.mouse_entered.emit()
	eq(SfxRes.hover_play_count, h0, "★ 没有悬停的平台（触屏）不播悬停音")
	ThemeRes.set_hover_enabled(true)
	b.mouse_entered.emit()
	eq(SfxRes.hover_play_count, h0 + 1, "★ 恢复悬停后正常播（证明上一条不是漏挂）")

	holder.queue_free()


func _test_attach_without_pressed_signal() -> void:
	var c := Control.new()
	SfxRes.attach(c)
	ok(not c.has_meta(SfxRes.META), "没有 pressed 信号的控件不会被挂接")
	c.queue_free()


func _test_build_and_recruit_sound() -> void:
	var b0 := SfxRes.build_play_count
	SfxRes.play_build()
	eq(SfxRes.build_play_count, b0 + 1, "★ play_build() 播一声并计数")

	var r0 := SfxRes.recruit_play_count
	SfxRes.play_recruit()
	SfxRes.play_recruit()
	eq(SfxRes.recruit_play_count, r0 + 2, "★ 招募不节流（一批只由调用方控制播一次）")


## ★★ 用户拍板：攻击 / 受击同一档 0.2 秒最多一声；不同档互不影响。
func _test_combat_throttle() -> void:
	SfxRes._combat_last_ms.clear()
	var bow0 := SfxRes.bow_attack_play_count
	SfxRes.play_bow_attack()
	SfxRes.play_bow_attack()
	eq(SfxRes.bow_attack_play_count, bow0 + 1, "★ 同一档 0.2s 内只响一声（远程攻击）")

	var sw0 := SfxRes.sword_attack_play_count
	SfxRes.play_sword_attack()
	eq(SfxRes.sword_attack_play_count, sw0 + 1, "★ 另一档不受影响（近战攻击）")

	SfxRes._combat_last_ms.clear()
	SfxRes.play_bow_attack()
	eq(SfxRes.bow_attack_play_count, bow0 + 2, "★ 清掉闸门后同一档可以再响")


## ★ 素材本身 hover（峰值 0.345）比 down（0.154）响；音量档必须把这个关系翻过来。
func _test_volume_levels() -> void:
	ok(SfxRes.click_db() > SfxRes.hover_db(),
		"★ 点击音量高于悬停（点击 %.1fdB / 悬停 %.1fdB）" % [
			SfxRes.click_db(), SfxRes.hover_db()])
