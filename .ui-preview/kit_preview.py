"""零件验收：不碰四个编辑器，单独跑一遍新组件库并截图。

用法：python .ui-preview/kit_preview.py
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "dev_gd_a" / "tools"
OUT = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))
sys.path.insert(0, str(OUT))

import tkinter as tk  # noqa: E402
from tkinter import ttk  # noqa: E402

from editor_ui import (  # noqa: E402
    DARK, EditorShell, FONT_SMALL, ThinScrollbar, apply_theme, list_card,
    make_card, set_ui, toast,
)
from win_grab import grab_client, settle  # noqa: E402

UI = dict(DARK)


def build(root: tk.Tk):
    set_ui(UI)
    apply_theme(root, UI)
    shell = EditorShell(root, title="零件验收", brand="单位编辑器",
                        tabs=[("unit", "单位"), ("trait", "单位特性"),
                              ("gen", "将领特性"), ("building", "建筑")],
                        geometry="1280x820", minsize=(1020, 640),
                        status_hint="Ctrl+S 保存 · F5 重新载入")
    shell.add_file_label().configure(text="data/config.json")
    chip = shell.add_dirty_chip()
    shell.add_button("save", "保存", lambda: None, primary=True)
    shell.add_button("reload", "重新载入", lambda: None)
    shell.add_button("save_as", "另存为…", lambda: None)

    content = shell.content
    content.grid_rowconfigure(0, weight=1)
    content.grid_columnconfigure(0, weight=1)

    # 左：表格卡片（高度撑满）
    host = tk.Frame(content, bg=UI["bg"])
    host.grid(row=0, column=0, sticky="nsew", padx=(0, 10))
    host.pack_propagate(False)
    panel = list_card(host, "兵种", "共 6 条")
    panel.pack(fill="both", expand=True)

    inner = tk.Frame(panel.body, bg=UI["panel"])
    inner.pack(fill="both", expand=True, padx=18, pady=(10, 14))
    cols = [("id", 110), ("名称", 110), ("归属", 70), ("血量", 60),
            ("攻击", 60), ("距离", 60), ("移速", 70), ("造价", 120)]
    tree = ttk.Treeview(inner, columns=[c[0] for c in cols], show="headings",
                        selectmode="browse")
    for key, width in cols:
        tree.heading(key, text=key, anchor="w")
        tree.column(key, width=width, anchor="w" if key in ("id", "名称", "归属") else "e")
    rows = [("spearman", "长枪兵", "步兵", "180", "11", "1", "0.6", "80 / 0 / 1"),
            ("longbowman", "长弓兵", "步兵", "115", "18", "4", "0.5", "120 / 0 / 1"),
            ("rider", "骑手", "骑兵", "150", "20", "1", "1.2", "80 / 160 / 1"),
            ("grain_cart", "粮车", "siege", "150", "0", "0", "0.6", "100 / 0 / 1"),
            ("knight", "骑士", "骑兵", "365", "30", "1", "1.0", "120 / 320 / 1"),
            ("catapult", "投石车", "siege", "265", "46", "6", "0.35", "360 / 360 / 1")]
    for row in rows:
        tree.insert("", "end", values=row)
    tree.selection_set(tree.get_children()[0])
    bar = ThinScrollbar(inner, command=tree.yview, trough=UI["panel"])
    tree.configure(yscrollcommand=bar.set)
    bar.pack(side="right", fill="y", padx=(6, 0))
    tree.pack(side="left", fill="both", expand=True)

    # 右：侧栏卡片
    side = tk.Frame(content, bg=UI["bg"], width=340)
    side.grid(row=0, column=1, sticky="nsew")
    side.grid_propagate(False)
    body = make_card(side, "说明", hint="左边点一行 → 右边改它的全部数值。")
    tk.Label(body, text="改完按 Ctrl+S 保存，保存后顶栏的「已保存」会变成「未保存」。",
             bg=UI["panel"], fg=UI["text_soft"], font=FONT_SMALL, anchor="w",
             justify="left", wraplength=280).pack(fill="x", pady=(2, 6))

    body2 = make_card(side, "选中 · spearman")
    for k, v in (("名称", "长枪兵"), ("归属", "步兵"), ("血量", "180"),
                 ("攻击", "11"), ("射程", "1"), ("移速", "0.6")):
        row = tk.Frame(body2, bg=UI["panel"])
        row.pack(fill="x", pady=2)
        tk.Label(row, text=k, bg=UI["panel"], fg=UI["text_dim"],
                 font=FONT_SMALL).pack(side="left")
        tk.Label(row, text=v, bg=UI["panel"], fg=UI["text"],
                 font=FONT_SMALL).pack(side="right")

    root.after(400, lambda: toast(root, "已保存 data/config.json"))
    return shell


def main():
    root = tk.Tk()
    build(root)
    settle(root, 30)
    img = grab_client(root)
    path = OUT / "kit_preview.png"
    img.save(path)
    print("saved", path, img.size)
    root.destroy()


if __name__ == "__main__":
    main()
