## bench_ai_shot.gd —— 合作 AI 队友局的一张观感图（人工看面板 / 标记用；不进测试套件）。
extends SceneTree

const GameSceneRes = preload("res://view/game_scene3d.gd")
const CampaignRes = preload("res://logic/campaign.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const LEVEL_ID := "02_twin_line"
const OUT_DIR := "res://shots"


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var cfg = load("res://logic/config.gd").load_default()
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var level = camp.level(LEVEL_ID) if camp != null else null
	if level == null:
		printerr("[SHOT] no level")
		quit(1)
		return
	var game = GameSceneRes.new()
	game.name = "AiShotGame"
	root.add_child(game)
	if not game.start_coop_solo(level, {"difficulty": "normal"}):
		printerr("[SHOT] start_coop_solo failed")
		quit(1)
		return
	await _wait(40)
	# 给 AI 一条行军指令：看面板状态 + 地图目标环
	game.world.set_ai_directive("F2", "march", 10.5, 10.5, "F1")
	if game.hud != null and game.hud.ai_panel != null:
		game.hud.ai_panel.sync()
		game.hud.ai_panel.set_pick_mode("march")
	await _wait(30)
	var img: Image = root.get_texture().get_image()
	if img == null:
		printerr("[SHOT] no image (headless?)")
		quit(1)
		return
	var path := "%s/ai_panel.png" % OUT_DIR
	print("[SHOT] ", ProjectSettings.globalize_path(path), " err=", img.save_png(path))
	quit(0)


func _wait(frames: int) -> void:
	for i in frames:
		await process_frame
