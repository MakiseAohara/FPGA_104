# v22_gate 中断与恢复记录

此文件记录采集工具和交付过程的问题，不评估入侵检测效果。

- 2026-10-26 07:33（Asia/Shanghai），最初三轮在 `flash_vendor.ps1` 的 `Get-FileHash` 前置检查退出，未执行 JTAG、未上传固件。对应 `flash_attempt_1.log` 至 `flash_attempt_3.log`。
- 原因：Python 子进程继承 PowerShell 7 模块目录，Windows PowerShell 5.1 未能自动加载其原生 Utility 模块。已把烧录子进程模块路径限定为 Windows PowerShell 目录，并在打开串口前检查命令可用性。
- 用户追加授权“可以烧录”“再试几次”后，第 4 轮完成 JTAG 编程和 477,722 字节原固件上传。板端输出 `MMT_LOAD_PASS DDR_CRC`、`MMT_LIVE_BOOT v19 ... AE=0 ... LOWPOWER=1`。
- 07:39:29.938–07:39:59.943 只进行 30 秒启动观察，没有复位，也没有执行 ENTER/LEAVE 动作流程。
- 采集器末尾报 `No MMT_CAM boot lines captured`，原因是固件 LF/CR 行尾产生下一行的前导 CR。原始日志确实包含 `2026-10-26T07:39:30.114+08:00` 的 `MMT_CAM_VTS ok=1 vts=0x0x5dc rom_vts=0 fallback=1`；离线解析已保留 LF/CR 并正确读取。原日志和原异常记录均保留，后续使用的 `capture_v22.py` 已修正 framing。
- 原始日志 SHA256：`F6885C01531B10151E67477751FA1019EE5F2524B3C5AA44FD68F15B0FBC21C6`。
- 六轮真人入侵实测按用户最新指示暂缓；本次不能代表该流程的实测结果。
- GitHub 推送环境：`GH_TOKEN` 未配置，标准 Git Credential Manager 无 GitHub 凭据，GitHub 插件未连接。main 只读访问正常；推送状态另见输出根目录的 `push_main.log`。

固件 CRC32 `9410DBEF`，SHA256 `8C0AE09D06851257D5412EC834C5BF143D91BFE2F30D111AC298BC571F0D2AD3`。未重新编译、未修改曝光/AE。
