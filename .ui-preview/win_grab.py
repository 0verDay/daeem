"""用 Win32 PrintWindow 抓取被遮挡的 Tk 窗口（不依赖桌面可见性）。"""

from __future__ import annotations

import ctypes
import time
import tkinter as tk
from ctypes import wintypes

from PIL import Image

user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)

GA_ROOT = 2
PW_RENDERFULLCONTENT = 0x00000002
DIB_RGB_COLORS = 0


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize", wintypes.DWORD),
        ("biWidth", wintypes.LONG),
        ("biHeight", wintypes.LONG),
        ("biPlanes", wintypes.WORD),
        ("biBitCount", wintypes.WORD),
        ("biCompression", wintypes.DWORD),
        ("biSizeImage", wintypes.DWORD),
        ("biXPelsPerMeter", wintypes.LONG),
        ("biYPelsPerMeter", wintypes.LONG),
        ("biClrUsed", wintypes.DWORD),
        ("biClrImportant", wintypes.DWORD),
    ]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER), ("bmiColors", wintypes.DWORD * 3)]


def grab_window(root: tk.Tk) -> Image.Image:
    """把顶层窗口的真实像素抓成 PIL Image（被遮挡也行）。"""
    user32.GetAncestor.restype = wintypes.HWND
    hwnd = user32.GetAncestor(root.winfo_id(), GA_ROOT)
    rect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    w, h = rect.right - rect.left, rect.bottom - rect.top
    if w <= 0 or h <= 0:
        raise RuntimeError("window has no size")

    hdc = user32.GetWindowDC(hwnd)
    memdc = gdi32.CreateCompatibleDC(hdc)
    bmp = gdi32.CreateCompatibleBitmap(hdc, w, h)
    old = gdi32.SelectObject(memdc, bmp)
    ok = user32.PrintWindow(hwnd, memdc, PW_RENDERFULLCONTENT)
    if not ok:
        # 老系统不支持 PW_RENDERFULLCONTENT 时退回 0
        user32.PrintWindow(hwnd, memdc, 0)

    bi = BITMAPINFO()
    bi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    bi.bmiHeader.biWidth = w
    bi.bmiHeader.biHeight = -h  # 负值 = 自上而下，省一次翻转
    bi.bmiHeader.biPlanes = 1
    bi.bmiHeader.biBitCount = 32
    bi.bmiHeader.biCompression = 0

    buf = ctypes.create_string_buffer(w * h * 4)
    gdi32.GetDIBits(memdc, bmp, 0, h, buf, ctypes.byref(bi), DIB_RGB_COLORS)

    gdi32.SelectObject(memdc, old)
    gdi32.DeleteObject(bmp)
    gdi32.DeleteDC(memdc)
    user32.ReleaseDC(hwnd, hdc)

    return Image.frombuffer("RGB", (w, h), buf, "raw", "BGRX", 0, 1)


def grab_client(root: tk.Tk) -> Image.Image:
    """只取窗口**客户区**（去掉标题栏与边框）。"""
    user32.GetAncestor.restype = wintypes.HWND
    hwnd = user32.GetAncestor(root.winfo_id(), GA_ROOT)

    wrect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(wrect))
    crect = wintypes.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(crect))
    pt = wintypes.POINT(0, 0)
    user32.ClientToScreen(hwnd, ctypes.byref(pt))
    off_x, off_y = pt.x - wrect.left, pt.y - wrect.top

    img = grab_window(root)
    box = (off_x, off_y, off_x + crect.right, off_y + crect.bottom)
    return img.crop(box)


def settle(root: tk.Tk, rounds: int = 10) -> None:
    for _ in range(rounds):
        root.update_idletasks()
        root.update()
        time.sleep(0.05)


if __name__ == "__main__":
    root = tk.Tk()
    root.geometry("460x260+80+80")
    root.configure(bg="#ff0088")
    tk.Label(root, text="PRINTWINDOW OK", bg="#ff0088", fg="white",
             font=("Arial", 26)).pack(expand=True)
    settle(root)
    img = grab_window(root)
    img.save(".ui-preview/_printwindow_probe.png")
    print("saved", img.size, "corner", img.getpixel((8, 8)), "center", img.getpixel((230, 130)))
    root.destroy()
