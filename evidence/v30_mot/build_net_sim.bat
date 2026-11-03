@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
cd /d "C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace\FPGA_104\evidence\v30_mot"
cl /nologo /W3 /O2 net_sim.c /Fe:net_sim.exe
if errorlevel 1 exit /b 1
net_sim.exe
