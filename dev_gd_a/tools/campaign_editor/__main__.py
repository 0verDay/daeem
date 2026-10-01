"""入口：``python dev_gd_a/tools/campaign_editor``。

命令行（与另两个编辑器同一套习惯）：

    python dev_gd_a/tools/campaign_editor                      # 打开上次/默认战役目录
    python dev_gd_a/tools/campaign_editor data/campaigns/demo   # 直接开一个战役目录
    python dev_gd_a/tools/campaign_editor --new my_campaign     # 新建一个战役
    python dev_gd_a/tools/campaign_editor --selftest            # 不开窗口，跑数据层自检

★ 「上次打开的是哪个战役」记在一个**小状态文件**里
  （`<用户配置目录>/daeem_campaign_editor.json`，见 `load_last_dir` / `save_last_dir`）：
  战役编辑器不像 unit_editor 那样只有一份固定目标，但也不该每次都让人打一遍路径。
  ⚠️ 状态文件写不进去（受限环境 / 只读盘）时**静默跳过** —— 它只是便利，不是数据。

★ `--new` 会在 `data/campaigns/<id>/` 下**真的建出目录与文件**（不然退出之后什么都没留下），
  并顺手建第一关：逻辑层要求「一个战役至少一关」，一关都没有的战役是读不出来的。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Optional

if __package__ in (None, ""):        # 直接 python 这个文件时也能跑
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from campaign_editor import app as app_module
    from campaign_editor import levelfile
    from campaign_editor import model as model_mod
else:
    from . import app as app_module
    from . import levelfile
    from . import model as model_mod

#: 仓库里的 Godot 工程目录（编辑器读它的 data/，一个字节都不写）
DEFAULT_PROJECT_DIR = Path(__file__).resolve().parents[2] / "daeem"

# 中文控制台（Windows 的 GBK 代码页）下让输出别炸
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")      # type: ignore[union-attr]
    except (AttributeError, ValueError):
        pass


# ----------------------------------------------------------------------
# 「上次打开的战役」
# ----------------------------------------------------------------------

def state_path() -> Path:
    """状态文件放哪儿：`%APPDATA%`（Windows）/ `$XDG_CONFIG_HOME`（其它平台）。"""
    base = os.environ.get("APPDATA") or os.environ.get("XDG_CONFIG_HOME")
    root = Path(base) if base else Path.home() / ".config"
    return root / "daeem_campaign_editor.json"


def load_last_dir() -> Optional[str]:
    try:
        data = json.loads(state_path().read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None
    if isinstance(data, dict) and isinstance(data.get("last_dir"), str):
        return str(data["last_dir"]) or None
    return None


def save_last_dir(dir_path: Any) -> None:
    """记下「上次打开的战役」；写不进去就算了（它只是便利，不是数据）。"""
    try:
        path = state_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"last_dir": str(dir_path)}, ensure_ascii=False, indent=2),
                        encoding="utf-8")
    except OSError:
        pass


# ----------------------------------------------------------------------
# 路径解析
# ----------------------------------------------------------------------

def resolve_campaign_dir(arg: str, project_dir: Path) -> Path:
    """把命令行给的战役目录解析出来（相对工程目录或当前目录都认）。

    认这几种写法：
      · `data/campaigns/demo`（相对工程目录 —— `daeem/data/campaigns/demo` 不存在时
        再按「相对 dev_gd_a」试一次，因为 `dev_plan_7` 里的路径是 `data/campaigns/...`
        而本文件的默认工程目录是 `dev_gd_a/daeem`）；
      · `demo`（只给战役 id，去 `data/campaigns/` 下找）；
      · 绝对路径 / 相对当前目录的路径。
    """
    raw = str(arg).strip()
    p = Path(raw)
    candidates = [p]
    candidates.append(project_dir / raw)
    candidates.append(project_dir.parent / raw)
    if os.sep not in raw and "/" not in raw:
        candidates.append(project_dir.joinpath(*model_mod.CAMPAIGNS_SUBDIR) / raw)
    for cand in candidates:
        if cand.is_dir():
            return cand.resolve()
    return p


def campaigns_root(project_dir: Path) -> Path:
    return project_dir.joinpath(*model_mod.CAMPAIGNS_SUBDIR)


# ----------------------------------------------------------------------
# 自检（--selftest）
# ----------------------------------------------------------------------

def selftest(project_dir: Path, campaign_dir: Optional[str] = None) -> int:
    """无头自检：把「编辑器看到的」与「游戏会读到的」摆在一起，一条条打印并核对。

    ★ 这一份自检的用处：**确认契约没漂**。它做三件事：
      1. 列出 `data/campaigns/` 下的战役、每关的模式 / 地图 / 目标 / 席位；
      2. 跑一遍那 16+4 条校验，把拦截项一条条打出来（**拦截项不算自检失败**：
         编辑器本来就是用来发现它们的 —— 自检失败只表示「数据读不出来」或「往返不一致」）；
      3. 在**临时目录**里做一次「读进来 → 写出去 → 再读进来」，逐字段比对。
         真文件一个字节都不动（这是本工程的一条硬规矩）。
    """
    print("DAEEM 战役编辑器 · 数据层自检")
    print("工程目录：%s" % project_dir)
    config = levelfile.load_config(project_dir)
    print("[config] 兵种 %d：%s" % (len(config.unit_types), "、".join(config.unit_types)))
    print("[config] 将领 %d 位（护卫 %d）：%s"
          % (len(config.general_types), config.escort_count,
             "、".join(config.general_label(i) for i in config.general_indices())))
    print("[config] 建筑：%s　区划种类：%s"
          % ("、".join(config.building_types), "、".join(config.zone_kinds)))

    maps = levelfile.maps_by_id(project_dir)
    if not maps:
        print("[error] data/maps/ 下一张地图都没有")
        return 1
    for mid in sorted(maps):
        info = maps[mid]
        marks = [m for m, on in (("仅战役", info.hidden), ("占位", info.placeholder)) if on]
        print("[map] %-10s %2dx%-2d 区划 %d 个大本营 %d 个%s"
              % (mid, info.cols, info.rows, len(info.zone_ids), len(info.faction_bases),
                 "（%s）" % "、".join(marks) if marks else ""))

    dirs = levelfile.list_campaign_dirs(project_dir)
    if not dirs:
        print("[warn] data/campaigns/ 下一个战役都没有 —— 用 --new <id> 建一个")
        return 0
    print("[campaigns] %s" % "、".join(p.name for p in dirs))

    failures = 0
    target = Path(campaign_dir) if campaign_dir else dirs[0]
    for cdir in dirs:
        try:
            model = levelfile.load_campaign(cdir, project_dir)
        except model_mod.ModelError as exc:
            if cdir == target:
                print("[error] 载入战役失败：%s" % exc)
                failures += 1
            else:
                print("[skip] 战役 %s 读不出来：%s" % (cdir.name, exc))
            continue
        print("\n[战役] %s（%s，%d 关，默认%s）"
              % (model.campaign_id, model.name, len(model.levels),
                 "双人合作" if model.default_mode == model_mod.MODE_COOP else "单人"))
        print("      可玩阵营：%s" % ("、".join(model.playable_ids()) or "（一个都没有）"))
        for i, lv in enumerate(model.levels):
            obj = lv.objective() or {}
            print("  [%d] %-14s %-10s %s　席位 %s　目标区划 %s / %s 秒　额外失败 %d 条"
                  % (i + 1, lv.level_id, lv.map_id, lv.summary(),
                     "、".join(lv.seats()) or "（空）",
                     model_mod.zone_label(int(obj.get("zone", -1))),
                     model_mod.fmt_sec(float(obj.get("hold_sec", 0.0))),
                     len(lv.fail_conditions)))
            for e in lv.factions:
                print("        · 阵营 %-8s ai=%-8s 大本营 %-8s 资源 ×%-4g 进攻目标 %s"
                      % (e.fid, e.ai, e.base_label(), e.resource_mult,
                         model_mod.target_label(e.attack_target)))
        issues = model_mod.validate_campaign(model, maps)
        blocks = model_mod.blockers(issues)
        warns = model_mod.warnings(issues)
        for issue in issues:
            print("  [%s] %s　%s　%s"
                  % ("拦截" if issue.sev == model_mod.SEV_BLOCK else "警告",
                     issue.code, issue.where, issue.msg))
        print("  → 拦截 %d 条、警告 %d 条%s"
              % (len(blocks), len(warns), "（这一份数据现在导不出去）" if blocks else ""))
        if cdir == target:
            ok, diffs = _selftest_roundtrip(model, project_dir)
            print("  [roundtrip] 读进来 → 写出去 → 再读进来：%s" % ("逐字段一致" if ok
                                                                    else "**不一致**"))
            for line in diffs[:10]:
                print("      · %s" % line)
            if not ok:
                failures += 1
    if failures:
        print("\n[FAILED] 自检失败 %d 处" % failures)
        return 1
    print("\n[OK] 自检通过（真文件一字未改；往返在临时目录里做）")
    return 0


def _selftest_roundtrip(model, project_dir: Path):
    """在工程内的临时目录里做一次往返（**不动真文件**）。

    ⚠️ 为什么不放系统 temp：受限环境下系统 temp 不一定可写（实测被拦过），
      而工程目录里的 `.tmp_campaign_editor_selftest` 一定可写 —— 与另两个编辑器同款。
    """
    import shutil
    tmp = Path(__file__).resolve().parent / ".tmp_campaign_editor_selftest"
    shutil.rmtree(tmp, ignore_errors=True)
    try:
        return levelfile.roundtrip_ok(model, tmp, project_dir)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ----------------------------------------------------------------------
# main
# ----------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="campaign_editor",
        description="DAEEM 战役编辑器（战役 / 关卡 / AI 指派 / 摆放 / 目标）")
    parser.add_argument("campaign", nargs="?",
                        help="战役目录（相对 dev_gd_a/daeem/ 或当前目录都认；也可只给 id）")
    parser.add_argument("--project", default=str(DEFAULT_PROJECT_DIR),
                        help="Godot 工程目录（默认 dev_gd_a/daeem）")
    parser.add_argument("--new", metavar="ID", help="新建一个战役（在 data/campaigns/ 下）")
    parser.add_argument("--name", default="", help="配合 --new：战役显示名")
    parser.add_argument("--map", default="", help="配合 --new：第一关用哪张地图（默认第一张）")
    parser.add_argument("--selftest", action="store_true", help="不开窗口，跑一遍数据层自检")
    parser.add_argument("--list", action="store_true", help="列出所有战役目录后退出")
    args = parser.parse_args(argv)

    project_dir = Path(args.project).resolve()
    if not project_dir.is_dir():
        print("[error] 工程目录不存在：%s" % project_dir)
        return 2

    if args.list:
        dirs = levelfile.list_campaign_dirs(project_dir)
        for d in dirs:
            print("%s\t%s" % (d.name, d))
        return 0

    if args.new:
        try:
            model, written = levelfile.create_campaign(project_dir, args.new, args.name, args.map)
        except model_mod.ModelError as exc:
            print("[error] %s" % exc)
            return 2
        print("[new] 战役「%s」建在 %s" % (model.campaign_id, model.dir_path))
        for p in written:
            print("      写了 %s" % p)
        print("      接着打开它：python %s %s"
              % (Path(__file__).parent.name, Path(model.dir_path)))
        save_last_dir(model.dir_path)
        if args.selftest:
            return selftest(project_dir, str(model.dir_path))
        return 0

    if args.selftest:
        target = resolve_campaign_dir(args.campaign, project_dir) if args.campaign else None
        return selftest(project_dir, str(target) if target else None)

    # ---- 打开界面 ----
    target: Optional[Path] = None
    if args.campaign:
        target = resolve_campaign_dir(args.campaign, project_dir)
    else:
        last = load_last_dir()
        if last and Path(last).is_dir():
            target = Path(last)
        else:
            dirs = levelfile.list_campaign_dirs(project_dir)
            if dirs:
                target = dirs[0]
    if target is None:
        print("没有可打开的战役。%s" % campaigns_root(project_dir))
        print("先建一个：python dev_gd_a/tools/campaign_editor --new my_campaign")
        return 2
    if not Path(target).is_dir():
        print("[error] 战役目录不存在：%s" % target)
        return 2
    save_last_dir(target)
    return app_module.run(target, project_dir)


if __name__ == "__main__":
    raise SystemExit(main())
