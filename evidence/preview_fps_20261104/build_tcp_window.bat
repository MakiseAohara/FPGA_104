@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 exit /b 1
cd /d "%~dp0"
cl /nologo /utf-8 /W3 /O2 /LD /DNET_CONN_COUNT=1 /DNET_TX_SEGMENTS=1 tcp_window_api.c /Fe:tcp_window_1.dll > tcp_window_1_build.log 2>&1
if errorlevel 1 exit /b 1
cl /nologo /utf-8 /W3 /O2 /LD /DNET_CONN_COUNT=1 tcp_window_api.c /Fe:tcp_window_2.dll > tcp_window_2_build.log 2>&1
if errorlevel 1 exit /b 1
cl /nologo /utf-8 /W3 /O2 /LD /DNET_CONN_COUNT=1 /DNET_PAIR_TAIL=0 tcp_window_api.c /Fe:tcp_window_2_nopair.dll > tcp_window_2_nopair_build.log 2>&1
exit /b %errorlevel%
