"""test_editor_catalog.py —— 有用表读写（读取 / 追加 / 去重 / 保留注释）。"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve()
if str(HERE.parent) not in sys.path:
    sys.path.insert(0, str(HERE.parent))

from editor_catalog import add_campaign, add_map, campaign_ids, map_ids, path

TMP = HERE.parent / ".tmp_editor_catalog_test"


def main() -> int:
    shutil.rmtree(TMP, ignore_errors=True)
    (TMP / "data").mkdir(parents=True, exist_ok=True)
    target = path(TMP)
    target.write_text(json.dumps({
        "_comment": "keep me",
        "maps": ["main_test"],
        "campaigns": ["demo"],
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    assert map_ids(TMP) == ["main_test"]
    assert add_map(TMP, "ai_test_2") is True
    assert add_map(TMP, "ai_test_2") is False
    assert map_ids(TMP) == ["main_test", "ai_test_2"]
    assert add_campaign(TMP, "extra") is True
    assert campaign_ids(TMP) == ["demo", "extra"]

    data = json.loads(target.read_text(encoding="utf-8"))
    assert data["_comment"] == "keep me"
    assert data["maps"] == ["main_test", "ai_test_2"]
    assert data["campaigns"] == ["demo", "extra"]

    shutil.rmtree(TMP, ignore_errors=True)
    print("[CASE] test_editor_catalog -> passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
