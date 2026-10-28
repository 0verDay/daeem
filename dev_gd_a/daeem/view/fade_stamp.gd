## fade_stamp.gd —— 「3×3 内有可见单位」的**按格位图**（纯工具：无节点、无跨帧状态）。
##
## ★★ 为什么要有它（2026.10.28 性能）：
##   `unit_view_3d.sync()` 每帧产出一张「可见单位所在格」的字典（`fade_marked()`），
##   两个消费方（`building_view_3d` / `terrain_props_view`）判断
##   「这一栋建筑 / 这一棵树该不该淡出」时，原来的写法是**逐个对象**做 9 次
##   `Dictionary.has(Vector2i(...))` —— 每次都要新建一个 `Vector2i` 再算哈希。
##
##   量级：树按 `tree_spacing = 0.5` 撒 ⇒ 每格 4 个候选点，29×22 的图约 700 棵、
##   100×100 的图可达上万棵；城墙上限 240 段。于是**每帧**就是 6k~90k 次
##   「分配 + 哈希」——而它只是回答一个是非题。
##
##   这里把方向倒过来：**先由单位那一侧把 3×3 铺进位图**（每单位 9 次整数写，
##   66 个单位 = 594 次），消费方只做**一次数组下标**（`at()` / 直接读 `stamp[t]`）。
##
## ★ 等价性（这是唯一需要被信任的一条）：
##     `stamp[t] != 0`  ⇔  原来的「`marked` 里存在一个格 `m`，使 `t` 落在 `m` 的 3×3 内」。
##   两侧的 3×3 定义完全相同：`|dx| <= 1 && |dy| <= 1`（含自己那一格）。
##   贴边时**只铺地图内**的格：地图外的邻居本来就不可能有建筑 / 树，
##   所以「没铺到」与「原来 `has()` 判 false」等价。
##
## ★ 它只服务**纯表现**（树 / 山块 / 建筑变半透明的条件），
##   不参与任何玩法判定 —— 与 `unit_view_3d.fade_marked()` 同一条纪律。
extends RefCounted


## 由「单位所在格」的字典铺成位图。返回长度 = `cols * rows`，1 = 该格在某个单位的 3×3 内。
##
## @param marked 键是 `Vector2i`（单位所在格），值忽略
## @return PackedByteArray（`cols`/`rows` 非法时返回空数组）
static func build(marked: Dictionary, cols: int, rows: int) -> PackedByteArray:
	var out := PackedByteArray()
	if cols <= 0 or rows <= 0:
		return out
	out.resize(cols * rows)
	out.fill(0)
	# ★ 没有单位可见时直接返回一张全 0 的位图：调用方靠「与上一帧相同」整段跳过。
	if marked.is_empty():
		return out
	for key in marked.keys():
		var t: Vector2i = key
		if t.x < 0 or t.y < 0 or t.x >= cols or t.y >= rows:
			continue
		var y0: int = maxi(0, t.y - 1)
		var y1: int = mini(rows - 1, t.y + 1)
		var x0: int = maxi(0, t.x - 1)
		var x1: int = mini(cols - 1, t.x + 1)
		var y: int = y0
		while y <= y1:
			var row: int = y * cols
			var x: int = x0
			while x <= x1:
				out[row + x] = 1
				x += 1
			y += 1
	return out


## 某一格在不在「3×3 内有可见单位」里（越界 / 空位图 → false）。
static func at(stamp: PackedByteArray, tx: int, ty: int, cols: int) -> bool:
	if stamp.is_empty() or cols <= 0 or tx < 0 or ty < 0:
		return false
	var idx: int = ty * cols + tx
	return idx < stamp.size() and stamp[idx] != 0
