#!/usr/bin/env python3
"""临时 / 一次性：只为「教堂」烘一张建筑蒙版（`assets/ui/card_icon/building_church.png`）。

为什么不直接跑 `bake_unit_card_icon.py --commit`：那会重烘**全部**原画 / 组合 / 建筑 / 科技，
把已有的 png 全部重写一遍（无意义的 diff），而且新派系的单位还没有原画、科技也没有
`TECH_SHAPES` 条目。这里只调它内部的 `bake_building()` / `_ensure_mipmaps()`，产物格式一致。
"""
import os
import sys

HERE = os.path.abspath(os.path.dirname(__file__))
sys.path.insert(0, HERE)

import bake_unit_card_icon as B  # noqa: E402

from PIL import Image  # noqa: E402


def main() -> int:
    project, _repo = B._paths()
    wanted = {"church"}
    hits = [b for b in B.discover_buildings(project) if b["type"] in wanted]
    if not hits:
        raise SystemExit("BUILDING_MODELS 里没找到 church（先改 view/building_view_3d.gd）")
    out_dir = os.path.join(project, "assets", "ui", "card_icon")
    os.makedirs(out_dir, exist_ok=True)
    for b in hits:
        rgba = B.bake_building(project, b)
        if rgba is None:
            raise SystemExit("教堂模型读不到：%s" % b.get("res"))
        path = os.path.join(out_dir, "building_" + b["type"] + ".png")
        Image.fromarray(rgba, "RGBA").save(path, "PNG", optimize=True)
        fixed = B._ensure_mipmaps(path)
        cov = float((rgba[:, :, 3] > 24).mean() * 100.0)
        print("[commit] %s  %.1f KB  cov=%.1f%%  mipmap=%s"
              % (path, os.path.getsize(path) / 1024.0, cov, fixed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
