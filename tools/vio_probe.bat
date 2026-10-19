@echo off
chcp 65001 >nul
setlocal
set PYTHONIOENCODING=utf-8
set EFINITY_HOME=D:/Efinity/2026.1
set PYTHONHOME=D:\Efinity\2026.1\python311
set EFXPT_HOME=D:/Efinity/2026.1/pt
set EFXPGM_HOME=D:/Efinity/2026.1/pgm
set EFXDBG_HOME=D:/Efinity/2026.1/debugger
set EFXIPM_HOME=D:/Efinity/2026.1/ipm
set EFXSVF_HOME=D:/Efinity/2026.1/debugger/svf_player
set EFXSERDESDBG_HOME=D:/Efinity/2026.1/debugger/serdes_debug_tool
set EFINITY_USER_DIR=C:/Users/18915/AppData/Local/efinity
set EFINITY_USER_DIR_INI=C:/Users/18915/AppData/Local/efinity/user_dir.ini
set PYTHONPATH=%EFXDBG_HOME%/bin;%EFXPGM_HOME%/bin
set PATH=D:\Efinity\2026.1\python311\bin;D:\Efinity\2026.1\bin;D:\Efinity\2026.1\pgm\bin;D:\Efinity\2026.1\debugger\bin;D:\Efinity\2026.1\scripts;%PATH%

set PROFILE=%~1
if "%PROFILE%"=="" set PROFILE=D:\FPGA\mmt\_debug_wbh4.json

echo ============================================================
echo PROFILE = %PROFILE%
echo ============================================================
echo.

"D:\Efinity\2026.1\python311\bin\python.exe" "D:\FPGA\mmt\tools\vio_probe.py" "%PROFILE%"

echo.
echo ============================================================
echo DONE. Copy ALL output above and send it back.
echo ============================================================
endlocal
