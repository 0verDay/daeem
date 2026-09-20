# tools/ 说明

## run-tests.ps1 —— 一键跑完所有无头测试

```powershell
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_path   # 只跑名字含 test_path 的
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -List               # 只列出要跑哪些
```

行为：遍历 `tests/test_*.gd`，逐个用

```powershell
<Godot>_console.exe --headless --path <工程根> --script res://tests/test_xxx.gd
```

跑一遍，**靠退出码判定成败**，最后打一张汇总表。任一文件失败或崩溃 → 整体退出码 1。

引擎路径优先取环境变量 `$env:GODOT_EXE`，其次才是本机的
`C:\D\GodotEngine\gd4.7.2mono\Godot_v4.7.2-stable_mono_win64_console.exe`。

> ⚠️ **为什么是 mono 版**：工程里有一份 C# 群体内核（`logic/crowd/*.cs`，
> 1000 单位群编的性能前提）。**普通版 Godot 不会加载 C# 程序集** ——
> 用普通版跑，碰撞会自动退回 GDScript 实现（不会崩，但慢 200 倍），
> 而 `test_csharp_bridge.gd` 会直接红。跑测试请统一用 mono 版。

### 三条不能改的约定

1. **必须用 `_console.exe`**。GUI 版（`..._win64.exe`）会 detach，
   stdout 抓不到、`$LASTEXITCODE` 是空的 —— 那等于测试没有结论。
2. **必须靠退出码**，不要改成解析输出文本。一旦退出码永远返回 0，
   整套测试就变成「永远绿灯」的摆设，比没有测试更糟。
3. **这个 .ps1 文件里只许写 ASCII**。中文 Windows 的 PowerShell 5.1 会把
   无 BOM 的 `.ps1` 当 GBK 解码，任何中文字面量都会变成乱码并**直接解析报错**
   （`-Encoding UTF8` 救不了：引擎在脚本有机会设置编码之前就已经解码完了）。
   所以中文说明放在这个 md 里，脚本本身只输出 `[OK]` / `[FAIL]` / `ALL PASS`。

### 单跑某一个

```powershell
& 'C:\D\GodotEngine\gd4.7.2mono\Godot_v4.7.2-stable_mono_win64_console.exe' `
  --headless --path 'C:\Users\yy197\Documents\GitHub\daeem\dev_gd_a\daeem' `
  --script res://tests/test_smoke.gd
```

只想知道某个脚本**结构上**能不能过（不执行）：

```powershell
& 'C:\D\GodotEngine\gd4.7.2mono\Godot_v4.7.2-stable_mono_win64_console.exe' `
  --headless --path '<工程根>' --check-only --script res://logic/grid.gd
```

`--check-only` 是排查 GDScript 解析/编译问题最快的一条路，
它比跑整个测试更早、更准地指出出错的行号。

## setup-font.ps1 —— 把中文字体拷进 assets/

Godot 默认字体没有中文字形，不装字体的话 HUD 与事件日志全是方框。
跑一次：

```powershell
powershell -ExecutionPolicy Bypass -File tools/setup-font.ps1
```

它从 `C:\Windows\Fonts` 拷一份中文字体到 `assets/fonts/`（**不进 git**，
见根目录 `.gitignore`）。换台机器重新跑一次即可。

## 引擎路径

`C:\D\GodotEngine\...` 只在本机成立。脚本允许用 `$env:GODOT_EXE` 覆盖，
否则换台机器会全跑不了。**不要**为了图省事把引擎拷进工作区（会让仓库变脏）。
