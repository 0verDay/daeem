"""editor_ui/theme.py —— ttk 主题（clam）的统一配置。

★ 目标：**任何会漏出「原生浅色」的状态都要压回当前 token**。
  下拉 readonly / 勾选框 / 悬停 / 选中行 / 表头 / 输入框聚焦 —— 这些是 ttk
  默认主题最刺眼的地方，也是「一看就是 tkinter」的根源。

★ 只改 ttk 的**画法**，不改任何控件的布局与行为。
"""

from __future__ import annotations

import tkinter as tk
from tkinter import ttk
from typing import Dict

from . import dpi
from .tokens import FONT_BODY, FONT_SECTION, FONT_SMALL, FONT_TITLE


def enable_tree_hover(root: tk.Tk, ui: Dict[str, str]) -> None:
    """给**所有** Treeview 挂上「鼠标划过一行就提亮」的效果。

    ★ 为什么用 `bind_class`：表格散落在四个编辑器里（列表、侧栏、表单），
      逐个 bind 迟早漏一个；绑到 Tk 的 "Treeview" 类上，一次覆盖全部。
    ★ 只在「换了一行」时才改 tag —— <Motion> 触发得非常密，
      每像素都重打一次 tag 会让大表明显发黏。
    """
    if getattr(root, "_tree_hover_ready", False):
        return
    root._tree_hover_ready = True          # type: ignore[attr-defined]
    hover_bg = ui.get("row_hover", ui["hover"])

    def on_motion(event) -> None:
        tree = event.widget
        try:
            iid = tree.identify_row(int(event.y))
        except (tk.TclError, AttributeError):
            return
        prev = getattr(tree, "_hover_iid", None)
        if iid == prev:
            return
        if prev:
            try:
                tags = [t for t in tree.item(prev, "tags") if t != "hover"]
                tree.item(prev, tags=tags)
            except tk.TclError:
                pass
        tree._hover_iid = iid               # type: ignore[attr-defined]
        if not iid:
            return
        try:
            tree.tag_configure("hover", background=hover_bg)
            tags = [t for t in tree.item(iid, "tags") if t != "hover"]
            tree.item(iid, tags=tags + ["hover"])
        except tk.TclError:
            pass

    def on_leave(event) -> None:
        tree = event.widget
        prev = getattr(tree, "_hover_iid", None)
        if not prev:
            return
        try:
            tags = [t for t in tree.item(prev, "tags") if t != "hover"]
            tree.item(prev, tags=tags)
        except tk.TclError:
            pass
        tree._hover_iid = None              # type: ignore[attr-defined]

    root.bind_class("Treeview", "<Motion>", on_motion, add="+")
    root.bind_class("Treeview", "<Leave>", on_leave, add="+")


