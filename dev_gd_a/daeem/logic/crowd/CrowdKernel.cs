using Godot;

namespace Daeem.Crowd;

/// <summary>
/// 群体碰撞内核（方案里的 K2）：空间哈希 + 软分离推挤 + 建筑本体推出。
///
/// ★ 为什么必须有它（实测，1000 单位 / 100×100 图）：
///   `CollisionRes.resolve()` 每帧跑 n(n-1)/2 × iterations 对，
///   1000 单位 = 50 万对 × 3 轮 = 150 万次「取距离 + 判重叠」→ 实测 **605 ms/帧**
///   （占每帧逻辑 614 ms 的 98.5%，折合 1.6 fps）。分桶之后每帧只看同桶 + 相邻桶。
///
/// ★ 接口按「批」划，不按「单位」划：实测 1000 次跨语言小调用 = 518 µs/帧，
///   1 次批量调用 = 4.8 µs/帧（差 108 倍）。所以进出都是整条 Packed 数组。
///
/// ★★ 语义必须与 logic/collision.gd **完全一致**（手感与回归测试都挂在这上面）：
///   · 软分离：重叠量按权重反比分配（有命令的推得动待命的）；
///   · 推开后的位置必须站得住（山 / 敌方城墙 / 建筑本体），站不住就沿轴滑动；
///   · 推挤只改位置，不碰 path / moving / goal；
///   · 圆心完全重合时方向取 +X（与 GDScript 版同一个退化处理）；
///   · 配对顺序仍是「i 升序、j 升序」，连锁重叠时的结果才不会变。
///
/// ⚠️ 内部一律 double：GDScript 的 float 是 64 位，Godot 的 Vector2 是 32 位。
///    用 float 算中间量会和 GDScript 版差出一点点，位置类断言就会莫名变红。
/// </summary>
[GlobalClass]
public partial class CrowdKernel : RefCounted
{
    // ------------------------------------------------------------------
    // 静态通行表（只在 building_revision 变化时重建）
    // ------------------------------------------------------------------

    private int _cols;
    private int _rows;
    private int _tileCount;

    /// <summary>地形级阻挡：1 = 图外或山（与阵营无关）。</summary>
    private byte[] _terrainBlocked;

    /// <summary>按阵营的格级阻挡：布局 [faction][y * cols + x]，1 = 不可通行。</summary>
    private byte[] _tileBlocked;
    private int _factionCount;

    /// <summary>每格上的建筑本体下标（-1 = 没有）。项目保证每格最多一个建筑。</summary>
    private int[] _bodyAtTile = new int[0];
    private double[] _bodyCx = new double[0];
    private double[] _bodyCy = new double[0];
    private double[] _bodyHalf = new double[0];
    private int[] _bodyMask = new int[0]; // 位 f = 该本体挡阵营 f

    private const double PushEps = 1e-6;

    // ------------------------------------------------------------------
    // 空间哈希（每帧重建，只覆盖「有活单位的包围盒」）
    // ------------------------------------------------------------------

    private double _cellSize = 1.0;
    private double _originX;
    private double _originY;
    private int _cellCols = 1;
    private int _cellRows = 1;
    private int[] _cellStart = new int[2];
    private int[] _cellCursor = new int[2];
    private int[] _cellItems = new int[0];
    private int[] _bucketOf = new int[0];
    private int[] _candBuf = new int[64];


    // ==================================================================
    // 建表
    // ==================================================================

    /// <summary>建地形表。地图不变时只调用一次。</summary>
    public void SetupTerrain(int cols, int rows, byte[] terrainBlocked)
    {
        _cols = cols;
        _rows = rows;
        _tileCount = cols * rows;
        _terrainBlocked = terrainBlocked;
        if (_bodyAtTile.Length != _tileCount)
        {
            _bodyAtTile = new int[_tileCount];
            for (int i = 0; i < _tileCount; i++)
            {
                _bodyAtTile[i] = -1;
            }
        }
    }

    /// <summary>
    /// 建「按阵营的格级阻挡」表（building_revision 变化时才调用）。
    ///
    /// ★★ 为什么参数是「每格的建筑阻挡掩码」而不是现成的整张表：
    ///    GDScript 那边逐格调 `passable()` 来填表 = factionCount × cols × rows 次跨语言+函数调用
    ///    （100×100 × 2 阵营 = 2 万次，实测 **~70 ms**）——而且它会在**每次建/拆建筑之后**
    ///    重跑一遍，也就是每盖一堵墙卡一下。
    ///    改成：GDScript 只遍历**建筑**（几十个）算出掩码，整张表由 C# 一遍填完（~1 ms）。
    /// </summary>
    /// <param name="factionCount">阵营个数</param>
    /// <param name="blockerMask">长度 cols*rows；位 f = 该格上的建筑挡阵营 f（没有建筑 = 0）</param>
    public void SetupTileBlockers(int factionCount, int[] blockerMask)
    {
        _factionCount = factionCount;
        int n = factionCount > 0 ? factionCount : 1;
        if (_tileBlocked == null || _tileBlocked.Length != n * _tileCount)
        {
            _tileBlocked = new byte[n * _tileCount];
        }
        for (int f = 0; f < factionCount; f++)
        {
            int bit = 1 << f;
            int baseIdx = f * _tileCount;
            for (int i = 0; i < _tileCount; i++)
            {
                // 地形挡住 → 挡；否则看这一格上的建筑挡不挡这个阵营
                bool blocked = (_terrainBlocked != null && _terrainBlocked[i] != 0)
                    || ((blockerMask[i] & bit) != 0);
                _tileBlocked[baseIdx + i] = blocked ? (byte)1 : (byte)0;
            }
        }
    }

    /// <summary>建建筑本体表（building_revision 变化时才调用）。</summary>
    public void SetupBodies(int[] bodyAtTile, double[] cx, double[] cy, double[] half, int[] mask)
    {
        _bodyAtTile = bodyAtTile;
        _bodyCx = cx;
        _bodyCy = cy;
        _bodyHalf = half;
        _bodyMask = mask;
    }


    // ==================================================================
    // 每帧：单位之间的软分离（对应 collision.gd 的 resolve）
    // ==================================================================

