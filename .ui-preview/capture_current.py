"""在进程内构建四个编辑器窗口，抓一张「现状」图（PrintWindow，被遮挡也行）。

用法：python .ui-preview/capture_current.py [名字 ...]
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "dev_gd_a" / "tools"
PROJECT = ROOT / "dev_gd_a" / "daeem"
OUT = Path(__file__).resolve().parent

sys.path.insert(0, str(TOOLS))
sys.path.insert(0, str(OUT))

import tkinter as tk  # noqa: E402

from win_grab import grab_client, settle  # noqa: E402


def _capture(name: str, build, geometry: str = "+30+30"):
    root = tk.Tk()
    try:
        build(root)
        root.geometry(geometry)
        settle(root, 12)
        img = grab_client(root)
        path = OUT / f"current_{name}.png"
        img.save(path)
        print("saved", path, img.size)
    finally:
        try:
            root.destroy()
        except tk.TclError:
            pass


def map_editor(root):
    from map_editor import app as m
    from map_editor import mapfile
    from map_editor.model import load_config

    cfg = load_config(PROJECT)
    path = PROJECT / "data" / "maps" / "main_test" / "main_test_map.json"
    model = mapfile.load_map(path, cfg) if path.is_file() else None
    m.EditorApp(root, PROJECT, model, path if path.is_file() else None)


def campaign_editor(root):
    from campaign_editor import app as m
    from campaign_editor.model import load_campaign

    cdir = PROJECT / "data" / "campaigns" / "demo"
    model = load_campaign(cdir, PROJECT)
    m.EditorApp(root, model, PROJECT)


def unit_editor(root):
    from unit_editor import app as m
    from unit_editor.model import ConfigModel

    model = ConfigModel.load(PROJECT / "data" / "config.json")
    m.EditorApp(root, model, PROJECT / "data" / "config.json", PROJECT)


def tech_editor(root):
    from tech_editor import app as m
    from tech_editor.model import ConfigModel

    model = ConfigModel.load(PROJECT / "data" / "config.json")
    m.TechEditorApp(root, model, PROJECT / "data" / "config.json", PROJECT)


BUILDERS = {
    "map": map_editor,
    "campaign": campaign_editor,
    "unit": unit_editor,
    "tech": tech_editor,
}


def main(argv):
    names = argv or list(BUILDERS)
    for name in names:
        print("==>", name)
        try:
            _capture(name, BUILDERS[name])
        except Exception as exc:  # noqa: BLE001
            print("FAILED", name, type(exc).__name__, exc)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
