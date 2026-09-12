/**
 * render.js —— Canvas 2D 渲染
 * 只负责“把状态画出来”，不做任何游戏逻辑。
 *
 * 坐标系约定（改这里请务必保持三条一致，否则会出现“鼠标位置和地块对不上”）：
 *   1. 相机与所有输入换算一律使用 **CSS 像素**（state.view.w / state.view.h）；
 *   2. canvas 后备缓冲按 devicePixelRatio 放大，绘制前用 ctx.scale(dpr) 对齐；
 *   3. 世界坐标 = 地块坐标 × CONFIG.cell（单位可以处于地块之间的连续位置上）。
 */

import { CONFIG } from './config.js';
import { tileCenter, clamp } from './util.js';

/** 当前视口逻辑尺寸（CSS 像素）——相机数学只认这个 */
export function viewSize(state) {
  return { w: state.view.w, h: state.view.h };
}

export function createCamera(state) {
  const cam = {
    x: -CONFIG.edgePad,
    y: -CONFIG.edgePad,
    scale: 1,
    minScale: CONFIG.camera.minScale,
    maxScale: CONFIG.camera.maxScale,
    worldW: state.terrain.cols * CONFIG.cell,
    worldH: state.terrain.rows * CONFIG.cell,
  };
  fit(cam, state);
  // 地图比视口大得多，fit 结果会很小；开局用 startScale 让玩家看清局部
  cam.scale = clamp(CONFIG.camera.startScale, cam.minScale, cam.maxScale);
  centerOn(cam, state, cam.worldW / 2, cam.worldH / 2);
  return cam;
}

export function fit(cam, state) {
  const v = viewSize(state);
  const sx = v.w / (cam.worldW + CONFIG.edgePad * 2);
  const sy = v.h / (cam.worldH + CONFIG.edgePad * 2);
  cam.scale = clamp(Math.min(sx, sy), cam.minScale, cam.maxScale);
  centerOn(cam, state, cam.worldW / 2, cam.worldH / 2);
}

export function centerOn(cam, state, wx, wy) {
  const v = viewSize(state);
  cam.x = wx - v.w / (2 * cam.scale);
  cam.y = wy - v.h / (2 * cam.scale);
  clampCam(cam, state);
}

export function clampCam(cam, state) {
  const v = viewSize(state);
  const viewW = v.w / cam.scale;
  const viewH = v.h / cam.scale;
  const pad = CONFIG.edgePad;
  if (viewW >= cam.worldW + pad * 2) cam.x = (cam.worldW - viewW) / 2;
  else cam.x = clamp(cam.x, -pad, cam.worldW + pad - viewW);
  if (viewH >= cam.worldH + pad * 2) cam.y = (cam.worldH - viewH) / 2;
  else cam.y = clamp(cam.y, -pad, cam.worldH + pad - viewH);
}

export function screenToWorld(cam, sx, sy) {
  return { x: cam.x + sx / cam.scale, y: cam.y + sy / cam.scale };
}

export function worldToTile(wx, wy) {
  return { x: Math.floor(wx / CONFIG.cell), y: Math.floor(wy / CONFIG.cell) };
}

/* ------------------------------------------------------------------ */
/* 主绘制                                                              */
/* ------------------------------------------------------------------ */

export function draw(state, canvas, cam, ui) {
  const ctx = canvas.getContext('2d');
  const dpr = state.view.dpr || 1;
  const v = viewSize(state);

  // 后备缓冲是 CSS 像素 × dpr，所以先按 dpr 对齐，之后全部按 CSS 像素绘制
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, v.w, v.h);
  ctx.fillStyle = '#131714';
  ctx.fillRect(0, 0, v.w, v.h);

  // 当前可见的世界矩形：地图变大后靠它裁剪绘制，避免每帧画整张图
  const view = {
    x0: cam.x, y0: cam.y,
    x1: cam.x + v.w / cam.scale,
    y1: cam.y + v.h / cam.scale,
  };

  ctx.save();
  ctx.translate(-cam.x * cam.scale, -cam.y * cam.scale);
  ctx.scale(cam.scale, cam.scale);

  drawTerrain(ctx, state, view);
  drawZones(ctx, state, view);
  drawGrid(ctx, state, view);
  drawBuildings(ctx, state, ui, view);
  if (ui.buildMode) drawBuildPreview(ctx, state, ui);
  if (ui.selectedUnits && ui.selectedUnits.length) drawSelectionInfo(ctx, state, ui);
  drawUnits(ctx, state, view);
  ctx.restore();

  drawScreenOverlay(ctx, state, cam);
}

