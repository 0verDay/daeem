/**
 * util.js —— 通用小工具 + 四连通网格容器
 */

export const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
export const lerp = (a, b, t) => a + (b - a) * t;
export const dist = (ax, ay, bx, by) => Math.hypot(ax - bx, ay - by);
export const manhattan = (ax, ay, bx, by) => Math.abs(ax - bx) + Math.abs(ay - by);

/** 四连通方向（上、右、下、左）—— 本游戏地图为四连通 */
export const DIRS4 = [
  { dx: 0, dy: -1 },
  { dx: 1, dy: 0 },
  { dx: 0, dy: 1 },
  { dx: -1, dy: 0 },
];

export const inBounds = (grid, x, y) => x >= 0 && y >= 0 && x < grid.cols && y < grid.rows;
export const idx = (grid, x, y) => y * grid.cols + x;

/** 二维网格：底层一维数组，避免越界崩溃 */
export class Grid {
  constructor(cols, rows, fill = null) {
    this.cols = cols;
    this.rows = rows;
    this.data = new Array(cols * rows).fill(fill);
  }
  get(x, y) {
    if (!inBounds(this, x, y)) return null;
    return this.data[y * this.cols + x];
  }
  set(x, y, v) {
    if (!inBounds(this, x, y)) return false;
    this.data[y * this.cols + x] = v;
    return true;
  }
  has(x, y) {
    return inBounds(this, x, y);
  }
  /** 遍历所有格子：fn(x, y, value) */
  forEach(fn) {
    for (let y = 0; y < this.rows; y++) {
      for (let x = 0; x < this.cols; x++) fn(x, y, this.data[y * this.cols + x]);
    }
  }
  countWhere(fn) {
    let n = 0;
    this.forEach((x, y, v) => { if (fn(v, x, y)) n++; });
    return n;
  }
  clone() {
    const g = new Grid(this.cols, this.rows);
    g.data = this.data.slice();
    return g;
  }
}

/** 像素坐标 -> 地块坐标 */
export function toTile(px, py, cell) {
  return { x: Math.floor(px / cell), y: Math.floor(py / cell) };
}
/** 地块坐标 -> 该地块中心点的像素坐标 */
export function tileCenter(tx, ty, cell) {
  return { x: (tx + 0.5) * cell, y: (ty + 0.5) * cell };
}

/** 极简二叉堆优先队列（A* 用） */
export class MinHeap {
  constructor(scoreFn) {
    this.items = [];
    this.score = scoreFn;
  }
  get size() { return this.items.length; }
  push(item) {
    const a = this.items;
    a.push(item);
    let i = a.length - 1;
    while (i > 0) {
      const p = (i - 1) >> 1;
      if (this.score(a[p]) <= this.score(a[i])) break;
      [a[p], a[i]] = [a[i], a[p]];
      i = p;
    }
  }
  pop() {
    const a = this.items;
    if (a.length === 0) return null;
    const top = a[0];
    const last = a.pop();
    if (a.length > 0) {
      a[0] = last;
      let i = 0;
      for (;;) {
        const l = i * 2 + 1, r = l + 1;
        let m = i;
        if (l < a.length && this.score(a[l]) < this.score(a[m])) m = l;
        if (r < a.length && this.score(a[r]) < this.score(a[m])) m = r;
        if (m === i) break;
        [a[m], a[i]] = [a[i], a[m]];
        i = m;
      }
    }
    return top;
  }
}

/** 判断某点是否落在矩形内 */
export function pointInRect(px, py, x0, y0, x1, y1) {
  return px >= x0 && px <= x1 && py >= y0 && py <= y1;
}
