// map_border.gdshader —— 地图边界的**金线**（view/map_border_view.gd 用）
//
// 这一层只干两件事：
//   ① **渐变带**的透明度：形状由**几何**给（顶点色 alpha：金线本体 1 → 渐变末端 0），
//      这里只把它搬到 ALPHA 上 —— 不在 shader 里再算一遍「离边界多远」；
//   ② **由上往下的扫描**：按世界 z 算一条软边扫掠带，带心把透明度抬到 `scan_alpha`，
//      带外压到 `dim_alpha`（即「平时暗一些，扫到时亮起来」）。
//
// ★★ 为什么扫描必须在**片元**里算，不能在顶点里算（网格一共只有 12 个顶点）：
//   上下两条边**整条共用一个 z** ⇒ 顶点级的带子落在它们身上，插值出来是「整条一起亮」，
//   永远看不到「一段光带扫过去」。按片元算才是那效果。
//
// ★ 写 `ALPHA` ⇒ 引擎按透明管线画它。线在地面**之外**的虚空上、不与任何东西重叠
//   （拐角处相邻两条边共用顶点、也不重叠）⇒ 不需要强制写深度，不会双层叠加。
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform vec4 line_color : source_color = vec4(1.0, 0.8196, 0.4, 1.0);
// 扫掠带**中心**的世界 z（每帧由 view 推进）
uniform float scan_z = 0.0;
// 扫掠带的**半**长（世界单位）。★ ≤ 0 = 关掉扫描：整条线都用 scan_alpha（即不打折）
uniform float scan_half = 0.0;
// 没被扫到时的不透明度（config 的 render.map_border_dim_alpha）
uniform float dim_alpha : hint_range(0.0, 1.0) = 0.45;
// 被扫到（带心）时的不透明度（config 的 render.map_border_scan_alpha）
uniform float scan_alpha : hint_range(0.0, 1.0) = 1.0;

// ⚠️ 顶点色只在 vertex 阶段取，再自己传下去（与 unit_flash / selection_ring 那套同一条约定：
//    「逐顶点 / 逐实例的数据在 vertex 里读」）
varying float v_fade;   // 几何写好的渐变形状（金线本体 1 → 渐变末端 0）
varying float v_z;      // 世界 z：扫描按它定位

void vertex() {
	v_fade = COLOR.a;
	v_z = (MODEL_MATRIX * vec4(VERTEX, 1.0)).z;
}

void fragment() {
	// 扫掠权重：到带心的距离在 scan_half 处归零，再过一次 smoothstep 做软边（三角形核）
	float k = 1.0;
	if (scan_half > 0.0) {
		k = 1.0 - clamp(abs(v_z - scan_z) / scan_half, 0.0, 1.0);
		k = k * k * (3.0 - 2.0 * k);
	}
	ALBEDO = line_color.rgb;
	ALPHA = v_fade * mix(dim_alpha, scan_alpha, k);
}
