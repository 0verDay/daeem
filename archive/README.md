# 归档内容

本目录存放从 `dev_gd_a/daeem/data/` 收口的旧内容。运行时不再引用它们；如需恢复，用 `git mv` 搬回原路径即可。

## 已归档

| 归档路径 | 原路径 | 原因 |
|---|---|---|
| `archive/maps/crossing/` | `dev_gd_a/daeem/data/maps/crossing/` | 只被 `ferry` 战役使用；该战役不在当前战役菜单里 |
| `archive/campaigns/ferry/` | `dev_gd_a/daeem/data/campaigns/ferry/` | 旧战役「渡口争夺」，当前菜单与编辑器只保留 `demo` |

## 恢复

```powershell
git mv archive/maps/crossing dev_gd_a/daeem/data/maps/crossing
git mv archive/campaigns/ferry dev_gd_a/daeem/data/campaigns/ferry
```

## 为什么其它旧图没有一起搬走

`frontier / arena / dongzheng / ai_test` 仍被默认图兜底、旧关卡或测试直接引用。物理搬走会让默认图、旧关卡与测试大面积失效，所以它们**保留在 `data/maps`**，只从两个编辑器的可见列表里隐藏。

编辑器可见范围由 [`data/editor_visible.json`](../dev_gd_a/daeem/data/editor_visible.json) 控制：地图编辑器只列有用表里的地图，战役编辑器的关卡树只列使用这些地图的关卡。逐条引用说明见 [`../dev_gd_a/tools/README-editor-scope.md`](../dev_gd_a/tools/README-editor-scope.md)。