/** 裁剪辅助：把一个世界矩形换算成地块范围（含 1 格余量） */
function visibleTileRange(view) {
  const cell = CONFIG.cell;
  return {
    x0: Math.max(0, Math.floor(view.x0 / cell) - 1),
    y0: Math.max(0, Math.floor(view.y0 / cell) - 1),
    x1: Math.floor(view.x1 / cell) + 1,
    y1: Math.floor(view.y1 / cell) + 1,
  };
}

const inView = (view, px, py, pad = CONFIG.cell) =>
  px + pad >= view.x0 && px - pad <= view.x1 && py + pad >= view.y0 && py - pad <= view.y1;

function drawTerrain(ctx, state, view) {
  const cell = CONFIG.cell;
  const C = CONFIG.colors;
  const r = visibleTileRange(view);
  const x1 = Math.min(state.terrain.cols - 1, r.x1);
  const y1 = Math.min(state.terrain.rows - 1, r.y1);
  for (let y = r.y0; y <= y1; y++) {
    for (let x = r.x0; x <= x1; x++) {
      const t = state.terrain.get(x, y);
      const px = x * cell, py = y * cell;
      if (t === 'mountain') {
        ctx.fillStyle = C.mountain;
        ctx.fillRect(px, py, cell, cell);
        ctx.fillStyle = C.mountainEdge;
        ctx.beginPath();
        ctx.moveTo(px + cell * 0.18, py + cell * 0.82);
        ctx.lineTo(px + cell * 0.46, py + cell * 0.2);
        ctx.lineTo(px + cell * 0.72, py + cell * 0.82);
        ctx.closePath();
        ctx.fill();
        ctx.fillStyle = 'rgba(255,255,255,0.10)';
        ctx.beginPath();
        ctx.moveTo(px + cell * 0.46, py + cell * 0.2);
        ctx.lineTo(px + cell * 0.6, py + cell * 0.5);
        ctx.lineTo(px + cell * 0.34, py + cell * 0.5);
        ctx.closePath();
        ctx.fill();
      } else if (t === 'forest') {
        ctx.fillStyle = C.forest;
        ctx.fillRect(px, py, cell, cell);
        ctx.strokeStyle = 'rgba(120,190,130,0.45)';
        ctx.lineWidth = 1.4;
        for (const [ox, oy, s] of [[0.3, 0.62, 0.18], [0.62, 0.72, 0.15], [0.5, 0.4, 0.2]]) {
          const cx = px + cell * ox, cy = py + cell * oy, r = cell * s;
          ctx.beginPath();
          ctx.moveTo(cx, cy - r);
          ctx.lineTo(cx + r * 0.85, cy + r * 0.75);
          ctx.lineTo(cx - r * 0.85, cy + r * 0.75);
          ctx.closePath();
          ctx.stroke();
        }
      } else {
        ctx.fillStyle = (x + y) % 2 === 0 ? C.grass : C.grassAlt;
        ctx.fillRect(px, py, cell, cell);
      }
    }
  }
}

function drawZones(ctx, state, view) {
  const cell = CONFIG.cell;
  const C = CONFIG.colors;

  for (const z of state.zones) {
    const x = z.x0 * cell, y = z.y0 * cell;
    const w = (z.x1 - z.x0 + 1) * cell;
    const h = (z.y1 - z.y0 + 1) * cell;
    if (!inView(view, x + w / 2, y + h / 2, Math.max(w, h) / 2)) continue;   // 视野外跳过

    if (z.owner === 'player') {
      ctx.fillStyle = C.zonePlayer;
      ctx.fillRect(x, y, w, h);
    } else if (z.progress > 0) {
      // 占领进度：从下往上填色（黄色）
      const ph = h * z.progress;
      ctx.fillStyle = C.zoneProgress;
      ctx.fillRect(x, y + h - ph, w, ph);
    } else {
      ctx.fillStyle = C.zoneNeutral;
      ctx.fillRect(x, y, w, h);
    }

    ctx.strokeStyle = z.owner === 'player' ? 'rgba(120,210,255,0.55)' : C.zoneLine;
    ctx.lineWidth = 2;
    ctx.strokeRect(x + 1, y + 1, w - 2, h - 2);

    if (state.ui.showZoneNames) {
      ctx.fillStyle = z.owner === 'player' ? 'rgba(200,240,255,0.85)' : 'rgba(255,255,255,0.35)';
      ctx.font = '600 15px "Segoe UI", system-ui, sans-serif';
      ctx.textAlign = 'left';
      ctx.textBaseline = 'top';
      const label = z.owner === 'player'
        ? `${z.name} · 己方`
        : z.progress > 0 ? `${z.name} · 占领 ${Math.round(z.progress * 100)}%` : `${z.name} · 无主`;
      ctx.fillText(label, x + 8, y + 7);
    }
  }
}

