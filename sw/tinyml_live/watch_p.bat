@echo off
REM ============================================================
REM  实时人体检测读数
REM
REM  用法：双击运行，然后走进/走出画面，看 p 和判决是否翻转
REM        watch_p.bat            COM15，一直跑（Ctrl+C 停）
REM        watch_p.bat COM15 60   跑 60 秒
REM
REM  判读：
REM    空场  p 应稳定在 -90 左右，判决 EMPTY
REM    有人  p 应转正（>0），判决 PERSON
REM ============================================================

set EFINITY_HOME=D:/Efinity/2026.1
set PYTHONHOME=D:/Efinity/2026.1/python311
set PYTHONIOENCODING=utf-8
set PATH=D:\Efinity\2026.1\bin;D:\Efinity\2026.1\python311\bin;%PATH%

"D:\Efinity\2026.1\python311\bin\python.exe" "%~dp0watch_p.py" %*

echo.
pause
