"""configfile.py —— `data/config.json` 的**原地最小改动**读写（无界面，可无头测试）。

★ 为什么不走「json.load → 改字典 → json.dump 整份重写」

    `config.json` 是**手写 + 带注释**的文件：那些 `"_comment"` 键就是文档本体，
    而且很多条目刻意压在一行里（`"wall": { "id": "wall", "name": "城墙", … }`）。
    实测：把现在这份文件整份 `json.dumps(indent=2)` 重排，898 行里**约 320 行**会变 ——
    设计师只想改一个「建造时间」，diff 里却躺着三百行格式噪音，
    git blame / review / 回滚全部作废。

    所以本模块做的是「**只动被改的那几个字符**」：改一个数 = 替换那几个字节，
    文件里其它部分逐字节不变（有断言钉着，见 test_model.py 的
    `[0] 原地最小改动` 那一组：无改动保存 == 原文件；改一个数只多出一处 diff）。

★ 解析模型

    `Doc.parse(text)` 走一遍递归下降，给**每个值**记下它在原文里的字符区间
    （`Node.start` / `Node.end`）。所有编辑 = 按区间做一次字符串拼接，
    拼完**整份重新解析**（50 KB 实测 1~3 ms，界面里一次编辑完全够用）——
    于是「区间失效」这一类 bug 在结构上就不存在了。
    ⚠️ 不做增量区间维护是**故意**的：省下的那几毫秒不值得换来一套会错位的区间簿记。

★ 尾逗号

    Godot 的 JSON 解析器**容忍尾逗号**（实测：`config.json` 里 tech._comment 那句尾逗号
    让 Python 的 `json` 直接报错，而游戏读得进去，test_smoke 全绿）。
    所以本模块读的时候也容忍（逗号之后直接遇到 `]` / `}` 就当容器结束），
    但**永远不会写**尾逗号 —— 保存出来的都是严格合法的 JSON，
    于是编辑器第一次保存就把那个尾逗号顺手清掉了。

界面那一层只用这几个入口：`value` / `set` / `remove` / `append` / `text`。
"""

from __future__ import annotations

import json
import re
from typing import Any, Dict, List, Optional, Tuple, Union

#: 路径 = 一串键（字典的字符串键 / 数组的下标），从根往下走。
Path = List[Union[str, int]]

#: JSON 里的空白（与 `json` 模块一致）
_WS = " \t\r\n"
#: 数字字面量（严格 JSON：不允许 `.5` / `1.` / `+1`）
_NUM_RE = re.compile(r"-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?")

#: 标量在文件里的「原样」写法（重新格式化时用）。int / float 分开是刻意的：
#: 文件里 `0` 与 `0.0` 是两种写法，改一个值不该把它换成另一种（diff 越小越好）。
_SCALAR_KINDS = ("str", "num", "bool", "null")


class JsonError(Exception):
    """JSON 文本本身有问题（消息里带出错的位置）。"""


def path_text(path: Path) -> str:
    """路径 → 给人看的写法（`unit.types.spearman.hp_max`）。"""
    out = ""
    for part in path:
        if isinstance(part, int):
            out += "[%d]" % part
        else:
            out += ("." if out else "") + str(part)
    return out


class Node:
    """一个 JSON 值 + 它在原文里的位置。

    kind: "dict" / "list" / "str" / "num" / "bool" / "null"
    start / end: 这个值在原文里的字符区间（`end` 不含）
    """

    __slots__ = ("kind", "start", "end", "value", "raw",
                 "entries", "order", "key_starts", "items", "open_pos", "close_pos")

    def __init__(self, kind: str, start: int, end: int,
                 value: Any = None, raw: str = "") -> None:
        self.kind = kind
        self.start = start
        self.end = end
        self.value = value
        self.raw = raw
        # ---- 容器（kind == "dict" / "list"）
        self.entries: Dict[str, "Node"] = {}      # dict：键 → 值节点
        self.order: List[str] = []                # dict：键的出现顺序
        self.key_starts: Dict[str, int] = {}      # dict：键的字符串**开头引号**的位置
        self.items: List["Node"] = []             # list：元素
        self.open_pos = -1                        # 容器的 `{` / `[`
        self.close_pos = -1                       # 容器的 `}` / `]`

    @property
    def is_scalar(self) -> bool:
        return self.kind in _SCALAR_KINDS

    def children(self) -> List["Node"]:
        """容器的子节点（按出现顺序）；标量返回空表。"""
        if self.kind == "dict":
            return [self.entries[k] for k in self.order]
        if self.kind == "list":
            return list(self.items)
        return []

    def __repr__(self) -> str:                      # pragma: no cover - 调试用
        return "<Node %s [%d:%d]>" % (self.kind, self.start, self.end)


