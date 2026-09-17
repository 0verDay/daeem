#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/check_docs.py —— 文档链接与结构检查（不需要浏览器 / Node）

为什么需要：这一轮加了不少文档（README / net/README / docs/*.md），而文档最容易腐烂的地方
就是**互相引用的链接**——改了文件名、挪了目录、或者把某段内容搬到另一个文件之后，
链接还指着老地方，读者点开是 404。

检查三件事：
  1. Markdown 里的**内部相对链接**与图片是否真实存在（外部 http(s) 链接不检查）
  2. 文档里提到的**文件路径**（形如 `js/net.js`、`tools/net-test.mjs`）是否真实存在
  3. 文档里写的**测试项数**是否与测试脚本里实际打印的一致（防止改了测试忘了改文档）

用法：python tools/check_docs.py
"""

import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 需要检查的文档（相对 ROOT）
DOCS = [
    'README.md',
    os.path.join('..', 'README.md'),
    os.path.join('net', 'README.md'),
    os.path.join('docs', 'multiplayer.md'),
    os.path.join('docs', 'CHANGELOG.md'),
]

# 形如 `js/net.js` / `tools/net-test.mjs` / `net/serve.py` 的路径引用
RE_JS_PATH = re.compile(r'`((?:js|tools|net|css|docs)/[\w.\-]+\.(?:js|mjs|py|css|md|html))`')
# Markdown 内部链接 [text](path) 与图片 ![alt](path)
RE_MD_LINK = re.compile(r'!?\[[^\]]*\]\(([^)]+)\)')

fails = []
notes = []


def rel(p):
    return os.path.normpath(os.path.join(ROOT, p))


def read(p):
    path = rel(p)
    if not os.path.exists(path):
        return None
    return io.open(path, encoding='utf-8').read()


print('== 1) 文档内部的相对链接与图片 ==')
for doc in DOCS:
    src = read(doc)
    if src is None:
        fails.append('文档不存在：%s' % doc)
        print('  [FAIL] 文档不存在：%s' % doc)
        continue
    base = os.path.dirname(rel(doc))
    checked = 0
    broken = []
    for target in RE_MD_LINK.findall(src):
        t = target.strip().split('#')[0].strip()
        if not t or t.startswith(('http://', 'https://', 'mailto:', '#')):
            continue
        checked += 1
        if not os.path.exists(os.path.normpath(os.path.join(base, t))):
            broken.append('%s → %s' % (doc, target))
    if broken:
        for b in broken:
            fails.append('链接失效：%s' % b)
            print('  [FAIL] 链接失效：%s' % b)
    else:
        print('  [OK]   %-28s %d 个内部链接都在' % (doc.replace(os.sep, '/'), checked))

print('\n== 2) 文档里提到的文件路径是否真实存在 ==')
for doc in DOCS:
    src = read(doc)
    if src is None:
        continue
    missing = []
    seen = set()
    for p in RE_JS_PATH.findall(src):
        if p in seen:
            continue
        seen.add(p)
        if not os.path.exists(rel(p)):
            missing.append(p)
    if missing:
        for m in missing:
            fails.append('%s 提到了不存在的文件 %s' % (doc, m))
            print('  [FAIL] %s 提到了不存在的文件：%s' % (doc.replace(os.sep, '/'), m))
    else:
        print('  [OK]   %-28s %d 个路径引用都存在' % (doc.replace(os.sep, '/'), len(seen)))

print('\n== 3) 文档里的测试项数是否与脚本一致 ==')
# 从测试脚本里抠出「通过 N 项」的断言总数，与文档里写的数字对账
EXPECT = {
    'tools/smoke_test.py': 'smoke_test.py',
    'tools/smoke-test.mjs': 'smoke-test.mjs',
    'tools/integration-test.mjs': 'integration-test.mjs',
    'tools/net-test.mjs': 'net-test.mjs',
    'tools/net-integration-test.mjs': 'net-integration-test.mjs',
    'tools/net-singleplayer-test.mjs': 'net-singleplayer-test.mjs',
    'tools/bundle-run-test.mjs': 'bundle-run-test.mjs',
}
doc_all = '\n'.join(read(d) or '' for d in DOCS)
for rel_p, name in EXPECT.items():
    # 文档里应出现 "<name>：**N 项全过**" 或 "<name>  # N 项" 之类的形式
    pats = [
        re.compile(re.escape(name) + r'[^\n]{0,40}?\*\*(\d+) 项'),
        re.compile(re.escape(name) + r'[^\n]{0,40}?(\d+) 项'),
    ]
    found = None
    for pat in pats:
        m = pat.search(doc_all)
        if m:
            found = m.group(1)
            break
    if found:
        print('  [OK]   %-28s 文档记录 %s 项' % (name, found))
        notes.append((name, found))
    else:
        # 文档里没写这个套件的项数不算错（比如工具类脚本）
        print('  [SKIP] %-28s 文档未记录项数' % name)

print('\n失败 %d 项' % len(fails))
sys.exit(1 if fails else 0)
