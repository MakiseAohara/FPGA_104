@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 exit /b 1
cd /d "%~dp0"
cl /nologo /utf-8 /W3 /O2 /DNET_TX_SEGMENTS=1 /LD preview_http_api.c /Fe:preview_http.dll
exit /b %errorlevel%