function drawGrid(ctx, state, view) {
  const cell = CONFIG.cell;
  const r = visibleTileRange(view);
  const x0 = r.x0 * cell, y0 = r.y0 * cell;
  const x1 = Math.min(state.terrain.cols, r.x1 + 1) * cell;
  const y1 = Math.min(state.terrain.rows, r.y1 + 1) * cell;
  ctx.strokeStyle = CONFIG.colors.grid;
  ctx.lineWidth = 1;
  ctx.beginPath();
  for (let x = r.x0; x <= r.x1 + 1; x++) {
    ctx.moveTo(x * cell, y0);
    ctx.lineTo(x * cell, y1);
  }
  for (let y = r.y0; y <= r.y1 + 1; y++) {
    ctx.moveTo(x0, y * cell);
    ctx.lineTo(x1, y * cell);
  }
  ctx.stroke();
}

function drawBuildings(ctx, state, ui, view) {
  for (const b of state.buildingList) {
    if (!b.alive) continue;
    if (!inView(view, (b.tx + 0.5) * CONFIG.cell, (b.ty + 0.5) * CONFIG.cell, CONFIG.cell)) continue;
    if (b.type === 'wall') drawWall(ctx, state, b);
    else if (b.type === 'tower') drawTower(ctx, state, b, ui);
    else if (b.type === 'base') drawBase(ctx, b);
  }
}

function drawWall(ctx, state, b) {
  const cell = CONFIG.cell;
  const px = b.tx * cell, py = b.ty * cell;
  const C = CONFIG.colors;
  const pad = 1;
  ctx.fillStyle = C.wall;
  ctx.fillRect(px + pad, py + pad, cell - pad * 2, cell - pad * 2);

  // 砖缝
  ctx.strokeStyle = 'rgba(0,0,0,0.28)';
  ctx.lineWidth = 1.2;
  ctx.beginPath();
  for (let i = 1; i < 3; i++) {
    ctx.moveTo(px + pad, py + (cell / 3) * i);
    ctx.lineTo(px + cell - pad, py + (cell / 3) * i);
  }
  for (let i = 1; i < 3; i++) {
    const off = i % 2 === 0 ? cell * 0.35 : cell * 0.65;
    ctx.moveTo(px + off, py + pad);
    ctx.lineTo(px + off, py + cell - pad);
  }
  ctx.stroke();

  // 与相邻城墙连接处不画边框，看起来连成一段墙
  ctx.fillStyle = C.wallDark;
  const neighbors = [[0, -1, 0, 0, cell, 3], [0, 1, 0, cell - 3, cell, 3], [-1, 0, 0, 0, 3, cell], [1, 0, cell - 3, 0, 3, cell]];
  for (const [dx, dy, ox, oy, w, h] of neighbors) {
    const nb = state.buildings.get(b.tx + dx, b.ty + dy);
    if (!nb || nb.type !== 'wall') ctx.fillRect(px + ox, py + oy, w, h);
  }

  drawBuildingDamage(ctx, b, px, py, cell);
}

/** 受击闪光：被打的瞬间整格闪一下红 */
function drawHitFlash(ctx, b, px, py, cell) {
  if (b.flash > 0) {
    ctx.fillStyle = `rgba(255,90,80,${(0.5 * clamp(b.flash, 0, 1)).toFixed(3)})`;
    ctx.fillRect(px, py, cell, cell);
  }
}

/** 受击闪光 + 掉血后的血条（城墙 / 箭塔共用；满血时不画血条，避免刷屏） */
function drawBuildingDamage(ctx, b, px, py, cell) {
  drawHitFlash(ctx, b, px, py, cell);
  if (b.hp < b.hpMax) {
    drawHpBar(ctx, px + 6, py + cell - 12, cell - 12, 6, b.hpRatio);
  }
}