    /// <summary>
    /// 一帧把「单位之间的软分离」+「把单位从建筑本体里推出来」一次做完。
    ///
    /// ★ 为什么要合成一个入口：分成两次调用时，GDScript 那边每帧要塞两遍
    ///   1000 个单位的数组、再写回两遍（`_pack` / `_unpack` 各跑两次）。实测
    ///   碰撞段 2.07 ms 里有相当一部分就是这个打包/解包，而不是计算本身。
    /// </summary>
    public double[] ResolveAll(double[] xy, int[] faction, double[] weight, byte[] alive, int count,
                               double radius, double allowance, double slack, int iterations)
    {
        double[] p = Resolve(xy, faction, weight, alive, count, radius, allowance, slack, iterations);
        p = ResolveBodies(p, faction, alive, count, radius, iterations);
        return p;
    }

    /// <summary>参与过推挤的对数（测试/调试用）。</summary>
    public int StatsPairs { get; private set; }

    /// <summary>真的动过的单位数。</summary>
    public int StatsPushed { get; private set; }

    /// <summary>实际检查过的邻居对数量（用来验证分桶真的把 O(n²) 砍掉了）。</summary>
    public int StatsExamined { get; private set; }

    /// <param name="xy">长度 2n：[x0,y0,x1,y1,…]；**入参不被修改**，结果从返回值拿</param>
    /// <param name="faction">长度 n：阵营下标</param>
    /// <param name="weight">长度 n：推挤权重（GDScript 侧算好，等价于 collision.gd 的 _weight）</param>
    /// <param name="alive">长度 n：0 = 阵亡（跳过）</param>
    /// <returns>长度 2n 的新位置</returns>
    public double[] Resolve(double[] xy, int[] faction, double[] weight, byte[] alive, int count,
                            double radius, double allowance, double slack, int iterations)
    {
        var pos = new double[count * 2];
        System.Array.Copy(xy, pos, count * 2);

        StatsPairs = 0;
        StatsPushed = 0;
        StatsExamined = 0;

        if (count <= 0 || radius <= 0.0)
        {
            return pos;
        }
        double minDist = radius * 2.0 * allowance;
        if (minDist <= 0.0)
        {
            return pos;
        }
        _standRadius = radius;

        var touched = new byte[count];

        for (int it = 0; it < iterations; it++)
        {
            if (!BuildHash(pos, alive, count, minDist))
            {
                break; // 没有活单位
            }

            bool any = false;
            for (int i = 0; i < count; i++)
            {
                if (alive[i] == 0)
                {
                    continue;
                }
                int cand = GatherCandidates(pos, i, alive);
                // ★ 按 j 升序处理：与 GDScript 版「i 升序、j 从 i+1 升序」的配对顺序一致，
                //   多单位连锁重叠时的最终位置才不变（手感不变）。
                SortAscending(cand);

                for (int k = 0; k < cand; k++)
                {
                    int j = _candBuf[k];
                    if (j <= i || alive[j] == 0)
                    {
                        continue;
                    }
                    StatsExamined++;
                    if (Separate(pos, faction, weight, alive, i, j, minDist, slack))
                    {
                        any = true;
                        StatsPairs++;
                        touched[i] = 1;
                        touched[j] = 1;
                    }
                }
            }

            if (!any)
            {
                break; // 没有重叠了，提前收工
            }
        }

        int pushed = 0;
        for (int i = 0; i < count; i++)
        {
            if (touched[i] != 0)
            {
                pushed++;
            }
        }
        StatsPushed = pushed;
        return pos;
    }


    /// <summary>把一对重叠的单位分开。逐条对应 collision.gd 的 `_separate()`。</summary>
    private bool Separate(double[] pos, int[] faction, double[] weight, byte[] alive,
                          int a, int b, double minDist, double slack)
    {
        double ax = pos[a * 2], ay = pos[a * 2 + 1];
        double bx = pos[b * 2], by = pos[b * 2 + 1];
        double dx = bx - ax;
        double dy = by - ay;
        double d = System.Math.Sqrt(dx * dx + dy * dy);

        if (d >= minDist - slack)
        {
            return false;
        }
        double overlap = minDist - d;

        // 圆心完全重合时没有方向可用 —— 与 GDScript 版一致，取固定方向 +X
        double dirx = 1.0, diry = 0.0;
        if (d > 1e-6)
        {
            dirx = dx / d;
            diry = dy / d;
        }

        double wa = weight[a];
        double wb = weight[b];
        double total = wa + wb;
        if (total <= 1e-6)
        {
            // 两边权重都是 0（配置写错）→ 退回各推一半，别让这条规则静默失效
            wa = 1.0;
            wb = 1.0;
            total = 2.0;
        }

        // 权重越大承担越少：把 overlap 反比分配
        double moveAx = -dirx * (overlap * (wb / total));
        double moveAy = -diry * (overlap * (wb / total));
        double moveBx = dirx * (overlap * (wa / total));
        double moveBy = diry * (overlap * (wa / total));

        // 分开施加：能站住就直接推，站不住就沿墙滑动
        bool aMoved = TryMove(pos, faction, alive, a, moveAx, moveAy);
        bool bMoved = TryMove(pos, faction, alive, b, moveBx, moveBy);
        return aMoved || bMoved;
    }


    // ==================================================================
    // 每帧：把单位从建筑本体的硬障碍里推出来（对应 resolve_buildings）
    // ==================================================================

    public double[] ResolveBodies(double[] xy, int[] faction, byte[] alive, int count,
                                  double radius, int iterations)
    {
        var pos = new double[count * 2];
        System.Array.Copy(xy, pos, count * 2);

        StatsPushed = 0;
        if (count <= 0)
        {
            return pos;
        }
        _standRadius = radius;

        for (int it = 0; it < iterations; it++)
        {
            bool any = false;
            for (int i = 0; i < count; i++)
            {
                if (alive[i] == 0)
                {
                    continue;
                }
                if (!NearestBodyPushOut(pos, faction, i, radius, out double px, out double py))
                {
                    continue;
                }
                if (TryMove(pos, faction, alive, i, px, py))
                {
                    any = true;
                    StatsPushed++;
                }
            }
            if (!any)
            {
                break;
            }
        }
        return pos;
    }

