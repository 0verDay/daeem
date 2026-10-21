## detail_rows.gd —— 「详细信息」方框里的**两列表格**
##
## ★ 需求：详细信息分两列显示 —— 左列 = 血量 / 攻击力（+攻击增益），
##   右列 = 移动速度 / 防御力（+防御增益）；区划中心则是「类型 / 大小 | 产能」。
##
## ★ 为什么不用两个 Label：
##   · 每一行的字号不一样（主数值 13、增益行 11），Label 只能整块一个字号；
##   · 一行放不下时要**按行缩字 / 截断**，不能整块缩（那会把「血量」也缩成蚂蚁腿）；
##   · 两列的行数不相等（左列 2~4 行、右列 2~6 行），要各自独立往下排。
##
## ★ 行数据：`{"text": String, "small": bool, "dim": bool}`
##   也接受纯字符串（= 普通字号、不暗）。
## ★ 行高固定 `DETAIL_ROW_H`（= 17）：13 号字放得下，116 高的框里正好 6 行。
##   超出的行**不画**（clip_contents 也会裁）—— 目前没有滚动，所以文案不要太长。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")

## 一行最少缩到几号：再小就成蚂蚁腿了，那时应改写文案。
const MIN_FONT := 9

var font: Font = null

var _left: Array = []
var _right: Array = []
## 上一次应用的**内容快照**：HUD 以 10Hz 重喂同一批行时不要反复重画。
var _sig: String = "#none#"
## 画过几帧（测试用：无头下 `_draw` 里的错误不会让测试失败）
var draw_count: int = 0


func setup(p_font: Font = null) -> void:
	font = p_font
	name = "DetailRows"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	custom_minimum_size = Vector2(0.0, UiLayoutRes.DETAIL_BODY_ROWS_H)


## 喂两列的**全部行**（每一行见文件头的字典格式）。
func set_rows(left_rows: Array, right_rows: Array) -> void:
	var next_left: Array = _normalize(left_rows)
	var next_right: Array = _normalize(right_rows)
	var sig := _signature(next_left) + "|" + _signature(next_right)
	if sig == _sig:
		return
	_sig = sig
	_left = next_left
	_right = next_right
	queue_redraw()


func _signature(rows: Array) -> String:
	var parts: PackedStringArray = []
	for row in rows:
		var d: Dictionary = row
		parts.append("%s|%d|%d" % [String(d.get("text", "")),
			int(bool(d.get("small", false))), int(bool(d.get("dim", false)))])
	return "\n".join(parts)


func _normalize(rows: Array) -> Array:
	var out: Array = []
	for row in rows:
		if row is Dictionary:
			var d: Dictionary = row
			out.append({
				"text": String(d.get("text", "")),
				"small": bool(d.get("small", false)),
				"dim": bool(d.get("dim", false)),
			})
		else:
			out.append({"text": String(row), "small": false, "dim": false})
	return out


# ------------------------------------------------------------------
# 画
# ------------------------------------------------------------------

func _draw() -> void:
	draw_count += 1
	var f: Font = font
	if f == null:
		f = get_theme_default_font()
	if f == null:
		return
	# 本控件已经摆在方框内边距之内：左列 x=0，右列 x = 右栏起点 − 内边距
	_draw_column(f, _left, 0.0, UiLayoutRes.DETAIL_BODY_COL_W)
	_draw_column(f, _right,
		UiLayoutRes.DETAIL_BODY_COL2_X - UiLayoutRes.DETAIL_BODY_PAD,
		UiLayoutRes.DETAIL_BODY_COL2_W)


func _draw_column(f: Font, rows: Array, x: float, w: float) -> void:
	for i in rows.size():
		var y: float = float(i) * UiLayoutRes.DETAIL_ROW_H
		# 放不下的行不画（没有滚动；宁可少一行，也不要糊出方框）
		if y + UiLayoutRes.DETAIL_ROW_H > size.y + 0.01:
			return
		var row: Dictionary = rows[i]
		var text: String = String(row.get("text", ""))
		if text == "":
			continue
		var pref: int = UiStyleRes.FS_TINY if bool(row.get("small", false)) \
			else UiStyleRes.FS_SMALL
		var fs: int = _fit_size(f, text, w, pref)
		var color: Color = UiStyleRes.text_dim() if bool(row.get("dim", false)) \
			else UiStyleRes.text()
		var baseline: float = y + UiLayoutRes.DETAIL_ROW_H * 0.5 + float(fs) * 0.5 - 2.0
		draw_string(f, Vector2(x, baseline), _clip_text(f, text, w, fs),
			HORIZONTAL_ALIGNMENT_LEFT, w, fs, color)


## 这一行该用几号字：先按首选字号试，放不下就 1 号 1 号往下缩到 `MIN_FONT`。
func _fit_size(f: Font, text: String, max_w: float, pref: int) -> int:
	var size: int = maxi(MIN_FONT, pref)
	while size > MIN_FONT:
		if f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= max_w:
			return size
		size -= 1
	return size


## 缩到最小字号仍放不下 → 砍尾巴加省略号（`draw_string` 的宽度参数不保证裁剪）。
func _clip_text(f: Font, text: String, max_w: float, size: int) -> String:
	if f == null or text == "":
		return text
	if f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= max_w:
		return text
	var ell := "…"
	var out := text
	while out.length() > 0:
		out = out.substr(0, out.length() - 1)
		var probe := out + ell
		if f.get_string_size(probe, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= max_w:
			return probe
	return ell


# ------------------------------------------------------------------
# 给测试 / detail_panel 读的接口
# ------------------------------------------------------------------

## 两列合回 `左 \t 右` 的文本（右列空时只给左列）。
func text() -> String:
	var out: PackedStringArray = []
	for i in maxi(_left.size(), _right.size()):
		var l: String = _row_text(_left, i)
		var r: String = _row_text(_right, i)
		out.append("%s\t%s" % [l, r] if r != "" else l)
	return "\n".join(out)


func left_text() -> String:
	var out: PackedStringArray = []
	for i in _left.size():
		out.append(_row_text(_left, i))
	return "\n".join(out)


func right_text() -> String:
	var out: PackedStringArray = []
	for i in _right.size():
		out.append(_row_text(_right, i))
	return "\n".join(out)


func left_rows() -> Array:
	return _left


func right_rows() -> Array:
	return _right


func row_count() -> int:
	return maxi(_left.size(), _right.size())


func _row_text(rows: Array, i: int) -> String:
	if i < 0 or i >= rows.size():
		return ""
	return String((rows[i] as Dictionary).get("text", ""))
