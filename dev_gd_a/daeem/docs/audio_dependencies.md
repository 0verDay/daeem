# 音效资源依赖记录

## 当前状态

游戏运行时已取消所有音效触发点与按钮音效挂接。音频文件及 Godot 的 `.import`
导入记录均保留在 `assets/sound/`；`view/sfx.gd` 也保留作旧依赖清单/实现参考，
但生产界面和游戏场景不再引用它。当前没有菜单点击、悬停、建造、战斗、冲锋或招募音效播放。

## 资源清单与原用途

| 文件 | 原用途 | 原播放入口 |
| --- | --- | --- |
| `assets/sound/click_button/down.wav` | 菜单点击 | `view/fill_button.gd` 的按钮挂接；开场、退出确认和进入关卡交互（`start_screen.gd`、`quit_confirm.gd`、`level_transition.gd`） |
| `assets/sound/click_button/hover.wav` | 菜单按钮悬停 | `view/fill_button.gd` 的悬停回调 |
| `assets/sound/build/build.wav` | 本方建筑建造 | `view/game_scene3d.gd` 的 `building_built` 事件处理 |
| `assets/sound/attack/bow/Bow Attack 1.wav` | 远程攻击 | `view/game_scene3d.gd` 的 `unit_attacked` 事件 |
| `assets/sound/attack/bow/Bow Attack 2.wav` | 远程攻击（随机变体） | 同上 |
| `assets/sound/attack/bow/Bow Impact Hit 1.wav` | 远程受击 | `view/game_scene3d.gd` 的 `unit_hit` / `building_hit` 事件 |
| `assets/sound/attack/bow/Bow Impact Hit 2.wav` | 远程受击（随机变体） | 同上 |
| `assets/sound/attack/bow/Bow Impact Hit 3.wav` | 远程受击（随机变体） | 同上 |
| `assets/sound/attack/sword/Sword Attack 1.wav` | 近战攻击 | `view/game_scene3d.gd` 的 `unit_attacked` 事件 |
| `assets/sound/attack/sword/Sword Attack 2.wav` | 近战攻击（随机变体） | 同上 |
| `assets/sound/attack/sword/Sword Attack 3.wav` | 近战攻击（随机变体） | 同上 |
| `assets/sound/attack/sword/Sword Impact Hit 1.wav` | 近战受击；原冲锋音也复用此组素材 | `view/game_scene3d.gd` 的 `unit_hit` / `building_hit` / `unit_charge` 事件 |
| `assets/sound/attack/sword/Sword Impact Hit 2.wav` | 近战受击（随机变体） | 同上 |
| `assets/sound/attack/sword/Sword Impact Hit 3.wav` | 近战受击（随机变体） | 同上 |
| `assets/sound/recruit/Sword Unsheath 1.wav` | 招募完成 | `view/game_scene3d.gd` 的 `unit_recruited` / `zone_unit_recruited` 事件 |
| `assets/sound/recruit/Sword Unsheath 2.wav` | 招募完成（随机变体） | 同上 |

## 解绑范围

- `fill_button.gd` 不再给按钮挂接音效，也不再在悬停时调用音效模块。
- 菜单、合作、备战、过渡与退出确认界面不再调用 `sfx.gd` 或标记音效子树。
- `game_scene3d.gd` 不再把建造、攻击/受击、冲锋与招募事件转发给音效模块；冲锋冲击波等纯视觉效果仍保留。
- 原有按钮挂接点还包括 `menu_back_button.gd`、`menu_banner.gd`、`menu_corner_hit.gd`、`menu_corner_button.gd`、`menu_text_button.gd`、`coop_map_card.gd`、`coop_ready_panel.gd`、`coop_room_panel.gd`、`prepare_faction_button.gd` 和 `prepare_panel.gd`；这些运行时挂接均已移除。
- 未删除音频文件、导入元数据或其他音频资源。
