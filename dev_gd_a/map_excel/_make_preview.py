# -*- coding: utf-8 -*-
"""生成「登神长阶」地图预览 HTML（自包含，不依赖外部资源）。"""
from __future__ import annotations

import json
import os
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.abspath(os.path.join(HERE, "..", "daeem"))
MAP_PATH = os.path.join(PROJECT, "data", "maps", "dengshen_changjie", "map.json")
LEVEL_PATH = os.path.join(PROJECT, "data", "campaigns", "demo", "levels", "dengshen_changjie.json")
OUT_PATH = os.path.join(HERE, "dengshen_changjie_map.html")

with open(MAP_PATH, encoding="utf-8") as f:
    MAP = json.load(f)
with open(LEVEL_PATH, encoding="utf-8") as f:
    LEVEL = json.load(f)

# 只嵌入渲染需要的字段，避免 HTML 过大。
map_doc = {
    "cols": MAP["cols"],
    "rows": MAP["rows"],
    "layout": MAP["layout"],
    "exists": MAP["exists"],
    "zones": MAP["zones"],
    "zone_list": [
        {k: z[k] for k in ("id", "name", "kind", "center", "production", "x0", "y0", "x1", "y1", "tile_count")}
        for z in MAP["zone_list"]
    ],
    "buildings": MAP.get("buildings", []),
}
level_doc = {
    "name": LEVEL["name"],
    "mode": LEVEL["mode"],
    "zones": LEVEL["zones"],
    "factions": LEVEL["factions"],
    "allies": LEVEL.get("allies", []),
    "objectives": LEVEL.get("objectives", []),
    "fail_conditions": LEVEL.get("fail_conditions", []),
    "start_units": LEVEL.get("start_units", []),
    "briefing": LEVEL.get("briefing", []),
}

terrain_counts = Counter()
for row in MAP["layout"]:
    for ch in row:
        terrain_counts[{".": "草地", "^": "森林", "#": "山地", "~": "水域"}.get(ch, ch)] += 1
building_counts = Counter(b["type"] for b in MAP.get("buildings", []))
owner_counts = Counter(z["owner"] for z in LEVEL["zones"])
enemy_generals = [u for u in LEVEL["start_units"] if u["faction"] == "enemy"]
enemy_escorts = sum(int(u.get("escort_count", 0)) for u in enemy_generals)
max_slots = max(int(z.get("build_point_count", 0)) for z in LEVEL["zones"])

html = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>登神长阶 · 地图预览</title>
<style>
  :root {
    --bg: #0d1117;
    --panel: #151b23;
    --panel-2: #1b232d;
    --line: #2a3542;
    --text: #e6edf3;
    --dim: #8b98a5;
    --gold: #ffd166;
    --blue: #5ac8ff;
    --red: #e05a5a;
    --green: #8ce08c;
    --pink: #ff8adf;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; height: 100%; }
  body {
    background:
      radial-gradient(1200px 700px at 20% -10%, rgba(90,200,255,.08), transparent 60%),
      radial-gradient(900px 600px at 110% 20%, rgba(255,209,102,.06), transparent 55%),
      var(--bg);
    color: var(--text);
    font: 14px/1.5 "Microsoft YaHei", "Noto Sans SC", system-ui, sans-serif;
  }
  .app { display: flex; height: 100%; min-height: 0; }
  .panel {
    width: 360px; flex: 0 0 360px; padding: 18px 16px 22px;
    background: linear-gradient(180deg, rgba(21,27,35,.96), rgba(15,20,27,.96));
    border-right: 1px solid var(--line); overflow: auto;
  }
  h1 { margin: 0 0 4px; font-size: 22px; letter-spacing: .06em; }
  .sub { color: var(--dim); margin-bottom: 14px; display: flex; align-items: center; justify-content: space-between; gap: 10px; }
  .sub button { border: 1px solid var(--line); background: var(--panel-2); color: var(--gold);
    border-radius: 7px; padding: 3px 9px; font-size: 12px; cursor: pointer; }
  .sub button:hover { border-color: rgba(255,209,102,.6); }
  body.map-only .panel { display: none; }
  body.map-only .stage { padding: 8px; }
  body.map-only canvas { max-height: calc(100vh - 24px); }
  body.map-only .hint { left: 10px; }
  .badges { display: flex; flex-wrap: wrap; gap: 6px; margin: 12px 0 16px; }
  .badge { border: 1px solid var(--line); background: var(--panel-2); color: var(--text);
    border-radius: 999px; padding: 3px 9px; font-size: 12px; }
  .badge b { color: var(--gold); font-weight: 600; }
  .card { background: var(--panel); border: 1px solid var(--line); border-radius: 10px;
    padding: 12px 12px 10px; margin-bottom: 12px; }
  .card h2 { font-size: 13px; letter-spacing: .12em; color: var(--dim); margin: 0 0 10px;
    text-transform: uppercase; font-weight: 600; }
  .kv { display: grid; grid-template-columns: 1fr auto; gap: 5px 12px; }
  .kv span:nth-child(odd) { color: var(--dim); }
  .kv span:nth-child(even) { text-align: right; font-variant-numeric: tabular-nums; }
  .legend { display: grid; grid-template-columns: 1fr 1fr; gap: 7px 10px; }
  .lg { display: flex; align-items: center; gap: 7px; color: var(--dim); font-size: 12px; }
  .sw { width: 16px; height: 16px; border-radius: 4px; border: 1px solid rgba(255,255,255,.18); flex: 0 0 auto; }
  .zone-list { display: flex; flex-direction: column; gap: 3px; max-height: 270px; overflow: auto; padding-right: 2px; }
  .zrow { display: flex; align-items: center; gap: 8px; padding: 5px 7px; border-radius: 7px;
    cursor: pointer; border: 1px solid transparent; }
  .zrow:hover { background: var(--panel-2); border-color: var(--line); }
  .zrow.active { background: rgba(255,209,102,.10); border-color: rgba(255,209,102,.45); }
  .zdot { width: 10px; height: 10px; border-radius: 50%; flex: 0 0 auto; }
  .zname { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .zmeta { color: var(--dim); font-size: 11px; text-align: right; white-space: nowrap; }
  .stage { flex: 1; min-width: 0; display: flex; align-items: center; justify-content: center;
    padding: 18px; position: relative; overflow: auto; }
  .map-wrap { position: relative; background: #0b0f14; border: 1px solid var(--line);
    border-radius: 12px; padding: 8px; box-shadow: 0 18px 60px rgba(0,0,0,.45); }
  canvas { display: block; image-rendering: pixelated; max-height: calc(100vh - 54px); width: auto; height: auto; }
  .hint { position: fixed; left: 380px; bottom: 10px; color: var(--dim); font-size: 12px;
    background: rgba(13,17,23,.75); padding: 4px 8px; border-radius: 6px; }
  .tip { position: fixed; z-index: 20; pointer-events: none; display: none;
    background: rgba(13,17,23,.96); border: 1px solid var(--line); border-radius: 8px;
    padding: 8px 10px; font-size: 12px; min-width: 170px; box-shadow: 0 10px 30px rgba(0,0,0,.5); }
  .tip b { color: var(--gold); }
  .tip .row { display: flex; justify-content: space-between; gap: 14px; }
  .tip .row span:first-child { color: var(--dim); }
  .tip .row span:last-child { text-align: right; }
  .controls { display: flex; flex-wrap: wrap; gap: 8px 12px; color: var(--dim); font-size: 12px; }
  .controls label { display: flex; align-items: center; gap: 5px; cursor: pointer; }
  input[type=checkbox] { accent-color: var(--gold); }
  .foot { color: #5f6b78; font-size: 11px; line-height: 1.6; margin-top: 10px; }
  @media (max-width: 980px) {
    .app { flex-direction: column; }
    .panel { width: auto; flex: 0 0 auto; max-height: 38vh; border-right: 0; border-bottom: 1px solid var(--line); }
    .stage { flex: 1; min-height: 0; padding: 8px; overflow: hidden; }
    canvas { max-height: calc(62vh - 20px); }
    .hint { left: 10px; }
  }
</style>
</head>
<body>
<div class="app">
  <aside class="panel">
    <h1>登神长阶</h1>
    <div class="sub"><span>合作任务 · 33 × 51 · 16 个区划</span><button id="btnFocus">全屏地图</button></div>
    <div class="badges">
      <div class="badge">区划 <b>16</b></div>
      <div class="badge">建筑 <b>__BUILDING_COUNT__</b></div>
      <div class="badge">守将 <b>__ENEMY_GENERALS__</b></div>
      <div class="badge">附属兵 <b>__ENEMY_ESCORTS__</b></div>
      <div class="badge" id="redBadge" style="display:none">红点 <b id="redCount">0</b></div>
    </div>
    <div class="card">
      <h2>地图概览</h2>
      <div class="kv">
        <span>地图尺寸</span><span>33 × 51</span>
        <span>区划数量</span><span>16</span>
        <span>玩家席位</span><span>p1 / p2</span>
        <span>目标</span><span>占领 zone 1「人0」</span>
        <span>守军区划</span><span>__OWNER_DF__ 个归 df</span>
      </div>
    </div>
    <div class="card" id="redCard" style="display:none">
      <h2>红点波次</h2>
      <div class="kv" id="redInfo"></div>
    </div>
    <div class="card">
      <h2>地形</h2>
      <div class="kv">
        __TERRAIN_ROWS__
      </div>
    </div>
    <div class="card">
      <h2>图例</h2>
      <div class="legend">
        <div class="lg"><span class="sw" style="background:#40573a"></span>草地</div>
        <div class="lg"><span class="sw" style="background:#264b2b"></span>森林</div>
        <div class="lg"><span class="sw" style="background:#5e594f"></span>山地</div>
        <div class="lg"><span class="sw" style="background:#2c6288"></span>水域</div>
        <div class="lg"><span class="sw" style="background:#ff8adf"></span>区划中心</div>
        <div class="lg"><span class="sw" style="background:#e05a5a"></span>enemy 守军</div>
        <div class="lg"><span class="sw" style="background:#c9a0ff"></span>红点生成 / 目标</div>
        <div class="lg"><span class="sw" style="background:#ff9a5c"></span>区划边缘区</div>
        <div class="lg"><span class="sw" style="background:#ffd166"></span>p1 / 木墙</div>
        <div class="lg"><span class="sw" style="background:#5ac8ff"></span>p2 / 石墙</div>
      </div>
    </div>
    <div class="card">
      <h2>区划列表</h2>
      <div class="zone-list" id="zoneList"></div>
    </div>
    <div class="card">
      <h2>显示</h2>
      <div class="controls">
        <label><input type="checkbox" id="cbZone" checked>区划色</label>
        <label><input type="checkbox" id="cbOwner">归属色</label>
        <label><input type="checkbox" id="cbBuild" checked>建筑</label>
        <label><input type="checkbox" id="cbUnits" checked>守军</label>
        <label><input type="checkbox" id="cbNoGo">边缘区</label>
        <label><input type="checkbox" id="cbGrid">网格</label>
      </div>
    </div>
    <div class="foot">
      数据来自 <code>data/maps/dengshen_changjie/map.json</code> 与
      <code>data/campaigns/demo/levels/dengshen_changjie.json</code>。
      红底格 = 区划中心；数字 1/2/5/6/7 = 警戒塔 / 哨塔 / 粮田 / 房屋 / 矿脉。
      紫色菱形 = 红点生成点；紫色虚线框 = 红点行军目标。
      水域 / 山地 / 森林不属于任何区划；黑色细线是表格里的区划框。
    </div>
  </aside>
  <main class="stage">
    <div class="map-wrap"><canvas id="map"></canvas></div>
  </main>
</div>
<div class="hint">悬停查看格子信息 · 点击左侧区划高亮</div>
<div class="tip" id="tip"></div>
<script>
const MAP = __MAP_JSON__;
const LEVEL = __LEVEL_JSON__;

const TERRAIN = {
  '.': { name: '草地', color: '#40573a' },
  '^': { name: '森林', color: '#264b2b' },
  '#': { name: '山地', color: '#5e594f' },
  '~': { name: '水域', color: '#2c6288' },
};
const BUILDING = {
  base:        { name: '大本营', icon: '本', color: '#ffd166' },
  watch_tower: { name: '警戒塔', icon: '警', color: '#ff8a4a' },
  tower:       { name: '哨塔', icon: '塔', color: '#c9a0ff' },
  farm:        { name: '粮田', icon: '田', color: '#7ce07c' },
  house:       { name: '房屋', icon: '屋', color: '#9ea6b0' },
  mine:        { name: '矿脉', icon: '矿', color: '#8ce08c' },
  wall:        { name: '木墙', icon: '', color: '#ff8800' },
  stone_wall:  { name: '石墙', icon: '', color: '#8f959e' },
};
const OWNER = {
  p1: { name: 'p1', color: '#5ac8ff' },
  p2: { name: 'p2', color: '#ffd166' },
  df: { name: 'df', color: '#8ce08c' },
};
const ZONE_HUES = [190, 40, 120, 280, 330, 20, 160, 240, 60, 300, 90, 210, 0, 140, 260, 180];
const ZONES = {};
for (const z of MAP.zone_list) ZONES[z.id] = z;
const LEVEL_ZONES = {};
for (const z of LEVEL.zones) LEVEL_ZONES[z.id] = z;
const OWNER_OF = {};
for (const z of LEVEL.zones) OWNER_OF[z.id] = z.owner || '';

const CELL = 24;
const W = MAP.cols, H = MAP.rows;
const canvas = document.getElementById('map');
const ctx = canvas.getContext('2d');
canvas.width = W * CELL;
canvas.height = H * CELL;

const buildingAt = {};
for (const b of MAP.buildings || []) buildingAt[`${b.x},${b.y}`] = b;

const unitMarkers = [];
for (const u of LEVEL.start_units || []) {
  if (u.faction === 'enemy') unitMarkers.push({x: u.x, y: u.y, n: u.escort_count || 0, u});
  else if (u.faction === 'p1' || u.faction === 'p2') unitMarkers.push({x: u.x, y: u.y, n: 0, u, player: true});
}

const REDDOT_FACTION = (LEVEL.factions || []).find(f => f.ai === 'reddot') || null;
const REDDOT = REDDOT_FACTION ? (REDDOT_FACTION.reddot_ai || {}) : null;
const redSpawns = REDDOT ? (REDDOT.spawn_tiles || []).map(t => ({x: Number(t[0]), y: Number(t[1])})) : [];
const redMarch = REDDOT ? (REDDOT.march_tiles || []).map(t => ({x: Number(t[0]), y: Number(t[1])})) : [];
const redSpawnSet = new Set(redSpawns.map(p => `${p.x},${p.y}`));
const redMarchSet = new Set(redMarch.map(p => `${p.x},${p.y}`));
if (REDDOT) {
  document.getElementById('redBadge').style.display = '';
  document.getElementById('redCount').textContent = '1';
  const card = document.getElementById('redCard');
  card.style.display = '';
  document.getElementById('redInfo').innerHTML = [
    ['阵营', `${REDDOT_FACTION.name || REDDOT_FACTION.id}`],
    ['首波', `${REDDOT.wave_time_expr || 'x'} 分钟`],
    ['每波将领', `${REDDOT.general_count_expr || 'x'}`],
    ['附属兵', `${REDDOT.escort_count ?? 0} / 将`],
    ['生成点', `${redSpawns.length} 格`],
    ['行军目标', `${redMarch.length} 格`],
    ['波数', `${REDDOT.waves ? REDDOT.waves + ' 波' : '无限'}`],
  ].map(([k, v]) => `<span>${k}</span><span>${v}</span>`).join('');
}

let showZone = true, showOwner = false, showBuild = true, showUnits = true, showGrid = false, showNoGo = false;
let activeZone = -1;
let hover = null;

const NO_GO = new Set();
for (const z of LEVEL.zones || []) {
  for (const p of z.no_go || []) NO_GO.add(`${Number(p[0])},${Number(p[1])}`);
}

function zoneColor(id) {
  const h = ZONE_HUES[id % ZONE_HUES.length];
  return `hsl(${h} 70% 62%)`;
}
function ownerColor(id) {
  const o = OWNER_OF[id] || '';
  return (OWNER[o] || { color: '#9ea6b0' }).color;
}
function centerName(z) {
  return `${z.name}`;
}
function draw() {
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  // 地形
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const ch = MAP.layout[y][x];
      ctx.fillStyle = (TERRAIN[ch] || TERRAIN['.']).color;
      ctx.fillRect(x * CELL, y * CELL, CELL, CELL);
    }
  }
  // 归属/区划色
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const zid = MAP.zones[y][x];
      if (zid < 0) continue;
      if (showOwner) {
        ctx.globalAlpha = 0.12;
        ctx.fillStyle = ownerColor(zid);
        ctx.fillRect(x * CELL, y * CELL, CELL, CELL);
      }
      if (showZone && activeZone >= 0 && zid === activeZone) {
        ctx.globalAlpha = 0.16;
        ctx.fillStyle = zoneColor(zid);
        ctx.fillRect(x * CELL, y * CELL, CELL, CELL);
      }
    }
  }
  ctx.globalAlpha = 1;

  // 区划边缘区（no_go）
  if (showNoGo) {
    for (let y = 0; y < H; y++) {
      for (let x = 0; x < W; x++) {
        if (!NO_GO.has(`${x},${y}`)) continue;
        ctx.fillStyle = 'rgba(255,154,92,.28)';
        ctx.fillRect(x * CELL, y * CELL, CELL, CELL);
        ctx.strokeStyle = 'rgba(255,154,92,.55)';
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(x * CELL + 2, y * CELL + CELL - 3);
        ctx.lineTo(x * CELL + CELL - 3, y * CELL + 2);
        ctx.stroke();
      }
    }
  }

  // 区划边界
  ctx.lineWidth = 1.6;
  ctx.strokeStyle = 'rgba(236,244,255,.55)';
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const z = MAP.zones[y][x];
      if (x + 1 < W && MAP.zones[y][x + 1] !== z) {
        ctx.beginPath(); ctx.moveTo((x + 1) * CELL, y * CELL); ctx.lineTo((x + 1) * CELL, (y + 1) * CELL); ctx.stroke();
      }
      if (y + 1 < H && MAP.zones[y + 1][x] !== z) {
        ctx.beginPath(); ctx.moveTo(x * CELL, (y + 1) * CELL); ctx.lineTo((x + 1) * CELL, (y + 1) * CELL); ctx.stroke();
      }
    }
  }

  // 网格
  if (showGrid) {
    ctx.strokeStyle = 'rgba(255,255,255,.10)';
    ctx.lineWidth = 1;
    for (let x = 0; x <= W; x++) { ctx.beginPath(); ctx.moveTo(x * CELL, 0); ctx.lineTo(x * CELL, H * CELL); ctx.stroke(); }
    for (let y = 0; y <= H; y++) { ctx.beginPath(); ctx.moveTo(0, y * CELL); ctx.lineTo(W * CELL, y * CELL); ctx.stroke(); }
  }

  // 建筑
  if (showBuild) {
    for (const b of MAP.buildings || []) {
      const def = BUILDING[b.type] || { name: b.type, icon: '?', color: '#fff' };
      const px = b.x * CELL, py = b.y * CELL;
      if (b.type === 'wall' || b.type === 'stone_wall') {
        ctx.fillStyle = def.color;
        ctx.globalAlpha = 0.9;
        ctx.fillRect(px + 1, py + 1, CELL - 2, CELL - 2);
        ctx.globalAlpha = 1;
        ctx.strokeStyle = 'rgba(0,0,0,.35)';
        ctx.lineWidth = 1;
        ctx.strokeRect(px + 1.5, py + 1.5, CELL - 3, CELL - 3);
      } else {
        ctx.fillStyle = 'rgba(8,12,17,.72)';
        ctx.beginPath(); ctx.roundRect(px + 3, py + 3, CELL - 6, CELL - 6, 5); ctx.fill();
        ctx.strokeStyle = def.color;
        ctx.lineWidth = 1.3;
        ctx.stroke();
        ctx.fillStyle = def.color;
        ctx.font = 'bold 13px "Microsoft YaHei", sans-serif';
        ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
        ctx.fillText(def.icon, px + CELL / 2, py + CELL / 2 + 0.5);
      }
    }
  }

  // 守军 / 玩家单位
  if (showUnits) {
    for (const m of unitMarkers) {
      const px = m.x * CELL, py = m.y * CELL;
      const col = m.player ? OWNER[m.u.faction].color : '#e05a5a';
      ctx.beginPath();
      ctx.arc(px + CELL / 2, py + CELL / 2, CELL * 0.33, 0, Math.PI * 2);
      ctx.fillStyle = col;
      ctx.globalAlpha = 0.92; ctx.fill(); ctx.globalAlpha = 1;
      ctx.strokeStyle = 'rgba(0,0,0,.55)'; ctx.lineWidth = 1.2; ctx.stroke();
      ctx.fillStyle = m.player ? '#0b1118' : '#fff';
      ctx.font = 'bold 10px "Microsoft YaHei", sans-serif';
      ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.fillText(m.player ? m.u.faction : String(m.n), px + CELL / 2, py + CELL / 2 + 0.5);
    }
  }

  // 红点：生成点（实心菱形）与行军目标（虚线方框）
  if (REDDOT) {
    for (const p of redMarch) {
      const px = p.x * CELL, py = p.y * CELL;
      ctx.strokeStyle = '#c9a0ff';
      ctx.lineWidth = 1.4;
      ctx.setLineDash([4, 3]);
      ctx.strokeRect(px + 3, py + 3, CELL - 6, CELL - 6);
      ctx.setLineDash([]);
    }
    for (const p of redSpawns) {
      const px = p.x * CELL, py = p.y * CELL;
      ctx.fillStyle = '#c9a0ff';
      ctx.strokeStyle = 'rgba(13,17,23,.8)';
      ctx.lineWidth = 1.2;
      ctx.beginPath();
      ctx.moveTo(px + CELL / 2, py + 3);
      ctx.lineTo(px + CELL - 4, py + CELL / 2);
      ctx.lineTo(px + CELL / 2, py + CELL - 4);
      ctx.lineTo(px + 4, py + CELL / 2);
      ctx.closePath();
      ctx.fill();
      ctx.stroke();
      ctx.fillStyle = '#160b24';
      ctx.font = 'bold 9px "Microsoft YaHei", sans-serif';
      ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.fillText('R', px + CELL / 2, py + CELL / 2 + 0.5);
    }
  }

  // 区划中心
  for (const z of MAP.zone_list) {
    const [x, y] = z.center;
    const px = x * CELL, py = y * CELL;
    ctx.fillStyle = '#ff8adf';
    ctx.globalAlpha = 0.92;
    ctx.beginPath(); ctx.roundRect(px + 2, py + 2, CELL - 4, CELL - 4, 5); ctx.fill();
    ctx.globalAlpha = 1;
    ctx.strokeStyle = '#fff';
    ctx.lineWidth = 1.2; ctx.stroke();
    ctx.fillStyle = '#180a16';
    ctx.font = 'bold 9px "Microsoft YaHei", sans-serif';
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText(z.name, px + CELL / 2, py + CELL / 2 + 0.5);
  }

  // 区划号（中心左上）
  for (const z of MAP.zone_list) {
    const [x, y] = z.center;
    ctx.fillStyle = 'rgba(13,17,23,.82)';
    ctx.beginPath(); ctx.roundRect(x * CELL + 1, y * CELL - 8, 18, 12, 4); ctx.fill();
    ctx.fillStyle = '#ffd166';
    ctx.font = 'bold 9px monospace';
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText('Z' + z.id, x * CELL + 10, y * CELL - 2);
  }

  // 高亮区划
  if (activeZone >= 0) {
    ctx.strokeStyle = '#ffd166';
    ctx.lineWidth = 3;
    for (let y = 0; y < H; y++) {
      for (let x = 0; x < W; x++) {
        if (MAP.zones[y][x] !== activeZone) continue;
        if (x === 0 || MAP.zones[y][x - 1] !== activeZone) { ctx.beginPath(); ctx.moveTo(x * CELL, y * CELL); ctx.lineTo(x * CELL, (y + 1) * CELL); ctx.stroke(); }
        if (x + 1 === W || MAP.zones[y][x + 1] !== activeZone) { ctx.beginPath(); ctx.moveTo((x + 1) * CELL, y * CELL); ctx.lineTo((x + 1) * CELL, (y + 1) * CELL); ctx.stroke(); }
        if (y === 0 || MAP.zones[y - 1][x] !== activeZone) { ctx.beginPath(); ctx.moveTo(x * CELL, y * CELL); ctx.lineTo((x + 1) * CELL, y * CELL); ctx.stroke(); }
        if (y + 1 === H || MAP.zones[y + 1][x] !== activeZone) { ctx.beginPath(); ctx.moveTo(x * CELL, (y + 1) * CELL); ctx.lineTo((x + 1) * CELL, (y + 1) * CELL); ctx.stroke(); }
      }
    }
  }
}

