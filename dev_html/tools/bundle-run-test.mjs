/**
 * tools/bundle-run-test.mjs —— 真的把打包产物跑起来（不需要浏览器）
 * 运行：node tools/bundle-run-test.mjs
 *
 * 为什么需要它：
 *   tools/verify_build.py 只做**文本比对**（每个模块剥离模块语法后是否逐字出现在产物里），
 *   它证明不了产物**能运行**。而单文件版是把 11 个模块按顺序拼进一个 <script> 里，
 *   于是多了一类只存在于产物中的风险：
 *     · 模块顺序错了 —— `const` 不像函数声明那样提升，A 模块顶层引用 B 模块的 const
 *       会直接 ReferenceError（原生 ESM 下不会，因为 import 会先求值）
 *     · 剥离 import/export 时漏了某个语法形态
 *     · 拼接后出现重复的顶层标识符（同名的 const 会 SyntaxError）
 *
 * 这里用 node:vm 在 DOM 桩里**执行**产物里的脚本，等价于浏览器的加载过程。
 *   URL 不带 #net=1 → 单机路径
 *   URL 带  #net=1  → 联机路径（顺便验证打包产物里的联机代码也能起来）
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');
const BUNDLE = join(ROOT, 'rts-prototype.html');

let pass = 0, fail = 0;
const ok = (cond, msg) => {
  if (cond) { pass++; console.log(`  ✔ ${msg}`); }
  else { fail++; console.log(`  ✘ ${msg}`); }
};
const section = (t) => console.log(`\n== ${t} ==`);

const html = readFileSync(BUNDLE, 'utf-8');

section('0 产物结构');
{
  ok(!/<script[^>]*type="module"/.test(html), '产物里没有 <script type="module">（file:// 下不会被 CORS 拦）');
  ok(!/^\s*import\s/m.test(html), '产物里没有残留的 import 语句');
  ok(!/^\s*export\s/m.test(html), '产物里没有残留的 export 关键字');
  ok(html.indexOf('<style>') > 0, 'CSS 已内联');

  // 模块拼接顺序：faction 必须在所有 import 它的模块之前
  const order = [...html.matchAll(/={20}\s*(js\/[\w.]+)\s*={20}/g)].map((m) => m[1]);
  ok(order.length === 11, `产物里标出了 11 个模块段（实际 ${order.length}）`);
  const idx = (f) => order.indexOf(f);
  ok(idx('js/faction.js') > -1 && idx('js/faction.js') < idx('js/path.js')
    && idx('js/faction.js') < idx('js/zone.js') && idx('js/faction.js') < idx('js/building.js')
    && idx('js/faction.js') < idx('js/unit.js') && idx('js/faction.js') < idx('js/render.js')
    && idx('js/faction.js') < idx('js/main.js'),
    '★ faction.js 排在所有依赖它的模块之前（const 不提升，顺序错会 ReferenceError）');
  ok(idx('js/config.js') < idx('js/faction.js'),
    'config.js 排在 faction.js 之前（faction 顶层读 CONFIG.colors）');
  ok(idx('js/net.js') < idx('js/render.js'),
    'net.js 排在 render.js 之前（render 顶层读 INTERP_DELAY）');
  ok(idx('js/util.js') < idx('js/net.js'), 'util.js 在 net.js 之前');
}

/** 抽出产物里的那个大 <script>（跳过任何 <script src> 之类） */
function extractScript(src) {
  const m = src.match(/<script>\s*"use strict";([\s\S]*?)<\/script>/);
  return m ? m[1] : null;
}

/** 造一套 DOM 桩并把产物脚本跑起来 */
function runBundle({ hash, withWebSocket }) {
  const ctx2d = new Proxy({}, {
    get: (_t, k) => {
      if (k === 'getTransform') return () => ({ a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 });
      return () => {};
    },
    set: () => true,
  });
  const elements = {};
  const makeEl = (id) => ({
    id, textContent: '', innerHTML: '', dataset: {}, style: {},
    clientWidth: 1200, clientHeight: 700, scrollTop: 0, scrollHeight: 0,
    classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
    addEventListener() {}, getBoundingClientRect: () => ({ left: 0, top: 0, width: 1200, height: 700 }),
    getContext: () => ctx2d,
  });

  const sent = [];
  const sandbox = {
    console,
    performance,
    setTimeout, clearTimeout, Math, Date, JSON,
    // vm 沙箱是独立 realm，浏览器里天然存在的全局要显式注入
    URLSearchParams, Map, Set, Promise, Number, String, Array, Object, Error,
    devicePixelRatio: 1,
    requestAnimationFrame: () => 0,
    addEventListener() {}, removeEventListener() {},
    ResizeObserver: class { observe() {} },
    document: { getElementById: (id) => (elements[id] || (elements[id] = makeEl(id))), addEventListener() {} },
    location: { hash, search: '', protocol: 'http:', host: '127.0.0.1:8080' },
  };
  sandbox.window = sandbox;
  sandbox.globalThis = sandbox;
  if (withWebSocket) {
    sandbox.WebSocket = class {
      static OPEN = 1;
      constructor(url) {
        this.url = url; this.readyState = 0;
        this._open = () => { this.readyState = 1; if (this.onopen) this.onopen({}); };
        setTimeout(this._open, 0);
      }
      send(d) { sent.push(JSON.parse(d)); }
      close() { this.readyState = 3; }
    };
  }

  const script = extractScript(html);
  vm.createContext(sandbox);
  vm.runInContext(script, sandbox, { filename: 'rts-prototype.bundle.js' });
  return { sandbox, sent, elements };
}

