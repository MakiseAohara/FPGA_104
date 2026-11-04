@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 exit /b 1
cd /d D:\FPGA\netfix04\evidence\network_20261104
cl /nologo /W3 /O2 /LD net_test_api.c /Fe:net_test.dll
exit /b %errorlevel%
