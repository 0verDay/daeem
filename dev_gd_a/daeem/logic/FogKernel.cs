using Godot;
using System;
using System.Collections.Generic;

namespace Daeem.Logic;

/// <summary>
/// 战争迷雾的视野计算内核（C# 版）。
///
/// ★★ 为什么单独搬这一段（手机端实测）：
///   `world.tick` 的 `fg` 段在 68 单位 / 29×22 图上约 **2.7 ms/帧**，
///   其中几乎全部是 GDScript 的「扇区 OR 进掩码」与逐格 DDA 视线：
///   每个贡献格要把一张 `cols×rows` 的掩码整个扫一遍，单位一走动就是几十张。
///   这是纯数字循环，没有对象状态、没有 Godot 类型参与运算 —— 最适合下沉到 C#。
///
/// ★★ 接口按**批**划（与 CrowdKernel 同一条规矩）：
///   GDScript 把「每一方从哪些格、以多大半径产生视野」压成三条 Packed 数组，
///   一次调用返回**所有方**的掩码（`sideCount × cols × rows` 的扁平数组）。
///   不做「每个贡献格调一次 C#」——实测那会抵消掉语言带来的全部收益。
///
/// ★ 语义必须与 `logic/fog.gd` 的 `compute_sector` / `_los_blocked` **逐条一致**：
///   · 起点格自己可见；
///   · 只遍历半径以内（半径按格心到格心算，`d² > r² + 1e-6` 才排除）；
///   · 视线被**山脉**挡住，且只检查**中间格**（山自己那格可见、山后面不可见）；
///   · 正好穿过格点时两侧都算擦到；
///   · 扇区按格缓存，**只有半径变大才重算**（更小的复用超集 —— 与 GDScript 同一条规则）。
///
/// ★ 与 GDScript 版的唯一实现差异：这里缓存的是**稀疏的可见格下标**（`int[]`），
///   不是整张 `cols×rows` 掩码。OR 的时候只遍历真正可见的那部分：
///   半径 8 的一格约 200 个下标，而整图掩码是 594（29×22）~ 10000（100×100）。
///   语义完全相同，只是把「遍历全图」换成「遍历可见集」。
/// </summary>
[GlobalClass]
public partial class FogKernel : RefCounted
{
    /// <summary>视野半径的防呆上限（与 fog.gd 的 MAX_VISION 同值）。</summary>
    private const float MaxVision = 160.0f;

    /// <summary>DDA 步数护栏（与 fog.gd 的 LOS_GUARD 同值）。</summary>
    private const int LosGuard = 4096;

    private int _cols;
    private int _rows;
    private int _cells;

    /// <summary>1 = 山。地图外一律按「不是山」处理（与 map.is_mountain 一致）。</summary>
    private byte[] _mountain = System.Array.Empty<byte>();

    /// <summary>格下标 → 该格视野扇区（稀疏的可见格下标）。</summary>
    private sealed class Sector
    {
        public float Radius;
        public int[] Visible;
    }

    private readonly Dictionary<int, Sector> _cache = new Dictionary<int, Sector>();

    /// <summary>返回缓冲复用（每帧一次调用，尺寸不变时不重新分配）。</summary>
    private byte[] _out = System.Array.Empty<byte>();


    // ------------------------------------------------------------------
    // 建图 / 清缓存
    // ------------------------------------------------------------------

    /// <summary>
    /// 建地图表。换地图（或地形变了之后 `reset_cache()` 再建）时调用一次。
    /// </summary>
    /// <param name="mountain">长度 cols×rows；非 0 = 山</param>
    public void SetupMap(int cols, int rows, byte[] mountain)
    {
        if (cols <= 0 || rows <= 0)
        {
            _cols = 0;
            _rows = 0;
            _cells = 0;
            _mountain = System.Array.Empty<byte>();
            _cache.Clear();
            return;
        }
        _cols = cols;
        _rows = rows;
        _cells = cols * rows;
        _mountain = mountain ?? System.Array.Empty<byte>();
        _cache.Clear();
    }

    /// <summary>清掉扇区缓存（换地图 / 地形变化）。</summary>
    public void ResetCache()
    {
        _cache.Clear();
    }

    /// <summary>诊断：当前缓存了多少个扇区（测试 / 排查用）。</summary>
    public int CachedSectors => _cache.Count;


    // ------------------------------------------------------------------
    // 每帧入口：一次算完所有方的掩码
    // ------------------------------------------------------------------

    /// <summary>
    /// 一次调用算出所有方的视野掩码。
    /// </summary>
    /// <param name="sideCount">有几方（输出数组按它分段）</param>
    /// <param name="sides">长度 count：每个贡献格属于第几方</param>
    /// <param name="tiles">长度 count：贡献格的地图下标（ty*cols+tx）</param>
    /// <param name="radii">长度 count：贡献格的视野半径（格）</param>
    /// <param name="count">贡献格数量</param>
    /// <returns>长度 sideCount×cols×rows 的扁平掩码；非 0 = 该方看得见那一格</returns>
    public byte[] BuildSight(int sideCount, int[] sides, int[] tiles, double[] radii, int count)
    {
        if (sideCount <= 0 || _cells <= 0)
        {
            return System.Array.Empty<byte>();
        }
        int total = sideCount * _cells;
        if (_out.Length != total)
        {
            _out = new byte[total];
        }
        else
        {
            System.Array.Clear(_out, 0, total);
        }

        if (sides == null || tiles == null || radii == null || count <= 0)
        {
            return _out;
        }
        int n = Math.Min(count, Math.Min(sides.Length, Math.Min(tiles.Length, radii.Length)));
        for (int k = 0; k < n; k++)
        {
            int side = sides[k];
            int idx = tiles[k];
            if (side < 0 || side >= sideCount || idx < 0 || idx >= _cells)
            {
                continue;
            }
            int[] visible = GetSector(idx, (float)radii[k]);
            int baseIdx = side * _cells;
            for (int j = 0; j < visible.Length; j++)
            {
                _out[baseIdx + visible[j]] = 1;
            }
        }
        return _out;
    }


