/**
 * tools/net-load-test.mjs —— 多人同时连的负载测试（需要先起服务器）
 * 运行：py net/serve.py --port 8097   然后   node tools/net-load-test.mjs 8097 [人数]
 *
 * 目标里写的是「多人同屏」，但之前的测试最多只连了 2 个客户端。
 * 这个脚本验证：满员（8 个席位）、持续 20Hz 快照时，服务器会不会丢消息 / 变慢 /
 * 撑不住 —— 也就是回答「小水管服务器到底能带几个人」。
 *
 * 测法：
 *   · 开 1 个房主 + N-1 个客机，全部进同一个房间
 *   · 房主按真实体积（约 1.6KB/条）持续发 snap，客机按真实频率发 cmd
 *   · 统计每个人的收包数、丢包、最大间隔、总吞吐
 */

const PORT = process.argv[2] || '8097';
const N = Math.max(2, Math.min(8, Number(process.argv[3] || 6)));
const WSU = `ws://127.0.0.1:${PORT}/ws`;
const DURATION_MS = 4000;
const SNAP_HZ = 20;

let pass = 0, fail = 0;
const ok = (cond, msg) => {
  if (cond) { pass++; console.log(`  ✔ ${msg}`); }
  else { fail++; console.log(`  ✘ ${msg}`); }
};
const section = (t) => console.log(`\n== ${t} ==`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 一份接近真实体积的快照：6 个单位 + 22 段城墙 + 24 个区块 */
function realSnapshot(i) {
  return {
    t: 'snap',
    s: {
      units: Array.from({ length: 6 }, (_, k) => ({
        i: `general-p${(k % 2) + 1}-${k}`, f: (k % 2) ? 'p2' : 'p1', k: 'general',
        x: 1000.25 + k * 37 + i, y: 800.5 + k * 21, h: 200 - k, m: 0, fa: 1, hk: '1',
      })),
      buildings: Array.from({ length: 22 }, (_, k) => ({
        t: 'wall', x: 5 + (k % 10), y: 5 + Math.floor(k / 10), o: 'p1', h: 300 - k,
      })),
      zones: Array.from({ length: 24 }, (_, k) => ({ o: k < 4 ? 'p1' : null, p: k < 4 ? 1 : 0 })),
      res: [12.5, 7.25], owned: 32, time: 10 + i * 0.05,
    },
  };
}

class Client {
  constructor(name) {
    this.name = name;
    this.inbox = [];
    this.lastAt = 0;
    this.maxGap = 0;
    this.bytes = 0;
    this.ws = null;
    this.welcome = null;
  }
  async open(room) {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(WSU);
      this.ws = ws;
      const timer = setTimeout(() => reject(new Error(`${this.name} 连接超时`)), 5000);
      ws.addEventListener('message', (e) => {
        const now = Date.now();
        if (this.lastAt && this.name !== 'host') this.maxGap = Math.max(this.maxGap, now - this.lastAt);
        this.lastAt = now;
        this.bytes += String(e.data).length;
        let m = null;
        try { m = JSON.parse(e.data); } catch {}
        if (m) {
          if (m.t === 'welcome') this.welcome = m;
          this.inbox.push(m);
        }
      });
      ws.addEventListener('open', () => {
        clearTimeout(timer);
        ws.send(JSON.stringify({ t: 'hello', room }));
        setTimeout(resolve, 150);
      });
      ws.addEventListener('error', () => { clearTimeout(timer); reject(new Error(`${this.name} 连接出错`)); });
    });
  }
  send(o) { if (this.ws && this.ws.readyState === 1) this.ws.send(JSON.stringify(o)); }
  close() { try { this.ws.close(); } catch {} }
}

section(`负载测试：${N} 个客户端同房间，持续 ${DURATION_MS / 1000}s @ ${SNAP_HZ}Hz`);

const room = 'load' + Date.now();
const clients = [];
try {
  for (let i = 0; i < N; i++) {
    const c = new Client(i === 0 ? 'host' : `guest${i}`);
    await c.open(room);
    clients.push(c);
  }
} catch (e) {
  ok(false, `连接失败：${e.message} —— 服务器起了吗？（py net/serve.py --port ${PORT}）`);
  console.log(`\n通过 ${pass} 项，失败 ${fail + 1} 项`);
  process.exit(1);
}

const host = clients[0];
const guests = clients.slice(1);
const t0 = Date.now();

// 清掉握手期的计数，只统计稳态
for (const c of clients) { c.inbox.length = 0; c.bytes = 0; c.lastAt = 0; c.maxGap = 0; }

// 服务器分配的阵营应当是 p1..pN
const factions = clients.map((c) => c.welcome && c.welcome.faction);
ok(new Set(factions).size === N,
  `★ ${N} 个客户端各拿到唯一阵营（${factions.join(', ')}）`);
