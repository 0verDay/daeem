extends SceneTree
const MainScene := preload("res://view/main.tscn")
func _initialize():
    _run()
func _run():
    var main = MainScene.instantiate()
    root.add_child(main)
    await process_frame
    await process_frame
    var screen = main.start_screen
    screen.dismiss_intro()
    var deadline = Time.get_ticks_msec() + 8000
    while Time.get_ticks_msec() < deadline and int(screen.page()) != 1:
        await process_frame
    await process_frame
    screen.menu_deck().goto_prepare()
    deadline = Time.get_ticks_msec() + 8000
    while Time.get_ticks_msec() < deadline and screen.menu_deck().current_page() != "prepare":
        await process_frame
    await process_frame
    await process_frame
    var pp = screen.prepare_panel()
    var r = pp.roster()
    print("panel1 size=", pp.panels()[1].size, " roster size=", r.size)
    print("content size=", r.get_node("_content").size, " vbox size=", r.get_node("_vbox").size)
    print("vbox min=", r.get_node("_vbox").get_combined_minimum_size())
    print("max_scroll=", r.max_scroll(), " gen=", r.general_buttons().size(), " unit=", r.unit_buttons().size(), " tech=", r.tech_buttons().size())
    print("headers=", r.section_headers().size(), " item0 size=", r.general_buttons()[0].size, " item0 min=", r.general_buttons()[0].get_combined_minimum_size())
    print("section0 min=", r.get_node("_vbox").get_child(0).get_combined_minimum_size())
    quit(0)
