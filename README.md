# daeem

Dynasty And Empire : Eastern March

欲译为"王朝与帝国：东征"，是设想中"王朝与帝国"系列作品的第一部

现用ai进行开发，当前游戏名可能不是最终游戏名，本README为纯手搓，用于记录更新

## 开发者

- 轶名 @yuyi-yutie

## dev_html

（命名dev为develop版本）本版本为原型阶段html的开发，仅展示玩法

### 2026.9.17更新：联机对战（v0.4 → v0.6）

在原型上加上了**多人同屏对战**，用于快速验证玩法。架构是**房主权威 + 服务器中继**，
服务器用 Python 标准库手写 WebSocket，零第三方依赖。

**怎么玩：**

```powershell
py net\serve.py --port 8080          # 服务器上（局域网的话一台电脑就能当服务器）
```

| 谁 | 地址 |
|---|---|
| 房主（第 1 个打开的 → p1） | `http://<IP>:8080/rts-prototype.html#net=1` |
| 客机（其他人 → p2、p3…） | `http://<IP>:8080/rts-prototype.html#net=1&room=default` |
| 只看服务器活没活 | `http://<IP>:8080/health` |

流程：**双方都按 R 准备 → 房主宣布开战 → 倒数 3 秒 → 打掉对方大本营者胜**。
阵亡 8 秒后在自家大本营复活；一局结束后按 R 可以再来一局。

**文档：**

| 文档 | 内容 |
|---|---|
| [`dev_html/README.md`](dev_html/README.md) | 玩法、操作、目录结构、测试清单 |
| [`dev_html/net/README.md`](dev_html/net/README.md) | 部署与排错（安全组 / 防火墙 / 免备案端口 / 五项排查判据） |
| [`dev_html/docs/multiplayer.md`](dev_html/docs/multiplayer.md) | **联机设计文档**：架构决策、协议、踩坑记录、测试体系、未验证项 |
| [`dev_html/docs/CHANGELOG.md`](dev_html/docs/CHANGELOG.md) | 版本变更记录（v0.3 → v0.6） |

### 2026.9.12更新
1. 初始化了占位地图，加入了地块和区块的概念，加入了占点的基本玩法
2. 加入了基本的数字键选中编队逻辑和建造逻辑
3. 为单位加入了攻击和警戒逻辑
4. 初始化了基本的镜头逻辑
5. 目前单位寻路还存在问题，但无关紧要，放引擎里再优化

> 注：第 5 条已经解决 —— A* 只负责"绕开山/城墙走哪几个格子"，
> 再用超覆盖 DDA 判定把折线**拉直**（`js/path.js` 的 `smoothPath` / `segmentClear`），
> 所以开阔地带走直线，只有真的挡着东西才保留拐点。