section('1 单机路径：产物能在 DOM 桩里跑起来');
let single = null;
{
  let err = null;
  try { single = runBundle({ hash: '', withWebSocket: false }); }
  catch (e) { err = String(e); }
  ok(err === null, `★ 产物脚本执行无异常${err ? '：' + err : ''}`);
  const R = single && single.sandbox.RTS;
  ok(!!R && !!R.state, '产物暴露了 window.RTS');
  ok(R && R.state.units.length === 3, `开局 3 个将领（${R ? R.state.units.length : '-'}）`);
  ok(R && R.state.units.every((u) => u.faction === 'player'), "单机阵营是 'player'");
  ok(R && R.state.zones.length === 24 && R.state.zoneLookup.length === 384, '区块系统建立完成');
  ok(R && !!R.state.buildings.get(R.state.base.x, R.state.base.y), '大本营已放置');
  ok(R && R.netStatus().active === false, '不带 #net=1 时不进联机模式');

  // 推动几帧 + 渲染一帧（真正走到 game loop 的每一部分）
  let loopErr = null;
  try {
    for (let i = 0; i < 30; i++) R.frame(1 / 60);
    R.drawOnce();
  } catch (e) { loopErr = String(e); }
  ok(loopErr === null, `★★ 产物能连续推进 30 帧并渲染（这才是真正"跑起来"）${loopErr ? '：' + loopErr : ''}`);

  // 玩法自检：下达移动命令并确认真的动了
  const g = R && R.state.units[0];
  if (g) {
    R.selectUnits([g]);
    const moved = g.orderMove(R.state, { x: 20 * 120 + 55, y: 12 * 120 + 40 });
    for (let i = 0; i < 60; i++) R.frame(1 / 60);
    ok(moved === true && g.path !== null || g.moving, '产物里能下达移动命令并推进');
  }
}

section('2 联机路径：产物里的联机代码也能起来（#net=1）');
{
  let net = null;
  let err = null;
  try { net = runBundle({ hash: '#net=1&room=bundletest', withWebSocket: true }); }
  catch (e) { err = String(e); }
  ok(err === null, `★ 产物在 #net=1 下执行无异常${err ? '：' + err : ''}`);
  const R = net && net.sandbox.RTS;
  ok(!!R, '产物在联机模式下暴露了 window.RTS');
  ok(R && R.netStatus().active === true, '联机模式激活');
  ok(R && R.myFaction() === 'p1', `★ 启动阵营是 p1（实际 ${R ? R.myFaction() : '-'}）`);
  ok(R && R.state.units.every((u) => u.faction === 'p1'),
    '房主的将领阵营是 p1（打包后仍正确）');

  // 等 hello 发出去，再推帧看快照广播
  await new Promise((r) => setTimeout(r, 30));
  ok(net.sent.some((m) => m.t === 'hello'), '产物发出了 hello 握手');
  ok(net.sent.some((m) => m.t === 'hello' && m.room === 'bundletest'),
    'hello 带了房间名（产物里 URL 解析正确）');

  net.sent.length = 0;
  let loopErr = null;
  try { for (let i = 0; i < 60; i++) R.frame(1 / 60); }
  catch (e) { loopErr = String(e); }
  const snaps = net.sent.filter((m) => m.t === 'snap');
  ok(loopErr === null, `产物在联机模式下能连续推帧${loopErr ? '：' + loopErr : ''}`);
  ok(snaps.length >= 15 && snaps.length <= 25,
    `★★ 产物按 20Hz 广播快照（1 秒 ${snaps.length} 条）—— 联机主循环在打包后仍然成立`);
  ok(snaps[0] && snaps[0].s.units.length === 3, '快照内容完整');

  /**
   * ★ 线上事故回归：产物在联机模式下**开局不能自己判胜负**。
   *
   * 名单 FACTION_ROSTER 有 8 个席位，但开局只有房主 p1 有基地。
   * 曾经 checkVictory 拿名单当分母 → 第 0 帧就判「p1 获胜」，
   * 两个玩家一打开页面就看见"P1 赢了"，根本没法玩。
   */
  ok(R.state.match.over === false,
    `★ 产物开局不判胜负（over=${R.state.match.over} winner=${R.state.match.winner}）`
    + (R.state.match.over ? ' ← 就是"一打开就显示 P1 赢了"' : ''));
  ok(R.state.match.winner === null, '没有胜者');
  ok(!R.state.match.logged, '也没有播报结算');
  ok(R.state.buildingList.filter((b) => b.type === 'base').length === 1,
    '开局只有房主一个基地（别人还没进房间）');
}

console.log(`\n———————————————\n通过 ${pass} 项，失败 ${fail} 项`);
process.exit(fail ? 1 : 0);
