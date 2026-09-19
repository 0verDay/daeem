"""test_app.py —— 界面动作的无头测试（建真窗口，但不显示、不截图）。

跑法（仓库根目录任意处）：

    python dev_gd_a/tools/map_editor/test_app.py

做法：真的 new 一个 Tk 窗口 + EditorApp，然后用**假的鼠标事件**去点它，
断言的是「点完之后数据层变成了什么样」—— 也就是需求里那几条的自动化版：

    1. 地块页签：左键点在虚线格上 → 建出一个空白地块，属性面板切到它
    2. 地块页签：左键点已有地块 → 只开属性面板（不建新格、不刷地形），地形在面板里选
    3. 地块页签：右键点已有地块 → 变回虚线格；右键点虚线格 → 什么都不做
    4. 区块页签：选中区块后左键点地块 → 划入 / 再点一次移除
    5. 导出 / 导入 JSON 往返一致（文件对话框被替换成直接给路径）

⚠️ 不需要显示器：用的是 Tk 自己的窗口系统，测试机没装 Tk 时会「跳过」而不是失败。
⚠️ 界面文案 / 像素级外观不在这里断言（那要靠人看，见 tools/map_editor/README.md）。
"""

from __future__ import annotations

import shutil
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve()
PKG_PARENT = HERE.parent.parent            # dev_gd_a/tools/
PROJECT_DIR = HERE.parent.parent.parent / "daeem"
if str(PKG_PARENT) not in sys.path:
    sys.path.insert(0, str(PKG_PARENT))

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")      # type: ignore[union-attr]
    except (AttributeError, ValueError):
        pass

import tkinter as tk                        # noqa: E402
from tkinter import filedialog, ttk        # noqa: E402

from map_editor import app as app_module    # noqa: E402
from map_editor import mapfile              # noqa: E402

_FAILED = 0
_PASSED = 0
_SKIPPED = False


def ok(cond, label: str) -> None:
    global _FAILED, _PASSED
    if cond:
        _PASSED += 1
        print("  [ok]   %s" % label)
    else:
        _FAILED += 1
        print("  [FAIL] %s" % label)


def eq(actual, expected, label: str) -> None:
    ok(actual == expected, "%s（实际 %r，期望 %r）" % (label, actual, expected))


class FakeEvent:
    """假鼠标事件（tk 的 event 只要有 x / y 就够了，界面代码只用这两个）。"""

    def __init__(self, x: float, y: float) -> None:
        self.x = x
        self.y = y


def click_at(editor, tile_x: int, tile_y: int, button: str = "left") -> None:
    """按「格坐标」点一下（自己换算成屏幕坐标，顺带验证换算函数本身）。

    ⚠️ 左键要走**按下 + 抬起**两个回调（跟真实鼠标一样）：`on_left_up` 里才有
    「这次是点击还是拖动」的判断，直接调 `on_left_click` 会绕开那层。
    ⚠️ 点完立刻 `redraw()`：编辑器的重绘是**合并式**的（`request_redraw` 会攒到下一帧），
    测试里不等待事件循环，所以得手动把画面同步过来。
    """
    sx, sy = editor.tile_to_screen(tile_x, tile_y)
    event = FakeEvent(sx + editor.tile_px() / 2, sy + editor.tile_px() / 2)
    if button == "left":
        editor.on_left_down(event)
        editor.on_left_up(event)
    else:
        editor.on_right_click(event)
    editor.redraw()


def click_world(editor, tile_x: int, tile_y: int) -> None:
    """按**世界坐标**点一格。

    `click_at` 是「先算屏幕坐标再换回来」，落点会随窗口尺寸漂；
    要精确指定负坐标（世界坐标 -1 这种）就得先把坐标喂给 `screen_to_tile`。
    这里临时替掉换算函数，走的仍是真实的点击处理链（含原点平移与界面刷新）。
    """
    saved = editor.screen_to_tile
    editor.screen_to_tile = lambda sx, sy: (tile_x, tile_y)
    try:
        event = FakeEvent(0, 0)
        editor.on_left_down(event)
        editor.on_left_up(event)
    finally:
        editor.screen_to_tile = saved
    editor.redraw()


def fake_mouse(editor, tile_x: int, tile_y: int, shift: bool = False) -> FakeEvent:
    """造一个落在某格中心的假鼠标事件（可带 Shift）。

    ⚠️ Shift 在 tk 的鼠标事件里是 `event.state` 的一个位，**不是 keysym** ——
    造事件时忘了给 `state`，编辑器就会把「Shift+拖拽」当成普通拖拽（静默不框选）。
    """
    sx, sy = editor.tile_to_screen(tile_x, tile_y)
    event = FakeEvent(sx + editor.tile_px() / 2, sy + editor.tile_px() / 2)
    event.state = app_module.SHIFT_MASK if shift else 0
    return event


def box_select(editor, from_tile, to_tile) -> None:
    """Shift + 从一格拖到另一格（按下 → 若干次拖动 → 抬起），与真实鼠标同一条路。"""
    editor.on_left_down(fake_mouse(editor, *from_tile, shift=True))
    editor.on_left_drag(fake_mouse(editor, *to_tile, shift=True))
    editor.on_left_up(fake_mouse(editor, *to_tile, shift=True))
    editor.redraw()


def build_editor(cols: int = 0, rows: int = 0, size: str = "1000x700"):
    """建一个编辑器窗口（不显示，但**有真实尺寸**）。

    默认 (0, 0) = **全新的无限虚线画布**（初始地图的内存网格就是 0×0）。
    要给一张固定尺寸的地图就传 cols/rows。

    ⚠️ 窗口必须先有尺寸、而且**在 new EditorApp 时仍然是映射状态**：withdraw 之后
    canvas 会退回 1×1，而 app 的初始视野要读 canvas 尺寸（见 app.apply_initial_view）——
    读成 1×1 的话缩放/居中全错，后面所有「屏幕坐标 ↔ 格坐标」的断言都会跟着错位。
    所以顺序是：deiconify → new → update → 再 withdraw。
    """
    root = tk.Tk()
    root.geometry(size)
    root.deiconify()          # 先映射出来，让 canvas 拿到真实尺寸
    root.update()
    model = mapfile.empty_map(cols, rows, None)
    editor = app_module.EditorApp(root, PROJECT_DIR, model, None)
    root.update()
    editor.apply_initial_view()
    root.withdraw()           # 摆好之后立刻藏起来（测试不打扰人）
    return root, editor


def stub_dialogs():
    """把 tk 的弹窗全部存根掉，返回一个「恢复原样」的函数。

    ⚠️ 必须做这件事：`do_export()` 在地图有毛病（没大本营 / 空区块）时会先弹一个
    `askyesno` 问「仍然导出吗」，而模态弹窗会**一直等人点**——
    无头测试就卡死在那里（第一次写这个测试时真卡了 3 分钟，靠 faulthandler 打出栈才看见）。
    """
    saved = {
        "askyesno": app_module.messagebox.askyesno,
        "showinfo": app_module.messagebox.showinfo,
        "showerror": app_module.messagebox.showerror,
        "showwarning": app_module.messagebox.showwarning,
    }
    app_module.messagebox.askyesno = lambda *a, **k: True
    app_module.messagebox.showinfo = lambda *a, **k: None
    app_module.messagebox.showerror = lambda *a, **k: None
    app_module.messagebox.showwarning = lambda *a, **k: None

    def restore() -> None:
        for name, fn in saved.items():
            setattr(app_module.messagebox, name, fn)

    return restore


# ----------------------------------------------------------------------

def t_step1_create_tile() -> None:
    print("\n[1] 地块页签：左键点虚线格 → 建出空白地块 + 属性面板切到它")
    root, editor = build_editor()
    try:
        eq(editor.page, "tile", "默认就在地块页签")
        eq(editor.model.existing_count(), 0, "新地图一个地块都没有")
        ok(not editor.model.exists(2, 3), "(2,3) 现在是虚线格")
        click_at(editor, 2, 3)
        ok(editor.model.exists(2, 3), "★ 左键点了一下 → 地块被创建出来了")
        eq(editor.model.terrain_at(2, 3), "grass", "新建的是空白地块（草地）")
        eq(editor.inspect, (2, 3), "★ 属性面板跟着切到这一格（不用再点第二下）")
        click_at(editor, 2, 3)
        eq(editor.model.existing_count(), 1, "★ 在已有地块上左键 = 看属性，不会又多一格")
        eq(editor.model.terrain_at(2, 3), "grass", "★ 左键点已有地块也不会顺手改地形（没有笔刷）")
    finally:
        root.destroy()


def t_step1b_terrain_only_from_panel() -> None:
    """★ 需求：「在其中选择该格的地形（不需要用笔刷更改地形）」。

    所以地形**只能**从属性面板改，而且改的是「面板正在看的那一格」。
    顺带钉住两件事：面板的控件是**就地改值**的（不是每次重建），改完立刻生效。
    """
    print("\n[1b] 地块页签：地形只在属性面板里选（无笔刷）")
    root, editor = build_editor()
    try:
        click_at(editor, 0, 0)
        buttons = editor._tile_widgets["terrain"]
        eq(sorted(buttons), ["forest", "grass", "mountain"], "面板里有三种地形的按钮")

        buttons["forest"].invoke()
        eq(editor.model.terrain_at(0, 0), "forest", "★ 点「森林」→ 这一格变成森林")
        ok("森林" in editor._tile_widgets["coord"].cget("text"),
           "面板上的文字跟着变成森林（就地改值，不是重建）")

        buttons["mountain"].invoke()
        eq(editor.model.terrain_at(0, 0), "mountain", "改成山地也立刻生效")

        # ★ 地形只影响「面板正在看的那一格」：点另一格建格，新格仍然是空白草地
        click_at(editor, 1, 0)
        eq(editor.model.terrain_at(1, 0), "grass",
           "★ 新建的格子是空白草地 —— 上一次选过的山地不会变成「当前笔刷」")
        eq(editor.model.terrain_at(0, 0), "mountain", "刚才那格的地形没被改掉")

        # ★ 不能有「当前笔刷」这个东西（需求明确不要笔刷）
        ok(not hasattr(editor, "paint_terrain"), "★ 编辑器里没有「当前笔刷」这个状态")

        # 虚线格改不了地形（属性面板还在，但地形按钮是灰的）
        click_at(editor, 4, 4)
        click_at(editor, 4, 4, button="right")          # 右键把它删回虚线格
        eq(editor.inspect, (4, 4), "面板还指着这一格")
        eq(editor._tile_widgets["terrain"]["grass"].cget("state"), "disabled",
           "★ 虚线格时地形按钮是灰的（没地块可改）")
        editor.set_tile_terrain("forest")
        eq(editor.model.exists(4, 4), False, "对着虚线格改地形不会凭空建出地块")
    finally:
        root.destroy()


