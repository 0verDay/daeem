"""bench_app.py —— 跟手度的无头基准（真实的 Tk 窗口，不显示、不截图）。

跑法（仓库根目录）：

    python dev_gd_a/tools/map_editor/bench_app.py

它量的不是「代码看起来快不快」，而是**一个鼠标事件从进入回调、到像素真的画完**要多少毫秒 ——
这正是「拖起来跟不跟手」的判据（人眼在 ~16ms 以内察觉不到延迟；一帧 16.7ms）。

量的东西（都是真实事件序列，不是空转）：
  1. 全量重绘一次要多久（空画布 / 画满的图 / 分了区块的图 / 缩远了）
  2. 鼠标划过一格（`on_motion` + 重绘 + 画面刷新）
  3. 拖动平移一帧
  4. 滚轮缩放一次
  5. 点击建一格（含属性面板刷新）

⚠️ 只做测量，不做断言 —— 阈值怎么定看这里的数字（别拍脑袋）。
⚠️ 两条实测踩过的坑，写在这里免得下一个人重踩：
   · `canvas.update_idletasks()` 必须算进计时里：tk 是**攒着**画图命令一起下发的，
     只调 redraw() 测到的是「把命令排进队列」的时间，不是「画完」的时间；
   · 测悬停必须给 FakeEvent 加 `.delta`：真实事件有它，旧版本基准没给，
     于是 `on_wheel` 半路抛异常、测量结果全是假的。
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve()
PKG_PARENT = HERE.parent.parent
PROJECT_DIR = HERE.parent.parent.parent / "daeem"
if str(PKG_PARENT) not in sys.path:
    sys.path.insert(0, str(PKG_PARENT))

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")      # type: ignore[union-attr]
    except (AttributeError, ValueError):
        pass

import tkinter as tk                            # noqa: E402

from map_editor import app as app_module        # noqa: E402
from map_editor import mapfile                  # noqa: E402


class FakeEvent:
    def __init__(self, x: float, y: float) -> None:
        self.x = x
        self.y = y
        self.delta = 0


def build_editor(cols: int = 0, rows: int = 0, size: str = "1280x800"):
    root = tk.Tk()
    root.geometry(size)
    root.deiconify()
    root.update()
    model = mapfile.empty_map(cols, rows, None)
    editor = app_module.EditorApp(root, PROJECT_DIR, model, None)
    root.update()
    editor.apply_initial_view()
    root.withdraw()
    return root, editor


def paint(editor, cols: int, rows: int, terrain: str = "grass") -> None:
    """直接往模型里铺一片地（不走界面：这里要量「画出来贵不贵」，不是「铺地贵不贵」）。"""
    editor.model.ensure_tile(cols - 1, rows - 1)
    for y in range(rows):
        for x in range(cols):
            editor.model.create_tile(x, y)
            editor.model.set_terrain(x, y, terrain)


def flush(editor) -> None:
    """把攒着的重绘与画图命令都执行完（这样才等于「用户看到画面更新了」）。"""
    editor.cancel_redraw()
    editor.redraw()
    editor.canvas.update_idletasks()


def timed(editor, fn, *args) -> float:
    t0 = time.perf_counter()
    fn(*args)
    flush(editor)
    return (time.perf_counter() - t0) * 1000.0


def report(label: str, samples) -> None:
    samples = [s for s in samples if s is not None]
    if not samples:
        print("  %-36s （没有样本）" % label)
        return
    avg = sum(samples) / len(samples)
    print("  %-36s 平均 %7.2f ms   最坏 %7.2f ms   n=%d"
          % (label, avg, max(samples), len(samples)))


def wheel_event(x: float, y: float, delta: int) -> FakeEvent:
    event = FakeEvent(x, y)
    event.delta = delta
    return event


def main() -> int:
    print("基准：一个鼠标事件（回调 → 重绘 → 画到屏上）要多少毫秒 —— 目标 < 16ms\n")

    # ---- 1. 刚打开：一张全虚线画的空画布
    root, editor = build_editor()
    try:
        root.update()
        print("[1] 空画布（整屏虚线格）")
        report("一次全量重绘", [timed(editor, editor.redraw) for _ in range(3)])
        print("       格子 %.0fpx，图元 %d" % (editor.tile_px(), len(editor.canvas.find_all())))
        report("悬停划过一格", [timed(editor, editor.on_motion, FakeEvent(200 + i * 7, 300))
                            for i in range(60)])
    finally:
        root.destroy()

    # ---- 2. 一块画满地的地图（平移 / 缩放的真实场景）
    root, editor = build_editor()
    try:
        paint(editor, 64, 64)
        editor.fit_view()
        editor.zoom = 1.0
        editor.center_on(32, 32)
        root.update()
        print("\n[2] 64×64 已画地块，1:1 视野")
        report("一次全量重绘", [timed(editor, editor.redraw) for _ in range(5)])
        print("       图元 %d" % len(editor.canvas.find_all()))
        report("悬停划过一格", [timed(editor, editor.on_motion,
                                 FakeEvent(100 + (i % 200), 200 + (i % 100)))
                            for i in range(60)])

        editor._pan_anchor = (400.0, 300.0)
        report("拖动一帧（on_motion + 重绘）",
               [timed(editor, editor.on_motion, FakeEvent(400.0 + i, 300.0 + i))
                for i in range(60)])
        editor._pan_anchor = None

        report("滚轮缩放一次",
               [timed(editor, editor.on_wheel,
                      wheel_event(600.0, 400.0, 120 if i % 2 == 0 else -120))
                for i in range(20)])

        editor.zoom = 0.35
        print()
        report("0.35 倍视野：一次全量重绘", [timed(editor, editor.redraw) for _ in range(3)])
        print("       图元 %d" % len(editor.canvas.find_all()))
    finally:
        root.destroy()

    # ---- 3. 点击建地块（含属性面板刷新）
    root, editor = build_editor()
    try:
        print("\n[3] 点击建一格（含属性面板）")
        samples = []
        for i in range(10):
            sx, sy = editor.tile_to_screen(i, 3)
            event = FakeEvent(sx + editor.tile_px() / 2, sy + editor.tile_px() / 2)
            t0 = time.perf_counter()
            editor.on_left_down(event)
            editor.on_left_up(event)
            editor.canvas.update_idletasks()
            samples.append((time.perf_counter() - t0) * 1000.0)
        report("左键点一下（建一格）", samples)

        # 改地形：就地改值，不该重建任何控件
        buttons = editor._tile_widgets["terrain"]
        samples = []
        for i in range(10):
            t0 = time.perf_counter()
            buttons["forest" if i % 2 else "mountain"].invoke()
            editor.canvas.update_idletasks()
            samples.append((time.perf_counter() - t0) * 1000.0)
        report("在面板里改地形", samples)
    finally:
        root.destroy()

    # ---- 4. 区块页：一屏区块底色的边界计算
    root, editor = build_editor()
    try:
        paint(editor, 64, 64)
        editor.model.add_zone("东关")
        for y in range(64):
            for x in range(64):
                if (x + y) % 3:
                    editor.model.assign_tile(x, y, 0)
        editor.zoom = 1.0
        editor.center_on(32, 32)
        root.update()
        print("\n[4] 64×64 地块分属区块（区块底色 + 边界线）")
        report("一次全量重绘", [timed(editor, editor.redraw) for _ in range(5)])
        print("       图元 %d" % len(editor.canvas.find_all()))
    finally:
        root.destroy()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
