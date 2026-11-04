@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 exit /b 1
cd /d "%~dp0"
cl /nologo /utf-8 /W3 /O2 test_alg.c /Fe:test_alg.exe
if errorlevel 1 exit /b 1
test_alg.exe
exit /b %errorlevel%
