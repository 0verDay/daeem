"""入口：``python dev_gd_a/tools/map_editor``。

命令行：

    python dev_gd_a/tools/map_editor                 # 打开一张空白画布
    python dev_gd_a/tools/map_editor data/maps/frontier/map.json   # 直接打开一张地图
                                                     #（路径相对 dev_gd_a/daeem/ 或当前目录都行）
    python dev_gd_a/tools/map_editor --map frontier   # ★ 按**地图 id** 直接打开
                                                     #（= data/maps/<id>/ 那个目录名；
                                                     #  战役编辑器的「一键打开地图编辑器」用它）
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

#: 一个地图一个目录，目录名就是地图 id（与 logic/map_library.gd 同一条约定）。
MAPS_SUBDIR = Path("data") / "maps"
MAP_FILE_NAME = "map.json"

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


def resolve_map_arg(arg: str, project_dir: Path):
    """把 ``--map`` 的值解析成一张地图文件的路径；解析不出来返回 ``None``。

    认三种写法（先后有别，见 docstring）：

    1. ``data/maps/<id>/map.json`` / 任意指向文件的路径（相对工程目录或当前目录都行）——
       与位置参数同一个口径，直接走 ``_resolve_map``；
    2. ``<id>``（**地图 id** = 目录名）：``<工程>/data/maps/<id>/map.json``；
    3. ``data/maps/<id>``（指向**目录**）：那个目录里的 ``map.json``。

    ★ 为什么要有「按 id」这一档：战役编辑器只知道当前关引用的**地图 id**
      （关卡 JSON 里写的就是 ``"map": "frontier"``），它不该去拼 `data/maps/...` 这种
      路径细节 —— 拼错了会安静地打开一张不存在的图。id 与目录的对应关系由这里负责。
    """
    raw = (arg or "").strip()
    if raw == "":
        return None

    # 1) 直接就是文件
    direct = _resolve_map(raw, project_dir)
    if direct.is_file():
        return direct

    # 2) 相对工程目录（或当前目录）的一个**目录**：`data/maps/<id>` 这种写法
    for base in (project_dir, Path.cwd()):
        cand0 = base / raw
        if cand0.is_dir():
            found = _map_in_dir(cand0)
            if found is not None:
                return found

    # 3) 当**地图 id**（= 目录名）用：`<工程>/data/maps/<id>/`
    cand = project_dir / MAPS_SUBDIR / raw
    if cand.is_dir():
        return _map_in_dir(cand)

    return None


def _map_in_dir(folder: Path):
    """在一个地图目录里找那份地图 JSON（``map.json`` → ``<目录名>.json`` → 任一 ``*.json``）。

    ★ 候选顺序与 ``logic/map_library.gd`` 的 ``find_map_file`` **同规**：
      两边不一致的话会出现「游戏认这张图、编辑器打开的是另一张」这种最难查的错。
    """
    prefer = folder / MAP_FILE_NAME
    if prefer.is_file():
        return prefer
    named = folder / (folder.name + ".json")
    if named.is_file():
        return named
    jsons = sorted(folder.glob("*.json"))
    if jsons:
        return jsons[0]
    return None


def selftest(project_dir: Path) -> int:
    """无头自检：读 config、读一张旧地图、再走一遍导出 / 重新导入。"""
    cfg = load_config(project_dir)
    cols, rows = config_grid(cfg)
    print("[config] %s -> grid %dx%d, colors: %s" % (
        project_dir / "data" / "config.json", cols, rows,
        ", ".join(sorted(k for k in (cfg.get("colors") or {}) if isinstance(
            (cfg.get("colors") or {}).get(k), str)))))

    sample = project_dir / "data" / "maps" / "frontier" / "map.json"
    if not sample.is_file():
        print("[map] 找不到样例地图：%s" % sample)
        return 1
    model = mapfile.load_map(sample, cfg)
    print("[load] %s -> %dx%d, tiles=%d, zones=%d, centers=%d, factions=%d" % (
        sample.name, model.cols, model.rows, model.existing_count(),
        len(model.zones), len(model.center_of), len(model.factions)))
    print("[centers] %s" % ", ".join(
        "%s=(%d,%d)" % (z.name, z.center[0], z.center[1])
        for z in model.zones[:4] if z.center is not None))
    print("[kinds] %s" % ", ".join(
        "%s=%s" % (z.name, model.zone_kind(z.zone_id)) for z in model.zones[:4]))
    for problem in model.problems():
        print("[warn] %s" % problem)

    import json
    text = mapfile.dumps(model)
    again = mapfile.dict_to_model(json.loads(text), cfg)
    same = (again.existing == model.existing and again.terrain == model.terrain
            and again.cols == model.cols and again.rows == model.rows
            and again.faction_bases == model.faction_bases
            and sorted((z.zone_id, z.name, z.kind, sorted(z.tiles), z.center,
                        tuple(sorted(z.production.items()))) for z in again.zones)
            == sorted((z.zone_id, z.name, z.kind, sorted(z.tiles), z.center,
                       tuple(sorted(z.production.items()))) for z in model.zones))
    print("[roundtrip] %s" % ("OK" if same else "FAILED"))
    return 0 if same else 1


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="map_editor", description="DAEEM 地图编辑器（地块 / 区块 / 大本营）")
    parser.add_argument("map", nargs="?", help="要打开的地图 JSON（可省）")
    parser.add_argument("--map", dest="map_opt", default="",
                        help="要打开的地图：地图 id（目录名）或 map.json 的路径（可省）")
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

    # ★ `--map` 与位置参数都能开图。两个都给时以 `--map` 为准（它是「明确点名要开哪张」）。
    target: Path | None = None
    if args.map_opt:
        target = resolve_map_arg(args.map_opt, project_dir)
        if target is None:
            print("[error] 找不到 --map 指定的地图：%s" % args.map_opt)
            print("        （认地图 id，比如 frontier；也认 map.json 的路径）")
            return 2
    elif args.map:
        target = _resolve_map(args.map, project_dir)

    if target is not None:
        try:
            model = mapfile.load_map(target, cfg)
            current = target
            print("[open] %s -> %dx%d, tiles=%d, zones=%d"
                  % (target, model.cols, model.rows, model.existing_count(), len(model.zones)))
        except MapError as exc:
            print("[error] %s" % exc)
            return 2

    return app_module.run(project_dir, model, current)


if __name__ == "__main__":
    raise SystemExit(main())