# ======================================================================
# 解析
# ======================================================================

class _Parser:
    def __init__(self, text: str) -> None:
        self.s = text
        self.i = 0
        self.n = len(text)
        #: 容忍进来的**尾逗号**位置（见文件头那一节）。Doc 会把它们擦掉。
        self.trailing_commas: List[int] = []

    # ---- 入口
    def parse(self) -> Node:
        node = self._value()
        self._ws()
        if self.i != self.n:
            raise JsonError("JSON 末尾还有多余内容（第 %d 个字符处：%r）"
                            % (self.i, self.s[self.i:self.i + 24]))
        return node

    # ---- 基础
    def _ws(self) -> None:
        while self.i < self.n and self.s[self.i] in _WS:
            self.i += 1

    def _line_start(self, pos: int) -> int:
        j = self.s.rfind("\n", 0, pos)
        return 0 if j < 0 else j + 1

    def _value(self) -> Node:
        self._ws()
        if self.i >= self.n:
            raise JsonError("JSON 在这里就结束了（第 %d 个字符之后没有值）" % self.i)
        c = self.s[self.i]
        if c == "{":
            return self._object()
        if c == "[":
            return self._array()
        if c == '"':
            return self._string()
        for lit, kind in (("true", "bool"), ("false", "bool"), ("null", "null")):
            if self.s.startswith(lit, self.i):
                start = self.i
                self.i += len(lit)
                value = None if kind == "null" else (lit == "true")
                return Node(kind, start, self.i, value=value, raw=lit)
        m = _NUM_RE.match(self.s, self.i)
        if m is not None:
            raw = m.group(0)
            start = self.i
            self.i = m.end()
            return Node("num", start, self.i, value=_num_value(raw), raw=raw)
        raise JsonError("第 %d 个字符处不是合法的 JSON 值：%r"
                        % (self.i, self.s[self.i:self.i + 24]))

    def _string(self) -> Node:
        start = self.i
        value = self._scan_string()
        return Node("str", start, self.i, value=value, raw=self.s[start:self.i])

    def _scan_string(self) -> str:
        """扫一个字符串，返回它的**值**；`self.i` 停在收尾引号之后。"""
        assert self.s[self.i] == '"'
        j = self.i + 1
        out: List[str] = []
        while True:
            if j >= self.n:
                raise JsonError("字符串没有收尾引号（从第 %d 个字符开始）" % self.i)
            c = self.s[j]
            if c == '"':
                j += 1
                break
            if c == "\\":
                if j + 1 >= self.n:
                    raise JsonError("转义符后面没有东西（第 %d 个字符）" % j)
                esc = self.s[j + 1]
                if esc == "u":
                    hexs = self.s[j + 2:j + 6]
                    if len(hexs) < 4:
                        raise JsonError("\\u 后面缺 4 位十六进制（第 %d 个字符）" % j)
                    try:
                        out.append(chr(int(hexs, 16)))
                    except ValueError:
                        raise JsonError("\\u%s 不是合法的十六进制" % hexs)
                    j += 6
                    continue
                simple = {"n": "\n", "t": "\t", "r": "\r", "b": "\b",
                          "f": "\f", '"': '"', "\\": "\\", "/": "/"}
                if esc not in simple:
                    # ★ 严格 JSON 不认这个转义 —— 但也没必要为此让编辑器打不开文件，
                    #   原样留着（它照样是合法字符序列，只是我们解不出来）。
                    out.append("\\" + esc)
                else:
                    out.append(simple[esc])
                j += 2
                continue
            out.append(c)
            j += 1
        self.i = j
        return "".join(out)

    def _object(self) -> Node:
        node = Node("dict", self.i, -1)
        node.open_pos = self.i
        self.i += 1                                   # '{'
        self._ws()
        if self.i < self.n and self.s[self.i] == "}":
            node.close_pos = self.i
            self.i += 1
            node.end = self.i
            return node
        while True:
            self._ws()
            if self.i >= self.n:
                raise JsonError("对象没有收尾的 `}`（从第 %d 个字符开始）" % node.open_pos)
            if self.s[self.i] != '"':
                raise JsonError("对象的键必须是字符串（第 %d 个字符：%r）"
                                % (self.i, self.s[self.i:self.i + 16]))
            kstart = self.i
            key = self._scan_string()
            self._ws()
            if self.i >= self.n or self.s[self.i] != ":":
                raise JsonError("键 %r 后面缺 `:`（第 %d 个字符）" % (key, self.i))
            self.i += 1
            value = self._value()
            node.entries[key] = value
            node.order.append(key)
            node.key_starts[key] = kstart
            self._ws()
            if self.i < self.n and self.s[self.i] == ",":
                comma = self.i
                self.i += 1
                self._ws()
                # ★ 容忍尾逗号：`,` 之后直接是 `}` 就当对象结束（见文件头）
                if self.i < self.n and self.s[self.i] == "}":
                    self.trailing_commas.append(comma)
                    break
                continue
            break
        self._ws()
        if self.i >= self.n or self.s[self.i] != "}":
            raise JsonError("对象没有收尾的 `}`（从第 %d 个字符开始）" % node.open_pos)
        node.close_pos = self.i
        self.i += 1
        node.end = self.i
        return node

    def _array(self) -> Node:
        node = Node("list", self.i, -1)
        node.open_pos = self.i
        self.i += 1                                   # '['
        self._ws()
        if self.i < self.n and self.s[self.i] == "]":
            node.close_pos = self.i
            self.i += 1
            node.end = self.i
            return node
        while True:
            node.items.append(self._value())
            self._ws()
            if self.i < self.n and self.s[self.i] == ",":
                comma = self.i
                self.i += 1
                self._ws()
                if self.i < self.n and self.s[self.i] == "]":
                    self.trailing_commas.append(comma)
                    break
                continue
            break
        self._ws()
        if self.i >= self.n or self.s[self.i] != "]":
            raise JsonError("数组没有收尾的 `]`（从第 %d 个字符开始）" % node.open_pos)
        node.close_pos = self.i
        self.i += 1
        node.end = self.i
        return node


