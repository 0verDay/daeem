## test_expr.gd —— `logic/expr.gd`（红点波次的 `y = a·x + b` 表达式）的断言。
##
## 覆盖：各种合法写法、非法写法一律判非法、求值正确、默认表达式（`x`）。
## ★ 编辑器侧（`tools/campaign_editor/model.py`）有同一套语法的 Python 实现 ——
##   那边有自己的测试（`test_model.py`），两边必须一起改。
extends "res://tests/test_case.gd"

const ExprRes = preload("res://logic/expr.gd")
const ConfigRes = preload("res://logic/config.gd")


func _initialize() -> void:
	_case_name = "expr"
	run_all(_cases)


func _cases() -> void:
	_test_valid_forms()
	_test_invalid_forms()
	_test_eval()
	_test_default()
	_test_gen_weight_helpers()


func _coef(expr: String) -> Array:
	return ExprRes.coefficients(expr)


func _test_valid_forms() -> void:
	eq(_coef("x"), [1.0, 0.0], "『x』→ a=1, b=0")
	eq(_coef("y=x"), [1.0, 0.0], "『y=x』前缀可省")
	eq(_coef("y = x + 1"), [1.0, 1.0], "带空格 / y= 也认")
	eq(_coef("x+1"), [1.0, 1.0], "『x+1』→ a=1, b=1")
	eq(_coef("2x"), [2.0, 0.0], "『2x』→ a=2, b=0")
	eq(_coef("2x+1"), [2.0, 1.0], "『2x+1』→ a=2, b=1")
	eq(_coef("2x-1"), [2.0, -1.0], "『2x-1』→ a=2, b=-1")
	eq(_coef("-x"), [-1.0, 0.0], "『-x』→ a=-1, b=0")
	eq(_coef("+x"), [1.0, 0.0], "『+x』→ a=1, b=0")
	eq(_coef("0.5x+0.25"), [0.5, 0.25], "小数系数与常数")
	eq(_coef(".5x"), [0.5, 0.0], "『.5x』也认")
	eq(_coef("3"), [0.0, 3.0], "常数（没有 x）")
	eq(_coef("-2.5"), [0.0, -2.5], "负常数")
	eq(_coef("2 x + 1"), [2.0, 1.0], "系数与 x 之间有空格也认")
	eq(_coef("X"), [1.0, 0.0], "大写 X 也认（转小写）")


func _test_invalid_forms() -> void:
	ok(_coef("").is_empty(), "空串判非法")
	ok(_coef("   ").is_empty(), "只有空白判非法")
	ok(_coef("x2").is_empty(), "『x2』判非法（x 后面必须跟符号）")
	ok(_coef("abc").is_empty(), "乱写判非法")
	ok(_coef("2x+1+1").is_empty(), "多段常数判非法")
	ok(_coef("x y").is_empty(), "带 y 的乱写判非法")
	ok(_coef("++x").is_empty(), "『++x』判非法")
	ok(_coef("2x*3").is_empty(), "乘号判非法")
	ok(not ExprRes.is_valid("x/2"), "is_valid 对除号返回假")
	ok(ExprRes.is_valid("x"), "is_valid 对『x』返回真")


func _test_eval() -> void:
	near(ExprRes.eval_linear("x+1", 1.0), 2.0, 1e-6, "y=x+1 在 x=1 → 2（第 1 波 2min）")
	near(ExprRes.eval_linear("x+1", 2.0), 3.0, 1e-6, "y=x+1 在 x=2 → 3（第 2 波 3min）")
	near(ExprRes.eval_linear("2x+1", 1.0), 3.0, 1e-6, "y=2x+1 在 x=1 → 3")
	near(ExprRes.eval_linear("2x+1", 2.0), 5.0, 1e-6, "y=2x+1 在 x=2 → 5")
	near(ExprRes.eval_linear("x", 7.0), 7.0, 1e-6, "y=x 在 x=7 → 7")
	near(ExprRes.eval_linear("3", 100.0), 3.0, 1e-6, "常数表达式与 x 无关")
	ok(is_nan(ExprRes.eval_linear("乱写", 1.0)), "非法表达式求值 → NAN")


func _test_default() -> void:
	# 需求原文：默认表达式为 y = x。
	near(ExprRes.eval_linear("x", 1.0), 1.0, 1e-6, "默认 y=x：第 1 波 1min")
	near(ExprRes.eval_linear("x", 3.0), 3.0, 1e-6, "默认 y=x：第 3 波 3min")


func _test_gen_weight_helpers() -> void:
	# config.gd 的权重表工具（与 expr 同文件族、一并验一下）。
	var list: Array = ConfigRes.normalize_weight_list([
		{"type": "spearman", "weight": 0.7},
		{"type": "rider", "weight": 0.3},
	])
	eq(list.size(), 2, "权重表读进来两项")
	near(ConfigRes.weight_total(list), 1.0, 1e-6, "权重和 = 1")
	eq(ConfigRes.normalize_weight_list([{"type": "x"}]).size(), 0, "没有 weight 的项被丢掉")
	eq(ConfigRes.normalize_weight_list("乱写").size(), 0, "非数组 → 空表")
	var neg: Array = ConfigRes.normalize_weight_list([{"weight": -5.0}])
	eq(neg.size(), 1, "负权重项仍在表里（只是被夹）")
	near(float((neg[0] as Dictionary)["weight"]), 0.0, 1e-6, "负权重被夹成 0")
