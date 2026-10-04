@echo off
chcp 65001 >nul
setlocal
rem =====================================================================
rem  DAEEM 战役编辑器 —— 双击本文件即可打开（不用敲命令行）
rem
rem  它管的是战役与关卡：daeem/data/campaigns/<id>/
rem    （campaign.json + levels/*.json —— 谁参展 / 谁可玩 / 谁挂什么 AI /
rem      往哪打 / 开局摆放 / 目标与失败条件）
rem
rem  可选：把**一个战役目录**拖到本文件上 -> 直接打开那一个。
rem        双击（不拖东西）= 打开上次那个战役；没有就打开 data/campaigns/ 下第一个。
rem
rem  ⚠️ 实测结论，改这个文件前先看（与 map_editor.bat / unit_editor.bat 同一套坑）：
rem   1. 开窗口必须用 `start "" pythonw <包目录> <参数>`：
rem      裸 `pythonw ...` 与 `start "" python ...` 起的窗口会跟着黑框一起被杀掉
rem      （控制台一退出，GUI 进程被连坐）—— 表现就是「双击了但什么都没发生」。
rem      `start "" pythonw ...` 起的是独立进程：黑框闪一下就没，窗口留得住。
rem   2. 路径里不能留 `..`：用 for %%~fI 规范化。带 `..` 的路径会被 Python 的
rem      pathlib 当成「真的叫 .. 的目录」，战役目录打不开、窗口一闪就没。
rem   3. 目录层级别数错：本文件在 dev_gd_a/tools/campaign_editor/，
rem      工程在 dev_gd_a/daeem/，所以工程目录是 `..\..\daeem`。
rem      ⚠️ 战役目录**由 Python 自己按 __file__ 与命令行算**（见 __main__.py），
rem         这里只在「拖了个目录进来」时把它转成绝对路径传过去 —— 少一处会漂的字符串。
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
rem 拖进来的战役目录（可选，不一定是战役目录 —— Python 侧会再说一遍）
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
rem 工程目录也确认一下：没有它，编辑器读不到 data/campaigns 与 data/maps
if not exist "%PROJDIR%\data\maps" goto :noproject

rem ---- 开窗口 ----
if not defined ARG goto :no_dir_arg
if defined PYW goto :open_with_dir_windowless
start "" %PY% "%PKG%" "%ARG%"
goto :eof

:no_dir_arg
rem 不传战役目录：Python 会自己找「上次打开的」→ 没有就挑 data/campaigns 下第一个
if defined PYW goto :open_windowless
start "" %PY% "%PKG%"
goto :eof

:open_with_dir_windowless
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

:noproject
echo.
echo ============================================================
echo   找不到工程目录下的 data\maps：
echo     %PROJDIR%\data\maps
echo.
echo   本文件应该在 dev_gd_a\tools\campaign_editor\ 里
echo   （工程在 dev_gd_a\daeem\）。目录被搬过的话就会走到这里。
echo ============================================================
echo.
pause
goto :eof
