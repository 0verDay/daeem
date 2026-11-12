"""抓取正在运行的 Godot 游戏窗口（PrintWindow），并可移动 / 点击鼠标。

用法：
    python .ui-preview/game_capture.py out.png
    python .ui-preview/game_capture.py out.png --hover 960 300
"""

from __future__ import annotations

import argparse
import ctypes
import time
from ctypes import wintypes
from pathlib import Path

from PIL import Image

user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)

PW_RENDERFULLCONTENT = 0x00000002
DIB_RGB_COLORS = 0
TITLE_PREFIX = "DAEEM"


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


def find_hwnd(title_prefix: str = TITLE_PREFIX) -> int:
    found: list[int] = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def cb(hwnd, _lparam):
        length = user32.GetWindowTextLengthW(hwnd)
        if length <= 0:
            return True
        buf = ctypes.create_unicode_buffer(length + 1)
        user32.GetWindowTextW(hwnd, buf, length + 1)
        if buf.value.startswith(title_prefix):
            found.append(hwnd)
        return True

    user32.EnumWindows(cb, 0)
    if not found:
        raise RuntimeError("game window not found")
    return found[0]


def client_rect(hwnd: int) -> tuple[int, int, int, int]:
    wrect = wintypes.RECT()
    crect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(wrect))
    user32.GetClientRect(hwnd, ctypes.byref(crect))
    pt = wintypes.POINT(0, 0)
    user32.ClientToScreen(hwnd, ctypes.byref(pt))
    off_x, off_y = pt.x - wrect.left, pt.y - wrect.top
    return wrect.left, wrect.top, off_x, off_y, crect.right, crect.bottom


def grab(hwnd: int) -> Image.Image:
    wrect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(wrect))
    w, h = wrect.right - wrect.left, wrect.bottom - wrect.top
    hdc = user32.GetWindowDC(hwnd)
    memdc = gdi32.CreateCompatibleDC(hdc)
    bmp = gdi32.CreateCompatibleBitmap(hdc, w, h)
    old = gdi32.SelectObject(memdc, bmp)
    ok = user32.PrintWindow(hwnd, memdc, PW_RENDERFULLCONTENT)
    if not ok:
        user32.PrintWindow(hwnd, memdc, 0)

    bi = BITMAPINFO()
    bi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    bi.bmiHeader.biWidth = w
    bi.bmiHeader.biHeight = -h
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


def grab_client(hwnd: int, crop_title: bool = True) -> Image.Image:
    left, top, off_x, off_y, cw, ch = client_rect(hwnd)
    img = grab(hwnd)
    if crop_title:
        return img.crop((off_x, off_y, off_x + cw, off_y + ch))
    return img


def screen_to_client(hwnd: int, x: int, y: int) -> tuple[int, int]:
    pt = wintypes.POINT(x, y)
    user32.ScreenToClient(hwnd, ctypes.byref(pt))
    return pt.x, pt.y


def client_to_screen(hwnd: int, x: int, y: int) -> tuple[int, int]:
    pt = wintypes.POINT(x, y)
    user32.ClientToScreen(hwnd, ctypes.byref(pt))
    return pt.x, pt.y


def focus(hwnd: int) -> None:
    user32.ShowWindow(hwnd, 9)  # SW_RESTORE
    user32.SetForegroundWindow(hwnd)


def move_mouse(hwnd: int, x: int, y: int) -> None:
    focus(hwnd)
    sx, sy = client_to_screen(hwnd, x, y)
    user32.SetCursorPos(sx, sy)


def click(hwnd: int, x: int, y: int, settle: float = 0.25) -> None:
    focus(hwnd)
    move_mouse(hwnd, x, y)
    time.sleep(settle)
    sx, sy = client_to_screen(hwnd, x, y)
    user32.mouse_event(0x0002, 0, 0, 0, 0)  # LEFTDOWN
    time.sleep(0.05)
    user32.mouse_event(0x0004, 0, 0, 0, 0)  # LEFTUP
    time.sleep(settle)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--hover", nargs=2, type=int)
    ap.add_argument("--click", nargs=2, type=int)
    ap.add_argument("--title", default=TITLE_PREFIX)
    args = ap.parse_args()

    hwnd = find_hwnd(args.title)
    if args.click:
        click(hwnd, *args.click)
    elif args.hover:
        move_mouse(hwnd, *args.hover)
        time.sleep(0.5)
    time.sleep(0.35)
    img = grab_client(hwnd)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out)
    print("saved", out, img.size)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