function buildZoneList() {
  const box = document.getElementById('zoneList');
  const rows = [...MAP.zone_list].sort((a, b) => a.id - b.id);
  box.innerHTML = '';
  for (const z of rows) {
    const row = document.createElement('div');
    row.className = 'zrow' + (z.id === activeZone ? ' active' : '');
    row.dataset.zid = z.id;
    const owner = OWNER_OF[z.id] || '中立';
    const lvl = LEVEL_ZONES[z.id] || {};
    row.innerHTML = `<span class="zdot" style="background:${zoneColor(z.id)}"></span>
      <span class="zname">Z${z.id} ${centerName(z)}</span>
      <span class="zmeta">${owner} · ${lvl.build_point_count ?? 0} 点位</span>`;
    row.addEventListener('click', () => { activeZone = activeZone === z.id ? -1 : z.id; draw(); buildZoneList(); });
    box.appendChild(row);
  }
}

const tip = document.getElementById('tip');
function showTip(ev) {
  const rect = canvas.getBoundingClientRect();
  const scaleX = canvas.width / rect.width;
  const scaleY = canvas.height / rect.height;
  const cx = Math.floor((ev.clientX - rect.left) * scaleX / CELL);
  const cy = Math.floor((ev.clientY - rect.top) * scaleY / CELL);
  if (cx < 0 || cy < 0 || cx >= W || cy >= H) { tip.style.display = 'none'; return; }
  hover = { x: cx, y: cy };
  const ch = MAP.layout[cy][cx];
  const t = TERRAIN[ch] || TERRAIN['.'];
  const zid = MAP.zones[cy][cx];
  const z = ZONES[zid];
  const lvl = LEVEL_ZONES[zid] || {};
  const b = buildingAt[`${cx},${cy}`];
  const units = unitMarkers.filter(m => m.x === cx && m.y === cy);
  const rows = [
    ['格子', `(${cx}, ${cy})`],
    ['地形', t.name],
    ['区划', z ? `Z${z.id} ${z.name}` : '无区划'],
    ['归属', z ? (OWNER_OF[zid] || '无主') : '—'],
    ['建筑点位', z ? String(lvl.build_point_count ?? 0) : '—'],
  ];
  if (b) rows.push(['建筑', `${(BUILDING[b.type] || {}).name || b.type}（${b.owner}）`]);
  const key = `${cx},${cy}`;
  if (redSpawnSet.has(key)) rows.push(['红点', '生成地块']);
  if (redMarchSet.has(key)) rows.push(['红点', '行军目标']);
  if (NO_GO.has(key)) rows.push(['边缘区', '是']);
  for (const u of units) rows.push([u.player ? '玩家单位' : '守军', u.player ? u.u.faction : `general + ${u.n} 兵`]);
  tip.innerHTML = `<div style="margin-bottom:5px"><b>${z ? `Z${zid} · ${z.name}` : '无区划'}</b></div>` +
    rows.map(([k, v]) => `<div class="row"><span>${k}</span><span>${v}</span></div>`).join('');
  tip.style.display = 'block';
  const pad = 14;
  let left = ev.clientX + 16, top = ev.clientY + 16;
  if (left + 230 > window.innerWidth) left = ev.clientX - 240;
  if (top + 170 > window.innerHeight) top = ev.clientY - 180;
  tip.style.left = Math.max(pad, left) + 'px';
  tip.style.top = Math.max(pad, top) + 'px';
}
canvas.addEventListener('mousemove', showTip);
canvas.addEventListener('mouseleave', () => { tip.style.display = 'none'; });
canvas.addEventListener('click', () => {
  if (!hover) return;
  const zid = MAP.zones[hover.y][hover.x];
  activeZone = activeZone === zid ? -1 : zid;
  draw(); buildZoneList();
});

