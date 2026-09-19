@echo off
chcp 65001 >nul
setlocal
rem =====================================================================
rem  DAEEM 地图编辑器 —— 双击本文件即可打开（不用敲命令行）
rem
rem  可选：把一张地图 JSON 拖到本文件上 -> 直接打开那张图。
rem
rem  ⚠️ 实测结论，改这个文件前先看：
rem   1. 开窗口必须用 `start "" pythonw <包目录> <地图>`：
rem      裸 `pythonw ...` 与 `start "" python ...` 起的窗口会跟着黑框一起被杀掉
rem      （控制台一退出，GUI 进程被连坐）—— 表现就是「双击了但什么都没发生」。
rem      `start "" pythonw ...` 起的是独立进程：黑框闪一下就没，窗口留得住。
rem   2. 路径里不能留 `..`：用 for %%~fI 规范化。带 `..` 的路径会被 Python 的
rem      pathlib 当成「真的叫 .. 的目录」，地图文件打不开、窗口一闪就没。
rem   3. 目录层级别数错：本文件在 dev_gd_a/tools/map_editor/，
rem      工程在 dev_gd_a/daeem/ —— 所以要 `..\..\daeem`（少一层会去开
rem      dev_gd_a/data/map_01.json 那个不存在的文件，同样是一闪就没）。
rem   4. 变量不要写在 `if (...)` / `for (...)` 的括号块里再用：%VAR% 在**整块解析时**
rem      就展开了，块内 set 的值取不到。所以下面一律用 goto 分支，不写括号块。
rem   5. 行尾必须是 CRLF：cmd 解析 LF 换行的 .bat 会错乱。
rem =====================================================================

rem 本文件所在目录（编辑器就在同级）；注意 %~dp0 结尾自带反斜杠
set "HERE=%~dp0"
rem 包目录拼成「目录\.」—— 免得结尾反斜杠把引号吃掉
set "PKG=%HERE%."
rem 工程目录 dev_gd_a/daeem；for %%~fI 把 `..` 消掉（见文件头第 2 条）
for %%I in ("%HERE%..\..\daeem") do set "PROJDIR=%%~fI"
rem 要打开的地图：拖动文件进来 / 传参；不给就用工程里的 map_01.json
set "MAP=%~1"
if defined MAP goto :has_map
set "MAP=%PROJDIR%\data\map_01.json"
goto :have_map

:has_map
rem 相对路径补成绝对路径（双击拖进来的本来就是绝对路径，这里只是兜底）
if not exist "%MAP%" goto :have_map
for %%F in ("%MAP%") do set "MAP=%%~fF"

:have_map
rem ---- 找一个能用的 Python：优先无窗口的 pythonw ----
set "PYW="
set "PY="
where pythonw >nul 2>nul && set "PYW=pythonw"
where pyw     >nul 2>nul && if not defined PYW set "PYW=pyw"
where python  >nul 2>nul && set "PY=python"
where py      >nul 2>nul && if not defined PY set "PY=py"
if defined PY goto :check
if defined PYW set "PY=%PYW%"
if not defined PY goto :nopython

:check
rem 先确认这个 Python 真能跑（tkinter 缺了也算不能跑）
"%PY%" -c "import tkinter" >nul 2>nul
if errorlevel 1 goto :notkinter

rem ---- 开窗口 ----
if defined PYW goto :open_windowless
start "" %PY% "%PKG%" "%MAP%"
goto :eof

:open_windowless
start "" %PYW% "%PKG%" "%MAP%"
goto :eof

:nopython
echo.
echo ============================================================
echo   没有找到 Python，编辑器起不来。
echo.
echo   装一个就行：https://www.python.org/downloads/
echo   安装时记得勾上 "Add python.exe to PATH"。
echo ============================================================
echo.
pause
goto :eof

:notkinter
echo.
echo ============================================================
echo   找到了 Python，但它缺少 tkinter（画不出界面）。
echo.
echo   官方安装包默认自带 tkinter；重装时把 "tcl/tk and IDLE"
echo   勾上即可。也可以把另一个 python 命令放进 PATH 后再试。
echo ============================================================
echo.
pause
goto :eof
