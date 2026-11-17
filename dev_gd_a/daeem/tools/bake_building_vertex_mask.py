#!/usr/bin/env python3
"""bake_building_vertex_mask.py —— 给分级建筑模型补回「阵营色遮罩」顶点色。

背景
----
现有建筑模型（`base_lowpoly.glb` / `tower_lowpoly.glb` …）的顶点色是 **COLOR_0 VEC4**：
  · rgb = 材质原色（木褐 / 石灰 / 麦金 …）；
  · a   = 阵营色遮罩（1 = 旗 / 屋顶 / 廊柱 / 栅栏吃阵营色，0 = 保留原色）。

2026.11.17 新做的分级模型（`*_l1_lowpoly.glb` / `*_l2_lowpoly.glb`）导出成了
**COLOR_0 VEC3**（没有 alpha）。游戏 shader 把缺失的 alpha 当 1，于是整栋模型
都被染成阵营色，看起来像「没有贴图」。

这个脚本把新模型的 COLOR_0 从 VEC3 转成 VEC4，并按**同类型的现有模型**的
「rgb → alpha」表补回 alpha。颜色必须能在旧模型里找到（找不到直接报错，
不猜测、不静默兜底）。

用法（在 `dev_gd_a/daeem` 目录下）：
    python tools/bake_building_vertex_mask.py           # 只检查，不写文件
    python tools/bake_building_vertex_mask.py --write   # 写回 glb
    python tools/bake_building_vertex_mask.py --write --import
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import subprocess
import sys

COMP = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}

# 新分级模型 → 用来查「rgb → alpha」的现有模型。
JOBS = {
    "base_l1_lowpoly.glb": "base_lowpoly.glb",
    "base_l2_lowpoly.glb": "base_lowpoly.glb",
    "tower_l1_lowpoly.glb": "tower_lowpoly.glb",
    "watch_tower_l1_lowpoly.glb": "watch_tower_lowpoly.glb",
    "farm_l1_lowpoly.glb": "farm_lowpoly.glb",
    "house_l2_lowpoly.glb": "house_lowpoly.glb",
    "mine_l1_lowpoly.glb": "mine_lowpoly.glb",
}

MODEL_DIR = os.path.join("assets", "models")


# ---------------------------------------------------------------------------
# glb 读写
# ---------------------------------------------------------------------------

def load_glb(path: str):
    raw = open(path, "rb").read()
    magic, version, length = struct.unpack_from("<III", raw, 0)
    if magic != 0x46546C67 or version != 2:
        raise SystemExit(f"{path}: 不是 glTF 2.0 GLB")
    off = 12
    doc = None
    bin_chunk = b""
    while off < length:
        clen, ctype = struct.unpack_from("<II", raw, off)
        off += 8
        chunk = raw[off:off + clen]
        off += clen
        if ctype == 0x4E4F534A:
            doc = json.loads(chunk.decode("utf-8"))
        elif ctype == 0x004E4942:
            bin_chunk = chunk
    if doc is None:
        raise SystemExit(f"{path}: 没有 JSON chunk")
    return doc, bin_chunk


def save_glb(path: str, doc: dict, bin_chunk: bytes) -> None:
    doc["buffers"][0]["byteLength"] = len(bin_chunk)
    js = json.dumps(doc, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    js += b" " * ((4 - len(js) % 4) % 4)
    bin_padded = bin_chunk + b"\x00" * ((4 - len(bin_chunk) % 4) % 4)
    total = 12 + 8 + len(js) + (8 + len(bin_padded))
    out = bytearray()
    out += struct.pack("<III", 0x46546C67, 2, total)
    out += struct.pack("<II", len(js), 0x4E4F534A)
    out += js
    out += struct.pack("<II", len(bin_padded), 0x004E4942)
    out += bin_padded
    with open(path, "wb") as fh:
        fh.write(out)


def accessor_values(doc: dict, bin_chunk: bytes, idx: int):
    acc = doc["accessors"][idx]
    bv = doc["bufferViews"][acc["bufferView"]]
    start = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    fmt, size = COMP[acc["componentType"]]
    n = NCOMP[acc["type"]]
    stride = bv.get("byteStride", size * n)
    vals = []
    for i in range(acc["count"]):
        vals.append(struct.unpack_from("<" + fmt * n, bin_chunk, start + i * stride))
    return vals, acc


def normalized(component_type: int, values) -> tuple:
    if component_type == 5121:
        return tuple(x / 255.0 for x in values)
    if component_type == 5123:
        return tuple(x / 65535.0 for x in values)
    if component_type == 5126:
        return tuple(float(x) for x in values)
    raise SystemExit(f"不支持的 COLOR_0 分量类型 {component_type}")


def color_key(rgb) -> tuple:
    return tuple(round(float(x), 4) for x in rgb)


# ---------------------------------------------------------------------------
# 主逻辑
# ---------------------------------------------------------------------------

def build_alpha_map(old_path: str) -> dict:
    doc, bin_chunk = load_glb(old_path)
    out = {}
    for mesh in doc.get("meshes", []):
        for prim in mesh.get("primitives", []):
            ai = prim.get("attributes", {}).get("COLOR_0")
            if ai is None:
                continue
            vals, acc = accessor_values(doc, bin_chunk, ai)
            if acc["type"] != "VEC4":
                raise SystemExit(f"{old_path}: 现有模型的 COLOR_0 不是 VEC4，无法作为遮罩来源")
            for v in vals:
                c = normalized(acc["componentType"], v)
                key = color_key(c[:3])
                a = 1.0 if c[3] >= 0.5 else 0.0
                if key in out and abs(out[key] - a) > 1e-6:
                    raise SystemExit(f"{old_path}: 同一 rgb {key} 出现了两种 alpha")
                out[key] = a
    if not out:
        raise SystemExit(f"{old_path}: 没有 COLOR_0")
    return out


def find_alpha(alpha_map: dict, rgb) -> float:
    key = color_key(rgb)
    if key in alpha_map:
        return alpha_map[key]
    # 浮点误差兜底：在 0.002 以内找最近的颜色（找不到仍然报错，不猜）。
    best = None
    best_d = 1e9
    for k, a in alpha_map.items():
        d = sum((k[i] - key[i]) ** 2 for i in range(3)) ** 0.5
        if d < best_d:
            best_d = d
            best = a
    if best is not None and best_d <= 0.002:
        return best
    raise SystemExit(f"颜色 {key} 在现有模型的调色板里找不到（最近距离 {best_d:.4f}）")


def bake_one(new_path: str, old_path: str, write: bool) -> None:
    alpha_map = build_alpha_map(old_path)
    doc, bin_chunk = load_glb(new_path)
    changed = 0
    alpha_counts = {0.0: 0, 1.0: 0}
    for mesh in doc.get("meshes", []):
        for prim in mesh.get("primitives", []):
            attrs = prim.get("attributes", {})
            ai = attrs.get("COLOR_0")
            if ai is None:
                continue
            vals, acc = accessor_values(doc, bin_chunk, ai)
            if acc["type"] == "VEC4":
                # 已经是 VEC4：只检查，不重复改。
                print(f"  [skip] {os.path.basename(new_path)} 已经是 VEC4")
                return
            if acc["type"] != "VEC3":
                raise SystemExit(f"{new_path}: 预期 VEC3 / VEC4，实际 {acc['type']}")
            rgba = bytearray()
            for v in vals:
                rgb = normalized(acc["componentType"], v)
                a = find_alpha(alpha_map, rgb)
                alpha_counts[a] += 1
                rgba += struct.pack("<ffff", float(rgb[0]), float(rgb[1]), float(rgb[2]), a)
            # 追加新的 bufferView + accessor（旧数据留下不用，避免挪动整个 BIN）。
            off = (len(bin_chunk) + 3) & ~3
            if off > len(bin_chunk):
                bin_chunk += b"\x00" * (off - len(bin_chunk))
            bin_chunk += bytes(rgba)
            doc["bufferViews"].append({
                "buffer": 0,
                "byteOffset": off,
                "byteLength": len(rgba),
            })
            bv_idx = len(doc["bufferViews"]) - 1
            doc["accessors"].append({
                "bufferView": bv_idx,
                "componentType": 5126,
                "count": len(vals),
                "type": "VEC4",
            })
            attrs["COLOR_0"] = len(doc["accessors"]) - 1
            changed += 1
    if changed == 0:
        print(f"  [skip] {os.path.basename(new_path)} 没有可转换的 COLOR_0")
        return
    if alpha_counts[1.0] <= 0:
        raise SystemExit(f"{new_path}: 没有任何 a=1 的阵营色部件（README 硬约束）")
    print(f"  {os.path.basename(new_path)}: {changed} 个 primitive；"
          f"a=0 {alpha_counts[0.0]} 顶点 / a=1 {alpha_counts[1.0]} 顶点")
    if write:
        save_glb(new_path, doc, bin_chunk)
        print(f"  [write] {new_path}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true", help="写回 glb（默认只检查）")
    ap.add_argument("--import", dest="do_import", action="store_true",
                    help="写完后跑 Godot --headless --import")
    args = ap.parse_args()

    for new_name, old_name in JOBS.items():
        new_path = os.path.join(MODEL_DIR, new_name)
        old_path = os.path.join(MODEL_DIR, old_name)
        if not os.path.isfile(new_path):
            raise SystemExit(f"缺少文件：{new_path}")
        if not os.path.isfile(old_path):
            raise SystemExit(f"缺少参考文件：{old_path}")
        print(f"[{new_name}] <- {old_name}")
        bake_one(new_path, old_path, args.write)

    if args.do_import:
        godot = os.environ.get("GODOT", r"C:\D\GodotEngine\gd4.7.2mono\Godot_v4.7.2-stable_mono_win64_console.exe")
        print(f"[import] {godot} --headless --path . --import")
        subprocess.run([godot, "--headless", "--path", ".", "--import"], check=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
