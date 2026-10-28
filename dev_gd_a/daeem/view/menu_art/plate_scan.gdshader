// plate_scan.gdshader —— 主菜单左侧那张「雕版图」的**扫描金线**
//
// 输入是一张**只有线**的蒙版（assets/menu/menu_plate.png：白线 + alpha），
// 所以这里只做三件事：
//   1. 底色：线一直是看得见的（base），不然大多数时间左边是一片黑；
//   2. 扫描：一道很窄的亮前沿从左往右走，扫过的线**留一点余晖**再慢慢回落；
//   3. 上色：线色来自 theme.palette.art_line（uniform，不烤进贴图）。
//
// ★ 为什么用 shader 而不是把线切成一条条竖带各自调透明度：
//   竖带在扫过时会一格一格地跳（一条带子整段同时变亮），而线是斜的、横的都有；
//   这里按**像素到扫描前沿的距离**取值，任何方向的线都是被「扫」亮的。
//
// ★ 线色没有 premultiply：COLOR.rgb 是纯色，ALPHA 才带蒙版 —— 保持直通 alpha。
shader_type canvas_item;

// 线色（运行时由 etched_plate.gd 从 theme.palette.accent 灌进来）
uniform vec4 line_color : source_color = vec4(0.949, 0.710, 0.267, 1.0);
// 扫描头那一小段的颜色（theme.palette.accent_bright）：亮金，就是「被灯扫过」的那一下
uniform vec4 head_color : source_color = vec4(1.0, 0.851, 0.541, 1.0);
// 扫描头所在的 uv.x（-0.06 刚进画、1.06 已出画）
uniform float scan_x : hint_range(-0.2, 1.2) = -0.2;
// 亮前沿的半宽（uv 单位）。0.02 ≈ 26px，太宽就成了一整片，看不出「在扫」
uniform float band : hint_range(0.004, 0.2) = 0.04;
// 扫过之后的余晖长度（uv 单位）。越大拖得越长
uniform float decay : hint_range(0.02, 0.8) = 0.30;
// 底色浓度：一点都不亮的话，两次扫描之间左边就是空的
uniform float base : hint_range(0.0, 1.0) = 0.32;
// 扫描时额外提亮多少
uniform float glow : hint_range(0.0, 3.0) = 0.95;
// 整体不透明度（配置里的 menu.plate.opacity）
uniform float opacity : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	// ★★ 进来时的 COLOR 就是引擎注入的 modulate（含 self_modulate）。
	//    下面会整个重写 COLOR，所以**必须**先把它存下来再乘回去 ——
	//    否则 `node.modulate.a` 这条淡入会完全失效：材质那一帧全亮，
	//    看上去就是「雕版一步到位显现」（实测：alpha 从 0 爬到 1，画面亮度一动不动）。
	vec4 tint = COLOR;

	vec4 tex = texture(TEXTURE, UV);
	float m = tex.a;

	float dx = scan_x - UV.x;

	// 前沿：高斯 + 只照亮**还没扫到的地方之外**（dx<0 是右前方，不亮）
	float head = exp(-pow(dx / max(band, 0.0001), 2.0));
	head *= smoothstep(-band * 0.9, 0.0, dx);

	// 余晖：扫过之后按距离线性回落（平方一下收得更快，像余温）
	float trail = clamp(1.0 - dx / max(decay, 0.0001), 0.0, 1.0) * step(0.0, dx);
	trail *= trail;

	float lit = base + glow * (head * 0.90 + trail * 0.55);
	float a = clamp(m * lit, 0.0, 1.0) * opacity;

	// 扫描头那一段往亮金偏（head 是 0~1，两端各取一次色就够，不用另做贴图）
	vec3 c = mix(line_color.rgb, head_color.rgb, clamp(head * 1.2, 0.0, 1.0));
	COLOR = vec4(c * tint.rgb, a * tint.a);
}
