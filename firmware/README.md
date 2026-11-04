# 当前可加载文件

本目录对应 2026-11-04 的网口、双端网页、多目标跟踪及画面提速版本。先按 [现场验收步骤](../docs/review/ACCEPTANCE.md) 确认板卡、接线及实际串口，再加载对应文件。

| 文件 | 作用与身份 |
|---|---|
| [tinyml_pdti8.bin](tinyml_pdti8.bin) | 当前 RISC-V 应用，438,506 字节，CRC32 **B42CC161**。 |
| [netfix04_rxq2_seed1.bit](netfix04_rxq2_seed1.bit) | 当前网络位流，2,858,286 字节，seed 1。 |
| [tinyml_pdti8.elf](tinyml_pdti8.elf) | 当前应用的 ELF，供调试和符号核对。 |
| [firmware_identity.json](firmware_identity.json) | 当前应用的大小、CRC32、SHA256 与构建来源记录。 |
| [rollback_motweb04_fw4.bin](rollback_motweb04_fw4.bin) | 上一阶段回退应用，CRC32 `38DD7DBF`；需同时使用对应阶段的网页与监视器。 |

当前应用 SHA256：`EFE406B74287EAD4467C9111557871D89AD6013AD64EEA967171F898F8DD1CBB`。

当前位流 SHA256：`865458AB2AF51C366AAA2C22DCFA3312F4AB104E90680185BC90F58BDF0E69F5`。

加载记录采用 **JTAG 临时位流 + UART RAM 应用**，未写 SPI Flash，断电后需重新加载。文件存在和 CRC 正确不能替代现场功能验收；该位流仍有 setup 余量 −1.103 ns 未闭合的问题。

源码、工具环境和加载命令见 [构建与运行](../docs/review/REPRODUCE.md)。旧版固件在 [submission/firmware/](../submission/firmware/)，配套回退包在 [deliverables/20261104/](../deliverables/20261104/)，不能按旧文档里的“定版”字样判断当前版本。
