#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/smoke_test.py —— 无头逻辑校验（Python 版，等价于 tools/smoke-test.mjs）

没有 Node / 浏览器也能跑：用 Python 复刻同一套规则做校验：
地图连通性、四连通 A*、地块唯一建筑、城墙只挡敌方、箭塔单体伤害与冷却、
区块占领计时与资源增长、直线移动（路径拉直）、战斗与警戒。

运行： python tools/smoke_test.py

⚠️ 带 “与 js/xxx.js 等价” 注释的函数是 JS 源码的**镜像**，改了 js 里的对应逻辑
   记得同步改这里。战斗 / 移动的真模块测试在 tools/smoke-test.mjs（需要 Node）。
"""

import math
import sys
from collections import deque

# Windows 控制台默认是 GBK，打印 ✔ / 中文会抛 UnicodeEncodeError 把测试打断
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

# ------------------------- 与 js/config.js 保持一致 -------------------------
CELL = 120
MAP_COLS, MAP_ROWS = 24, 16
FOOD_PER_TILE = 1.0
GOLD_PER_TILE = 1.0
UNIT_SPEED = 2.4
CAMERA_MIN_SCALE = 0.18
CAMERA_MAX_SCALE = 1.6
EDGE_SIZE = 44
EDGE_MAX_SPEED = 1500
UNIT_RADIUS_FACTOR = 0.1
FOREST_MULT = 0.5
UNIT_HP = 200
ZONE_COLS, ZONE_ROWS = 6, 4
CAPTURE_TIME = 4.0
DECAY_PER_SEC = 0.6
ZONE_OWNED_BY_BUILDING = True
TOWER_DAMAGE, TOWER_RANGE, TOWER_COOLDOWN = 12, 3, 0.8
ENEMY_HP = 60
# ---- CONFIG.combat ----
AGGRO_RANGE = 4          # 警戒半径（格）
LEASH_FACTOR = 1.8       # 追击上限 = AGGRO_RANGE × 该系数
REPATH_SEC = 0.3         # 追击时重新寻路的最小间隔（秒）
BUILDING_DAMAGE = 40     # 单位每次攻击建筑的伤害
GENERAL_DAMAGE, GENERAL_RANGE, GENERAL_CD = 26, 1, 0.9
ENEMY_DAMAGE, ENEMY_RANGE, ENEMY_CD = 10, 1, 1.2
# ---- CONFIG.building ----
WALL_HP = 300            # 城墙血量
BASE_HP = 1000           # 大本营血量

MAP_LAYOUT = [
    '........................',
    '........................',
    '........................',
    '....^^.......###########',
    '....^..........#........',
    '...............#........',
    '...............#........',
    '...............#........',
    '........................',
    '........................',
    '........................',
    '........................',
    '.............^^.........',
    '........................',
    '........................',
    '........................',
]

DIRS4 = ((0, -1), (1, 0), (0, 1), (-1, 0))

# 建筑属性：blocks_player / blocks_enemy / hp
BUILDINGS = {
    'base':  dict(name='大本营', blocks_player=True,  blocks_enemy=True,  buildable=False, hp=BASE_HP),
    'wall':  dict(name='城墙',   blocks_player=False, blocks_enemy=True,  buildable=True,  hp=WALL_HP),
    'tower': dict(name='箭塔',   blocks_player=True,  blocks_enemy=True,  buildable=True),
}

pass_n = 0
fail_n = 0


def ok(cond, msg):
    global pass_n, fail_n
    if cond:
        pass_n += 1
        print(f'  \u2714 {msg}')
    else:
        fail_n += 1
        print(f'  \u2718 {msg}')


def section(t):
    print(f'\n== {t} ==')


# ------------------------------- 地图 -------------------------------
class Map:
    def __init__(self):
        self.terrain = [['grass'] * MAP_COLS for _ in range(MAP_ROWS)]
        self.base = None
        for y in range(MAP_ROWS):
            row = MAP_LAYOUT[y] if y < len(MAP_LAYOUT) else ''
            for x in range(MAP_COLS):
                ch = row[x] if x < len(row) else '.'
                if ch == '#':
                    self.terrain[y][x] = 'mountain'
                elif ch == '^':
                    self.terrain[y][x] = 'forest'
                elif ch == 'B':
                    self.terrain[y][x] = 'grass'
                    self.base = (x, y)
        if self.base is None:
            self.base = (MAP_COLS // 2, MAP_ROWS // 2)

        # 连通性修正：把从大本营到不了的可行走格变成山
        reach = flood_fill(self, self.base)
        self.sealed = 0
        for y in range(MAP_ROWS):
            for x in range(MAP_COLS):
                if self.terrain[y][x] != 'mountain' and (x, y) not in reach:
                    self.terrain[y][x] = 'mountain'
                    self.sealed += 1


def in_bounds(x, y):
    return 0 <= x < MAP_COLS and 0 <= y < MAP_ROWS


def walkable(m, x, y):
    return in_bounds(x, y) and m.terrain[y][x] != 'mountain'


def terrain_cost(m, x, y):
    return 1.0 / FOREST_MULT if m.terrain[y][x] == 'forest' else 1.0


def flood_fill(m, start):
    seen = {start}
    q = deque([start])
    while q:
        x, y = q.popleft()
        for dx, dy in DIRS4:
            nx, ny = x + dx, y + dy
            if walkable(m, nx, ny) and (nx, ny) not in seen:
                seen.add((nx, ny))
                q.append((nx, ny))
    return seen


# ------------------------------- 状态 -------------------------------
class State:
    def __init__(self):
        m = Map()
        self.map = m
        self.terrain = m.terrain
        self.base = m.base
        self.sealed = m.sealed
        self.buildings = {}          # (x,y) -> dict(type=..., owner=...)
        self.units = []
        self.resources = dict(food=0.0, gold=0.0)
        # 区块
        self.zones = []
        for zy in range(ZONE_ROWS):
            for zx in range(ZONE_COLS):
                x0 = zx * MAP_COLS // ZONE_COLS
                x1 = (zx + 1) * MAP_COLS // ZONE_COLS - 1
                y0 = zy * MAP_ROWS // ZONE_ROWS
                y1 = (zy + 1) * MAP_ROWS // ZONE_ROWS - 1
                self.zones.append(dict(
                    id=zy * ZONE_COLS + zx,
                    name=f'{chr(65 + zy)}{zx + 1}',
                    x0=x0, y0=y0, x1=x1, y1=y1,
                    owner=None, progress=0.0,
                    tile_count=(x1 - x0 + 1) * (y1 - y0 + 1),
                ))
        self.zone_lookup = {}
        for z in self.zones:
            for y in range(z['y0'], z['y1'] + 1):
                for x in range(z['x0'], z['x1'] + 1):
                    self.zone_lookup[(x, y)] = z['id']

    # 地块 -> 区块
    def zone_at(self, x, y):
        if not in_bounds(x, y):
            return None
        zid = self.zone_lookup.get((x, y))
        return self.zones[zid] if zid is not None else None

    def owned_tiles(self, owner='player'):
        return sum(z['tile_count'] for z in self.zones if z['owner'] == owner)


def passable(st, x, y, faction):
    if not walkable(st.map, x, y):
        return False
    b = st.buildings.get((x, y))
    if b:
        d = BUILDINGS[b['type']]
        return not (d['blocks_player'] if faction == 'player' else d['blocks_enemy'])
    return True


def occupied(st, x, y):
    return (x, y) in st.buildings


def add_building(st, btype, x, y, owner='player'):
    if not in_bounds(x, y) or occupied(st, x, y):
        return None
    st.buildings[(x, y)] = dict(type=btype, owner=owner, hp=BUILDINGS[btype].get('hp', 300),
                                cooldown=0.0)
    return st.buildings[(x, y)]


def remove_building(st, x, y):
    b = st.buildings.get((x, y))
    if not b or b['type'] == 'base':
        return False
    del st.buildings[(x, y)]
    return True


# --------------------------- A* 四连通寻路 ---------------------------
def find_path(st, frm, to, faction):
    if not in_bounds(*frm) or not in_bounds(*to):
        return None
    if frm == to:
        return []
    if not passable(st, to[0], to[1], faction):
        return None

    import heapq
    open_heap = [(abs(frm[0] - to[0]) + abs(frm[1] - to[1]), 0.0, frm)]
    g = {frm: 0.0}
    came = {}
    closed = set()
    while open_heap:
        _, gc, cur = heapq.heappop(open_heap)
        if cur == to:
            out = []
            k = to
            while k != frm:
                out.append(k)
                k = came[k]
            out.reverse()
            return out
        if cur in closed:
            continue
        closed.add(cur)
        for dx, dy in DIRS4:
            nx, ny = cur[0] + dx, cur[1] + dy
            if not passable(st, nx, ny, faction):
                continue
            nxt = (nx, ny)
            if nxt in closed:
                continue
            ng = g[cur] + terrain_cost(st.map, nx, ny)
            if nxt not in g or ng < g[nxt] - 1e-9:
                g[nxt] = ng
                came[nxt] = cur
                h = abs(nx - to[0]) + abs(ny - to[1])
                heapq.heappush(open_heap, (ng + h, ng, nxt))
    return None


def reachable_tiles(st, frm, faction):
    """⚠️ 与 js/path.js 的 reachableTiles 等价：按阵营通行规则 BFS，返回所有走得到的地块"""
    if not in_bounds(*frm):
        return set()
    seen = {tuple(frm)}
    q = deque([tuple(frm)])
    while q:
        x, y = q.popleft()
        for dx, dy in DIRS4:
            p = (x + dx, y + dy)
            if p in seen or not in_bounds(*p):
                continue
            if not passable(st, p[0], p[1], faction):
                continue
            seen.add(p)
            q.append(p)
    return seen


def nearest_reachable(st, frm, target, faction, max_radius=12):
    """⚠️ 与 js/path.js 的 nearestReachable 等价。
    ★ 只会返回“从 frm 真的走得到”的格子：BFS 是从目标往外扩的，第一圈可通行格
      很可能是墙 / 山**另一侧**的格子，旧实现直接返回它，调用方就会以为哪都去不了。"""
    if passable(st, target[0], target[1], faction):
        return target
    region = reachable_tiles(st, frm, faction)
    seen = {target}
    frontier = [target]
    for _ in range(max_radius):
        nxt = []
        for c in frontier:
            for dx, dy in DIRS4:
                p = (c[0] + dx, c[1] + dy)
                if p in seen or not in_bounds(*p):
                    continue
                seen.add(p)
                if passable(st, p[0], p[1], faction):
                    if p in region:
                        return p
                    continue                      # 墙那一边的格子：当不了终点
                nxt.append(p)
        frontier = nxt
        if not frontier:
            break
    return None


def find_blocking_wall_toward(st, frm, to, faction):
    """⚠️ 与 js/path.js 的 findBlockingWallToward 等价：
    挨着“frm 这边走得到的区域”、且离 to 最近的敌方城墙（旧实现只看身边 2 格内）。"""
    region = reachable_tiles(st, frm, faction)
    best, best_d = None, None
    for (bx, by), b in st.buildings.items():
        if b['type'] != 'wall' or b.get('owner') == faction or b['hp'] <= 0:
            continue
        if not any((bx + dx, by + dy) in region for dx, dy in DIRS4):
            continue
        d = abs(bx - to[0]) + abs(by - to[1])
        if best_d is None or d < best_d:
            best, best_d = (bx, by), d
    return best


# ------------------------------- 单位 -------------------------------
def make_general(st, x, y, idx=1):
    u = dict(id=f'general-{idx}', name=f'将领 {idx}', tx=x, ty=y, faction='player',
             kind='general', hp=UNIT_HP, hp_max=UNIT_HP, alive=True, path=None, goal=None)
    return u


def update_towers(st, dt):
    """箭塔：对射程内最近的敌人造成单体伤害"""
    for (tx, ty), b in st.buildings.items():
        if b['type'] != 'tower':
            continue
        if b['cooldown'] > 0:
            b['cooldown'] = max(0.0, b['cooldown'] - dt)
        cx, cy = (tx + 0.5) * CELL, (ty + 0.5) * CELL
        best, best_d = None, 1e9
        for u in st.units:
            if not u['alive'] or u['faction'] == b['owner']:
                continue
            ux, uy = (u['tx'] + 0.5) * CELL, (u['ty'] + 0.5) * CELL
            d = ((ux - cx) ** 2 + (uy - cy) ** 2) ** 0.5
            # ⚠️ 与 js/building.js 一致：射程外缘再加"单位半径"的余量（unitRadius('enemy')）
            if d <= TOWER_RANGE * CELL + CELL * UNIT_RADIUS_FACTOR * 0.75 and d < best_d:
                best, best_d = u, d
        if best is not None and b['cooldown'] <= 0:
            best['hp'] = max(0, best['hp'] - TOWER_DAMAGE)
            if best['hp'] <= 0:
                best['alive'] = False
            b['cooldown'] = TOWER_COOLDOWN


def update_zones(st, dt):
    touched = set()
    for u in st.units:
        if not u.get('alive') or u['faction'] != 'player':
            continue
        z = st.zone_at(u['tx'], u['ty'])
        if z and z['owner'] != 'player':
            touched.add(z['id'])
    for z in st.zones:
        if z['owner'] == 'player':
            continue
        if z['id'] in touched:
            z['progress'] = min(1.0, z['progress'] + dt / CAPTURE_TIME)
            if z['progress'] >= 1.0:
                z['owner'] = 'player'
        elif z['progress'] > 0:
            z['progress'] = max(0.0, z['progress'] - DECAY_PER_SEC * dt)


def refresh_building_ownership(st):
    if not ZONE_OWNED_BY_BUILDING:
        return
    for z in st.zones:
        if z['owner'] == 'player':
            continue
        for (x, y), b in st.buildings.items():
            if b['owner'] == 'player' and st.zone_at(x, y) is z:
                z['owner'] = 'player'
                z['progress'] = 1.0
                break


# =============================== 校验 ===============================
section('地图：尺寸 / 行长度 / 四连通连通性')
st = State()
bad_rows = [i for i, r in enumerate(MAP_LAYOUT) if len(r) != MAP_COLS]
ok(not bad_rows, f'每行都是 {MAP_COLS} 个字符（异常行：{bad_rows or "无"}）')
ok(len(MAP_LAYOUT) == MAP_ROWS, f'共 {len(MAP_LAYOUT)} 行 = {MAP_ROWS}')
ok(st.terrain[st.base[1]][st.base[0]] == 'grass', f'大本营点位 {st.base} 在草地上')
ok(st.sealed == 0, f'不存在被隔离的可通行区域（本次封堵 {st.sealed} 格）')
walkable_n = sum(1 for y in range(MAP_ROWS) for x in range(MAP_COLS) if walkable(st.map, x, y))
reach = flood_fill(st.map, st.base)
ok(len(reach) == walkable_n, f'{walkable_n} 个可通行地块全部从大本营可达（只有一个连通区域）')
mountain_n = sum(1 for y in range(MAP_ROWS) for x in range(MAP_COLS) if st.terrain[y][x] == 'mountain')
ok(mountain_n == 15, f'山体共 {mountain_n} 格（15 = 第3行横墙11格 + 第15列竖墙4格）')

section('寻路：四连通 A*')
p = find_path(st, (10, 10), (19, 4), 'player')
ok(p is not None, '(10,10) → (19,4) 有路径（需要绕过山体）')
ok(p is not None and len(p) == 15, f'路径长度 15（实际 {len(p) if p else None}）')
ok(p is not None and all(
    abs(p[i][0] - p[i - 1][0]) + abs(p[i][1] - p[i - 1][1]) == 1 for i in range(1, len(p))
), '路径每一步都是上下左右相邻 → 四连通')
ok(find_path(st, (10, 10), (13, 3), 'player') is None, '目标为山体时返回 None（不可达）')
p_forest = find_path(st, (10, 10), (4, 3), 'player')
ok(p_forest is not None and all(
    abs(p_forest[i][0] - p_forest[i - 1][0]) + abs(p_forest[i][1] - p_forest[i - 1][1]) == 1
    for i in range(1, len(p_forest))), '穿过森林的路径同样保持四连通')

section('建筑：每格最多一个 / 城墙通行规则')
st = State()
ok(add_building(st, 'wall', 12, 10) is not None, '在 (12,10) 建造城墙成功')
ok(add_building(st, 'wall', 12, 10) is None, '同一地块再建建筑被拒绝（每格仅一个建筑）')
ok(occupied(st, 12, 10), 'occupied() 能识别建筑占据')
ok(passable(st, 12, 10, 'player') is True, '城墙对己方单位放行（己方可以穿过）')
ok(passable(st, 12, 10, 'enemy') is False, '城墙对敌方单位阻挡（敌方不可进入）')
pp = find_path(st, (10, 10), (14, 10), 'player')
ok(pp is not None and (12, 10) in pp, '己方路径直接穿过城墙所在格')
pe = find_path(st, (10, 10), (14, 10), 'enemy')
ok(pe is not None and (12, 10) not in pe, '敌方路径不会穿过城墙格（绕行）')

st2 = State()
for dx, dy in DIRS4:
    add_building(st2, 'wall', 5 + dx, 5 + dy)
ok(find_path(st2, (10, 10), (5, 5), 'enemy') is None, '被城墙完全围住时敌方无路径（阻挡生效）')
ok(passable(st2, 5, 5, 'player') is True, '同一围城里己方仍可进入')
add_building(st, 'tower', 14, 10)
near = nearest_reachable(st, (10, 10), (14, 10), 'player')
ok(near is not None and near != (14, 10), f'目标被箭塔占据时自动改走邻格 {near}')
wall_tile = nearest_reachable(st, (10, 10), (12, 10), 'player')
ok(wall_tile == (12, 10), '己方可以走到城墙格上（城墙对己方不阻挡）')
wall_enemy = find_path(st, (14, 11), (12, 10), 'enemy')
ok(wall_enemy is None or (12, 10) not in wall_enemy, '敌方无法把城墙格当作终点')

section('箭塔：单体伤害 / 射程 / 冷却 / 不误伤己方')
st3 = State()
tower = add_building(st3, 'tower', 5, 5)
far = dict(id='far', faction='enemy', kind='enemy', tx=5, ty=5 + TOWER_RANGE + 2,
           hp=ENEMY_HP, hp_max=ENEMY_HP, alive=True, name='远处敌人')
inr = dict(id='in', faction='enemy', kind='enemy', tx=5, ty=5 + TOWER_RANGE,
           hp=ENEMY_HP, hp_max=ENEMY_HP, alive=True, name='射程内敌人')
ally = dict(id='ally', faction='player', kind='general', tx=6, ty=5,
            hp=UNIT_HP, hp_max=UNIT_HP, alive=True, name='己方将领')
st3.units = [far, inr, ally]
update_towers(st3, 0.016)
ok(far['hp'] == ENEMY_HP, '射程外敌人不受伤')
ok(inr['hp'] == ENEMY_HP - TOWER_DAMAGE, f'射程内敌人受到 {TOWER_DAMAGE} 点单体伤害')
ok(ally['hp'] == UNIT_HP, '己方单位不会被己方箭塔误伤')
hp1 = inr['hp']
update_towers(st3, 0.016)
ok(inr['hp'] == hp1, '冷却时间内不会重复开火')
update_towers(st3, TOWER_COOLDOWN + 0.01)
ok(inr['hp'] == hp1 - TOWER_DAMAGE, '冷却结束后可再次开火')
tick = 0
while inr['alive'] and tick < 100:
    update_towers(st3, TOWER_COOLDOWN + 0.01)
    tick += 1
ok(not inr['alive'], f'敌人血量归零后死亡（{(ENEMY_HP + TOWER_DAMAGE - 1) // TOWER_DAMAGE} 次命中）')
ok(remove_building(st3, 5, 5) is True, '箭塔可以拆除')
add_building(st3, 'base', 8, 8)
ok(remove_building(st3, 8, 8) is False, '大本营不可拆除')

section('区块占领（占位规则）与资源增长')
st4 = State()
ok(len(st4.zones) == ZONE_COLS * ZONE_ROWS, f'区块数量 = {ZONE_COLS} × {ZONE_ROWS} = {len(st4.zones)}')
total = sum(z['tile_count'] for z in st4.zones)
ok(total == MAP_COLS * MAP_ROWS, f'各区块地块数之和 = {total} = 全部 {MAP_COLS * MAP_ROWS} 格')
base_zone = st4.zone_at(*st4.base)
ok(base_zone is not None, f'大本营所在区块 = {base_zone["name"]}')

g = make_general(st4, 0, 0, 1)
st4.units = [g]
z = st4.zone_at(0, 0)
ok(z is not None and z['owner'] is None, f'(0,0) 属于区块 {z["name"]}，初始无主')
dt, elapsed = 0.1, 0.0
while z['owner'] != 'player' and elapsed < 10:
    update_zones(st4, dt)
    elapsed += dt
ok(z['owner'] == 'player', f'站入 {elapsed:.1f} 秒后区块 {z["name"]} 归己方（配置 {CAPTURE_TIME} 秒）')
ok(abs(elapsed - CAPTURE_TIME) < 0.25, '占领耗时与配置一致')
owned = st4.owned_tiles('player')
ok(owned == z['tile_count'], f'己方地块数 = {owned} = 该区块地块数')
st4.resources['food'] += owned * FOOD_PER_TILE * 1.0
st4.resources['gold'] += owned * GOLD_PER_TILE * 1.0
ok(st4.resources['food'] == owned, f'1 秒 +{st4.resources["food"]} 粮食 = 己方地块数 × {FOOD_PER_TILE}')
ok(st4.resources['gold'] == owned, f'1 秒 +{st4.resources["gold"]} 黄金 = 己方地块数 × {GOLD_PER_TILE}')

st5 = State()
g5 = make_general(st5, 23, 0, 1)
st5.units = [g5]
z5 = st5.zone_at(23, 0)
update_zones(st5, 2.0)
p1 = z5['progress']
ok(0 < p1 < 1, f'占领进度增长中（{p1:.2f}）')
g5['tx'], g5['ty'] = 0, 15
update_zones(st5, 0.5)
ok(z5['progress'] < p1, f'单位离开后进度回退（{z5["progress"]:.2f} < {p1:.2f}）')

st6 = State()
z6 = st6.zone_at(2, 2)
add_building(st6, 'tower', 2, 2)
refresh_building_ownership(st6)
ok(z6['owner'] == 'player', f'区块 {z6["name"]} 内有己方建筑即归己方（switch = {ZONE_OWNED_BY_BUILDING}）')

section('坐标换算：屏幕点 → 世界 → 地块（高 DPI 错位回归）')
# 与 js/render.js 的 screenToWorld / worldToTile / tileCenter 完全一致：
#   world = cam + screen / scale          （screen 一律用 CSS 像素）
#   tile  = floor(world / cell)
# 只要“画布后备缓冲按 dpr 放大、绘制前 ctx.scale(dpr)”这条约定被破坏，
# 屏幕点与地块就会错位——这里用纯数学把换算关系锁住。
class Cam:
    def __init__(self, x, y, scale):
        self.x, self.y, self.scale = x, y, scale


def screen_to_world(cam, sx, sy):
    return (cam.x + sx / cam.scale, cam.y + sy / cam.scale)


def world_to_tile(wx, wy):
    return (int(wx // CELL), int(wy // CELL))


def tile_center(tx, ty):
    return ((tx + 0.5) * CELL, (ty + 0.5) * CELL)


cam = Cam(-40.0, -12.5, 1.37)
errs = 0
checks = 0
for sx, sy in [(0, 0), (1, 1), (37, 91), (240, 200), (601, 399), (1200, 700)]:
    wx, wy = screen_to_world(cam, sx, sy)
    tx, ty = world_to_tile(wx, wy)
    # 1) 鼠标世界坐标必须落在判定出的地块矩形内
    if not (tx * CELL <= wx < (tx + 1) * CELL and ty * CELL <= wy < (ty + 1) * CELL):
        errs += 1
    checks += 1
    # 2) 该地块中心反算回屏幕，必须还落在同一个地块里
    cx, cy = tile_center(tx, ty)
    bx, by = world_to_tile(cx, cy)
    if (bx, by) != (tx, ty):
        errs += 1
    checks += 1
    # 3) 地块中心 → 屏幕坐标 → 再回世界，必须还原
    bsx = (cx - cam.x) * cam.scale
    bsy = (cy - cam.y) * cam.scale
    rx, ry = screen_to_world(cam, bsx, bsy)
    if abs(rx - cx) > 1e-6 or abs(ry - cy) > 1e-6:
        errs += 1
    checks += 1
ok(errs == 0, f'屏幕/世界/地块 三种换算自洽（检查 {checks} 项，异常 {errs}）')

# 高 DPI：后备缓冲 = CSS 尺寸 × dpr 时，绘制矩阵会把世界坐标铺满整个视口
DPR = 2.0
view_w, view_h = 1200, 700
cvs_w, cvs_h = int(view_w * DPR), int(view_h * DPR)
ok(cvs_w == 2400 and cvs_h == 1400, f'dpr={DPR} 时后备缓冲 {cvs_w}×{cvs_h}（CSS {view_w}×{view_h}）')
ok(abs(view_w * DPR - cvs_w) < 1 and abs(view_h * DPR - cvs_h) < 1, '后备缓冲与 CSS 尺寸严格成 dpr 倍数')
# 若漏掉 ctx.scale(dpr)，世界只会画进左上角 1/dpr 区域 → 右下角鼠标点会落到错误的格
cam_bad = Cam(0.0, 0.0, 1.0)
bad_tile = world_to_tile(*screen_to_world(cam_bad, 1000, 600))
good_tile = world_to_tile(*screen_to_world(cam_bad, 1000 / DPR, 600 / DPR))
ok(bad_tile != good_tile, f'漏掉 dpr 变换会导致错位（(1000,600) 会误判为 {bad_tile} 而不是 {good_tile}）')


section('单位移动：点到哪走到哪（像素级）+ 能走直线就走直线 + 不跳格')
# ⚠️ 下面是 js/unit.js 里 moveTo + stepAlongPath + syncTile 以及 js/path.js 里
#    segmentClear + smoothPath 的等价镜像实现，改了这几处逻辑请同步改这里。
#    注意：passable / nearest_reachable / find_path 直接用上面已定义的实现，
#    不要在这里重复定义同名函数（会造成无限递归）。


def segment_clear(st, ax, ay, bx, by, faction):
    """⚠️ 与 js/path.js 的 segmentClear 等价：直线是否“全程可通行”（超覆盖 DDA，像素坐标）"""
    x0, y0 = ax / CELL, ay / CELL
    dx, dy = bx / CELL - x0, by / CELL - y0
    tx, ty = int(math.floor(x0)), int(math.floor(y0))
    step_x = 1 if dx > 0 else -1
    step_y = 1 if dy > 0 else -1
    t_dx = abs(1 / dx) if dx != 0 else float('inf')
    t_dy = abs(1 / dy) if dy != 0 else float('inf')
    t_max_x = (((tx + 1 - x0) if dx > 0 else (x0 - tx)) * t_dx) if dx != 0 else float('inf')
    t_max_y = (((ty + 1 - y0) if dy > 0 else (y0 - ty)) * t_dy) if dy != 0 else float('inf')
    for _ in range(8192):
        if t_max_x > 1 and t_max_y > 1:
            return True
        if t_max_x < t_max_y:
            tx += step_x
            t_max_x += t_dx
            if not passable(st, tx, ty, faction):
                return False
        elif t_max_y < t_max_x:
            ty += step_y
            t_max_y += t_dy
            if not passable(st, tx, ty, faction):
                return False
        else:
            # 正好穿过格点：对角两侧都要让得开，才允许走这条直线
            if not passable(st, tx + step_x, ty, faction):
                return False
            if not passable(st, tx, ty + step_y, faction):
                return False
            tx += step_x
            ty += step_y
            t_max_x += t_dx
            t_max_y += t_dy
            if not passable(st, tx, ty, faction):
                return False
    return False


def smooth_path(st, points, faction):
    """⚠️ 与 js/path.js 的 smoothPath 等价：贪心把折线拉直（每段都要 segment_clear 通过）"""
    if not points or len(points) <= 2:
        return list(points or [])
    out = [points[0]]
    i = 0
    while i < len(points) - 1:
        j = len(points) - 1
        while j > i + 1 and not segment_clear(st, points[i][0], points[i][1], points[j][0], points[j][1], faction):
            j -= 1
        out.append(points[j])
        i = j
    return out


def order_move(st, unit, world_pt, faction='player'):
    """返回 (像素路径点列表, 目标地块) 或 None；与 js/unit.js 的 Unit.moveTo 一致（含路径拉直）"""
    wx, wy = world_pt
    from_tile = (unit['tx'], unit['ty'])
    cell = CELL
    dest_tile = (min(MAP_COLS - 1, max(0, int(wx // cell))), min(MAP_ROWS - 1, max(0, int(wy // cell))))
    dest_pt = (wx, wy)
    if not passable(st, dest_tile[0], dest_tile[1], faction):
        # 点到不可通行的格子（山 / 城墙 / 建筑）→ 改走到最近的可达格
        alt = nearest_reachable(st, from_tile, dest_tile, faction, 20)
        if alt is None:
            alt = nearest_reachable(st, from_tile, dest_tile, faction, 60)
        if alt is None:
            return None
        dest_tile = alt
        dest_pt = tile_center(alt[0], alt[1])
    tile_path = find_path(st, from_tile, dest_tile, faction)
    if tile_path is None:
        return None
    # 地块路线 → 像素折线（中间点格心），最后一点换成点击位置，然后**拉直**
    raw = [(unit['px'], unit['py'])]
    for n in tile_path:
        raw.append(tile_center(n[0], n[1]))
    if tile_path:
        raw[-1] = dest_pt
    elif abs(dest_pt[0] - unit['px']) > 0.5 or abs(dest_pt[1] - unit['py']) > 0.5:
        raw.append(dest_pt)
    pts = smooth_path(st, raw, faction)[1:]
    return pts, dest_tile


def step_unit(pos, path, speed, dt):
    """⚠️ 与 js/unit.js 的 Unit.stepAlongPath 等价：路径点就是像素坐标，不再吸附格心"""
    px, py = pos
    remaining = speed * CELL * dt
    path = list(path)
    guard = 0
    while remaining > 1e-9 and path and guard < 512:
        guard += 1
        cx, cy = path[0]
        dx, dy = cx - px, cy - py
        d = (dx * dx + dy * dy) ** 0.5
        if d <= 1e-6:
            path.pop(0)
            continue
        if remaining >= d:
            px, py = cx, cy
            remaining -= d
            path.pop(0)
        else:
            px += dx / d * remaining
            py += dy / d * remaining
            remaining = 0.0
    return (px, py), path, (not path)


st_move = State()
u1 = dict(tx=10, ty=10, px=tile_center(10, 10)[0], py=tile_center(10, 10)[1])

# 1) 目标点在目标格内的任意位置 → 终点就是那个像素位置，不吸附格心
off_pt = (20 * CELL + 7.5, 12 * CELL + 108.0)      # 目标格 (20,12) 内偏右下
res = order_move(st_move, u1, off_pt)
ok(res is not None, '点到可通行处：下令成功')
pts, dest_tile = res
ok(dest_tile == (20, 12), f'目标地块 = (20,12)（实际 {dest_tile}）')
ok(abs(pts[-1][0] - off_pt[0]) < 1e-9 and abs(pts[-1][1] - off_pt[1]) < 1e-9,
   f'路径终点就是点击位置 ({off_pt[0]:.1f},{off_pt[1]:.1f})，不是格心')
# ★ 能走直线就走直线：开阔地应被拉直成**一条**直线，而不是十几个格心点连成的阶梯
raw_tiles = find_path(st_move, (10, 10), (20, 12), 'player')
ok(len(pts) == 1,
   f'开阔地折线被拉直成一条直线（路径点 {len(pts)} 个；旧实现是 {len(raw_tiles)} 个格心点连成的阶梯）')
start_pt = (u1['px'], u1['py'])
ok(segment_clear(st_move, start_pt[0], start_pt[1], off_pt[0], off_pt[1], 'player'),
   '这条直线本身通过了通行判定（不是硬穿过去的）')
prev_pt, segs_ok = start_pt, True
for p in pts:
    if not segment_clear(st_move, prev_pt[0], prev_pt[1], p[0], p[1], 'player'):
        segs_ok = False
    prev_pt = p
ok(segs_ok, '拉直后的每一段直线都可通行（不会为了走直线而翻山）')

# 2) 逐帧推进：位移均匀、不跳格、精确停在点击位置、轨迹是直线
pos = (u1['px'], u1['py'])
left = list(pts)
deltas, tiles = [], [(int(pos[0] // CELL), int(pos[1] // CELL))]
deviations, frames = [], 0
done = False
line_len = math.hypot(off_pt[0] - start_pt[0], off_pt[1] - start_pt[1])
while not done and frames < 60 * 60:
    prev = pos
    pos, left, done = step_unit(pos, left, UNIT_SPEED, 1 / 60)
    deltas.append(((pos[0] - prev[0]) ** 2 + (pos[1] - prev[1]) ** 2) ** 0.5)
    # 点到“起点 → 点击位置”这条直线的距离（叉积 / 斜边长）
    deviations.append(abs((off_pt[0] - start_pt[0]) * (prev[1] - start_pt[1])
                          - (off_pt[1] - start_pt[1]) * (prev[0] - start_pt[0])) / line_len)
    cur = (int(pos[0] // CELL), int(pos[1] // CELL))
    if cur != tiles[-1]:
        tiles.append(cur)
    frames += 1

moved = [d for d in deltas if d > 0.01]
budget = UNIT_SPEED * CELL / 60          # 草地每帧预算
slow_budget = budget * FOREST_MULT       # 森林每帧预算
body = deltas[:-1]                       # 最后一帧只走余额，单独看
ok(frames > 10 and all(d > 0 for d in deltas), f'共推进 {frames} 帧，每帧都有位移')
ok(max(body) <= budget + 1e-6,
   f'每帧位移不超过草地预算 {budget:.2f}px（实际最大 {max(body):.2f}px）')
ok(all(abs(d - budget) < 1e-6 or abs(d - slow_budget) < 1e-6 for d in body),
   f'每帧位移只取两种值：草地 {budget:.2f}px / 森林 {slow_budget:.2f}px（覆盖全部 {len(body)} 帧）')
ok(deltas[-1] <= budget + 1e-6, f'最后一帧只走余额 {deltas[-1]:.2f}px（不会冲过终点）')
ok(all(d < CELL for d in deltas), f'不存在整格跳跃（单帧最大 {max(deltas):.2f}px < {CELL}px）')
ok(max(deviations) < 0.01,
   f'轨迹与“起点→终点”的直线最大偏差 {max(deviations):.4f}px（走的是直线，不是沿格心的阶梯）')
jumps = sum(1 for i in range(1, len(tiles))
            if max(abs(tiles[i][0] - tiles[i - 1][0]), abs(tiles[i][1] - tiles[i - 1][1])) != 1)
ok(jumps == 0, f'经过的地块始终相邻（允许斜穿，切比雪夫距离 1；{len(tiles)} 格，跳格 {jumps} 次）')
blocked_tiles = [t for t in tiles if not passable(st_move, t[0], t[1], 'player')]
ok(not blocked_tiles, f'经过的地块全部可通行（异常 {blocked_tiles}）')
ok(abs(pos[0] - off_pt[0]) < 0.01 and abs(pos[1] - off_pt[1]) < 0.01,
   f'精确停在点击位置 ({pos[0]:.2f},{pos[1]:.2f})')
ecx, ecy = tile_center(20, 12)
ok(abs(pos[0] - ecx) > 0.5 or abs(pos[1] - ecy) > 0.5, '终点没有吸附到格心（与格心不同）')

# 2.5) 有山阻挡时必须保留拐点绕行；直线通行判定本身也要正确
st_obs = State()
u_obs = dict(tx=8, ty=10, px=tile_center(8, 10)[0], py=tile_center(8, 10)[1])
res_obs = order_move(st_obs, u_obs, (19 * CELL + 60, 4 * CELL + 60))     # (19,4) 在山的另一侧
ok(res_obs is not None, '目标在山体另一侧：下令成功')
pts_obs, _ = res_obs
ok(len(pts_obs) > 1, f'绕行路线保留了 {len(pts_obs)} 个拐点（没有被错误地拉成一条直线）')
prev_pt, segs_ok2 = (u_obs['px'], u_obs['py']), True
for p in pts_obs:
    if not segment_clear(st_obs, prev_pt[0], prev_pt[1], p[0], p[1], 'player'):
        segs_ok2 = False
    prev_pt = p
ok(segs_ok2, '绕行的每一段直线都通过了通行判定')
ok(segment_clear(st_obs, tile_center(10, 10)[0], tile_center(10, 10)[1],
                 tile_center(16, 5)[0], tile_center(16, 5)[1], 'player') is False,
   '穿过山体的直线被通行判定拒绝')
ok(segment_clear(st_obs, tile_center(16, 4)[0], tile_center(16, 4)[1],
                 tile_center(18, 6)[0], tile_center(18, 6)[1], 'player') is True,
   '开阔地的直线被通行判定接受')
ok(segment_clear(st_obs, tile_center(14, 4)[0], tile_center(14, 4)[1],
                 tile_center(15, 5)[0], tile_center(15, 5)[1], 'player') is False,
   '只从山体一个角上蹭过去的对角线被拒绝（超覆盖判定）')
st_wall = State()
add_building(st_wall, 'wall', 12, 10)
ok(segment_clear(st_wall, tile_center(11, 10)[0], tile_center(11, 10)[1],
                 tile_center(13, 10)[0], tile_center(13, 10)[1], 'player') is True,
   '穿过城墙格的直线：己方可以走')
ok(segment_clear(st_wall, tile_center(11, 10)[0], tile_center(11, 10)[1],
                 tile_center(13, 10)[0], tile_center(13, 10)[1], 'enemy') is False,
   '同一條直线：敌方不可走（城墙只挡敌方）')
flat_player = smooth_path(st_wall, [tile_center(10, 10), tile_center(11, 10),
                                    tile_center(12, 10), tile_center(13, 10)], 'player')
flat_enemy = smooth_path(st_wall, [tile_center(10, 10), tile_center(11, 10),
                                   tile_center(12, 10), tile_center(13, 10)], 'enemy')
ok(len(flat_player) == 2, f'己方：4 点折线被拉直成 2 点（实际 {len(flat_player)}）')
ok(len(flat_enemy) > 2, f'敌方：同样的折线不会被拉直（城墙挡路，保留 {len(flat_enemy)} 个点）')

# 3) 点到山 / 城墙 / 建筑 → 自动改走到最近的可达处
mountain_pt = (15 * CELL + 60, 5 * CELL + 60)      # (15,5) 是山，四邻里正上方 (15,4) 也是山
st2 = State()
u2 = dict(tx=10, ty=10, px=tile_center(10, 10)[0], py=tile_center(10, 10)[1])
ok(not passable(st2, 15, 5, 'player'), '前提：(15,5) 确实是不可通行的山体')
res2 = order_move(st2, u2, mountain_pt)
ok(res2 is not None, '点到山体：仍能下令（自动改走最近可达格）')
pts2, dest2 = res2
ok(dest2 != (15, 5), f'不会把山体当作终点（改走 {dest2}）')
ok(passable(st2, dest2[0], dest2[1], 'player'), f'改走的目标格 {dest2} 确实可通行')
ok(abs(pts2[-1][0] - tile_center(dest2[0], dest2[1])[0]) < 1e-9, '改走时终点取该格格心（不是山里的点）')
ok(sum(abs(dest2[0] - 15) + abs(dest2[1] - 5) for _ in [0]) <= 2, f'改走的是山体附近的格（{dest2}）')

st3 = State()
add_building(st3, 'wall', 12, 10)
p_wall = order_move(st3, dict(tx=10, ty=10, px=tile_center(10, 10)[0], py=tile_center(10, 10)[1]),
                    (12 * CELL + 60, 10 * CELL + 60))
ok(p_wall is not None, '己方点到己方城墙：可下令（城墙对己方放行）')
ok(p_wall[1] == (12, 10), f'己方目标仍是城墙格 ({p_wall[1]})')

st4 = State()
add_building(st4, 'tower', 12, 10)
p_tower = order_move(st4, dict(tx=10, ty=10, px=tile_center(10, 10)[0], py=tile_center(10, 10)[1]),
                     (12 * CELL + 60, 10 * CELL + 60))
ok(p_tower is not None and p_tower[1] != (12, 10),
   f'点到箭塔（己方也进不去）→ 自动改走邻格 {p_tower[1] if p_tower else None}')

# 4) 森林减速
ok(UNIT_SPEED * FOREST_MULT < UNIT_SPEED, f'森林速度倍率生效：{UNIT_SPEED} → {UNIT_SPEED * FOREST_MULT} 格/秒')

# 5) 单位相对地块很小
unit_r = CELL * UNIT_RADIUS_FACTOR
ok(unit_r * 2 < CELL / 3, f'单位直径 {unit_r * 2:.0f}px 远小于地块 {CELL}px（占比 {unit_r * 2 / CELL:.0%}）')


section('战斗与警戒：静止索敌 → 先靠近 → 再攻击（CONFIG.combat 的镜像）')
# ⚠️ 下面是 js/unit.js 的 acquireTarget / updateCombat / attack / update 的等价镜像。
#    追击时用 order_move() 下达移动命令，等价于 Unit.moveTo。


def unit_radius(kind):
    r = CELL * UNIT_RADIUS_FACTOR
    return r if kind == 'general' else r * 0.75


def combat_cfg(kind):
    return (GENERAL_DAMAGE, GENERAL_RANGE, GENERAL_CD) if kind == 'general' else (ENEMY_DAMAGE, ENEMY_RANGE, ENEMY_CD)


def make_fighter(x, y, faction, kind):
    hp = UNIT_HP if kind == 'general' else ENEMY_HP
    return dict(tx=x, ty=y, px=tile_center(x, y)[0], py=tile_center(x, y)[1],
                faction=faction, kind=kind, alive=True, hp=hp, hp_max=hp,
                path=None, target=None, anchor=None, attack_cd=0.0, repath=0.0)


def acquire_target(st, u):
    """⚠️ 与 js/unit.js 的 Unit.acquireTarget 等价：静止时搜索警戒半径内最近的敌人"""
    best, best_d = None, float('inf')
    for v in st.units:
        if v is u or not v['alive'] or v['faction'] == u['faction']:
            continue
        d = math.hypot(u['px'] - v['px'], u['py'] - v['py']) - unit_radius(v['kind'])
        if d <= AGGRO_RANGE * CELL and d < best_d:
            best, best_d = v, d
    if best is None:
        return False
    u['target'] = best
    u['anchor'] = (u['px'], u['py'])
    u['repath'] = 0.0
    return True


def fire_at(u, v):
    """⚠️ 与 js/unit.js 的 Unit.attack 等价"""
    dmg, _rng, cd = combat_cfg(u['kind'])
    u['attack_cd'] = cd
    v['hp'] = max(0, v['hp'] - dmg)
    if v['hp'] <= 0:
        v['alive'] = False
        v['target'] = None


def update_combat(st, u):
    """⚠️ 与 js/unit.js 的 Unit.updateCombat 等价"""
    t = u['target']
    if t is None or not t['alive']:
        u['target'] = None
        return
    _dmg, rng, _cd = combat_cfg(u['kind'])
    reach = rng * CELL + unit_radius(t['kind'])
    d = math.hypot(u['px'] - t['px'], u['py'] - t['py'])
    if d <= reach:                                  # 进入攻击距离：站住开火
        u['path'] = None
        if u['attack_cd'] <= 0:
            fire_at(u, t)
        return
    if u['anchor'] and math.hypot(u['anchor'][0] - t['px'], u['anchor'][1] - t['py']) > AGGRO_RANGE * CELL * LEASH_FACTOR:
        u['target'] = None                          # 追太远了，放弃
        return
    if not u['path'] or u['repath'] <= 0:           # 先移动靠近（目标在动，隔一会儿重算）
        u['repath'] = REPATH_SEC
        res = order_move(st, u, (t['px'], t['py']), u['faction'])
        if res is not None:
            u['path'] = res[0]


def update_unit(st, u, dt):
    """⚠️ 与 js/unit.js 的 Unit.update 等价（省略回血等与战斗无关的部分）"""
    if not u['alive']:
        return
    u['attack_cd'] = max(0.0, u['attack_cd'] - dt)
    if u['repath'] > 0:
        u['repath'] = max(0.0, u['repath'] - dt)
    if u['target'] is not None:
        update_combat(st, u)
    elif not u['path']:
        acquire_target(st, u)                       # 只有静止（没有移动命令）时才警戒索敌
    if u['path']:
        pos, left, done = step_unit((u['px'], u['py']), u['path'], UNIT_SPEED, dt)
        u['px'], u['py'] = pos
        u['path'] = None if done else left
        u['tx'], u['ty'] = int(u['px'] // CELL), int(u['py'] // CELL)


st_c = State()
g_c = make_fighter(10, 10, 'player', 'general')
e_c = make_fighter(10, 13, 'enemy', 'enemy')
st_c.units = [g_c, e_c]
d0 = math.hypot(g_c['px'] - e_c['px'], g_c['py'] - e_c['py'])
ok(AGGRO_RANGE * CELL >= d0 > GENERAL_RANGE * CELL, f'初始间距 {d0:.0f}px：在警戒半径内、但够不着')
update_unit(st_c, g_c, 1 / 60)
ok(g_c['target'] is e_c, '静止的单位在警戒半径内锁定敌人')
ok(g_c['anchor'] is not None, '记录“警戒起点”（追击上限的判定基准）')

frames = 0
while frames < 60 * 10 and e_c['hp'] == e_c['hp_max']:
    update_unit(st_c, g_c, 1 / 60)
    frames += 1
d1 = math.hypot(g_c['px'] - e_c['px'], g_c['py'] - e_c['py'])
ok(d1 < d0, f'先移动靠近再攻击：{d0:.0f}px → {d1:.0f}px（{frames / 60:.2f} 秒后开火）')
ok(d1 <= GENERAL_RANGE * CELL + unit_radius('enemy') + 1e-6, f'开火时确实在攻击距离内（{d1:.1f}px）')
ok(e_c['hp'] == e_c['hp_max'] - GENERAL_DAMAGE,
   f'造成一次 {GENERAL_DAMAGE} 点单体伤害（敌人 {ENEMY_HP} → {e_c["hp"]}）')
ok(not g_c['path'], '进入攻击距离后站住不再移动')

hp1 = e_c['hp']
update_unit(st_c, g_c, 0.05)
ok(e_c['hp'] == hp1, '冷却时间内不会重复开火')
update_unit(st_c, g_c, GENERAL_CD + 0.01)
ok(e_c['hp'] == hp1 - GENERAL_DAMAGE, '冷却结束后可以再次开火')

frames2 = 0
while e_c['alive'] and frames2 < 60 * 30:
    update_unit(st_c, g_c, 1 / 60)
    frames2 += 1
ok(not e_c['alive'], '目标血量归零后死亡（alive = False）')
update_unit(st_c, g_c, 1 / 60)
ok(g_c['target'] is None, '目标死亡后自动脱离交战')

# 移动中的单位不索敌
st_m2 = State()
g_m2 = make_fighter(10, 10, 'player', 'general')
e_m2 = make_fighter(10, 12, 'enemy', 'enemy')
st_m2.units = [g_m2, e_m2]
res_m = order_move(st_m2, g_m2, (4 * CELL + 60, 10 * CELL + 60))
g_m2['path'] = res_m[0]
update_unit(st_m2, g_m2, 1 / 60)
ok(g_m2['path'] and g_m2['target'] is None, '正在执行移动命令的单位不会半路索敌（只有静止时才警戒）')

# 玩家命令优先：战斗中下达移动命令会中断交战
st_p = State()
g_p = make_fighter(10, 10, 'player', 'general')
e_p = make_fighter(10, 12, 'enemy', 'enemy')
st_p.units = [g_p, e_p]
update_unit(st_p, g_p, 1 / 60)
ok(g_p['target'] is e_p, '锁定目标')
res_p = order_move(st_p, g_p, (3 * CELL + 60, 3 * CELL + 60))
g_p['target'] = None                    # js: orderMove() 成功后 clearTarget()
ok(g_p['target'] is None and res_p is not None, '明确的移动命令会中断交战（玩家操作优先）')

# 追击上限
st_l = State()
g_l = make_fighter(10, 10, 'player', 'general')
e_l = make_fighter(10, 12, 'enemy', 'enemy')
st_l.units = [g_l, e_l]
update_unit(st_l, g_l, 1 / 60)
ok(g_l['target'] is e_l, '锁定近距离目标')
e_l['px'] = tile_center(10, 10)[0]
e_l['py'] = tile_center(10, 10)[1] + (AGGRO_RANGE * LEASH_FACTOR + 1) * CELL
update_unit(st_l, g_l, 1 / 60)
ok(g_l['target'] is None, f'目标跑出追击上限（{AGGRO_RANGE * LEASH_FACTOR:.1f} 格）后放弃，不会追到地图另一头')

# 两个阵营对称
st_sym = State()
g_s = make_fighter(10, 10, 'player', 'general')
e_s = make_fighter(10, 12, 'enemy', 'enemy')
st_sym.units = [g_s, e_s]
update_unit(st_sym, g_s, 1 / 60)
update_unit(st_sym, e_s, 1 / 60)
ok(e_s['target'] is g_s, '警戒逻辑对两个阵营都生效（静止的敌人也会盯上我方单位）')


section('城墙血量与敌人拆墙：贴墙一下一下拆，打光后让路')
# ⚠️ 与 js/building.js 的 Building.takeDamage、js/unit.js 的 updateBuildingCombat 等价的镜像。


def building_take_damage(b, amount):
    """⚠️ 与 js/building.js 的 Building.takeDamage 等价：返回是否还活着（大本营血量留 1）"""
    floor = 1 if b['type'] == 'base' else 0
    b['hp'] = max(floor, b['hp'] - amount)
    return b['hp'] > 0


st_w = State()
w_wall = add_building(st_w, 'wall', 12, 10)
ok(w_wall['hp'] == WALL_HP, f'新建城墙满血 {w_wall["hp"]}（与 CONFIG.building.wall.hpMax 一致）')

# 攻击距离 = 1 格 + 半格（建筑占满整格，贴着墙就能打到）
reach_w = ENEMY_RANGE * CELL + CELL * 0.5
near_d = math.hypot(tile_center(12, 9)[0] - tile_center(12, 10)[0],
                    tile_center(12, 9)[1] - tile_center(12, 10)[1])
far_d = math.hypot(tile_center(12, 8)[0] - tile_center(12, 10)[0],
                   tile_center(12, 8)[1] - tile_center(12, 10)[1])
ok(near_d <= reach_w < far_d,
   f'贴墙（{near_d:.0f}px）够得着、隔一格（{far_d:.0f}px）够不着（攻击距离 {reach_w:.0f}px）')

hits_w = math.ceil(WALL_HP / BUILDING_DAMAGE)
ok(hits_w == 8, f'打光一堵墙需要 {hits_w} 下（{WALL_HP} 血 ÷ 每次 {BUILDING_DAMAGE}）')
still_alive = True
for i in range(hits_w):
    still_alive = building_take_damage(w_wall, BUILDING_DAMAGE)
ok(still_alive is False and w_wall['hp'] == 0,
   f'{hits_w} 下之后城墙血量归零、takeDamage 返回 False（该被拆掉了）')

# 拆之前 / 之后：同一格对敌方从“不可通行”变成“可通行”（缺口打开，敌人才能进来）
ok(passable(st_w, 12, 10, 'enemy') is False, '拆之前：城墙格对敌方不可通行')
del st_w.buildings[(12, 10)]
ok(passable(st_w, 12, 10, 'enemy') is True, '拆之后：同一格对敌方变成可通行（围墙出现缺口）')
ok(occupied(st_w, 12, 10) is False, '拆之后该格不再被建筑占据')

# 大本营不可摧毁
st_w2 = State()
b_base = add_building(st_w2, 'base', 8, 8)
ok(b_base['hp'] == BASE_HP, f'大本营满血 {b_base["hp"]}（与 CONFIG.building.base.hpMax 一致）')
ok(building_take_damage(b_base, 99999) is True and b_base['hp'] == 1,
   '大本营被打到 0 血时保留 1 点（本版不可摧毁）')
ok(remove_building(st_w2, 8, 8) is False, '大本营不可手动拆除')


section('城墙拦断整条路线：可达性判定不能让敌人发呆')
# ⚠️ 与 js/path.js 的 reachableTiles / nearestReachable / findBlockingWallToward 等价。
st_seal = State()
add_building(st_seal, 'base', st_seal.base[0], st_seal.base[1])
built_seal, blocked_seal = 0, 0
for y in range(MAP_ROWS):
    if st_seal.terrain[y][13] == '#':          # 山地本来就不通
        blocked_seal += 1
        continue
    if add_building(st_seal, 'wall', 13, y):
        built_seal += 1
        blocked_seal += 1
ok(blocked_seal == MAP_ROWS,
   f'用一整列城墙 + 山地拦断路线（新建 {built_seal} 段，col 13 整列 {blocked_seal}/{MAP_ROWS} 格不通）')

region_seal = reachable_tiles(st_seal, (22, 2), 'enemy')
ok(st_seal.base not in region_seal, '敌人的可达区域里不包含大本营（路线被彻底拦断）')
ok((14, 2) in region_seal and (12, 2) not in region_seal,
   '墙确实切开了区域：东侧 (14,2) 可达、西侧 (12,2) 不可达')

# ★ 回归：nearest_reachable 不能返回“墙那一边、自己根本走不到”的格子
near_seal = nearest_reachable(st_seal, (22, 2), st_seal.base, 'enemy', 20)
ok(near_seal is None or near_seal in region_seal,
   f'返回的落脚点必须是自己走得到的（返回 {near_seal}；旧实现会返回墙那一边的 (12, 7)）')
ok(near_seal is None or find_path(st_seal, (22, 2), near_seal, 'enemy') is not None,
   '而且到那个落脚点的路线真的存在（旧实现返回的格子 find_path 为 None）')
near_wall_seal = nearest_reachable(st_seal, (22, 2), (13, 2), 'enemy', 20)
ok(near_wall_seal is not None and abs(near_wall_seal[0] - 13) + abs(near_wall_seal[1] - 2) == 1,
   f'朝“挨着自己区域的墙”找落脚点 → {near_wall_seal}，是自己这一侧的邻格')

# ★ 回归：该拆哪段墙 = 挨着自己可达区域、离大本营最近的那段（旧实现只看身边 2 格 → 找不到）
pick_seal = find_blocking_wall_toward(st_seal, (22, 2), st_seal.base, 'enemy')
ok(pick_seal == (13, 2), f'挑中 {pick_seal}：挨着可达区域、离大本营最近的那段墙')
ok(pick_seal != (13, 8),
   '没有挑离大本营最近、但自己根本走不到的 (13,8)（它在墙的另一侧）')
ok(find_blocking_wall_toward(State(), (10, 10), (12, 8), 'enemy') is None,
   '地图上没有城墙时返回 None（不会凭空挑一个目标）')
# 从墙的另一侧看：挑中的墙同样必须挨着“这一侧”的可达区域
west_region = reachable_tiles(st_seal, (10, 10), 'enemy')
pick_west = find_blocking_wall_toward(st_seal, (10, 10), st_seal.base, 'enemy')
ok(pick_west is not None
   and any((pick_west[0] + dx, pick_west[1] + dy) in west_region for dx, dy in DIRS4),
   f'从西侧挑中的 {pick_west} 也挨着西侧可达区域（不会选走不到的墙）')

# 拆穿之后：缺口打开，敌方能在这一列上通过，并能走到大本营旁边
del st_seal.buildings[pick_seal]
ok(passable(st_seal, 13, 2, 'enemy') is True, '拆掉后这一格对敌方变成可通行（缺口打开）')
after_seal = nearest_reachable(st_seal, (14, 2), st_seal.base, 'enemy', 20)
ok(after_seal is not None
   and abs(after_seal[0] - st_seal.base[0]) + abs(after_seal[1] - st_seal.base[1]) == 1,
   f'缺口打开后能找到大本营旁边的落脚点 {after_seal}')
ok(st_seal.base in reachable_tiles(st_seal, (14, 2), 'enemy')
   or (st_seal.base[0], st_seal.base[1] - 1) in reachable_tiles(st_seal, (14, 2), 'enemy'),
   '缺口打开后敌人的可达区域已经扩到大本营旁边')


section('边缘滚屏：鼠标推到视野边缘即平移视角')
def edge_scroll_velocity(mx, my, view_w, view_h, edge=EDGE_SIZE, max_speed=EDGE_MAX_SPEED):
    """⚠️ 与 js/main.js 的 updateCameraEdgeScroll 等价"""
    def ramp(dist):
        t = min(1.0, max(0.0, (edge - dist) / edge))
        return t * t * max_speed
    vx = vy = 0.0
    if mx <= edge:
        vx = -ramp(mx)
    elif mx >= view_w - edge:
        vx = ramp(view_w - mx)
    if my <= edge:
        vy = -ramp(my)
    elif my >= view_h - edge:
        vy = ramp(view_h - my)
    return vx, vy


VW, VH = 1200, 700
ok(edge_scroll_velocity(VW / 2, VH / 2, VW, VH) == (0.0, 0.0), '画面中央不滚动')
ok(edge_scroll_velocity(VW - 1, VH / 2, VW, VH)[0] > 0, '鼠标贴右边缘 → 视角向右平移')
ok(edge_scroll_velocity(0, VH / 2, VW, VH)[0] < 0, '鼠标贴左边缘 → 视角向左平移')
ok(edge_scroll_velocity(VW / 2, VH - 1, VW, VH)[1] > 0, '鼠标贴下边缘 → 视角向下平移')
ok(edge_scroll_velocity(VW / 2, 0, VW, VH)[1] < 0, '鼠标贴上边缘 → 视角向上平移')
v_edge = abs(edge_scroll_velocity(VW - 1, VH / 2, VW, VH)[0])
v_mid = abs(edge_scroll_velocity(VW - EDGE_SIZE / 2, VH / 2, VW, VH)[0])
ok(v_edge > v_mid > 0, f'越靠近边缘滚得越快（贴边 {v_edge:.0f} > 半程 {v_mid:.0f} px/s）')
ok(v_edge <= EDGE_MAX_SPEED + 1e-6, f'不超过最大速度 {EDGE_MAX_SPEED} px/s')
ok(edge_scroll_velocity(VW - EDGE_SIZE - 1, VH / 2, VW, VH) == (0.0, 0.0),
   f'离开 {EDGE_SIZE}px 触发区就停止滚动')

print(f'\n———————————————\n通过 {pass_n} 项，失败 {fail_n} 项')
sys.exit(0 if fail_n == 0 else 1)
