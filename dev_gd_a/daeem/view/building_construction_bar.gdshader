// building_construction_bar.gdshader —— 建筑「建造中」的头顶进度条（3D billboard 批次）
//
// ★ 为什么是 3D 而不是画在 2D overlay 里：进度条要跟着建筑走（升到多高、在哪里），
//   3D 侧已经有 `palette.to_world()` 与模型高度，不必再往 overlay 塞一条「世界→屏幕」的耦合。
// ★★ 一个 MultiMesh 画全部在建建筑：进度 / 透明度走 **每实例自定义数据**
//   （`.r` = 进度 0~1，`.g` = 透明度），与建筑本体的 flash shader 同一套手法 ⇒ 1 次 draw call。
// ★ 相机**只平移不旋转**（见 building_view_3d 文件头）⇒ 朝向由 view 侧每帧按相机基向量算好，
//   这里不需要 `render_mode billboard`。
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

varying float v_prog;
varying float v_alpha;

void vertex() {
	v_prog = INSTANCE_CUSTOM.r;
	v_alpha = INSTANCE_CUSTOM.g;
}

void fragment() {
	vec2 uv = UV;
	// 外框（深色底）+ 内芯（填到 progress 为止的金色）
	float bx = 0.055;
	vec4 col = vec4(0.04, 0.05, 0.07, 0.82);
	bool inner = uv.x > bx && uv.x < 1.0 - bx && uv.y > 0.22 && uv.y < 0.78;
	if (inner) {
		float w = 1.0 - 2.0 * bx;
		float filled = uv.x < bx + w * clamp(v_prog, 0.0, 1.0) ? 1.0 : 0.0;
		vec3 empty_col = vec3(0.17, 0.18, 0.21);
		vec3 fill_col = vec3(0.96, 0.80, 0.30);
		col.rgb = mix(empty_col, fill_col, filled);
	}
	col.a *= v_alpha;
	ALBEDO = col.rgb;
	ALPHA = col.a;
}
