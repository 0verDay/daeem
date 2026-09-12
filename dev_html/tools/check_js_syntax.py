#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/check_js_syntax.py —— 无 Node 环境下的 JS 结构检查

做三件事（都是"安全网"级别，不能替代真编译器，但能抓住绝大多数手改引入的错误）：
  1. 逐字符扫描：括号/中括号/花括号配平，字符串与模板串（含 ${} 嵌套）与注释状态正确；
  2. 模板串里的 `${...}` 内部也必须配平；
  3. 文件结尾不应停留在注释 / 字符串 / 未闭合括号中。

用法：python tools/check_js_syntax.py
"""

import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = ['config.js', 'util.js', 'path.js', 'map.js', 'zone.js', 'building.js', 'unit.js', 'render.js', 'main.js']

PAIRS = {')': '(', ']': '[', '}': '{'}
OPEN = set('([{')
CLOSE = set(')]}')


def check(path):
    src = io.open(path, encoding='utf-8').read()
    stack = []          # 期望的闭合字符栈
    tmpl_depth = []     # 模板串嵌套深度标记
    i = 0
    line = 1
    errs = []
    mode = 'code'       # code | line_comment | block_comment | squote | dquote | template

    def push(ch, ln):
        stack.append((ch, ln))

    while i < len(src):
        c = src[i]
        nxt = src[i + 1] if i + 1 < len(src) else ''
        if c == '\n':
            line += 1

        if mode == 'code':
            if c == '/' and nxt == '/':
                mode = 'line_comment'; i += 2; continue
            if c == '/' and nxt == '*':
                mode = 'block_comment'; i += 2; continue
            if c == "'":
                mode = 'squote'; i += 1; continue
            if c == '"':
                mode = 'dquote'; i += 1; continue
            if c == '`':
                mode = 'template'; i += 1; continue
            if c in OPEN:
                push(c, line); i += 1; continue
            if c in CLOSE:
                if not stack:
                    errs.append(f'{path}:{line} 多余的 {c}')
                else:
                    op, ln = stack.pop()
                    if op != PAIRS[c]:
                        errs.append(f'{path}:{line} {c} 与 {ln} 行的 {op} 不匹配')
                i += 1; continue
            i += 1; continue

        if mode == 'line_comment':
            if c == '\n':
                mode = 'code'
            i += 1; continue

        if mode == 'block_comment':
            if c == '*' and nxt == '/':
                mode = 'code'; i += 2; continue
            i += 1; continue

        if mode in ('squote', 'dquote'):
            if c == '\\':
                i += 2; continue
            if (mode == 'squote' and c == "'") or (mode == 'dquote' and c == '"'):
                mode = 'code'
            i += 1; continue

        if mode == 'template':
            if c == '\\':
                i += 2; continue
            if c == '`':
                mode = 'code'; i += 1; continue
            if c == '$' and nxt == '{':
                # 进入模板串里的表达式：用子扫描器保证配平
                depth = 1
                j = i + 2
                sub_line = line
                sub_mode = 'code'
                while j < len(src) and depth > 0:
                    d = src[j]
                    d2 = src[j + 1] if j + 1 < len(src) else ''
                    if d == '\n':
                        sub_line += 1
                    if sub_mode == 'code':
                        if d == '/' and d2 == '/':
                            sub_mode = 'line_comment'; j += 2; continue
                        if d == '/' and d2 == '*':
                            sub_mode = 'block_comment'; j += 2; continue
                        if d in '\'"`':
                            sub_mode = 'str' + d; j += 1; continue
                        if d == '{':
                            depth += 1
                        elif d == '}':
                            depth -= 1
                            if depth == 0:
                                j += 1
                                break
                        j += 1; continue
                    if sub_mode == 'line_comment':
                        if d == '\n':
                            sub_mode = 'code'
                        j += 1; continue
                    if sub_mode == 'block_comment':
                        if d == '*' and d2 == '/':
                            sub_mode = 'code'; j += 2; continue
                        j += 1; continue
                    # 字符串状态
                    if d == '\\':
                        j += 2; continue
                    if d == sub_mode[3]:
                        sub_mode = 'code'
                    j += 1; continue
                if depth != 0:
                    errs.append(f'{path}:{sub_line} 模板串 ${{...}} 内的括号不配平')
                i = j; line = sub_line; continue
            i += 1; continue

    if mode not in ('code', 'line_comment'):
        errs.append(f'{path}:{line} 文件结束时仍停留在 {mode} 状态（注释/字符串未闭合）')
    for op, ln in stack:
        errs.append(f'{path}:{ln} 未闭合的 {op}')
    return errs


def main():
    all_errs = []
    for name in FILES:
        p = os.path.join(ROOT, 'js', name)
        errs = check(p)
        status = 'OK' if not errs else 'FAIL'
        print(f'  [{status}] js/{name}' + ('' if not errs else f'  ({len(errs)} 个问题)'))
        all_errs += errs
    if all_errs:
        print()
        for e in all_errs:
            print('   ', e)
    print(f'\n失败 {len(all_errs)} 项')
    return 1 if all_errs else 0


if __name__ == '__main__':
    sys.exit(main())
