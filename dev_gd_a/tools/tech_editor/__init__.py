"""DAEEM 科技编辑器（Python + tkinter，零第三方依赖）。

它改的是**游戏唯一的数值表** `daeem/data/config.json` 里 `tech.*` 那一块：
`tech.max_active` / `tech.gold_per_sec_by_tier`、`tech.list`（原生 9 条）、
`tech.clan_list`（王朝 / 帝国 + 两派共用），以及 `clan.list[].tech`
（每派科技页的 9 个槽位）。

地图编辑器改地图、战役编辑器改关卡、单位编辑器改兵种 / 建筑 / 特性；
本工具只负责**科技**，与它们各管一头。

跑法（在仓库根目录）：

    python dev_gd_a/tools/tech_editor                 # 直接改工程里的 config.json
    python dev_gd_a/tools/tech_editor 别的配置.json    # 改另一份（对照 / 试验用）
    python dev_gd_a/tools/tech_editor --selftest       # 不开窗口，跑一遍自检

双击 `tech_editor.bat` 也一样（与其它编辑器同一个入口习惯）。

模块划分：

    configfile.py  带注释 JSON 的**原地最小改动**读写（与 unit_editor 那份同一份拷贝）
    model.py       科技页面（现算）/ 效果键注册表 / 解析 / 校验 / 预览（无界面）
    app.py         tkinter 界面
"""

__all__ = ["configfile", "model", "app"]
