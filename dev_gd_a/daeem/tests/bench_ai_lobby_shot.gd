## bench_ai_lobby_shot.gd —— 合作大厅 AI 模式的一张观感图（人工检查用；不进测试套件）。
extends SceneTree

const CoopLobbyRes = preload("res://view/coop_lobby.gd")
const OUT_DIR := "res://shots"

func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	_run()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	RenderingServer.set_default_clear_color(Color(0.08, 0.09, 0.1))
	var cfg = load("res://logic/config.gd").load_default()
	var lobby = CoopLobbyRes.new()
	root.add_child(lobby)
	lobby.setup(cfg, null)
	lobby._set_ai_mode(true)
	await _wait(30)
	var img: Image = root.get_texture().get_image()
	if img == null:
		printerr("[SHOT] no image")
		quit(1)
		return
	var path := "%s/ai_lobby.png" % OUT_DIR
	print("[SHOT] ", ProjectSettings.globalize_path(path), " err=", img.save_png(path))
	quit(0)

func _wait(frames: int) -> void:
	for i in frames:
		await process_frame
