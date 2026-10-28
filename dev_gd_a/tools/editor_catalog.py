"""editor_catalog.py —— 地图 / 战役编辑器的「有用表」读写。

表在 Godot 工程的 `data/editor_visible.json`，只控制编辑器可见范围，不参与运行时。
两个编辑器共用本模块；测试会把工程目录指到临时副本，因此不会改到真表。
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List

CATALOG_NAME = "editor_visible.json"


def path(project_dir: Any) -> Path:
    return Path(project_dir) / "data" / CATALOG_NAME


def load(project_dir: Any) -> Dict[str, Any]:
    try:
        data = json.loads(path(project_dir).read_text(encoding="utf-8"))
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def ids(project_dir: Any, key: str) -> List[str]:
    value = load(project_dir).get(key)
    if not isinstance(value, list):
        return []
    return [str(v).strip() for v in value if str(v).strip()]


def map_ids(project_dir: Any) -> List[str]:
    return ids(project_dir, "maps")


def campaign_ids(project_dir: Any) -> List[str]:
    return ids(project_dir, "campaigns")


def add(project_dir: Any, key: str, value: str) -> bool:
    """把 value 追加到表里的 key；已存在返回 False（不重复写）。"""
    text = str(value).strip()
    if not text:
        return False
    data = load(project_dir)
    value_list = data.get(key)
    if not isinstance(value_list, list):
        value_list = []
    value_list = [str(v).strip() for v in value_list if str(v).strip()]
    if text in value_list:
        return False
    value_list.append(text)
    data[key] = value_list
    try:
        target = path(project_dir)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(
            json.dumps(data, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8")
    except Exception:
        return False
    return True


def add_map(project_dir: Any, map_id: str) -> bool:
    return add(project_dir, "maps", map_id)


def add_campaign(project_dir: Any, campaign_id: str) -> bool:
    return add(project_dir, "campaigns", campaign_id)
