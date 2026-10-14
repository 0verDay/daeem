## test_expr.gd —— `logic/expr.gd`（红点波次的 `y = a·x + b` 表达式）的断言。
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
	_test_gen_weight_helpers()

func _coef(expr: String) -> Array:
	return ExprRes.coefficients(expr)

func _test_valid_forms() -> void:
	eq(_coef("x"), [1.0, 0.0], "『x』→ a=1, b=0")
	eq(_coef("y = x + 1"), [1.0, 1.0], "带空格 / y= 也认")
	eq(_coef("2x+1"), [2.0, 1.0], "『2x+1』→ a=2, b=1")
	eq(_coef("-x"), [-1.0, 0.0], "『-x』→ a=-1, b=0")
	eq(_coef(".5x"), [0.5, 0.0], "『.5x』也认")
	eq(_coef("3"), [0.0, 3.0], "常数（没有 x）")

func _test_invalid_forms() -> void:
	ok(_coef("").is_empty(), "空串判非法")
	ok(_coef("x2").is_empty(), "『x2』判非法（x 后面必须跟符号）")
	ok(_coef("2x+1+1").is_empty(), "多段常数判非法")
	ok(not ExprRes.is_valid("x/2"), "is_valid 对除号返回假")
	ok(ExprRes.is_valid("x"), "is_valid 对『x』返回真")

func _test_eval() -> void:
	near(ExprRes.eval_linear("x+1", 1.0), 2.0, 1e-6, "y=x+1 在 x=1 → 2")
	near(ExprRes.eval_linear("2x+1", 2.0), 5.0, 1e-6, "y=2x+1 在 x=2 → 5")
	near(ExprRes.eval_linear("3", 100.0), 3.0, 1e-6, "常数表达式与 x 无关")
	ok(is_nan(ExprRes.eval_linear("乱写", 1.0)), "非法表达式求值 → NAN")

func _test_gen_weight_helpers() -> void:
	var list: Array = ConfigRes.normalize_weight_list([
		{"type": "spearman", "weight": 0.7},
		{"type": "rider", "weight": 0.3},
	])
	eq(list.size(), 2, "权重表读进来两项")
	near(ConfigRes.weight_total(list), 1.0, 1e-6, "权重和 = 1")
	eq(ConfigRes.normalize_weight_list([{"type": "x"}]).size(), 0, "没有 weight 的项被丢掉")
	eq(ConfigRes.normalize_weight_list("乱写").size(), 0, "非数组 → 空表")
	var neg: Array = ConfigRes.normalize_weight_list([{"weight": -5.0}])
	near(float((neg[0] as Dictionary)["weight"]), 0.0, 1e-6, "负权重被夹成 0")