document.getElementById('cbZone').addEventListener('change', e => { showZone = e.target.checked; draw(); });
document.getElementById('cbOwner').addEventListener('change', e => { showOwner = e.target.checked; draw(); });
document.getElementById('cbBuild').addEventListener('change', e => { showBuild = e.target.checked; draw(); });
document.getElementById('cbUnits').addEventListener('change', e => { showUnits = e.target.checked; draw(); });
document.getElementById('cbNoGo').addEventListener('change', e => { showNoGo = e.target.checked; draw(); });
document.getElementById('cbGrid').addEventListener('change', e => { showGrid = e.target.checked; draw(); });
document.getElementById('btnFocus').addEventListener('click', () => {
  document.body.classList.toggle('map-only');
  document.getElementById('btnFocus').textContent =
    document.body.classList.contains('map-only') ? '显示侧栏' : '全屏地图';
});

buildZoneList();
draw();
</script>
</body>
</html>
"""

terrain_rows = "".join(
    f"<span>{name}</span><span>{count}</span>" for name, count in terrain_counts.most_common()
)
html = (
    html.replace("__MAP_JSON__", json.dumps(map_doc, ensure_ascii=False))
    .replace("__LEVEL_JSON__", json.dumps(level_doc, ensure_ascii=False))
    .replace("__BUILDING_COUNT__", str(len(MAP.get("buildings", []))))
    .replace("__ENEMY_GENERALS__", str(len(enemy_generals)))
    .replace("__ENEMY_ESCORTS__", str(enemy_escorts))
    .replace("__OWNER_DF__", str(owner_counts.get("df", 0)))
    .replace("__TERRAIN_ROWS__", terrain_rows)
)

with open(OUT_PATH, "w", encoding="utf-8", newline="\n") as f:
    f.write(html)
print(OUT_PATH)
print("terrain", dict(terrain_counts))
print("buildings", dict(building_counts))
print("owners", dict(owner_counts))
