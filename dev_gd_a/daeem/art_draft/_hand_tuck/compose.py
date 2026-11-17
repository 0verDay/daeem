import sys
from PIL import Image, ImageDraw

ROOT = r"C:\Users\yy197\Documents\GitHub\daeem\dev_gd_a\daeem\art_draft\_hand_tuck"

# 手牌区（设计分辨率 1600x900 的截图，实际 1920x1080 缩放）：只裁下半部分
CROP = (380, 640, 1560, 1080)
LABEL_H = 34


def panel(name, label):
    im = Image.open(f"{ROOT}/{name}.png").convert("RGB")
    im = im.crop(CROP)
    canvas = Image.new("RGB", (im.width, im.height + LABEL_H), (18, 18, 22))
    canvas.paste(im, (0, LABEL_H))
    d = ImageDraw.Draw(canvas)
    d.text((10, 9), label, fill=(240, 230, 200))
    return canvas


def stack(pairs, out):
    panels = [panel(n, l) for n, l in pairs]
    gap = 12
    w = max(p.width for p in panels)
    h = sum(p.height for p in panels) + gap * (len(panels) - 1)
    canvas = Image.new("RGB", (w, h), (8, 8, 10))
    y = 0
    for p in panels:
        canvas.paste(p, (0, y))
        y += p.height + gap
    canvas.save(f"{ROOT}/{out}")
    print(out, canvas.size)


stack([("hand_rest", "1) rest"),
       ("hand_dragging_tucked", "2) dragging a card -> others sink 40px + 0.82x"),
       ("hand_back", "3) released -> float back")], "compare_hand.png")

stack([("tech_rest", "1) tech rest"),
       ("tech_dragging_tucked", "2) tech card dragged -> others sink + shrink"),
       ("tech_back", "3) released -> float back")], "compare_tech.png")
