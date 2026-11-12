"""把四个编辑器的每个页签都截一张（用于逐页检查布局）。"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "dev_gd_a" / "tools"
PROJECT = ROOT / "dev_gd_a" / "daeem"
OUT = Path(__file__).resolve().parent / "pages"
sys.path.insert(0, str(TOOLS))
sys.path.insert(0, str(OUT.parent))

import tkinter as tk  # noqa: E402

from win_grab import grab_client, settle  # noqa: E402

OUT.mkdir(exist_ok=True)


def shoot(root, name):
    settle(root, 12)
    grab_client(root).save(OUT / (name + ".png"))
    print("saved", name)


def campaign():
    from campaign_editor import app as m
    from campaign_editor.model import load_campaign

    root = tk.Tk()
    app = m.EditorApp(root, load_campaign(PROJECT / "data" / "campaigns" / "demo", PROJECT),
                      PROJECT)
    root.geometry("+30+30")
    for key, label, _hint in m.PAGES:
        app.set_page(key)
        shoot(root, "campaign_" + key)
    root.destroy()


def map_editor():
    from map_editor import app as m
    from map_editor import mapfile
    from map_editor.model import load_config

    root = tk.Tk()
    cfg = load_config(PROJECT)
    path = PROJECT / "data" / "maps" / "main_test" / "main_test_map.json"
    model = mapfile.load_map(path, cfg)
    app = m.EditorApp(root, PROJECT, model, path)
    root.geometry("+30+30")
    for key in ("tile", "zone"):
        app.set_page(key)
        shoot(root, "map_" + key)
    root.destroy()


def unit():
    from unit_editor import app as m
    from unit_editor.model import ConfigModel

    root = tk.Tk()
    app = m.EditorApp(root, ConfigModel.load(PROJECT / "data" / "config.json"),
                      PROJECT / "data" / "config.json", PROJECT)
    root.geometry("+30+30")
    for key, _label, _hint in m.PAGES:
        app.set_page(key)
        shoot(root, "unit_" + key)
    root.destroy()


def tech():
    from tech_editor import app as m
    from tech_editor.model import ConfigModel

    root = tk.Tk()
    app = m.TechEditorApp(root, ConfigModel.load(PROJECT / "data" / "config.json"),
                          PROJECT / "data" / "config.json", PROJECT)
    root.geometry("+30+30")
    app.select_page("tech:list:6")
    shoot(root, "tech_list")
    app.select_page("tech:slots:dynasty")
    shoot(root, "tech_slots")
    root.destroy()


if __name__ == "__main__":
    for fn in (campaign, map_editor, unit, tech):
        try:
            fn()
        except Exception as exc:  # noqa: BLE001
            print("FAILED", fn.__name__, type(exc).__name__, exc)
