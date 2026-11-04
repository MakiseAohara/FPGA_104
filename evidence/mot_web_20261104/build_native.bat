@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 exit /b 1
cd /d "%~dp0"
cl /nologo /utf-8 /W3 /O2 /LD /DBASELINE native_api.c /Fe:baseline.dll > baseline_build.log 2>&1
if errorlevel 1 exit /b 1
cl /nologo /utf-8 /W3 /O2 /LD native_api.c /Fe:optimized.dll > optimized_build.log 2>&1
exit /b %errorlevel%
