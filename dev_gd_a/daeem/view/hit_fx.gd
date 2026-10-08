## hit_fx.gd —— 受击动效的**共用数学**（闪白 + 左右振动）
##
## ★★ 为什么要有它：同一个「受击左右振动」要在**三处**画出同一件事 ——
##   单位层（`unit_view_3d`）、建筑层（`building_view_3d`）、覆盖层的闪白
##   （`overlay_view_3d`）。三处各写一遍公式，迟早会漂成「单位和闪白抖得不一样」。
##   ⇒ 唯一的一份放在这里。
##
## ★ 纯表现、**无随机数**：相位是 `(1 - flash) × freq`，flash 由逻辑给（1 → 0），
##   所以同一时刻同一 flash 一定得到同一位移 ⇒ 可复现（存档 / 回放不受影响）。
##
## ⚠️ `amp_tiles` / `freq` 由调用方**在 setup 时缓存好**再传进来 ——
##   这个函数在「每单位每帧」的路径上，不许在里面 `cfg.num(...)`。
extends RefCounted


## 左右振动的**横向位移**（逻辑格）：振幅随 flash 衰减，方向按 sin 来回摆。
## flash = 0 ⇒ 0（不再振动）；flash = 1 ⇒ sin(0) = 0（刚被打中那一刻从中间开始摆）。
static func shake_tiles(flash: float, amp_tiles: float, freq: float) -> float:
	if flash <= 0.0:
		return 0.0
	return sin((1.0 - flash) * freq) * flash * amp_tiles
