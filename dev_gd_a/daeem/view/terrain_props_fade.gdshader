// terrain_props_fade.gdshader —— 靠近单位的树 / 山块的**淡出层**
//
// ★★ 为什么不直接在主 shader 里写 ALPHA（与建筑不同）：
//   树和山是**几百个实例的 MultiMesh**，一旦写 ALPHA 就整体进透明管线；
//   而透明管线默认不写深度 ⇒ 树与树的前后关系会乱（近的被远的盖住）。
//   建筑能写 ALPHA 是因为它用 `depth_draw_always` 强行写深度，但那又会让
//   **淡出的树挡住后面的单位**（单位是透明 billboard，被树的深度判掉）。
//
// ⇒ 这里拆成两批：
//   · 主批（`terrain_props.gdshader`）保持**不透明**：正常遮挡、深度正确；
//   · 本层只在“3×3 内有可见单位”时接管那几棵树 / 山块，**不写深度**，
//     并靠 `render_priority = -1` 画在单位**之前** ⇒ 单位始终叠在淡出的树上面。
//
// ★ 颜色 / 假光照与主 shader 完全一致，只是多了固定不透明度 `fade_alpha`。
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_opaque;

uniform float fade_alpha : hint_range(0.0, 1.0) = 0.30;
uniform float ambient : hint_range(0.0, 1.0) = 0.52;
uniform vec3 light_dir = vec3(0.45, 0.85, 0.30);

varying vec3 v_normal_w;
varying vec4 v_inst;

void vertex() {
	v_normal_w = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_inst = INSTANCE_CUSTOM;
}

void fragment() {
	vec3 n = FRONT_FACING ? v_normal_w : -v_normal_w;
	float ndl = max(dot(normalize(n), normalize(light_dir)), 0.0);
	float lit = ambient + (1.0 - ambient) * ndl;
	ALBEDO = COLOR.rgb * v_inst.rgb * lit;
	ALPHA = fade_alpha;
}