def _num_value(raw: str) -> Union[int, float]:
    if any(ch in raw for ch in ".eE"):
        return float(raw)
    return int(raw)


def parse_number(text: str) -> Optional[Union[int, float]]:
    """把界面输入框里的文字解析成数字；不是数字返回 None。

    ★ 与 `float()` 的差别（这两条都是**给设计师用的**取舍）：
      · 只认严格 JSON 数字 -> 不认 `nan` / `inf` / `1_000`（别把非法 JSON 写进文件）；
      · `"8"` → int 8、`"8.0"` → float 8.0 -> **写回去时保持设计师的写法**，
        不把 `0` 变成 `0.0`（那是 diff 噪音）。
    """
    s = text.strip()
    if not s:
        return None
    if s.startswith("+"):
        s = s[1:]
    m = _NUM_RE.fullmatch(s)
    if m is None:
        return None
    try:
        return _num_value(s)
    except ValueError:                                # pragma: no cover - 正则已挡住
        return None


# ======================================================================
# 文档
# ======================================================================

class Doc:
    """一份 JSON 文本 + 每个值的位置；所有编辑都是「拼接 + 重新解析」。"""

    def __init__(self, text: str) -> None:
        parser = _Parser(text)
        self.root = parser.parse()
        self._text = text
        #: 改过几次（界面用它判断「脏」；重新载入会归零）
        self.edits = 0
        if parser.trailing_commas:
            # ★ 容忍进来的尾逗号在这里**擦掉**：读的时候不跟它计较（Godot 也不计较），
            #   但写出去的一律是严格合法的 JSON —— 于是「手改 config.json 时多打了一个逗号」
            #   这种历史遗留会在编辑器第一次保存时被顺手治好。
            pieces: List[str] = []
            prev = 0
            for pos in sorted(parser.trailing_commas):
                pieces.append(text[prev:pos])
                prev = pos + 1
            pieces.append(text[prev:])
            self._text = "".join(pieces)
            self.root = _Parser(self._text).parse()

    # ------------------------------------------------------------------
    # 读
    # ------------------------------------------------------------------

    @property
    def text(self) -> str:
        return self._text

    def get(self, path: Path) -> Optional[Node]:
        """按路径取节点；路径不存在返回 None。"""
        node = self.root
        for part in path:
            if isinstance(part, int):
                if node.kind != "list" or part < 0 or part >= len(node.items):
                    return None
                node = node.items[part]
            else:
                if node.kind != "dict" or part not in node.entries:
                    return None
                node = node.entries[part]
        return node

    def has(self, path: Path) -> bool:
        return self.get(path) is not None

    def value(self, path: Path, default: Any = None) -> Any:
        """按路径取**纯 Python 值**（容器会被递归展开成一棵新的字典/列表）。

        ⚠️ 返回的是**拷贝**：改它不会影响文档（这是刻意的 —— 想改就调 `set`）。
           返回拷贝而不是原来那份的理由：模型层要拿它当只读快照做判断，
           直接给内部结构的话，谁手滑改一下就把「位置簿记」弄脏了。
        """
        node = self.get(path)
        return default if node is None else _materialize(node)

    def text_of(self, path: Path) -> str:
        """节点在原文里的**原样文本**（复制一个条目的样式时用）。"""
        node = self.get(path)
        if node is None:
            raise JsonError("路径不存在：%s" % path_text(path))
        return self._text[node.start:node.end]

    def keys(self, path: Path) -> List[str]:
        node = self.get(path)
        return list(node.order) if node is not None and node.kind == "dict" else []

    def size(self, path: Path) -> int:
        node = self.get(path)
        if node is None:
            return 0
        if node.kind == "dict":
            return len(node.order)
        if node.kind == "list":
            return len(node.items)
        return 0

    def entry_keys(self, path: Path) -> List[str]:
        """`keys` 的别名（界面/模型里读得更顺）。"""
        return self.keys(path)

    # ------------------------------------------------------------------
    # 写
    # ------------------------------------------------------------------

    def set(self, path: Path, value: Any) -> None:
        """把一个值写进指定路径：键已存在就**只替换那个值的文本**，不存在就插入。"""
        if not path:
            raise JsonError("不能整体替换根节点")
        parent = self.get(path[:-1])
        if parent is None:
            raise JsonError("父路径不存在：%s" % path_text(path[:-1]))
        key = path[-1]
        if parent.kind == "dict":
            name = str(key)
            node = parent.entries.get(name)
            if node is None:
                self._grow(parent, '"%s": %s' % (_escape_key(name),
                                                 self._format(value, parent)))
            else:
                self._splice(node.start, node.end, self._format(value, parent))
            return
        if parent.kind == "list":
            if not isinstance(key, int) or key < 0 or key >= len(parent.items):
                raise JsonError("数组下标越界：%s" % path_text(path))
            node = parent.items[key]
            self._splice(node.start, node.end, self._format(value, parent))
            return
        raise JsonError("父节点不是容器（%s 是 %s）" % (path_text(path[:-1]), parent.kind))

    def remove(self, path: Path) -> None:
        """删掉一个键（字典）或一个元素（数组，路径末位是下标）。"""
        if not path:
            raise JsonError("不能删掉根节点")
        parent = self.get(path[:-1])
        if parent is None:
            raise JsonError("父路径不存在：%s" % path_text(path[:-1]))
        key = path[-1]
        if parent.kind == "dict":
            name = str(key)
            if name not in parent.entries:
                raise JsonError("这个键不存在：%s" % path_text(path))
            idx = parent.order.index(name)
        elif parent.kind == "list":
            if not isinstance(key, int) or key < 0 or key >= len(parent.items):
                raise JsonError("数组下标越界：%s" % path_text(path))
            idx = key
        else:
            raise JsonError("父节点不是容器：%s" % path_text(path[:-1]))
        # ★ 一并吃掉**连接用的那个逗号与空白**，否则会留下 `{ "a": 1, }` 这种尾巴
        #   （严格 JSON 不许尾逗号 —— 而那正是本模块永远不写的东西）。
        if len(parent.children()) == 1:
            # 独苗：整对括号收成紧凑写法（`{}` / `[]`）——
            # 不然「加一个键再删掉」会在文件里留下一块三行的空字典。
            empty = "{}" if parent.kind == "dict" else "[]"
            self._splice(parent.open_pos, parent.close_pos + 1, empty)
            return
        s, e = self._removal_span(parent, idx)
        self._splice(s, e, "")

    def append(self, path: Path, value: Any) -> int:
        """往数组尾部插一个值；返回它的下标。"""
        node = self.get(path)
        if node is None or node.kind != "list":
            raise JsonError("不是数组（或不存在）：%s" % path_text(path))
        self._grow(node, self._format(value, node))
        return len(node.items)

    def append_raw(self, path: Path, raw: str) -> None:
        """往数组尾部插一段**现成的 JSON 文本**（复制条目的样式时用）。

        ⚠️ 调用方保证 `raw` 是合法 JSON —— 本模块会立刻整份重新解析，
           拼错了会当场抛 JsonError，不会把坏文本留在内存里。
        """
        node = self.get(path)
        if node is None or node.kind != "list":
            raise JsonError("不是数组（或不存在）：%s" % path_text(path))
        self._grow(node, raw)

    def insert_raw(self, path: Path, key: str, raw: str) -> None:
        """往字典里插一个键，值用**现成的 JSON 文本**（`append_raw` 的字典版）。"""
        node = self.get(path)
        if node is None or node.kind != "dict":
            raise JsonError("不是对象（或不存在）：%s" % path_text(path))
        self._grow(node, '"%s": %s' % (_escape_key(key), raw))

    def set_many(self, items: List[Tuple[Path, Any]]) -> None:
        """一次改多处（每次都重新解析，但界面只重建一次 —— 加单位那种批量动作用）。"""
        for path, value in items:
            self.set(path, value)

    # ------------------------------------------------------------------
    # 内部：拼接
    # ------------------------------------------------------------------

    def _splice(self, start: int, end: int, replacement: str) -> None:
        text = self._text[:start] + replacement + self._text[end:]
        try:
            root = _Parser(text).parse()
        except JsonError as exc:                      # pragma: no cover - 有 bug 才会走到
            raise JsonError("内部错误：这次修改会写出坏 JSON（%s）" % exc)
        self._text = text
        self.root = root
        self.edits += 1

    def _single_line(self, node: Node) -> bool:
        return "\n" not in self._text[node.start:node.end]

    def _child_indent(self, node: Node) -> int:
        """容器里的子项该缩进几格：照现有子项，空容器就按所在行 + 2。"""
        kids = node.children()
        if kids:
            head = node.key_starts[node.order[0]] if node.kind == "dict" else kids[0].start
            return head - self._line_start(head)
        return self._line_indent(node.open_pos) + 2

    def _line_start(self, pos: int) -> int:
        j = self._text.rfind("\n", 0, pos)
        return 0 if j < 0 else j + 1

    def _line_indent(self, pos: int) -> int:
        """某一行开头有几个空格。"""
        start = self._line_start(pos)
        col = 0
        while start + col < len(self._text) and self._text[start + col] == " ":
            col += 1
        return col

    def _separator(self, container: Node) -> str:
        """往容器里加东西之前要先写的那段东西（逗号 / 换行 / 缩进）。"""
        last = container.children()[-1]
        if self._single_line(container):
            return ", "
        # 多行容器：把新项放在最后一个子项**下面**，缩进与它对齐
        return ",\n" + " " * (last.start - self._line_start(last.start))

    def _grow(self, container: Node, body: str) -> None:
        """把 `body`（一段 JSON 文本）加进容器的末尾。

        ★ 插入点是**最后一个子项的结尾**，不是收尾括号的位置：
          收尾括号前面还压着 `\\n` + 外层缩进（`\\n    ]`），
          在括号位置上插会写成
              }
            ,
              { … }
          （实测踩到过 —— 合法但难看得离谱）。
        ★ 空容器走另一条路：`{}` / `[ ]` 里没有「上一项」可以挂逗号，
          只能把整对括号**撑开成多行**再放进去（`{\\n  "k": v\\n}`）。
        """
        kids = container.children()
        if not kids:
            indent = self._line_indent(container.open_pos) + 2
            outer = max(0, indent - 2)
            open_ch, close_ch = ("{", "}") if container.kind == "dict" else ("[", "]")
            self._splice(container.open_pos, container.close_pos + 1,
                         "%s\n%s%s\n%s%s" % (open_ch, " " * indent, body,
                                             " " * outer, close_ch))
            return
        end = kids[-1].end
        self._splice(end, end, self._separator(container) + body)

    def _format(self, value: Any, container: Node) -> str:
        """把一个 Python 值渲染成 JSON 文本（缩进照容器现在的位置）。"""
        indent = self._child_indent(container)
        return _dump(value, indent)

    def _child_span(self, parent: Node, idx: int) -> Tuple[int, int]:
        """第 idx 个子项在原文里的区间。

        ⚠️ 字典要**从键的引号开始**（不是从值的开头）—— 少了这一段就会留下
           `"名字": ` 这种半截东西。
        """
        if parent.kind == "dict":
            name = parent.order[idx]
            return parent.key_starts[name], parent.entries[name].end
        kid = parent.items[idx]
        return kid.start, kid.end

    def _removal_span(self, parent: Node, idx: int) -> Tuple[int, int]:
        """删第 idx 个子项时要一并吃掉的区间（带前后的逗号与空白）。"""
        count = len(parent.children())
        start, end = self._child_span(parent, idx)
        if idx + 1 < count:
            # 后面还有兄弟：吃掉「自己 + 到下一个兄弟之间的逗号与空白」
            return start, self._child_span(parent, idx + 1)[0]
        if idx > 0:
            # 自己是最后一个：吃掉「上一个兄弟的结尾之后到自己的结尾」
            return self._child_span(parent, idx - 1)[1], end
        # 独苗：只剩一对括号
        return start, end


