// story_glow_shell.gdshader —— 建筑 / 区划中心的**演出呼吸外发光外壳**。
//
// ★ 与 building_hover_outline 同一套「反向壳」思路：把同一份网格整体放大一圈、
//   只画背面（cull_front），于是只在轮廓外侧露出一圈光。
//   区别：
//     · 这是**独立的 MultiMesh 层**（view/story_glow_view.gd），不占用主材质的
//       INSTANCE_CUSTOM.b / .a（那两个已经归悬停 / 选中）；
//     · 逐实例强度走 **INSTANCE_CUSTOM.r**（0..1），由视图每帧按呼吸曲线写；
//     · 颜色是**批次 uniform**（同一层同色；视图按颜色分桶）。
//
// ★ 写 ALPHA ⇒ 透明管线；`depth_draw_never`：只做深度测试、不写深度，
//   不会挡住后面的单位 / 建筑。
shader_type spatial;
render_mode unshaded, cull_front, blend_mix, depth_draw_never;

uniform float glow_scale : hint_range(1.0, 1.5) = 1.06;
uniform vec3 glow_pivot = vec3(0.0);
uniform vec4 glow_color : source_color = vec4(1.0, 0.82, 0.4, 1.0);
uniform float alpha_scale : hint_range(0.0, 1.0) = 0.55;

varying float v_glow;

void vertex() {
	v_glow = INSTANCE_CUSTOM.r;
	VERTEX = glow_pivot + (VERTEX - glow_pivot) * glow_scale;
}

void fragment() {
	float a = clamp(v_glow, 0.0, 1.0);
	if (a < 0.001) {
		discard;
	}
	ALBEDO = glow_color.rgb;
	ALPHA = a * alpha_scale;
}