    // ------------------------------------------------------------------
    // 扇区（按格缓存）
    // ------------------------------------------------------------------

    private int[] GetSector(int idx, float radius)
    {
        float r = Math.Clamp(radius, 0.0f, MaxVision);
        if (_cache.TryGetValue(idx, out Sector cached) && cached.Radius >= r - 1e-6f)
        {
            return cached.Visible;
        }
        int[] visible = ComputeSector(idx, r);
        _cache[idx] = new Sector { Radius = r, Visible = visible };
        return visible;
    }

    /// <summary>
    /// 算「站在 idx 这一格、半径 r」能看见哪些格（稀疏下标表）。
    /// 这逐条对应 `fog.gd` 的 `compute_sector`。
    /// </summary>
    private int[] ComputeSector(int idx, float radius)
    {
        var list = new List<int>(64);
        if (idx < 0 || idx >= _cells)
        {
            return list.ToArray();
        }
        int ox = idx % _cols;
        int oy = idx / _cols;
        float r = Math.Clamp(radius, 0.0f, MaxVision);
        int ri = (int)Math.Ceiling(r);
        float r2 = r * r + 1e-6f;

        list.Add(idx); // 起点格自己永远可见
        for (int dy = -ri; dy <= ri; dy++)
        {
            int ty = oy + dy;
            if (ty < 0 || ty >= _rows)
            {
                continue;
            }
            for (int dx = -ri; dx <= ri; dx++)
            {
                int tx = ox + dx;
                if (tx < 0 || tx >= _cols)
                {
                    continue;
                }
                if (dx == 0 && dy == 0)
                {
                    continue; // 起点自己已经加过
                }
                if ((float)(dx * dx + dy * dy) > r2)
                {
                    continue;
                }
                if (LosBlocked(ox, oy, tx, ty))
                {
                    continue;
                }
                list.Add(ty * _cols + tx);
            }
        }
        return list.ToArray();
    }


    // ------------------------------------------------------------------
    // 视线（DDA）
    // ------------------------------------------------------------------

    /// <summary>
    /// 从 (ox,oy) 到 (tx,ty) 的直线中间有没有山。
    /// 逐条对应 `fog.gd` 的 `_los_blocked`：**只检查中间格**（起点与终点都不检查）。
    /// </summary>
    private bool LosBlocked(int ox, int oy, int tx, int ty)
    {
        if (ox == tx && oy == ty)
        {
            return false;
        }
        double x0 = ox + 0.5;
        double y0 = oy + 0.5;
        double dx = tx + 0.5 - x0;
        double dy = ty + 0.5 - y0;
        if (Math.Abs(dx) < 1e-9 && Math.Abs(dy) < 1e-9)
        {
            return false;
        }

        int cx = ox;
        int cy = oy;
        int stepX = dx > 0.0 ? 1 : -1;
        int stepY = dy > 0.0 ? 1 : -1;

        double tDeltaX = Math.Abs(dx) > 1e-12 ? Math.Abs(1.0 / dx) : double.PositiveInfinity;
        double tDeltaY = Math.Abs(dy) > 1e-12 ? Math.Abs(1.0 / dy) : double.PositiveInfinity;
        double tMaxX = dx > 0.0 ? ((cx + 1) - x0) * tDeltaX : (x0 - cx) * tDeltaX;
        double tMaxY = dy > 0.0 ? ((cy + 1) - y0) * tDeltaY : (y0 - cy) * tDeltaY;

        if (Math.Abs(dx) <= 1e-12)
        {
            tMaxX = double.PositiveInfinity;
        }
        if (Math.Abs(dy) <= 1e-12)
        {
            tMaxY = double.PositiveInfinity;
        }

        int guard = 0;
        while (guard < LosGuard)
        {
            guard++;
            if (tMaxX > 1.0 && tMaxY > 1.0)
            {
                return false;
            }
            if (tMaxX < tMaxY)
            {
                cx += stepX;
                tMaxX += tDeltaX;
                if (cx == tx && cy == ty)
                {
                    return false;
                }
                if (IsMountain(cx, cy))
                {
                    return true;
                }
            }
            else if (tMaxY < tMaxX)
            {
                cy += stepY;
                tMaxY += tDeltaY;
                if (cx == tx && cy == ty)
                {
                    return false;
                }
                if (IsMountain(cx, cy))
                {
                    return true;
                }
            }
            else
            {
                // 正好穿过格点：两侧都擦到了，任意一侧是山就算被挡
                if (IsMountain(cx + stepX, cy) || IsMountain(cx, cy + stepY))
                {
                    return true;
                }
                cx += stepX;
                cy += stepY;
                tMaxX += tDeltaX;
                tMaxY += tDeltaY;
                if (cx == tx && cy == ty)
                {
                    return false;
                }
                if (IsMountain(cx, cy))
                {
                    return true;
                }
            }
        }
        return false;
    }

    private bool IsMountain(int x, int y)
    {
        if (x < 0 || y < 0 || x >= _cols || y >= _rows)
        {
            return false; // 与 map.is_mountain 一致：地图外不是山
        }
        int idx = y * _cols + x;
        return _mountain.Length > idx && _mountain[idx] != 0;
    }
}