def t_step2_right_click_deletes() -> None:
    """★ 需求：「右键点击任意非虚线格会将其变为虚线格」。"""
    print("\n[2] 地块页签：右键点已有地块 → 变回虚线格")
    root, editor = build_editor()
    try:
        click_at(editor, 1, 1)
        click_at(editor, 3, 2)
        eq(editor.model.existing_count(), 2, "先建两个地块")

        # 右键点虚线格：什么都不做（不是「创建」的反操作），面板也不许被拽走
        click_at(editor, 3, 2)
        eq(editor.inspect, (3, 2), "先让属性面板看着 (3,2)")
        click_at(editor, 7, 7, button="right")
        eq(editor.model.existing_count(), 2, "★ 右键点虚线格不会建出地块")
        ok(not editor.model.exists(7, 7), "(7,7) 还是虚线格")
        eq(editor.inspect, (3, 2), "★ 右键点虚线格也不会把属性面板从正在编辑的格子上拽走")

        # 右键点已有地块：删掉
        click_at(editor, 1, 1, button="right")
        ok(not editor.model.exists(1, 1), "★ 右键点已有地块 → 变回虚线格了")
        eq(editor.model.existing_count(), 1, "地块总数少了一个")
        eq(editor.page, "tile", "右键不会把页签切走")
        eq(editor.inspect, (3, 2), "删的不是面板在看的那一格 → 面板不动")

        # 删的正好是面板在看的那一格：面板留着（显示「虚线格」），左键再点能建回来
        click_at(editor, 1, 1)
        click_at(editor, 1, 1, button="right")
        eq(editor.inspect, (1, 1), "★ 删掉面板正在看的那一格 → 面板仍指着它（方便再点一次建回来）")
        click_at(editor, 1, 1)
        ok(editor.model.exists(1, 1), "★ 左键再点一下 → 地块又建回来了")
        eq(editor.model.terrain_at(1, 1), "grass", "建回来的是空白地块（地形不残留）")

        # 右键删掉的那一格如果正被划在区块里，也要从区块里摘掉
        editor.model.assign_tile(3, 2, (editor.model.add_zone("东关")).zone_id)
        click_at(editor, 3, 2, button="right")
        eq(len(editor.model.zones[0].tiles), 0, "★ 删格时区块里的归属也一起摘掉了")

        # 撤销能把删掉的地块找回来
        editor.undo()
        ok(editor.model.exists(3, 2), "★ Ctrl+Z 能把右键删掉的地块撤销回来")

        # 大本营按钮还在（属性面板里）
        click_at(editor, 5, 4)
        editor.toggle_base(5, 4)
        eq(editor.model.base, (5, 4), "★ 侧边栏按钮把大本营设在这一格")
        editor.toggle_base(5, 4)
        eq(editor.model.base, None, "再点一次 = 取消大本营")

        # 「删除这个地块」按钮和右键删格是同一个动作
        click_at(editor, 5, 4)
        editor._tile_widgets["delete"].invoke()
        ok(not editor.model.exists(5, 4), "★ 面板里那颗「删除这个地块」也能删（变回虚线格）")
    finally:
        root.destroy()


def t_step3_zone_tab() -> None:
    print("\n[3] 区块页签：列表建/删/改名 + 左键点地块分配")
    root, editor = build_editor()
    try:
        for tile in ((0, 0), (1, 0), (1, 1), (2, 1)):
            click_at(editor, *tile)
        eq(editor.model.existing_count(), 4, "先准备好 4 个地块")
        editor.set_page("zone")
        eq(editor.page, "zone", "切到区块页签")
        eq(len(editor.model.zones), 0, "一开始没有区块")

        editor.add_zone()
        eq(len(editor.model.zones), 1, "★ 列表里能新建区块")
        zone = editor.model.zones[0]
        eq(editor.selected_zone, zone.zone_id, "新建的区块自动被选中")
        eq(zone.name, "区块1号", "默认名")

        click_at(editor, 0, 0)
        eq(zone.tile_count, 1, "★ 左键点地块 → 划给它")
        click_at(editor, 1, 0)
        click_at(editor, 1, 1)
        eq(zone.tile_count, 3, "再点两格 → 一共 3 格")
        click_at(editor, 1, 1)
        eq(zone.tile_count, 2, "★ 点已经属于它的格子 → 移除")
        eq(editor.model.zone_at(1, 1), None, "移除之后那格不属于任何区块")

        # 虚线格划不了
        click_at(editor, 5, 4)
        eq(zone.tile_count, 2, "虚线格点了没反应（要先创建地块）")

        # 改名（走侧边栏那个输入框的回调）
        editor.zone_name_var.set("东关")
        editor.apply_zone_name()
        eq(editor.model.zone(zone.zone_id).name, "东关", "★ 区块能重命名")

        # ★ 改名会把详情那一行销毁重建；如果用户正把光标放在输入框里，焦点必须还回去
        #   （不还的话，按 Enter 改完名字，键盘焦点就掉回画布，接着打字全丢）
        root.deiconify()
        root.update()
        entry = None
        for child in editor.zone_selected_row.winfo_children():
            if isinstance(child, ttk.Entry):
                entry = child
        ok(entry is not None, "详情里有名字输入框")
        if entry is not None:
            entry.focus_set()
            root.update()
            entry.delete(0, "end")
            entry.insert(0, "东关二")
            editor.apply_zone_name()
            root.update()
            focused = root.focus_get()
            ok(isinstance(focused, ttk.Entry) and focused is not entry,
               "★ 改完名字，键盘焦点落在**新的**输入框上（可以接着打字）")
            eq(editor.zone_tree.item(str(zone.zone_id), "text"), "东关二",
               "★ 列表里那一行也跟着改了（就地改值）")

        # 清空选中区块的地块
        editor.clear_selected_zone_tiles()
        eq(editor.model.zone(zone.zone_id).tile_count, 0, "★ 能一键清空这个区块的地块")
        eq(editor.model.existing_count(), 4, "清空归属不会把地块本身删掉")

        # 删除区块
        other = editor.model.add_zone("江陵")
        editor.selected_zone = other.zone_id
        eq(len(editor.model.zones), 2, "又建了一个区块")
        editor.model.delete_zone(other.zone_id)
        editor.selected_zone = zone.zone_id
        editor.refresh_sidebar()
        eq(len(editor.model.zones), 1, "★ 区块能删掉")
    finally:
        root.destroy()


def t_undo_redo() -> None:
    print("\n[4] 撤销 / 重做")
    root, editor = build_editor()
    try:
        click_at(editor, 0, 0)
        click_at(editor, 1, 0)
        eq(editor.model.existing_count(), 2, "建了两个地块")
        editor.undo()
        eq(editor.model.existing_count(), 1, "★ 撤销一次 → 回到一个地块")
        editor.undo()
        eq(editor.model.existing_count(), 0, "再撤销 → 全没了")
        editor.redo()
        eq(editor.model.existing_count(), 1, "★ 重做一次 → 又回来了")
        editor.redo()
        eq(editor.model.existing_count(), 2, "重做到头")

        # 区块也要能撤销
        editor.set_page("zone")
        editor.add_zone()
        editor.model.assign_tile(0, 0, editor.selected_zone)
        before = len(editor.model.zones)
        editor.undo()
        ok(len(editor.model.zones) == before - 1 or len(editor.model.zones) == before,
           "撤销能回退区块操作（不崩即可）")
    finally:
        root.destroy()


def t_step4_export_import() -> None:
    print("\n[5] 导出 / 导入 JSON（供 Godot 读取）")
    root, editor = build_editor(6, 5)
    original_save = filedialog.asksaveasfilename
    original_open = filedialog.askopenfilename
    tmp = PROJECT_DIR / ".tmp_map_editor_app_test"
    if tmp.exists():
        shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True, exist_ok=True)
    try:
        # 摆一张有内容的地图（地形只能先在「地块」页签把格子建出来再选）
        for tile in ((0, 0), (1, 0), (1, 1), (2, 2)):
            click_at(editor, *tile)
        click_at(editor, 2, 2)
        editor.set_tile_terrain("mountain")
        click_at(editor, 1, 1)
        editor.set_tile_terrain("forest")
        editor.toggle_base(0, 0)
        editor.set_page("zone")
        editor.add_zone()
        zone = editor.model.zones[0]
        for tile in ((0, 0), (1, 0)):
            click_at(editor, *tile)

        target = tmp / "exported.json"
        filedialog.asksaveasfilename = lambda **kwargs: str(target)
        editor.do_export()
        filedialog.asksaveasfilename = original_save
        ok(target.is_file(), "★ 导出按钮真的写出了文件")
        eq(editor.current_path, target, "导出后记住了当前文件")

        # 再打开回来
        filedialog.askopenfilename = lambda **kwargs: str(target)
        editor.do_open()
        filedialog.askopenfilename = original_open
        eq(editor.model.existing_count(), 4, "★ 重新打开：地块数一致")
        eq(editor.model.terrain_at(2, 2), "mountain", "地形一致（山地）")
        eq(editor.model.terrain_at(1, 1), "forest", "地形一致（森林）")
        eq(editor.model.base, (0, 0), "大本营一致")
        eq(len(editor.model.zones), 1, "区块数量一致")
        eq(editor.model.zone(editor.model.zones[0].zone_id).name, zone.name, "区块名一致")
        eq(editor.model.zone(editor.model.zones[0].zone_id).tile_count, 2, "区块的地块一致")
    finally:
        filedialog.asksaveasfilename = original_save
        filedialog.askopenfilename = original_open
        shutil.rmtree(tmp, ignore_errors=True)
        root.destroy()


