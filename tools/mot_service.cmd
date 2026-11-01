@echo off
cd /d "C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace\FPGA_104"
:loop
py -3 -u tools\web_monitor.py --port COM15 --http 8090 --out out\live >> out\live\monitor.log 2>&1
timeout /t 5 /nobreak >nul
goto loop