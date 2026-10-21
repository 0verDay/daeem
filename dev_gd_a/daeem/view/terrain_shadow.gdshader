// terrain_shadow.gdshader —— 道具的**接地暗斑**（假环境光遮蔽）
//
// ★ 为什么要它：场景是 unshaded、没有灯也没有阴影。树/草直接插在地面上时，
//   底部没有明暗过渡，看起来像“贴纸浮在地表”。这里在每棵树底部压一圈柔和暗斑，
//   把物体“钉”在地上 —— 比真的加一盏灯便宜得多，也不会改变其他图层的观感。
//
// ★ 形状由片元的 UV 距离算（网格就是一个 0..1 的方片），不依赖贴图：
//   中心最暗、到边缘归零，`smoothstep` 做软边。
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_opaque, cull_disabled;

uniform vec4 shadow_color : source_color = vec4(0.0, 0.0, 0.0, 0.30);

varying vec2 v_uv;

void vertex() {
	v_uv = UV;
}

void fragment() {
	float d = length(v_uv - vec2(0.5, 0.5));
	float k = 1.0 - smoothstep(0.10, 0.50, d);
	ALBEDO = shadow_color.rgb;
	ALPHA = shadow_color.a * k;
}
