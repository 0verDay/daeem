#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bake_unit_sprites.py —— 把 art_draft/test_assets 的占位美术烘成**游戏内 3D 立牌贴图**。

用法（任意目录都行；默认路径按本文件位置推）：

    python tools/bake_unit_sprites.py

    python tools/bake_unit_sprites.py --src ../../../art_draft/test_assets

产物（都写进工程的 assets/test_units/）：

    SpearMan/spearman.png      人 + 剑（剑当长枪用，用户口径「人物带剑 → 长枪兵」）
    LongbowMan/longbowman.png  人 + 弓
    Rider/rider.png            原画「骑手」  ┐
    GrainCart/grain_cart.png   原画「粮车」  │ art_draft 根目录的整张原画（直接拷贝）
    Knight/knight.png          原画「骑士」  │
    HorseArcher/horse_archer.png 原画「马弓手」│
    Catapult/catapult.png      原画「投石车」┘
    Projectile/arrow.png       箭（原样拷贝；投射物用）

★ 只有**形状与颜色**写进 PNG；阵营色描边、选中金描边都由运行时按阵营烘
  （MultiMesh 一批共用一张图，见 view/unit_sprite_3d.gd 与 view/unit_view_3d.gd）。
★ 运行时按兵种立牌比例生成画布（步兵 1×1 / 骑兵 1×1.5 / 器械 2×1，基准 64×96，
  与 unit_sprite_3d.gd 的 TEX_W / TEX_H 同一像素密度）；这里输出更高分辨率的原图，
  运行时再 contain-fit 并逐像素烘描边。
★ 单字永远从 config.json 现读 —— 改了「地图上的字」重跑本脚本即可，不会两处不一致。

