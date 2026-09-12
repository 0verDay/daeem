#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/verify_build.py —— 静态校验打包产物是否与源码一致

用途：在没有浏览器可用的环境里，确认 rts-prototype.html 确实是当前 js/ 与 css/
的结果（每个模块都已内联、ES 模块语法已剥离、关键函数都在）。

用法：python tools/verify_build.py
"""

import io
import importlib.util
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILT = os.path.join(ROOT, 'rts-prototype.html')

# 直接复用构建器的剥离逻辑，避免两处实现不一致造成误报
_spec = importlib.util.spec_from_file_location('builder', os.path.join(ROOT, 'tools', 'build_single_file.py'))
_builder = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_builder)
strip_module_syntax = _builder.strip_module_syntax

MODULES = [
    'js/config.js', 'js/util.js', 'js/path.js', 'js/map.js', 'js/zone.js',
    'js/building.js', 'js/unit.js', 'js/render.js', 'js/main.js',
]

KEY_SYMBOLS = [
    'createMap', 'findPath', 'nearestReachable', 'updateZones', 'refreshBuildingOwnership',
    'updateTowers', 'createGenerals', 'Building', 'Unit', 'draw', 'spawnEnemy',
    'drawOnce', 'window.RTS',
]


def main():
    fails = []

    if not os.path.exists(BUILT):
        print('未找到 rts-prototype.html，请先运行 python tools/build_single_file.py')
        return 2

    html = io.open(BUILT, encoding='utf-8').read()
    css = io.open(os.path.join(ROOT, 'css', 'style.css'), encoding='utf-8').read()
    print(f'产物: rts-prototype.html（{len(html) / 1024:.1f} KB）')

    def check(name, cond):
        print(('  [OK]   ' if cond else '  [FAIL] ') + name)
        if not cond:
            fails.append(name)

    check('CSS 已内联', '<style>' in html and css.strip()[:40] in html)
    check('不再引用外部 css/js', 'href="./css/style.css"' not in html and 'src="./js/main.js"' not in html)
    check('不含 <script type="module">', 'type="module"' not in html)
    check('无残留 import 语句', not re.search(r'^\s*import\s', html, re.M))
    check('无残留 export 关键字', not re.search(r'^\s*export\s', html, re.M))
    check('9 个模块都已内联', len(re.findall(r'={20} js/', html)) == len(MODULES))
    for sym in KEY_SYMBOLS:
        check(f'包含 {sym}', sym in html)

    print('\n逐模块比对（源码剥离模块语法后应逐字出现在产物里）:')
    for rel in MODULES:
        src = io.open(os.path.join(ROOT, rel), encoding='utf-8').read()
        stripped = strip_module_syntax(src).strip()
        check(f'{rel} 已同步', stripped in html)

    print(f'\n失败 {len(fails)} 项')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
