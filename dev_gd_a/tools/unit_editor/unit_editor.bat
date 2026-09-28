@echo off
chcp 65001 >nul
setlocal
rem =====================================================================
rem  DAEEM 单位编辑器 —— 双击本文件即可打开（不用敲命令行）
rem
rem  它改的是 daeem/data/config.json：单位 / 将领 / 建筑 / 科技的数值。
rem
rem  可选：把一份 config.json 拖到本文件上 -> 改那一份（做对照 / 试验用）。
rem
rem  ⚠️ 实测结论，改这个文件前先看（与 map_editor.bat 同一套坑）：
rem   1. 开窗口必须用 `start "" pythonw <包目录> <参数>`：
rem      裸 `pythonw ...` 与 `start "" python ...` 起的窗口会跟着黑框一起被杀掉
rem      （控制台一退出，GUI 进程被连坐）—— 表现就是「双击了但什么都没发生」。
rem      `start "" pythonw ...` 起的是独立进程：黑框闪一下就没，窗口留得住。
rem   2. 路径里不能留 `..`：用 for %%~fI 规范化。带 `..` 的路径会被 Python 的
rem      pathlib 当成「真的叫 .. 的目录」，配置文件打不开、窗口一闪就没。
rem   3. 目录层级别数错：本文件在 dev_gd_a/tools/unit_editor/，
rem      工程在 dev_gd_a/daeem/，所以工程目录是 `..\..\daeem`。
rem      ⚠️ 默认那份 config.json 是**由 Python 自己按 __file__ 算出来的**
rem         （见 __main__.py 的 DEFAULT_PROJECT_DIR），这里不重复拼一遍路径 ——
rem         少一处会漂的字符串。
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
rem 要改的配置文件：拖动文件进来 / 传参；不给就用工程里那一份（Python 侧算默认）
set "ARG=%~1"
if not defined ARG goto :no_arg
if not exist "%ARG%" goto :no_arg
for %%F in ("%ARG%") do set "ARG=%%~fF"

:no_arg
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
rem 工程目录也确认一下：没有它，编辑器读不到 config.json
if not exist "%PROJDIR%\data\config.json" goto :noconfig

rem ---- 开窗口 ----
if not defined ARG goto :no_file_arg
if defined PYW goto :open_with_file_windowless
start "" %PY% "%PKG%" "%ARG%"
goto :eof

:no_file_arg
if defined PYW goto :open_windowless
start "" %PY% "%PKG%"
goto :eof

:open_with_file_windowless
start "" %PYW% "%PKG%" "%ARG%"
goto :eof

:open_windowless
start "" %PYW% "%PKG%"
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

:noconfig
echo.
echo ============================================================
echo   找不到配置文件：
echo     %PROJDIR%\data\config.json
echo.
echo   本文件应该在 dev_gd_a\tools\unit_editor\ 里
echo   （工程在 dev_gd_a\daeem\）。目录被搬过的话就会走到这里。
echo ============================================================
echo.
pause
goto :eof
