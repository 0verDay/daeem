#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bake_menu_plate.py —— 把参考图烘成主菜单左侧轮播用的**雕版蒙版**。

用法（任意目录；默认路径按本文件位置接）：

    python tools/bake_menu_plate.py             # 两张都烘
    python tools/bake_menu_plate.py tall_tower  # 只烘某一张

产物（文字 = 表里的 key）：

    assets/menu/menu_plate.png              「高塔倒塌」：白线 + alpha 蒙版
    assets/menu/menu_plate_2.png            「堂吉诃德 + 风车」：同上
    ../../art_draft/main_menu/*_preview.png 深底预览（只给人看）

★ 为什么只烘**蒙版**、不烘彩色图：
  线色必须跟着 `theme.palette.accent` 走（换主题不用重烘）；而且彩色 JPEG
  里的暗蓝底会跟游戏的渐变底打架，蒙版则天然透明、只留线。
★ 为什么在离线烘、不在 shader 里现算：
  JPEG 的压缩噪点要靠中值滤波 + 亮温阈值才干净，那几样在 shader 里不划算，
  而且运行时要的是「一张能直接采样的蒙版」，不是每帧重算一遍阈值。

⚠️ 这个脚本只是**开发期工具**（不进游戏、不参与 run-tests）：换了参考图就重跑。
"""

import argparse
import os
import sys

import numpy as np
from PIL import Image, ImageFilter

# ------------------------------------------------------------------
# 每张图的参数（改这里就能调「雕版」的味道）
# ------------------------------------------------------------------
# crop：相对原图的裁剪框 (l, t, r, b)，0~1。
#   高塔那张：左边切掉缆索那一段，保住塔身与碎片；右边留到边缘。
#   风车那张：整幅都要（骑士在左、风车在右），不裁。
# out：输出尺寸。两张都烘成 **1280×1080**（= 1920 设计空间下左侧那块空白）——
#   运行时按 `menu.plate.fit` 铺满，宽度不是 1.185 的设备会再拉伸一次，
#   和第一张的处理方式完全一致（见 etched_plate.fit_rect 的说明）。
# frame：原图上那圈**双线画框**的内缩像素。高塔那张有（不切掉会只剩三条边，
#   像画坏了）；风车那张没有，填 0。
PLATES = {
    "tall_tower": {
        "src": "menu_plate_src.jpg",
        "out": "menu_plate.png",
        "preview": "menu_plate_preview.png",
        "crop": (0.33, 0.00, 1.00, 1.00),
        "size": (1280, 1080),
        "frame": 26,
    },
    "don_quixote": {
        "src": "plate2_src.jpg",
        "out": "menu_plate_2.png",
        "preview": "menu_plate_2_preview.png",
        "crop": (0.00, 0.00, 1.00, 1.00),
        "size": (1280, 1080),
        "frame": 0,
    },
}

# 抽线：亮度阈值区间（低于 LO 全黑、高于 HI 全白）+ 暖色权重
# ★ 原图线芯亮度约 0.62~0.95，抗锯齿边缘 0.3~0.5，天光 0.12~0.2。
LO = 0.26
HI = 0.58
WARM_GAIN = 3.0          # (R−B) 每 1.0 折算成多少暖度；冷蓝天光会被压掉

MEDIAN = 3               # 中值滤波核（去 JPEG 雪花；3 = 只去孤立点）
SHARPEN = 1.0            # 缩放后的锐化强度（细线缩小时会糊）

# 预览用的配色（只影响 preview.png，不影响产物）
PREVIEW_BG = (19, 25, 33)
PREVIEW_LINE = (216, 210, 188)


def _paths():
    here = os.path.abspath(os.path.dirname(__file__))
    project = os.path.abspath(os.path.join(here, ".."))          # dev_gd_a/daeem
    repo = os.path.abspath(os.path.join(project, "..", ".."))    # 仓库根
    return (os.path.join(repo, "art_draft", "main_menu"),
            os.path.join(project, "assets", "menu"))


def build_mask(img):
    """原图 → 0~255 的线蒙版（L 模式，同一尺寸）。"""
    arr = np.asarray(img.convert("RGB")).astype(np.float32) / 255.0
    lum = 0.2126 * arr[:, :, 0] + 0.7152 * arr[:, :, 1] + 0.0722 * arr[:, :, 2]
    span = max(1e-6, HI - LO)
    v = np.clip((lum - LO) / span, 0.0, 1.0)
    # 暖度：线是奶油金（R>B），天光是冷蓝（B>R）—— 用它把蓝辉光压掉
    warm = np.clip(0.5 + WARM_GAIN * (arr[:, :, 0] - arr[:, :, 2]), 0.0, 1.0)
    mask = Image.fromarray((v * warm * 255.0).astype(np.uint8), "L")
    return mask.filter(ImageFilter.MedianFilter(MEDIAN))


def crop_and_fit(mask, crop, size, frame):
    """按 crop 裁切 → 切掉画框 → cover 到 size（等比，不拉歪）。"""
    w, h = mask.size
    box = (int(w * crop[0]), int(h * crop[1]), int(w * crop[2]), int(h * crop[3]))
    mask = mask.crop(box)
    if frame > 0:
        fw, fh = mask.size
        if fw > frame * 4 and fh > frame * 4:
            mask = mask.crop((frame, frame, fw - frame, fh - frame))
    out_w, out_h = size
    cw, ch = mask.size
    k = max(float(out_w) / cw, float(out_h) / ch)
    nw, nh = int(round(cw * k)), int(round(ch * k))
    mask = mask.resize((nw, nh), Image.LANCZOS)
    left = (nw - out_w) // 2
    top = (nh - out_h) // 2
    mask = mask.crop((left, top, left + out_w, top + out_h))
    if SHARPEN > 0:
        mask = mask.filter(ImageFilter.UnsharpMask(radius=0.8,
                                                   percent=int(60 * SHARPEN),
                                                   threshold=2))
    return mask


def bake(name, src_dir, out_dir):
    spec = PLATES[name]
    src_path = os.path.join(src_dir, spec["src"])
    if not os.path.isfile(src_path):
        raise SystemExit("找不到参考图：%s" % src_path)
    out_path = os.path.join(out_dir, spec["out"])
    preview_path = os.path.join(src_dir, spec["preview"])

    src = Image.open(src_path)
    print("[%s] source  : %s  %s" % (name, src_path, src.size))
    mask = crop_and_fit(build_mask(src), spec["crop"], spec["size"], spec["frame"])

    # 白线 + alpha：运行时由 shader 按主题上色，不把颜色烤死
    rgba = Image.new("RGBA", mask.size, (255, 255, 255, 0))
    rgba.putalpha(mask)

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    rgba.save(out_path, "PNG", optimize=True)
    print("[%s] plate   : %s  %s  %.1f KB"
          % (name, out_path, rgba.size, os.path.getsize(out_path) / 1024.0))

    # 人工看的预览：深底 + 奶油线
    prev = Image.new("RGB", mask.size, PREVIEW_BG)
    prev.paste(PREVIEW_LINE, (0, 0), mask.split()[0].point(lambda v: v))
    prev.save(preview_path, "PNG", optimize=True)
    print("[%s] preview : %s" % (name, preview_path))

    # 覆盖率：太低说明阈值抽狠了，太高说明把天光也吃进去了
    hist = mask.histogram()
    total = float(mask.size[0] * mask.size[1])
    print("[%s] coverage: %.2f%%  (>24/255 的像素)" % (name, sum(hist[24:]) / total * 100.0))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="*", default=[],
                    help="要烘的图（%s）；留空 = 全部" % ", ".join(PLATES.keys()))
    args = ap.parse_args()
    names = args.names or list(PLATES.keys())
    for n in names:
        if n not in PLATES:
            raise SystemExit("未知的图：%s（可选：%s）" % (n, ", ".join(PLATES.keys())))
    src_dir, out_dir = _paths()
    for n in names:
        bake(n, src_dir, out_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
