"""DAEEM 单位编辑器（Python + tkinter，零第三方依赖）。

它改的是**数值**：`daeem/data/config.json`（游戏侧 `logic/config.gd` 读的那一份）。
地图编辑器（`tools/map_editor/`）改的是 `data/test_map.json` —— 两个工具各管一头。

跑法（在仓库根目录）：

    python dev_gd_a/tools/unit_editor                 # 直接改工程里的 config.json
    python dev_gd_a/tools/unit_editor 别的配置.json   # 改另一份（对照 / 试验用）
    python dev_gd_a/tools/unit_editor --selftest      # 不开窗口，跑一遍自检

双击 `unit_editor.bat` 也一样（和地图编辑器一个入口习惯）。

模块划分：

    configfile.py  带注释 JSON 的**原地最小改动**读写（只管文本与位置）
    model.py       单位 / 将领 / 建筑 / 科技的语义与校验（无界面）
    app.py         tkinter 界面
"""

__all__ = ["configfile", "model", "app"]
