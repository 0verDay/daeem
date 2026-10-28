# 编辑器「有用表」

## 一句话

地图编辑器、战役编辑器只显示**有用表**里的内容；表在：

`dev_gd_a/daeem/data/editor_visible.json`

```json
{
  "maps": ["main_test", "ai_test_2", "dscj"],
  "campaigns": ["demo"]
}
```

- 运行时**不读**这张表；它只控制编辑器界面。
- 文件缺失 / 写坏：编辑器回退为「不额外过滤」。
- 增删可见地图：改 `maps`；增删可见战役：改 `campaigns`。

## 地图编辑器

- 工具栏只有「可见地图」菜单 + 导出 / 新建；**不再提供手动选择文件导入**。
- 「可见地图」菜单按表里的 `maps` 生成，点击直接打开 `data/maps/<id>/` 里的地图文件。
- 导出到 `data/maps/<id>/map.json` 成功后，编辑器会**自动把 `<id>` 追加进表**并立刻刷新菜单。
- 导出到其它目录不会写表（避免把临时文件当正式图）。
- 高级 / 排障仍可用命令行：`python dev_gd_a/tools/map_editor --map <id>`。

## 战役编辑器

- 「战役」页的关卡树只列**关卡地图 ∈ 表 maps** 的关卡。
  - 当前表下：`mt / dscj / ai_test_2 / ai_test_battle`。
  - `01_beachhead / 02_twin_line / ai_test` 仍留在磁盘给运行时与测试，但不在树里。
- 「关卡」页地图下拉 = 表 maps 三张 + 当前关卡正在用的图（旧关卡不被改坏）；「新建关卡」只列三张。
- `--list` / 无参数启动 / `--selftest` 只列表 `campaigns` 里的战役（保留显式传目录的逃生口）。
- 保存战役成功后，编辑器自动把当前战役 id 追加进 `campaigns`；`--new` 同样会追加。
- 测试钩子：`EditorApp(..., show_all_levels=True)` 会跳过关卡树过滤（只给测试用）。

## 仍留在 `data/maps` 的旧图（不显示，但不能搬）

| 地图 | 仍被谁引用 |
|---|---|
| `frontier` | `logic/map_library.gd` 的默认图兜底；`tests/test_case.gd` 与大量测试；`tools/map_editor` 的测试样例 |
| `arena` | `tests/test_alliance.gd`、`tests/test_map_select.gd`、`tools/campaign_editor/test_model.py` |
| `dongzheng` | `demo` 的 `01_beachhead` / `02_twin_line`；大量合作测试；`tests/test_campaign.gd` |
| `ai_test` | `demo` 的 `ai_test` 关卡；`test_ai_commander` / `test_ai_observer` 的旧观战用例 |

要物理搬走它们，需要同步迁移上面的关卡、测试与默认值；当前只做编辑器层过滤。

## 已物理归档

`crossing` 地图 + `ferry` 战役这一对旧内容已经搬到仓库根 [`archive/`](../../archive/README.md)。