def _dump(value: Any, indent: int) -> str:
    """把一个 Python 值渲染成 JSON 文本；容器按「一项一行」展开。"""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        if isinstance(value, float):
            if value != value or value in (float("inf"), float("-inf")):
                raise JsonError("不能把 %r 写进 JSON" % value)
        return json.dumps(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, dict):
        if not value:
            return "{}"
        pad = " " * (indent + 2)
        body = ",\n".join('%s"%s": %s' % (pad, _escape_key(str(k)), _dump(v, indent + 2))
                          for k, v in value.items())
        return "{\n%s\n%s}" % (body, " " * indent)
    if isinstance(value, (list, tuple)):
        if not value:
            return "[]"
        pad = " " * (indent + 2)
        body = ",\n".join("%s%s" % (pad, _dump(v, indent + 2)) for v in value)
        return "[\n%s\n%s]" % (body, " " * indent)
    raise JsonError("不认识的值类型：%r" % type(value))


def _materialize(node: Node) -> Any:
    """Node → 纯 Python 值（容器递归拷贝）。"""
    if node.kind == "dict":
        return {k: _materialize(node.entries[k]) for k in node.order}
    if node.kind == "list":
        return [_materialize(item) for item in node.items]
    return node.value


def _escape_key(key: str) -> str:
    return key.replace("\\", "\\\\").replace('"', '\\"')
