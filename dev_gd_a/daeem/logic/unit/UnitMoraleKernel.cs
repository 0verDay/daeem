using Godot;

namespace Daeem.Logic;

/// <summary>
/// 士气 + 回血/掉血档位的计算内核（C# 版）。
///
/// ★ 为什么单独搬这一段（dscj 256 单位实测）：`u/morale` ≈ 0.62 ms/帧，
///   而它全是「查区划 → 判同方 → 判包围 → 加粮车光环 → 按档位回/掉血」这种
///   逐单位的查表与算术，没有对象状态、没有 Godot 类型参与运算 —— 最适合下沉。
///
/// ★★ 接口按**批**（与 CrowdKernel / FogKernel 同一条规矩）：
///   GDScript 一次把整帧所有单位压成几条 Packed 数组（C# 侧就是 int[] / double[] / byte[]），
///   一次调用返回全部结果。不做「每个单位调一次 C#」—— 实测那会把语言带来的全部收益抵消掉。
///
/// ★★ 语义关键：**按下标顺序、就地推进**。
///   「队员镜像队长的士气」在 GDScript 里是逐单位顺序执行的 ——
///   队长下标小于队员时，队员读到的是**本帧已更新**的值；反之读到上一帧的。
///   这里用同一个数组边写边读，就精确复现了这个顺序语义（不是"先算完再镜像"）。
///
/// ★ 与 `logic/morale.gd` 的 `tick_unit` 必须**逐位等价**：
///   `tests/test_unit_backend_equiv.gd` 用同种子世界跑两个后端、逐字段比对盯着。
/// </summary>
[GlobalClass]
public partial class UnitMoraleKernel : RefCounted
{
    /// <summary>
    /// 一整遍「士气 + 回血/掉血」。
    /// </summary>
    /// <param name="skip">1 = 这一位不参与（阵亡 / 濒死），原样返回。</param>
    /// <param name="anchorIndex">下标 i 的士气锚：i = 自己就是锚；否则队长的下标。</param>
    /// <param name="tile">单位所在格的线性下标（ty * cols + tx）。</param>
    /// <param name="side">单位所属「方」的编号；-1 = 未登记。</param>
    /// <param name="aura">粮车光环给的每秒速率（0 = 没有）。</param>
    /// <param name="zoneOfTile">格 → 区划 id（`zone.lookup`，-1 = 无区划）。</param>
    /// <param name="zoneOwnerSide">区划 id → 归属方的编号（-1 = 无主）。</param>
    /// <param name="zoneSurrounded">区划 id → 1 = 被包围。</param>
    /// <returns>长度 2n 的数组：`[0..n)` = 新士气，`[n..2n)` = 新血量。</returns>
    public double[] Tick(
        byte[] skip,
        int[] anchorIndex,
        double[] morale,
        double[] moraleMax,
        double[] hp,
        double[] hpMax,
        int[] tile,
        int[] side,
        double[] aura,
        int[] zoneOfTile,
        int[] zoneOwnerSide,
        byte[] zoneSurrounded,
        double dt,
        double regenAlly,
        double decayEnemy,
        double decaySurrounded,
        double highTier,
        double midTier,
        double lowTier,
        double regenHigh,
        double regenMid,
        double hpFloor,
        double decayZero,
        double decayLow)
    {
        int n = morale.Length;
        var output = new double[2 * n];
        if (n == 0) return output;

        // 就地数组：队员读「队长这一帧已经写回的值」，所以顺序推进、边写边用。
        var m = new double[n];
        var h = new double[n];
        for (int i = 0; i < n; i++)
        {
            m[i] = morale[i];
            h[i] = hp[i];
        }

        for (int i = 0; i < n; i++)
        {
            if (skip[i] != 0)
            {
                continue;                       // 阵亡 / 濒死：原样不动
            }

            int a = anchorIndex[i];
            if (a != i && a >= 0 && a < n)
            {
                // 队员：镜像锚的权威值（区划升降只由锚算一次）
                m[i] = m[a];
            }
            else
            {
                double rate;
                int zid = -1;
                if (tile[i] >= 0 && tile[i] < zoneOfTile.Length)
                {
                    zid = zoneOfTile[tile[i]];
                }
                bool owned = zid >= 0 && zid < zoneOwnerSide.Length && zoneOwnerSide[zid] >= 0;
                if (owned && side[i] >= 0 && zoneOwnerSide[zid] == side[i])
                {
                    // 己方 / 友方区划：被包围时改判「疲惫」
                    rate = (zid < zoneSurrounded.Length && zoneSurrounded[zid] != 0)
                        ? -decaySurrounded
                        : regenAlly;
                }
                else
                {
                    // 敌方区划与中立区划都算「疲惫」
                    rate = -decayEnemy;
                }
                rate += aura[i];
                double v = m[i] + rate * dt;
                double mx = moraleMax[i];
                m[i] = v < 0.0 ? 0.0 : (v > mx ? mx : v);
            }

            // 生命档位：**每个单位**都用自己当前的士气判（不只锚）——
            // 士气是整支部队共享的，就该整支部队一起回血 / 掉血。
            double hv = h[i];
            double hmax = hpMax[i];
            if (m[i] >= highTier)
            {
                hv = System.Math.Min(hmax, hv + regenHigh * dt);
            }
            else if (m[i] >= midTier)
            {
                hv = System.Math.Min(hmax, hv + regenMid * dt);
            }
            if (m[i] <= 0.0)
            {
                hv = System.Math.Max(hpFloor, hv - decayZero * dt);
            }
            else if (m[i] <= lowTier)
            {
                hv = System.Math.Max(hpFloor, hv - decayLow * dt);
            }
            h[i] = hv;
        }

        for (int i = 0; i < n; i++)
        {
            output[i] = m[i];
            output[n + i] = h[i];
        }
        return output;
    }
}
