"""入口：``python dev_gd_a/tools/tech_editor``。

命令行：

    python dev_gd_a/tools/tech_editor                    # 改工程里的 data/config.json
    python dev_gd_a/tools/tech_editor 别的配置.json       # 改另一份（路径相对工程目录或当前目录都行）
    python dev_gd_a/tools/tech_editor --selftest         # 不开窗口，跑一遍数据层自检

★ 默认目标与 unit_editor 一样是**一条固定路径**：`<工程>/data/config.json`。
  科技数值只有这一份 —— 打开编辑器就是为了改它，不设「打开文件」这一步。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

if __package__ in (None, ""):        # 直接 python 这个文件时也能跑
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from tech_editor import app as app_module
    from tech_editor.model import ConfigModel, ModelError, display_value
else:
    from . import app as app_module
    from .model import ConfigModel, ModelError, display_value

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
    """无头自检：读 config → 逐页打印科技的全部数值 → 改一处再改回来。

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

    # ★ 页面是**现算**的（按 doc 里实际存在的条目 / 槽位），所以这里遍历 model，
    #   而不是任何写死的注册表。
    pages = model.pages()
    if not pages:
        print("[error] config 里没有 tech 段（或没有任何可编辑的科技）")
        return 1
    for page in pages:
        print("[tech] %s  %s" % (page.name, model.summary(page)))
        print("       %s" % page.intro)
        try:
            values = model.values(page)
        except ModelError as exc:
            print("[error] %s" % exc)
            return 1
        for field in page.fields:
            cfg_path = ".".join(str(p) for p in field.config_path(page))
            print("       - %-24s %-38s %s" % (
                field.label, cfg_path, display_value(field, values[field.key])))
        warnings = model.warnings(page)
        for w in warnings:
            print("[warn] %s" % w)
        print("[tip] 游戏里的样子：")
        for line in model.preview(page).split("\n"):
            print("       %s" % line)

    # ---- 改一处再改回来：确认「原地最小改动」成立
    page = pages[0]
    field = page.fields[0]
    path_keys = list(field.config_path(page))
    before = model.text
    original = model.doc.value(path_keys)
    if not isinstance(original, (int, float)) or isinstance(original, bool):
        print("[roundtrip] FAILED：%s 不是数字" % field.key)
        return 1
    model.set_value(page, field, original + 1)
    changed = model.text != before
    model.doc.set(path_keys, original)
    restored = model.text == before
    print("[roundtrip] 改一处写回：%s；改回来与原文一致：%s"
          % ("OK" if changed else "FAILED", "OK" if restored else "FAILED"))
    return 0 if (changed and restored) else 1


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="tech_editor", description="DAEEM 科技编辑器（所有已存在科技的数值 / 文案 / 槽位）")
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
