#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/build_single_file.py —— 零依赖打包器

为什么需要它：
  浏览器在 file:// 协议下会以 CORS 策略拦截 <script type="module">，
  所以直接双击 index.html 会白屏。这个脚本把 css 与所有 ES 模块内联进
  一个 HTML 文件，产出可以通过双击直接打开的 rts-prototype.html。

用法：
  python tools/build_single_file.py            # 生成 rts-prototype.html
  python tools/build_single_file.py --watch    # 监听源码变化自动重建

源码仍然是模块化的（js/*.js + css/style.css），改完源码重新跑一次即可。
"""

import os
import re
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'rts-prototype.html')

# 依赖顺序（被依赖的模块排在前面）
MODULES = [
    'js/config.js',
    'js/util.js',
    'js/path.js',
    'js/map.js',
    'js/zone.js',
    'js/building.js',
    'js/unit.js',
    'js/render.js',
    'js/main.js',
]

# 只删除 import 语句本身；支持单行与“花括号换行”的多行写法
RE_IMPORT = re.compile(r'^\s*import\b')
RE_FROM = re.compile(r'''from\s*['"][^'"]*['"]\s*;?\s*$''')
RE_EXPORT_DECL = re.compile(r'^(\s*)export\s+(?=(const|let|var|function|class)\b)', re.M)


def strip_module_syntax(src):
    """逐行剥离 import（按花括号配平判断语句结束），并把 `export const` 还原为 `const`。"""
    out = []
    lines = src.split('\n')
    i = 0
    while i < len(lines):
        line = lines[i]
        if RE_IMPORT.match(line):
            depth = 0
            while i < len(lines):
                cur = lines[i]
                depth += cur.count('{') - cur.count('}')
                done = RE_FROM.search(cur) is not None or (depth <= 0 and cur.rstrip().endswith(';'))
                i += 1
                if done and depth <= 0:
                    break
            continue
        out.append(line)
        i += 1
    src = '\n'.join(out)
    src = RE_EXPORT_DECL.sub(r'\1', src)
    return src


def read(path):
    with open(path, 'r', encoding='utf-8') as f:
        return f.read()


def build():
    index = read(os.path.join(ROOT, 'index.html'))
    css = read(os.path.join(ROOT, 'css', 'style.css'))

    chunks = []
    for rel in MODULES:
        p = os.path.join(ROOT, rel)
        if not os.path.exists(p):
            print(f'  ! 缺少模块 {rel}')
            continue
        code = strip_module_syntax(read(p))
        header = f'/* ==================== {rel} ==================== */'
        chunks.append(f'{header}\n{code.strip()}\n')

    js = '\n'.join(chunks)

    # 内联 CSS
    index = index.replace(
        '<link rel="stylesheet" href="./css/style.css" />',
        f'<style>\n{css}\n</style>',
    )
    # 内联 JS（去掉 module 类型，模块语法已被剥离）
    index = index.replace(
        '<script type="module" src="./js/main.js"></script>',
        f'<script>\n"use strict";\n{js}\n</script>',
    )
    banner = '<!-- 该文件由 tools/build_single_file.py 自动生成，请勿直接编辑；请改 js/ 与 css/ 后重新构建 -->\n'
    index = index.replace('<!DOCTYPE html>', '<!DOCTYPE html>\n' + banner, 1)

    with open(OUT, 'w', encoding='utf-8') as f:
        f.write(index)

    kb = os.path.getsize(OUT) / 1024
    print(f'  构建完成: {os.path.relpath(OUT, ROOT)}  ({kb:.1f} KB, 内联 {len(chunks)} 个模块)')


def watch():
    print(f'监听源码变化（Ctrl+C 退出）…')
    stamps = {}
    while True:
        changed = False
        for rel in MODULES + ['index.html', 'css/style.css']:
            p = os.path.join(ROOT, rel)
            try:
                m = os.path.getmtime(p)
            except OSError:
                continue
            if stamps.get(p) != m:
                if p in stamps:
                    changed = True
                stamps[p] = m
        if changed:
            build()
        time.sleep(0.6)


if __name__ == '__main__':
    print('打包 RTS 原型…')
    build()
    if '--watch' in sys.argv:
        watch()