    /// <summary>
    /// 单位若与某个「挡它的」本体重叠，给出推到最近空处的位移。
    /// 同时压着两块本体时只挑穿透最深的（下一轮会处理另一块），与 GDScript 版一致。
    /// </summary>
    private bool NearestBodyPushOut(double[] pos, int[] faction, int i, double r,
                                    out double pushX, out double pushY)
    {
        pushX = 0.0;
        pushY = 0.0;
        if (_bodyMask.Length == 0)
        {
            return false;
        }
        double pxx = pos[i * 2], pyy = pos[i * 2 + 1];
        int tx = (int)System.Math.Floor(pxx);
        int ty = (int)System.Math.Floor(pyy);
        int f = faction[i];
        double deepest = 0.0;

        for (int dy = -1; dy <= 1; dy++)
        {
            int yy = ty + dy;
            if (yy < 0 || yy >= _rows)
            {
                continue;
            }
            for (int dx = -1; dx <= 1; dx++)
            {
                int xx = tx + dx;
                if (xx < 0 || xx >= _cols)
                {
                    continue;
                }
                int bi = _bodyAtTile[yy * _cols + xx];
                if (bi < 0 || !BodyBlocks(bi, f))
                {
                    continue;
                }
                double half = _bodyHalf[bi];
                double zx = _bodyCx[bi] - half - r;
                double zy = _bodyCy[bi] - half - r;
                double zex = _bodyCx[bi] + half + r;
                double zey = _bodyCy[bi] + half + r;
                if (!(pxx >= zx && pxx <= zex && pyy >= zy && pyy <= zey))
                {
                    continue;
                }
                double left = pxx - zx;
                double right = zex - pxx;
                double top = pyy - zy;
                double bottom = zey - pyy;
                double m = System.Math.Min(System.Math.Min(left, right), System.Math.Min(top, bottom));

                double ox = 0.0, oy = 0.0;
                if (m == left)
                {
                    ox = -(left + PushEps);
                }
                else if (m == right)
                {
                    ox = right + PushEps;
                }
                else if (m == top)
                {
                    oy = -(top + PushEps);
                }
                else
                {
                    oy = bottom + PushEps;
                }
                double depth = System.Math.Sqrt(ox * ox + oy * oy);
                if (depth > deepest + 1e-9)
                {
                    deepest = depth;
                    pushX = ox;
                    pushY = oy;
                }
            }
        }
        return deepest > 0.0;
    }

    private bool BodyBlocks(int bi, int faction)
    {
        if (bi < 0 || bi >= _bodyMask.Length || faction < 0 || faction >= 32)
        {
            return false;
        }
        return (_bodyMask[bi] & (1 << faction)) != 0;
    }


    // ==================================================================
    // 位置合法性：对应 collision.gd 的 `_can_stand()` / `body_blocked_at()`
    // ==================================================================

    /// <summary>_can_stand 用的外扩量（= 碰撞半径，每次入口同步一次）。</summary>
    private double _standRadius = 0.18;

    private bool CanStand(int[] faction, int i, double pxx, double pyy)
    {
        int tx = (int)System.Math.Floor(pxx);
        int ty = (int)System.Math.Floor(pyy);
        if (tx < 0 || ty < 0 || tx >= _cols || ty >= _rows)
        {
            return false;
        }
        int idx = ty * _cols + tx;
        if (_terrainBlocked != null && _terrainBlocked[idx] != 0)
        {
            return false;
        }
        int f = faction[i];
        if (_tileBlocked != null && f >= 0 && f < _factionCount)
        {
            if (_tileBlocked[f * _tileCount + idx] != 0)
            {
                return false;
            }
        }
        return !BodyBlockedAt(f, pxx, pyy);
    }

    /// <summary>某个点是否落在「挡这个阵营」的建筑本体里（扫 3×3 邻格，含半径外扩）。</summary>
    private bool BodyBlockedAt(int f, double pxx, double pyy)
    {
        if (_bodyMask.Length == 0)
        {
            return false;
        }
        int tx = (int)System.Math.Floor(pxx);
        int ty = (int)System.Math.Floor(pyy);
        double r = _standRadius;
        for (int dy = -1; dy <= 1; dy++)
        {
            int yy = ty + dy;
            if (yy < 0 || yy >= _rows)
            {
                continue;
            }
            for (int dx = -1; dx <= 1; dx++)
            {
                int xx = tx + dx;
                if (xx < 0 || xx >= _cols)
                {
                    continue;
                }
                int bi = _bodyAtTile[yy * _cols + xx];
                if (bi < 0 || !BodyBlocks(bi, f))
                {
                    continue;
                }
                double half = _bodyHalf[bi];
                double zx = _bodyCx[bi] - half - r;
                double zy = _bodyCy[bi] - half - r;
                double zex = _bodyCx[bi] + half + r;
                double zey = _bodyCy[bi] + half + r;
                if (pxx >= zx && pxx <= zex && pyy >= zy && pyy <= zey)
                {
                    return true;
                }
            }
        }
        return false;
    }

    /// <summary>
    /// 尝试把单位推走 move 这个位移；推不动就沿墙滑动（只保留一个轴）。
    /// 逐条对应 collision.gd 的 `_try_move()`。
    /// </summary>
    private bool TryMove(double[] pos, int[] faction, byte[] alive, int i, double mx, double my)
    {
        if (mx * mx + my * my <= 1e-12)
        {
            return false;
        }
        if (alive != null && alive[i] == 0)
        {
            return false;
        }
        double pxx = pos[i * 2];
        double pyy = pos[i * 2 + 1];

        if (CanStand(faction, i, pxx + mx, pyy + my))
        {
            pos[i * 2] = pxx + mx;
            pos[i * 2 + 1] = pyy + my;
            return true;
        }
        if (System.Math.Abs(mx) > 1e-9 && CanStand(faction, i, pxx + mx, pyy))
        {
            pos[i * 2] = pxx + mx;
            return true;
        }
        if (System.Math.Abs(my) > 1e-9 && CanStand(faction, i, pxx, pyy + my))
        {
            pos[i * 2 + 1] = pyy + my;
            return true;
        }
        return false;
    }


    // ==================================================================
    // 空间哈希
    //
    // ★ 网格只铺「有活单位的包围盒」，不是整张地图：桶宽必须 ≤ 最小圆心距才不漏邻居，
    //   而 100×100 的图上按 0.25 格开桶就是 16 万个格子 —— 每帧清三遍纯属浪费。
    //   单位挤在一小块时包围盒很小，网格也就很小；铺满全图时密度必然低，
    //   那时候格子多但每格几乎没人，两边都不亏。
    // ==================================================================

