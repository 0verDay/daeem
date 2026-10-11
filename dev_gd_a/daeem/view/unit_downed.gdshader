// unit_downed.gdshader —— 濒死将领立牌：billboard + 整体半透明
//
// ★★ 为什么要单独一个 shader（而不是给 unit_flash 加个 uniform 开关）：
//   是否写 `ALPHA` / 有没有 `ALPHA_SCISSOR_THRESHOLD` 决定的是**编译期**的渲染管线，
//   一个 uniform 切不过来。正常单位走 `unit_flash.gdshader`（写 ALPHA + scissor ⇒
//   **不透明管线**、深度正确）；濒死将领要**平滑半透明**，就必须走透明管线 ⇒ 拆成两个。
//   ★ billboard 那一段与 `unit_flash.gdshader` **逐字一致**（两者共用同一块 QuadMesh，
//     朝向必须一模一样，否则濒死/正常两种状态会"换个角度看"）。
//
// ★ 不写 `ALPHA_SCISSOR_THRESHOLD`：那会把半透明又变回"要么全有、要么全无"。
// ★ 不闪白：濒死将领无敌、不再吃伤害（见 logic/unit.gd 的 take_damage）。
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2D albedo_tex : filter_linear_mipmap_anisotropic;
// 濒死立牌的透明度（config 的 render.downed_alpha）
uniform float downed_alpha : hint_range(0.0, 1.0) = 0.4;

void vertex() {
	// 面向相机的立牌：用相机基向量替换模型的旋转，只保留实例的平移（与 unit_flash 同一段）
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]);
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	ALBEDO = tex.rgb;
	// 整体半透明 ⇒ 引擎按透明管线渲染（这几面立牌不写深度，只有濒死将领受影响）
	ALPHA = tex.a * downed_alpha;
}
