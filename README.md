# daeem

Dynasty And Empire : Eastern March

欲译为「王朝与帝国：东征」，是设想中「王朝与帝国」系列作品的第一部。

现用 AI 辅助开发，当前游戏名可能不是最终名称。本仓库是 Godot 原型，展示完整的局内玩法与 AI 指挥官。

- 开发者：轶名 [@yuyi-yutie](https://github.com/yuyi-yutie)

## 快速开始

1. 使用 **Godot 4.7.2 mono** 打开工程目录：

   ```text
   dev_gd_a/daeem
   ```

2. 首次运行前安装中文字体（否则 HUD / 日志会显示方框）：

   ```powershell
   powershell -ExecutionPolicy Bypass -File tools/setup-font.ps1
   ```

   > 在 `dev_gd_a/daeem` 目录下执行；脚本会把字体拷到 `assets/fonts/` 并执行一次 `--headless --import`。

3. 用编辑器运行，或直接启动主场景。

> 为什么必须用 mono：`logic/crowd/*.cs` 是 1000 单位群编的 C# 内核；普通版 Godot 不会加载 C# 程序集，会退回 GDScript 实现，性能差距约 200 倍，`test_csharp_bridge.gd` 也会失败。

## 目录结构

```text
.
├─ README.md / CHANGELOG.md
├─ ai_doc/                  # AI 现状、设计稿、参考规范
└─ dev_gd_a/daeem/          # Godot 工程根
   ├─ logic/                # 权威逻辑：世界、战斗、经济、AI、寻路、C# 群体内核
   ├─ view/                 # 表现层：HUD、3D 单位 / 建筑、输入、面板
   ├─ data/                 # 配置、地图、战役、关卡
   ├─ net/                  # 联机 / 合作
   ├─ server/               # 服务端
   ├─ tests/                # 无头测试（SceneTree 脚本）
   ├─ tools/                # 测试 / 字体 / 检查脚本
   └─ assets/               # 字体、模型、贴图等
```

## 已实现内容

- **占点与区划**：区划中心读条占领、区划经济（粮 / 金 / 人口）、区划特化、边界与守备。
- **建造与升级**：大本营 1~3 级、科技、箭塔、城墙、建筑升级；占领区禁止建造。
- **单位与战斗**：长枪兵、长弓兵、骑手、粮车、骑士、马弓手、投石车；护甲、攻城、范围伤害、移动射击、士气、受击整队反应、濒死将领保护。
- **将领系统**：招募、再起 / 召回、编制、将领特性、动态军队上限；升二本 / 三本分别要求 3 / 6 名将领。
- **合作模式**：真人队友或 AI 队友二选一；AI 队友支持行军 / 发展 / 扩张 / 屯兵四条指令。
- **AI 指挥官**：独立基地、资源、生产、建造、扩张、进攻、侦察、守备、巡逻；自主 `auto` 战略与难度包。
- **观战入口**：`ai_test`（只读观战）与 `ai_test_2`（可给 AI 下四条指令）。

## 开发者快捷键

| 快捷键 | 作用 |
|---|---|
| `Ctrl+1` | 本机阵营粮食 / 黄金 +1000 |
| `Ctrl+3` | 本机阵营大本营立即升到 3 级（免费；升级中则取消并退款） |
| `Ctrl+Q` | 合作模式测试：添加一个虚空队友 |
| `Ctrl+W` | 快速胜利 |
| `Ctrl+L` | 快速失败 |

## 测试

在 `dev_gd_a/daeem` 目录下：

```powershell
# 全量
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1

# 只跑某个测试
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_ai_commander

# 只列测试
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -List

# 只检查 GDScript 语法 / 编译
powershell -ExecutionPolicy Bypass -File tools/check-syntax.ps1
```

引擎路径优先取 `$env:GODOT_EXE`，否则使用本机 mono 版路径。完整约定见 [tools/README-tools.md](dev_gd_a/daeem/tools/README-tools.md)。

## 文档

- [更新记录](CHANGELOG.md)：按日期保留的历史变更。
- [AI 文档索引](ai_doc/README.md)：AI 现状、设计稿、参考规范。
- [AI 当前实现状态](ai_doc/ai-commander-current-status.md)：当前 AI 行为、配置与关键规则（优先阅读）。
- [AI 指挥官接入方案](ai_doc/ai-commander-integration-plan.md)：设计稿与早期实现记录。
- [Rusted Warfare AI 参考规范](ai_doc/rusted-warfare-ai-adaptation-spec.md)：外部参考，不是本作实现承诺。

## 说明

- 仓库同时保留了早期 HTML 原型的历史更新，见 [CHANGELOG.md](CHANGELOG.md) 的 `dev_html` 段。
- 地图、平衡数值与 AI 参数仍在迭代；以 `data/config.json` 和 `logic/ai_profile.gd` 的默认值为准。
