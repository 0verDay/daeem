# editor_ui —— 四个编辑器共用的「暖金深色 Web 卡片」主题层

四个编辑器（map / campaign / unit / tech）都从这里取样式，**改一处四个窗口一起变**。
默认外观是**浅色（白卡片 + 暖灰底）**；`DAEEM_EDITOR_THEME=dark|light|neutral` 可切回深色。
依赖：tkinter（标准库）+ **Pillow（可选）**。没装 Pillow 时圆角退回多边形画法，功能不受影响。

## 用哪几个入口

```python
from editor_ui import apply_theme, EditorShell, make_card, list_card, PillButton

apply_theme(root, UI)          # 启动时一次：量 DPI、压 ttk、挂行悬停
shell = EditorShell(root, ...) # 顶栏（品牌 + 下划线页签 + 右侧动作）+ 内容区 + 状态栏
body = make_card(sidebar, "分区标题", hint="…")        # 侧栏卡片，返回内容 frame
table = list_card(host, "兵种", kicker="共 8 条")      # 主区表格卡片（撑满，用 .body）
```

## 圆角是怎么画的（重点）

Tk 没有 `border-radius`，Canvas 画多边形也不抗锯齿。这里用 **9 宫格 + 图片**：

1. `paint.corner_photos()` 用 Pillow 在 2 倍超采样下画一个圆角扇形，LANCZOS 缩回，
   得到带 alpha 的四个角（其余三角用 `transpose` 翻转，成本为零）；
2. 角的图片**按 (半径, 填充色, 描边色, DPI) 缓存**，全应用复用；
3. `paint.draw_rounded_x()` 把四角贴上去，中间用普通矩形 + 4 条 1px 直线补满。

这样四角是**真透明**（不是把角涂成父容器底色），且成本与尺寸无关：

| 方案 | 900×300 卡片 | 备注 |
|---|---|---|
| 旧：`create_polygon(smooth=True)` | ~0 ms | 边缘有台阶 |
| 整图渲染（首版） | ~150 ms | 拉窗口会卡 |
| **9 宫格（现在）** | **~3 ms 首张 / 0.05 ms 复用** | 抗锯齿、真透明 |

小控件（按钮、勾选框）直接用整张小图（`paint.rounded_photo`），尺寸小、代价可忽略。

## 高 DPI

`dpi.py` 负责两件事：

- `enable_high_dpi()`：在 `tk.Tk()` **之前**声明 per-monitor DPI 感知。
  不声明的话，Windows 会把 150% 缩放下的窗口当位图拉伸 → 文字/圆角全糊。
  四个编辑器的 `run()` 里都调了；**测试不调**，所以测试环境缩放恒为 1.0，断言不受影响。
- `px(n) / pxf(n)`：把「设计稿像素」换成当前 DPI 下的像素。
  结构性尺寸（窗口、侧栏宽度、表格列宽、圆角、内边距、wraplength、行高）都走它。

## 视觉规则

| 层级 | 令牌 | 用途 |
|---|---|---|
| 页面底 | `bg` `#0a0e13` | 窗口底 / 侧栏「井」 |
| 卡片 | `panel` `#121a23` | 卡片、面板 |
| 卡内块 | `surface2` / `panel_alt` `#18222d` | 输入框、次级按钮 |
| 发丝边框 | `line` `#24303d` / `line_soft` | 卡片描边 / 卡内分隔线 |
| 当前状态 | `accent` `#f2b544` | 选中页签、主按钮、列表选中 |

- **强调色只用于「当前状态」**（选中页签 / 主按钮 / 选中行），不要铺底色。
- 卡片投影由 `paint.draw_rounded_x(shadow=(dy, spread, strength, color, bg))` 画：
  由外向内叠 `spread` 层 9 宫格，颜色从底色渐变到投影色。浅色底上这是标准网页投影，
  深色底上会自动淡到几乎看不见（同一份代码，不用换主题就换样式）。

## 几个必要的坑（都踩过）

1. `tk.Canvas` 的默认 `-height` 是 **`"7c"`（约 264px）**，不显式给 1 会把父容器撑高。
2. `pack` 是「先到先得」：**固定宽度的那一侧要先 pack**，否则主区 Treeview 的请求宽度会把侧栏挤成一条缝。
3. `RoundedPanel` 的内容是 `place` 上去的，Frame 自己请求 1×1 —— 按内容高度排要调 `fit_to_content()`。
4. Tk 9 的 clam 主题把「勾选」画成一个**叉**；`CheckBox` 因此自绘指示器，但仍是 `ttk.Checkbutton` 子类。
5. 动效统一走 `motion.py`；**测试里默认关闭**（`motion._auto_enabled`），别在回调里假设窗口还活着。
6. Pillow 的 `PhotoImage` 绑在某个 Tk 解释器上：缓存必须挂在 `root` 上（测试会反复建/销毁窗口），
   否则会拿到「已销毁解释器」的图片。
7. **`tk.Button` 的子控件在 Tk 9 下不会被绘制**。把 Canvas 盖在 Button 上做圆角，
   在 Frame 上正常、在 Button 上完全不可见（表现就是「按钮永远是方的」）。
   `PillButton` 因此改成把圆角图设为按钮自己的 `image` + `compound="center"`，
   文字由 Tk 画在图上；`invoke` / `cget` / `configure` 语义不变。
8. 勾选框同理：对勾不要用 `create_line` 画（14px 下 1.8px 直线会糊），
   整块（圆角方块 + 对勾）一次性栅格化成图片，见 `paint.check_photo()`。


## 性能（地图编辑器）

拖动画面（中键 / 空格 + 左键）**不要**每个 motion 事件都全量重绘：
重绘一次要重建约 2000 个图元（实测 13ms），一秒上百个事件就是幻灯片。

现在的做法（`map_editor/app.py` 的 `pan_step` / `pan_finish`）：

1. 拖动时只 `canvas.move("all", dx, dy)`（一次性挪图元，~1ms），再把底色矩形
   重新铺满画布；
2. 累计位移到 **2 格**才补一次真重绘，把新露出的边补上；
3. 重绘范围带 `OVERSCAN = 3` 格余量，所以挪动过程中看不到空白；
4. 松手 `pan_finish()` 同步补一次完整重绘（不用等 `after`，也不会弹回原位）。

实测：60 个拖拽步从 ~780ms 降到 ~158ms（约 5 倍）。
