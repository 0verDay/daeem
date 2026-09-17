/**
 * tools/net-server-test.mjs —— 真实 WebSocket 往返测试
 * 运行：先起服务器（py net/serve.py --port 8097），再 node tools/net-server-test.mjs 8097
 *
 * 验证的是 serve.py 里**手写的那部分协议**（RFC 6455 握手 + 帧编解码 + 房间/中继路由），
 * 因为那是整个联机方案里唯一「自己实现协议」的地方，也是最值得测的地方。
 *
 * 覆盖：
 *   1. WebSocket 握手成功
 *   2. /health 可用
 *   3. 房间里第一个是房主、第二个是客机（阵营 p1 / p2）
 *   4. 客机的 cmd 只发给房主，不广播给别人
 *   5. 房主的 snap 广播给客机，且不会回给房主自己
 *   6. 客机不能冒充房主发 snap
 *   7. 大消息（>125B，触发 126 扩展长度）能正确收发
 *   8. 有人离开时会收到 peer 通知
 */

const PORT = process.argv[2] || '8097';
const BASE = `http://127.0.0.1:${PORT}`;
const WSU = `ws://127.0.0.1:${PORT}/ws`;

let pass = 0, fail = 0;
const ok = (cond, msg) => {
  if (cond) { pass++; console.log(`  ✔ ${msg}`); }
  else { fail++; console.log(`  ✘ ${msg}`); }
};
const section = (t) => console.log(`\n== ${t} ==`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 打开一个 WS 并把收到的消息塞进队列，方便断言 */
function open(room) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WSU);
    const inbox = [];
    ws.addEventListener('message', (e) => {
      try { inbox.push(JSON.parse(e.data)); } catch { inbox.push({ t: 'raw', data: e.data }); }
    });
    const timer = setTimeout(() => reject(new Error('ws open timeout')), 5000);
    ws.addEventListener('open', () => {
      clearTimeout(timer);
      ws.send(JSON.stringify({ t: 'hello', room }));
      resolve({ ws, inbox });
    });
    ws.addEventListener('error', (e) => { clearTimeout(timer); reject(new Error('ws error')); });
  });
}

const waitFor = async (inbox, pred, ms = 3000) => {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    const hit = inbox.find(pred);
    if (hit) return hit;
    await sleep(20);
  }
  return null;
};

section('1 健康检查（不需要 WS）');
{
  let health = null;
  try {
    const r = await fetch(`${BASE}/health`);
    health = await r.json();
  } catch (e) { health = { error: String(e) }; }
  ok(health && health.ok === true, `/health 返回 ok（${JSON.stringify(health)}）`);
}

section('2 WebSocket 握手 + 房主分配');
let host = null, guest = null;
{
  try {
    host = await open('t1');
  } catch (e) {
    ok(false, `房主连接失败：${e.message} —— 服务器起了吗？（py net/serve.py --port ${PORT}）`);
    console.log(`\n通过 ${pass} 项，失败 ${fail + 1} 项`);
    process.exit(1);
  }
  const w = await waitFor(host.inbox, (m) => m.t === 'welcome');
  ok(!!w, '★ 握手成功，收到 welcome（说明手写的 RFC 6455 握手可用）');
  ok(w && w.isHost === true, `第一个进房间的是房主（isHost=${w && w.isHost}）`);
  ok(w && w.faction === 'p1', `房主阵营是 p1（faction=${w && w.faction}）`);

  guest = await open('t1');
  const wg = await waitFor(guest.inbox, (m) => m.t === 'welcome');
  ok(!!wg, '客机也收到 welcome');
  ok(wg && wg.isHost === false, `第二个进房间的是客机（isHost=${wg && wg.isHost}）`);
  ok(wg && wg.faction === 'p2', `客机阵营是 p2（faction=${wg && wg.faction}）`);
  ok(wg && Array.isArray(wg.roster) && wg.roster.indexOf('p1') >= 0 && wg.roster.indexOf('p2') >= 0,
    `welcome 带上了房间阵营表（${wg && JSON.stringify(wg.roster)}）`);

  const peerNotice = await waitFor(host.inbox, (m) => m.t === 'peer' && m.event === 'join');
  ok(!!peerNotice, '房主收到「有玩家加入」通知');
}

section('3 命令路由：cmd 只给房主');
{
  host.inbox.length = 0;
  guest.inbox.length = 0;

  const cmd = { t: 'cmd', kind: 'move', f: 'p2', ids: ['general-p2-1'], x: 100.5, y: 200.25 };
  guest.ws.send(JSON.stringify(cmd));

  const got = await waitFor(host.inbox, (m) => m.t === 'cmd');
  ok(!!got, '★ 房主收到了客机的 cmd（中继规则 1 生效）');
  ok(got && got.kind === 'move' && got.ids[0] === 'general-p2-1', 'cmd 内容完整转发');
  ok(got && got.f === 'p2', `★ 服务器给 cmd 盖上了发送者阵营（f=${got && got.f}）`);
  ok(got && got.from, `附带了发送者 id（from=${got && got.from}）`);

  await sleep(200);
  ok(guest.inbox.filter((m) => m.t === 'cmd').length === 0,
    '客机没有收到自己发的 cmd（没有回环广播）');
}

