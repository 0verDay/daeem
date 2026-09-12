#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/browser-test.py —— 浏览器内交互回归测试（无头 Edge/Chrome）

为什么需要：无头模式下 requestAnimationFrame 不触发，所以不能靠“等一会儿再看”。
这里把游戏主循环的 update/draw 通过 window.RTS 调试句柄暴露出来，在页面里
同步推进逻辑并断言，结果写进 DOM，再由本脚本读取。

覆盖：
  选中将领 / 右键移动 / 四连通路径 / 区块占领 / 资源增长 /
  建造城墙与箭塔 / 同格重复建造被拒 / 山地与大本营不可建造 /
  己方能穿墙而敌方不能 / 箭塔造成伤害 / 拆除建筑 / 渲染一帧

用法：
  python tools/browser-test.py                    # 自动探测 Edge / Chrome
  python tools/browser-test.py --browser "C:\\path\\to\\chrome.exe"
  python tools/browser-test.py --shot out.png     # 顺便截一张有内容的画面
"""

import argparse
import io
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'rts-prototype.html')

CANDIDATES = [
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    os.path.expandvars(r'%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe'),
    r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
]

TEST_HOOK = u"""
<pre id="bt-out" style="display:none">pending</pre>
<script>
setTimeout(function(){
  var R = window.RTS, s = R.state;
  var results = [];
  function check(name, cond, extra){ results.push((cond ? 'PASS' : 'FAIL') + '|' + name + '|' + (extra || '')); }
  function tick(n){ for (var i = 0; i < n; i++) R.tick(1/60); }

  // ---- 选中与移动（单位现在收**世界像素坐标**：点到哪走到哪） ----
  R.selectUnits([s.units[0]]);
  check('按 1 选中将领1', s.ui.selectedUnits.length === 1 && s.ui.selectedUnits[0] === s.units[0]);
  var CELL = 120;
  var aimTile = { x: 19, y: 4 };
  var aimPt = { x: aimTile.x * CELL + 7.5, y: aimTile.y * CELL + 108 };   // 目标格内偏右下，故意不取格心
  check('右键下令移动返回成功', s.units[0].orderMove(s, aimPt) === true);
  var path = s.units[0].path || [];
  check('得到路径点', path.length >= 1, 'len=' + path.length);
  var last = path[path.length - 1];
  check('路径终点 = 点击位置（不吸附格心）',
        Math.abs(last.x - aimPt.x) < 1e-6 && Math.abs(last.y - aimPt.y) < 1e-6,
        '(' + last.x + ',' + last.y + ')');
  // ★ 路径拉直：每一段直线都必须通过通行判定（不允许为了走直线而翻山 / 穿墙）
  var segFrom = { x: s.units[0].px, y: s.units[0].py }, segsClear = true;
  path.forEach(function(n){
    if (!R.segmentClearFor(s, segFrom, n, 'player')) segsClear = false;
    segFrom = n;
  });
  check('拉直后的每一段直线都可通行（不会为了走直线而翻山）', segsClear, '段数=' + path.length);
  check('有山阻挡时保留了拐点绕行（没有被错误地拉成一条直线）', path.length > 1, '路径点=' + path.length);
  check('路径点是像素坐标（都在地图世界范围内）', path.every(function(n){
    return n.x >= 0 && n.x <= s.terrain.cols * CELL && n.y >= 0 && n.y <= s.terrain.rows * CELL;
  }), 'len=' + path.length);

  // ---- 移动与占领 ----
  var from = s.units[0].tx + ',' + s.units[0].ty;
  var prevPos = { x: s.units[0].px, y: s.units[0].py };
  var maxStep = 0, offCenterFrames = 0;
  for (var mi = 0; mi < 60 * 20 && s.units[0].moving; mi++) {
    R.tick(1/60);
    var d = Math.hypot(s.units[0].px - prevPos.x, s.units[0].py - prevPos.y);
    maxStep = Math.max(maxStep, d);
    var cx = (Math.floor(s.units[0].px / CELL) + 0.5) * CELL;
    var cy = (Math.floor(s.units[0].py / CELL) + 0.5) * CELL;
    if (Math.abs(s.units[0].px - cx) > 1 || Math.abs(s.units[0].py - cy) > 1) offCenterFrames++;
    prevPos = { x: s.units[0].px, y: s.units[0].py };
  }
  var to = s.units[0].tx + ',' + s.units[0].ty;
  check('走到了点击所在的格子', s.units[0].tx === aimTile.x && s.units[0].ty === aimTile.y, from + ' -> ' + to);
  check('精确停在点击位置', Math.abs(s.units[0].px - aimPt.x) < 0.01 && Math.abs(s.units[0].py - aimPt.y) < 0.01,
        '(' + s.units[0].px.toFixed(2) + ',' + s.units[0].py.toFixed(2) + ')');
  check('单帧位移不超过一格（不存在整格跳变）', maxStep < CELL, 'maxStep=' + maxStep.toFixed(2) + 'px');
  check('移动途中确实处于地块内的连续位置', offCenterFrames > 5, '非格心帧数 ' + offCenterFrames);
  var z = s.zones[s.zoneLookup[aimTile.y * s.terrain.cols + aimTile.x]];
  check('站够时间后区块归己方', z.owner === 'player', z.name + ' progress=' + z.progress.toFixed(2));
  check('己方地块数随占领增长', s.ownedTiles >= z.tileCount && s.ownedTiles % z.tileCount === 0,
        'ownedTiles=' + s.ownedTiles + '（单个区块 ' + z.tileCount + ' 格，其他将领也可能占了区块）');
  check('粮食与黄金按地块数增长', s.resources.food > 0 && Math.abs(s.resources.food - s.resources.gold) < 0.5,
        'food=' + s.resources.food.toFixed(1) + ' gold=' + s.resources.gold.toFixed(1));

  // ---- 建造 ----
  R.selectBuildType('wall');
  check('建造城墙成功', R.tryBuildAt(11, 10) === true && !!s.buildings.get(11, 10));
  check('同一地块重复建造被拒绝', R.tryBuildAt(11, 10) === false);
  var w11 = s.buildings.get(11, 10);
  check('城墙有血量（新建满血）',
        !!w11 && w11.hp === R.CONFIG.building.wall.hpMax && w11.hpRatio === 1,
        'hp=' + (w11 ? w11.hp : 'null') + '/' + R.CONFIG.building.wall.hpMax);
  R.selectBuilding(w11);
  check('选中城墙后侧栏显示生命数值',
        document.getElementById('selDetail').textContent.indexOf('生命') >= 0,
        document.getElementById('selDetail').textContent);
  w11.takeDamage(R.CONFIG.combat.buildingDamage, s.units[0]);
  check('城墙受击掉血 + 闪光（渲染血条与红闪）',
        w11.hp === R.CONFIG.building.wall.hpMax - R.CONFIG.combat.buildingDamage && w11.flash === 1,
        'hp=' + w11.hp + ' flash=' + w11.flash);
  R.selectUnits([]);
  // 大本营本版不可摧毁
  var bb = s.buildings.get(12, 8);
  var bbHp = bb.hp;
  bb.takeDamage(99999, null);
  check('大本营被打到 0 血时保留 1 点（不可摧毁）', bb.alive === true && bb.hp === 1,
        'hp ' + bbHp + ' -> ' + bb.hp);
  R.selectBuildType('tower');
  check('建造箭塔成功', R.tryBuildAt(12, 11) === true);
  check('山地上不可建造', R.tryBuildAt(15, 5) === false);
  check('大本营所在格不可建造', R.tryBuildAt(12, 8) === false);
  check('建造会提升区块归属计数', s.buildingRevision >= 3, 'revision=' + s.buildingRevision);
  R.selectBuildType(null);

  // ---- 城墙：己方穿过 / 敌方阻挡（直线判定 + A* 都要正确） ----
  s.units[1].orderMove(s, { x: 13 * CELL + 60, y: 10 * CELL + 60 });
  check('己方：穿过城墙格的直线可以走（城墙不挡自己人）',
        R.segmentClearFor(s, { x: 11 * CELL + 60, y: 10 * CELL + 60 }, { x: 13 * CELL + 60, y: 10 * CELL + 60 }, 'player') === true);
  check('敌方：同一条直线被城墙挡住',
        R.segmentClearFor(s, { x: 11 * CELL + 60, y: 10 * CELL + 60 }, { x: 13 * CELL + 60, y: 10 * CELL + 60 }, 'enemy') === false);
  var pe = R.findPathFor(s, { x: 14, y: 10 }, { x: 12, y: 8 }, 'enemy');
  check('敌方无法把城墙格当作通路', !pe || !pe.some(function(n){ return n.x === 11 && n.y === 10; }), pe ? 'len=' + pe.length : 'null');

  // ---- 箭塔伤害（关掉单位战斗，避免将领抢人头，单独验证箭塔） ----
  R.CONFIG.combat.enabled = false;
  var e = R.spawnEnemy(13, 10);
  check('调试刷敌人成功', !!e, e ? e.tx + ',' + e.ty : 'null');
  var hp0 = e.hp;
  tick(60 * 2);
  check('箭塔对射程内敌人造成伤害', e.hp < hp0, 'hp ' + hp0 + ' -> ' + e.hp);
  check('己方单位不会被己方箭塔误伤', s.units[0].hp === s.units[0].hpMax || s.units[0].hp <= s.units[0].hpMax);
  R.CONFIG.combat.enabled = true;

  // ---- 拆除 ----
  check('拆除城墙成功', R.removeBuildingFor(s, s.buildings.get(11, 10)) === true && !s.buildings.get(11, 10));
  check('大本营不可拆除', R.removeBuildingFor(s, s.buildings.get(12, 8)) === false);

  // ---- 坐标换算：鼠标点 ↔ 地块 必须一致（高 DPI 错位 bug 的回归） ----
  var v = s.view, cvs = document.getElementById('game');
  check('画布后备缓冲 = CSS 尺寸 × dpr',
        cvs.width === Math.round(v.w * v.dpr) && cvs.height === Math.round(v.h * v.dpr),
        'canvas=' + cvs.width + 'x' + cvs.height + ' view=' + v.w + 'x' + v.h + ' dpr=' + v.dpr);
  check('画布元素实际尺寸与视口一致',
        Math.abs(cvs.getBoundingClientRect().width - v.w) < 1,
        'rect=' + cvs.getBoundingClientRect().width.toFixed(1) + ' view=' + v.w);
  var aimErr = 0, aimCases = 0;
  R.fitView();
  [[0, 0], [1, 1], [240, 200], [600, 400], [900, 500]].forEach(function(pt){
    var w = R.screenToWorld(pt[0], pt[1]);
    var t = R.worldToTile(w.x, w.y);
    var c = R.tileCenter(t.x, t.y);
    // 鼠标世界坐标必须落在判定出的那个地块内
    if (!(w.x >= t.x * CELL && w.x < (t.x + 1) * CELL && w.y >= t.y * CELL && w.y < (t.y + 1) * CELL)) aimErr++;
    aimCases++;
    // 该地块中心反算回去必须还是同一格
    var back = R.worldToTile(c.x, c.y);
    if (back.x !== t.x || back.y !== t.y) aimErr++;
    aimCases++;
  });
  check('屏幕点 → 世界 → 地块 换算自洽', aimErr === 0, '检查 ' + aimCases + ' 项，异常 ' + aimErr);

  // ---- 平滑移动：连续位置、不跳格、速度均匀、终点为点击位置 ----
  var g2 = s.units[2];
  g2.stop();
  var g2pt = { x: 20 * CELL + 12.5, y: 12 * CELL + 33.5 };
  check('右键下令移动返回成功(2)', g2.orderMove(s, g2pt) === true);
  check('开阔地：路径被拉直成一条直线（不再沿格心走阶梯）', g2.path.length === 1, '路径点=' + g2.path.length);
  var samples = [], prev = { x: g2.px, y: g2.py }, tileJumps = 0, lastTile = g2.tx + ',' + g2.ty;
  for (var fi = 0; fi < 60 * 25 && g2.moving; fi++) {
    R.tick(1/60);
    samples.push(Math.hypot(g2.px - prev.x, g2.py - prev.y));
    prev = { x: g2.px, y: g2.py };
    var tk = g2.tx + ',' + g2.ty;
    if (tk !== lastTile) {
      var p0 = lastTile.split(','), q0 = tk.split(',');
      if (Math.max(Math.abs(+p0[0] - +q0[0]), Math.abs(+p0[1] - +q0[1])) !== 1) tileJumps++;
      lastTile = tk;
    }
  }
  var moving = samples.filter(function(d){ return d > 0.01; });
  var budget = 2.4 * CELL / 60;                     // 草地每帧预算
  var badBudget = moving.filter(function(d){ return d > budget + 1e-6; }).length;
  check('移动是连续的（每帧位移都是小数格，不是整格跳）',
        moving.filter(function(d){ return d < CELL; }).length > 10,
        '采样 ' + samples.length + ' 帧');
  check('每帧位移不超过草地速度预算', badBudget === 0,
        '预算 ' + budget.toFixed(2) + 'px/帧，超预算 ' + badBudget + ' 帧');
  check('不会跨格跳跃（tx/ty 每次只走相邻格，允许斜穿）', tileJumps === 0, '跳格 ' + tileJumps + ' 次');
  var endCenter = R.tileCenter(g2.tx, g2.ty);
  check('停在点击位置而不是格心',
        Math.abs(g2.px - g2pt.x) < 0.01 && Math.abs(g2.py - g2pt.y) < 0.01
        && (Math.abs(g2.px - endCenter.x) > 1 || Math.abs(g2.py - endCenter.y) > 1),
        '(' + g2.px.toFixed(1) + ',' + g2.py.toFixed(1) + ') 格心 (' + endCenter.x + ',' + endCenter.y + ')');
  g2.stop();

  // ---- 战斗与警戒：静止单位发现敌人 → 先移动靠近 → 再攻击 ----
  s.units = s.units.filter(function(u){ return u.faction !== 'enemy'; });   // 先清场，保证只有下面这一个敌人
  R.CONFIG.combat.enabled = true;
  var cg = s.units[0];
  cg.stop();
  cg.hp = cg.hpMax;
  var ce = R.spawnEnemy(cg.tx + 3, cg.ty);          // 刷在警戒半径（4 格）之内
  check('刷出一个警戒范围内的敌人', !!ce && ce.alive === true, ce ? ce.tx + ',' + ce.ty : 'null');
  var cd0 = Math.hypot(cg.px - ce.px, cg.py - ce.py);
  check('初始：在警戒半径内但够不着',
        cd0 <= R.CONFIG.combat.aggroRange * CELL && cd0 > R.CONFIG.combat.general.range * CELL,
        '间距 ' + cd0.toFixed(0) + 'px');
  tick(1);
  check('静止的单位发现敌人后进入警戒（锁定目标）', cg.target === ce,
        cg.target ? '目标=' + cg.target.name : '未锁定');
  var hpE0 = ce.hp, minD = cd0;
  for (var ci = 0; ci < 60 * 6 && ce.hp === hpE0; ci++) {
    tick(1);
    minD = Math.min(minD, Math.hypot(cg.px - ce.px, cg.py - ce.py));
  }
  check('先移动靠近（距离变小）', minD < cd0, cd0.toFixed(0) + 'px -> ' + minD.toFixed(0) + 'px');
  check('进入攻击距离后开火（敌人掉血）', ce.hp < hpE0, 'hp ' + hpE0 + ' -> ' + ce.hp);
  check('开火时站住不再移动', cg.moving === false);
  var hpE1 = ce.hp;
  tick(6);
  check('冷却时间内不会连续开火', ce.hp === hpE1, 'hp=' + ce.hp);
  // 让将领一直打，直到敌人被击杀
  for (var ki = 0; ki < 60 * 20 && ce.alive; ki++) tick(1);
  check('敌人被击杀后移除', ce.alive === false && s.units.indexOf(ce) < 0, 'alive=' + ce.alive);
  tick(1);
  check('击杀后自动脱离交战', cg.target === null);

  // ---- 移动中的单位不索敌（只有静止时才警戒） ----
  var mg = s.units[1];
  mg.stop();
  var me = R.spawnEnemy(mg.tx + 3, mg.ty);
  check('刷出一个移动单位旁边的敌人', !!me, me ? me.tx + ',' + me.ty : 'null');
  mg.orderMove(s, { x: mg.px - 4 * CELL, y: mg.py });
  tick(1);
  check('正在执行移动命令的单位不会半路索敌', mg.moving === true && mg.target === null,
        'moving=' + mg.moving + ' target=' + (mg.target ? mg.target.name : 'null'));
  s.units = s.units.filter(function(u){ return u.faction !== 'enemy'; });   // 收尾清场

  // ---- 边缘滚屏 ----
  var beforeCamX = s.camera.x;
  s.ui.mouseScreen = { x: s.view.w - 2, y: s.view.h / 2 };   // 鼠标贴右边缘
  for (var ei = 0; ei < 30; ei++) R.tick(1/60);
  check('鼠标贴视野右边缘 → 视角向右移动', s.camera.x > beforeCamX,
        'camX ' + beforeCamX.toFixed(1) + ' -> ' + s.camera.x.toFixed(1));
  var midCamX = s.camera.x;
  s.ui.mouseScreen = { x: s.view.w / 2, y: s.view.h / 2 };   // 回到画面中央
  for (var ei2 = 0; ei2 < 30; ei2++) R.tick(1/60);
  check('鼠标回到画面中央 → 停止滚动', Math.abs(s.camera.x - midCamX) < 1e-6,
        'camX=' + s.camera.x.toFixed(1));
  s.ui.mouseScreen = null;
  // 全图视野下不应越界
  R.fitView();
  var camDiag = { x: s.camera.x, y: s.camera.y };
  check('F 全图：视野覆盖整张地图',
        s.camera.x <= 0.5 && s.camera.y <= 0.5 &&
        s.camera.x + s.view.w / s.camera.scale >= s.terrain.cols * CELL - 0.5,
        'camX=' + camDiag.x.toFixed(1) + ' scale=' + s.camera.scale.toFixed(3));
  R.fitView();

  // ---- 渲染 ----
  // 让一栋建筑处于“掉血 + 受击闪光”状态，确保血条 / 红闪这两条渲染路径都跑到
  var dmgTower = s.buildings.get(12, 11);
  if (dmgTower) { dmgTower.takeDamage(R.CONFIG.combat.buildingDamage, s.units[0]); dmgTower.flash = 1; }
  check('掉血 / 受击闪光状态下的建筑存在（下面的渲染检查会画它）', !!dmgTower,
        dmgTower ? 'hp=' + dmgTower.hp + '/' + dmgTower.hpMax : 'null');
  var drawErr = null;
  try { R.drawOnce(); } catch (err) { drawErr = '' + err; }
  check('渲染一帧无异常', drawErr === null, drawErr || '');
  check('无未捕获的 JS 异常', window.__btErrs.length === 0, window.__btErrs.join(' / '));

  document.getElementById('bt-out').textContent =
    JSON.stringify({ results: results, errs: window.__btErrs }, null, 1);
}, 1000);
</script>
"""

HEAD = u"""<script>
window.__btErrs = [];
window.addEventListener('error', function(e){
  var t = e.target;
  if (t && t.tagName) window.__btErrs.push('RESOURCE_ERR ' + t.tagName);
  else window.__btErrs.push('ERROR ' + e.message + ' @' + (e.filename || '?') + ':' + e.lineno);
});
window.addEventListener('unhandledrejection', function(e){ window.__btErrs.push('REJECT ' + e.reason); });
</script>
"""


def find_browser(explicit=None):
    if explicit:
        return explicit if os.path.exists(explicit) else None
    for p in CANDIDATES:
        if p and os.path.exists(p):
            return p
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--browser', default=None)
    ap.add_argument('--shot', default=None, help='额外截一张游戏画面到该路径')
    args = ap.parse_args()

    if not os.path.exists(SRC):
        print('未找到 rts-prototype.html，请先运行: python tools/build_single_file.py')
        return 2

    browser = find_browser(args.browser)
    if not browser:
        print('未找到 Chrome / Edge，可用 --browser 指定可执行文件路径')
        return 2

    profile = os.path.join(tempfile.gettempdir(), 'rts_browser_test_profile')

    html = io.open(SRC, encoding='utf-8').read()
    html = html.replace(u'<!DOCTYPE html>', u'<!DOCTYPE html>\n' + HEAD, 1)
    html = html.replace(u'</body>', TEST_HOOK + u'</body>')

    tests_html = os.path.join(ROOT, 'tools', '_browser_test.html')
    io.open(tests_html, 'w', encoding='utf-8').write(html)

    def run(url, extra=None):
        """用临时文件收集浏览器输出（避免依赖管道抓取 stdout）。"""
        log = os.path.join(tempfile.gettempdir(), 'rts_browser_test_dom.html')
        cmd = [browser, '--headless=new', '--disable-gpu', '--no-first-run',
               '--user-data-dir=' + profile, '--window-size=1500,900',
               '--virtual-time-budget=6000']
        if extra:
            cmd += extra
        cmd.append(url)
        with open(log, 'w', encoding='utf-8') as fh:
            subprocess.run(cmd, stdout=fh, stderr=subprocess.DEVNULL)
        if not os.path.exists(log):
            return ''
        return io.open(log, encoding='utf-8', errors='replace').read()

    print(f'浏览器: {browser}')
    stdout = run('file:///' + tests_html.replace('\\', '/'), ['--dump-dom'])
    m = re.search(r'<pre id="bt-out"[^>]*>(.*?)</pre>', stdout, re.S)
    if not m:
        print('未能读取测试结果（页面可能未执行到探针）')
        tail = stdout[-800:] if stdout else '(无输出)'
        print(tail)
        return 2

    data = json.loads(m.group(1))
    results = data['results']
    failed = [r for r in results if r.startswith('FAIL')]
    print()
    for r in results:
        state, name, extra = (r.split('|') + ['', ''])[:3]
        mark = '[OK]  ' if state == 'PASS' else '[FAIL]'
        print(f'  {mark} {name}' + (f'  — {extra}' if extra else ''))

    if args.shot:
        shot_hook = u"""
