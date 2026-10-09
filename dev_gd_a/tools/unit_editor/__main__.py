"""入口：``python dev_gd_a/tools/unit_editor``。

命令行：

    python dev_gd_a/tools/unit_editor                    # 改工程里的 data/config.json
    python dev_gd_a/tools/unit_editor 别的配置.json       # 改另一份（路径相对工程目录或当前目录都行）
    python dev_gd_a/tools/unit_editor --selftest         # 不开窗口，跑一遍数据层自检

★ 默认目标是**一条固定路径**：`<工程>/data/config.json`。
  这不是「打开文件」式工具（地图编辑器要打开不同的地图），
  单位数值只有这一份 —— 打开编辑器就是为了改它，多一步「选文件」纯属多余。
  「另存为」还留着，用来做对照 / 备份。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

if __package__ in (None, ""):        # 直接 python 这个文件时也能跑
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from unit_editor import app as app_module
    from unit_editor.model import ConfigModel, ModelError, TECH_EFFECTS, fmt_number
else:
    from . import app as app_module
    from .model import ConfigModel, ModelError, TECH_EFFECTS, fmt_number

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
    """无头自检：读 config → 打印一遍游戏真正会读的数值 → 改一处再改回来。

    ★ 这一份自检的用处：**确认编辑器看到的数 = 游戏读到的数**。
      它把「单位 / 将领 / 建筑（含每级）/ 科技」都过一遍，
      任何一条路径写错（比如把 `cooldown_sec` 写成 `cooldown`）都会在这里现形。
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
    print("[config] %s（%d 行，%d 字节）" % (path, model.text.count("\n") + 1,
                                            len(model.text.encode("utf-8"))))
    for unit in model.units():
        print("[unit] %-12s %-6s %-8s 字 %-3s 血 %-5s 攻 %-5s 距离 %-5s 攻速 %-5s 移速 %-5s"
              " 造价 %s/%s/%s 招募 %ss%s"
              % (unit.id, unit.name, unit.class_label, unit.icon_char,
                 fmt_number(unit.hp_max),
                 fmt_number(unit.damage), fmt_number(unit.range),
                 fmt_number(unit.cooldown_sec), fmt_number(unit.speed),
                 fmt_number(unit.cost_food), fmt_number(unit.cost_gold),
                 fmt_number(unit.population_cost), fmt_number(unit.train_sec),
                 "" if unit.has_recruit else "（不在招募表）"))
    for gen in model.generals():
        own = [k for k in ("hp_max", "damage", "range", "cooldown_sec", "speed")
               if not gen.inherits(k)]
        print("[general] %d %-10s 类型 %-11s 血 %s 攻 %s 距离 %s 移速 %s 造价 %s/%s/%s"
              " 招募 %ss%s"
              % (gen.index + 1, gen.name, gen.type_id, fmt_number(gen.effective_of("hp_max")),
                 fmt_number(gen.effective_of("damage")),
                 fmt_number(gen.effective_of("range")),
                 fmt_number(gen.effective_of("speed")),
                 fmt_number(gen.cost_food), fmt_number(gen.cost_gold),
                 fmt_number(gen.population_cost), fmt_number(gen.train_sec),
                 "　单独数值：%s" % "、".join(own) if own else "　（完全跟随兵种）"))
    # ★ 「开局护卫数」这个全局缺省已经删掉：开局带几个附属兵只能在**战役编辑器的
    #   摆放页**里一个一个摆出来（见 app.py 里那一行灰字提示）。
    print("[general] 开局附属兵：改在**战役编辑器的摆放页**里摆"
          "（config.json 里不再有这个全局缺省）")
    for b in model.buildings():
        atk = ("攻 %s / 距离 %s / 攻速 %ss" % (fmt_number(b.damage), fmt_number(b.range),
                                              fmt_number(b.cooldown))
               if b.attackable else "不可攻击")
        print("[building] %-12s %-6s 血 %-6s 造价 %s/%s 建造 %ss %s 建造页 %s 升级 %s"
              % (b.id, b.name, fmt_number(b.hp_max), fmt_number(b.cost_food),
                 fmt_number(b.cost_gold), fmt_number(b.build_sec), atk,
                 "是" if b.buildable else "否",
                 "、".join("%d级%g血(%.0f)" % (lv.level, lv.hp_mult, lv.hp_of(b.hp_max))
                           for lv in b.levels) or "没有表"))
        for lv in b.levels:
            if lv.index == 0:
                continue
            own = [k for k in ("damage", "range", "cooldown") if lv.has_attack(k)]
            print("           升到 %d 级：%s 粮 %s 金 %s，读条 %ss%s"
                  % (lv.level, "血 ×%g" % lv.hp_mult, fmt_number(lv.cost_food),
                     fmt_number(lv.cost_gold), fmt_number(lv.time_sec),
                     "　攻击：%s" % "、".join("%s=%s" % (k, fmt_number(lv.attack[k]))
                                             for k in own) if own else "　攻击沿用基础值"))
    for tech in model.techs():
        effects = "、".join("%s=%g" % (k, tech.effect_value(k)) for k, _l, _h in
                            TECH_EFFECTS if tech.effect_value(k) is not None)
        print("[tech] %-14s %-12s %s" % (tech.id, tech.name, effects or "（没有加成）"))
    print("[tech] 同一时间最多启用 %d 条" % model.max_active())

    # ---- 改一处再改回来：确认「原地最小改动」成立（文本必须逐字节回到原样）
    #
    # ⚠️ 「改回来」必须回到**它原本的值**（这里读一次），不能写死一个数：
    #    当初写死的 `0` 是「箭塔建造时间本来就是 0」那个年代的假设，
    #    而 config 里它后来变成了别的值 ⇒ 自检会假红（实测踩到）。
    before = model.text
    path = ["building", "tower", "build_sec"]
    orig = model.doc.value(path, 0)          # 源 JSON 里的**原值**（类型也原样）
    model.set_building("tower", "build_sec", float(orig) + 7)
    changed = model.text != before
    model.doc.set(path, orig)                # 写回原值（按原类型，文本才逐字节回得去）
    print("[roundtrip] 改一处写回：%s；改回来与原文一致：%s"
          % ("OK" if changed else "FAILED", "OK" if model.text == before else "FAILED"))
    return 0 if (changed and model.text == before) else 1


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="unit_editor", description="DAEEM 单位编辑器（单位 / 建筑 / 科技数值）")
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
    return app_module.run(path, project_dir)


if __name__ == "__main__":
    raise SystemExit(main())
