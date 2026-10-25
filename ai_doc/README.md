# AI 文档索引

本目录区分「当前事实」「设计方案」和「外部参考」，避免把历史计划当成现状。

## 阅读顺序

1. [AI 指挥官当前实现状态](ai-commander-current-status.md)  
   **先读这篇。** 当前代码实际行为、资源顺序、开局规则、占领 / 索敌 / 防抽搐策略、配置入口和测试基线。

2. [AI 指挥官接入方案](ai-commander-integration-plan.md)  
   设计稿与早期实现记录。包含模块职责、每 tick 顺序、状态归属、经济 / 生产 / 军队 / 建造设计，以及 2026.10.24 前后的落地过程。  
   ⚠️ 文中的旧测试数字、旧行为描述可能已被后续改动覆盖，以「当前实现状态」和代码为准。

3. [Rusted Warfare AI 参考规范](rusted-warfare-ai-adaptation-spec.md)  
   外部参考与本地化映射，不是本作的实现承诺；实际以 `logic/ai_*.gd` 为准。

4. [AI 系统参考页](rusted-warfare-ai-system.html)  
   原始 HTML 资料，仅作查阅。

## 相关文档

- [项目 README](../README.md)：快速开始、目录、测试、快捷键。
- [更新记录](../CHANGELOG.md)：按日期保留的全部变更。
- [tools/README-tools.md](../dev_gd_a/daeem/tools/README-tools.md)：测试 / 字体 / 语法检查脚本的约定。

## 维护约定

- **代码是最终事实**：规则冲突时，以 `dev_gd_a/daeem/logic/ai_*.gd`、`logic/upgrade.gd`、`data/config.json` 为准。
- 改了 AI 行为，至少同步：
  1. 本目录的「当前实现状态」；
  2. 根目录 `CHANGELOG.md`；
  3. 对应测试或新增测试。
- 「设计稿」只记录为什么这样做；不要把所有增量都继续堆到设计稿末尾。
