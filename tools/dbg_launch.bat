@echo off
chcp 65001 >nul
setlocal
set PYTHONIOENCODING=utf-8

REM ---- Efinity environment (mirrors bin\setup.bat) ----
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

REM ---- KEY: without this the Debugger finds NO USB target ----
set EFX_HIFTDI_ENABLE=1

set PROF=%~1
if "%PROF%"=="" set PROF=D:\FPGA\mmt\_debug_wbh3.json
if not exist "%PROF%" (
  echo [ERROR] profile not found: %PROF%
  pause
  exit /b 2
)

echo ============================================================
echo  EFX_HIFTDI_ENABLE = %EFX_HIFTDI_ENABLE%
echo  profile           = %PROF%
echo ============================================================
echo.
echo  Steps after GUI opens:
echo   1) Perspectives - Debug
echo   2) Program panel: click refresh icon next to USB Target
echo   3) Select the FTDI device
echo   4) Run panel: click Configure (target icon)
echo   5) Edit vio0 values
echo.

"D:\Efinity\2026.1\debugger\bin\efinity_dbg.bat" --project_home "D:\FPGA\mmt" --profile_file "%PROF%"

endlocal