    /// <returns>false = 没有活单位</returns>
    private bool BuildHash(double[] pos, byte[] alive, int count, double minDist)
    {
        _cellSize = minDist > 1e-6 ? minDist : 1e-6;

        double minX = double.MaxValue, minY = double.MaxValue;
        double maxX = double.MinValue, maxY = double.MinValue;
        int nAlive = 0;
        for (int i = 0; i < count; i++)
        {
            if (alive[i] == 0)
            {
                continue;
            }
            double px = pos[i * 2], py = pos[i * 2 + 1];
            if (px < minX) { minX = px; }
            if (px > maxX) { maxX = px; }
            if (py < minY) { minY = py; }
            if (py > maxY) { maxY = py; }
            nAlive++;
        }
        if (nAlive == 0)
        {
            return false;
        }

        _originX = System.Math.Floor(minX / _cellSize) * _cellSize;
        _originY = System.Math.Floor(minY / _cellSize) * _cellSize;
        _cellCols = (int)((maxX - _originX) / _cellSize) + 1;
        _cellRows = (int)((maxY - _originY) / _cellSize) + 1;
        int cells = _cellCols * _cellRows + 1; // +1：0 号桶留给阵亡单位

        if (_cellStart.Length < cells + 1)
        {
            _cellStart = new int[cells + 1];
            _cellCursor = new int[cells + 1];
        }
        if (_cellItems.Length < count)
        {
            _cellItems = new int[count];
            _bucketOf = new int[count];
        }
        System.Array.Clear(_cellStart, 0, cells + 1);

        for (int i = 0; i < count; i++)
        {
            int b = alive[i] == 0 ? 0 : BucketOf(pos[i * 2], pos[i * 2 + 1]);
            _bucketOf[i] = b;
            _cellStart[b + 1]++;
        }
        for (int c = 0; c < cells; c++)
        {
            _cellStart[c + 1] += _cellStart[c];
        }
        System.Array.Copy(_cellStart, _cellCursor, cells + 1);
        for (int i = 0; i < count; i++)
        {
            if (alive[i] == 0)
            {
                continue;
            }
            int b = _bucketOf[i];
            _cellItems[_cellCursor[b]++] = i;
        }
        return true;
    }

    private int BucketOf(double pxx, double pyy)
    {
        int cx = (int)((pxx - _originX) / _cellSize);
        int cy = (int)((pyy - _originY) / _cellSize);
        if (cx < 0) { cx = 0; }
        if (cy < 0) { cy = 0; }
        if (cx >= _cellCols) { cx = _cellCols - 1; }
        if (cy >= _cellRows) { cy = _cellRows - 1; }
        return cy * _cellCols + cx + 1;
    }

    /// <summary>收集可能与 i 重叠的邻居（不含 i）。桶宽 = 最小圆心距，所以 3×3 足够。</summary>
    private int GatherCandidates(double[] pos, int i, byte[] alive)
    {
        int cx = (int)((pos[i * 2] - _originX) / _cellSize);
        int cy = (int)((pos[i * 2 + 1] - _originY) / _cellSize);
        int n = 0;
        for (int dy = -1; dy <= 1; dy++)
        {
            int yy = cy + dy;
            if (yy < 0 || yy >= _cellRows)
            {
                continue;
            }
            for (int dx = -1; dx <= 1; dx++)
            {
                int xx = cx + dx;
                if (xx < 0 || xx >= _cellCols)
                {
                    continue;
                }
                int b = yy * _cellCols + xx + 1;
                int s = _cellStart[b];
                int e = _cellStart[b + 1];
                for (int k = s; k < e; k++)
                {
                    int j = _cellItems[k];
                    if (j == i || alive[j] == 0)
                    {
                        continue;
                    }
                    if (n >= _candBuf.Length)
                    {
                        System.Array.Resize(ref _candBuf, _candBuf.Length * 2);
                    }
                    _candBuf[n++] = j;
                }
            }
        }
        return n;
    }

    /// <summary>按单位下标升序排（插入排序：候选通常只有几个）。</summary>
    private void SortAscending(int n)
    {
        for (int i = 1; i < n; i++)
        {
            int v = _candBuf[i];
            int j = i - 1;
            while (j >= 0 && _candBuf[j] > v)
            {
                _candBuf[j + 1] = _candBuf[j];
                j--;
            }
            _candBuf[j + 1] = v;
        }
    }


    // ==================================================================
    // 寻路：距离场（Dijkstra）+ 顺场下降 + 可达掩码
    //
    // ★ 为什么要有这一段（实测，100×100 图、58 步的一条路）：
    //     find_path（A*，open list 还是线性扫）  19.0 ms / 次
    //     reachable_tiles（GDScript 全图 BFS）  131.8 ms / 次
    //   → 1000 个单位群编 = 1000 次 A* = 17 秒的命令帧冻结。
    //   代价口径必须与 logic/pathfinder.gd **逐条一致**（通行、对角守卫、地形代价、
    //   建筑惩罚），否则会出现「场说能走、A* 说不能」那种不一致
    //   （docs/pitfalls.md 3.3 的同一个坑）。对齐关系写在每个分支的注释里。
    // ==================================================================

    private double[] _moveCost = new double[0];
    private byte[] _penaltyTiles = new byte[0];
    private double _penaltyValue = 12.0;
    private byte[] _hasBuilding = new byte[0];
    private bool _diag = true;
    private bool _cornerCut = false;
    private double _unitRadius = 0.18;

    private const double Inf = 1e30;
    private const double StepDiag = 1.4142135623730951;

    private static readonly int[] Dx8 = { 0, 1, 0, -1, 1, 1, -1, -1 };
    private static readonly int[] Dy8 = { -1, 0, 1, 0, -1, 1, 1, -1 };
    private static readonly int[] Dx4 = { 0, 1, 0, -1 };
    private static readonly int[] Dy4 = { -1, 0, 1, 0 };

    /// <summary>
    /// 寻路用的静态数据（地图/建筑变化时重建）。
    /// </summary>
    /// <param name="moveCost">每格地形代价（森林更贵），与 map.terrain_cost() 一致</param>
    /// <param name="penaltyTiles">按阵营的「建筑惩罚」标记，布局 [faction][idx]</param>
    /// <param name="penaltyValue">惩罚值（config 的 path.building_penalty）</param>
    /// <param name="hasBuilding">每格是否有活着的建筑（给「斜穿建筑缝」用）</param>
    public void SetupPathing(double[] moveCost, byte[] penaltyTiles, double penaltyValue,
                             byte[] hasBuilding, bool diagonal, bool cornerCut, double unitRadius)
    {
        _moveCost = moveCost;
        _penaltyTiles = penaltyTiles;
        _penaltyValue = penaltyValue;
        _hasBuilding = hasBuilding;
        _diag = diagonal;
        _cornerCut = cornerCut;
        _unitRadius = unitRadius;
    }

    private bool InBounds(int x, int y)
    {
        return x >= 0 && y >= 0 && x < _cols && y < _rows;
    }

    /// <summary>格级可通行：对应 pathfinder.passable()（地形 + 建筑格级阻挡）。</summary>
    private bool PassableTile(int idx, int f)
    {
        if (_terrainBlocked != null && _terrainBlocked[idx] != 0)
        {
            return false;
        }
        if (_tileBlocked != null && f >= 0 && f < _factionCount)
        {
            return _tileBlocked[f * _tileCount + idx] == 0;
        }
        return true;
    }

