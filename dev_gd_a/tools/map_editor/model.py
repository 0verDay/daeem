"""model.py —— 地图编辑器的数据层（不依赖 tkinter，可无头测试）。

设计来源（与项目里已有的约定对齐，改之前先看这几处）：

  · 地形只有三种：grass / forest / mountain（dev_gd_a/daeem/logic/map_data.gd 的 TERRAIN_*）。
  · 「地块存在与否」是**独立于地形**的一件事：JSON 里多一张 ``exists`` 网格。
    地图可以不是规则矩形（拖出一个 L 形），但内部不会缺格。
    Godot 侧读它：exists=0 的地块一律不可通行（见 map_data.gd 的 exists 字段）。
  · 区块是**逐格分配**的：每张地图给出一张 ``zones`` 网格（地块 → 区块 id，-1 = 不属任何区块）。
    zone.gd 的注释里一直写着「等地图编辑器给出真正的区块网格」，这里就是那张网格。
  · 颜色与大本营默认值都从 ``data/config.json`` 读，编辑器里不写死配色。

坐标一律是「格」（整数 tx, ty），原点在左上角，与逻辑层一致。
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

# ----------------------------------------------------------------------
# 常量
# ----------------------------------------------------------------------

#: 地形 id → 图例字符（与 map_data.gd 的 LAYOUT_LEGEND 一一对应）
TERRAIN_CHARS: Dict[str, str] = {
    "grass": ".",
    "forest": "^",
    "mountain": "#",
}
CHAR_TERRAINS: Dict[str, str] = {v: k for k, v in TERRAIN_CHARS.items()}
#: 旧文件里的 'B' 是注释性质的遗留字符，读进来当草地（map_data.gd 也这么干）
CHAR_TERRAINS["B"] = "grass"

#: 编辑器里能选的地形（顺序 = 界面上按钮的顺序）
TERRAIN_ORDER: Tuple[str, ...] = ("grass", "forest", "mountain")

#: 阵营 id 的规矩：就是**游戏里那套字符串**（logic/faction.gd 的 DEFAULT_FACTION /
#: FACTION_ROSTER / NPC_FACTION）。编辑器不自己编号，也不做翻译表 ——
#: 这样导出的 `faction_bases` 里可以直接写 `{"p2": [3, 4]}`，Godot 按 id 就查得到。
#:
#: ★ 没有 'player' 这个别名了（改过一版）：单机 / 房主就是 **p1**。
#:   以前单机引擎找 'player'、地图里划的却是 p1/p2，两边对不上 ——
#:   症状是「地图里明明给 p1 划了大本营，单机跑起来却用默认点位」。
FACTION_ENEMY = "enemy"
FACTION_ROSTER: Tuple[str, ...] = ("p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8")
#: 单机 / 房主的阵营 id（与 logic/faction.gd 的 DEFAULT_FACTION 一致）
FACTION_DEFAULT = "p1"

#: 「这是不是游戏认识的阵营 id」——只用来在导出前提醒，**不阻止**设计师写别的。
#: （导出一个游戏不认识的阵营名不会崩：Godot 那边按 id 查不到大本营就走旧行为。）
KNOWN_FACTIONS: Tuple[str, ...] = (FACTION_ENEMY,) + FACTION_ROSTER

#: 新增阵营时的兜底配色（取 config.json 的 colors.faction 里那几档，读不到就用这些）。
#: ⚠️ 它只是**编辑器里标识哪个阵营**用的颜色，游戏不读它（游戏的颜色在 config.json）。
FACTION_PALETTE: Tuple[str, ...] = (
    "#ffd166", "#5ac8ff", "#8ce08c", "#c9a0ff",
    "#ffb0b0", "#ffd9a0", "#a0e8e0", "#d0a0ff", "#e05a5a",
)

TERRAIN_LABELS: Dict[str, str] = {
    "grass": "草地",
    "forest": "森林",
    "mountain": "山地",
}

#: 兜底配色（config.json 读不到时用；正常情况下都从 config 读）
DEFAULT_COLORS: Dict[str, object] = {
    "grass": "#33422f",
    "grass_alt": "#2f3d2c",
    "forest": "#24402a",
    "mountain": "#4c4a45",
    "mountain_edge": "#5f5c55",
    "grid": "rgba(255,255,255,0.055)",
    "grid_strong": "rgba(255,255,255,0.12)",
    "zone_line": "rgba(255,255,255,0.10)",
    "zone_neutral": "rgba(230,190,80,0.05)",
    "zone_player": "rgba(90,200,255,0.13)",
    "base": "#4a90d9",
}

#: 区块配色循环（编辑器用，取的是 config colors.faction 里那几档的观感）
ZONE_PALETTE: Tuple[str, ...] = (
    "#e6be50", "#5ac8ff", "#8ce08c", "#c9a0ff",
    "#ffb0b0", "#ffd9a0", "#a0e8e0", "#d0a0ff",
    "#7ce07c", "#6ea8e8", "#d98a5a", "#b0b0d0",
)

Tile = Tuple[int, int]

ROW_LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
#: 新建区块的默认名（区块1号 / 区块2号 …）——带个「号」是为了让「区块1号」和
#: 用户自己起的「区块1444」区分得开：默认名要能重新编号，用户的名字不能动。
DEFAULT_ZONE_NAME_FORMAT = "区块{}号"

#: 兜底上限：格子坐标落在 `-MAX_COORD … MAX_COORD-1` 之内都接受（四个方向都是）。
#:
#: ★ 为什么是 4096 而不是原来的 512，也不是更大的数：
#:   · 512 太容易撞上（那是一条**隐形**的边界：越界时只在状态栏提示一句），
#:     设计师画到那儿会以为编辑器坏了；
#:   · 4096×4096 = 1600 万格，是「一张 RTS 地图」的一百多倍（24×16 的图是 0.04% 于它），
#:     正常画图撞不到；
#:   · 再往上就没有意义了 —— 内存里的网格是**稠密数组**（每个方向都要按最大坐标算宽），
#:     8192 需要 ~600 MB、16384 需要 ~2.3 GB，编辑器会被系统直接杀掉。
#:     与其给一个「写着无限、一点就崩」的数，不如给一个真能画到的边界，
#:     而且撞到边界时状态栏把话说清楚（不再有隐形线）。
#:
#: ⚠️ 真·无上限要把 existing/terrain 换成稀疏 dict（只存画过的格子）——
#: 那是一次数据层重写，与「地图尺寸」这件事无关，要做请单独一轮。
MAX_COORD = 4096
#: 网格一次至少长这么多格（配合增量生长，避免连着画时反复重建数组）
MIN_GROW_STEP = 16

#: 每次生长多留这么多格的余量（见 _grow_to_include：按需长 + 余量，
#: 而不是把网格倍增 —— 倍增会在「在很远的地方误点一下」时分配一整片方阵）。
#: 实际余量取 `min(它, 当前边长)`，所以小地图不会被余量撑大（第一次点击是 16×16 而不是 257×257）。
GROW_MARGIN = 256

#: 网格最多占多少内存（粗略估算，超出就拒绝落笔）。
#: ★ 这是**安全网**，正常情况下撞不到它：MAX_COORD 之内的最大网格（约 4097×4097）
#:   只要 ~150 MB。它拦的是「有人把 MAX_COORD 调大」或几何上的意外组合 ——
#:   稠密数组的占用是 O(面积)，到 2 GB 那一档进程会被系统直接杀掉，
#:   那一下宁可拒绝落笔，也不要「窗口突然没了」。
MAX_GRID_BYTES = 512 * 1024 * 1024

#: 估算一格的字节数：existing 一个 bool 引用 + terrain 一个字符串引用（两个 8 字节指针）
#: 再加对象本身的均摊。粗糙但足够用来「拦住会 OOM 的那一下」。
_BYTES_PER_TILE = 9

#: 导出的地图超过这个边长（格）就在导出前提醒一句（**不阻止**导出）。
#: 512×512 已经是 26 万格；再大下去 Godot 侧的稠密网格就要吃掉几十上百 MB。
BIG_MAP_WARN_TILES = 512


class MapError(Exception):
    """地图数据本身有问题（不是文件读不到那种 IO 错误）。"""


#: 默认区块名的前缀与后缀（"区块" + 数字 + "号"），用来判断一个名字是不是「还没改过」
_ZONE_NAME_PREFIX = "区块"
_ZONE_NAME_SUFFIX = "号"


def _is_default_zone_name(name: str) -> bool:
    """这个名字是不是自动生成的（还是默认名 → 删区块时可以重新编号）。"""
    if not (name.startswith(_ZONE_NAME_PREFIX) and name.endswith(_ZONE_NAME_SUFFIX)):
        return False
    middle = name[len(_ZONE_NAME_PREFIX):len(name) - len(_ZONE_NAME_SUFFIX)]
    return middle.isdigit()


# ----------------------------------------------------------------------
# 颜色
# ----------------------------------------------------------------------

def parse_color(text, fallback=(255, 0, 255, 1.0)) -> Tuple[int, int, int, float]:
    """config.json 里的颜色字符串 → (r, g, b, a)。

    支持 ``#rrggbb`` 与 ``rgba(r,g,b,a)`` / ``rgb(r,g,b)`` 两种写法，
    通道值 0~255 或 0~1 都能认（与 logic/config.gd 的 parse_color 同口径）。
    a 是 0~1 的浮点，其余是 0~255 的整数。
    """
    if not isinstance(text, str):
        return fallback
    t = text.strip()
    if t.startswith("#"):
        h = t[1:]
        if len(h) == 3:
            h = "".join(ch * 2 for ch in h)
        if len(h) == 6:
            try:
                return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), 1.0)
            except ValueError:
                return fallback
        if len(h) == 8:      # #rrggbbaa
            try:
                return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16),
                        int(h[6:8], 16) / 255.0)
            except ValueError:
                return fallback
        return fallback
    if t.startswith("rgba(") or t.startswith("rgb("):
        try:
            inner = t[t.index("(") + 1:t.index(")")]
            parts = [p.strip() for p in inner.split(",")]
            vals = [float(p) for p in parts]
        except (ValueError, IndexError):
            return fallback
        if len(vals) < 3:
            return fallback
        scale = 1.0 if max(vals[0], vals[1], vals[2]) > 1.0 else 255.0
        a = vals[3] if len(vals) >= 4 else 1.0
        return (int(vals[0] * scale), int(vals[1] * scale), int(vals[2] * scale), float(a))
    return fallback


def to_hex(rgb: Sequence[float]) -> str:
    """(r, g, b[, a]) → '#rrggbb'（tkinter 认这个）。"""
    r, g, b = (max(0, min(255, int(round(float(v))))) for v in rgb[:3])
    return "#%02x%02x%02x" % (r, g, b)


def blend(bottom: Sequence[float], top: Sequence[float], k: float) -> Tuple[int, int, int, float]:
    """把带 alpha 的 top 叠在 bottom 上（k = 额外的不透明度倍率）。

    tkinter 的 Canvas 不支持 alpha，所以编辑器只能自己把半透明色压成实色。
    """
    k = max(0.0, min(1.0, k)) * float(top[3] if len(top) > 3 else 1.0)
    out = [float(bottom[i]) * (1.0 - k) + float(top[i]) * k for i in range(3)]
    return (int(round(out[0])), int(round(out[1])), int(round(out[2])), 1.0)


# ----------------------------------------------------------------------
# config.json
# ----------------------------------------------------------------------

def load_config(project_dir: Path) -> dict:
    """读 ``dev_gd_a/daeem/data/config.json``（读不到就返回 {}，用兜底配色）。"""
    path = Path(project_dir) / "data" / "config.json"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return {}
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def config_colors(cfg: dict) -> Dict[str, object]:
    """把 config.json 的 colors.* 取出来（缺项用 DEFAULT_COLORS 兜底）。"""
    out: Dict[str, object] = dict(DEFAULT_COLORS)
    colors = cfg.get("colors") if isinstance(cfg, dict) else None
    if isinstance(colors, dict):
        for key, value in colors.items():
            if isinstance(value, str):
                out[key] = value
    return out


def config_grid(cfg: dict) -> Tuple[int, int]:
    """config.json 的 grid.cols / grid.rows —— 编辑器的默认画布尺寸。"""
    grid = cfg.get("grid") if isinstance(cfg, dict) else None
    if isinstance(grid, dict):
        try:
            return (int(grid.get("cols", 24)), int(grid.get("rows", 16)))
        except (TypeError, ValueError):
            pass
    return (24, 16)


# ----------------------------------------------------------------------
# 地图模型
# ----------------------------------------------------------------------

class Faction:
    """一个阵营：游戏认识的 id + 显示名 + 颜色（颜色只给编辑器看）。

    ★ id 就是游戏里的阵营字符串（'p1'…'p8' / 'enemy'），
      不做数字映射 —— 导出的 ``faction_bases`` 直接以它为键，Godot 拿去就能用。
    """

    __slots__ = ("faction_id", "name", "color")

    def __init__(self, faction_id: str, name: str = "", color: str = "") -> None:
        self.faction_id = str(faction_id).strip()
        self.name = (name or self.faction_id).strip() or self.faction_id
        self.color = (color or FACTION_PALETTE[0]).strip().upper()

    def __repr__(self) -> str:  # pragma: no cover - 调试用
        return "Faction(%r, %r, %r)" % (self.faction_id, self.name, self.color)

    def label(self) -> str:
        """列表里显示成什么样：名字（id）—— 两边都看得见，免得改错了人。"""
        if self.name and self.name != self.faction_id:
            return "%s（%s）" % (self.name, self.faction_id)
        return self.faction_id


class Zone:
    """一个区块：一个名字 + 一组地块。

    地图上的区块是**逐格分配**的，所以不再有 x0/y0/x1/y1 那种矩形包围盒；
    但 Godot 侧的 zone_view 还按包围盒画底色，所以导出时会带一个最小包围盒。
    """

    __slots__ = ("zone_id", "name", "tiles")

    def __init__(self, zone_id: int, name: str = "") -> None:
        self.zone_id = int(zone_id)
        self.name = name or DEFAULT_ZONE_NAME_FORMAT.format(1)
        self.tiles: set[Tile] = set()

    def __repr__(self) -> str:  # pragma: no cover - 调试用
        return "Zone(%d, %r, %d tiles)" % (self.zone_id, self.name, len(self.tiles))

    @property
    def tile_count(self) -> int:
        return len(self.tiles)

    @property
    def bounds(self) -> Tuple[int, int, int, int]:
        """(x0, y0, x1, y1)；没有地块时返回 (0, 0, -1, -1)。"""
        if not self.tiles:
            return (0, 0, -1, -1)
        xs = [t[0] for t in self.tiles]
        ys = [t[1] for t in self.tiles]
        return (min(xs), min(ys), max(xs), max(ys))


class MapModel:
    """一张地图的内存形态：cols × rows 的画布 + 区块表。

    · ``existing``  : 画布上哪些格子真的存在（不存在 = 编辑器里的虚线格 = Godot 里不可通行）
    · ``terrain``   : 每个格子的地形；**不存在的格子也保留一个地形值**（默认草地），
                      这样撤销 / 重新启用一个格子不会丢掉地形。
    · ``zones``     : 区块表（含还没有任何地块的空区块）
    · ``zone_of``   : 地块 → 区块 id 的索引

    ★ 编辑器界面上的画布是**无限虚线格**（想画到哪里就画到哪里），
      而导出给 Godot 的地图必须是一张有限矩形网格。两者的接法是：
      内存里的网格按需**朝四个方向生长**——`ensure_tile()` 发现要点/要刷的格子
      在网格外时，就把网格扩到能装下它（按 MIN_GROW_STEP / 倍增），
      于是「先随便找块空地画」与「按 24×16 导出」两件事都不难。

    ★ 数组下标必须 ≥ 0，但设计师要能**往左上画**（世界坐标是负的）。
      接法：模型里存一份 ``origin``——世界坐标 (0,0) 对应数组里的 ``origin`` 那一格。
      往左上画到世界 x=-1 时，就整张网格右移/下移一格、origin 跟着减一，
      已经画好的内容、区块归属、大本营**全部跟着搬**，所以画面上一点都不动。
      于是「绝对坐标」只在编辑器界面与导出时存在，模型内部永远是 0 起的下标。
    """

    def __init__(self, cols: int, rows: int) -> None:
        self.cols = 0
        self.rows = 0
        self.existing: List[bool] = []
        self.terrain: List[str] = []
        self.zones: List[Zone] = []
        self.zone_of: Dict[int, int] = {}
        #: 世界坐标 (0, 0) 落在数组里的哪一格（见类注释里的「往左上画」）。
        #: 正常从 (0,0) 起画时它一直是 (0, 0)，对老代码没有任何影响。
        self.origin_x = 0
        self.origin_y = 0
        #: 已存在地块数（O(1) 查询：大网格下每帧扫一遍会卡）
        self._exists_count = 0
        #: 大本营点位（编辑器里唯一需要手工指定的出生点）——**世界坐标**
        self.base: Optional[Tile] = None
        #: 阵营表（id / 名字 / 颜色）与「每个阵营的大本营点位」——世界坐标。
        #:
        #: ★ 阵营 id 用的是**游戏那套字符串**（'p1'…'p8' / 'enemy'，
        #:   见 logic/faction.gd），不是编辑器自己编的号：这样导出后 Godot 直接按 id
        #:   就能找到「这一方的大本营在哪」，不需要任何翻译表。
        #: ★ 一个阵营只有一个大本营（对齐 Godot 的 TYPE_BASE：一方一座基地）。
        #: ★ 没设大本营的阵营**不写进 JSON**（`faction_bases` 里没有它的键），
        #:   Godot 那边就会退回旧行为（主阵营用地图中心的 base、其他按 pvp_points 轮流）。
        self.factions: List[Faction] = []
        self.faction_bases: Dict[str, Tile] = {}
        #: 从原文件里读到的、编辑器不管的字段（general_spawns / buildings / units / pvp_points /
        #: _comment …）——导出时原样写回，免得编辑器把 Godot 会用的东西吃掉。
        self.extra: Dict[str, object] = {}
        self.resize(cols, rows)

    # ---------------- 基本换算 ----------------

    def idx(self, x: int, y: int) -> int:
        return y * self.cols + x

    def coord(self, index: int) -> Tile:
        return (index % self.cols, index // self.cols)

    # ---------------- 世界坐标 ↔ 数组下标 ----------------
    #
    # ★ 模型对外的坐标一律是**世界坐标**（可以是负的，往左上画就是负的）；
    #   数组下标则必须是 0 起的。这两者的换算只有下面两个方法，别在别处自己减 origin。

    def view_of(self, x: int, y: int) -> Tile:
        """世界坐标 → 数组下标（模型内部用）。"""
        return (x + self.origin_x, y + self.origin_y)

    def world_of(self, x: int, y: int) -> Tile:
        """数组下标 → 世界坐标（界面与导出用）。"""
        return (x - self.origin_x, y - self.origin_y)

    def in_bounds(self, x: int, y: int) -> bool:
        """这个世界坐标在网格里吗（网格外 = 还没长到那儿）。"""
        vx, vy = self.view_of(x, y)
        return 0 <= vx < self.cols and 0 <= vy < self.rows

    def exists(self, x: int, y: int) -> bool:
        return self.in_bounds(x, y) and self.existing[self.idx(*self.view_of(x, y))]

    def terrain_at(self, x: int, y: int) -> str:
        if not self.in_bounds(x, y):
            return "grass"
        return self.terrain[self.idx(*self.view_of(x, y))]

    def existing_count(self) -> int:
        return self._exists_count

    def recount(self) -> int:
        """重算「已存在地块数」缓存。

        ⚠️ 任何**直接赋值** `self.existing` 的地方（导入地图、撤销快照恢复）都必须调它一次：
        `_exists_count` 只在 set_existing() 里增量维护，绕过那条路就会让计数与数组不一致
        （症状：刚导入的地图显示「地块 0」，导出时还以为图是空的）。
        """
        self._exists_count = sum(1 for flag in self.existing if flag)
        return self._exists_count

    def bounds(self) -> Optional[Tuple[int, int, int, int]]:
        """所有已存在地块的**世界坐标**包围盒；一个都没有时返回 None。

        ★ 这个包围盒就是「导出时地图有多大」：导出会把它的左上角搬到 (0,0)，
        宽高写进 JSON 的 cols/rows（见 mapfile.model_to_dict）。
        所以画布上的绝对位置不影响导出尺寸 —— 往左上画、把第一块地画在 (0,0) 左边，
        导出的地图一样是最小包围盒。
        """
        for i, flag in enumerate(self.existing):
            if flag:
                x0 = x1 = i % self.cols
                y0 = y1 = i // self.cols
                break
        else:
            return None
        for i, flag in enumerate(self.existing):
            if not flag:
                continue
            x, y = i % self.cols, i // self.cols
            x0, x1 = min(x0, x), max(x1, x)
            y0, y1 = min(y0, y), max(y1, y)
        # 数组下标 → 世界坐标（可能带负号）
        return (x0 - self.origin_x, y0 - self.origin_y,
                x1 - self.origin_x, y1 - self.origin_y)

    # ---------------- 地块 ----------------

    def set_existing(self, x: int, y: int, value: bool) -> bool:
        """把一个格子设成存在 / 不存在。返回是否真的变了。

        删除一个格子会连带处理两件「挂在格子上的东西」：
          · 把它从所属区块里摘掉（否则区块会留下一块「地图外的领地」）；
          · 如果它是某个阵营的大本营，就把那个大本营**忘掉**
            （留着一个指向虚线格的大本营，导出后 Godot 会找不到格子）。
        """
        if not self.in_bounds(x, y):
            return False
        i = self.idx(*self.view_of(x, y))
        value = bool(value)
        if self.existing[i] == value:
            return False
        self.existing[i] = value
        self._exists_count += 1 if value else -1
        if not value:
            self.clear_zone(x, y)
            self._drop_faction_base_at(x, y)
        return True

    def _drop_faction_base_at(self, x: int, y: int) -> None:
        """这一格没了 → 把以它为家的阵营大本营也清掉。"""
        owner = self.faction_base_owner(x, y)
        if owner is not None:
            self.faction_bases.pop(owner, None)

    def create_tile(self, x: int, y: int) -> bool:
        return self.set_existing(x, y, True)

    def delete_tile(self, x: int, y: int) -> bool:
        return self.set_existing(x, y, False)

    def set_terrain(self, x: int, y: int, terrain: str) -> bool:
        """改一格的地形（世界坐标）。不存在的格子改不了。"""
        if not self.in_bounds(x, y) or terrain not in TERRAIN_CHARS:
            return False
        i = self.idx(*self.view_of(x, y))
        if self.terrain[i] == terrain:
            return False
        self.terrain[i] = terrain
        return True

    ## ★ 编辑器界面的入口：这个格子现在还不存在，但我要往里点/刷 —— 先保证网格装得下它。
    ## (x, y) 是**世界坐标**，可以是负的（往左上画）：网格装不下就往那个方向长，
    ## 要往左上画时还会把整张数组平移一格让出位置（origin 同步加一）。
    ## 返回 False = 这一格装不下（超出 ±MAX_COORD，或会长到吃掉太多内存）。
    def ensure_tile(self, x: int, y: int) -> bool:
        if not self.can_draw_at(x, y):
            return False
        if self.in_bounds(x, y):
            return True
        return self._grow_to_include(x, y)

    ## 这一格**画得出来吗**（不看它现在存不存在）。
    ##
    ## ★ 为什么不能只看 `abs(x) < MAX_COORD`：数组下标 = 世界坐标 + origin，
    ##   而 origin 会随着「往左上画」变大 —— 于是往左上画得越多，右上方向的余量越小。
    ##   两个方向的边界是互相挤的，唯一的判据就是这个式子。
    ##   （界面上的提示/越界说明都读它，别在别处再写一份判断 —— 写两份必然对不上。）
    def can_draw_at(self, x: int, y: int) -> bool:
        vx, vy = self.view_of(x, y)
        return -MAX_COORD <= vx < MAX_COORD and -MAX_COORD <= vy < MAX_COORD

    ## 还能往哪个方向画多远（给状态栏用）。
    ##
    ## 返回 `((往左, 往上), (往右, 往下))`，四个数都是**格数**（非负）。
    ## 推导：数组下标 = 世界坐标 + origin，而画得出来的区间是 `-MAX_COORD ≤ 下标 < MAX_COORD`，
    ## 代进去就是世界坐标的可画区间 `[-MAX_COORD - origin, MAX_COORD - 1 - origin]`，
    ## 所以往左有 `坐标 + MAX_COORD + origin` 格、往右有 `MAX_COORD - 1 - origin - 坐标` 格。
    ## ⚠️ 左/上那两个是**加**、右/下是**减**，符号别写反（踩过：写反之后
    ##    「离边界还剩几格」永远算错，提示在边界上反而不出现）。
    def draw_room(self, x: int = 0, y: int = 0) -> Tuple[Tuple[int, int], Tuple[int, int]]:
        """从世界坐标 (x, y) 看，四个方向各还能画几格。"""
        return ((x + MAX_COORD + self.origin_x, y + MAX_COORD + self.origin_y),
                (MAX_COORD - 1 - self.origin_x - x, MAX_COORD - 1 - self.origin_y - y))

    ## ★ 生长量是「按需 + 一点余量」，**不是倍增**。这里换过一版：
    ##   原来 `new = max(need, cols * 2)` 是倍增，理由是「连续画一片新区域时把重建次数
    ##   压到 log 级」（每次重建都要把整个数组拷一遍）。但倍增有个要命的副作用：
    ##   在离原点很远的地方点一下（比如 (8000, 8000)），网格会被直接撑到
    ##   8000×8000=6400 万格 ≈ 1.1 GB，一次误点就能把编辑器拖死（实测：4096 那一跳
    ##   就 268 ms / 144 MB，16384 是 4.7 秒 / 2.3 GB）。
    ##   所以改成：**只长到「装得下 + 一点余量」**，把浪费从 O(面积) 降到 O(周长)。
    ##   代价是「连续往一个方向猛画」时会多重建几次 —— 但那是画地图，不是拖鼠标，
    ##   每次重建几十毫秒仍然可以接受（而且余量让它每几百格才重建一次）。
    ##
    ## ★ 再叠一层 `MAX_GRID_BYTES` 安全网：稠密数组的占用是 O(面积)，
    ##   到 2 GB 那一档进程会被系统直接杀掉 —— 那一下宁可拒绝落笔。
    def _grow_to_include(self, x: int, y: int) -> bool:
        # 平移量：往左上画时 (x, y) 是负的，数组要整体挪一格才让它落进下标。
        shift_x = max(0, -x - self.origin_x)
        shift_y = max(0, -y - self.origin_y)
        # 平移之后这一格的数组下标 = x + origin_x + shift_x（origin 也要跟着加 shift）。
        # 同时「平移出去的老内容」要留下 → 尺寸至少是 老尺寸 + 平移量。
        need_cols = max(self.cols + shift_x, x + self.origin_x + shift_x + 1)
        need_rows = max(self.rows + shift_y, y + self.origin_y + shift_y + 1)
        # 余量跟着当前尺寸走（小图不会一上来就占一大片）；基准取 max(当前, 需要) ——
        # ⚠️ 只按当前尺寸加余量的话，远跳几百格时算出来的目标比 need 还小，
        #    会被上限一路顶掉（踩过：点 4095 得到的网格宽度是 272，「能画到 ±4096」成了空话）。
        margin_x = max(MIN_GROW_STEP, min(GROW_MARGIN, self.cols))
        margin_y = max(MIN_GROW_STEP, min(GROW_MARGIN, self.rows))
        new_cols = min(max(self.cols + shift_x, need_cols) + margin_x, MAX_COORD)
        new_rows = min(max(self.rows + shift_y, need_rows) + margin_y, MAX_COORD)
        if new_cols < need_cols or new_rows < need_rows:
            return False                # 顶到 ±MAX_COORD 了，这一格装不下
        if new_cols * new_rows * _BYTES_PER_TILE > MAX_GRID_BYTES:
            return False                # 内存安全网（见常量注释）
        if new_cols == self.cols and new_rows == self.rows and not (shift_x or shift_y):
            return False
        # ★ origin 必须**先**改：`_resize` 会用 `view_of()` 重新登记区块归属，
        #   而 view_of 是「世界坐标 + origin」——origin 还是旧值的话，
        #   归属会被登记到旧下标上，接着往下画一格就整片指空
        #   （症状：往左上画第三格之后，前两格的区块归属没了；实测踩过两次）。
        self.origin_x += shift_x
        self.origin_y += shift_y
        self._resize(new_cols, new_rows, shift_x, shift_y)
        return True

    def resize(self, cols: int, rows: int) -> None:
        """改画布尺寸（变大 / 变小），**不动 origin**。左上角对齐：老内容留在原位。

        ★ 载入地图时用（`mapfile.dict_to_model`）。界面上「往左上画」要的平移不走这里，
        而是 `_resize(new_cols, new_rows, shift_x=…, shift_y=…)` —— 两者都会重建
        `existing` / `terrain` / `zone_of`，差别只在「老内容往哪挪一格」。
        """
        self._resize(cols, rows, 0, 0)

    def _resize(self, cols: int, rows: int, shift_x: int = 0, shift_y: int = 0) -> None:
        """改尺寸；`shift_x/y` = 老内容在数组里往右下挪几格（往左上画时用）。

        ⚠️⚠️ `zone_of` 的键是**数组下标**（`y * cols + x`），重建它的那一刻必须
        用**旧**的 cols 拆、用**新**的 cols 拼。这里踩过两次：
          · 两处都用了新 cols → 网格一变大陆块归属整张丢失（只在「先划区块、
            再往新方向画」的顺序下出现）；
          · `zone.tiles` 是**世界坐标**，被误当成下标一起加了 shift →
            「世界坐标里的同一格」悄悄变成了另一格。
        所以下面只做一件事：先按 shift 搬数组，再按**世界坐标**重新登记一遍区块
        （`zone_of` 是从 `zone.tiles` 推出来的，不手工搬下标就不会错）。
        """
        cols, rows = int(cols), int(rows)
        if cols < 0 or rows < 0:
            raise MapError("地图尺寸不能是负数")
        if (cols, rows) == (self.cols, self.rows) and not (shift_x or shift_y):
            return
        old_existing, old_terrain = self.existing, self.terrain
        old_cols, old_rows = self.cols, self.rows
        self.cols, self.rows = cols, rows
        self.existing = [False] * (cols * rows)
        self.terrain = ["grass"] * (cols * rows)
        for ay in range(old_rows):
            ny = ay + shift_y
            if not (0 <= ny < rows):
                continue
            for ax in range(old_cols):
                nx = ax + shift_x
                if not (0 <= nx < cols):
                    continue
                self.existing[ny * cols + nx] = old_existing[ay * old_cols + ax]
                self.terrain[ny * cols + nx] = old_terrain[ay * old_cols + ax]
        self.recount()
        # 区块归属：tiles 是世界坐标，只要「这一格还在网格里」就留下。
        # ⚠️ 这里必须用**当前的 origin** 算下标 —— 调用方（`_grow_to_include`）
        #    在调本方法**之前**就已经把 origin 改好了，所以这里算出来的就是最终下标。
        kept: Dict[int, int] = {}
        for zone in self.zones:
            zone.tiles = {t for t in zone.tiles if self.in_bounds(t[0], t[1])}
            for tile in zone.tiles:
                vx, vy = self.view_of(tile[0], tile[1])
                kept[self.idx(vx, vy)] = zone.zone_id
        self.zone_of = kept
        if self.base is not None and not self.in_bounds(self.base[0], self.base[1]):
            self.base = None
        # 阵营大本营同理：格子出界了就把它忘掉（留着一个指向图外的大本营，
        # 导出后 Godot 读到的坐标会在网格外）
        for fid in [f for f, t in self.faction_bases.items() if not self.in_bounds(t[0], t[1])]:
            self.faction_bases.pop(fid, None)

    ## 把网格朝需要的方向长到能装下世界坐标 (x, y)；返回 False = 超出上限。
    ##
    ## ★ 生长量是「按需」的，**不是倍增**。这里换过一版：
    ##   原来 `new = max(need, cols * 2)` 是倍增，理由是「连续画一片新区域时把重建次数
    ##   压到 log 级」（每次重建都要把整个数组拷一遍）。但倍增有个要命的副作用：
    ##   在离原点很远的地方点一下（比如 (8000, 8000)），网格会被直接撑到
    ##   8000×8000=6400 万格 ≈ 1.1 GB，一次误点就能把编辑器拖死（实测：4096 那一跳
    ##   就 268 ms / 144 MB，16384 是 4.7 秒 / 2.3 GB）。
    ##   所以改成：**只长到「装得下 + 一点余量」**，把浪费从 O(面积) 降到 O(周长)。
    ##   代价是「连续往一个方向猛画」时会多重建几次 —— 但那是画地图，不是拖鼠标，
    ##   每次重建几十毫秒仍然可以接受（而且余量让它每几百格才重建一次）。
    ##
    ## ★ 再叠一层 `MAX_GRID_BYTES` 安全网：稠密数组的占用是 O(面积)，
    ##   在 (16000,16000) 点一下就是 2 GB，编辑器会被系统直接杀掉 ——
    ##   那一下宁可拒绝，也不要「进程没了」。

    def clear_tiles(self) -> None:
        """把所有格子变回「不存在」（区块里的地块也一并清掉，但区块本身保留）。"""
        self.existing = [False] * (self.cols * self.rows)
        self._exists_count = 0
        for zone in self.zones:
            zone.tiles.clear()
        self.zone_of.clear()

    # ---------------- 区块 ----------------

    def zone(self, zone_id: int) -> Optional[Zone]:
        for z in self.zones:
            if z.zone_id == zone_id:
                return z
        return None

    def zone_at(self, x: int, y: int) -> Optional[Zone]:
        """这个地块属于哪个区块（不存在 / 不属于任何区块 → None）。"""
        if not self.exists(x, y):
            return None
        return self.zone(self.zone_of.get(self.idx(*self.view_of(x, y)), -1))

    # ---- 按**数组下标**直接问的四个入口：重绘时逐格扫，省一次坐标换算 ----
    #      （界面上的重绘是每帧几百上千次调用，世界坐标那条路要额外算一次加减；
    #        有世界坐标的时候一律用上面那套，别在业务代码里用这几个。）

    def in_view(self, vx: int, vy: int) -> bool:
        return 0 <= vx < self.cols and 0 <= vy < self.rows

    def exists_view(self, vx: int, vy: int) -> bool:
        return self.in_view(vx, vy) and self.existing[self.idx(vx, vy)]

    def terrain_view(self, vx: int, vy: int) -> str:
        if not self.in_view(vx, vy):
            return "grass"
        return self.terrain[self.idx(vx, vy)]

    def zone_id_at_view(self, vx: int, vy: int) -> int:
        """按**数组下标**问区块 id（-1 = 没有）。"""
        return self.zone_of.get(self.idx(vx, vy), -1)

    def create_tile_view(self, vx: int, vy: int) -> bool:
        """按数组下标建一格（内部用；界面上要建格请走 ensure_tile + create_tile）。"""
        return self.set_existing(*self.world_of(vx, vy), value=True)

    def add_zone(self, name: str = "") -> Zone:
        """新建区块（默认名「区块N」，不与现有名字撞车）。"""
        used = {z.zone_id for z in self.zones}
        new_id = 0
        while new_id in used:
            new_id += 1
        zone = Zone(new_id, name)
        if not name.strip():
            zone.name = self._next_default_name()
        self.zones.append(zone)
        return zone

    def delete_zone(self, zone_id: int) -> bool:
        """删掉区块（它名下的地块变成「不属于任何区块」）。"""
        zone = self.zone(zone_id)
        if zone is None:
            return False
        for tile in zone.tiles:
            self.zone_of.pop(self.idx(*self.view_of(*tile)), None)
        zone.tiles.clear()
        self.zones.remove(zone)
        self._renumber_default_names()
        return True

    def rename_zone(self, zone_id: int, name: str) -> bool:
        zone = self.zone(zone_id)
        if zone is None:
            return False
        zone.name = name.strip() or self._next_default_name()
        return True

    def assign_tile(self, x: int, y: int, zone_id: int) -> bool:
        """把一格划给某个区块。返回是否真的变了。

        地块必须已经存在（虚线格不能划，先创建地块）。
        """
        if not self.exists(x, y):
            return False
        zone = self.zone(zone_id)
        if zone is None:
            return False
        i = self.idx(*self.view_of(x, y))
        old = self.zone_of.get(i, -1)
        if old == zone.zone_id:
            return False
        if old >= 0:
            prev = self.zone(old)
            if prev is not None:
                prev.tiles.discard((x, y))
        zone.tiles.add((x, y))
        self.zone_of[i] = zone.zone_id
        return True

    def clear_zone(self, x: int, y: int) -> bool:
        """把一格从它所属的区块里摘出来。"""
        if not self.in_bounds(x, y):
            return False
        i = self.idx(*self.view_of(x, y))
        old = self.zone_of.pop(i, -1)
        if old < 0:
            return False
        zone = self.zone(old)
        if zone is not None:
            zone.tiles.discard((x, y))
        return True

    #: toggle_tile_zone 的返回值
    TOGGLE_ASSIGNED = "assigned"
    TOGGLE_REMOVED = "removed"
    TOGGLE_NONE = ""

    def toggle_tile_zone(self, x: int, y: int, zone_id: int) -> str:
        """单击地块（区块页签）：属于这个区块就摘出去，否则划进来。

        返回 ``MapModel.TOGGLE_ASSIGNED`` / ``TOGGLE_REMOVED`` / ``TOGGLE_NONE``
        —— 调用方要据此告诉用户「划入了」还是「移除了」，所以不能只回一个 bool。
        """
        if not self.exists(x, y):
            return self.TOGGLE_NONE
        current = self.zone_of.get(self.idx(*self.view_of(x, y)), -1)
        if current == zone_id:
            return self.TOGGLE_REMOVED if self.clear_zone(x, y) else self.TOGGLE_NONE
        return self.TOGGLE_ASSIGNED if self.assign_tile(x, y, zone_id) else self.TOGGLE_NONE

    def zone_display_name(self, zone_id: int) -> str:
        zone = self.zone(zone_id)
        return zone.name if zone is not None else ""

    def _next_default_name(self) -> str:
        """取一个还没被占用的默认名（区块1 / 区块2 …）。

        ⚠️ 不能拿「区块数量 + 1」当名字：删掉「区块1」再新建会撞名，
        而区块名在侧边栏的下拉框里当键用，重名会让归属选错区块。
        """
        used = {z.name for z in self.zones}
        serial = 1
        while DEFAULT_ZONE_NAME_FORMAT.format(serial) in used:
            serial += 1
        return DEFAULT_ZONE_NAME_FORMAT.format(serial)

    def _renumber_default_names(self) -> None:
        """删掉区块之后，把「还是默认名」的那些重新编号（区块1 / 区块2 …）。

        两条规矩：
          · 用户起过的名字一律不碰（否则删一个区块会把「东关」改掉）；
          · 重新编号也**不许撞名**（删掉「区块1」会让后面的「区块2」想改成「区块1」，
            而那个名字可能已经被新建的区块占了）。
        """
        kept: set[str] = {z.name for z in self.zones
                          if not _is_default_zone_name(z.name)}
        serial = 0
        for zone in self.zones:
            if not _is_default_zone_name(zone.name):
                continue
            serial += 1
            candidate = DEFAULT_ZONE_NAME_FORMAT.format(serial)
            while candidate in kept:
                serial += 1
                candidate = DEFAULT_ZONE_NAME_FORMAT.format(serial)
            zone.name = candidate
            kept.add(candidate)

    # ---------------- 阵营与大本营 ----------------
    #
    # ★ 语义（与 Godot 侧对齐，见 logic/faction.gd / map_data.gd / world.gd）：
    #   · 阵营 id = 游戏那套字符串；一个阵营**一个**大本营（一方一座 TYPE_BASE）。
    #   · 大本营存在 faction_bases 里，值是**世界坐标**；没设的阵营在里面没有键。
    #   · 旧的单数 base 仍然保留：它是「地图中心 / 默认点位」，
    #     没有 faction_bases 的老地图在 Godot 里照旧走它（行为一字不改）。

    def faction(self, faction_id: str) -> Optional[Faction]:
        for f in self.factions:
            if f.faction_id == faction_id:
                return f
        return None

    def add_faction(self, faction_id: str, name: str = "", color: str = "") -> Optional[Faction]:
        """加一个阵营。id 为空或已存在 → 返回 None（调用方据此提示）。

        颜色留空时按 FACTION_PALETTE 依次取一个还没被用过的 —— 地图上要能一眼分清
        「哪个大本营是哪一方的」。
        """
        fid = str(faction_id).strip()
        if not fid or self.faction(fid) is not None:
            return None
        if not color:
            used = {f.color for f in self.factions}
            color = next((c for c in FACTION_PALETTE if c.upper() not in used),
                         FACTION_PALETTE[len(self.factions) % len(FACTION_PALETTE)])
        faction = Faction(fid, name, color)
        self.factions.append(faction)
        return faction

    def remove_faction(self, faction_id: str) -> bool:
        """删阵营（它的大本营点位一并忘掉）。"""
        faction = self.faction(faction_id)
        if faction is None:
            return False
        self.factions.remove(faction)
        self.faction_bases.pop(faction_id, None)
        return True

    def rename_faction(self, faction_id: str, name: str) -> bool:
        faction = self.faction(faction_id)
        if faction is None:
            return False
        faction.name = name.strip() or faction_id
        return True

    def set_faction_color(self, faction_id: str, color: str) -> bool:
        faction = self.faction(faction_id)
        if faction is None or not color.strip():
            return False
        faction.color = color.strip().upper()
        return True

    def set_faction_base(self, faction_id: str, x: int, y: int) -> bool:
        """把某个阵营的大本营设在 (x, y)。返回是否真的变了。

        ★ 一格只能是一个阵营的大本营：设给新阵营时会从原来那个阵营手里**拿走**
        （否则导出两个阵营抢同一格，Godot 里两座基地叠在一起）。
        """
        if self.faction(faction_id) is None:
            return False
        if not self.exists(x, y):
            return False
        current = self.faction_base_owner(x, y)
        if current == faction_id:
            return False
        if current is not None:
            self.faction_bases.pop(current, None)
        self.faction_bases[faction_id] = (x, y)
        return True

    def clear_faction_base(self, faction_id: str) -> bool:
        """取消某个阵营的大本营（它之后在游戏里退回默认点位）。"""
        return self.faction_bases.pop(faction_id, None) is not None

    def faction_base_of(self, faction_id: str) -> Optional[Tile]:
        return self.faction_bases.get(faction_id)

    def faction_base_owner(self, x: int, y: int) -> Optional[str]:
        """这一格是谁的大本营（不是任何阵营的大本营 → None）。"""
        for fid, tile in self.faction_bases.items():
            if tile == (x, y):
                return fid
        return None

    # ---------------- 矩形框选（批量改地形 / 归属的基础） ----------------

    def rect_tiles(self, x0: int, y0: int, x1: int, y1: int) -> List[Tile]:
        """矩形范围内**已存在**的地块（世界坐标，按行优先排序）。

        ★ 只返回真实地块：虚线格不参与批量操作 —— 框选是「改已有的地」，
          不是「批量创建」（需求原话：被矩形框选到的地块会被选中）。
        ★ 矩形可能很大（拖满一屏是几百格），所以按行扫、碰到不存在的就跳过，
          不做「先枚举全部格子再过滤」。
        """
        lo_x, hi_x = (x0, x1) if x0 <= x1 else (x1, x0)
        lo_y, hi_y = (y0, y1) if y0 <= y1 else (y1, y0)
        out: List[Tile] = []
        for y in range(lo_y, hi_y + 1):
            for x in range(lo_x, hi_x + 1):
                if self.exists(x, y):
                    out.append((x, y))
        return out

    def count_in_rect(self, x0: int, y0: int, x1: int, y1: int) -> int:
        return len(self.rect_tiles(x0, y0, x1, y1))

    # ---------------- 校验 ----------------

    def problems(self) -> List[str]:
        """给用户看的问题清单（导出前提示；**不阻止**导出）。"""
        out: List[str] = []
        if self.existing_count() == 0:
            out.append("地图上一个地块都没有（导出的图在游戏里是空的）")
        for zone in self.zones:
            if zone.tile_count == 0:
                out.append("区块「%s」还没有地块（导出后它在游戏里是空区块）" % zone.name)
        out.extend(self._base_problems())
        out.extend(self._faction_problems())
        out.extend(self._size_problems())
        return out

    ## 「默认大本营点位」（那个单数的 base）要不要管，取决于**有没有阵营在用它兜底**。
    ##
    ## ★ 这里踩过一次（用户报的）：所有阵营都设了自己的大本营，只是没设这个「默认点位」，
    ##   导出时却弹「大本营点位没设」—— 而 Godot 那边根本不会退回地图中心，
    ##   它用的是地图指定的阵营大本营。**一句不该出现的警告会让人去改本来没问题的东西。**
    ##
    ## 规则（与 logic/map_data.gd 的 spawn_layout_for 一一对应）：
    ##   · 没有阵营 → 这个点位是唯一的出生点，没设就要说（老行为）；
    ##   · 有阵营 → 它只是「某些阵营没设大本营时的兜底」：
    ##       - 每一方都有大本营 → 不提醒（游戏里完全用不到它）；
    ##       - 有阵营要靠它兜底 → 提醒，而且要说清是**谁**要靠它。
    def _base_problems(self) -> List[str]:
        out: List[str] = []
        # 设了「默认点位」时，只看这一格本身合不合法（与有没有阵营无关）
        if self.base is not None:
            if not self.exists(*self.base):
                out.append("大本营点位落在一个「不存在」的格子上")
            elif self.terrain_at(*self.base) == "mountain":
                out.append("大本营点位落在山地上（游戏里会就近找一个能站的格子）")
            return out
        if not self.factions:
            out.append("大本营点位没设（Godot 会退回地图中心）")
            return out
        fallback = [f.label() for f in self.factions
                    if self.faction_base_of(f.faction_id) is None]
        if fallback:
            out.append("默认大本营点位没设，而 %s 也没设自己的大本营 —— "
                       "游戏里这些阵营会退回地图中心" % "、".join(fallback))
        return out

    def _faction_problems(self) -> List[str]:
        """阵营大本营的提醒（同样只提醒、不阻止）。

        三种情况值得说一句：
          · 阵营一个都没建，但设计者显然是想要分阵营（这里不猜，只在有阵营时检查）；
          · 设了阵营却没设大本营（它在游戏里会退回默认点位，多半不是设计者想要的）；
          · 大本营落在山地上（游戏会就近换格，位置会跑）。
        """
        if not self.factions:
            return []
        out: List[str] = []
        for faction in self.factions:
            base = self.faction_bases.get(faction.faction_id)
            if base is None:
                # 没设自己的大本营 → 它在游戏里靠「默认点位」兜底；
                # 默认点位也没设的话，_base_problems() 已经把那一条说清楚了，
                # 这里不重复报（同一件事说两遍只会让人以为有两处要改）。
                if self.base is not None:
                    out.append("阵营「%s」还没设大本营（游戏里会退回默认点位）"
                               % faction.label())
                continue
            if not self.exists(*base):
                out.append("阵营「%s」的大本营落在一个「不存在」的格子上" % faction.label())
            elif self.terrain_at(*base) == "mountain":
                out.append("阵营「%s」的大本营落在山地上（游戏里会就近找一个能站的格子）"
                           % faction.label())
        unknown = [f.faction_id for f in self.factions if f.faction_id not in KNOWN_FACTIONS]
        if unknown:
            out.append("这些阵营 id 游戏不认识（联机名单里没有）：%s —— "
                       "它们的大本营在游戏里不会生效" % "、".join(unknown))
        return out

    def _size_problems(self) -> List[str]:
        """地图太大时的提醒。

        ★ 为什么要有这一条：画布上限放到 MAX_COORD 之后，导出的 AABB 可以很大，
        而 Godot 侧的网格是**稠密数组**（每张网格 cols×rows，一格 4~8 字节；
        `map_data.gd` 里 terrain / exists / zones 三张，加上 zone.gd 的 lookup）。
        10000×10000 的地图在编辑器里画得出来，在 Godot 里一加载就要几百 MB ——
        那时候的表现是「游戏一开就卡死」，很难联想到是地图太大。
        所以这里**只提醒、不阻止**：作者自己知道自己在画什么，编辑器不替他做决定。
        """
        box = self.bounds()
        if box is None:
            return []
        x0, y0, x1, y1 = box
        cols = x1 - x0 + 1
        rows = y1 - y0 + 1
        if cols <= BIG_MAP_WARN_TILES and rows <= BIG_MAP_WARN_TILES:
            return []
        # 三张网格（地形 / 存在 / 区块）+ 区块查找表，粗算一格的量级
        approx_mb = cols * rows * 12 / (1024.0 * 1024.0)
        return ["导出的地图很大（%d×%d ≈ %.0f 万个地块，约 %.0f MB）——"
                "Godot 侧会把它整张读进内存" % (cols, rows,
                                                cols * rows / 10000.0, approx_mb)]