⚠️ 这个脚本只是**开发期工具**（不进游戏、不参与 run-tests）：改了 art_draft 里的素材就重跑。
"""

import argparse
import io
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

# ------------------------------------------------------------------
# 合成参数（改这里就能调姿势；单位都是「合成画布」的像素）
# ------------------------------------------------------------------
CANVAS_W = 420
CANVAS_H = 400
PERSON_H = 360            # 人物在合成画布上的高度（源图 175×239 等比放大）
SWORD_H = 300             # 剑的长度
SWORD_DX = 0.35           # 剑柄的横向位置（0 = 人物左缘，1 = 人物右缘）
SWORD_DY = 0.85           # 剑柄的纵向位置（0 = 人物底边，1 = 人物顶边）
BOW_H = 300
BOW_DX = 0.72
BOW_DY = 0.88

# 单字画布 / 字面占画布的比例
GLYPH_PX = 64
GLYPH_FILL = 0.88

# 缺素材的兵种 → 产物文件名（字从 config 的 icon 读）。
# ★ 目前七个兵种都有整张原画了，这里为空；将来加缺素材的兵种时往里加即可。
GLYPH_TARGETS = []

# 已有整张原画的兵种：art_draft 根目录的文件 → 产物（原样拷贝，不再画单字）
ART_TARGETS = [
    ("粮车.png", "GrainCart", "grain_cart.png"),
    ("骑手.png", "Rider", "rider.png"),
    ("骑士.png", "Knight", "knight.png"),
    ("马弓手.png", "HorseArcher", "horse_archer.png"),
    ("投石车.png", "Catapult", "catapult.png"),
]


def _default_paths():
    here = os.path.abspath(os.path.dirname(__file__))
    project = os.path.abspath(os.path.join(here, ".."))          # dev_gd_a/daeem
    repo = os.path.abspath(os.path.join(project, "..", ".."))    # 仓库根
    return (os.path.join(repo, "art_draft", "test_assets"),
            os.path.join(project, "assets", "test_units"),
            os.path.join(repo, "art_draft"))


def load_rgba(path):
    if not os.path.isfile(path):
        raise SystemExit("找不到素材：%s" % path)
    return Image.open(path).convert("RGBA")


def compose(src_dir, weapon_name, weapon_h, dx, dy):
    """人物 + 武器 拼成一张（透明底），按 alpha 裁到内容边界。"""
    person = load_rgba(os.path.join(src_dir, "person.png"))
    weapon = load_rgba(os.path.join(src_dir, weapon_name))
    ph = PERSON_H
    pw = max(1, round(person.width * ph / person.height))
    p = person.resize((pw, ph), Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    px = (CANVAS_W - pw) // 2
    canvas.alpha_composite(p, (px, CANVAS_H - ph))
    wh = weapon_h
    ww = max(1, round(weapon.width * wh / weapon.height))
    w = weapon.resize((ww, wh), Image.LANCZOS)
    canvas.alpha_composite(w, (int(px + pw * dx), int(CANVAS_H - ph * dy)))
    bbox = canvas.getchannel("A").getbbox()
    if bbox is None:
        raise SystemExit("合成结果是空的：%s" % weapon_name)
    return canvas.crop(bbox)


def bake_glyph(ch, font_path):
    """一个汉字 → 透明底白字（64×64），字面占画布 GLYPH_FILL。"""
    font = ImageFont.truetype(font_path, 160)
    bbox = font.getbbox(ch)
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    if w <= 0 or h <= 0:
        raise SystemExit("字画不出来：%r" % ch)
    pad = 8
    ink = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    ImageDraw.Draw(ink).text((pad - bbox[0], pad - bbox[1]), ch, font=font,
                             fill=(255, 255, 255, 255))
    target = int(GLYPH_PX * GLYPH_FILL)
    scale = min(target / ink.width, target / ink.height)
    tw = max(1, round(ink.width * scale))
    th = max(1, round(ink.height * scale))
    ink = ink.resize((tw, th), Image.LANCZOS)
    out = Image.new("RGBA", (GLYPH_PX, GLYPH_PX), (0, 0, 0, 0))
    out.alpha_composite(ink, ((GLYPH_PX - tw) // 2, (GLYPH_PX - th) // 2))
    return out


def save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, "PNG")
    print("  -> %s  %dx%d" % (os.path.relpath(path), img.width, img.height))


def main(argv=None):
    src_default, out_default, art_default = _default_paths()
    ap = argparse.ArgumentParser(description="烘 3D 立牌贴图（人 + 武器 / 原画 / 单字 / 箭）")
    ap.add_argument("--src", default=src_default, help="art_draft/test_assets 目录")
    ap.add_argument("--out", default=out_default, help="工程 assets/test_units 目录")
    ap.add_argument("--art", default=art_default,
                    help="art_draft 根目录（整张原画所在处，直接拷贝）")
    ap.add_argument("--config", default=None, help="config.json（默认取工程 data/config.json）")
    ap.add_argument("--font", default=None, help="单字用的字体（默认 assets/fonts/simhei.ttf）")
    args = ap.parse_args(argv)

    out = os.path.abspath(args.out)
    project = os.path.abspath(os.path.join(out, "..", ".."))
    cfg_path = args.config or os.path.join(project, "data", "config.json")
    font_path = args.font or os.path.join(project, "assets", "fonts", "simhei.ttf")
    # 只有还要画单字占位时才需要 config / 字体（目前 GLYPH_TARGETS 为空）。
    if GLYPH_TARGETS:
        if not os.path.isfile(cfg_path):
            raise SystemExit("找不到 config.json：%s" % cfg_path)
        if not os.path.isfile(font_path):
            raise SystemExit("找不到字体：%s" % font_path)

    print("[bake] 源素材：%s" % os.path.abspath(args.src))
    print("[bake] 输出：  %s" % out)

    print("[bake] 长枪兵 = 人 + 剑")
    save(compose(args.src, "sword.png", SWORD_H, SWORD_DX, SWORD_DY),
         os.path.join(out, "SpearMan", "spearman.png"))

    print("[bake] 长弓兵 = 人 + 弓")
    save(compose(args.src, "g.png", BOW_H, BOW_DX, BOW_DY),
         os.path.join(out, "LongbowMan", "longbowman.png"))

    print("[bake] 整张原画（直接拷贝 art_draft 根目录的素材）")
    for src_name, folder, filename in ART_TARGETS:
        save(load_rgba(os.path.join(args.art, src_name)),
             os.path.join(out, folder, filename))

    if GLYPH_TARGETS:
        cfg = json.loads(io.open(cfg_path, encoding="utf-8").read())
        types = cfg["unit"]["types"]
        print("[bake] 单字占位（字从 config.json 的 unit.types.*.icon 读）")
        for folder, type_id, filename in GLYPH_TARGETS:
            ch = str(types.get(type_id, {}).get("icon", "") or "").strip()
            if not ch:
                raise SystemExit("config 里 %s 没有 icon" % type_id)
            print("[bake]   %s = %r" % (type_id, ch))
            save(bake_glyph(ch, font_path), os.path.join(out, folder, filename))

    print("[bake] 箭（投射物贴图）")
    arrow = load_rgba(os.path.join(args.src, "arrow.png"))
    save(arrow, os.path.join(out, "Projectile", "arrow.png"))
    # 运行时把白剪影乘成开火方阵营色（MultiMesh / 材质共用一张图，做不到逐实例换色）
    white = Image.new("RGBA", arrow.size, (255, 255, 255, 0))
    white.putalpha(arrow.getchannel("A"))
    save(white, os.path.join(out, "Projectile", "arrow_white.png"))

    print("[bake] 完成。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
