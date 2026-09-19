"""test_model.py —— 地图编辑器数据层的无头测试（不需要图形界面）。

跑法（仓库根目录任意处）：

    python dev_gd_a/tools/map_editor/test_model.py

为什么要有它：编辑器的导出格式是**游戏要读的**东西（map_data.gd / zone.gd），
格式写错了要等跑起来才发现。这里把「旧地图读进来 → 一字不差地导出回去」钉成断言。
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve()
PKG_PARENT = HERE.parent.parent           # dev_gd_a/tools/
PROJECT_DIR = HERE.parent.parent.parent / "daeem"   # dev_gd_a/daeem/
if str(PKG_PARENT) not in sys.path:
    sys.path.insert(0, str(PKG_PARENT))

# 中文控制台（Windows 的 GBK 代码页）下让输出别炸
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")      # type: ignore[union-attr]
    except (AttributeError, ValueError):
        pass

from map_editor import mapfile                      # noqa: E402
from map_editor import model as model_module        # noqa: E402
from map_editor.model import (                      # noqa: E402
    MAX_COORD,
    TERRAIN_ORDER,
    MapModel,
    Zone,
    config_colors,
    config_grid,
    load_config,
    parse_color,
)

_FAILED = 0
_PASSED = 0


def ok(cond, label: str) -> None:
    global _FAILED, _PASSED
    if cond:
        _PASSED += 1
        print("  [ok]   %s" % label)
    else:
        _FAILED += 1
        print("  [FAIL] %s" % label)


def eq(actual, expected, label: str) -> None:
    ok(actual == expected, "%s（实际 %r，期望 %r）" % (label, actual, expected))


# ----------------------------------------------------------------------

def t_parse_color() -> None:
    print("\n[1] config.json 的颜色解析")
    eq(parse_color("#33422f")[:3], (0x33, 0x42, 0x2f), "十六进制")
    eq(parse_color("rgba(255,255,255,0.055)"), (255, 255, 255, 0.055), "rgba 带 alpha")
    eq(parse_color("rgb(230,190,80)")[:3], (230, 190, 80), "rgb 三通道")
    eq(parse_color("rgba(0.5,0.5,0.5,0.5)")[:3], (127, 127, 127), "0~1 通道也能认")


def t_config() -> None:
    print("\n[2] 读 Godot 的 data/config.json")
    cfg = load_config(PROJECT_DIR)
    cols, rows = config_grid(cfg)
    eq((cols, rows), (24, 16), "默认画布尺寸来自 config.grid")
    colors = config_colors(cfg)
    for key in ("grass", "grass_alt", "forest", "mountain"):
        ok(isinstance(colors.get(key), str) and str(colors[key]).startswith("#"),
           "配色里有 %s" % key)


def t_legacy_import() -> None:
    print("\n[3] 读旧地图 map_01.json（没有 exists / zones）")
    cfg = load_config(PROJECT_DIR)
    model = mapfile.load_map(PROJECT_DIR / "data" / "map_01.json", cfg)
    eq((model.cols, model.rows), (24, 16), "尺寸")
    eq(model.existing_count(), 24 * 16, "旧地图所有格子都存在")
    eq(model.terrain_at(4, 4), "forest", "(4,4) 是森林（layout 第 5 行 '....^'）")
    eq(model.terrain_at(15, 3), "mountain", "(15,3) 是山地")
    eq(model.base, (12, 8), "大本营点位")
    eq(len(model.zones), 24, "旧地图的区块按 6×4 均分 = 24 块")

    first = model.zone(0)
    eq(first.name, "A1", "第一块叫 A1")
    eq(first.bounds, (0, 0, 3, 3), "A1 的包围盒是 4×4")
    eq(model.zone(23).name, "D6", "最后一块叫 D6")
    eq(model.zone_at(0, 0).zone_id, 0, "(0,0) 属于 A1")
    eq(model.zone_at(4, 3).zone_id, 1, "(4,3) 属于 A2（列优先：列 1 行 0）")

    ok("general_spawns" in model.extra, "编辑器不管的字段被带在 extra 里")
    ok("buildings" in model.extra and "units" in model.extra, "预置建筑 / 单位也在 extra 里")


def t_legacy_roundtrip_is_byte_stable() -> None:
    print("\n[4] 旧地图「打开 → 导出」应当一字不差（游戏里区块归属不变）")
    cfg = load_config(PROJECT_DIR)
    path = PROJECT_DIR / "data" / "map_01.json"
    original = json.loads(path.read_text(encoding="utf-8"))
    model = mapfile.load_map(path, cfg)
    out = mapfile.model_to_dict(model)

    eq(out["cols"], original["cols"], "cols 不变")
    eq(out["rows"], original["rows"], "rows 不变")
    eq(out["layout"], original["layout"], "layout 逐行一致")
    eq(out["base"], original["base"], "base 不变")
    for key in mapfile.PRESERVED_KEYS:
        if key in original:
            eq(out[key], original[key], "字段 %s 原样带过去" % key)

    # 区块网格与老实现的均分结果一致：A1 = x 0..3 / y 0..3
    zones = out["zones"]
    eq(zones[0][0], 0, "(0,0) 属于区块 0")
    eq(zones[0][3], 0, "(3,0) 属于区块 0")
    eq(zones[3][0], 0, "(0,3) 还是区块 0（id = 行块号×6 + 列块号）")
    eq(zones[0][4], 1, "★ 列优先：x=4 起是列块 1 → 区块 1")
    eq(zones[3][4], 1, "(4,3) 也属于区块 1")
    eq(zones[4][0], 6, "(0,4) 进入行块 1 → 区块 6 = B1")
    eq(zones[0][7], 1, "x=7 还是区块 1（列块 1 占 x 4..7）")
    eq(zones[0][8], 2, "x=8 起是区块 2（列块 2 占 x 8..11）")
    eq(zones[0][11], 2, "x=11 还是区块 2")
    eq(zones[0][23], 5, "最后一列是区块 5")
    eq(zones[15][0], 18, "最后一行第一列是区块 18（3×6 + 0）")
    zone_names = {z["id"]: z["name"] for z in out["zone_list"]}
    eq(zone_names[0], "A1", "区块 0 叫 A1")
    eq(zone_names[6], "B1", "区块 6 叫 B1")
    eq(zone_names[23], "D6", "区块 23 叫 D6")
    eq(out["zone_list"][0]["tile_count"], 16, "A1 有 16 个地块")
    ok(all(row.count(0) == 4 for row in zones[:4]), "区块 0 在前 4 行各占 4 格")


def t_editor_format_roundtrip() -> None:
    print("\n[5] 编辑器自己的格式往返（exists / zones 网格）")
    model = mapfile.empty_map(6, 5, None)
    eq(model.existing_count(), 0, "空地图上一个地块都没有")

    for (x, y) in [(0, 0), (1, 0), (1, 1), (2, 1), (2, 2), (5, 4)]:
        model.create_tile(x, y)
    eq(model.existing_count(), 6, "创建了 6 个地块")
    model.set_terrain(1, 1, "forest")
    model.set_terrain(2, 2, "mountain")
    model.set_terrain(0, 0, "无效地形")
    eq(model.terrain_at(0, 0), "grass", "非法地形被忽略")

    a = model.add_zone("东关")
    b = model.add_zone()
    eq(b.name, "区块1号", "第二个区块拿第一个还没被占用的默认名")
    model.add_zone()
    c = model.add_zone("江陵")
    eq(c.name, "江陵", "起了名字就用名字")
    model.assign_tile(0, 0, a.zone_id)
    model.assign_tile(1, 0, a.zone_id)
    model.assign_tile(1, 1, b.zone_id)
    eq(a.tile_count, 2, "东关有 2 个地块")
    eq(model.zone_at(1, 1).name, "区块1号", "(1,1) 归那个默认名区块")
    ok(model.assign_tile(4, 4, a.zone_id) is False, "虚线格不能划给区块")
    model.base = (2, 1)

    data = mapfile.model_to_dict(model)
    eq(data["exists"][0], [1, 1, 0, 0, 0, 0], "exists 第 0 行")
    eq(data["exists"][3], [0, 0, 0, 0, 0, 0], "exists 第 3 行（一个地块都没有）")
    eq(data["layout"][0], "......", "layout 第 0 行（(0,0) 是草地 → '.'）")
    eq(data["layout"][1], ".^....", "layout 第 1 行（(1,1) 是森林 → '^'）")
    eq(data["layout"][2], "..#...", "layout 第 2 行（(2,2) 是山地 → '#'）")
    eq(data["layout"][4], "......", "不存在的地块在 layout 里写 '.' 占位（以 exists 为准）")
    eq(data["zones"][0][0], a.zone_id, "zones 第 0 行第 0 格归东关")
    eq(data["zones"][3][1], -1, "没有地块的格子是 -1")
    eq(data["base"], [2, 1], "大本营点位")

    again = mapfile.dict_to_model(json.loads(mapfile.dumps(model)), load_config(PROJECT_DIR))
    eq(again.existing, model.existing, "exists 往返一致")
    eq(again.terrain, model.terrain, "地形往返一致")
    eq(again.base, model.base, "base 往返一致")
    eq(sorted((z.zone_id, z.name, sorted(z.tiles)) for z in again.zones),
       sorted((z.zone_id, z.name, sorted(z.tiles)) for z in model.zones),
       "区块往返一致")

    # 文件写出去再读回来（临时目录放在工程里：DSH 的文件沙箱只允许写工作区）
    tmp = PROJECT_DIR / ".tmp_map_editor_test"
    if tmp.exists():
        shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True, exist_ok=True)
    try:
        path = tmp / "round.json"
        mapfile.save_map(path, model)
        text = path.read_text(encoding="utf-8")
        ok(text.endswith("\n"), "导出的文件以换行结尾")
        reloaded = mapfile.load_map(path, load_config(PROJECT_DIR))
        eq(reloaded.existing, model.existing, "文件往返：exists")
        eq(reloaded.base, model.base, "文件往返：base")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def t_zone_ops() -> None:
    print("\n[6] 区块的增删改与地块分配")
    model = mapfile.empty_map(4, 4, "grass")
    z1 = model.add_zone()
    z2 = model.add_zone()
    eq(z1.name, "区块1号", "第一个新区块的默认名")
    eq(z2.name, "区块2号", "第二个新区块的默认名")
    model.assign_tile(0, 0, z1.zone_id)
    eq(model.toggle_tile_zone(1, 1, z1.zone_id), MapModel.TOGGLE_ASSIGNED, "点一下 = 划入")
    eq(model.toggle_tile_zone(1, 1, z1.zone_id), MapModel.TOGGLE_REMOVED, "再点一下 = 移除")
    eq(z1.tile_count, 1, "移除之后只剩 1 格")

    model.assign_tile(0, 0, z2.zone_id)
    eq(z1.tile_count, 0, "改划给别人后，原来那块不再持有它")
    eq(z2.tile_count, 1, "新主人拿到了它")

    model.rename_zone(z2.zone_id, "江陵")
    eq(z2.name, "江陵", "重命名")
    model.rename_zone(z2.zone_id, "   ")
    eq(z2.name, "区块2号", "名字清空 → 退回一个没被占用的默认名")

    model.delete_tile(0, 0)
    eq(z2.tile_count, 0, "删掉地块会把它从区块里摘掉")

    model.delete_zone(z1.zone_id)
    eq(len(model.zones), 1, "区块被删掉了")
    ok(model.zone(z1.zone_id) is None, "按 id 找不到它了")

    # ★ 默认名重新编号，但绝不能撞上用户起的名字或其它区块
    model2 = mapfile.empty_map(2, 2, "grass")
    model2.add_zone()          # 区块1号
    model2.add_zone()          # 区块2号
    model2.add_zone()          # 区块3号
    model2.zones[1].name = "东关"
    model2.delete_zone(model2.zones[0].zone_id)
    eq([z.name for z in model2.zones], ["东关", "区块1号"],
       "默认名重新编号，用户起的名字不碰")

    # 删掉「区块1号」之后新建的区块不该抢到同一个名字
    model3 = mapfile.empty_map(2, 2, "grass")
    a = model3.add_zone()      # 区块1号
    model3.add_zone()          # 区块2号
    model3.delete_zone(a.zone_id)
    b = model3.add_zone()
    ok(b.name not in [z.name for z in model3.zones if z is not b],
       "新建区块的名字不与现有的撞车（%s）" % b.name)
    eq(len({z.name for z in model3.zones}), len(model3.zones), "区块名互不相同")


def t_shape_ops() -> None:
    print("\n[7] 画布尺寸 / 非矩形形状")
    model = mapfile.empty_map(4, 3, None)
    for x in range(4):
        model.create_tile(x, 0)
    model.resize(6, 5)
    eq((model.cols, model.rows), (6, 5), "尺寸改了")
    eq(model.existing_count(), 4, "老内容留在左上角")
    eq(model.terrain_at(1, 0), "grass", "地形跟着保留")
    model.resize(2, 2)
    eq(model.existing_count(), 2, "缩小画布会丢掉范围外的地块")

    model.resize(3, 3)
    model.set_terrain(1, 1, "mountain")
    model.delete_tile(1, 1)
    eq(model.terrain_at(1, 1), "mountain", "删掉地块不会丢掉它的地形值（撤销/重建都不丢）")
    eq(model.zone_at(1, 1), None, "虚线格不属于任何区块")

    model.clear_tiles()
    eq(model.existing_count(), 0, "清空画布")


def t_validation() -> None:
    print("\n[8] 导出前的问题清单")
    model = mapfile.empty_map(3, 3, None)
    problems = model.problems()
    ok(any("地块" in p for p in problems), "空地图会被提醒")
    ok(any("大本营" in p for p in problems), "没设大本营会被提醒")
    for y in range(3):
        for x in range(3):
            model.create_tile(x, y)
    model.base = (0, 0)
    model.set_terrain(0, 0, "mountain")
    ok(any("山" in p for p in model.problems()), "大本营落在山上会被提醒")
    zone = model.add_zone("空区块")
    ok(any("空区块" in p for p in model.problems()), "空区块会被提醒")
    model.delete_zone(zone.zone_id)
    model.set_terrain(0, 0, "grass")
    eq(model.problems(), [], "都齐了就没有提醒")
    ok(Zone is not None, "Zone 可以正常构造")


def t_base_warning_with_factions() -> None:
    """★ 用户报的：「所有阵营的大本营都设了，导出却弹『大本营点位没设』」。

    根因：那句话检查的是**默认点位**（JSON 里那个单数的 `base`），而它现在只是
    「某些阵营没设大本营时的兜底」。所有阵营都有自己的大本营时，Godot 根本用不到它 ——
    这时再警告一句，只会让人去改一个本来没问题的东西（更糟的是那句提示还写着
    「Godot 会退回地图中心」，而实际上游戏用的是阵营大本营）。

    这里把四种组合都钉住（与 logic/map_data.gd 的 spawn_layout_for 一一对应）。
    """
    print("\n[15] 大本营提醒：有阵营时以阵营大本营为准")

    def fresh():
        m = MapModel(0, 0)
        for t in ((0, 0), (1, 0), (0, 1), (1, 1), (8, 6), (9, 6)):
            m.ensure_tile(*t)
            m.create_tile(*t)
        return m

    # ① 两方大本营都设了、默认点位没设 → **不该**提醒（用户遇到的就是这个）
    m = fresh()
    m.add_faction("p1", "p1")
    m.add_faction("p2", "p2")
    m.set_faction_base("p1", 0, 0)
    m.set_faction_base("p2", 8, 6)
    eq([p for p in m.problems() if "大本营" in p], [],
       "★ 所有阵营都设了大本营 → 不再提「大本营点位没设」（默认点位这时用不到）")

    # ② 没有阵营、默认点位也没设 → 仍然要提醒（这是唯一出生点）
    m2 = fresh()
    ok(any("大本营" in p for p in m2.problems()),
       "★ 没有阵营时，默认点位没设仍然提醒（老行为不能丢）")

    # ③ 有阵营、但某一方要靠默认点位兜底 → 提醒，而且要点名是谁
    m3 = fresh()
    m3.add_faction("p1", "p1")
    problems = m3.problems()
    ok(any("大本营" in p for p in problems), "★ 有一方没设、默认点位也没设 → 要提醒")
    ok(any("p1" in p for p in problems), "★ 提醒里点名了是哪一方要靠兜底（%s）" % problems)

    # ④ 有阵营、都设了，且默认点位也设了 → 一切正常
    m4 = fresh()
    m4.base = (1, 1)
    m4.add_faction("p1", "p1")
    m4.set_faction_base("p1", 0, 0)
    eq([p for p in m4.problems() if "大本营" in p], [], "都设齐了 → 没有大本营相关的提醒")

    # ⑤ 默认点位设了但落在山上 / 虚线格上 → 照旧提醒（与有没有阵营无关）
    m5 = fresh()
    m5.add_faction("p1", "p1")
    m5.set_faction_base("p1", 0, 0)
    m5.base = (0, 0)
    m5.set_terrain(0, 0, "mountain")
    ok(any("山" in p for p in m5.problems() if "大本营" in p), "默认点位在山上照样提醒")

    # ⑥ 阵营大本营自己落在山上 / 虚线格上 → 提醒那一条
    m6 = fresh()
    m6.add_faction("p1", "p1")
    m6.set_faction_base("p1", 1, 1)
    m6.set_terrain(1, 1, "mountain")
    # ⚠️ 断言里搜「山地」不是「山上」：提示原文是「落在山地上」，
    #    「山上」在这句话里**不是**连续子串（中间隔着「地」）—— 写测试时栽过这一次。
    ok(any("山地" in p for p in m6.problems()), "★ 阵营大本营落在山地上会被提醒")


def t_terrain_order() -> None:
    print("\n[9] 地形表")
    eq(TERRAIN_ORDER, ("grass", "forest", "mountain"), "三种地形（与 map_data.gd 一致）")
    cfg = load_config(PROJECT_DIR)
    d = mapfile.empty_map(2, 2, "forest")
    eq(d.terrain_at(0, 0), "forest", "起始地形可以直接铺")
    eq(mapfile.model_to_dict(d)["layout"], ["^^", "^^"], "森林的图例字符是 ^")
    _ = cfg


def t_bom_file() -> None:
    """带 BOM 的 JSON 也要能读（Windows 记事本 / PowerShell 写出来的文件基本都带）。

    这条是实测踩出来的：拖一张带 BOM 的地图进启动器，窗口一闪就没 ——
    因为 `json.loads` 见到 BOM 直接报「不是合法 JSON」。
    """
    print("\n[10] 带 BOM 的地图文件（记事本存出来的那种）")
    tmp = PROJECT_DIR / ".tmp_map_editor_bom_test"
    if tmp.exists():
        shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True, exist_ok=True)
    try:
        path = tmp / "bom.json"
        payload = {
            "cols": 4, "rows": 3,
            "layout": ["....", ".^^.", "...."],
            "exists": [[1, 1, 1, 1], [1, 1, 1, 1], [1, 1, 1, 1]],
            "zones": [[0, 0, 1, 1], [0, 1, 1, 1], [1, 1, 1, 1]],
            "zone_list": [{"id": 0, "name": "东关"}, {"id": 1, "name": "江陵"}],
            "base": [1, 1],
        }
        path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8-sig")
        ok(path.read_bytes()[:3] == b"\xef\xbb\xbf", "测试文件确实带 UTF-8 BOM")

        cfg = load_config(PROJECT_DIR)
        model = mapfile.load_map(path, cfg)
        eq((model.cols, model.rows), (4, 3), "★ 带 BOM 的地图能读进来")
        eq(model.terrain_at(1, 1), "forest", "地形读对了")
        eq([z.name for z in model.zones], ["东关", "江陵"], "区块名读对了")
        eq(model.base, (1, 1), "大本营读对了")

        # 再存一次：写出去的是不带 BOM 的 UTF-8（Godot 读起来最省事）
        out = tmp / "no_bom.json"
        mapfile.save_map(out, model)
        ok(out.read_bytes()[:3] != b"\xef\xbb\xbf", "导出的是不带 BOM 的 UTF-8")
        again = mapfile.load_map(out, cfg)
        eq(again.existing, model.existing, "不带 BOM 的文件同样能读回来")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def t_negative_coords_and_growth() -> None:
    """★ 往左上画（世界坐标是负的）+ 网格变大时不许丢区块归属。

    这里两条都是实测踩出来的坑，值得钉死：

      1. `origin` 平移：数组下标不能是负的，所以模型靠「整体挪一格」把负坐标装下来。
         挪的时候地块、区块、`zone_of`、大本营必须一起搬，且**世界坐标含义不变**。
      2. `zone_of` 的键是 `y * cols + x`：重建它时必须用**旧** cols 拆、**新** cols 拼。
         原来两处都用了新的 `self.cols` —— 于是网格一变大（16→32、128→256…）
         归属就被整张丢掉，而且只在「先划区块、再往新方向画」这个顺序下才出现。
    """
    print("\n[11] 负坐标（往左上画）+ 网格生长")
    m = MapModel(0, 0)
    ok(m.ensure_tile(0, 0) and m.create_tile(0, 0), "先有 (0,0)")
    ok(m.ensure_tile(-1, -1) and m.create_tile(-1, -1), "★ (-1,-1) 建得出来")
    eq((m.origin_x, m.origin_y), (1, 1), "★ 网格原点平移了一格（数组下标仍然非负）")
    eq(m.bounds(), (-1, -1, 0, 0), "★ 包围盒是世界坐标（含负数）")

    # 世界坐标 ↔ 数组下标 的换算
    eq(m.view_of(-1, -1), (0, 0), "世界 (-1,-1) → 数组 (0,0)")
    eq(m.world_of(0, 0), (-1, -1), "数组 (0,0) → 世界 (-1,-1)")
    ok(m.in_bounds(-1, -1) and not m.in_bounds(-99, -99), "越界的负坐标不算在网格里")

    # 平移之后：地形 / 区块 / 大本营都要跟着走
    m.set_terrain(-1, -1, "mountain")
    zone = m.add_zone("东关")
    m.assign_tile(-1, -1, zone.zone_id)
    m.base = (-1, -1)
    m.ensure_tile(-2, -2)
    m.create_tile(-2, -2)
    eq(m.terrain_at(-1, -1), "mountain", "★ 再往左上画：老地块的地形没丢")
    eq(m.zone_at(-1, -1).zone_id, zone.zone_id, "★ 区块归属没丢")
    eq(m.base, (-1, -1), "★ 大本营没跑")
    eq(m.bounds(), (-2, -2, 0, 0), "包围盒跟着长大")

    # 网格生长（cols 变了）不许把 zone_of 弄丢 —— 就是上面说的第 2 条
    before_zones = {z.zone_id: set(z.tiles) for z in m.zones}
    before_cols = m.cols
    m.ensure_tile(m.cols + 5, 3)          # 强制长一格（cols 会变）
    ok(m.cols > before_cols, "★ 网格确实长大了（%d → %d）" % (before_cols, m.cols))
    eq({z.zone_id: set(z.tiles) for z in m.zones}, before_zones,
       "★ 长大之后区块的地块集合不变")
    eq(m.zone_at(-1, -1).zone_id, zone.zone_id,
       "★ 长大之后 zone_of 仍然指得对（键要用新 cols 重新编号）")

    # 导出：尺寸 = 包围盒，坐标搬到 (0,0)
    data = mapfile.model_to_dict(m)
    eq((data["cols"], data["rows"]), (3, 3), "★ 导出尺寸 = 包围盒 3×3")
    eq(data["base"], [1, 1], "大本营搬到导出坐标系（(-1,-1) → (1,1)）")

    # 上限：越界那一下不建格，也不会崩
    ok(not m.can_draw_at(MAX_COORD, 0), "★ 超出 MAX_COORD 不接受落笔")
    ok(not m.ensure_tile(MAX_COORD, 0), "ensure_tile 同样拒绝")
    # ★ 边界上的那一格必须真的画得出来 ——
    #   否则「状态栏说能画到某个范围，实际差一格就被内存安全网拦下」，
    #   那就又成了一条「说了能画却画不了」的隐形线。
    #   ⚠️ 边界位置**不能写死**：数组下标 = 世界坐标 + origin，而 origin 会随
    #      「往左上画」变大 —— 上面已经往左上画过，所以右上方向的余量变小了。
    #      这里就用模型自己的 `draw_room` 算出「最右/最下那一格的世界坐标」。
    (left, up), (right, down) = m.draw_room(0, 0)
    ok(left > 0 and right > 0, "左右都还有空间（左 %d、右 %d）" % (left, right))
    edge_x, edge_y = right, down              # 从 (0,0) 出发往右/往下能走到的最后一格
    ok(m.can_draw_at(edge_x, edge_y), "★ 贴着边界的那一格被判为「画得出来」（%d,%d）"
       % (edge_x, edge_y))
    ok(not m.can_draw_at(edge_x + 1, edge_y), "边界外一格画不出来（差一格也不行）")
    ok(m.ensure_tile(edge_x, edge_y), "★ 边界那一格真的画得出来（不被内存安全网误拦）")
    m.create_tile(edge_x, edge_y)
    ok(m.exists(edge_x, edge_y), "边界格子真的建出来了")


def t_memory_guard() -> None:
    """内存安全网：只拦「会长到把进程干掉」的那一下，不拦正常画图。

    ⚠️ 这条测试**必须改小 `MAX_GRID_BYTES`**：按当前常量，MAX_COORD 之内最大的网格
    （4096×4096 ≈ 144 MB）离 512 MB 还远，正常路径根本走不到这个分支 ——
    而「走不到的分支」正是最容易在以后调常量时悄悄坏掉的那种。
    """
    print("\n[12] 内存安全网（模拟成很小的上限来触发）")
    m = MapModel(0, 0)
    m.ensure_tile(0, 0)
    m.create_tile(0, 0)
    saved = model_module.MAX_GRID_BYTES
    try:
        model_module.MAX_GRID_BYTES = 1        # 任何生长都会超出
        ok(not m.ensure_tile(200, 200), "★ 会长到超标的那一下被拒绝（不崩、不分配）")
        eq(m.cols, 17, "被拒绝时网格尺寸没变（没白分配）")
    finally:
        model_module.MAX_GRID_BYTES = saved
    ok(m.ensure_tile(200, 200), "把上限放回去之后，同一格又能画了")


def t_faction_bases() -> None:
    """阵营与它们的大本营（数据层）。

    钉住的几条（都是「改了会静默出错」的地方）：
      · 一个阵营一个大本营；同一格被两个阵营抢时，后者**拿走**（不能两个阵营同一格）；
      · 删格子 / 缩小网格时，指向它的那个大本营要一起忘掉（否则导出后是图外坐标）；
      · 大本营写进 JSON 时坐标要搬到导出坐标系（往左上画过之后尤其容易错）。
    """
    print("\n[13] 阵营大本营（数据层）")
    m = MapModel(0, 0)
    for t in ((3, 3), (4, 3), (3, 4), (4, 4), (-1, -1)):
        m.ensure_tile(*t)
        m.create_tile(*t)

    ok(m.add_faction("p1", "玩家") is not None, "加阵营 player")
    ok(m.add_faction("p2") is not None, "加阵营 p2（名字缺省 = id）")
    ok(m.add_faction("p1") is None, "★ 同一个 id 加两次 → 拒绝（返回 None）")
    ok(m.add_faction("") is None, "空 id 也拒绝")
    eq([f.faction_id for f in m.factions], ["p1", "p2"], "阵营表按加入顺序")
    eq(m.faction("p2").name, "p2", "名字缺省时用 id")
    ok(m.faction("p1").color != m.faction("p2").color, "★ 两个阵营的默认颜色不同（地图上分得清）")

    # 设大本营
    ok(not m.set_faction_base("nobody", 3, 3), "没这个阵营 → 设不了")
    ok(not m.set_faction_base("p1", 99, 99), "★ 不存在的格子设不了")
    ok(m.set_faction_base("p1", 3, 3), "★ player 的大本营设在 (3,3)")
    eq(m.faction_base_of("p1"), (3, 3), "查得到")
    eq(m.faction_base_owner(3, 3), "p1", "反向查得到")
    ok(not m.set_faction_base("p1", 3, 3), "同一格再设一次 → 没变化")

    # 抢格：一格只能是一方的大本营
    ok(m.set_faction_base("p2", 3, 3), "p2 把 (3,3) 抢过去")
    eq(m.faction_base_owner(3, 3), "p2", "★ 那一格现在属于 p2")
    eq(m.faction_base_of("p1"), None, "★ player 的大本营被拿走了（不能两方共用一格）")

    # 删格子 → 大本营一起忘掉
    m.delete_tile(3, 3)
    eq(m.faction_base_of("p2"), None, "★ 删掉那一格 → 大本营也忘掉")

    # 取消
    m.set_faction_base("p1", 4, 4)
    ok(m.clear_faction_base("p1"), "能取消大本营")
    eq(m.faction_base_of("p1"), None, "取消之后查不到")
    ok(not m.clear_faction_base("p1"), "再取消一次 → 没变化")

    # 删阵营 → 大本营一起没
    m.set_faction_base("p1", 3, 4)
    ok(m.remove_faction("p1"), "删阵营")
    eq(m.faction_base_of("p1"), None, "★ 阵营没了，它的大本营也没了")
    eq(m.faction_base_owner(3, 4), None, "反向也查不到")

    # 往左上画过之后导出的坐标（要搬到导出坐标系）
    m2 = MapModel(0, 0)
    for t in ((0, 0), (-1, -1), (-2, -2)):
        m2.ensure_tile(*t)
        m2.create_tile(*t)
    m2.add_faction("p1")
    m2.set_faction_base("p1", -2, -2)
    data = mapfile.model_to_dict(m2)
    eq(data["faction_bases"], {"p1": [0, 0]},
       "★ 大本营坐标搬到了导出坐标系（(-2,-2) 是包围盒左上角 → (0,0)）")
    eq(data["factions"], [{"id": "p1", "name": "p1", "color": m2.factions[0].color}],
       "阵营表写进 JSON")

    # 往返：读回来还是同一个大本营
    again = mapfile.dict_to_model(data, {})
    eq(again.faction_base_of("p1"), (0, 0), "★ 读回来之后大本营一致")
    eq([f.faction_id for f in again.factions], ["p1"], "读回来之后阵营表一致")

    # ★ 没有阵营的地图不该多出这两个字段（旧图往返逐字节一致靠这条）
    plain = MapModel(0, 0)
    plain.ensure_tile(0, 0)
    plain.create_tile(0, 0)
    plain_data = mapfile.model_to_dict(plain)
    ok("factions" not in plain_data and "faction_bases" not in plain_data,
       "★ 没有阵营时 JSON 里不出现 factions / faction_bases")


def t_rect_selection() -> None:
    """矩形框选的内容（只有已有地块参与）。"""
    print("\n[14] 矩形框选")
    m = MapModel(0, 0)
    for t in ((0, 0), (1, 0), (2, 0), (1, 1), (5, 5)):
        m.ensure_tile(*t)
        m.create_tile(*t)
    tiles = m.rect_tiles(0, 0, 2, 1)
    eq(tiles, [(0, 0), (1, 0), (2, 0), (1, 1)], "★ 框选只返回已有地块（按行优先）")
    eq(m.rect_tiles(0, 0, 2, 1), m.rect_tiles(2, 1, 0, 0),
       "★ 两个角反着传也认（矩形会规范化）")
    eq(m.rect_tiles(9, 9, 10, 10), [], "空白区域 → 空列表")
    eq(m.count_in_rect(0, 0, 1, 1), 3, "count_in_rect 只数已有地块")
    ok((5, 5) not in m.rect_tiles(0, 0, 2, 1), "框外的不算")


def main() -> int:
    print("DAEEM 地图编辑器 · 数据层测试")
    print("工程目录：%s" % PROJECT_DIR)
    t_parse_color()
    t_config()
    t_legacy_import()
    t_legacy_roundtrip_is_byte_stable()
    t_editor_format_roundtrip()
    t_zone_ops()
    t_shape_ops()
    t_validation()
    t_base_warning_with_factions()
    t_terrain_order()
    t_bom_file()
    t_negative_coords_and_growth()
    t_memory_guard()
    t_faction_bases()
    t_rect_selection()
    print("\n[CASE] test_model -> passed %d / failed %d" % (_PASSED, _FAILED))
    return 1 if _FAILED else 0


if __name__ == "__main__":
    raise SystemExit(main())
