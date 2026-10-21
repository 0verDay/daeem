// terrain_water.gdshader —— 水域表面（半透明的一层水面）
//
// ★ 为什么单独一个 shader：水面**不需要假光照**（它是平的、法线朝上，
//   按 terrain_props 那套算出来会是整片同一个亮度），需要的是 alpha 混合。
//   一个 uniform 颜色 + 逐实例压暗系数就够了。
//
// ★ 水面只负责「看起来是水」：抬高 `render.terrain_props.water_lift` 个世界单位，
//   压在烘好的水底色之上；逻辑层的水域判定完全不受影响（这张图不参与任何玩法）。
//
// ★ 逐实例的 `INSTANCE_CUSTOM.rgb` 与地形道具同一套口径：迷雾里按格压暗。
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_opaque;

// 水面颜色（含不透明度）。改这里只影响观感，不改 config 里的地形底色。
uniform vec4 water_color : source_color = vec4(0.18, 0.40, 0.52, 0.55);

varying vec4 v_inst;

void vertex() {
	v_inst = INSTANCE_CUSTOM;
}

void fragment() {
	ALBEDO = water_color.rgb * v_inst.rgb;
	ALPHA = water_color.a;
}
