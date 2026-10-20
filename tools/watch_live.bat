@echo off
REM 站在摄像头前，双击运行本文件，看分类结果会不会从 EMPTY 变成 PERSON
set EFINITY_HOME=D:/Efinity/2026.1
set EFXPGM_HOME=D:/Efinity/2026.1/pgm
set EFXDBG_HOME=D:/Efinity/2026.1/debugger
set EFXPT_HOME=D:/Efinity/2026.1/pt
set EFXIPM_HOME=D:/Efinity/2026.1/ipm
set EFINITY_USER_DIR=%LOCALAPPDATA%/efinity
set EFINITY_USER_DIR_INI=%LOCALAPPDATA%/efinity/user_dir.ini
set PYTHONHOME=D:/Efinity/2026.1/python311
set PATH=D:\Efinity\2026.1\bin;D:\Efinity\2026.1\python311\bin;%PATH%

set SECS=%1
if "%SECS%"=="" set SECS=30

echo ============================================================
echo  实时推理观察器：%SECS% 秒
echo  现在请站到摄像头前（挥手/走近），然后等结果
echo ============================================================
echo.

"D:\Efinity\2026.1\python311\bin\python.exe" "%~dp0watch_live.py" %SECS% COM15

echo.
pause