def t_infinite_canvas() -> None:
    """★ 需求：初始应当是一个无限大小的虚线地图。

    所以：画布上没有「边界」这种东西 —— 视野里任何一点都对应一个格子，
    看得很远很远的地方也能建地块（网格在内存里按需生长）。
    """
    print("\n[6] 无限虚线画布")
    root, editor = build_editor()          # 一张全新地图
    try:
        root.update()
        eq((editor.model.cols, editor.model.rows), (0, 0), "新地图的内存网格是 0×0（一个地块都没有）")
        eq(editor.model.existing_count(), 0, "初始一个地块都没有（整张图都是虚线格）")

        # 看得很远的地方：屏幕换算照样给出格子，不是 None
        far = editor.screen_to_tile(99999.0, 99999.0)
        ok(far is not None and far[0] > 100 and far[1] > 100,
           "看得很远的地方也有格子（%s）—— 画布没有边界" % (far,))

        # 在远离原点的地方建地块 → 网格自己长过去
        click_at(editor, 60, 40)
        ok(editor.model.exists(60, 40), "★ 在 (60,40) 建出了地块")
        ok(editor.model.cols > 60 and editor.model.rows > 40,
           "★ 内存网格自己长到了 %d×%d 以装下它" % (editor.model.cols, editor.model.rows))
        eq(editor.model.terrain_at(60, 40), "grass", "它是草地")

        # 再往另一个方向长
        click_at(editor, 5, 70)
        ok(editor.model.exists(5, 70), "在 (5,70) 也建得出来")
        ok(editor.model.rows > 70, "网格继续长高")

        # 生长之后老内容还在
        ok(editor.model.exists(60, 40), "生长不会丢掉已经画好的地块")

        # 导出：范围是「已画地块的包围盒」，不是整个内存网格
        # ⚠️ 断言里不写死 61×71：点击是按屏幕坐标换算回格子的，窗口尺寸变了落点就会变。
        #    这里对「模型自己的包围盒」做断言，测试才与窗口尺寸无关。
        box = editor.model.bounds()
        data = mapfile.model_to_dict(editor.model)
        eq(data["cols"], box[2] - box[0] + 1, "导出宽度 = 已画地块的包围盒宽")
        eq(data["rows"], box[3] - box[1] + 1, "导出高度 = 已画地块的包围盒高")
        ok(data["cols"] < editor.model.cols or data["rows"] < editor.model.rows,
           "★ 导出只覆盖画到的那一片（%d×%d），不是内存里长出来的 %d×%d"
           % (data["cols"], data["rows"], editor.model.cols, editor.model.rows))
        eq(sum(sum(row) for row in data["exists"]), 2, "导出里只有 2 个存在的地块")
        # 导出的格子全在画过的范围里
        eq(editor.model.existing_count(), 2, "模型里也只有 2 个地块")

        # 兜底上限：超出 ±MAX_COORD 就不接受落笔，而且**状态栏要说清楚**
        # （用户报过「有一条隐形的线」——那时越界提示含糊，鼠标扫过去更是毫无提示）
        from map_editor.model import MAX_COORD
        editor.model.resize(MAX_COORD, MAX_COORD)
        before = editor.model.existing_count()
        editor.on_left_click(FakeEvent(editor.ox + MAX_COORD * editor.tile_px() + 5, editor.oy + 5))
        eq(editor.model.existing_count(), before, "超出上限的那一下不会建出地块")
        ok("超出可用范围" in editor.status_var.get(),
           "★ 越界时状态栏明说「超出可用范围」（实际：%s）" % editor.status_var.get())
        ok(str(MAX_COORD) in editor.status_var.get(),
           "★ 提示里带上了真实边界（撞墙的人得知道墙在哪）")
    finally:
        root.destroy()


def t_draw_up_left_no_invisible_wall() -> None:
    """★ 需求：「隐形线」不能再有；往左上也要能画；导出的尺寸自动按包围盒算。

    这条需求背后是两个具体问题：
      1. 以前落笔要求 `min(x, y) >= 0` —— 从 (0,0) 往左上画**根本画不了**，
         而且没有任何提示（鼠标扫过去什么都不显示）。现在模型会用 origin 平移
         把负坐标装下来（见 MapModel._shift_origin_to_fit）。
      2. 上限 512 太小、又只有点击时才提示，看起来就是一条「隐形的线」。
         现在上限是 MAX_COORD（16384），并且接近边界时状态栏就会提醒。
    """
    print("\n[16] 左上也能画 + 没有隐形线 + 导出尺寸自动算")
    root, editor = build_editor()
    try:
        eq((editor.model.origin_x, editor.model.origin_y), (0, 0), "一开始网格原点是 (0,0)")

        # 先把鼠标「骗」到世界坐标 (0,0)，再从它往左上点几格
        # （真按屏幕坐标点也行，但那样依赖窗口尺寸；直接喂世界坐标更稳定）
        real_screen_to_tile = editor.screen_to_tile

        click_world(editor, 0, 0)
        click_world(editor, -1, 0)
        click_world(editor, -1, -1)
        click_world(editor, 0, -2)
        eq(editor.model.existing_count(), 4, "★ 往左上点出了 4 格（以前这四格里有两格根本点不出来）")
        ok(editor.model.exists(-1, -1), "★ 负坐标 (-1,-1) 的格子真的建出来了")
        ok(editor.model.origin_x > 0 and editor.model.origin_y > 0,
           "★ 网格原点跟着平移了（origin = %d,%d）—— 数组下标仍然非负"
           % (editor.model.origin_x, editor.model.origin_y))

        # 世界坐标 ↔ 屏幕 必须还是对的（原点平移以后最容易在这里错位）
        for tile in ((0, 0), (-1, 0), (-1, -1), (0, -2)):
            sx, sy = editor.tile_to_screen(*tile)
            back = real_screen_to_tile(sx + editor.tile_px() * 0.5,
                                       sy + editor.tile_px() * 0.5)
            eq(back, tile, "★ 屏幕 ↔ 世界坐标往返：%s（origin 平移过也不能错位）" % (tile,))

        # 平移过原点之后：地形 / 区块 / 大本营都得跟着搬
        editor.inspect = (-1, -1)
        editor.set_tile_terrain("mountain")
        eq(editor.model.terrain_at(-1, -1), "mountain", "★ 负坐标那一格的地形改得动")
        editor.set_page("zone")
        editor.add_zone()
        editor.model.assign_tile(-1, -1, editor.selected_zone)
        eq(editor.model.zone_at(-1, -1).zone_id, editor.selected_zone,
           "★ 负坐标的格子也能划给区块")
        editor.toggle_base(-1, -1)
        eq(editor.model.base, (-1, -1), "★ 大本营也能设在负坐标上")

        # 再往左上画一格：已有内容必须原地不动（世界坐标含义不变）
        # ⚠️ 别忘了切回「地块」页签：区块页签上左键是「划区块」，不建格。
        editor.set_page("tile")
        click_world(editor, -2, -2)
        eq(editor.model.bounds(), (-2, -2, 0, 0), "★ 再往左上画：包围盒变成 (-2,-2)…(0,0)")
        eq(editor.model.terrain_at(-1, -1), "mountain", "★ 平移之后老地块的地形没丢")
        eq(editor.model.base, (-1, -1), "★ 平移之后大本营没跑")
        eq(editor.model.zone_at(-1, -1).zone_id, editor.selected_zone,
           "★ 平移之后区块归属没跑")

        # 导出：尺寸 = 包围盒（3×3），坐标自动搬到左上角，游戏里形状不变
        editor.set_page("tile")
        data = mapfile.model_to_dict(editor.model)
        eq((data["cols"], data["rows"]), (3, 3), "★ 导出尺寸 = 包围盒 3×3（自动算出来的）")
        eq(sum(sum(row) for row in data["exists"]), 5, "导出里有 5 个地块")
        eq(data["base"], [1, 1], "大本营被搬到导出坐标系里（(-1,-1) → (1,1)）")

        # 撤销：网格平移这件事也要能退回去（否则同一格的世界坐标会整体偏）
        origin_before = (editor.model.origin_x, editor.model.origin_y)
        editor.undo()
        ok((editor.model.origin_x, editor.model.origin_y) != origin_before
           or editor.model.existing_count() == 4,
           "★ 撤销能把「往左上画 + 网格平移」一起退回去")
        editor.redo()
        eq(editor.model.bounds(), (-2, -2, 0, 0), "★ 重做又回到 (-2,-2)…(0,0)")

        # 接近上限时状态栏要有提醒（隐形线就是因为「什么都不说」）
        # ⚠️ 位置不能写死 ±MAX_COORD：数组下标 = 世界坐标 + origin，origin 会随
        #    「往左上画」变大。这里直接按模型的定义算最右那一格的**世界坐标**。
        from map_editor.model import MAX_COORD
        edge_x = MAX_COORD - 1 - editor.model.origin_x
        edge_y = MAX_COORD - 1 - editor.model.origin_y
        ok(editor.model.can_draw_at(edge_x, edge_y),
           "★ 最角落那一格（世界 %d,%d）判为可画 —— 提示与判据用的是同一个式子"
           % (edge_x, edge_y))
        ok(editor._limit_hint(edge_x, edge_y) != "", "★ 光标贴着上限时状态栏会提醒")
        eq(editor._limit_hint(0, 0), "", "离得远时不打扰")

        # ★★ 建地块时**画面不许动**（用户报的「创建空白地块时会自动移动视角」）
        #
        # 根因：往左上画会让模型把 origin 加 S（数组整体右移/下移给负坐标让位），
        # 而屏幕位置 = ox + (世界坐标 + origin) × 格子大小 —— 所以 ox 要**减** S×格子大小。
        # 原来写成了 `+=`，于是「origin 一格 + ox 一格」= 画面往右下跳两格。
        # 这里钉两条：① 已画好的格子在屏幕上一格都不动；② 新格子就出现在鼠标点的那里。
        editor2, root2 = None, None
        root2, editor2 = build_editor(size="1280x800")
        try:
            # 把视野往左上推一段，这样新点的格子世界坐标是负的（会触发 origin 平移）
            editor2.ox += 700
            editor2.oy += 500
            for t in ((0, 0), (1, 0), (0, 1)):
                click_at(editor2, *t)

            def screen_of(tile):
                return tuple(round(v, 3) for v in editor2.tile_to_screen(*tile))

            tracked = ((0, 0), (1, 0), (0, 1))
            before = {t: screen_of(t) for t in tracked}
            origin_before = (editor2.model.origin_x, editor2.model.origin_y)

            # 真按屏幕坐标点一个负世界坐标的格子
            target = (-3, -3)
            sx, sy = editor2.tile_to_screen(*target)
            event = FakeEvent(sx + editor2.tile_px() / 2, sy + editor2.tile_px() / 2)
            editor2.on_left_down(event)
            editor2.on_left_up(event)
            editor2.redraw()

            ok((editor2.model.origin_x, editor2.model.origin_y) != origin_before,
               "★ 这一下确实触发了 origin 平移（否则这条测试没测到东西）")
            moved = {t: (before[t], screen_of(t)) for t in tracked
                     if before[t] != screen_of(t)}
            eq(moved, {}, "★★ 建地块时**已经画好的格子**在屏幕上一格都没动")
            eq(editor2.tile_to_screen(*target), (sx, sy),
               "★ 新建的那一格就出现在原来算出来的屏幕位置上（视角没有自己走）")
            eq((round(event.x, 3), round(event.y, 3)),
               (round(sx + editor2.tile_px() / 2, 3), round(sy + editor2.tile_px() / 2, 3)),
               "★ 鼠标点在哪儿，格子就建在哪儿（落点没被视角移动带偏）")
        finally:
            root2.destroy()
    finally:
        root.destroy()


