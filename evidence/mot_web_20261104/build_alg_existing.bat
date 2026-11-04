@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 exit /b 1
cd /d "%~dp0"
cl /nologo /utf-8 /W3 /O2 ..\v30_mot\test_mot.c /Fe:test_alg_existing.exe
if errorlevel 1 exit /b 1
test_alg_existing.exe
exit /b %errorlevel%
