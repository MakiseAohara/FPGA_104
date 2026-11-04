@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 exit /b 1
cd /d "%~dp0"
cl /nologo /utf-8 /W3 /O2 /LD tcp_multi_api.c /Fe:tcp_multi_2.dll > tcp_multi_2_build.log 2>&1
if errorlevel 1 exit /b 1
cl /nologo /utf-8 /W3 /O2 /LD /DNET_CONN_COUNT=1 tcp_multi_api.c /Fe:tcp_multi_1.dll > tcp_multi_1_build.log 2>&1
exit /b %errorlevel%