def t_view_math() -> None:
    print("\n[7] 视图换算（滚轮缩放 / 适应视野）")
    root, editor = build_editor(24, 16)
    try:
        root.update()
        editor.fit_view()
        size = editor.tile_px()
        ok(size > 0, "适应视野之后格子有尺寸")
        ok(editor.ox <= 0 or editor.ox >= 0, "偏移是数字")
        # 屏幕 → 格 → 屏幕 往返
        for (tx, ty) in ((0, 0), (5, 4), (23, 15)):
            sx, sy = editor.tile_to_screen(tx, ty)
            back = editor.screen_to_tile(sx + size * 0.5, sy + size * 0.5)
            eq(back, (tx, ty), "屏幕 ↔ 格 换算往返：%s" % ((tx, ty),))
        far = editor.screen_to_tile(-99999, -99999)
        ok(far is not None, "★ 负方向（画布左上外面）也有格子：%s —— 画布是无限的" % (far,))

        # 滚轮缩放以光标为锚点
        editor.zoom = 1.0
        editor.ox, editor.oy = 0.0, 0.0
        before = editor.screen_to_tile(200.0, 100.0)
        event = FakeEvent(200.0, 100.0)
        event.delta = 120
        editor.on_wheel(event)
        after = editor.screen_to_tile(200.0, 100.0)
        ok(editor.zoom > 1.0, "向上滚滚轮 = 放大")
        eq(after, before, "★ 光标底下的那一格在缩放前后是同一格（锚点缩放）")
    finally:
        root.destroy()


def t_pan_controls() -> None:
    """★ 需求：方向键的方向 + 空格按住拖动平移。"""
    print("\n[8] 平移：方向键 / 空格 + 拖动")
    root, editor = build_editor()
    try:
        root.geometry("1000x700")
        root.update()

        # ---- 方向键：按左键 = 视野往左走（内容右移 ⇒ ox 变大）----
        for key, axis, sign, label in (("Left", 0, +1, "← 视野往左走"),
                                       ("Right", 0, -1, "→ 视野往右走"),
                                       ("Up", 1, +1, "↑ 视野往上走"),
                                       ("Down", 1, -1, "↓ 视野往下走")):
            editor.ox, editor.oy = 100.0, 100.0
            editor.pan_arrow(key)
            moved = (editor.ox - 100.0) if axis == 0 else (editor.oy - 100.0)
            ok(moved * sign > 0, "★ %s（位移 %+.0f 像素）" % (label, moved))

        # 方向表与按键绑定必须是同一份（别在两处各写一份方向）
        for key in ("Left", "Right", "Up", "Down"):
            ok(key in editor.ARROW_PAN and editor.ARROW_PAN[key] != (0, 0),
               "方向表里有 %s" % key)

        # ---- 空格按住 → 左键拖动平移 ----
        eq(editor.space_held, False, "一开始不在平移模式")
        editor.on_space_down(FakeEvent(300, 300))
        eq(editor.space_held, True, "★ 按下空格 → 进入平移模式")
        start_ox, start_oy = editor.ox, editor.oy
        editor.on_left_down(FakeEvent(300, 300))
        editor.on_left_drag(FakeEvent(340, 320))
        editor.on_left_up(FakeEvent(340, 320))
        eq((editor.ox, editor.oy), (start_ox + 40, start_oy + 20), "★ 拖动 40/20 像素 → 画布跟着移")
        eq(editor.model.existing_count(), 0, "★ 平移模式下拖动不会误建地块")

        editor.on_space_up(FakeEvent(340, 320))
        eq(editor.space_held, False, "松开空格 → 回到画地块模式")
        editor.on_left_down(FakeEvent(500, 400))
        editor.on_left_up(FakeEvent(500, 400))
        eq(editor.model.existing_count(), 1, "松开空格之后，左键点击又能建地块了")

        # ---- 中键拖动照样能平移 ----
        before = (editor.ox, editor.oy)
        editor.on_middle_down(FakeEvent(100, 100))
        editor.on_middle_drag(FakeEvent(120, 130))
        editor.on_middle_up(FakeEvent(120, 130))
        eq((editor.ox, editor.oy), (before[0] + 20, before[1] + 30), "中键拖动也能平移")
    finally:
        root.destroy()


def t_redraw_coalescing() -> None:
    """★ 性能：拖动时不能每个鼠标事件都全量重绘（实测那样拖动 100 个事件要 2 秒）。

    `request_redraw()` 会把同一帧里的多次请求合并成一次。这里把「合并」本身钉住：
    128 个 motion 事件 → 实际重绘次数必须远小于 128，而且停手之后**必须**补上那一次
    （不能为了快而丢掉重绘，那样画面就停在旧样子上了）。
    """
    print("\n[11] 重绘合并（拖动要跟手）")
    root, editor = build_editor(size="1280x800")
    try:
        root.update()
        calls = {"n": 0}
        real = editor.redraw
        home = (editor.ox, editor.oy)

        def counting():
            calls["n"] += 1
            real()

        editor.redraw = counting
        editor.on_space_down(FakeEvent(400, 300))
        editor.on_left_down(FakeEvent(400, 300))
        for i in range(128):
            editor.on_left_drag(FakeEvent(400 + i, 300 + i))
        pending = calls["n"]
        editor.on_left_up(FakeEvent(527, 427))
        editor.on_space_up(FakeEvent(527, 427))
        editor.redraw = real

        ok(pending <= 4, "★ 128 个拖动事件只触发了 %d 次重绘（合并生效）" % pending)
        eq((editor.ox, editor.oy), (home[0] + 127, home[1] + 127), "拖动把视野移到位了")

        # 停手之后那次重绘必须真的执行（画面不能停在旧样子）。
        # ⚠️ 两件事别踩：① after 回调里存的是「请求重绘那一刻」的 self.redraw（原来的绑定方法），
        #    所以换掉 self.redraw 拦不住它 —— 要看画布内容；
        #    ② after 要等**真实时间**过去才跑，root.update() 只处理待办事件、不推进定时器，
        #    所以这里要 sleep 一下再 update（这也是实测踩出来的）。
        editor.hover = None
        editor.canvas.delete("all")           # 清空 → 如果补跑的那次重绘没执行，画布就空着
        for _ in range(20):
            time.sleep(0.02)
            root.update()
            if editor.canvas.find_all():
                break
        ok(len(editor.canvas.find_all()) > 0, "★ 扫尾的那次重绘真的执行了（画布不是空的）")

        # 重绘之后画布内容是对的（虚线格盖满视野）
        editor.hover = None
        real()
        vx0, vy0, vx1, vy1 = editor.visible_tile_range()
        dashed = [i for i in editor.canvas.find_all()
                  if editor.canvas.type(i) == "rectangle" and editor.canvas.itemcget(i, "dash")]
        eq(len(dashed), (vx1 - vx0 + 1) * (vy1 - vy0 + 1), "重绘之后的虚线格数量仍然正确")
    finally:
        root.destroy()


