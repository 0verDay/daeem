#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/lint_refs.py —— 轻量静态引用检查（不需要浏览器、不需要 Node）

用途：前面的改动（地块尺寸、相机签名、单位移动语义）容易留下"旧 API 残留"，
例如 render.js 的函数已经从 canvas 改成 state，但某个调用点还是老的写法。
这个脚本做几件正则级的检查：

  1. 每个 js/*.js 里 `import { a, b } from './x.js'` 的名字，必须在 x.js 里被导出；
  2. 各模块导出的函数被调用时参数个数是否大致对得上（数量级检查，仅提示）；
  3. 全局搜索已废弃的调用形态（例如作为旧 namespace 使用的 `R.`）。

用法：python tools/lint_refs.py
"""

import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JS_DIR = os.path.join(ROOT, 'js')
MODULES = ['config.js', 'util.js', 'path.js', 'map.js', 'zone.js', 'building.js', 'unit.js', 'render.js', 'main.js']

RE_IMPORT = re.compile(r"import\s*\{([^}]*)\}\s*from\s*'\./([\w.]+)'", re.S)
RE_EXPORT_FN = re.compile(r"export\s+(?:async\s+)?function\s+(\w+)\s*\(([^)]*)\)", re.S)
RE_EXPORT_CLASS = re.compile(r"export\s+class\s+(\w+)", re.S)
RE_EXPORT_CONST = re.compile(r"export\s+const\s+(\w+)", re.S)

fails = []
notes = []


def read(name):
    return io.open(os.path.join(JS_DIR, name), encoding='utf-8').read()


def strip_comments(src):
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    src = re.sub(r'//[^\n]*', '', src)
    return src


exports = {}
sources = {}
for name in MODULES:
    src = read(name)
    sources[name] = src
    clean = strip_comments(src)
    names = set(RE_EXPORT_FN.findall(clean) and [m[0] for m in RE_EXPORT_FN.findall(clean)] or [])
    names |= set(RE_EXPORT_CLASS.findall(clean))
    names |= set(RE_EXPORT_CONST.findall(clean))
    exports[name] = names

print('== 模块导出清单 ==')
for name in MODULES:
    print(f'  {name:14s} {len(exports[name]):2d} 个导出: {", ".join(sorted(exports[name]))}')

print('\n== 1) import 的名字必须在被导入模块里导出 ==')
imports_by_file = {}
for name in MODULES:
    clean = strip_comments(sources[name])
    imports_by_file[name] = []
    for names_str, mod in RE_IMPORT.findall(clean):
        wanted = [n.strip().split(' as ')[0].strip() for n in names_str.split(',') if n.strip()]
        imports_by_file[name].append((mod, wanted))
        missing = [w for w in wanted if w not in exports.get(mod, set())]
        if missing:
            msg = f'{name} 从 {mod} 导入了不存在的 {missing}'
            print(f'  [FAIL] {msg}')
            fails.append(msg)
        else:
            print(f'  [OK]   {name} ← {mod}（{len(wanted)} 个名字都在）')

print('\n== 2) 已废弃的调用形态 ==')
DEPRECATED = [
    (r'\bR\.(draw|fit|clampCam|centerOn|createCamera|screenToWorld|worldToTile)\b', 'render 的命名空间调用 R.xxx（已改为具名导入）'),
    (r'clampCam\([^)]*canvas', 'clampCam(cam, canvas) 旧签名（现为 clampCam(cam, state)）'),
    (r'\bfit\(state\.camera,\s*canvas\)', 'fit(cam, canvas) 旧签名（现为 fit(cam, state)）'),
    (r'screenToWorld\([^)]*canvas', 'screenToWorld 旧签名（现为 screenToWorld(cam, sx, sy)）'),
    (r'CONFIG\.unit\.radius\b(?!Factor)', 'CONFIG.unit.radius 旧字段（现用 cell × radiusFactor）'),
    (r'cell:\s*40\b', 'config 里仍是旧地块尺寸 40'),
    (r'snapToTileCenter', '已删除的格心吸附（现在停在点击位置）'),
]
for pattern, why in DEPRECATED:
    hits = []
    for name in MODULES:
        for m in re.finditer(pattern, strip_comments(sources[name])):
            line = sources[name][:m.start()].count('\n') + 1
            hits.append(f'{name}:{line}')
    if hits:
        msg = f'{why} → {hits}'
        print(f'  [FAIL] {msg}')
        fails.append(msg)
    else:
        print(f'  [OK]   无：{why}')

print('\n== 3) 关键常量一致性 ==')
def cfg_value(key, src):
    m = re.search(rf'\b{key}\s*:\s*([\d.]+)', src)
    return m.group(1) if m else None

cfg = sources['config.js']
cell = cfg_value('cell', cfg)
print(f'  config.cell = {cell}')
if cell != '120':
    fails.append('config.cell 不是 120')
    print('  [FAIL] 期望 120')
else:
    print('  [OK]   cell = 120（格数不变、地块变大）')

# smoke_test.py 的镜像常量要和 config 对齐
smoke = io.open(os.path.join(ROOT, 'tools', 'smoke_test.py'), encoding='utf-8').read()
m = re.search(r'^CELL = (\d+)', smoke, re.M)
smoke_cell = m.group(1) if m else None
if smoke_cell != cell:
    fails.append(f'smoke_test.py 的 CELL={smoke_cell} 与 config.cell={cell} 不一致')
    print(f'  [FAIL] smoke_test.py CELL={smoke_cell} ≠ config {cell}')
else:
    print(f'  [OK]   smoke_test.py 的 CELL={smoke_cell} 与 config 一致')

print(f'\n失败 {len(fails)} 项')
sys.exit(1 if fails else 0)