    /// <summary>对应 pathfinder._blocked_by_building()：可通行地形 + 有活建筑。</summary>
    private bool BlockedByBuilding(int x, int y)
    {
        if (!InBounds(x, y))
        {
            return false;
        }
        int idx = y * _cols + x;
        if (_terrainBlocked != null && _terrainBlocked[idx] != 0)
        {
            return false;
        }
        return _hasBuilding != null && _hasBuilding.Length > idx && _hasBuilding[idx] != 0;
    }

    /// <summary>对应 pathfinder.diagonal_step_allowed()：反对角穿角 + 建筑缝例外。</summary>
    private bool DiagonalAllowed(int x, int y, int dx, int dy, int f)
    {
        if (dx == 0 || dy == 0)
        {
            return true;
        }
        if (_cornerCut)
        {
            return true;
        }
        int ax = x + dx, ay = y;
        if (!InBounds(ax, ay) || !PassableTile(ay * _cols + ax, f))
        {
            return SqueezeThroughGap(x, y, dx, dy);
        }
        int bx = x, by = y + dy;
        if (!InBounds(bx, by) || !PassableTile(by * _cols + bx, f))
        {
            return SqueezeThroughGap(x, y, dx, dy);
        }
        return true;
    }

    /// <summary>对应 pathfinder._squeeze_through_gap()：两块小本体之间的缝够宽才放行。</summary>
    private bool SqueezeThroughGap(int x, int y, int dx, int dy)
    {
        int ax = x + dx, ay = y;
        int bx = x, by = y + dy;
        if (!BlockedByBuilding(ax, ay) || !BlockedByBuilding(bx, by))
        {
            return false; // 「斜穿两座山」一律禁止：只有两边都是建筑才谈得上缝
        }
        int ba = _bodyAtTile[ay * _cols + ax];
        int bb = _bodyAtTile[by * _cols + bx];
        if (ba < 0 || bb < 0)
        {
            return false;
        }
        double cornerX = x + (dx > 0 ? 1 : 0);
        double cornerY = y + (dy > 0 ? 1 : 0);

        double pax = Clamp(cornerX, _bodyCx[ba] - _bodyHalf[ba], _bodyCx[ba] + _bodyHalf[ba]);
        double pay = Clamp(cornerY, _bodyCy[ba] - _bodyHalf[ba], _bodyCy[ba] + _bodyHalf[ba]);
        double pbx = Clamp(cornerX, _bodyCx[bb] - _bodyHalf[bb], _bodyCx[bb] + _bodyHalf[bb]);
        double pby = Clamp(cornerY, _bodyCy[bb] - _bodyHalf[bb], _bodyCy[bb] + _bodyHalf[bb]);

        double w = System.Math.Sqrt((pax - pbx) * (pax - pbx) + (pay - pby) * (pay - pby));
        return w >= _unitRadius * 2.0;
    }

    private static double Clamp(double v, double lo, double hi)
    {
        return v < lo ? lo : (v > hi ? hi : v);
    }

    /// <summary>一步的代价：地形代价 + 建筑惩罚（都是「进入目标格」的代价，与 A* 一致）。</summary>
    private double StepCost(int ni, int f)
    {
        double c = _moveCost.Length > ni ? _moveCost[ni] : 1.0;
        if (_penaltyTiles != null && f >= 0 && _penaltyTiles.Length > f * _tileCount + ni
            && _penaltyTiles[f * _tileCount + ni] != 0)
        {
            c += _penaltyValue;
        }
        return c;
    }

    /// <summary>
    /// 从目标格做一次 Dijkstra，返回「每格到目标还要多少费」的距离场。
    /// 不可达 = Inf。**命令帧的全部尖峰都在这里被消掉**：一次场顶 N 次 A*。
    /// </summary>
    public double[] BuildField(int faction, int goalIdx)
    {
        var field = new double[_tileCount];
        for (int i = 0; i < _tileCount; i++)
        {
            field[i] = Inf;
        }
        if (goalIdx < 0 || goalIdx >= _tileCount || !PassableTile(goalIdx, faction))
        {
            return field; // 终点必须完全可通行，与 find_path 一致
        }

        var heap = new MinHeap(1024);
        field[goalIdx] = 0.0;
        heap.Push(0.0, goalIdx);

        int n = _diag ? 8 : 4;
        int[] dxs = _diag ? Dx8 : Dx4;
        int[] dys = _diag ? Dy8 : Dy4;

        while (heap.Count > 0)
        {
            heap.Pop(out double d, out int idx);
            if (d > field[idx] + 1e-12)
            {
                continue; // 过期条目
            }
            int x = idx % _cols;
            int y = idx / _cols;
            // ★★ 一步的代价记在**进入的那一格**上（find_path 的 `_terrain_cost(nx, ny)`），
            //    所以这个图是**有向的**：从 u 走到 v 花 w(v)，从 v 走到 u 花 w(u)。
            //    反向 Dijkstra 里「从 cur 扩到邻居 nb」对应的是正向的 nb → cur，
            //    因此这一步的代价必须用 **cur（= 正向的目的地）**，不是 nb。
            //    （第一版写成 StepCost(nb)，于是森林格的代价被算到走出来的那一格上，
            //     场里出现了「比真实最优更贵的值」——表现是下降时找不到下降方向。）
            double hereCost = StepCost(idx, faction);
            for (int k = 0; k < n; k++)
            {
                int dx = dxs[k], dy = dys[k];
                int nx = x + dx, ny = y + dy;
                if (!InBounds(nx, ny))
                {
                    continue;
                }
                int ni = ny * _cols + nx;
                // 正向是 nb → cur：来源格 nb 自己必须可通行（否则场上没有它的 D 值）
                if (!PassableTile(ni, faction))
                {
                    continue;
                }
                // 对角守卫：按正向那条边（nb → cur）判定。它是几何对称的，
                // 这里用邻居 + 反向 d 写，语义最直白。
                if (!DiagonalAllowed(nx, ny, -dx, -dy, faction))
                {
                    continue;
                }
                double step = (dx != 0 && dy != 0) ? StepDiag : 1.0;
                double nd = d + hereCost * step;
                if (nd < field[ni] - 1e-12)
                {
                    field[ni] = nd;
                    heap.Push(nd, ni);
                }
            }
        }
        return field;
    }