def apply_theme(root: tk.Tk, ui: Dict[str, str]) -> ttk.Style:
    # ★ 第一件事：量出这块屏的缩放（150% → 1.5），后面所有像素都乘它
    dpi.set_scale(dpi.measure(root))
    style = ttk.Style(root)
    try:
        style.theme_use("clam")
    except tk.TclError:
        pass

    bar = ui.get("bar", ui["bg"])
    panel, alt, bg = ui["panel"], ui["panel_alt"], ui["bg"]
    line = ui["line"]
    soft = ui.get("line_soft", line)
    text, soft_text, dim = ui["text"], ui.get("text_soft", ui["text"]), ui["text_dim"]
    accent = ui["accent"]
    hover, pressed = ui["hover"], ui["pressed"]
    sel_bg = ui.get("selection_bg", accent)
    sel_fg = ui.get("selection_fg", text)

    # ---- 基础 ----------------------------------------------------
    style.configure(".", background=panel, foreground=text, fieldbackground=alt,
                    bordercolor=line, lightcolor=panel, darkcolor=panel,
                    focuscolor=accent, troughcolor=bg, borderwidth=1)
    style.configure("TFrame", background=panel)
    style.configure("Bar.TFrame", background=bar)
    style.configure("Page.TFrame", background=bg)
    style.configure("Card.TFrame", background=panel)

    # ---- 文字 ----------------------------------------------------
    style.configure("TLabel", background=panel, foreground=text)
    style.configure("Bar.TLabel", background=bar, foreground=text)
    style.configure("Page.TLabel", background=bg, foreground=text)
    style.configure("Dim.TLabel", background=panel, foreground=dim)
    style.configure("Title.TLabel", background=panel, foreground=text,
                    font=FONT_TITLE)
    style.configure("Section.TLabel", background=panel, foreground=text,
                    font=FONT_SECTION)
    style.configure("Hint.TLabel", background=panel, foreground=dim,
                    font=FONT_SMALL)
    style.configure("Accent.TLabel", background=panel, foreground=accent)
    style.configure("Status.TLabel", background=bar, foreground=dim,
                    font=FONT_SMALL, padding=(dpi.px(14), dpi.px(5)))

    # ---- 输入 ----------------------------------------------------
    style.configure("TEntry", fieldbackground=alt, foreground=text, insertcolor=accent,
                    bordercolor=line, lightcolor=alt, darkcolor=alt,
                    borderwidth=1, relief="flat", padding=(dpi.px(8), dpi.px(5)))
    style.map("TEntry",
              fieldbackground=[("readonly", alt), ("disabled", panel)],
              foreground=[("disabled", dim)],
              selectbackground=[("!disabled", sel_bg)],
              selectforeground=[("!disabled", sel_fg)],
              bordercolor=[("focus", accent)],
              lightcolor=[("focus", accent)], darkcolor=[("focus", accent)])

    style.configure("TCombobox", fieldbackground=alt, background=alt, foreground=text,
                    arrowcolor=dim, bordercolor=line, lightcolor=alt, darkcolor=alt,
                    borderwidth=1, relief="flat", padding=(dpi.px(8), dpi.px(5)), arrowsize=dpi.px(12))
    style.map("TCombobox",
              fieldbackground=[("readonly", alt), ("disabled", panel)],
              background=[("readonly", alt), ("active", hover), ("disabled", panel)],
              foreground=[("readonly", text), ("disabled", dim)],
              arrowcolor=[("readonly", dim), ("active", accent)],
              selectbackground=[("readonly", alt), ("!disabled", sel_bg)],
              selectforeground=[("readonly", text), ("!disabled", sel_fg)],
              bordercolor=[("focus", accent)],
              lightcolor=[("focus", accent)], darkcolor=[("focus", accent)])
    for pattern, value in (("*TCombobox*Listbox.background", alt),
                           ("*TCombobox*Listbox.foreground", text),
                           ("*TCombobox*Listbox.selectBackground", sel_bg),
                           ("*TCombobox*Listbox.selectForeground", sel_fg),
                           ("*TCombobox*Listbox.borderWidth", "0"),
                           ("*TCombobox*Listbox.relief", "flat"),
                           ("*TCombobox*Listbox.font", FONT_BODY),
                           ("*TCombobox*Listbox.highlightThickness", "0")):
        root.option_add(pattern, value, "interactive")

    # ---- 表格 ----------------------------------------------------
    # ★ 行高 30：比旧版 28 松一点，数字表才不挤；表头用 dim + 小字号做「弱化」。
    style.configure("Treeview", background=panel, fieldbackground=panel,
                    foreground=soft_text, bordercolor=panel, lightcolor=panel,
                    darkcolor=panel, rowheight=dpi.px(30), borderwidth=0, relief="flat",
                    font=FONT_BODY)
    style.map("Treeview",
              background=[("selected", sel_bg), ("disabled", panel)],
              foreground=[("selected", sel_fg), ("disabled", dim)])
    style.configure("Treeview.Heading", background=panel, foreground=dim,
                    relief="flat", borderwidth=0, padding=(dpi.px(10), dpi.px(7)),
                    font=FONT_SMALL)
    style.map("Treeview.Heading",
              background=[("active", hover), ("pressed", pressed)],
              foreground=[("active", text)])
    style.layout("Treeview", [("Treeview.treearea", {"sticky": "nswe"})])

    # ---- 滚动条（默认不用，但别漏出浅色三角） ----------------------
    for orient in ("Vertical", "Horizontal"):
        style.configure("%s.TScrollbar" % orient, background=soft, troughcolor=bg,
                        bordercolor=bg, arrowcolor=dim, relief="flat",
                        borderwidth=0, width=8)
        style.map("%s.TScrollbar" % orient,
                  background=[("active", ui.get("hover", soft)),
                              ("pressed", pressed)],
                  arrowcolor=[("active", text)])

    # ---- 勾选 / 单选 ---------------------------------------------
    for name in ("TCheckbutton", "TRadiobutton"):
        style.configure(name, background=panel, foreground=soft_text,
                        focuscolor=panel, indicatorbackground=alt,
                        indicatorforeground=accent, upperbordercolor=line,
                        lowerbordercolor=line, padding=(dpi.px(2), dpi.px(2)))
        style.map(name,
                  background=[("active", panel)],
                  foreground=[("disabled", dim)],
                  indicatorbackground=[("selected", accent), ("active", hover),
                                       ("disabled", panel)],
                  indicatorforeground=[("selected", ui.get("accent_fg", "#ffffff"))])

    # ---- 按钮（编辑器基本用 PillButton，这里只兜底） ----------------
    style.configure("TButton", background=alt, foreground=text, bordercolor=line,
                    focuscolor=alt, padding=(dpi.px(12), dpi.px(6)), borderwidth=0, font=FONT_BODY)
    style.map("TButton",
              background=[("active", hover), ("pressed", pressed), ("disabled", panel)],
              foreground=[("disabled", dim)])
    style.configure("Accent.TButton", background=ui["accent_btn"],
                    foreground=ui["accent_fg"], font=FONT_BODY)
    style.map("Accent.TButton",
              background=[("active", ui["accent_btn_hover"])],
              foreground=[("disabled", dim)])

    style.configure("TNotebook", background=bg, borderwidth=0)
    style.configure("TNotebook.Tab", background=panel, foreground=dim, padding=(dpi.px(16), dpi.px(8)),
                    borderwidth=0, font=FONT_BODY)
    style.map("TNotebook.Tab",
              background=[("selected", alt), ("active", hover)],
              foreground=[("selected", accent)])
    style.configure("TSeparator", background=soft)
    style.configure("TScale", background=panel, troughcolor=alt)
    enable_tree_hover(root, ui)
    return style
