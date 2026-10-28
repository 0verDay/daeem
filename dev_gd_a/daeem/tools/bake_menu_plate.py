#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bake_menu_plate.py —— 把「高塔倒塌」那张参考图烘成主菜单左侧的**雕版蒙版**。

用法（任意目录；默认路径按本文件位置接）：
    python tools/bake_menu_plate.py

    python tools/bake_menu_plate.py --src ../../art_draft/main_menu/menu_plate_src.jpg

产物：

    assets/menu/menu_plate.png            白线 + alpha 蒙版（运行时按主题上色）
    ../../art_draft/main_menu/menu_plate_preview.png   深底预览（只给人看）

★ 为什么只烘**蒙版**、不烘彩色图：
  线色必须跟着 `theme.palette.art_line` 走（换主题不用重烘）；而且彩色 JPEG
  里的暗蓝底会跟游戏的渐变底打架，蒙版则天然透明、只留线。
★ 为什么在离线烘、不在 shader 里现算：
  JPEG 的压缩噪点要靠中值滤波 + 亮温阈值才干净，那几样在 shader 里做不划算，
  而且运行时要的是「一张能直接采样的蒙版」，不是每帧重算一遍阈值。

⚠️ 这个脚本只是**开发期工具**（不进游戏、不参与 run-tests）：换了参考图就重跑。
"""

import argparse
import os
import sys

import numpy as np
from PIL import Image, ImageFilter

# ------------------------------------------------------------------
# 参数（改这里就能调「雕版」的味道）
# ------------------------------------------------------------------
# 裁剪框（相对原图，0~1）：从左边切掉缆索那一段，保住塔身与碎片；
# 右边留到边缘 —— 塔本来就被画框切掉了，让它继续从面板后面穿出去。
CROP_L = 0.33
CROP_T = 0.00
CROP_R = 1.00
CROP_B = 1.00

# 输出尺寸 = 1920 设计空间下左侧那块空白（1920 − 640）× 1080。
OUT_W = 1280
OUT_H = 1080

# 抽线：亮度阈值区间（低于 LO 全黑、高于 HI 全白）+ 暖色权重
# ★ 原图线芯亮度约 0.62~0.95，抗锯齿边缘 0.3~0.5，天光 0.12~0.2。
LO = 0.26
HI = 0.58
WARM_GAIN = 3.0          # (R−B) 每 1.0 折算成多少暖度；冷蓝天光会被压掉

MEDIAN = 3               # 中值滤波核（去 JPEG 雪花；3 = 只去孤立点）
SHARPEN = 1.0            # 缩放后的锐化强度（细线缩小时会糊）

# 原图四周那圈**双线画框**（源图坐标，约 11px 与 20px 两道）。
# ★ 不切掉的话，裁剪之后只剩三条边 —— 看着像画坏了，不像雕版。
FRAME_INSET_PX = 26

# 预览用的配色（只影响 preview.png，不影响产物）
PREVIEW_BG = (19, 25, 33)
PREVIEW_LINE = (216, 210, 188)


def _default_paths():
    here = os.path.abspath(os.path.dirname(__file__))
    project = os.path.abspath(os.path.join(here, ".."))          # dev_gd_a/daeem
    repo = os.path.abspath(os.path.join(project, "..", ".."))    # 仓库根
    return (os.path.join(repo, "art_draft", "main_menu", "menu_plate_src.jpg"),
            os.path.join(project, "assets", "menu", "menu_plate.png"),
            os.path.join(repo, "art_draft", "main_menu", "menu_plate_preview.png"))


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


def crop_and_fit(mask):
    """按 CROP_* 裁切 → 切掉原图那圈画框 → cover 到 OUT_W×OUT_H（等比，不拉歪）。"""
    w, h = mask.size
    box = (int(w * CROP_L), int(h * CROP_T), int(w * CROP_R), int(h * CROP_B))
    mask = mask.crop(box)
    fw, fh = mask.size
    inset = FRAME_INSET_PX
    if fw > inset * 4 and fh > inset * 4:
        mask = mask.crop((inset, inset, fw - inset, fh - inset))
    cw, ch = mask.size
    k = max(float(OUT_W) / cw, float(OUT_H) / ch)
    nw, nh = int(round(cw * k)), int(round(ch * k))
    mask = mask.resize((nw, nh), Image.LANCZOS)
    left = (nw - OUT_W) // 2
    top = (nh - OUT_H) // 2
    mask = mask.crop((left, top, left + OUT_W, top + OUT_H))
    if SHARPEN > 0:
        mask = mask.filter(ImageFilter.UnsharpMask(radius=0.8, percent=int(60 * SHARPEN), threshold=2))
    return mask


def main():
    default_src, default_out, default_preview = _default_paths()
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=default_src)
    ap.add_argument("--out", default=default_out)
    ap.add_argument("--preview", default=default_preview)
    args = ap.parse_args()

    if not os.path.isfile(args.src):
        raise SystemExit("找不到参考图：%s" % args.src)

    src = Image.open(args.src)
    print("source  : %s  %s" % (args.src, src.size))
    mask = build_mask(src)
    mask = crop_and_fit(mask)

    # 白线 + alpha：运行时由 shader 按主题上色，不把颜色烤死
    rgba = Image.new("RGBA", mask.size, (255, 255, 255, 0))
    rgba.putalpha(mask)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    rgba.save(args.out, "PNG", optimize=True)
    print("plate   : %s  %s  %.1f KB" % (args.out, rgba.size, os.path.getsize(args.out) / 1024.0))

    # 人工看的预览：深底 + 奶油线
    if args.preview:
        prev = Image.new("RGB", mask.size, PREVIEW_BG)
        prev.paste(PREVIEW_LINE, (0, 0), mask.split()[0].point(lambda v: v))
        os.makedirs(os.path.dirname(args.preview), exist_ok=True)
        prev.save(args.preview, "PNG", optimize=True)
        print("preview : %s" % args.preview)

    # 覆盖率：太低说明阈值抽狠了，太高说明把天光也吃进去了
    hist = mask.histogram()
    total = float(mask.size[0] * mask.size[1])
    lit = sum(hist[24:]) / total
    print("coverage: %.2f%%  (>24/255 的像素)" % (lit * 100.0))


if __name__ == "__main__":
    sys.exit(main())
