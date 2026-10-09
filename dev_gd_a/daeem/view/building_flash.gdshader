// building_flash.gdshader —— 建筑方块：逐像素「受击闪白」+ 有单位靠近时整栋「淡出」
//
// ★ 建筑不 billboard（它是一个立方块），所以没有单位那份立牌代码。
//   尺寸差异由 MultiMesh 的**逐实例缩放**表达（保持原样，这里只改颜色 / 透明度）。
//
// ★★ `depth_draw_always` 是这里的**关键一行**（别删）：
//   本 shader 写 `ALPHA` ⇒ 引擎把建筑归到**透明管线**，而透明管线**默认不写深度**。
//   后果：建筑之间的遮挡变成「谁后画谁在上」——所有批次的节点原点都在 (0,0,0)，
//   MultiMesh 内部也不排序 ⇒ 近的建筑会被远的盖住（用户报的 bug）。
//   强制写深度之后：不管谁先画，**近的都正确挡住远的**（实测：同一 MultiMesh
//   里「近 idx0 / 远 idx1」在加这一行前是远的在上、加了一行后是近的在上）。
//
// ★ 逐像素闪白：`INSTANCE_CUSTOM.r` 是这一实例的闪白程度（0 = 原色，1 = 纯白）。
// ★ 淡出：`INSTANCE_CUSTOM.g` 是这一实例的淡出程度（0 = 不透明，1 = 淡到 `fade_alpha`）。
//   两者都走每实例自定义数据 ⇒ 一批共用材质、不必逐实例换材质。
//
// ★★ 立体感：场景里**没有灯**，所以这里仍然 `unshaded`，光照由本 shader **自己按面法线算**
//   （假漫反射，见 fragment 的 `shade`）：朝光的面亮、背光的面暗 ⇒ 立方体/模型不再是
//   一块纯色剪影。相机姿态固定（只平移不旋转）⇒ 各面明暗稳定、可复现（存档 / 回放不漂）。
//
// ★ 与原来对齐：unshaded（不投影阴影）/ cull_back。
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_always;

uniform vec4 base_color : source_color = vec4(1.0);
// 闪白峰值强度（config 的 render.hit_flash_alpha）：1 = 打到纯白，0 = 不闪
uniform float flash_strength : hint_range(0.0, 1.0) = 0.8;
// 有单位靠近时整栋淡到的不透明度（config 的 render.building_fade_alpha）
uniform float fade_alpha : hint_range(0.0, 1.0) = 0.3;
// ★★ 假光照（立体感）：
//   · light_dir_world = **指向光源**的方向（世界空间，从上方略偏前左）；
//   · shade_min / shade_max = 最暗面 / 最亮面的亮度倍率。
//   · shade_min = 1.0 等价于**关掉假光照**（所有面同亮 ⇒ 退回原来的平面观感）。
uniform vec3 light_dir_world = vec3(-0.5, 0.9, 0.6);
uniform float shade_min : hint_range(0.0, 1.0) = 0.6;
uniform float shade_max : hint_range(0.0, 2.0) = 1.0;

// ⚠️ INSTANCE_CUSTOM 只在 vertex 里可读（见 unit_flash.gdshader 的说明）
varying float v_flash;
varying float v_fade;

void vertex() {
	v_flash = INSTANCE_CUSTOM.r;
	v_fade = INSTANCE_CUSTOM.g;
}

void fragment() {
	// 世界光向 → 视空间（fragment 里的 NORMAL 是视空间；相机不动 ⇒ 这是个常量）
	vec3 l = normalize((VIEW_MATRIX * vec4(normalize(light_dir_world), 0.0)).xyz);
	float d = clamp(dot(normalize(NORMAL), l), 0.0, 1.0);
	float shade = mix(shade_min, shade_max, d);

	float flash = clamp(v_flash * flash_strength, 0.0, 1.0);
	ALBEDO = mix(base_color.rgb, vec3(1.0), flash) * shade;
	// 基础不透明度（base_color.a）× 淡出系数：v_fade = 0 → 不透明，= 1 → fade_alpha
	ALPHA = base_color.a * mix(1.0, fade_alpha, clamp(v_fade, 0.0, 1.0));
}
