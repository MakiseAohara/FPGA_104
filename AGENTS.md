# 当前工程入口（2026-11-04）

先读 `docs/HANDOFF_2026-11-04.md`，以当前用户任务为准。10/27的旧实测安排保存在 `docs/history/AGENTS_2026-10-27.md`，不能当作当前板卡状态或默认执行步骤。

- 当前活动应用：`firmware/tinyml_pdti8.bin`，CRC32 `B42CC161`；源码入口 `evidence/v30_mot/main_live30.cc`、`build_v30.py`。
- 活动网络位流：`firmware/netfix04_rxq2_seed1.bit`，SHA256 `865458AB2AF51C366AAA2C22DCFA3312F4AB104E90680185BC90F58BDF0E69F5`。
- PC 169.254.47.62:8090；板内169.254.47.63:80。共享网页是 `tools/page.html`；改动后运行 `tools/embed_page.py` 并重编应用，两端一起验证。
- 真正的源帧率按新capture ID及像素内容统计，重复刷新缓存图不算新帧。合成算法指标与无人工真值的历史实拍回归须分别报告。
- 白平衡仍为344/280/368；红外是未完成校准的相对热变化/估算温度，45℃为限幅。不能声称这些问题已修好。
- 固定左右拼接已修正，读图基址为0x017E9200，行距1920，bank间距8294912。勿沿用旧的半跨度计算。
- 实际Efinity工程上下文见 `evidence/network_20261104/project_settings/`；位流来自seed1补跑，命令与日志见对应builds/reproduction目录。根目录历史工程不自动等同当前已加载工程。
- 本轮使用JTAG临时加载和UART RAM应用，未写SPI。旧版本与回退包均保留。避免占用正在运行的串口；串口协议没有块序号，丢ACK时不能盲目重发已发送块。

证据放在 `evidence/`，结论与交接说明放在 `comms/` 或 `docs/`。先核对实际文件哈希及运行记录，再开展当前用户授权的工作。
