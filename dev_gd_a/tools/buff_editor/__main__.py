"""入口：``python dev_gd_a/tools/buff_editor``。

命令行：

    python dev_gd_a/tools/buff_editor                    # 改工程里的 data/config.json
    python dev_gd_a/tools/buff_editor 别的配置.json       # 改另一份（路径相对工程目录或当前目录都行）
    python dev_gd_a/tools/buff_editor --selftest         # 不开窗口，跑一遍数据层自检

★ 默认目标与 unit_editor 一样是**一条固定路径**：`<工程>/data/config.json`。
  buff 数值只有这一份 —— 打开编辑器就是为了改它，不设「打开文件」这一步。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

if __package__ in (None, ""):        # 直接 python 这个文件时也能跑
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from buff_editor import app as app_module
    from buff_editor.model import BUFFS, ConfigModel, ModelError, display_value, fmt_number
else:
    from . import app as app_module
    from .model import BUFFS, ConfigModel, ModelError, display_value, fmt_number

#: 仓库里的 Godot 工程目录（编辑器读它的 data/config.json）
DEFAULT_PROJECT_DIR = Path(__file__).resolve().parents[2] / "daeem"

# 中文控制台（Windows 的 GBK 代码页）下让输出别炸
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")      # type: ignore[union-attr]
    except (AttributeError, ValueError):
        pass


def resolve_config(arg: str, project_dir: Path) -> Path:
    """把命令行给的配置路径解析出来（相对工程目录或当前目录都认）。"""
    p = Path(arg)
    if p.is_file():
        return p
    candidate = project_dir / arg
    if candidate.is_file():
        return candidate
    return p


def selftest(project_dir: Path) -> int:
    """无头自检：读 config → 打印游戏真正会读的 buff 数值 → 改一处再改回来。

    ★ 用处与 unit_editor 的 `--selftest` 相同：**确认编辑器看到的数 = 游戏读到的数**。
      每条字段的 config 路径都会读一遍（缺键会当场报出来），并验一遍
      「改一个数 → 文本真的变了 → 改回原值 → 与原文逐字节一致」。
    """
    path = project_dir / "data" / "config.json"
    if not path.is_file():
        print("[error] 找不到 %s" % path)
        return 1
    try:
        model = ConfigModel.load(path)
    except ModelError as exc:
        print("[error] %s" % exc)
        return 1
    print("[config] %s（%d 行，%d 字节）" % (
        path, model.text.count("\n") + 1, len(model.text.encode("utf-8"))))

    for buff in BUFFS:
        print("[buff] %s「%s」  %s" % (buff.name, buff.icon, model.summary(buff)))
        print("       %s" % buff.intro)
        try:
            values = model.values(buff)
        except ModelError as exc:
            print("[error] %s" % exc)
            return 1
        for field in buff.fields:
            cfg_path = ".".join(str(p) for p in field.config_path(buff))
            print("       - %-24s %-38s %s" % (
                field.label, cfg_path, display_value(field, values[field.key])))
        warnings = model.warnings(buff)
        for w in warnings:
            print("[warn] %s" % w)
        print("[tip] 悬停文案：")
        for line in model.preview(buff).split("\n"):
            print("       %s" % line)

    # ---- 改一处再改回来：确认「原地最小改动」成立
    buff = BUFFS[0]
    field = buff.fields[0]
    path_keys = list(field.config_path(buff))
    before = model.text
    original = model.doc.value(path_keys)
    if not isinstance(original, (int, float)):
        print("[roundtrip] FAILED：%s 不是数字" % field.key)
        return 1
    model.set_value(buff, field, original + 1)
    changed = model.text != before
    model.doc.set(path_keys, original)
    restored = model.text == before
    print("[roundtrip] 改一处写回：%s；改回来与原文一致：%s"
          % ("OK" if changed else "FAILED", "OK" if restored else "FAILED"))
    return 0 if (changed and restored) else 1


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="buff_editor", description="DAEEM buff 编辑器（士气等 buff 的全部数值）")
    parser.add_argument("config", nargs="?", help="要改的 config.json（可省 = 工程里那一份）")
    parser.add_argument("--project", default=str(DEFAULT_PROJECT_DIR),
                        help="Godot 工程目录（默认 dev_gd_a/daeem）")
    parser.add_argument("--selftest", action="store_true", help="不开窗口，跑一遍自检")
    args = parser.parse_args(argv)

    project_dir = Path(args.project).resolve()
    if args.selftest:
        return selftest(project_dir)

    path = resolve_config(args.config, project_dir) if args.config \
        else project_dir / "data" / "config.json"
    if not path.is_file():
        print("[error] 找不到配置文件：%s" % path)
        return 2
    try:
        return app_module.run(path, project_dir)
    except ModelError as exc:
        print("[error] %s" % exc)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
