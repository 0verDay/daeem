## expr.gd —— 线性表达式 `y = a·x + b` 的解析与求值（红点波次的时间 / 将领数用）。
##
## 需求原文（红点生成配置）：
##   · 生成频率：输入 y 和 x 的函数表达式，y = 第几波的时间点（分钟），x = 波次，
##     例如 y = x + 1 ⇒ 第 1 波在 2min、第 2 波在 3min；默认 y = x；
##   · 生成的将领数：同样输入函数表达式，y = 将领数，x = 波次。
##   · 「只需要支持常规的 y = ax + b 表达式即可」。
##
## 支持写法（大小写 / 空格随意，`y=` 可省）：
##   ""（空）→ 非法       "x" → a=1, b=0        "-x" → a=-1, b=0
##   "2x" → a=2, b=0      "x+1" → a=1, b=1      "2x+1" / "2x-1"
##   "3" → a=0, b=3       "+x" / "0.5x+0.5"     "1.5x - 0.25"
##
## 解析失败一律返回「非法」（调用方退回默认表达式），**绝不抛错、绝不猜**。
##
## ⚠️ 编辑器侧（`tools/campaign_editor/model.py`）有**同一套语法**的 Python 实现 ——
##    两边必须一起改（和校验 code 那套「编辑器 / 测试 / 运行时逐字一致」同一个道理）。
##
## ⚠️ 跨文件引用只用本文件里的 preload 常量（`--script` 下全局 class_name 不可用）。
extends RefCounted


## 解析成 `[a, b]`；非法 → `[]`（空数组，调用方据此判断）。
##
## ★ 为什么返回数组而不是 Vector2：GDScript 没有「可选值」，
##   而 `Vector2(NAN, NaN)` 这种哨兵一旦被谁拿去算就会静默污染 —— 空数组更明确。
static func coefficients(expr: String) -> Array:
	var s := String(expr).strip_edges().to_lower()
	# 去掉可选的 `y` 与 `=`（`y = x+1` / `= x+1` / `x+1` 都认）。
	if s.begins_with("y"):
		s = s.substr(1).strip_edges()
	if s.begins_with("="):
		s = s.substr(1).strip_edges()
	# 去掉所有空白（"2 x + 1" 也认）。
	s = s.replace(" ", "").replace("\t", "")
	if s == "":
		return []
	var a := 0.0
	var b := 0.0
	var xi := s.find("x")
	if xi >= 0:
		# 只允许出现一个 x。
		if s.rfind("x") != xi:
			return []
		var coef := s.substr(0, xi)          # x 前面的系数部分
		var rest := s.substr(xi + 1)         # x 后面的常数部分
		# 系数："" / "+" → 1，"-" → -1，其余按数字。
		if coef == "" or coef == "+":
			a = 1.0
		elif coef == "-":
			a = -1.0
		else:
			a = _signed_number(coef)
			if is_nan(a):
				return []
		# 常数："" → 0；否则必须带符号（"x1" 这种要判非法）。
		if rest == "":
			b = 0.0
		elif rest.begins_with("+") or rest.begins_with("-"):
			b = _signed_number(rest)
			if is_nan(b):
				return []
		else:
			return []
	else:
		# 没有 x：整串就是一个常数（可以是无符号的，如 "3"）。
		a = 0.0
		b = _signed_number(s)
		if is_nan(b):
			return []
	return [a, b]


## 求值：`y = a·x + b`；表达式非法 → `NAN`（调用方退回默认）。
static func eval_linear(expr: String, x: float) -> float:
	var c := coefficients(expr)
	if c.is_empty():
		return NAN
	return float(c[0]) * x + float(c[1])


## 表达式能不能解析（编辑器校验与测试用）。
static func is_valid(expr: String) -> bool:
	return not coefficients(expr).is_empty()


## 带可选符号的数字："" / "+" / "-" 之类 → NAN；否则返回数值。
static func _signed_number(s: String) -> float:
	if s == "" or s == "+" or s == "-":
		return NAN
	var sign := 1.0
	var body := s
	if s.begins_with("+"):
		body = s.substr(1)
	elif s.begins_with("-"):
		sign = -1.0
		body = s.substr(1)
	if body == "":
		return NAN
	if body.is_valid_float():
		return sign * float(body)
	if body.is_valid_int():
		return sign * float(int(body))
	return NAN