    /// <summary>
    /// 顺场下降：从起点格沿着场走到目标格，返回**不含起点、含终点**的地块下标序列。
    /// 与 find_path 的返回口径一致；不可达 / 场坏了返回 null。
    ///
    /// ★ 起点不检查通行性：单位可能正站在后来被建筑占住的格子上（与 find_path 同一条规矩）。
    /// </summary>
    public int[] DescendPath(double[] field, int fromIdx, int goalIdx, int maxSteps)
    {
        if (field == null || fromIdx < 0 || fromIdx >= _tileCount || goalIdx < 0 || goalIdx >= _tileCount)
        {
            return null;
        }
        var list = new System.Collections.Generic.List<int>(64);
        int f = _descendFaction;
        int cur = fromIdx;
        int n = _diag ? 8 : 4;
        int[] dxs = _diag ? Dx8 : Dx4;
        int[] dys = _diag ? Dy8 : Dy4;
        DebugLog = DebugCapture
            ? "from=" + fromIdx + " goal=" + goalIdx + " f=" + f + " fieldFrom=" + field[fromIdx].ToString("F3") + " fieldGoal=" + field[goalIdx].ToString("F3") + " diag=" + _diag
            : "";

        // ★★ 平局怎么破，直接决定「绕障时走哪一边」。
        //    距离场在开阔地有很多条等价最优路；如果只按 DIRS8 的顺序取第一个，
        //    绕山时就会稳定地选到与 A* **相反的那一侧** —— 代价一样，但一整队人
        //    会从另一边涌过来，拥挤收敛的落点跟着变（实测 test_arrival 会红）。
        //    A* 有 octile 启发式牵着，天然贴住「通向目标的直线」，所以这里也照抄这条：
        //    代价相同时，取与「当前格 → 目标格」方向最贴合的那一步。
        int gx = goalIdx % _cols;
        int gy = goalIdx / _cols;

        // 起点自己不可达（站在障碍上 / 场没覆盖到它）：先找一个合法的第一步
        if (field[cur] >= Inf * 0.5)
        {
            int firstBest = -1;
            double firstVal = Inf;
            double firstAlign = double.MinValue;
            int cx = cur % _cols, cy = cur / _cols;
            for (int k = 0; k < n; k++)
            {
                int nx = cx + dxs[k], ny = cy + dys[k];
                if (!InBounds(nx, ny))
                {
                    continue;
                }
                int ni = ny * _cols + nx;
                if (!PassableTile(ni, f) || !DiagonalAllowed(cx, cy, dxs[k], dys[k], f))
                {
                    continue;
                }
                double step = (dxs[k] != 0 && dys[k] != 0) ? StepDiag : 1.0;
                double val = field[ni] + StepCost(ni, f) * step;
                double align = (nx - cx) * (gx - cx) + (ny - cy) * (gy - cy);
                if (val < firstVal - 1e-9 || (val <= firstVal + 1e-9 && align > firstAlign))
                {
                    firstVal = val;
                    firstAlign = align;
                    firstBest = ni;
                }
            }
            if (firstBest < 0)
            {
                if (DebugCapture)
                {
                    DebugLog += " | no first step";
                }
                return null;
            }
            if (DebugCapture)
            {
                DebugLog += " | first=" + firstBest;
            }
            cur = firstBest;
            list.Add(firstBest);
            if (cur == goalIdx)
            {
                return list.ToArray();
            }
        }

        int guard = 0;
        while (cur != goalIdx)
        {
            guard++;
            if (guard > maxSteps)
            {
                return null;
            }
            int x = cur % _cols, y = cur / _cols;
            int best = -1;
            double bestVal = Inf;
            double bestAlign = double.MinValue;
            for (int k = 0; k < n; k++)
            {
                int dx = dxs[k], dy = dys[k];
                int nx = x + dx, ny = y + dy;
                if (!InBounds(nx, ny))
                {
                    continue;
                }
                int ni = ny * _cols + nx;
                if (!PassableTile(ni, f) || !DiagonalAllowed(x, y, dx, dy, f))
                {
                    continue;
                }
                double step = (dx != 0 && dy != 0) ? StepDiag : 1.0;
                double val = field[ni] + StepCost(ni, f) * step;
                double align = (nx - x) * (gx - x) + (ny - y) * (gy - y);
                if (val < bestVal - 1e-9 || (val <= bestVal + 1e-9 && align > bestAlign))
                {
                    bestVal = val;
                    bestAlign = align;
                    best = ni;
                }
            }
            // 场是正确的 Dijkstra 场时，bestVal 必然等于 field[cur]（沿最优边走）
            if (best < 0 || bestVal > field[cur] + 1e-6)
            {
                if (DebugCapture)
                {
                    DebugLog += " | stop cur=" + cur + " best=" + best + " bv=" + bestVal.ToString("F3")
                        + " fc=" + field[cur].ToString("F3");
                }
                return null;
            }
            cur = best;
            list.Add(best);
            if (DebugCapture && guard < 6)
            {
                DebugLog += " | step" + guard + "=" + best;
            }
        }
        return list.ToArray();
    }

    /// <summary>下降时用的阵营下标（DescendPath 的参数里塞不下，用这个传）。</summary>
    private int _descendFaction;

    /// <summary>最近一次 DescendPath 的过程记录（只在排查时看，逻辑不读它）。</summary>
    public string DebugLog { get; private set; } = "";

    /// <summary>打开后才记录 DebugLog。**默认关** —— 生产路径上每单位一次，
    /// 拼字符串会给 1000 单位群编添几千次分配，纯属白花。</summary>
    public bool DebugCapture { get; set; } = false;

    /// <summary>设置 DescendPath 用的阵营（每次调用前设一次）。</summary>
    public void SetDescendFaction(int f)
    {
        _descendFaction = f;
    }

    /// <summary>排查用：内核眼里的格级可通行（应与 pathfinder.passable() 完全一致）。</summary>
    public bool DebugPassable(int x, int y, int f)
    {
        if (!InBounds(x, y))
        {
            return false;
        }
        return PassableTile(y * _cols + x, f);
    }

    /// <summary>排查用：内核眼里的对角守卫结果。d 用两个 int 传，避免 Vector2i 依赖。</summary>
    public bool DebugDiagonal(int x, int y, int dx, int dy, int f)
    {
        return DiagonalAllowed(x, y, dx, dy, f);
    }


