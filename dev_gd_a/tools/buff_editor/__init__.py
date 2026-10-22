"""DAEEM buff 编辑器（Python + tkinter，零第三方依赖）。

它改的是**游戏唯一的数值表** `daeem/data/config.json` 里与 buff 有关的那些键
（目前是 `morale` 整段 + 共用的 `combat.damage_reduction_cap`）。
地图编辑器改地图、战役编辑器改关卡、单位编辑器改兵种 / 建筑 / 科技；
本工具只负责**buff 数值**，与它们各管一头。

跑法（在仓库根目录）：

    python dev_gd_a/tools/buff_editor                 # 直接改工程里的 config.json
    python dev_gd_a/tools/buff_editor 别的配置.json   # 改另一份（对照 / 试验用）
    python dev_gd_a/tools/buff_editor --selftest      # 不开窗口，跑一遍自检

双击 `buff_editor.bat` 也一样（与另外两个编辑器同一个入口习惯）。

模块划分：

    configfile.py  带注释 JSON 的**原地最小改动**读写（与 unit_editor 那份同一份拷贝）
    model.py       buff 字段表 / 解析 / 校验 / 悬停文案预览（无界面）
    app.py         tkinter 界面
"""

__all__ = ["configfile", "model", "app"]
