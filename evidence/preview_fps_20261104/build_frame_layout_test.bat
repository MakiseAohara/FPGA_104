@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 exit /b 1
cd /d "D:\FPGA\fps04\evidence\preview_fps_20261104"
cl /nologo /O2 /LD frame_layout_test_api.c /Fe:frame_layout_test.dll > frame_layout_build.log 2>&1
exit /b %errorlevel%
