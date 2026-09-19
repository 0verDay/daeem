"""入口：``python dev_gd_a/tools/map_editor``。

命令行：

    python dev_gd_a/tools/map_editor                 # 打开一张空白画布
    python dev_gd_a/tools/map_editor data/map_01.json  # 直接打开一张地图
                                                     #（路径相对 dev_gd_a/daeem/ 或当前目录都行）
    python dev_gd_a/tools/map_editor --selftest      # 不开窗口，跑一遍数据层自检
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

if __package__ in (None, ""):        # 直接 python 这个文件时也能跑
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from map_editor import app as app_module
    from map_editor import mapfile
    from map_editor.model import MapError, config_grid, load_config
else:
    from . import app as app_module
    from . import mapfile
    from .model import MapError, config_grid, load_config

#: 仓库里的 Godot 工程目录（编辑器读它的 data/config.json 拿配色与默认尺寸）
DEFAULT_PROJECT_DIR = Path(__file__).resolve().parents[2] / "daeem"

# 中文控制台（Windows 的 GBK 代码页）下让输出别炸
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")      # type: ignore[union-attr]
    except (AttributeError, ValueError):
        pass


def _resolve_map(arg: str, project_dir: Path) -> Path:
    """把命令行给的地图路径解析出来（相对 dev_gd_a/daeem/ 或当前目录都认）。"""
    p = Path(arg)
    if p.is_file():
        return p
    candidate = project_dir / arg
    if candidate.is_file():
        return candidate
    return p


def selftest(project_dir: Path) -> int:
    """无头自检：读 config、读一张旧地图、再走一遍导出 / 重新导入。"""
    cfg = load_config(project_dir)
    cols, rows = config_grid(cfg)
    print("[config] %s -> grid %dx%d, colors: %s" % (
        project_dir / "data" / "config.json", cols, rows,
        ", ".join(sorted(k for k in (cfg.get("colors") or {}) if isinstance(
            (cfg.get("colors") or {}).get(k), str)))))

    sample = project_dir / "data" / "map_01.json"
    if not sample.is_file():
        print("[map] 找不到样例地图：%s" % sample)
        return 1
    model = mapfile.load_map(sample, cfg)
    print("[load] %s -> %dx%d, tiles=%d, zones=%d, base=%s" % (
        sample.name, model.cols, model.rows, model.existing_count(),
        len(model.zones), model.base))
    for problem in model.problems():
        print("[warn] %s" % problem)

    import json
    text = mapfile.dumps(model)
    again = mapfile.dict_to_model(json.loads(text), cfg)
    same = (again.existing == model.existing and again.terrain == model.terrain
            and again.cols == model.cols and again.rows == model.rows
            and again.base == model.base
            and sorted((z.zone_id, z.name, sorted(z.tiles)) for z in again.zones)
            == sorted((z.zone_id, z.name, sorted(z.tiles)) for z in model.zones))
    print("[roundtrip] %s" % ("OK" if same else "FAILED"))
    return 0 if same else 1


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="map_editor", description="DAEEM 地图编辑器（地块 / 区块 / 大本营）")
    parser.add_argument("map", nargs="?", help="要打开的地图 JSON（可省）")
    parser.add_argument("--project", default=str(DEFAULT_PROJECT_DIR),
                        help="Godot 工程目录（读它的 data/config.json）")
    parser.add_argument("--selftest", action="store_true", help="不开窗口，跑一遍自检")
    args = parser.parse_args(argv)

    project_dir = Path(args.project).resolve()
    if not (project_dir / "data" / "config.json").is_file():
        print("[warn] %s 下没有 data/config.json，将使用兜底配色与 24x16 画布" % project_dir)

    if args.selftest:
        return selftest(project_dir)

    cfg = load_config(project_dir)
    model = None
    current = None
    if args.map:
        path = _resolve_map(args.map, project_dir)
        try:
            model = mapfile.load_map(path, cfg)
            current = path
            print("[open] %s -> %dx%d, tiles=%d, zones=%d"
                  % (path, model.cols, model.rows, model.existing_count(), len(model.zones)))
        except MapError as exc:
            print("[error] %s" % exc)
            return 2

    return app_module.run(project_dir, model, current)


if __name__ == "__main__":
    raise SystemExit(main())