function drawTower(ctx, state, b, ui) {
  const cell = CONFIG.cell;
  const c = tileCenter(b.tx, b.ty, cell);
  const t = ui.time;

  // 射程指示（选中 / 悬停 / 预览时）
  const showRange = ui.hoverBuilding === b || (ui.selectedBuilding === b);
  if (showRange) drawRangeCircle(ctx, c.x, c.y, b.def.range * cell, b.def.color);

  const r = cell * 0.3;
  ctx.fillStyle = b.def.color;
  ctx.beginPath();
  ctx.arc(c.x, c.y, r, 0, Math.PI * 2);
  ctx.fill();
  ctx.strokeStyle = 'rgba(0,0,0,0.45)';
  ctx.lineWidth = 2;
  ctx.stroke();

  // 城垛
  ctx.fillStyle = '#6d5348';
  for (let i = 0; i < 4; i++) {
    const a = (i / 4) * Math.PI * 2 + Math.PI / 4;
    ctx.fillRect(c.x + Math.cos(a) * r * 0.85 - 2.5, c.y + Math.sin(a) * r * 0.85 - 2.5, 5, 5);
  }

  // 塔顶旋转的箭
  if (b.lastTarget && b.lastTarget.alive) {
    ctx.strokeStyle = `rgba(255,220,120,${0.35 + 0.4 * (b.flash || 0)})`;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(c.x, c.y);
    ctx.lineTo(b.lastTarget.px, b.lastTarget.py);
    ctx.stroke();
  }
  ctx.save();
  ctx.translate(c.x, c.y);
  ctx.rotate((t * 1.2) % (Math.PI * 2));
  ctx.strokeStyle = 'rgba(255,255,255,0.5)';
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.moveTo(0, 0);
  ctx.lineTo(0, -r * 1.15);
  ctx.stroke();
  ctx.restore();

  drawBuildingDamage(ctx, b, b.tx * cell, b.ty * cell, cell);
}

function drawBase(ctx, b) {
  const cell = CONFIG.cell;
  const px = b.tx * cell, py = b.ty * cell;
  const C = CONFIG.colors;
  ctx.fillStyle = C.hq;
  ctx.fillRect(px + 2, py + 2, cell - 4, cell - 4);
  ctx.fillStyle = C.hqLight;
  ctx.fillRect(px + 6, py + 6, cell - 12, cell * 0.32);
  ctx.strokeStyle = 'rgba(0,0,0,0.5)';
  ctx.lineWidth = 2;
  ctx.strokeRect(px + 2, py + 2, cell - 4, cell - 4);

  // 旗杆
  const cx = px + cell * 0.5, cy = py + cell * 0.18;
  ctx.strokeStyle = '#e8e8e8';
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.moveTo(cx, cy);
  ctx.lineTo(cx, cy - cell * 0.22);
  ctx.stroke();
  ctx.fillStyle = '#ffd166';
  ctx.beginPath();
  ctx.moveTo(cx, cy - cell * 0.22);
  ctx.lineTo(cx + cell * 0.26, cy - cell * 0.15);
  ctx.lineTo(cx, cy - cell * 0.08);
  ctx.closePath();
  ctx.fill();

  // HP 条
  drawHitFlash(ctx, b, px, py, cell);
  drawHpBar(ctx, px + 4, py + cell - 8, cell - 8, 4, b.hp / b.hpMax);
}

function drawHpBar(ctx, x, y, w, h, ratio) {
  ctx.fillStyle = 'rgba(0,0,0,0.55)';
  ctx.fillRect(x, y, w, h);
  ctx.fillStyle = ratio > 0.5 ? '#5fd35f' : ratio > 0.25 ? '#e8c04a' : '#e05a5a';
  ctx.fillRect(x, y, w * clamp(ratio, 0, 1), h);
}

function drawRangeCircle(ctx, cx, cy, r, color, alpha = 1) {
  ctx.save();
  ctx.globalAlpha = clamp(alpha, 0, 1);
  ctx.fillStyle = CONFIG.colors.range;
  ctx.beginPath();
  ctx.arc(cx, cy, r, 0, Math.PI * 2);
  ctx.fill();
  ctx.strokeStyle = color || CONFIG.colors.rangeEdge;
  ctx.lineWidth = 2;
  ctx.setLineDash([6, 6]);
  ctx.stroke();
  ctx.setLineDash([]);
  ctx.restore();
}

