// terrain_props.gdshader —— 地形道具（树 / 山块）的**假光照**
//
// ★★ 为什么道具不交给引擎打光：整个 3D 场景**没有灯**（地面是 unshaded 的烘焙贴图），
//   加一盏 DirectionalLight3D 会把地面、单位、建筑一起改亮 —— 那是全局观感改动，
//   不是「给地形加装饰」。这里用面法线算一层固定的明暗，只作用于道具自己：
//     亮度 = ambient + (1 - ambient) · max(0, N · L)
//   ⇒ 顶面亮、侧面按朝向分两档，低多边形的硬边能读出体积，而引擎里仍然只有 unshaded。
//
// ★ 颜色来自顶点色：Blender 导出的 glb 里每个面已经按材质写好了基色（COLOR_0），
//   程序化的水也写顶点色 ⇒ 一个材质就能画完一整批，不必按材质拆批次。
//
// ★★ 逐实例的 `INSTANCE_CUSTOM.rgb` 是**迷雾压暗系数**（1 = 看得见，0.55 = 被迷雾盖住）：
//   地面靠 `ground_view` 的迷雾平面变暗，道具高过那块平面（y = 1.5），压不到它们，
//   所以只能在这里按格自己乘。见 view/terrain_props_view.gd 的 `_apply_fog`。
//
// ★ `cull_disabled`：水面是单层面片，从低角度看也要看得见；树/山块是闭合网格，多画一层无妨。
shader_type spatial;
render_mode unshaded, cull_disabled;

// 没被光照到的面有多亮（只影响道具，与地面底色无关）
uniform float ambient : hint_range(0.0, 1.0) = 0.52;
// 世界空间的光照方向（相机固定俯视，用世界上方偏一侧即可，不需要真的灯）
uniform vec3 light_dir = vec3(0.45, 0.85, 0.30);

varying vec3 v_normal_w;
varying vec4 v_inst;

void vertex() {
	// ⚠️ MODEL_MATRIX 在 MultiMesh 里**已经包含逐实例变换**（含旋转/缩放），
	//    所以这里算出来就是世界法线；实例是等比缩放，不需要法线矩阵。
	v_normal_w = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// 逐实例数据在 vertex 里取，再传给 fragment（与 map_border 那套同一条约定）
	v_inst = INSTANCE_CUSTOM;
}

void fragment() {
	// 背面（草叶另一半）把法线翻过来，否则背面会全黑
	vec3 n = FRONT_FACING ? v_normal_w : -v_normal_w;
	float ndl = max(dot(normalize(n), normalize(light_dir)), 0.0);
	float lit = ambient + (1.0 - ambient) * ndl;
	ALBEDO = COLOR.rgb * v_inst.rgb * lit;
}