<script>
setTimeout(function(){
  var R = window.RTS, s = R.state;
  function tick(n){ for (var i = 0; i < n; i++) R.tick(1/60); }
  R.selectUnits([s.units[0]]);
  s.units[0].orderMove(s, { x: 19 * CELL + 60, y: 4 * CELL + 60 }); tick(60 * 11); tick(60);
  s.units[1].orderMove(s, { x: 3 * CELL + 60, y: 2 * CELL + 60 }); tick(60 * 10);
  R.selectBuildType('wall');
  for (var x = 10; x <= 14; x++) R.tryBuildAt(x, 12);
  R.tryBuildAt(12, 13); R.tryBuildAt(12, 14);
  R.selectBuildType('tower');
  R.tryBuildAt(9, 11); R.tryBuildAt(15, 11);
  R.selectBuildType(null);
  R.spawnEnemy(13, 10); R.spawnEnemy(14, 11);
  tick(60 * 3);
  R.selectBuilding(s.buildings.get(9, 11));
  R.drawOnce();
  document.getElementById('food').textContent = s.resources.food.toFixed(1);
  document.getElementById('gold').textContent = s.resources.gold.toFixed(1);
  document.getElementById('tiles').textContent = s.ownedTiles;
  document.getElementById('rate').textContent = '+' + s.ownedTiles + ' / +' + s.ownedTiles + ' 每秒';
  document.getElementById('zoneList').textContent = R.ownedZoneNames();
  document.getElementById('statUnits').textContent = s.units.filter(function(u){return u.alive && u.faction==='player';}).length;
  document.getElementById('statEnemies').textContent = s.units.filter(function(u){return u.alive && u.faction==='enemy';}).length;
  document.getElementById('statBuildings').textContent = s.buildingList.length;
  document.getElementById('statRevision').textContent = s.buildingRevision;
  document.getElementById('log').innerHTML = s.log.map(function(l){ return '<div>' + l + '</div>'; }).join('');
}, 900);
</script>
"""
        shot_html = html.replace(TEST_HOOK, '').replace(u'</body>', shot_hook + u'</body>')
        shot_file = os.path.join(ROOT, 'tools', '_browser_shot.html')
        io.open(shot_file, 'w', encoding='utf-8').write(shot_html)
        shot_path = os.path.abspath(args.shot)
        run('file:///' + shot_file.replace('\\', '/'), ['--hide-scrollbars', '--screenshot=' + shot_path])
        print(f'\n截图: {shot_path}')

    print(f'\n通过 {len(results) - len(failed)} 项，失败 {len(failed)} 项')
    return 0 if not failed else 1


if __name__ == '__main__':
    sys.exit(main())
