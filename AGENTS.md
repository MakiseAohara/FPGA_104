# 先读这个（给 Codex）—— 10/27 更新（Claude / Kevin）

## 现在要做的(按顺序)
按 comms/STATUS.md 最后一行和 10/27 总任务执行:
1. 烧录 evidence/v27_rtl_ir/v7_MERGE15.bit(SHA256 74E205F8…13AF40),再加载 v26 固件(CRC32 B7CCB8D0)。
2. 冒烟测试四条:HDMI/OSD 正常;人入画报警、离开释放;串口 MMT_DEC 持续且帧率约 60;空场 30 秒无报警。
   任何一条不过,立刻刷回 v7_MERGE14.bit(SHA256 E399F990…A8B41FE8)并在 comms/codex/ 报告。
3. 用 1512f07 的操作者面板做有真值重测(操作者点开始、按键标注),数据放 evidence/v27_gate/。
4. 顺带记录红外:空场/有人时 irhot 的值,手机录 HDMI 红外热力图小窗,含手靠近 20 cm 的 10 秒。
5. 在 comms/codex/ 写说明:冒烟是否通过、标注是否齐全、红外观察、异常。判定留给 Claude。

## 不做
VIO/LA/白平衡/曝光/AE;不改固件;不重新编译 RTL;不自行调红外参数。

## 卡住时
单个障碍超过 15 分钟:在 comms/codex/ 写清做了什么、卡在哪、需要谁回答什么,然后做下一项,不要等。

## 约定
证据只放 evidence/,判断与建议只放 comms/。
