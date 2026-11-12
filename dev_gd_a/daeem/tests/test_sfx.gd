## test_sfx.gd —— 音效资源保留回归：只检查依赖仍可加载，不触发播放。
extends "res://tests/test_case.gd"

const SfxRes = preload("res://view/sfx.gd")


func _initialize() -> void:
	_case_name = "sfx_assets"
	run_all(_cases)


func _cases() -> void:
	_test_streams_loaded()


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
		eq(pool.size(), int(pair[1]), "%s音素材保留且能载入" % label)
		for stream in pool:
			_check_audio(stream, "%s音" % label)


func _check_audio(stream, what: String) -> void:
	ok(stream is AudioStreamWAV, "%s 是 AudioStreamWAV" % what)
	if stream is AudioStreamWAV:
		var sec: float = (stream as AudioStreamWAV).get_length()
		ok(sec > 0.05, "%s 仍是有效音频（时长 %.3fs）" % [what, sec])
