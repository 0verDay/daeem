// building_edge_outline.gdshader —— 建筑 / 区划中心 / 旗面的**所有折边**描边
//
// ★★ 与 building_hover_outline.gdshader 的分工：
//   · building_hover_outline（反向壳）：只画**外轮廓**，负责把整体轮廓加粗；
//   · 本 shader：给模型上**每一条折边**画一条粗线（网格由 building_edge_ribbon.gd
//     展开成面向相机的 ribbon），所以塔身的竖棱、台阶的水平棱、旗面的四周都有线。
//
// ★ 颜色 / 显隐与反向壳完全一致：
//   · `INSTANCE_CUSTOM.b` = 悬停进度 → 白边；
//   · `INSTANCE_CUSTOM.a` = 选中开关 → 金边；
//   · 悬停白色优先于选中金色（与单位「悬停 > 选中」同一条口径）。
//   ★ 没悬停也没选中的实例 `discard`，不会给整场建筑画满线框。
//
// ★★ 展开在**顶点着色器**里按每个实例的真实视线方向做（不是 CPU 预先展开）：
//   透视相机下屏幕不同位置的视线方向不同，固定方向展开会让下半屏的线带扎进模型、
//   被深度测试整条挡掉（「地图上半建筑每根线都有描边、下半只剩外轮廓」的 bug）。
//   · VERTEX = 折边中心线点；NORMAL = 边方向；UV.x = 侧向（±1）；UV.y = 线宽（局部单位）；
//   · 在视图空间里取 `to_cam`（相机在原点）算侧向、并沿 `to_cam` 抬一个 bias；
//   · 最后把 MODELVIEW_MATRIX 置为单位阵，VERTEX 直接当视图空间坐标输出。
//
// ★ 深度：抬 bias 后正面的折边浮在表面之上；背面的折边仍在正面表面之后，被深度挡住。
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_opaque;

// 悬停白边 / 选中金边（config: render.hover_outline_color / unit_select_outline_color）
uniform vec4 hover_color : source_color = vec4(1.0);
uniform vec4 select_color : source_color = vec4(0.949, 0.710, 0.267, 1.0);

varying float v_hover;
varying float v_selected;

void vertex() {
	v_hover = INSTANCE_CUSTOM.b;
	v_selected = INSTANCE_CUSTOM.a;

	// 实例缩放（建筑是「格宽 × body_scale」；方块类 y 可能不同，用横向缩放做线宽基准）
	float inst_scale = length(MODELVIEW_MATRIX[0].xyz);

	// 中心线点 / 边方向 → 视图空间（相机在视图空间的原点）
	vec4 p_view = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec3 edge_dir = (MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
	if (dot(edge_dir, edge_dir) < 1e-12) {
		edge_dir = vec3(0.0, 1.0, 0.0);
	}
	edge_dir = normalize(edge_dir);

	// 相机 → 该点方向的**反向**（沿它抬 bias 就浮向相机）
	vec3 to_cam = -normalize(p_view.xyz + vec3(0.0, 0.0, 1e-9));
	vec3 side = cross(edge_dir, to_cam);
	if (dot(side, side) < 1e-10) {
		side = cross(edge_dir, vec3(0.0, 1.0, 0.0));
	}
	side = normalize(side);

	float half_w = UV.y * 0.5 * inst_scale;
	float bias = max(0.003, UV.y * 0.2) * inst_scale;
	p_view.xyz += side * half_w * UV.x + to_cam * bias;

	// 已经算到视图空间：模型视图矩阵置为单位阵，VERTEX 直接当视图空间坐标输出。
	MODELVIEW_MATRIX = mat4(1.0);
	VERTEX = p_view.xyz;
}

void fragment() {
	float hov = clamp(v_hover, 0.0, 1.0);
	float sel = clamp(v_selected, 0.0, 1.0);
	if (hov < 0.001 && sel < 0.001) {
		discard;
	}
	ALBEDO = mix(select_color.rgb, hover_color.rgb, hov);
	ALPHA = max(hov, sel);
}
