// building_hover_outline.gdshader —— 建筑 / 区划中心 / 旗面的**悬停白边 + 选中金边**
//
// ★★ 为什么是「反向壳」而不是后处理描边：
//   建筑是一个个独立的 3D 网格，屏幕上没有一张现成的剪影图。这里沿用低模描边的
//   通用做法：把同一份网格**整体放大**一圈、只画背面（`cull_front`），
//   于是它只在原网格的轮廓外侧露出来 ⇒ 看上去就是一圈描边。
//
// ★ 挂在建筑材质的 `next_pass` 上（见 view/building_view_3d.gd 的 `_outline_pass`）：
//   · 用同一份 MultiMesh 实例数据 ⇒ 变换 / 每实例缩放都不用再传一遍；
//   · `INSTANCE_CUSTOM.b` = 这一实例的**悬停进度**（白边）；
//   · `INSTANCE_CUSTOM.a` = 这一实例的**选中开关**（金边，单位选中同色）；
//   · 两个都是 0 的实例在片元里 `discard` ⇒ 不会给整场建筑套描边。
//
// ★★ 优先级与单位一致：**悬停白色 > 选中金色**。同时选中且悬停时，颜色从金色
//   渐变到白色（`mix(select_color, outline_color, v_hover)`），不透明度取两者较大值。
//
// ★ 深度：主 pass 已经 `depth_draw_always` 写进深度；本 pass 只画背面，
//   被建筑本体挡住的部分深度测试失败 ⇒ 只在轮廓外留下描边（不会盖在建筑正面）。
// ★★ 悬停白边的**不透明度跟着悬停进度走**（`ALPHA = v_hover`）：
//   否则鼠标一放上去白边就整圈出现，而建筑主体还在 0.1s 的淡回过程里 ——
//   看起来像「先亮边、再亮主体 / 底面」，用户会以为是两段动画。
//   同步之后主体与白边是同一条曲线。
//   `depth_draw_opaque`：alpha=1 时才写深度，半透明阶段不会误挡后面的东西。
//
// ★ 描边粗细：`outline_scale` 是**比例**（config: render.building_outline_scale，默认 1.02）。
//   建筑尺寸差异很大（城墙 1 格、区划中心旗杆只有 0.3 格），比例放大的视觉粗细
//   会随建筑变小而变细；这是刻意取舍：同一格网格里墙和塔的描边都还看得见。
//
// ★★ `outline_pivot` 必须是**网格 AABB 的中心**（由 building_view_3d 按网格算好传进来）：
//   模型的原点大多在「底边中心」（y = 0），直接 `VERTEX *= scale` 只会向上 / 向两侧扩，
//   旗面那种原点在**左下角**的网格会缺掉左边和下边的描边。绕 AABB 中心放大之后，
//   四个方向都有白边；向下的那一点会埋进地面，看不见。
shader_type spatial;
render_mode unshaded, cull_front, blend_mix, depth_draw_opaque;

uniform float outline_scale : hint_range(1.0, 1.5) = 1.02;
// 悬停白边颜色（config: render.hover_outline_color）
uniform vec4 outline_color : source_color = vec4(1.0);
// 选中金边颜色（config: render.unit_select_outline_color，与单位选中同一个金）
uniform vec4 select_color : source_color = vec4(0.949, 0.710, 0.267, 1.0);
uniform vec3 outline_pivot = vec3(0.0);

// ⚠️ INSTANCE_CUSTOM 只在 vertex 里可读（同 unit_flash.gdshader 的说明）
varying float v_hover;
varying float v_selected;

void vertex() {
	v_hover = INSTANCE_CUSTOM.b;
	v_selected = INSTANCE_CUSTOM.a;
	VERTEX = outline_pivot + (VERTEX - outline_pivot) * outline_scale;
}

void fragment() {
	float hov = clamp(v_hover, 0.0, 1.0);
	float sel = clamp(v_selected, 0.0, 1.0);
	// 既没悬停也没选中的实例一个像素都不画（本 pass 与主 pass 共用整批实例）。
	if (hov < 0.001 && sel < 0.001) {
		discard;
	}
	// 悬停白边优先于选中金边（与单位选中时「悬停白色覆盖金边」同一条口径）。
	ALBEDO = mix(select_color.rgb, outline_color.rgb, hov);
	// 悬停时跟主体同一条淡入 / 淡出曲线；选中时直接满不透明（选中是即时的）。
	ALPHA = max(hov, sel);
}
