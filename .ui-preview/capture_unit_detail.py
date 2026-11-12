"""抓「选中一行之后」的单位编辑器（验证侧栏卡片 + 表单）。"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "dev_gd_a" / "tools"
PROJECT = ROOT / "dev_gd_a" / "daeem"
OUT = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))
sys.path.insert(0, str(OUT))

import tkinter as tk  # noqa: E402

from win_grab import grab_client, settle  # noqa: E402


def main():
    from unit_editor import app as m
    from unit_editor.model import ConfigModel

    root = tk.Tk()
    app = m.EditorApp(root, ConfigModel.load(PROJECT / "data" / "config.json"),
                      PROJECT / "data" / "config.json", PROJECT)
    app.selection = ("unit", "spearman")
    app.refresh_all()
    root.geometry("+30+30")
    settle(root, 25)
    grab_client(root).save(OUT / "unit_selected.png")
    print("saved unit_selected.png")

    app.set_page("building")
    settle(root, 15)
    grab_client(root).save(OUT / "unit_building.png")
    print("saved unit_building.png")
    root.destroy()


if __name__ == "__main__":
    main()