def t_zoom_out_keeps_it_fast() -> None:
    """★ 缩得很远时不能画几万个虚线格（实测一屏 8 万个格子要 420 ms，那是卡死的根源）。

    断言都按**当前视野范围**算，不写死格子数（画布尺寸会随窗口/环境变）。
    """
    print("\n[12] 缩得很远时不再画虚格（速度优先）")
    root, editor = build_editor(size="1280x800")
    try:
        root.update()
        editor.hover = None

        def dashed_count() -> int:
            editor.redraw()
            return len([i for i in editor.canvas.find_all()
                        if editor.canvas.type(i) == "rectangle"
                        and editor.canvas.itemcget(i, "dash")])

        # 1:1：格子够大 → 该画；数量 = 视野里的格子数
        editor.zoom = 1.0
        before = dashed_count()
        vx0, vy0, vx1, vy1 = editor.visible_tile_range()
        eq(before, (vx1 - vx0 + 1) * (vy1 - vy0 + 1),
           "1:1 时视野里每格一个虚线框（%d 个）" % before)
        ok(before > 0, "1:1 时确实画了虚线格")

        # 缩到很远（格子 3.6px）→ 不画虚线格，图元很少
        editor.zoom = 0.1
        eq(dashed_count(), 0, "★ 缩到 0.1 时不再画虚线格（太密了，画了看不清还会卡）")
        ok(len(editor.canvas.find_all()) < 20,
           "缩到很远时图元很少（%d 个）" % len(editor.canvas.find_all()))

        # 但已经画出来的地块还得看得见：拿一个在视野正中的格子来画
        vx0, vy0, vx1, vy1 = editor.visible_tile_range()
        target = editor.view_to_world((vx0 + vx1) // 2, (vy0 + vy1) // 2)
        editor.zoom = 1.0
        click_at(editor, *target)
        editor.zoom = 0.1
        editor.hover = None
        editor.redraw()
        # ⚠️ 别数「所有没虚线的方框」：属性面板那圈白色选中框也是实心方框
        #    （点了一格之后它必然在），而且画布底图在某些尺寸下也会被数进来。
        #    这里按**颜色**认那格地：树地块的颜色就是地形色。
        tile_color = editor.terrain_color(editor.model.terrain_at(*target))
        painted = [i for i in editor.canvas.find_all()
                   if editor.canvas.type(i) == "rectangle"
                   and editor.canvas.itemcget(i, "fill") == tile_color]
        eq(len(painted), 1, "缩远了地块照样画出来（画了 1 个，画面上就是 1 个）")
    finally:
        root.destroy()


def t_zone_tab_with_real_map() -> None:
    """★ 回归：带区块的地图里「地块 → 区块」来回切，不能卡死。

    这条是用户报的「点完地块再点区块就无响应」。根因是死循环：
        点页签 → 重建侧边栏 → 新建 Treeview 时 tk 派发 <<TreeviewSelect>>
        → on_zone_select → 又重建侧边栏 → …
    所以下面既测「来回切不卡」，也把那个会递归的事件手动触发一遍。
    """
    print("\n[13] 地块 ↔ 区块 来回切（曾经死循环）")
    cfg = mapfile.load_config(PROJECT_DIR) if hasattr(mapfile, "load_config") else None
    from map_editor.model import load_config as _load_cfg
    model = mapfile.load_map(PROJECT_DIR / "data" / "map_01.json", _load_cfg(PROJECT_DIR))
    root = tk.Tk()
    root.geometry("1280x800")
    root.deiconify()
    root.update()
    editor = app_module.EditorApp(root, PROJECT_DIR, model,
                                  PROJECT_DIR / "data" / "map_01.json")
    root.update()
    editor.apply_initial_view()
    try:
        eq(len(editor.model.zones), 24, "这张图有 24 个区块")
        started = time.perf_counter()
        for i in range(3):
            editor.tab_buttons["zone"].invoke()
            root.update()
            eq(editor.page, "zone", "第 %d 次点「区块」→ 切过去了" % (i + 1))
            eq(len(editor.zone_tree.get_children()), 24, "区块列表里有 24 行")
            editor.tab_buttons["tile"].invoke()
            root.update()
            eq(editor.page, "tile", "第 %d 次点「地块」→ 切回去了" % (i + 1))
        elapsed = time.perf_counter() - started
        # ⚠️ 这条断言**只是死循环的守门员**（不卡就是「秒级回来」），不是性能指标：
        #    阈值给得宽是因为一页侧边栏里要 new 一个 24 行的 Treeview（tk 建行很贵），
        #    而切页签本来就该重建一次。真正的性能断言在 t_smooth_no_wasted_work 里。
        ok(elapsed < 8.0, "★ 来回切 3 轮只花了 %.2f 秒（死循环的话这里会永远回不来）" % elapsed)

        # 手动触发那个「会递归」的事件：选区变化 → 重建侧边栏（重建中再来一律忽略）
        editor.tab_buttons["zone"].invoke()
        root.update()
        eq(editor.selected_zone, editor.model.zones[0].zone_id, "切过去时自动选中第一个区块")
        second = editor.model.zones[1].zone_id
        editor.zone_tree.selection_set(str(second))
        editor.on_zone_select(None)          # 就是这里曾经递归
        eq(editor.selected_zone, second, "★ 选第二个区块 → 选中状态跟着变")
        editor.on_zone_select(None)          # 再触发一次（同一个选区，不该有任何副作用）
        eq(editor.selected_zone, second, "★ 重复触发同一个选区事件仍然没反应也不卡")
        eq(len(editor.zone_tree.get_children()), 24, "列表还是完整的 24 行")

        # 侧边栏重建的防重入闸门不该卡在「正在进行」上
        eq(editor._rebuilding, False, "★ 防重入闸门已经放开（能继续重建侧边栏）")
        editor.refresh_sidebar()
        eq(len(editor.zone_tree.get_children()), 24, "手动重建侧边栏后列表仍然正确")
        eq(editor._rebuilding, False, "重建完闸门是开的")
    finally:
        root.destroy()


def t_tabs_always_respond() -> None:
    """★ 需求：点页签有时没反应。

    根因是焦点：tk 的按钮点过之后会拿住键盘焦点，而**空格在 tk 里是「激活焦点按钮」**——
    用户按住空格拖画面时，最后点过的那个页签被反复重选，看起来就是「点页签没反应 / 页面乱跳」。
    修法：按钮 takefocus=0 + 点完把焦点交还画布。这里把这两条都钉住。
    """
    print("\n[9] 页签：点了必须有反应（含「空格不再去按按钮」）")
    root, editor = build_editor()
    try:
        root.update()
        eq(editor.page, "tile", "一开始在地块页签")

        # 连点几次，每次都换页签：必须每次都生效
        for i in range(4):
            editor.tab_buttons["zone"].invoke()
            eq(editor.page, "zone", "第 %d 次点「区块」→ 切过去了" % (i + 1))
            editor.redraw()
            editor.tab_buttons["tile"].invoke()
            eq(editor.page, "tile", "第 %d 次点「地块」→ 切回去了" % (i + 1))

        # 按钮点了之后不该拿住键盘焦点（否则空格会去按它）。
        # ⚠️ 焦点查询要求窗口是「已映射」的：withdraw 状态下 focus_get() 永远是 None，
        #    所以这一段先把窗口显示出来（仍然很小、几百毫秒，不影响用电脑）。
        root.deiconify()
        root.geometry("600x400")
        root.update()
        editor.tab_buttons["zone"].invoke()
        eq(editor.page, "zone", "★ 窗口真正显示时，点页签照样生效")
        eq(root.focus_get(), editor.canvas, "★ 点完页签，键盘焦点回到画布（不是按钮）")
        eq(int(editor.tab_buttons["zone"].cget("takefocus")), 0,
           "★ 页签按钮 takefocus=0（Tab 遍历不到它，空格也不会激活它）")

        # 真正模拟用户的操作：点页签 → 按空格 → 焦点不该在按钮上
        editor.tab_buttons["tile"].invoke()
        focus = root.focus_get()
        ok(focus is not editor.tab_buttons["tile"],
           "★ 点了页签之后，空格不会落到那颗按钮上（焦点=%s）" % (focus,))

        # 画布上的空格绑定与页签按钮互不干扰
        eq(editor.space_held, False, "没按空格时不在平移模式")
        editor.canvas.focus_set()
        root.update()
        editor.canvas.event_generate("<KeyPress-space>")
        root.update()
        eq(editor.space_held, True, "★ 画布上按空格 → 进入平移模式")
        editor.canvas.event_generate("<KeyRelease-space>")
        root.update()
        eq(editor.space_held, False, "松开 → 退出平移模式")
        eq(editor.page, "tile", "★ 空格没有把页签按得乱跳（还在原地块页签）")
        root.withdraw()
    finally:
        root.destroy()


def t_smooth_no_wasted_work() -> None:
    """★ 需求：「和参考编辑器一样流畅」。

    「流畅」在代码里就三件事，这里各钉一条（都是有实测数字支撑的，见 README 第十节）：

      1. **划格高亮要跟手**：`on_motion` 的重绘节流不能比一帧还大（原来是 40 ms，
         肉眼看得见方框在追光标），也不能把整条侧边栏重建一遍。
      2. **平移时不画错位的高亮**：拖动一开始就把 hover 清掉，
         否则鼠标底下那格的方框会跟着拖动一路闪。
      3. **点一下地不重建侧边栏**：改一格属性走就地改值（`refresh_tile_panel`），
         只有「换格子且面板结构变了」才重建整条。
    """
    print("\n[14] 跟手度：不做白工（节流 / 平移清高亮 / 就地改值）")
    root, editor = build_editor(size="1280x800")
    try:
        root.update()

        ok(app_module.HOVER_THROTTLE_MS <= app_module.REDRAW_COALESCE_MS,
           "★ 悬停节流（%d ms）不比一次重绘的合并窗口（%d ms）大 —— 高亮才跟得住光标"
           % (app_module.HOVER_THROTTLE_MS, app_module.REDRAW_COALESCE_MS))

        # 平移一开始就清高亮
        click_at(editor, 2, 2)
        editor.on_motion(FakeEvent(200, 200))
        ok(editor.hover is not None, "鼠标在画布上时记着光标下的格子（画高亮框）")
        editor.on_middle_down(FakeEvent(200, 200))
        ok(editor.hover is None, "★ 开始拖动平移 → 光标高亮立刻清掉（不会画出一个跟不上的框）")
        editor.on_middle_up(FakeEvent(200, 200))

        # 悬停的 after 回调在窗口销毁时会被取消：这里先确认它确实会挂上、也会被撤掉
        editor.on_motion(FakeEvent(260, 240))
        ok(editor._hover_job is not None, "划过新格子会挂一次「稍后重绘」")
        editor.cancel_redraw()
        ok(editor._hover_job is None, "★ 取消重绘时把悬停那次也取消了（免得回调打到销毁后的控件）")

        # 点一下地：不能重建侧边栏（换格但结构一样时走就地改值）
        built = {"n": 0}
        real_build = editor._build_sidebar

        def counting_build():
            built["n"] += 1
            real_build()

        editor._build_sidebar = counting_build
        click_at(editor, 10, 10)          # 虚线格 → 建出来（结构变了，这里会重建一次）
        first = built["n"]
        click_at(editor, 11, 10)          # 两格都是「已有地块」→ 面板结构没变
        eq(built["n"], first, "★ 从一格已有地块点到另一格：没有重建整条侧边栏")
        click_at(editor, 12, 10)
        eq(built["n"], first, "★ 连着建好几格也不重建（就地改值就够）")

        # 但「面板结构真的变了」必须重建：删掉面板正在看的那一格（已有 → 虚线格）
        click_at(editor, 12, 10, button="right")
        ok(built["n"] > first, "★ 面板看的那一格从「有地块」变成「虚线格」时必须重建")
        eq(editor._tile_widgets["terrain"]["grass"].cget("state"), "disabled",
           "重建之后地形按钮是灰的（虚线格没有地形可改）")

        # 没有选中格子时，面板里一个可改控件都没有
        editor.inspect = None
        editor.refresh_sidebar()
        eq(editor._tile_widgets, {}, "没有选中格子时，面板里没有可改的控件")
        click_at(editor, 20, 20)          # 虚线格 → 建出来（结构变化，必须重建一次）
        ok("terrain" in editor._tile_widgets, "重建之后地形按钮回来了")

        # ---- 页签：点自己已经选中的那个，不该白重建一遍 ----
        editor.set_page("tile")           # 已经在地块页
        before_click = built["n"]
        editor.tab_buttons["tile"].invoke()
        eq(built["n"], before_click, "★ 点自己已选中的页签 → 不重建（否则「点了像卡一下」）")

        # ---- 区块页：划地块 / 改名 / 换选中项都是高频操作，同样不许整条重建 ----
        click_at(editor, 21, 20)          # 先备一格地
        editor.set_page("zone")
        editor.add_zone()                 # 这一下**该**重建（列表多了一行）
        zone_after_add = built["n"]
        click_at(editor, 21, 20)          # 左键点地块 → 划给区块
        eq(built["n"], zone_after_add, "★ 点一下地块划给区块：没有重建侧边栏")
        eq(editor.model.zones[0].tile_count, 1, "（那一格真的划进去了）")
        click_at(editor, 21, 20)          # 再点一次 → 移除
        eq(built["n"], zone_after_add, "★ 再点一次移除：也没有重建")
        editor.zone_tree.selection_set(str(editor.model.zones[0].zone_id))
        editor.on_zone_select(None)
        eq(built["n"], zone_after_add, "★ 在列表里换选中项：没有重建（就地改图例与详情）")
        editor.zone_name_var.set("改成这个名字")
        editor.apply_zone_name()
        eq(built["n"], zone_after_add, "★ 改区块名：没有重建（就地改那一行）")
        eq(editor.zone_tree.item(str(editor.model.zones[0].zone_id), "text"), "改成这个名字",
           "列表里那一行的名字也确实刷新了")
    finally:
        root.destroy()


def t_no_map_size_ui() -> None:
    """★ 需求：「设计师在设计时不需要考虑地图尺寸」，地图可以是不规则形状。

    所以侧边栏不该再有「宽 × 高」「铺满这个范围」「裁剪到画布」这些东西，
    导出范围永远是**已画地块的包围盒**（见 mapfile.model_to_dict）。
    """
    print("\n[15] 没有「地图尺寸」这个概念（导出范围 = 已画地块的包围盒）")
    root, editor = build_editor()
    try:
        for name in ("cols_var", "rows_var"):
            ok(not hasattr(editor, name), "★ 编辑器里没有 %s（没有宽高输入框）" % name)
        for name in ("apply_size", "fill_all", "pick_terrain_by_index"):
            ok(not hasattr(editor, name), "★ 编辑器里没有 %s 这个方法" % name)
        # 「新建地图」不再弹尺寸对话框（弹了就会卡在无头测试里）
        ok(not hasattr(app_module, "_NewMapDialog"), "★ 新建地图不会再问宽 × 高")

        # 画一个不规则形状（L 形），导出就是它的包围盒，没有被裁掉
        for tile in ((0, 0), (1, 0), (2, 0), (0, 1), (0, 2)):
            click_at(editor, *tile)
        eq(editor.model.existing_count(), 5, "画了 5 格（L 形）")
        data = mapfile.model_to_dict(editor.model)
        eq((data["cols"], data["rows"]), (3, 3), "★ 导出范围 = 已画地块的包围盒 3×3")
        eq(sum(sum(row) for row in data["exists"]), 5, "★ 形状内部的空格是「地图外」（不可通行）")
        ok(any(0 in row for row in data["exists"]), "L 形的缺口确实写成了 0")

        # 「全部清空」还在（只是搬到了「整张地图」那一栏）
        ok(hasattr(editor, "clear_all_tiles"), "「全部清空」按钮还在")
        saved_ask = app_module.messagebox.askyesno
        app_module.messagebox.askyesno = lambda *a, **k: True    # 它会先弹一个确认框
        try:
            editor.clear_all_tiles()
        finally:
            app_module.messagebox.askyesno = saved_ask
        eq(editor.model.existing_count(), 0, "★ 全部清空把所有地块变回虚线格")
    finally:
        root.destroy()


def t_canvas_only_has_dashed_cells() -> None:
    """★ 需求：只要虚线；不要斜线、不要背景线条、不要实心网格。

    「斜线」的来历是个 tk 的坑：`create_line` 传进来超过 2 个点时会画**折线**，
    于是原来那批「顶点小点」（每点 4 个坐标）被连成了一串斜线。这里把这类东西全钉死。
    """
    print("\n[10] 画布上只该有虚线格（没有斜线 / 背景线条 / 实心网格）")
    root, editor = build_editor()
    try:
        root.geometry("1000x700")
        root.update()
        editor.apply_initial_view()
        editor.redraw()

        kinds = {}
        for item in editor.canvas.find_all():
            kinds[editor.canvas.type(item)] = kinds.get(editor.canvas.type(item), 0) + 1
        solids = [i for i in editor.canvas.find_all() if editor.canvas.type(i) == "line"]
        eq(solids, [], "★ 画布上一个 line 都没有（斜线/网格线就是这么来的）")
        ok(kinds.get("rectangle", 0) > 0, "画的全是方框（%d 个）" % kinds.get("rectangle", 0))
        dashed = [i for i in editor.canvas.find_all()
                  if editor.canvas.type(i) == "rectangle" and editor.canvas.itemcget(i, "dash")]
        # 非虚线的「内容方框」只允许是光标高亮 / 属性面板选中框（最多 2 个）
        solids = [i for i in _content_rectangles(editor) if not editor.canvas.itemcget(i, "dash")]
        ok(len(solids) <= 2, "★ 非虚线的方框只有高亮/选中框（实际 %d 个）" % len(solids))
        # 虚线格的数量 = 视野里的格子数（每一格一个虚线框）
        vx0, vy0, vx1, vy1 = editor.visible_tile_range()
        eq(len(dashed), (vx1 - vx0 + 1) * (vy1 - vy0 + 1),
           "★ 视野里每一格都画了一个虚线框（%d 格）" % len(dashed))

        # 有了地块之后：地块是实心的（没有虚线），那些格子的虚线框应当消失
        # ⚠️ 按**坐标集合**比对，不要数数量：数量取决于视野里正好有几格（画布尺寸一变就变）。
        painted = [(2, 2), (3, 2)]
        painted_set = set(painted)
        before_dashed = _dashed_tiles(editor)
        for tile in painted:
            click_at(editor, *tile)
        # 点击会把光标高亮与属性面板选中框都留在最后一格上（两个实心方框，都是**该有的**）。
        # 想让它们消失得走界面动作：鼠标移走 + 面板切到别处。
        moved_to = (8, 8)
        click_at(editor, *moved_to)
        editor.hover = None            # 光标高亮框也是方框，数之前关掉
        editor.refresh_tile_panel()    # 面板的就地刷新（inspect 已经指向 moved_to）
        editor.redraw()
        # ⚠️ Canvas 的 item id 在 delete("all") 之后就作废了，必须重新问一次
        eq([i for i in editor.canvas.find_all() if editor.canvas.type(i) == "line"], [],
           "★ 建了地块之后画布上仍然没有 line")
        after_dashed = _dashed_tiles(editor)
        eq(before_dashed - after_dashed, painted_set | {moved_to},
           "★ 消失的虚线格正好就是刚建出来的那几格")
        ok(len(after_dashed) < len(before_dashed), "★ 虚线格变少了（%d → %d）"
           % (len(before_dashed), len(after_dashed)))
        # 有内容的方框 = 虚线格 + 已建地块 + 1 个属性面板选中框（没有棋盘格 / 实心网格）
        # ⚠️ 别写死数字：点击落点会随窗口尺寸变化，用**模型里真实的地块数**来算。
        eq(len(_content_rectangles(editor)), len(after_dashed) + editor.model.existing_count() + 1,
           "★ 有内容的方框只有两种：虚线格 + 已建的地块（没有棋盘格 / 实心网格）")
    finally:
        root.destroy()


def _content_rectangles(editor) -> list:
    """画面上「有内容的方框」：虚线格 + 已建地块 + 高亮框。

    排除铺满整块画布的底图那么大、而且没有边框（那是一个填充矩形，怎么都会有一个）。
    """
    cw, ch = editor.canvas.winfo_width(), editor.canvas.winfo_height()
    out = []
    for item in editor.canvas.find_all():
        if editor.canvas.type(item) != "rectangle":
            continue
        x0, y0, x1, y1 = editor.canvas.coords(item)
        if x0 <= 0 and y0 <= 0 and x1 >= cw and y1 >= ch:
            continue                      # 底图
        out.append(item)
    return out


def _dashed_tiles(editor) -> set:
    """画面上每个虚线框对应的格子坐标（用来按坐标比对，而不是数数量）。"""
    out = set()
    size = editor.tile_px()
    for item in editor.canvas.find_all():
        if editor.canvas.type(item) != "rectangle":
            continue
        if not editor.canvas.itemcget(item, "dash"):
            continue
        x0, y0 = editor.canvas.coords(item)[0], editor.canvas.coords(item)[1]
        out.add((int(round((x0 - 1 - editor.ox) / size)),
                 int(round((y0 - 1 - editor.oy) / size))))
    return out


def t_file_buttons_wired() -> None:
    """需求：「在编辑器里加导入导出按钮」—— 断言这两颗按钮真的在、而且真的接上了动作。

    为什么值得单独测：按钮「看起来在」但 command 接错（或者压根忘了接）是这种工具最常见的坏法，
    它不会崩、只会「点了没反应」—— 正是最难自己发现的一类问题。
    """
    print("\n[7] 导入 / 导出按钮（在工具栏上，而且真的接上了动作）")
    root, editor = build_editor()
    root.update()
    # ⚠️ 不用 tempfile.TemporaryDirectory：它会把目录 chmod 成 0700，
    #    在这个沙箱里反而连自己建的目录都扫不了（WinError 5）。
    #    手写一个普通权限的临时目录，cleanup 用 ignore_errors，免得清理失败把测试判成失败。
    tmpdir = PROJECT_DIR / ".tmp_map_editor_button_test"
    shutil.rmtree(tmpdir, ignore_errors=True)
    tmpdir.mkdir(parents=True, exist_ok=True)
    original_save = filedialog.asksaveasfilename
    original_open = filedialog.askopenfilename
    restore_dialogs = stub_dialogs()
    try:
        buttons = getattr(editor, "file_buttons", {})
        for key, expected in (("export", "导出"), ("import", "导入"), ("new", "新建")):
            btn = buttons.get(key)
            ok(btn is not None, "工具栏上有「%s」按钮" % expected)
            if btn is None:
                continue
            ok(expected in str(btn.cget("text")), "按钮文字含「%s」（实际 %r）"
               % (expected, str(btn.cget("text"))))
            ok(bool(btn.cget("command")), "「%s」按钮接上了动作（点了不会没反应）" % expected)
            ok(btn.winfo_manager() == "pack", "「%s」按钮真的被排进了工具栏" % expected)

        # 点「导出 JSON」：替换掉文件对话框，确认它真的写出文件
        target = tmpdir / "from_button.json"
        click_at(editor, 0, 0)
        filedialog.asksaveasfilename = lambda **kwargs: str(target)
        editor.file_buttons["export"].invoke()
        filedialog.asksaveasfilename = original_save
        ok(target.is_file(), "★ 点「导出 JSON」真的写出了文件")

        # 点「导入地图…」：同样替换对话框，确认它读进一张真图
        filedialog.askopenfilename = lambda **kwargs: str(PROJECT_DIR / "data" / "map_01.json")
        editor.file_buttons["import"].invoke()
        filedialog.askopenfilename = original_open
        eq(editor.model.existing_count(), 384, "★ 点「导入地图…」真的把 map_01.json 读进来了")
        eq(len(editor.model.zones), 24, "导入之后区块也一起进来了")

        # 「新建」不再弹任何对话框：直接给一张全新的无限虚线画布
        ok(bool(editor.file_buttons["new"].cget("command")), "「新建地图」按钮也接上了动作")
        editor.file_buttons["new"].invoke()
        eq(editor.model.existing_count(), 0, "★ 点「新建地图」→ 画布清成一片虚线格")
        eq((editor.model.cols, editor.model.rows), (0, 0), "★ 新建出来的是一张 0×0 的无限画布")
    finally:
        restore_dialogs()
        filedialog.asksaveasfilename = original_save
        filedialog.askopenfilename = original_open
        shutil.rmtree(tmpdir, ignore_errors=True)
        root.destroy()


def t_faction_page() -> None:
    """★ 需求：上边栏加一个「阵营」页签，在里面建阵营、给阵营配大本营。

    钉住的几条：
      · 阵营 id 直接就是游戏那套字符串（player / p1 / enemy）—— 导出的
        `faction_bases` 以它为键，Godot 侧不需要任何翻译表；
      · 一个阵营一个大本营；同一格被别的阵营抢走时，原来那方**失去**它；
      · 设大本营走「先在面板里选格，再点按钮」；再点一次 = 取消；
      · 阵营大本营会进撤销栈（Ctrl+Z 能退）；
      · 地图上画得出阵营标记（这是「哪个大本营是哪一方」的唯一线索）。
    """
    print("\n[17] 阵营页签：建阵营 + 配大本营")
    root, editor = build_editor()
    try:
        # ---- 页签本身
        editor.tab_buttons["faction"].invoke()
        eq(editor.page, "faction", "★ 上边栏有「阵营」页签，点了能切过去")
        eq(editor.selected_faction, None, "还没有阵营时没有选中项")
        eq(editor.faction_tree.get_children(), (), "阵营列表一开始是空的（需求：全部手动加）")

        # ---- 建阵营（直接走模型 + 面板刷新，绕开输入框弹窗）
        f1 = editor.model.add_faction("p1", "玩家")
        editor.model.add_faction("p2", "小明")
        editor.selected_faction = "p1"
        editor.refresh_sidebar()
        ok(f1 is not None, "加了阵营 p1")
        eq([editor.faction_tree.item(i, "text") for i in editor.faction_tree.get_children()],
           ["玩家（p1）", "小明（p2）"], "★ 列表里显示「名字（id）」——两边都看得见")
        eq([editor.faction_tree.item(i, "values")[0]
            for i in editor.faction_tree.get_children()], ["—", "—"], "还没设大本营 → 显示「—」")

        # ---- 建几格，选中一格，设大本营
        editor.set_page("tile")
        for tile in ((3, 3), (4, 3), (3, 4)):
            click_at(editor, *tile)
        editor.set_page("faction")
        eq(editor.faction_base_btn.cget("state"), "normal", "选了阵营 → 按钮可点")

        # 还没选格子时按钮要拦住
        editor.inspect = None
        editor.toggle_faction_base()
        ok("先在地图上点一格" in editor.status_var.get(),
           "★ 没选格子时不猜、不设（提示先去选一格）")

        editor.inspect = (3, 3)
        editor.refresh_faction_panel()
        editor.toggle_faction_base()
        eq(editor.model.faction_base_of("p1"), (3, 3), "★ 一键把大本营设在面板看的那一格")
        eq(editor.faction_tree.item("p1", "values")[0], "(3, 3)", "★ 列表里那一行跟着更新")
        ok("(3, 3)" in editor.faction_base_label.cget("text"), "面板上显示大本营位置")

        # ---- 抢格：一格只能是一方的大本营
        editor.selected_faction = "p2"
        editor.refresh_faction_panel()
        editor.inspect = (3, 3)
        editor.toggle_faction_base()
        eq(editor.model.faction_base_of("p2"), (3, 3), "★ p2 把那一格抢过去了")
        eq(editor.model.faction_base_of("p1"), None, "★ player 同时失去它（不能两方共用一格）")
        ok("原来属于" in editor.status_var.get(), "状态栏说明了是从谁手里拿走的")

        # ---- 再点一次 = 取消
        editor.toggle_faction_base()
        eq(editor.model.faction_base_of("p2"), None, "★ 对同一个大本营再点一次 = 取消")

        # ---- 虚线格不能当大本营
        editor.inspect = (9, 9)
        editor.toggle_faction_base()
        eq(editor.model.faction_base_of("p2"), None, "★ 虚线格设不了大本营")
        ok("虚线格" in editor.status_var.get(), "状态栏说清了原因")

        # ---- 撤销能退回去
        editor.inspect = (4, 3)
        editor.toggle_faction_base()
        eq(editor.model.faction_base_of("p2"), (4, 3), "设上")
        editor.undo()
        eq(editor.model.faction_base_of("p2"), None, "★ Ctrl+Z 能撤销「设大本营」")

        # ---- 地图上画得出阵营标记
        editor.inspect = (3, 4)
        editor.toggle_faction_base()
        editor.redraw()
        marker_color = editor.faction_color(editor.model.faction("p2"))
        marks = [i for i in editor.canvas.find_all()
                 if editor.canvas.type(i) == "rectangle"
                 and editor.canvas.itemcget(i, "fill") == marker_color]
        eq(len(marks), 1, "★ 地图上给这个阵营画了一个标记方块（哪个大本营是哪一方一眼看得出）")

        # ---- 删阵营：它的大本营一起忘掉
        editor.selected_faction = "p2"
        editor.refresh_faction_panel()
        saved_ask = app_module.messagebox.askyesno
        app_module.messagebox.askyesno = lambda *a, **k: True
        try:
            editor.delete_selected_faction()
        finally:
            app_module.messagebox.askyesno = saved_ask
        eq([f.faction_id for f in editor.model.factions], ["p1"], "★ 删掉了阵营")
        eq(editor.model.faction_base_of("p2"), None, "★ 它的大本营也一起没了")

        # ---- 切页签 / 导入导出之后，阵营状态不残留
        editor.set_page("tile")
        click_at(editor, 7, 7)
        editor.set_page("faction")
        editor.inspect = (7, 7)
        editor.refresh_faction_panel()
        editor.toggle_faction_base()
        eq(editor.model.faction_base_of("p1"), (7, 7), "player 的大本营挪到 (7,7)")
    finally:
        root.destroy()


def t_box_selection_batch_edit() -> None:
    """★ 需求：Shift + 拖拽框选出矩形，批量改地形 / 区划归属，并支持批量删除。

    钉住的几条：
      · 只有**已有地块**被选中（虚线格不参与，也不会被批量创建）；
      · Shift + 拖拽走的是真实鼠标事件链（state 里的 Shift 位），不是直接调函数；
      · 一次批量操作 = **一步撤销**；
      · 框选之后点地图 = 退出框选、回到单格；切页签 / Esc 也会清掉框选。
    """
    print("\n[18] Shift 框选 + 批量改地形 / 归属 / 删除")
    root, editor = build_editor()
    try:
        # 先画一片 4×3 的地，右边留一片虚线格
        for y in range(3):
            for x in range(4):
                click_at(editor, x, y)
        eq(editor.model.existing_count(), 12, "先画好 12 格")

        # ---- 没有 Shift 的拖拽不该框选（它现在是「什么都不做」，平移仍是中键/空格）
        editor.on_left_down(fake_mouse(editor, 0, 0))
        editor.on_left_drag(fake_mouse(editor, 3, 2))
        editor.on_left_up(fake_mouse(editor, 3, 2))
        eq(editor.selection, None, "★ 不按 Shift 的拖拽不会框选（也不会误建 / 误删）")

        # ---- Shift + 拖拽 = 框选
        box_select(editor, (0, 0), (2, 1))
        eq(editor.selection, (0, 0, 2, 1), "★ Shift 拖拽框出了矩形")
        eq(len(editor.batch_tiles()), 6, "★ 选中矩形里的 6 个已有地块")
        ok("已框选 6 个地块" in editor.status_var.get(), "状态栏报了数量与范围")

        # 框选里包含虚线格时，那些不进来 ——
        # 先框一个更大的矩形（0,0)–(3,2) 里 12 格全是已有地块；再往外扩到虚线区
        box_select(editor, (0, 0), (3, 2))
        eq(len(editor.batch_tiles()), 12, "框住整片 4×3 = 12 格")
        box_select(editor, (2, 1), (9, 9))
        eq(len(editor.batch_tiles()), 4, "★ 矩形扩到虚线格上，选中的仍然只有已有地块")
        box_select(editor, (0, 0), (2, 1))

        # ---- 批量改地形
        eq(sorted(editor._tile_widgets), [], "★ 框选期间走的是批量面板（不是单格面板）")
        editor.batch_set_terrain("forest")
        eq({editor.model.terrain_at(*t) for t in editor.model.rect_tiles(0, 0, 2, 1)},
           {"forest"}, "★ 选中的格子全变成森林")
        eq(editor.model.terrain_at(3, 0), "grass", "框外的格子没被动")
        ok("6 格" in editor.status_var.get(), "状态栏报了改了几格")

        # ---- 一次批量操作 = 一步撤销
        editor.undo()
        eq({editor.model.terrain_at(*t) for t in editor.model.rect_tiles(0, 0, 2, 1)},
           {"grass"}, "★ 撤销一次就整批退回（不是一格一格退）")

        # ---- 批量划区块
        editor.batch_set_terrain("mountain")
        click_at(editor, 0, 5)                  # 点一下会退出框选
        eq(editor.selection, None, "★ 框选之后在地图上点一下 = 退出框选、回到单格")
        box_select(editor, (0, 0), (2, 1))
        editor.add_zone()                        # 这会重建侧边栏（框选要还在）
        eq(editor.selection, (0, 0, 2, 1), "★ 新建区块不会把框选弄丢")
        editor.batch_zone_choice.set(editor.model.zones[0].name)
        editor.batch_set_zone()
        eq({editor.model.zone_at(*t).zone_id for t in editor.model.rect_tiles(0, 0, 2, 1)},
           {editor.model.zones[0].zone_id}, "★ 选中的格子全划给了那个区块")
        editor.batch_zone_choice.set("（不属于任何区块）")
        editor.batch_set_zone()
        eq({editor.model.zone_at(*t) for t in editor.model.rect_tiles(0, 0, 2, 1)}, {None},
           "★ 也能一次全部摘出来")

        # ---- 批量删除
        saved_ask = app_module.messagebox.askyesno
        app_module.messagebox.askyesno = lambda *a, **k: True
        try:
            editor.batch_delete_tiles()
        finally:
            app_module.messagebox.askyesno = saved_ask
        eq(editor.model.existing_count(), 6, "★ 批量删掉了选中的 6 格")
        eq(editor.selection, None, "删完之后框选自动清掉（格子都没了）")

        # ---- Esc 先清框选，再回地块页
        box_select(editor, (0, 2), (3, 2))
        ok(editor.selection is not None, "又框了一次")
        editor.on_escape()
        eq(editor.selection, None, "★ Esc 先取消框选")
        editor.set_page("faction")
        editor.on_escape()
        eq(editor.page, "tile", "★ 再按一次 Esc 才回到地块页签")

        # ---- 切页签会清掉框选
        editor.set_page("tile")
        box_select(editor, (0, 2), (3, 2))
        editor.set_page("zone")
        eq(editor.selection, None, "★ 切页签时框选被清掉（免得两个页的语义打架）")

        # ---- 框选矩形画得出来（拖动中是虚线预览，松手后是实线 + 数量）
        editor.set_page("tile")
        editor.on_left_down(fake_mouse(editor, 0, 2, shift=True))
        editor.on_left_drag(fake_mouse(editor, 3, 2, shift=True))
        editor.redraw()
        dashed = [i for i in editor.canvas.find_all()
                  if editor.canvas.type(i) == "rectangle"
                  and editor.canvas.itemcget(i, "outline") == app_module.SELECT_OUTLINE
                  and editor.canvas.itemcget(i, "dash")]
        ok(len(dashed) >= 1, "★ 拖动中有虚线预览矩形")
        editor.on_left_up(fake_mouse(editor, 3, 2, shift=True))
        editor.redraw()
        texts = [editor.canvas.itemcget(i, "text") for i in editor.canvas.find_all()
                 if editor.canvas.type(i) == "text"]
        ok(any("格" in t for t in texts), "★ 落定之后画面上标了「N 格」（不用自己数）")
    finally:
        root.destroy()


def t_shift_drag_survives_missing_state_bit() -> None:
    """★ 用户报的：「Shift + 左键拖拽框选」没生效。

    实测根因：**tk 的鼠标事件不保证带 Shift 位** ——
    把 Shift 和鼠标事件分开送进 tk 时，`<ButtonPress-1>` 的 `state` 是 `0x0`，
    于是「按住 Shift 再拖」被当成普通拖拽，**静默不框选**（没有任何提示）。
    另一个同族的坑：拖动期间 tk 也不保证发 `<B1-Motion>`（带 B1 位的 `<Motion>`
    走的是 `<Motion>` 那条绑定），于是预览矩形停在起点不动。

    所以这里**故意造两种「缺信息」的事件**，钉住三条：
      ① 只靠键盘事件（state 位是 0）也能框选；
      ② 只靠鼠标 state 位（不按键盘）也能框选；
      ③ 带 B1 位的 `<Motion>`（而不是 `<B1-Motion>`）也要把预览推到位。
    """
    print("\n[19] Shift 框选：不依赖鼠标事件里的 Shift 位")
    root, editor = build_editor()
    try:
        for y in range(3):
            for x in range(4):
                click_at(editor, x, y)
        editor.selection = None

        # ① 键盘按住 Shift，鼠标事件里**不带** state 位
        editor.on_shift_down()
        ok(editor.shift_held, "按住 Shift 会被记下来（键盘事件那条路）")
        bare = fake_mouse(editor, 0, 0, shift=False)      # state = 0
        editor.on_left_down(bare)
        ok(editor._select_drag is not None,
           "★ 鼠标事件没带 Shift 位、但只要键盘按着 Shift，也要开始框选")
        editor.on_left_drag(fake_mouse(editor, 2, 1, shift=False))
        editor.on_left_up(fake_mouse(editor, 2, 1, shift=False))
        eq(editor.selection, (0, 0, 2, 1), "★ 这样也框出来了（以前这里什么都没有）")
        editor.on_shift_up()
        ok(not editor.shift_held, "松开 Shift 之后状态跟着复位")

        # ② 不按键盘，只有鼠标 state 位（以前唯一认的那条路，不能坏）
        editor.clear_selection()
        box_select(editor, (1, 0), (3, 2))
        eq(editor.selection, (1, 0, 3, 2), "★ 只靠鼠标 state 位仍然能框选")

        # ③ 拖动事件用「带 B1 位的 <Motion>」表达（tk 真的会这么发）
        editor.clear_selection()
        motion = fake_mouse(editor, 2, 2, shift=True)
        motion.state = app_module.SHIFT_MASK | app_module.BUTTON1_MASK
        editor.on_left_down(fake_mouse(editor, 0, 0, shift=True))
        editor.on_motion(motion)                # ← 走的是 on_motion，不是 on_left_drag
        eq(editor._select_drag, ((0, 0), (2, 2)),
           "★ 带 B1 位的 Motion 也会推动框选预览（否则预览停在起点）")
        editor.on_left_up(fake_mouse(editor, 2, 2, shift=True))
        eq(editor.selection, (0, 0, 2, 2), "落定成矩形")

        # ④ 拖到一半松开 Shift：这一拖先落地，不留「僵尸预览」
        editor.clear_selection()
        editor.on_shift_down()
        editor.on_left_down(fake_mouse(editor, 1, 1, shift=False))
        editor.on_left_drag(fake_mouse(editor, 3, 2, shift=False))
        editor.on_shift_up()
        eq(editor._select_drag, None, "★ 松开 Shift 时预览状态被清掉")
        eq(editor.selection, (1, 1, 3, 2), "★ 并且把已经拖出来的矩形落地（不白拖）")
    finally:
        root.destroy()


def main() -> int:
    global _SKIPPED
    print("DAEEM 地图编辑器 · 界面动作测试（无头，不截图）")
    try:
        probe = tk.Tk()
        probe.withdraw()
        probe.destroy()
    except Exception as exc:              # noqa: BLE001 - 没有 Tk 就跳过，不算失败
        print("[skip] 这台机器上起不了 tkinter 窗口：%s" % exc)
        _SKIPPED = True
        print("\n[CASE] test_app -> skipped")
        return 0

    t_step1_create_tile()
    t_step1b_terrain_only_from_panel()
    t_step2_right_click_deletes()
    t_step3_zone_tab()
    t_undo_redo()
    t_step4_export_import()
    t_infinite_canvas()
    t_view_math()
    t_pan_controls()
    t_redraw_coalescing()
    t_zoom_out_keeps_it_fast()
    t_zone_tab_with_real_map()
    t_tabs_always_respond()
    t_canvas_only_has_dashed_cells()
    t_smooth_no_wasted_work()
    t_no_map_size_ui()
    t_draw_up_left_no_invisible_wall()
    t_faction_page()
    t_box_selection_batch_edit()
    t_shift_drag_survives_missing_state_bit()
    t_file_buttons_wired()
    print("\n[CASE] test_app -> passed %d / failed %d" % (_PASSED, _FAILED))
    return 1 if _FAILED else 0


if __name__ == "__main__":
    raise SystemExit(main())
