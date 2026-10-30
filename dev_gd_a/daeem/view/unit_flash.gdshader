// unit_flash.gdshader —— 单位的立牌：billboard + 逐像素「受击闪白」
//
// ★★ 为什么必须自己写 billboard（本文件最容易踩的地方）：
//   `BaseMaterial3D.billboard_mode` 只在**引擎的默认材质**里有效；换成自定义 ShaderMaterial
//   之后那个开关**完全不生效**。所以要在这里用相机的基向量重建 MODELVIEW 矩阵 ——
//   等价于原来的 `BILLBOARD_ENABLED`（面向相机、只保留实例的**平移**）。
//   ⚠️ 立牌实例的变换里没有缩放（`Transform3D(Basis(), w)`），所以丢掉 basis 是安全的。
//
// ★ 逐像素闪白：闪白程度走**每实例自定义数据** `INSTANCE_CUSTOM.r`（MultiMesh 的
//   `set_instance_custom_data`），在片元里 `mix(贴图, 白, flash)` ⇒ 贴图不透明的地方
//   整块变白，透明的地方仍然是透明的（不是盖一个白方块，而是**逐像素**）。
//
// ★★ 悬停样式：`INSTANCE_CUSTOM.g` 是这一实例的悬停进度（0 = 原画，1 = 全换）。
//   悬停长什么样**烘在另一张贴图** `hover_tex` 里：纯阵营色躯体 + 一圈白描边
//   （见 view/unit_sprite_3d.gd 的 `bake_asset(..., hover = true)`）。两张图的**剪影
//   覆盖范围**逐像素对齐（白边更实，所以 alpha 数值更高）⇒ 交叉混合时剪影不会变。
//   `hover_fill_alpha` 是混合强度（config 的 render.hover_fill_alpha，默认 1.0 =
//   完全换成悬停贴图；调低会保留一部分原画）。
//   ★ 顺序：先悬停混合、后闪白（受击的白色反馈永远压在最上面）。
//
// ★ 与原来的 StandardMaterial3D 逐条对齐（换了材质别把观感换掉）：
//   unshaded（不投影、不吃光）/ cull_disabled（billboard 极端角度能看到背面）/
//   ALPHA_SCISSOR_THRESHOLD = 0.35（透明区不参与混合）/ 贴图用线性 + mipmap + 各向异性。
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2D albedo_tex : filter_linear_mipmap_anisotropic;
uniform float scissor_threshold : hint_range(0.0, 1.0) = 0.35;
// 闪白峰值强度（config 的 render.hit_flash_alpha）：1 = 打到纯白，0 = 不闪
uniform float flash_strength : hint_range(0.0, 1.0) = 0.8;
// 悬停贴图（纯阵营色 + 白描边，由 view/unit_view_3d.gd 按批次烘）+ 混合强度
// ⚠️ `source_color` 不能省：这张图是 CPU 直接写 sRGB 值的 ImageTexture，
//   不加这个提示引擎会把它当线性色采样 ⇒ 阵营色整体发白（实测 #5ac8ff 变成 #a0e5ff）。
//   只加在 hover_tex 上：原画贴图保持现有观感不变（本轮不动常态单位）。
uniform sampler2D hover_tex : source_color, filter_linear_mipmap_anisotropic;
uniform float hover_fill_alpha : hint_range(0.0, 1.0) = 1.0;

// ⚠️ INSTANCE_CUSTOM 只在 **vertex** 里可读（实测：直接写进 fragment 会报
//    `Unknown identifier: INSTANCE_CUSTOM`）⇒ 用 varying 传到片元。
varying float v_flash;
varying float v_hover;

void vertex() {
	// 面向相机的立牌：用相机基向量替换模型的旋转，只保留实例的平移。
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]);
	v_flash = INSTANCE_CUSTOM.r;
	v_hover = INSTANCE_CUSTOM.g;
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	vec4 hov = texture(hover_tex, UV);
	// flash = 0 → 原贴图；flash = 1 → 纯白。逐像素（透明处仍透明）。
	float flash = clamp(v_flash * flash_strength, 0.0, 1.0);
	float fill = clamp(v_hover * hover_fill_alpha, 0.0, 1.0);
	vec3 col = mix(tex.rgb, hov.rgb, fill);
	ALBEDO = mix(col, vec3(1.0), flash);
	// ★ alpha 也从原贴图混向悬停贴图：悬停贴图的描边是**满不透明**的白边
	//   （原贴图的普通描边是 0.72），不混的话白边会显得发灰。
	//   两张图的**覆盖范围**逐像素一致 ⇒ 只是描边更实，剪影不会变大。
	ALPHA = mix(tex.a, hov.a, fill);
	ALPHA_SCISSOR_THRESHOLD = scissor_threshold;
}
