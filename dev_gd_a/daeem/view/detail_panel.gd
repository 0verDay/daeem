## detail_panel.gd —— 底栏「详细信息」面板（参考图标注的 1030×240）
##
## 内部分栏：
##   左栏 = **选中对象本身的信息**（部队 / 队伍 / 建筑），没选中就写「未选中」
##   右栏 = **阵营 + 粮食 + 黄金**
##
## ★ 按需求砍掉的东西（别再默默加回来）：
##   · 己方地块 / 区块 / 建造模式 / 暂停 —— 都不显示
##   · **整块事件日志** —— 日志栏已经删掉（事件仍然由 logic 收集，只是没有界面画它，
##     见 view/hud.gd 末尾那段说明）
##   · 左栏的各种操作提示（左键选单位 / 右键移动 / 快捷键…）
##
## ★ 只负责显示：文本从哪来由 hud.gd 决定。
extends PanelContainer

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")

var _body: Label
var _status: Label


func setup() -> void:
	name = "DetailPanel"
	mouse_filter = Control.MOUSE_FILTER_STOP
	var s := UiStyleRes.panel_style()
	s.set_content_margin_all(UiLayoutRes.DETAIL_PAD)
	add_theme_stylebox_override("panel", s)
	UiLayoutRes.apply_rect(self, UiLayoutRes.DETAIL_RECT, false, true)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 14)
	cols.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(cols)

	# ---- 左栏：选中对象的信息 ----
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 4)
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cols.add_child(left)

	var title := Label.new()
	title.text = "详细信息"
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.add_theme_font_size_override("font_size", UiStyleRes.FS_SMALL)
	title.add_theme_color_override("font_color", UiStyleRes.ACCENT)
	left.add_child(title)

	_body = Label.new()
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)
	_body.add_theme_color_override("font_color", UiStyleRes.TEXT)
	left.add_child(_body)

	# ---- 右栏：阵营 + 资源 ----
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(UiLayoutRes.DETAIL_RIGHT_W, 0.0)
	right.add_theme_constant_override("separation", 4)
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cols.add_child(right)

	_status = Label.new()
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)
	_status.add_theme_color_override("font_color", UiStyleRes.TEXT_DIM)
	right.add_child(_status)


# ------------------------------------------------------------------
# 显示
# ------------------------------------------------------------------

func set_detail(text: String) -> void:
	if _body != null:
		_body.text = text


## 右栏：阵营 + 资源（多行也可以，长了会自动折行）
func set_status(text: String) -> void:
	if _status != null:
		_status.text = text


# ------------------------------------------------------------------
# 给测试用的小接口
# ------------------------------------------------------------------

func detail_text() -> String:
	return _body.text if _body != null else ""


func status_text() -> String:
	return _status.text if _status != null else ""


## 日志栏是否还在（按需求它必须**不在**：这条断言防止有人顺手加回来）
func has_log() -> bool:
	return get_node_or_null("LogBox") != null
