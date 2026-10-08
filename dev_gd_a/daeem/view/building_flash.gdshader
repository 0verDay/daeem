// building_flash.gdshader —— 建筑方块：逐像素「受击闪白」
//
// ★ 建筑不 billboard（它是一个立方块），所以没有单位那份立牌代码。
//   尺寸差异由 MultiMesh 的**逐实例缩放**表达（保持原样，这里只改颜色）。
//
// ★ 逐像素闪白：`INSTANCE_CUSTOM.r` 是这一实例的闪白程度（0 = 原色，1 = 纯白），
//   在片元里 `mix(基色, 白, flash)`。基色由 `base_color` 逐批次给（阵营 / 类型色）。
//
// ★ 与原 StandardMaterial3D 对齐：unshaded（不投影）/ cull_back（原 CULL_BACK）。
shader_type spatial;
render_mode unshaded, cull_back;

uniform vec4 base_color : source_color = vec4(1.0);
// 闪白峰值强度（config 的 render.hit_flash_alpha）：1 = 打到纯白，0 = 不闪
uniform float flash_strength : hint_range(0.0, 1.0) = 0.8;

// ⚠️ INSTANCE_CUSTOM 只在 vertex 里可读（见 unit_flash.gdshader 的说明）
varying float v_flash;

void vertex() {
	v_flash = INSTANCE_CUSTOM.r;
}

void fragment() {
	float flash = clamp(v_flash * flash_strength, 0.0, 1.0);
	ALBEDO = mix(base_color.rgb, vec3(1.0), flash);
	ALPHA = base_color.a;
}
