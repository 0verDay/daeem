#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/test-module-version.py —— 验证「模块化源码版」在浏览器里也能跑

file:// 下 <script type="module"> 会被 CORS 拦截，所以这里起一个本地 HTTP 服务，
把同样的回归探针注入 index.html，确认 js/*.js 模块图本身没有问题。

用法：python tools/test-module-version.py
"""

import http.server
import importlib.util
import io
import json
import os
import re
import socketserver
import subprocess
import sys
import tempfile
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 8899

# 复用 browser-test.py 里的探针与浏览器探测逻辑
spec = importlib.util.spec_from_file_location('browsertest', os.path.join(ROOT, 'tools', 'browser-test.py'))
browsertest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(browsertest)


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def log_message(self, *a):
        pass


def main():
    browser = browsertest.find_browser()
    if not browser:
        print('未找到 Chrome / Edge')
        return 2

    socketserver.TCPServer.allow_reuse_address = True
    httpd = socketserver.TCPServer(('127.0.0.1', PORT), QuietHandler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    print(f'本地服务已启动: http://127.0.0.1:{PORT}/')

    # 复制一份 index.html 并注入探针（保持 <script type="module"> 不变）
    # 注意：必须生成在项目根目录，否则页面里的 ./js/... 相对路径会解析错
    src = io.open(os.path.join(ROOT, 'index.html'), encoding='utf-8').read()
    src = src.replace(u'<!DOCTYPE html>', u'<!DOCTYPE html>\n' + browsertest.HEAD, 1)
    src = src.replace(u'</body>', browsertest.TEST_HOOK + u'</body>')
    test_page = os.path.join(ROOT, '_module_test.html')
    io.open(test_page, 'w', encoding='utf-8').write(src)

    profile = os.path.join(tempfile.gettempdir(), 'rts_module_test_profile')
    log = os.path.join(tempfile.gettempdir(), 'rts_module_dom.html')
    url = f'http://127.0.0.1:{PORT}/_module_test.html'
    cmd = [browser, '--headless=new', '--disable-gpu', '--no-first-run',
           '--user-data-dir=' + profile, '--window-size=1500,900',
           '--virtual-time-budget=6000', '--dump-dom', url]
    with open(log, 'w', encoding='utf-8') as fh:
        subprocess.run(cmd, stdout=fh, stderr=subprocess.DEVNULL)
    httpd.shutdown()

    stdout = io.open(log, encoding='utf-8', errors='replace').read()
    m = re.search(r'<pre id="bt-out"[^>]*>(.*?)</pre>', stdout, re.S)
    if not m or not m.group(1).strip().startswith('{'):
        print('未取到测试结果。页面尾部：')
        print(stdout[-700:])
        return 2

    data = json.loads(m.group(1))
    results = data['results']
    failed = [r for r in results if r.startswith('FAIL')]
    for r in results:
        state, name, extra = (r.split('|') + ['', ''])[:3]
        mark = '[OK]  ' if state == 'PASS' else '[FAIL]'
        print(f'  {mark} {name}' + (f'  — {extra}' if extra else ''))
    print(f'\n模块版通过 {len(results) - len(failed)} 项，失败 {len(failed)} 项')
    return 0 if not failed else 1


if __name__ == '__main__':
    sys.exit(main())
