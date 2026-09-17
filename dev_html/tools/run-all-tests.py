#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/run-all-tests.py —— 一键跑完所有本地测试

为什么需要：这一轮之后测试套件涨到 12 个，手动一个个敲很容易漏（漏掉的往往就是
最该跑的那一个）。这个脚本按「不依赖外部服务 → 依赖 Node → 依赖服务器」的顺序全跑一遍，
最后给一张汇总表。

用法：
  python tools/run-all-tests.py              # 跑全部不依赖服务器的套件
  python tools/run-all-tests.py --with-server --port 8097
                                             # 顺便跑需要服务器的两项（会自己起服务器）
  python tools/run-all-tests.py --stop-on-fail

说明：
  · 浏览器测试（browser-test.py / test-module-version.py）**不在**默认列表里 ——
    它们需要能启动 Chromium，受限环境里跑不了（见 docs/multiplayer.md 第八节）。
    加 --with-browser 才尝试。
"""

import argparse
import io
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RE_PASS = re.compile(r'通过\s*(\d+)\s*项[，,]\s*失败\s*(\d+)\s*项')
RE_FAIL = re.compile(r'失败\s*(\d+)\s*项')

# (名称, 运行器, 参数, 需要服务器?)
SUITES = [
    ('smoke_test.py',           'py',   ['tools/smoke_test.py'],            False),
    ('check_js_syntax.py',      'py',   ['tools/check_js_syntax.py'],       False),
    ('lint_refs.py',            'py',   ['tools/lint_refs.py'],             False),
    ('check_docs.py',           'py',   ['tools/check_docs.py'],            False),
    ('verify_build.py',         'py',   ['tools/verify_build.py'],          False),
    ('smoke-test.mjs',          'node', ['tools/smoke-test.mjs'],           False),
    ('integration-test.mjs',    'node', ['tools/integration-test.mjs'],     False),
    ('net-test.mjs',            'node', ['tools/net-test.mjs'],             False),
    ('net-integration-test.mjs','node', ['tools/net-integration-test.mjs'], False),
    ('net-singleplayer-test.mjs','node',['tools/net-singleplayer-test.mjs'],False),
    ('bundle-run-test.mjs',     'node', ['tools/bundle-run-test.mjs'],      False),
]

BROWSER_SUITES = [
    ('browser-test.py',         'py',   ['tools/browser-test.py'],          False),
    ('test-module-version.py',  'py',   ['tools/test-module-version.py'],   False),
]


def read_text(p):
    try:
        return io.open(p, encoding='utf-8', errors='replace').read()
    except OSError:
        return ''


def run_suite(name, runner, args, capture_cmd=None):
    """跑一个套件，返回 (是否通过, 通过项数, 摘要文本)"""
    cmd = [runner] + args
    t0 = time.time()
    try:
        # 不用管道捕获（受限环境下管道的 stdio 可能被拦），写临时文件再读
        out_path = os.path.join(ROOT, 'tools', '_runall_out.txt')
        with io.open(out_path, 'w', encoding='utf-8') as fh:
            proc = subprocess.run(cmd, cwd=ROOT, stdout=fh,
                                  stderr=subprocess.DEVNULL, timeout=300)
        text = read_text(out_path)
        try:
            os.remove(out_path)
        except OSError:
            pass
    except FileNotFoundError:
        return (False, 0, '找不到命令 %s（装了吗？）' % runner)
    except subprocess.TimeoutExpired:
        return (False, 0, '超时（300 秒）')

    dt = time.time() - t0
    m = RE_PASS.search(text)
    if m:
        n_pass, n_fail = int(m.group(1)), int(m.group(2))
        ok = (n_fail == 0 and proc.returncode == 0)
        return (ok, n_pass, '%d 项 / %.1fs' % (n_pass, dt))
    m = RE_FAIL.search(text)
    if m:
        n_fail = int(m.group(1))
        return (n_fail == 0 and proc.returncode == 0, 0, '失败 %d 项 / %.1fs' % (n_fail, dt))
    # 没有"通过 N 项"格式的脚本（静态检查类），只看退出码
    return (proc.returncode == 0, 0, '退出码 %d / %.1fs' % (proc.returncode, dt))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--with-server', action='store_true', help='顺便跑需要服务器的套件（自动起服务器）')
    ap.add_argument('--with-browser', action='store_true', help='顺便跑浏览器套件（需要 Chromium）')
    ap.add_argument('--port', type=int, default=8097)
    ap.add_argument('--stop-on-fail', action='store_true')
    args = ap.parse_args()

    # 入口检查：tools/ 必须能跑（否则先提醒 build）
    if not os.path.exists(os.path.join(ROOT, 'rts-prototype.html')):
        print('提示：还没有 rts-prototype.html，先跑 py tools/build_single_file.py')

    suites = list(SUITES)
    if args.with_browser:
        suites += BROWSER_SUITES

    server_proc = None
    if args.with_server:
        py = 'py' if os.name == 'nt' else 'python3'
        print('启动测试服务器（端口 %d）…' % args.port)
        server_proc = subprocess.Popen(
            [py, os.path.join('net', 'serve.py'), '--port', str(args.port)],
            cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        time.sleep(2.0)
        suites.append(('net-server-test.mjs', 'node', ['tools/net-server-test.mjs', str(args.port)], True))
        suites.append(('net-load-test.mjs(8人)', 'node', ['tools/net-load-test.mjs', str(args.port), '8'], True))

    print('=' * 66)
    print(' RTS 原型 · 本地测试总跑（%d 个套件）' % len(suites))
    print('=' * 66)

    results = []
    total_pass = 0
    for name, runner, cmdargs, needs_server in suites:
        ok, n, summary = run_suite(name, runner, cmdargs)
        results.append((name, ok, n, summary))
        total_pass += n
        print('  %s %-26s %s' % ('✔' if ok else '✘', name, summary))
        if not ok and args.stop_on_fail:
            print('\n（--stop-on-fail：停在第一个失败）')
            break

    if server_proc is not None:
        server_proc.terminate()
        try:
            server_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server_proc.kill()

    failed = [r for r in results if not r[1]]
    print('-' * 66)
    print(' 套件：%d 通过 / %d 失败    断言总计：%d 项'
          % (len(results) - len(failed), len(failed), total_pass))
    if failed:
        print(' 失败的套件：')
        for name, _ok, _n, summary in failed:
            print('   · %s（%s）' % (name, summary))
    print('=' * 66)
    if not args.with_browser:
        print(' 注：浏览器套件未包含（需要 Chromium）。加 --with-browser 尝试。')
    if not args.with_server:
        print(' 注：服务器套件未包含。加 --with-server 一起跑。')

    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