    // ==================================================================
    // 直线判定（segment_clear 的 C# 版）
    //
    // ★ 为什么这个也要下沉：`smooth_path` 对**每个单位**都要跑一次 DDA，
    //   而 DDA 每经过一格就要问一次「这格能不能切」。GDScript 版那次询问是
    //   三层函数调用（约 3.7 µs/格），一条 57 格的直线就是 0.21 ms ——
    //   1000 个单位群编里这一项 ≈ 210 ms，是命令帧的最大单项。
    //
    // ⚠️ 规则必须与 pathfinder.segment_clear 逐条一致（有回归测试盯着）：
    //    · 只检查线段**进入**的格子，**起点所在格不检查**（单位可能站在建筑上）；
    //    · 正好穿过格点时，对角两侧都得让得开；
    //    · 「切不动」= 格级不可通行 **或** 这条线切进了挡自己的建筑本体（含 pad 外扩）。
    // ==================================================================

    /// <param name="f">阵营下标</param>
    /// <returns>true = 全程可切（对应 GDScript 的 segment_clear 返回 true）</returns>
    public bool SegmentClear(int f, double ax, double ay, double bx, double by)
    {
        // pad = 单位碰撞半径（与 pathfinder.segment_clear 里的 cfg.unit_collision_radius 同源，
        // 由 SetupPathing 传入）。它在外扩建筑本体时用，和 _can_stand 的口径一致。
        double pad = _unitRadius;
        double x0 = ax, y0 = ay;
        double dx = bx - x0;
        double dy = by - y0;
        int tx = (int)System.Math.Floor(x0);
        int ty = (int)System.Math.Floor(y0);

        int stepX = dx > 0.0 ? 1 : -1;
        int stepY = dy > 0.0 ? 1 : -1;
        double tDeltaX = dx != 0.0 ? System.Math.Abs(1.0 / dx) : double.PositiveInfinity;
        double tDeltaY = dy != 0.0 ? System.Math.Abs(1.0 / dy) : double.PositiveInfinity;
        double tMaxX = dx > 0.0 ? (tx + 1 - x0) * tDeltaX : (x0 - tx) * tDeltaX;
        double tMaxY = dy > 0.0 ? (ty + 1 - y0) * tDeltaY : (y0 - ty) * tDeltaY;
        if (dx == 0.0) { tMaxX = double.PositiveInfinity; }
        if (dy == 0.0) { tMaxY = double.PositiveInfinity; }

        int guard = 0;
        while (guard < 8192)
        {
            guard++;
            if (tMaxX > 1.0 && tMaxY > 1.0)
            {
                return true;                    // 线段已经走完
            }
            if (tMaxX < tMaxY)
            {
                tx += stepX;
                tMaxX += tDeltaX;
                if (SegBlocked(f, tx, ty, ax, ay, bx, by, pad))
                {
                    return false;
                }
            }
            else if (tMaxY < tMaxX)
            {
                ty += stepY;
                tMaxY += tDeltaY;
                if (SegBlocked(f, tx, ty, ax, ay, bx, by, pad))
                {
                    return false;
                }
            }
            else
            {
                // 正好穿过格点：对角两侧都得让得开，才允许走这条直线
                if (SegBlocked(f, tx + stepX, ty, ax, ay, bx, by, pad))
                {
                    return false;
                }
                if (SegBlocked(f, tx, ty + stepY, ax, ay, bx, by, pad))
                {
                    return false;
                }
                tx += stepX;
                ty += stepY;
                tMaxX += tDeltaX;
                tMaxY += tDeltaY;
                if (SegBlocked(f, tx, ty, ax, ay, bx, by, pad))
                {
                    return false;
                }
            }
        }
        return false;
    }

    /// <summary>这一格切不切得动（对应 pathfinder._seg_blocked）。</summary>
    private bool SegBlocked(int f, int x, int y, double ax, double ay, double bx, double by, double pad)
    {
        if (!InBounds(x, y))
        {
            return true;                        // 地图外：与 passable() 的 has() 失败同义
        }
        int idx = y * _cols + x;
        if (!PassableTile(idx, f))
        {
            return true;
        }
        // 格级放行了，还要看这条线有没有切进「挡这个阵营」的建筑本体
        int bi = _bodyAtTile[idx];
        if (bi < 0 || !BodyBlocks(bi, f))
        {
            return false;
        }
        double half = _bodyHalf[bi] + pad;
        double zx = _bodyCx[bi] - half;
        double zy = _bodyCy[bi] - half;
        double zex = _bodyCx[bi] + half;
        double zey = _bodyCy[bi] + half;
        return SegmentHitsRect(ax, ay, bx, by, zx, zy, zex, zey);
    }

