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
// ★★ 悬停填充：`INSTANCE_CUSTOM.g` 是这一实例的悬停进度（0 = 原画，1 = 全填），
//   颜色由**批次 uniform** `hover_fill_color` 给（单位批次 = 一个阵营 ⇒ 同批同色）。
//   `hover_fill_alpha` 是叠色强度（config 的 render.hover_fill_alpha，默认 0.7 ⇒
//   半透明罩色，保留原画明暗）。ALPHA 不动 ⇒ 仍是逐像素剪影、仍走不透明管线。
//   ★ 顺序：先填充、后闪白（受击的白色反馈永远压在最上面）。
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
// 悬停填充色（阵营色，由 view/unit_view_3d.gd 按批次设）+ 叠色强度
uniform vec4 hover_fill_color : source_color = vec4(1.0);
uniform float hover_fill_alpha : hint_range(0.0, 1.0) = 0.7;

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
	// flash = 0 → 原贴图；flash = 1 → 纯白。逐像素（透明处仍透明）。
	float flash = clamp(v_flash * flash_strength, 0.0, 1.0);
	float fill = clamp(v_hover * hover_fill_alpha, 0.0, 1.0);
	vec3 col = mix(tex.rgb, hover_fill_color.rgb, fill);
	ALBEDO = mix(col, vec3(1.0), flash);
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = scissor_threshold;
}