function drawBuildPreview(ctx, state, ui) {
  const t = state.ui.hoverTile;
  if (!t || !state.ui.buildType) return;
  const cell = CONFIG.cell;
  const valid = state.ui.hoverValid;
  const def = state.ui.buildType === 'wall' ? CONFIG.building.wall : CONFIG.building.tower;

  if (state.ui.buildType === 'tower') {
    drawRangeCircle(ctx, (t.x + 0.5) * cell, (t.y + 0.5) * cell, def.range * cell, def.color);
  }
  ctx.fillStyle = valid ? 'rgba(120,255,150,0.30)' : 'rgba(255,90,90,0.35)';
  ctx.fillRect(t.x * cell, t.y * cell, cell, cell);
  ctx.strokeStyle = valid ? 'rgba(160,255,180,0.9)' : 'rgba(255,120,120,0.9)';
  ctx.lineWidth = 2;
  ctx.strokeRect(t.x * cell + 1, t.y * cell + 1, cell - 2, cell - 2);
}

function drawSelectionInfo(ctx, state, ui) {
  const u = ui.selectedUnits[0];
  if (!u || !u.alive) return;
  const cell = CONFIG.cell;

  // 攻击距离 / 警戒半径：一眼看出这个单位能打多远、多远内的敌人会被它盯上
  if (CONFIG.combat.enabled) {
    drawRangeCircle(ctx, u.px, u.py, u.aggroRangePx, 'rgba(255,255,255,0.30)', 0.22);
    drawRangeCircle(ctx, u.px, u.py, u.attackRangePx, 'rgba(255,170,120,0.85)', 0.5);
  }

  // 交战目标：套一圈虚线
  const tg = u.target;
  if (tg && tg.alive) {
    ctx.strokeStyle = 'rgba(255,120,120,0.9)';
    ctx.lineWidth = 2;
    ctx.setLineDash([4, 4]);
    ctx.beginPath();
    ctx.arc(tg.px, tg.py, unitRadius(tg.kind) + 7, 0, Math.PI * 2);
    ctx.stroke();
    ctx.setLineDash([]);
  }

  if (!u.goal) return;
  const g = tileCenter(u.goal.x, u.goal.y, cell);
  ctx.strokeStyle = 'rgba(255,209,102,0.75)';
  ctx.lineWidth = 2;
  ctx.setLineDash([5, 5]);
  ctx.beginPath();
  ctx.arc(g.x, g.y, cell * 0.34, 0, Math.PI * 2);
  ctx.stroke();
  ctx.setLineDash([]);

  // 剩余路径：路径点已经是**像素**坐标（见 unit.js 的 moveTo），这里直接连；
  // 早先这里又做了一次 tileCenter 换算，于是预览线会飞出地图。
  if (u.path && u.path.length) {
    ctx.strokeStyle = 'rgba(255,209,102,0.35)';
    ctx.lineWidth = 1.6;
    ctx.beginPath();
    ctx.moveTo(u.px, u.py);
    for (const n of u.path) ctx.lineTo(n.x, n.y);
    ctx.stroke();
  }
}

/**
 * 单位的绘制半径（世界像素）。
 * 统一从这里取，保证“画出来的大小”和“鼠标点选的判定范围”一致。
 */
export function unitRadius(kind = 'general') {
  const r = CONFIG.cell * (CONFIG.unit.radiusFactor || 0.1);
  return kind === 'general' ? r : r * 0.75;
}