    /// <summary>线段 vs 轴对齐矩形（slab 法）。对应 building.gd 的 _segment_hits_rect。</summary>
    private static bool SegmentHitsRect(double ax, double ay, double bx, double by,
                                        double rx0, double ry0, double rx1, double ry1)
    {
        double dx = bx - ax;
        double dy = by - ay;
        double tmin = 0.0;
        double tmax = 1.0;
        if (System.Math.Abs(dx) < 1e-12)
        {
            if (ax < rx0 || ax > rx1)
            {
                return false;
            }
        }
        else
        {
            double t1 = (rx0 - ax) / dx;
            double t2 = (rx1 - ax) / dx;
            tmin = System.Math.Max(tmin, System.Math.Min(t1, t2));
            tmax = System.Math.Min(tmax, System.Math.Max(t1, t2));
            if (tmin > tmax)
            {
                return false;
            }
        }
        if (System.Math.Abs(dy) < 1e-12)
        {
            if (ay < ry0 || ay > ry1)
            {
                return false;
            }
        }
        else
        {
            double t3 = (ry0 - ay) / dy;
            double t4 = (ry1 - ay) / dy;
            tmin = System.Math.Max(tmin, System.Math.Min(t3, t4));
            tmax = System.Math.Min(tmax, System.Math.Max(t3, t4));
            if (tmin > tmax)
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>
    /// 从起点做一次「按阵营通行规则」的 BFS，返回每格是否可达的掩码（1 = 可达）。
    /// 对应 pathfinder.reachable_tiles()：邻居生成与对角守卫必须与 A*/场同一套。
    /// </summary>
    public byte[] ReachableMask(int faction, int fromIdx)
    {
        var seen = new byte[_tileCount];
        if (fromIdx < 0 || fromIdx >= _tileCount)
        {
            return seen;
        }
        seen[fromIdx] = 1; // 起点自己也算（单位可能站在后来被占住的格子上）
        var queue = new int[_tileCount];
        int head = 0, tail = 0;
        queue[tail++] = fromIdx;

        int n = _diag ? 8 : 4;
        int[] dxs = _diag ? Dx8 : Dx4;
        int[] dys = _diag ? Dy8 : Dy4;

        while (head < tail)
        {
            int cur = queue[head++];
            int x = cur % _cols, y = cur / _cols;
            for (int k = 0; k < n; k++)
            {
                int nx = x + dxs[k], ny = y + dys[k];
                if (!InBounds(nx, ny))
                {
                    continue;
                }
                int ni = ny * _cols + nx;
                if (seen[ni] != 0)
                {
                    continue;
                }
                if (!PassableTile(ni, faction) || !DiagonalAllowed(x, y, dxs[k], dys[k], faction))
                {
                    continue;
                }
                seen[ni] = 1;
                queue[tail++] = ni;
            }
        }
        return seen;
    }


    // ==================================================================
    // 警戒索敌（combat.acquire_target 的批量版）
    //
    // ★★ 为什么必须有它（实测，1000 单位 / 100×100 图）：
    //    GDScript 版是每个**待命**单位扫一遍 world.units —— O(n²)。
    //    1000 个单位全部待命时实测 **283 ms/帧（4 fps）**：
    //    100 万次「阵营串比较 + 距离」。而「1000 单位常态」在真实玩法里
    //    绝大部分时间就是待命，这个场景比「全都在走」更常发生。
    //
    // ★ 做法：先按阵营分组（计数排序），每个单位只扫**别的阵营**那一组。
    //   · 场上没有敌人（最常见）→ 内层循环一次都不进 → 几乎零成本
    //   · 两个 500 人大军对垒 → 25 万次距离，在 C# 里约 1~2 ms
    //
    // ⚠️ 判定必须与 combat.acquire_target 逐条一致：
    //    敌对 = 阵营下标不同（对应 FactionRes.same_side 的字符串相等）；
    //    命中条件 = 距离 − 目标体积 ≤ 自己的警戒半径（「半个身子进射程」也算）；
    //    取最近，平局取下标小的那个（GDScript 版用的是严格小于）。
    // ==================================================================

    private const int MaxSides = 32;
    private readonly int[] _tgtStart = new int[MaxSides + 1];
    private readonly int[] _tgtCursor = new int[MaxSides + 1];
    private int[] _tgtOrder = new int[0];
    private int[] _tgtResult = new int[0];

    /// <param name="xy">长度 2n 的位置</param>
    /// <param name="alive">长度 n，0 = 跳过</param>
    /// <param name="side">长度 n：阵营下标（同一方 = 同一个值）</param>
    /// <param name="aggro">长度 n：警戒半径（格）</param>
    /// <param name="radius">长度 n：单位体积（格），用于「半个身子进射程」</param>
    /// <returns>长度 n：每个单位的目标下标，-1 = 射程内没有敌人</returns>
    public int[] AcquireTargets(double[] xy, byte[] alive, int[] side, double[] aggro, double[] radius, int count)
    {
        if (_tgtOrder.Length < count)
        {
            _tgtOrder = new int[count];
            _tgtResult = new int[count];
        }
        var result = _tgtResult;
        for (int i = 0; i < count; i++)
        {
            result[i] = -1;
        }
        if (count <= 0)
        {
            return result;
        }

        System.Array.Clear(_tgtStart, 0, MaxSides + 1);
        for (int i = 0; i < count; i++)
        {
            if (alive[i] == 0)
            {
                continue;
            }
            _tgtStart[SideOf(side[i]) + 1]++;
        }
        for (int s = 0; s < MaxSides; s++)
        {
            _tgtStart[s + 1] += _tgtStart[s];
        }
        System.Array.Copy(_tgtStart, _tgtCursor, MaxSides + 1);
        for (int i = 0; i < count; i++)
        {
            if (alive[i] == 0)
            {
                continue;
            }
            _tgtOrder[_tgtCursor[SideOf(side[i])]++] = i;
        }

        for (int i = 0; i < count; i++)
        {
            if (alive[i] == 0)
            {
                continue;
            }
            int si = SideOf(side[i]);
            double xi = xy[i * 2];
            double yi = xy[i * 2 + 1];
            double ag = aggro[i];
            if (ag <= 0.0)
            {
                continue;
            }
            int best = -1;
            double bestD = double.MaxValue;
            for (int s = 0; s < MaxSides; s++)
            {
                if (s == si)
                {
                    continue;
                }
                int from = _tgtStart[s];
                int to = _tgtStart[s + 1];
                for (int k = from; k < to; k++)
                {
                    int j = _tgtOrder[k];
                    double dx = xy[j * 2] - xi;
                    double dy = xy[j * 2 + 1] - yi;
                    double d = System.Math.Sqrt(dx * dx + dy * dy) - radius[j];
                    if (d <= ag && d < bestD)
                    {
                        bestD = d;
                        best = j;
                    }
                }
            }
            result[i] = best;
        }
        return result;
    }

    private static int SideOf(int s)
    {
        if (s < 0)
        {
            return 0;
        }
        if (s >= MaxSides)
        {
            return MaxSides - 1;
        }
        return s;
    }


    /// <summary>惰性二叉堆（(cost, tile)）。允许重复条目，弹出时用 field 值判过期。</summary>
    private sealed class MinHeap
    {
        private double[] _key;
        private int[] _val;
        private int _n;

        public MinHeap(int cap)
        {
            _key = new double[cap];
            _val = new int[cap];
        }

        public int Count => _n;

        public void Push(double key, int val)
        {
            if (_n == _key.Length)
            {
                System.Array.Resize(ref _key, _key.Length * 2);
                System.Array.Resize(ref _val, _val.Length * 2);
            }
            int i = _n++;
            _key[i] = key;
            _val[i] = val;
            while (i > 0)
            {
                int p = (i - 1) / 2;
                if (_key[p] <= _key[i])
                {
                    break;
                }
                Swap(p, i);
                i = p;
            }
        }

        public void Pop(out double key, out int val)
        {
            key = _key[0];
            val = _val[0];
            _n--;
            if (_n > 0)
            {
                _key[0] = _key[_n];
                _val[0] = _val[_n];
                int i = 0;
                while (true)
                {
                    int l = i * 2 + 1;
                    int r = l + 1;
                    int m = i;
                    if (l < _n && _key[l] < _key[m])
                    {
                        m = l;
                    }
                    if (r < _n && _key[r] < _key[m])
                    {
                        m = r;
                    }
                    if (m == i)
                    {
                        break;
                    }
                    Swap(m, i);
                    i = m;
                }
            }
        }

        private void Swap(int a, int b)
        {
            double tk = _key[a];
            _key[a] = _key[b];
            _key[b] = tk;
            int tv = _val[a];
            _val[a] = _val[b];
            _val[b] = tv;
        }
    }
}
