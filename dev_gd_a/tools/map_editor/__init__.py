"""DAEEM 地图编辑器（Python + tkinter，零第三方依赖）。

跑法（在仓库根目录）：

    python dev_gd_a/tools/map_editor            # 打开空地图
    python dev_gd_a/tools/map_editor 路径.json   # 直接打开一张地图

模块划分：

    model.py    数据层：地形 / 存在格 / 区块（无界面，可无头测试）
    mapfile.py  地图 JSON 的读写（Godot 格式，兼容旧地图）
    app.py      tkinter 界面
"""

__all__ = ["model", "mapfile", "app"]
