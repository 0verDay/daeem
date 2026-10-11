// selection_ring.gdshader —— 选中单位脚下的「绿色空心圆」贴花
//
// ★★ 为什么单独一个 shader（不复用将领贴花的 StandardMaterial3D）：
//   选中下标要**逐实例的透明度动画**（0 → 80%）。StandardMaterial3D 的透明度来自
//   材质 / 贴图，没法按实例给；于是走 `INSTANCE_CUSTOM.r` 当逐实例 alpha。
//   （MultiMesh 的 `use_custom_data` 与闪白那套是同一个机制。）
//
// ★ 写 `ALPHA` ⇒ 透明管线（贴花贴在地面上、不需要写深度，正是想要的）。
// ★ 空心：`albedo_tex` 只有一圈圆环有 alpha，中心是空的。
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2D albedo_tex : filter_linear_mipmap_anisotropic;
// 空心圆的颜色（config 的 render.selection_ring_color，绿）
uniform vec4 ring_color : source_color = vec4(0.24, 0.86, 0.35, 1.0);

// ⚠️ INSTANCE_CUSTOM 只在 vertex 里可读（见 unit_flash.gdshader 的说明）
varying float v_alpha;

void vertex() {
	v_alpha = INSTANCE_CUSTOM.r;   // 逐实例透明度（动画：0 → 峰值）
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	ALBEDO = ring_color.rgb;
	ALPHA = tex.a * clamp(v_alpha, 0.0, 1.0);
}
