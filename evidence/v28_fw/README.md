# v28 三路融合固件

源自 evidence/v19/main_live19.cc，保留 v26 的 AI_AREA_MAX=20000，AI_P_OFF 改为 -60；IR_WIN=10、IR_NEED=2、IR_OFF_WIN=15、AI_P_STRONG=60。原始 AI 投票及 ai_reset、低功耗进入/退出控制、96×96 MMT_IMG 每40轮路径均保留，差异在 source.patch。

每次非低功耗 dec_update 将 ir_hot 写入15项环形缓冲；ir_cnt 为最近10项之和。开始报警要求 cand_left>0 且（ir_cnt>=2 或当前AI p>=60）；解除要求最近15项IR均为0，且最近3次AI样本严格小于-60。低功耗清空IR环并沿用原来的强制解除与ai_reset，启动/清空的环以0填充，没有额外的“满15项”门槛。

MMT_DEC 新增 ir_cnt。每4个主循环输出一条 MMT_THUMB，2304字节十六进制；将原 MMT_IMG 同一 uint8 灰度字节视图按2×2整除平均，时间戳使用同帧DEC时刻。低功耗轮询也只读采样一张新图供导出，仍不运行推理；p=-128 是 ai_reset 后的无新AI样本状态，不能把它当作新一次模型输出。正常模式的缩略图使用 Invoke 前保留的同一 input_snapshot。

固件482754字节，CRC32 **13F6B971**，SHA256 **259B2A78D3EC3480DDB9B7C48D0DFFB786959795FC52570EA69C2918E9B3777F**。构建沿用 sw/tinyml_live/build_tinyml_firmware.py、112个官方源及v26相同工具链/编译参数；build_v26_board.py 本身是派生数据解析器，不是固件构建入口。构建日志、实际编译命令、ELF、函数SHA1和原v19/26哈希均保留。

实际提取的C函数以RV32IM/Unicorn运行：v26在v27输入上479/479状态一致，v28边界检查覆盖候选门控、AI强证据、两次IR、15零释放、-60严格比较、LP清空与10项环边界。dump_thumb 的实际C函数也核对了全部2304像素（含int8跨界字节）及头部参数。没有用Python逻辑替代实际C回放。

按原始E/L延续标签：v28在场199/202报警tick＝98.515%，按相邻tick时长加权97.184%；空场标签99/161报警tick；椅子0/25。与预期88%/11有明显差异，未改参数追预期。v27存在重复ENTER，且最后LEAVE后的低头/侧身前漏了ENTER；初始区间未独立标注，保留为unlabelled。逐段结果在 replay_label_segments.csv，逐tick在 replay/；这些是标签统计，不是经独立核实的物理真值。

离线回放固定使用v27观测到的AI/低功耗时间表：两版的on-vote/person序列相同，低功耗控制逻辑未变；新增导图会改变新实测的循环速度，因此旧数据回放不是新实测效果的承诺。新30分钟数据的真值由Claude查看缩略图判定。
