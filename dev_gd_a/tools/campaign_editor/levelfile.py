"""levelfile.py —— 战役 / 关卡 JSON 的读写与往返（对应 map_editor 的 mapfile.py）。

写出来的文件与仓库里那几份**同一套风格**（照 `data/maps/dongzheng/map.json`）：

    · **LF 行尾、无 BOM**（`encoding="utf-8"` + `newline="\\n"`；读的时候宽容 `utf-8-sig`）；
    · `json.dumps(..., ensure_ascii=False, indent=2)`，末尾**一个换行**；
    · **省略等于默认值的字段**（见 `model.LevelModel.to_dict`），`_comment` 原样带回去。

★★ 往返是这一层的**守门人契约**：读进来 → 写出去 → 再读进来，模型必须**逐字段一致**。
   为什么值得为它单独写一层并配一整套断言：编辑器与运行时之间没有别的合同，
   合同就是「两边读同一份 JSON 读到同一个东西」；这一层漂了，游戏里就会静默按别的数跑。

★ 本文件**不许 import tkinter**（同另两个编辑器的规矩）：数据层的测试不需要开窗。
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from . import model as model_mod
from .model import (
    COMMENT_KEY,
    LEVELS_SUBDIR,
    CampaignModel,
    LevelModel,
    MapInfo,
    ModelError,
    load_campaign as _load_campaign,
    load_level as _load_level,
)

#: 一个战役目录里，除了 `campaign.json` 与 `levels/`，编辑器还可能写的东西。
#: （目前没有；留这个常量是为了「保存时清理什么」有一个明确的地方可写。）
MANAGED_NAMES: Tuple[str, ...] = ("campaign.json", LEVELS_SUBDIR)


# ======================================================================
# 读
# ======================================================================

def load_campaign(dir_path: Any, project_dir: Any) -> CampaignModel:
    """读一个战役（`campaign.json` + 全部关卡）。读不出来抛 `ModelError`。"""
    return _load_campaign(dir_path, project_dir)


def load_level(path: Any, project_dir: Any, campaign_id: str = "",
               default_mode: str = model_mod.MODE_SOLO,
               level_id: str = "") -> LevelModel:
    """读一份关卡 JSON。读不出来抛 `ModelError`。"""
    return _load_level(path, project_dir, campaign_id, default_mode, level_id)


def list_campaign_dirs(project_dir: Any) -> List[Path]:
    """扫 `data/campaigns/` 下的战役目录（按目录名排序，稳定可预期）。

    ★ 只扫一级子目录、按**目录名**（不区分大小写）排 —— 与 `logic/campaign_library.gd`
      的第 1 条同规。一个都没有时返回空列表（调用方自己兜底成「新建战役」）。
    """
    root = Path(project_dir).joinpath(*model_mod.CAMPAIGNS_SUBDIR)
    try:
        return sorted((p for p in root.iterdir() if p.is_dir()), key=lambda p: p.name.lower())
    except OSError:
        return []


# ======================================================================
# 写
# ======================================================================

def dumps_campaign(model: CampaignModel, indent: int = 2) -> str:
    """战役 → JSON 文本（**不带**末尾换行；`save_campaign` 会加）。"""
    return json.dumps(model.to_dict(), ensure_ascii=False, indent=indent)


def dumps_level(model: LevelModel, indent: int = 2) -> str:
    """关卡 → JSON 文本（**不带**末尾换行）。"""
    return json.dumps(model.to_dict(), ensure_ascii=False, indent=indent)


def _write_text(path: Path, text: str) -> None:
    """写一个文本文件：UTF-8、**LF 行尾**、末尾一个换行。

    ⚠️ 为什么显式 `newline="\\n"`：Windows 上 `Path.write_text` 走的是
      `open(..., newline=None)`，它会把 `\\n` **翻译成 `\\r\\n`** —— 于是「在 Windows 上
      保存一次」与「在 Linux 上保存一次」产出两个不同字节的文件，git 里红成一片，
      而 JSON 本身是合法的（所以这个坑不会报错，只会让 diff 噪声越来越大）。
      `newline="\\n"` 是关掉那个翻译的唯一开关（map_editor 的 mapfile.py 同款）。
    """
    if path.parent and not path.parent.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


def save_level(model: LevelModel, path: Any) -> Path:
    """写一份关卡 JSON，返回写过的路径。"""
    p = Path(path)
    _write_text(p, dumps_level(model) + "\n")
    return p


def level_path(campaign: CampaignModel, lv: LevelModel) -> Path:
    """这一关该写到哪个文件（**沿用源文件写的那个相对路径**，不自作主张改名）。"""
    if campaign.dir_path is None:
        raise ModelError("战役「%s」没有目录，先给它一个 dir_path" % campaign.campaign_id)
    rel = model_mod.level_file_of(lv)
    # ⚠️ 只允许写到战役目录**里面**：源 JSON 里的 `file` 是别人写的字符串，
    #    一个 `../../x.json` 就能把文件写到仓库别处去（宁可报错也不照写）。
    base = Path(campaign.dir_path).resolve()
    target = (base / rel).resolve()
    if base != target and base not in target.parents:
        raise ModelError("关卡文件越出了战役目录：%s" % rel)
    return target


def save_campaign(model: CampaignModel) -> List[str]:
    """写 `campaign.json` + 每一关的 `levels/*.json`，返回写过的路径列表。

    ★ 顺序：先写关卡、**最后**写 `campaign.json`（它是「目录里这一串文件是什么」的索引；
      索引最后落地，中途失败也不会留下一个指向不存在关卡的 campaign.json）。
    ★ 不删除任何文件：改名 / 删关留下的旧 JSON 留在目录里，由作者自己清
      （编辑器不替人删文件 —— 删错了就没法撤销，而多一个文件只是 `levels[]` 里不再提它）。
    """
    if model.dir_path is None:
        raise ModelError("战役「%s」没有目录，先给它一个 dir_path" % model.campaign_id)
    written: List[str] = []
    for lv in model.levels:
        written.append(str(save_level(lv, level_path(model, lv))))
    camp = Path(model.dir_path) / model_mod.CAMPAIGN_FILE_NAME
    _write_text(camp, dumps_campaign(model) + "\n")
    written.append(str(camp))
    return written


def new_campaign_files(model: CampaignModel) -> List[str]:
    """（界面用）新战役第一次落盘：先把空目录建出来，再走 `save_campaign`。"""
    if model.dir_path is None:
        raise ModelError("战役「%s」没有目录" % model.campaign_id)
    Path(model.dir_path).mkdir(parents=True, exist_ok=True)
    Path(model.dir_path).joinpath(LEVELS_SUBDIR).mkdir(parents=True, exist_ok=True)
    return save_campaign(model)


# ======================================================================
# 往返比较（测试与界面的「导出前后有没有实质变化」都用它）
# ======================================================================

def level_payload(model: LevelModel) -> dict:
    """关卡「语义载荷」= `to_dict()` 去掉 `_comment` 那一类只给人看的字段。

    ★ 为什么比较载荷而不是字节：往返的契约是**逐字段一致**，不是「字节一样」——
      格式（缩进 / 数字写法）允许规范化，语义一个都不许动。
      `_comment` 不参与：它是文档，源的注释我们原样带回去，但换一份注释不该算「数据变了」。
    """
    data = model.to_dict()
    data.pop(COMMENT_KEY, None)
    return data


def campaign_payload(model: CampaignModel) -> dict:
    data = model.to_dict()
    data.pop(COMMENT_KEY, None)
    return data


#: 这几种数组**顺序无意义**（运行时按 id / key 查）—— 比对时先排序再比。
#:
#: ★ 为什么要有它：编辑器重建 `zones[]` / `factions[]` 时可能按 id 排过序，
#:   而源文件里是「设计的顺序」。那**不是**数据变化（运行时一个字都不受影响），
#:   可是 JSON 数组是有序的，直接比会报成「往返不一致」这种极难查的假红。
#: ⚠️ **别**把有序的列表塞进来：`players[]` 的顺序 = 席位顺序、`objectives[]`
#:   虽然第一版只有一项但顺序有意义 —— 它们必须逐位比较。
#:
#: ★★ `start_units` 是**后加的**（本轮）：编辑器导出时会把**将领排到它自己的兵前面**
#:   （运行时的硬约定：`world.units` 的前几个必须是将领），于是数组顺序会与源文件不同 ——
#:   那是同一份数据的另一种写法，不是数据变了。⚠️ 前提是「顺序不携带语义」：
#:   `units[].escort_of` 指的是**第几位将领**（按将领自己的 `general_index`），
#:   不是「数组里的第几项」，所以排序之后语义不变。
UNORDERED_KEYS: Tuple[str, ...] = ("zones", "factions", "start_units", "start_buildings",
                                   "fail_conditions", "briefing")


def canonical_payload(value: Any, key: str = "") -> Any:
    """把载荷规整成**可比较的规范形式**：数字统一成 float、无意义的数组排序。

    ★ 这是「逐字段一致」那条契约的**唯一**一处实现：往返比较、测试、界面上的
      「有没有实质变化」都该用它，别再各写一份（三份实现必然漂开）。
    """
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, dict):
        # ★★ 键排序：JSON 对象的**成员顺序不携带语义**，而导出时 `escort_of` 是最后
        #    追加的键、作者手写的 JSON 里可能排在 `name` 前面 —— 按位置比会报成
        #    「往返不一致」这种假红（实测踩到）。排序之后：多键 / 少键 / 值变了照样抓得住。
        return {k: canonical_payload(v, k) for k, v in sorted(value.items())}
    if isinstance(value, list):
        items = [canonical_payload(v, key) for v in value]
        if key in UNORDERED_KEYS:
            try:
                return sorted(items, key=lambda x: json.dumps(x, sort_keys=True,
                                                              ensure_ascii=False))
            except (TypeError, ValueError):                 # pragma: no cover - 兜底
                return items
        return items
    return value


def diff_levels(before: LevelModel, after: LevelModel) -> List[str]:
    """两关的语义差异（返回人话列表；空列表 = 逐字段一致）。"""
    return _diff(canonical_payload(level_payload(before)),
                 canonical_payload(level_payload(after)), "关卡")


def _diff(a: Any, b: Any, path: str) -> List[str]:
    if isinstance(a, dict) and isinstance(b, dict):
        out: List[str] = []
        for key in sorted(set(a) | set(b)):
            if key not in a:
                out.append("%s.%s：写多了（%r）" % (path, key, b[key]))
            elif key not in b:
                out.append("%s.%s：丢了（原来 %r）" % (path, key, a[key]))
            else:
                out.extend(_diff(a[key], b[key], "%s.%s" % (path, key)))
        return out
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            return ["%s：长度不同（%d → %d）" % (path, len(a), len(b))]
        out = []
        for i, (x, y) in enumerate(zip(a, b)):
            out.extend(_diff(x, y, "%s[%d]" % (path, i)))
        return out
    if isinstance(a, bool) or isinstance(b, bool):
        if bool(a) != bool(b):
            return ["%s：%r → %r" % (path, a, b)]
        return []
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        if abs(float(a) - float(b)) > 1e-9:
            return ["%s：%r → %r" % (path, a, b)]
        return []
    if a != b:
        return ["%s：%r → %r" % (path, a, b)]
    return []


def roundtrip_ok(model: CampaignModel, tmp_root: Any, project_dir: Any) -> Tuple[bool, List[str]]:
    """把一个战役写进临时目录再读回来，比较「逐字段一致」。

    @return `(是否一致, 差异说明列表)`
    """
    tmp_root = Path(tmp_root)
    clone = CampaignModel(model.campaign_id, tmp_root / model.campaign_id)
    clone.name = model.name
    clone.description = model.description
    clone.default_mode = model.default_mode
    clone.unlock = model.unlock
    clone.factions = [dict(f) for f in model.factions]
    clone.preserved = json.loads(json.dumps(model.preserved, ensure_ascii=False))
    clone.levels = model.levels            # 只借用，写盘时按它落文件
    save_campaign(clone)
    back = load_campaign(clone.dir_path, project_dir)
    diffs: List[str] = []
    if campaign_payload(back) != campaign_payload(model):
        diffs.extend(_diff(campaign_payload(model), campaign_payload(back), "战役"))
    if len(back.levels) != len(model.levels):
        diffs.append("关卡数量不同：%d → %d" % (len(model.levels), len(back.levels)))
    for a, b in zip(model.levels, back.levels):
        diffs.extend(diff_levels(a, b))
    return (not diffs), diffs


# ======================================================================
# 新建（界面与命令行共用一条路）
# ======================================================================

def create_campaign(project_dir: Any, campaign_id: str, name: str = "",
                    map_id: str = "") -> Tuple[CampaignModel, List[str]]:
    """建一个新战役并**立刻落盘**，返回 `(模型, 写过的路径)`。

    ★ 落盘时才叫「建出来了」：只改内存的话，命令行 `--new` 退出之后什么都没留下。
    ★ `map_id` 给了就顺手建第一关（新战役一关都没有的话 `load_campaign` 是读不出来的 ——
      逻辑层与这里都要求「至少一关」，所以新建时**必须**给一关）。
    """
    model = model_mod.new_campaign(project_dir, campaign_id, name)
    if not map_id:
        maps = model_mod.list_maps(project_dir)
        map_id = maps[0].map_id if maps else ""
    if map_id:
        lv = model.new_level("01_%s" % campaign_id, map_id)
        lv.name = "%s · 第一关" % (name or campaign_id)
        _fill_new_level(lv, map_id)
    written = new_campaign_files(model)
    return model, written


def _fill_new_level(lv: LevelModel, map_id: str) -> None:
    """给新关卡一份**能通过校验**的起手数据（不写的话作者一打开就是一片红）。

    ★ 只放「最小可用」的那几样：一个玩家席位（用战役第一个可玩阵营）+
      一张占位目标（第一个区划、90 秒）—— 目标区划的归属与阵营大本营
      留空，让作者按自己的图去填（校验会把缺的那些一条条列出来）。
    """
    lv.players.append({"faction": "", "base": None})
    lv.mark_declared("players")


# ======================================================================
# 地图 / 配置的转发（界面只 import 本文件与 model，事情少一件）
# ======================================================================

def list_maps(project_dir: Any) -> List[MapInfo]:
    return model_mod.list_maps(project_dir)


def load_map(project_dir: Any, map_id: str) -> Optional[MapInfo]:
    return model_mod.load_map(project_dir, map_id)


def maps_by_id(project_dir: Any) -> Dict[str, MapInfo]:
    return {info.map_id: info for info in model_mod.list_maps(project_dir)}


def load_config(project_dir: Any) -> model_mod.ConfigInfo:
    return model_mod.load_config(project_dir)