section('4 快照广播：snap 给其他所有人');
{
  host.inbox.length = 0;
  guest.inbox.length = 0;

  // 大消息：触发 126 扩展长度分支
  const big = {
    t: 'snap',
    s: {
      units: Array.from({ length: 40 }, (_, i) => ({
        i: `general-p${(i % 2) + 1}-${i}`, f: (i % 2) ? 'p2' : 'p1', k: 'general',
        x: 1234.56 + i, y: 789.01 + i, h: 200, m: 0, fa: 1, hk: String(i % 3 + 1),
      })),
      buildings: [], zones: [], res: [1, 2], owned: 3, time: 4,
    },
  };
  const payload = JSON.stringify(big);
  host.ws.send(payload);

  const got = await waitFor(guest.inbox, (m) => m.t === 'snap');
  ok(!!got, '★ 客机收到了房主的 snap（中继规则 2 生效）');
  ok(got && got.s.units.length === 40,
    `★ 大消息（${payload.length}B > 125）正确收发 —— 126 扩展长度分支可用`);

  await sleep(200);
  ok(host.inbox.filter((m) => m.t === 'snap').length === 0,
    '房主没有收到自己发的 snap（不回环）');
}

section('5 客机不能冒充房主广播');
{
  guest.inbox.length = 0;
  host.inbox.length = 0;
  guest.ws.send(JSON.stringify({ t: 'snap', s: { units: [], buildings: [], zones: [] } }));
  await sleep(300);
  ok(guest.inbox.filter((m) => m.t === 'snap').length === 0,
    '★ 客机发的 snap 被服务器丢弃（非房主不能广播快照）');
  ok(host.inbox.filter((m) => m.t === 'snap').length === 0,
    '房主也没有收到客机伪造的 snap');
}

section('6 离开房间的通知');
{
  // ★ 必须在**同一个房间**里观察：leave 只会发给同房间的其他人
  const stayer = await open('t2');
  await waitFor(stayer.inbox, (m) => m.t === 'welcome');

  const leaver = await open('t2');
  await waitFor(leaver.inbox, (m) => m.t === 'welcome');
  await waitFor(stayer.inbox, (m) => m.t === 'peer' && m.event === 'join');
  stayer.inbox.length = 0;          // 清掉 join 通知，只看 leave

  leaver.ws.close();
  const left = await waitFor(stayer.inbox, (m) => m.t === 'peer' && m.event === 'leave', 3000);
  ok(!!left, `同房间的人收到 leave 通知（peers=${left && left.peers}）`);
  ok(left && left.peers === 1, `通知里人数正确递减到 1`);

  // 房主掉线 → 剩下的人接任（否则这局没人跑权威逻辑）
  const h2 = await open('t4');
  await waitFor(h2.inbox, (m) => m.t === 'welcome');
  const g2 = await open('t4');
  const wg2 = await waitFor(g2.inbox, (m) => m.t === 'welcome');
  ok(wg2 && wg2.isHost === false, 't4 房间里 g2 是客机');
  g2.inbox.length = 0;

  h2.ws.close();
  const promoted = await waitFor(g2.inbox, (m) => m.t === 'welcome' && m.isHost === true, 3000);
  ok(!!promoted, '★ 房主掉线后，客机被提升为新房主（这局不会因此停摆）');
  g2.ws.close();
  stayer.ws.close();
}

section('7 房间隔离');
{
  const other = await open('t3');
  const w = await waitFor(other.inbox, (m) => m.t === 'welcome');
  ok(w && w.isHost === true, '新房间里第一个人也是房主（房间互相隔离）');
  ok(w && w.peers === 1, `新房间人数为 1（peers=${w && w.peers}）`);
  other.ws.close();
}

section('8 准备界面：ready 广播 / start 只认房主');
{
  // 新开一个干净房间，避免被前面的连接干扰
  const rHost = await open('t5');
  const wHost = await waitFor(rHost.inbox, (m) => m.t === 'welcome');
  const rGuest = await open('t5');
  const wGuest = await waitFor(rGuest.inbox, (m) => m.t === 'welcome');
  ok(wHost && wGuest && wHost.isHost && !wGuest.isHost, '准备界面房间里房主 / 客机身份正确');

  // ready：客机点准备 → 房主应当收到，且带服务器盖章的阵营
  rHost.inbox.length = 0; rGuest.inbox.length = 0;
  rGuest.ws.send(JSON.stringify({ t: 'ready', ready: true }));
  const rMsg = await waitFor(rHost.inbox, (m) => m.t === 'ready');
  ok(!!rMsg && rMsg.ready === true, '★ 客机的 ready 转发给了房主');
  ok(rMsg && rMsg.f === 'p2', `★ 服务器给 ready 盖上了发送者阵营（f=${rMsg && rMsg.f}）`);

  // ready 是广播：客机自己也能收到（用它刷新"谁准备好了"）
  const echo = await waitFor(rGuest.inbox, (m) => m.t === 'ready');
  ok(!!echo, 'ready 也会回到发送者本人（用于刷新界面）');

  // start：房主宣布开战 → 客机收到
  rGuest.inbox.length = 0;
  rHost.ws.send(JSON.stringify({ t: 'start', countdown: 3 }));
  const sMsg = await waitFor(rGuest.inbox, (m) => m.t === 'start');
  ok(!!sMsg && sMsg.countdown === 3, '★ 房主的 start 广播给了客机（含倒计时秒数）');

  // start：客机冒充房主宣布开战 → 必须被丢弃
  rHost.inbox.length = 0; rGuest.inbox.length = 0;
  rGuest.ws.send(JSON.stringify({ t: 'start', countdown: 0 }));
  await sleep(300);
  ok(rHost.inbox.filter((m) => m.t === 'start').length === 0,
    '★ 客机发的 start 被丢弃（只有房主能宣布开战）');

  rHost.ws.close(); rGuest.ws.close();
}

for (const c of [host, guest]) { try { c.ws.close(); } catch {} }
await sleep(200);

console.log(`\n———————————————\n通过 ${pass} 项，失败 ${fail} 项`);
process.exit(fail ? 1 : 0);