ok(factions[0] === 'p1' && host.welcome.isHost === true, '房主是第 1 个进来的（p1）');
ok(guests.every((g) => g.welcome.isHost === false), `${guests.length} 个客机身份正确`);

// 房主按 20Hz 发快照；客机各按 10Hz 发 cmd（真实玩法下不会这么密，算压力上限）
let snapSent = 0;
let sendWindow = 0;          // ★ 真正在发快照的时间窗，用来算「应该发多少条」
const snapTimer = setInterval(() => {
  host.send(realSnapshot(snapSent));
  snapSent++;
}, 1000 / SNAP_HZ);
const cmdTimers = guests.map((g, i) => setInterval(() => {
  g.send({ t: 'cmd', kind: 'move', f: g.welcome.faction, ids: [`general-${g.welcome.faction}-1`], x: 100 + i, y: 200 });
}, 100));

const winStart = Date.now();
await sleep(DURATION_MS);
const winEnd = Date.now();
sendWindow = (winEnd - winStart) / 1000;
clearInterval(snapTimer);
for (const t of cmdTimers) clearInterval(t);
await sleep(400);   // 等最后几包落地

section('结果');
const elapsed = (winEnd - winStart) / 1000;
/**
 * ★ 基准用「房主实际发出的条数」，而不是「按墙钟时间应该发出的条数」。
 *   setInterval 在 Node 里不保证精确 50ms（尤其在 8 个连接 + 每次 JSON 序列化 2KB 的压力下），
 *   拿理论值当分母会把「本机定时器抖动」误判成「网络丢包」。
 *   真正要验证的是：**发出去的包有没有到**（转发可靠性），不是定时器准不准。
 */
console.log(`  房主实际发出      : ${snapSent} 条快照（${(snapSent / elapsed).toFixed(1)} Hz，目标 ${SNAP_HZ}Hz）`);

const expectedSnaps = snapSent;
for (const g of guests) {
  const snaps = g.inbox.filter((m) => m.t === 'snap').length;
  const lost = Math.max(0, expectedSnaps - snaps);
  ok(snaps >= expectedSnaps * 0.98,
    `${g.name} 收到 ${snaps}/${expectedSnaps} 条快照（丢失 ${lost}，转发丢失率 ${(100 * lost / expectedSnaps).toFixed(1)}%）`);
}

const hostCmds = host.inbox.filter((m) => m.t === 'cmd').length;
// 客机侧同样用「实际发出的计数」不现实（每个客机自己的定时器），这里放宽到 90%
const expectedCmds = guests.length * Math.round(elapsed * 10);
ok(hostCmds >= expectedCmds * 0.9,
  `房主收到 ${hostCmds}/${expectedCmds} 条客机 cmd（${guests.length} 个客机 × 10Hz，含定时器抖动）`);

// 房主不该收到自己的 snap（不回环），客机不该收到自己的 cmd
ok(host.inbox.filter((m) => m.t === 'snap').length === 0, '房主没有收到自己广播的快照（不回环）');
ok(guests.every((g) => g.inbox.filter((m) => m.t === 'cmd').length === 0),
  '客机没有收到自己发的 cmd（不回环）');

// 客机之间不该互相看到对方的 cmd（转发规则：cmd 只给房主）
const guestSnapOnly = guests.every((g) => g.inbox.every((m) => m.t === 'snap' || m.t === 'peer'));
ok(guestSnapOnly, '客机的收件箱里只有 snap（cmd 确实只转发给房主，没广播）');

section('吞吐与延迟');
let totalDown = 0;
for (const g of guests) totalDown += g.bytes;
const downRate = totalDown / elapsed;
const perGuest = downRate / guests.length;
console.log(`  房主上行（估算）: ${(perGuest * guests.length / 1024).toFixed(1)} KB/s`);
console.log(`  每客机下行      : ${(perGuest / 1024).toFixed(1)} KB/s`);
console.log(`  快照单包        : ${(JSON.stringify(realSnapshot(0)).length / 1024).toFixed(2)} KB`);
console.log(`  合计下行        : ${(downRate / 1024).toFixed(1)} KB/s`);

ok(perGuest / 1024 < 60,
  `每客机下行 ${(perGuest / 1024).toFixed(1)} KB/s < 60KB/s（1Mbps 上行能带住）`);

const maxGap = Math.max(...guests.map((g) => g.maxGap));
console.log(`  最大快照间隔    : ${maxGap} ms（理想 ${(1000 / SNAP_HZ).toFixed(0)} ms）`);
ok(maxGap < 1000,
  `最大快照间隔 ${maxGap}ms < 1s（没有卡死或长时间断流）`);

ok(clients.every((c) => c.ws.readyState === 1),
  `★ ${N} 个连接在负载下全部保持存活（没有被动断开）`);

for (const c of clients) c.close();
await sleep(200);

console.log(`\n———————————————\n通过 ${pass} 项，失败 ${fail} 项`);
process.exit(fail ? 1 : 0);
