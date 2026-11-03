# 网页与网口的未完成问题（2026-11-03，交接用）

## 一、板内 HTTP：软件完成，被 RX 卡住

| 模块 | 状态 |
|---|---|
| `net_core.h`（ARP/ICMP/TCP/HTTP） | ✅ PC 自测 PASS |
| `page_html.h`（tools/page.html 逐字节） | ✅ 4013 B，sha 一致 |
| `http_app.h`（/、/api/status、/frame.png） | ✅ PNG 用 Pillow 校验像素一致 |
| 固件集成 | ✅ 编译通过（357 KB） |
| **上板跑通** | ❌ 浏览器请求进不来（RX 不通） |

## 二、网口 RX 的具体卡点

1. **缺 `gmii_arbi` 时完全收不到**——已定位并加回，加回后 `ping` 能拿到回复（1/3）；
2. **丢包严重**：3 个 ping 只回 1 个；UDP 负载始终 `rx=0`（`udp_rec_data_valid` 不触发）；
3. 判断为 **RGMII 接收时钟余量不足**：demo 的 RX/TX 都在 PLL 给的带相位 125 MHz 上，
   我们因为"没有空闲 PLL"只能用 `rxc` 直驱；发送侧已证明可用，接收侧余量明显不够。

## 三、可选的解决路径（按风险排序）

| 方案 | 代价 | 风险 |
|---|---|---|
| A. 腾出 PLL_TR0 给 GE（DDR3 换 PLL） | 1 轮位流 + 验证 | 中：可能影响 DDR3/HDMI |
| B. 用 `rxc` 反相或 IO 延时给 RX 采样加余量 | 1 轮位流 | 低，但效果不确定 |
| C. 自研 raw RX（不经 mac_top），配合 A/B 的时钟 | 2 轮位流 | 高工作量 |

## 四、已确认可用的部分（可直接演示/写报告）

- 千兆网口**发送**：主设计实测 1800+ 帧、`err=0`（`TX_RX_2026-11-03.md`）；
- 板子基线 `MERGE17 + v3.8`：相机/HDMI/OSD/MOT/低功耗/PC 监控页全部正常。

## 五、复现命令

```powershell
# 烧 GE 位流 + 固件（会先杀看门狗）
py -3 evidence\eth_rgmii\flash_upload.py
# 看发送计数/接收计数
py -3 -u evidence\eth_rgmii\rx_verify3.py
# 板内 HTTP 探测
py -3 -u evidence\eth_rgmii\http_probe2.py
```
