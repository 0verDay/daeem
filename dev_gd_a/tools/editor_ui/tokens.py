"""editor_ui/tokens.py —— 四个编辑器共用的设计令牌（纯数据，零依赖）。

★ 2026.11 改版：从「暗色游戏工具」升级成**暖金深色 Web 卡片风**。
  · 表面分三层：`bg`（页面底）→ `panel`（卡片）→ `panel_alt`（输入框 / 次级块）。
    三层必须**互不相同**，暗色下卡片才浮得起来（旧版 panel 与 bg 太近，看着是一张平图）。
  · `line` 是「发丝边框」：1px、低对比，负责勾出卡片轮廓；阴影只做很轻的一层。
  · 金色只用在**当前状态**（选中页签、主按钮、图表高亮），不做大面积铺底。

★ 只放**颜色 / 字体 / 间距 / 圆角 / 时长**，不放任何控件逻辑。
"""

from __future__ import annotations

from typing import Dict, Tuple

#: 中文界面优先用系统自带的雅黑；没有时 tk 会自动回退。
FONT_FAMILY = "Microsoft YaHei UI"
FONT_MONO = "Consolas"

#: 字号层级（tk 的 font 是 tuple，直接用）。
FONT_TINY: Tuple[str, int] = (FONT_FAMILY, 8)
FONT_SMALL: Tuple[str, int] = (FONT_FAMILY, 9)
FONT_BODY: Tuple[str, int] = (FONT_FAMILY, 10)
FONT_TITLE: Tuple[str, int, str] = (FONT_FAMILY, 14, "bold")
FONT_SECTION: Tuple[str, int, str] = (FONT_FAMILY, 10, "bold")
FONT_BRAND: Tuple[str, int, str] = (FONT_FAMILY, 12, "bold")
FONT_NUM: Tuple[str, int] = (FONT_MONO, 9)

#: 8px 栅格（与 Web UI 的 spacing scale 同一套）。
SPACE_XS = 4
SPACE_S = 8
SPACE_M = 12
SPACE_L = 16
SPACE_XL = 24

#: 圆角阶梯。
RADIUS_XS = 6
RADIUS_S = 8
RADIUS_M = 10
RADIUS_L = 16       # 卡片圆角
RADIUS_XL = 18

#: 常用尺寸（px）。
TOPBAR_H = 60
TABBAR_H = 44
STATUSBAR_H = 30
CARD_PAD = 18       # 卡片内边距
GAP = 14            # 卡片之间的缝
SIDEBAR_W = 360     # 右侧栏宽度（旧版 320 太窄，卡片标题被挤断行）

#: 动效时长（毫秒）。集中放这里，四个编辑器节奏才一致。
DUR_FAST = 90
DUR_BASE = 150
DUR_SLOW = 240
FRAME_MS = 16

#: 卡片 / 分区标题的彩色池。同一个标题永远拿同一个颜色（按标题 CRC 取模），
#: 所以重建侧边栏时颜色不会跳来跳去。
CARD_COLORS = (
    "#f2b544",   # 琥珀
    "#5aa9ff",   # 天蓝
    "#4fd18b",   # 薄荷绿
    "#e05ad0",   # 品红
    "#ff8a4c",   # 橙
    "#a78bfa",   # 紫
    "#4dd6e8",   # 青
    "#ff6b6b",   # 珊瑚红
)


#: ★ 当前默认：暖金深色（与 `ref_B` 参考图一致）。
#:
#: 语义与旧 `UI` 完全兼容（键名一个不少），所以老代码 `UI["panel"]` 不用改。
#: 新增的键（bar / surface2 / text_soft / row_hover ...）供新组件使用。
DARK: Dict[str, str] = {
    "bar": "#0b1016",           # 顶栏 / 状态栏（比页面底再深一档）
    "bg": "#0a0e13",            # 页面底 / 侧栏「井」
    "panel": "#121a23",         # 卡片（浮起一档）
    "surface2": "#18222d",      # 卡片内的次级块 / 输入框
    "panel_alt": "#18222d",     # 旧键名，等同 surface2
    "line": "#24303d",          # 发丝边框
    "line_soft": "#1b2532",     # 更弱的分隔线（卡片内部）
    "text": "#e7eef5",
    "text_soft": "#c2cedb",     # 正文（比纯白柔一档）
    "text_dim": "#8795a6",
    "accent": "#f2b544",        # 主题金：只用在「当前状态」
    "accent_btn": "#f2b544",
    "accent_btn_hover": "#ffcb63",
    "accent_soft": "#3a2f16",   # 金色的淡底（选中行 / 徽标底）
    "accent_fg": "#17120a",     # 金底上的深色字
    "danger_btn": "#c4474c",
    "danger_btn_hover": "#d95a5f",
    "danger_soft": "#2b1618",
    "danger_line": "#4c2427",
    "danger_fg": "#ffffff",
    "hover": "#1e2936",         # 悬停底色
    "pressed": "#243141",
    "selection_bg": "#3a2f16",  # 列表选中（淡金底，不刺眼）
    "selection_fg": "#f7e9c6",
    "row_hover": "#16202b",     # 鼠标划过一行
    "canvas_bg": "#0c1218",
    "empty": "#0e151c",
    "empty_line": "#24303d",
    "shadow": "#05080b",        # 卡片阴影（只做一层很轻的）
    "center": "#d24bc4",        # 区划中心标记（品红）
    "ok": "#3fb950",
    "warn": "#d29922",
    "bad": "#f87171",
}


