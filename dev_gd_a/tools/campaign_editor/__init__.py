"""DAEEM 战役编辑器（Python + tkinter，零第三方依赖）。

它管的是**战役与关卡**：谁参展、谁可玩、谁挂什么 AI、往哪打、开局摆放、目标与失败条件。
数据落在 `daeem/data/campaigns/<id>/`（`campaign.json` + `levels/*.json`）。

和另两个编辑器的分工（dev_plan_7 6.4）：

    `tools/map_editor/`    改地形 / 区划 / 中心 / 地图自带的大本营与守军（`data/maps/`）
    `tools/unit_editor/`   改兵种 / 建筑 / 科技数值（`data/config.json`）
    `tools/campaign_editor/`（本工具）改**战役与关卡**：只引用地图、只读配置

跑法（在仓库根目录）：

    python dev_gd_a/tools/campaign_editor                    # 打开上次/默认战役，没有就提示新建
    python dev_gd_a/tools/campaign_editor data/campaigns/demo # 直接开一个战役目录
    python dev_gd_a/tools/campaign_editor --new my_campaign   # 新建一个战役
    python dev_gd_a/tools/campaign_editor --selftest          # 不开窗口，跑数据层自检

双击 `campaign_editor.bat` 也一样（和另两个编辑器一个入口习惯）。

模块划分：

    model.py      战役 / 关卡 / AI 指派 / 目标与失败条件 + 那 16+4 条校验（**不 import tkinter**）
    levelfile.py  战役 / 关卡 JSON 的读写与往返（LF、无 BOM、未知字段原样带回）
    app.py        tkinter 界面（五个页签 + 画布 + 校验导出 + 一键跳地图编辑器）
"""

__all__ = ["model", "levelfile", "app"]
