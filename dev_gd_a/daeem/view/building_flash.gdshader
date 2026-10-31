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
// ★★ 悬停填充：`INSTANCE_CUSTOM.b` 是这一实例的悬停进度（0 = 本体色，1 = 全填），
//   填充色由**批次 uniform** `hover_fill_color` 给（建筑批次 = 一个 owner ⇒ 同批同色；
//   区划中心例外：用**它所属区划**的归属色，见 building_view_3d.gd 的 `_hover_color_of`）。
//   强度 `hover_fill_alpha` 来自 config 的 render.hover_fill_alpha（默认 1.0 = 纯色剪影）。
//   ★ 本体色是按类型暗化过的（墙 / 石墙 / 哨塔各一档），填充色是**纯阵营色** ——
//     两者必须分开，否则悬停时暗色墙会显得像没亮。
// ★★ 2026.10.31：本体色 = 模型顶点色（材质原色）；顶点色的 **alpha 通道当阵营色遮罩**，
//   只有标了 1 的部分（旗 / 屋顶 / 廊柱 / 栅栏）显示阵营色，其余保留原色。
//   悬停填充**不参与**遮罩，保持「纯阵营色剪影」。
// ★★ 白描边 / 选中金边在**另一个 pass**（building_hover_outline.gdshader，挂在
//   `next_pass`），本 shader 只负责「填色 + 把淡出收回去」。
// ★★ 悬停**或选中**时都把「3×3 内有单位 ⇒ 淡出」**收回去**：
//   `fade` 乘 `(1 - max(hov, sel))` ⇒ 悬停进度到 1（或选中）时完全不透明；
//   `hov` 本身按 render.hover_fill_sec（默认 0.1s）淡入 ⇒ 悬停时透明度也是
//   0.1s 淡回；选中是即时的（`.a` = 0/1），所以选中瞬间回到不透明。
//
// ★★ 立体感：场景里**没有灯**，所以这里仍然 `unshaded`，光照由本 shader **自己按面法线算**
//   （假漫反射，见 fragment 的 `shade`）：朝光的面亮、背光的面暗 ⇒ 立方体/模型不再是
//   一块纯色剪影。相机姿态固定（只平移不旋转）⇒ 各面明暗稳定、可复现（存档 / 回放不漂）。
//   ★ 悬停填充也要乘 `shade` —— 否则被悬停的那一栋会比邻居"平"一块。
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_always;

uniform vec4 base_color : source_color = vec4(1.0);
// 悬停填充色（阵营色，由 view/building_view_3d.gd 按批次设）+ 混合强度
uniform vec4 hover_fill_color : source_color = vec4(1.0);
uniform float hover_fill_alpha : hint_range(0.0, 1.0) = 1.0;
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
varying float v_hover;
// 选中状态（0 = 没选中，1 = 选中）：与悬停一样把「靠近淡出」收回去
varying float v_selected;

void vertex() {
	v_flash = INSTANCE_CUSTOM.r;
	v_fade = INSTANCE_CUSTOM.g;
	v_hover = INSTANCE_CUSTOM.b;
	v_selected = INSTANCE_CUSTOM.a;
}

void fragment() {
	// 世界光向 → 视空间（fragment 里的 NORMAL 是视空间；相机不动 ⇒ 这是个常量）
	vec3 l = normalize((VIEW_MATRIX * vec4(normalize(light_dir_world), 0.0)).xyz);
	float d = clamp(dot(normalize(NORMAL), l), 0.0, 1.0);
	float shade = mix(shade_min, shade_max, d);

	float flash = clamp(v_flash * flash_strength, 0.0, 1.0);
	float hov = clamp(v_hover, 0.0, 1.0);
	float sel = clamp(v_selected, 0.0, 1.0);
	float fill = hov * hover_fill_alpha;
	// ★★ 顶点色（GLB 的 COLOR_0）：`rgb` = 模型自带的材质色（木褐 / 石灰 / 陶瓦 / 麦金 / 青矿），
	//   `a` = **阵营色遮罩**（1 = 这块吃阵营色，0 = 保留原色）。
	//   只有旗 / 屋顶 / 廊柱 / 栅栏这类显眼件被标成 1 ⇒ 蓝方不会再把整栋压成青灰；
	//   没有顶点色的老模型（区划中心 / 旗面）缺省 COLOR = (1,1,1,1) ⇒ 整栋仍是阵营色，行为不变。
	//   悬停填充不参与其中，保持「纯阵营色剪影」。
	float mask = clamp(COLOR.a, 0.0, 1.0);
	vec3 body = mix(COLOR.rgb, base_color.rgb, mask);
	vec3 col = mix(body, hover_fill_color.rgb, fill);
	ALBEDO = mix(col, vec3(1.0), flash) * shade;
	// 基础不透明度（base_color.a）× 淡出系数：v_fade = 0 → 不透明，= 1 → fade_alpha；
	// 悬停 / 选中都按 max(hov, sel) 把淡出收回 ⇒ 被指着或选中的那一栋完全可见。
	ALPHA = base_color.a * mix(1.0, fade_alpha,
		clamp(v_fade, 0.0, 1.0) * (1.0 - max(hov, sel)));
}