function drawUnits(ctx, state, view) {
  const cell = CONFIG.cell;
  const C = CONFIG.colors;
  for (const u of state.units) {
    if (!u.alive) continue;
    const r = unitRadius(u.kind);
    if (!inView(view, u.px, u.py, cell)) continue;   // 视野外单位不画
    const barW = Math.max(14, cell * 0.26);
    const barH = Math.max(3, cell * 0.035);

    // 攻击线：开火瞬间到特效结束（attackFlash 由 unit.js 驱动）；打建筑时连到建筑中心
    if (u.attackFlash > 0) {
      let tgt = null;
      if (u.lastTarget && u.lastTarget.alive) tgt = { x: u.lastTarget.px, y: u.lastTarget.py };
      else if (u.lastBuilding && u.lastBuilding.alive) tgt = u.lastBuilding.center;
      if (tgt) {
        const a = (0.2 + 0.7 * clamp(u.attackFlash, 0, 1)).toFixed(3);
        ctx.strokeStyle = u.faction === 'player' ? `rgba(255,225,150,${a})` : `rgba(255,120,120,${a})`;
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.moveTo(u.px, u.py);
        ctx.lineTo(tgt.x, tgt.y);
        ctx.stroke();
      }
    }

    if (u.faction === 'player') {
      // 选中光环
      if (u.selected) {
        ctx.strokeStyle = C.generalSel;
        ctx.lineWidth = 3;
        ctx.beginPath();
        ctx.arc(u.px, u.py, r + 6, 0, Math.PI * 2);
        ctx.stroke();
        ctx.fillStyle = 'rgba(255,209,102,0.16)';
        ctx.beginPath();
        ctx.arc(u.px, u.py, r + 6, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.fillStyle = C.general;
      ctx.beginPath();
      ctx.arc(u.px, u.py, r, 0, Math.PI * 2);
      ctx.fill();
      ctx.strokeStyle = 'rgba(0,0,0,0.55)';
      ctx.lineWidth = 2;
      ctx.stroke();

      // 数字快捷键角标
      if (u.hotkey) {
        const badge = Math.max(6, r * 0.62);
        ctx.fillStyle = '#20261f';
        ctx.beginPath();
        ctx.arc(u.px + r * 0.8, u.py - r * 0.8, badge, 0, Math.PI * 2);
        ctx.fill();
        ctx.fillStyle = '#ffe9a8';
        ctx.font = `700 ${Math.round(badge * 1.5)}px "Segoe UI", system-ui, sans-serif`;
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(u.hotkey, u.px + r * 0.8, u.py - r * 0.8 + 0.5);
      }
    } else {
      ctx.fillStyle = C.enemy;
      ctx.beginPath();
      ctx.arc(u.px, u.py, r, 0, Math.PI * 2);
      ctx.fill();
      ctx.strokeStyle = 'rgba(0,0,0,0.55)';
      ctx.lineWidth = 2;
      ctx.stroke();
    }

    // 交战中：头顶一个小三角（黄=己方，红=敌方），方便一眼看出谁在打谁 / 谁在拆墙
    const engaged = (u.target && u.target.alive) || (u.targetBuilding && u.targetBuilding.alive);
    if (engaged) {
      const s = Math.max(4, r * 0.5);
      const ty0 = u.py - r - 5;
      ctx.fillStyle = u.faction === 'player' ? '#ffd166' : '#ff8a8a';
      ctx.beginPath();
      ctx.moveTo(u.px, ty0);
      ctx.lineTo(u.px - s, ty0 - s * 1.3);
      ctx.lineTo(u.px + s, ty0 - s * 1.3);
      ctx.closePath();
      ctx.fill();
    }

    // 血条（跟随单位尺寸缩放）
    ctx.fillStyle = 'rgba(0,0,0,0.45)';
    ctx.fillRect(u.px - barW / 2, u.py + r + 3, barW, barH);
    ctx.fillStyle = u.faction === 'player' ? '#7ce07c' : '#e05a5a';
    ctx.fillRect(u.px - barW / 2, u.py + r + 3, barW * clamp(u.hp / u.hpMax, 0, 1), barH);
  }
}

/** 悬停地块高亮 + 调试准星（画在屏幕空间，避免缩放导致线宽变化） */
function drawScreenOverlay(ctx, state, cam) {
  const ui = state.ui;
  const cell = CONFIG.cell;

  ctx.save();
  ctx.setTransform(ctx.getTransform());       // 保持当前 dpr 变换
  ctx.translate(-cam.x * cam.scale, -cam.y * cam.scale);
  ctx.scale(cam.scale, cam.scale);

  if (ui.hoverTile) {
    ctx.strokeStyle = 'rgba(255,255,255,0.45)';
    ctx.lineWidth = 1.5 / cam.scale;
    ctx.strokeRect(ui.hoverTile.x * cell, ui.hoverTile.y * cell, cell, cell);
  }

  // 调试准星：把“鼠标世界坐标”和“判定出的地块中心”都画出来，
  // 两者不重合就说明坐标换算有问题（按 G 开关）。
  if (ui.debugAim && ui.mouseWorld) {
    const mw = ui.mouseWorld;
    ctx.strokeStyle = 'rgba(255,90,90,0.95)';
    ctx.lineWidth = 1.4 / cam.scale;
    const s = 7 / cam.scale;
    ctx.beginPath();
    ctx.moveTo(mw.x - s, mw.y); ctx.lineTo(mw.x + s, mw.y);
    ctx.moveTo(mw.x, mw.y - s); ctx.lineTo(mw.x, mw.y + s);
    ctx.stroke();

    if (ui.hoverTile) {
      const c = tileCenter(ui.hoverTile.x, ui.hoverTile.y, cell);
      ctx.strokeStyle = 'rgba(90,255,120,0.95)';
      ctx.beginPath();
      ctx.arc(c.x, c.y, 4 / cam.scale, 0, Math.PI * 2);
      ctx.stroke();
    }
  }
  ctx.restore();
}
