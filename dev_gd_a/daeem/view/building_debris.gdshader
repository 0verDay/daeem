// building_debris.gdshader —— 建筑倒塌时的碎块（每个实例一种颜色 + alpha 淡出）
//
// 为什么用 MultiMesh + INSTANCE_CUSTOM：
//   · 一次倒塌有几十块碎片，每块一个 MeshInstance3D = 几十次 draw call；
//   · 碎块颜色来自原模型顶点色的平均值（石 / 木 / 阵营色都可能），
//     用 per-instance custom data 直接当 ALBEDO，一个材质就够；
//   · 需要整体淡出，所以走透明管线（unshaded，避免碎块在暗处看不清）。
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

varying vec4 v_col;

void vertex() {
	v_col = INSTANCE_CUSTOM;
}

void fragment() {
	ALBEDO = v_col.rgb;
	ALPHA = v_col.a;
}