#: 浅色 Notion / Figma 风（保留给以后的切换；`ref_C` 那一套）。
LIGHT: Dict[str, str] = {
    "bar": "#ffffff",           # 顶栏 / 状态栏
    "bg": "#f6f6f3",            # 页面底（近白，卡片才浮得起来）
    "panel": "#ffffff",         # 卡片
    "surface2": "#f2f2ee",      # 卡内块 / 输入框
    "panel_alt": "#f2f2ee",
    "line": "#e4e4dd",          # 发丝边框
    "line_soft": "#eeeeea",
    "text": "#1f211e",
    "text_soft": "#3f423c",
    "text_dim": "#6f7169",
    "accent": "#2f6feb",
    "accent_btn": "#2f6feb",
    "accent_btn_hover": "#4a86f6",
    "accent_soft": "#e9efff",
    "accent_fg": "#ffffff",
    "danger_btn": "#d64545",
    "danger_btn_hover": "#e35c5c",
    "danger_soft": "#fdeeee",
    "danger_line": "#f3d2d2",
    "danger_fg": "#ffffff",
    "hover": "#f0f0ea",
    "pressed": "#e6e6df",
    "selection_bg": "#dfe9ff",
    "selection_fg": "#14306b",
    "row_hover": "#f7f7f3",
    "canvas_bg": "#eef0f3",
    "empty": "#fbfbf8",
    "empty_line": "#d8d8d0",
    "shadow": "#7d7d72",        # 投影色（按 alpha 与底色混合）
    "center": "#c026a3",
    "ok": "#1f9d55",
    "warn": "#b7791f",
    "bad": "#d64545",
}


NEUTRAL: Dict[str, str] = {
    "bar": "#ffffff",
    "bg": "#fafafa",
    "panel": "#ffffff",
    "surface2": "#f4f4f5",
    "panel_alt": "#f4f4f5",
    "line": "#e4e4e7",
    "line_soft": "#f0f0f2",
    "text": "#18181b",
    "text_soft": "#3f3f46",
    "text_dim": "#71717a",
    "accent": "#2563eb",
    "accent_btn": "#2563eb",
    "accent_btn_hover": "#3b82f6",
    "accent_soft": "#eff4ff",
    "accent_fg": "#ffffff",
    "danger_btn": "#dc2626",
    "danger_btn_hover": "#ef4444",
    "danger_soft": "#fef2f2",
    "danger_line": "#fecaca",
    "danger_fg": "#ffffff",
    "hover": "#f4f4f5",
    "pressed": "#e4e4e7",
    "selection_bg": "#eff4ff",
    "selection_fg": "#1e3a8a",
    "row_hover": "#fafafa",
    "canvas_bg": "#f4f4f5",
    "empty": "#fafafa",
    "empty_line": "#d4d4d8",
    "shadow": "#a1a1aa",
    "center": "#c026a3",
    "ok": "#16a34a",
    "warn": "#ca8a04",
    "bad": "#dc2626",
}

PRESETS = {"dark": DARK, "light": LIGHT, "neutral": NEUTRAL}

#: 默认外观。`DAEEM_EDITOR_THEME=dark|light|neutral` 可以临时改回来。
DEFAULT_PRESET = "light"


def default_preset() -> Dict[str, str]:
    """四个编辑器启动时取的那一份令牌。"""
    import os

    name = (os.environ.get("DAEEM_EDITOR_THEME") or DEFAULT_PRESET).strip().lower()
    return PRESETS.get(name, LIGHT)
