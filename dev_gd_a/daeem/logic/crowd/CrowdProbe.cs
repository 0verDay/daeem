using Godot;

namespace Daeem.Crowd;

/// <summary>
/// 阶段 0 探针：只用来回答两个问题，回答完就可以删（或者留着当冒烟测试的靶子）。
///
///   1. `--headless --script` 这种无头测试模式下，Godot 到底有没有把 C# 程序集加载起来？
///      —— 如果没加载，整个「C# 内核」方案当场作废，必须先知道。
///   2. 跨语言调用的**粒度**有多贵：1000 次「每次传一个 double」和 1 次「传 1000 个元素」
///      差多少？这个数字直接决定内核接口是按单位划还是按批划。
///
/// ⚠️ Godot 的 C# 要求**文件名 == 类名**（PascalCase），所以这个目录下的 .cs
///    文件名与项目里 GDScript 的 snake_case 约定不同 —— 这是引擎硬要求，不是笔误。
/// </summary>
[GlobalClass]
public partial class CrowdProbe : RefCounted
{
    /// <summary>程序集标识：测试用它确认「跑的是新构建出来的这一份」。</summary>
    public string BuildTag()
    {
        return "daeem-csharp-bridge-1";
    }

    /// <summary>最小实例方法：验证「GDScript 能拿到 C# 对象并调它」。</summary>
    public int Ping()
    {
        return 42;
    }

    /// <summary>最小参数往返：粒度测试的「小接口」那一侧。</summary>
    public double AddScalar(double a, double b)
    {
        return a + b;
    }

    /// <summary>批量入参：粒度测试的「批量接口」那一侧。</summary>
    /// <remarks>
    /// ★ Godot 4 的 C# 绑定里**没有** PackedFloat64Array 这种类型：Packed*Array
    ///   在 C# 侧就是原生数组（PackedFloat64Array ↔ double[]，PackedFloat32Array ↔ float[]）。
    ///   GDScript 传 Packed 数组进来会自动marshal，不需要手写转换。
    /// </remarks>
    public double SumDoubles(double[] values)
    {
        double sum = 0.0;
        for (int i = 0; i < values.Length; i++)
        {
            sum += values[i];
        }
        return sum;
    }

    /// <summary>
    /// 批量出参：验证「C# 造一个数组交回 GDScript」这条回程路能走通 ——
    /// 真正的内核（位置写回、渲染实例缓冲）全靠这条路。
    /// </summary>
    public float[] Twice(float[] values)
    {
        var result = new float[values.Length];
        for (int i = 0; i < values.Length; i++)
        {
            result[i] = values[i] * 2.0f;
        }
        return result;
    }
}
