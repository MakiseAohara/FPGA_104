from pathlib import Path
import difflib,hashlib,json,shutil,zipfile

HERE=Path(__file__).absolute().parent
WORKSPACE=HERE.parents[1]
SOURCE=Path(r'D:\FPGA\fps04')
BASELINE=Path(r'D:\FPGA\motweb04')
TARGET=WORKSPACE/'outputs/preview_fps_fix_20261104'
TARGET.mkdir(parents=True,exist_ok=True)
def copy(src,dst):
    dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst)
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()

for name in ('tools','sw','submission','firmware'):
    shutil.copytree(SOURCE/name,TARGET/name,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
for folder in ('evidence/v30_mot','evidence/mot_web_20261104','evidence/preview_fps_20261104'):
    for p in (SOURCE/folder).iterdir():
        if p.is_file() and p.suffix.lower() not in ('.obj','.lib','.exp','.exe'):
            copy(p,TARGET/folder/p.name)
for name in ('replays','recordings'):
    shutil.copytree(SOURCE/'evidence/mot_web_20261104'/name,TARGET/'evidence/mot_web_20261104'/name,dirs_exist_ok=True)
for name in ('board_fw2','jtag_fw2'):
    shutil.copytree(SOURCE/'evidence/preview_fps_20261104'/name,TARGET/'evidence/preview_fps_20261104'/name,dirs_exist_ok=True)
copy(SOURCE/'evidence/mot_web_20261104/recordings_index_portable.json',TARGET/'evidence/mot_web_20261104/recordings_index.json')
for name in ('baseline','after_fw1','after_fw2'):
    shutil.copytree(HERE/name,TARGET/'evidence/preview_fps_20261104/measurements'/name,dirs_exist_ok=True)
copy(HERE/'measure_preview_fps_v2.cjs',TARGET/'evidence/preview_fps_20261104/measure_preview_fps_v2.cjs')
for name in ('build_v30.log','link.log','size.txt','compile_commands.json'):
    copy(Path(r'D:\v30_build\out_previewfps04_fw2')/name,TARGET/'evidence/build_fw2'/name)
copy(HERE/'firmware2-build.log',TARGET/'evidence/build_fw2/build_summary.log')
copy(WORKSPACE/'outputs/fpga_onboard_verified_20261020/tools/flash_vendor.ps1',TARGET/'tools/flash_vendor.ps1')

before=json.loads((HERE/'baseline/measurement.json').read_text(encoding='utf8'))
after=json.loads((HERE/'after_fw2/measurement.json').read_text(encoding='utf8'))
identity=json.loads((SOURCE/'firmware/firmware_identity.json').read_text(encoding='utf8'))
rows=[]
for name in ('pc','board'):
    old=next(s for s in before['pages'] if s['name']==name);new=next(s for s in after['pages'] if s['name']==name)
    rows.append(f"| {'PC 网页' if name=='pc' else '板内网页'} | {old['unique_frames_per_window_second']:.2f} | {new['unique_frames_per_window_second']:.2f} | {new['unique_frame_ids']} / {new['measurement_seconds']:.2f}s |")

readme=f'''# 网页画面刷新率与左右拼接修复（2026-11-04）

本轮在隔离副本 `D:\\FPGA\\fps04` 完成。旧 `D:\\FPGA\\motweb04`、netfix04 和旧交付包均保留；未推送 GitHub，未覆盖用户原 Efinity 工程。

## 直接使用

- PC：[http://169.254.47.62:8090/](http://169.254.47.62:8090/)
- 板内：[http://169.254.47.63/](http://169.254.47.63/)
- 打开后 **Ctrl+F5 强制刷新**，让浏览器使用新页面。两端页面字节一致。

```powershell
.\\tools\\start_network_monitor.ps1
```

本次加载方式是 JTAG 临时位流 + UART RAM 应用；**断电后需重载**，未写 SPI Flash。重新载入前关闭本工程的监视程序并确认 COM15 释放，先重置位流，再载入应用，最后启动监视程序。工具中的串口脚本只在打开端口阶段短暂重试，不会盲目重发已发送的数据块。

## 真实画面帧率

| 入口 | 修复前 FPS | 最终实测 FPS | 最终新画面数 / 测量时长 |
|---|---:|---:|---|
{chr(10).join(rows)}

以上按 Edge 浏览器实际绘制的新 capture ID 计数，重复绘制同一快照不算新帧；同时记录原始像素 SHA256。不是网页控件轮询频率，也不是 HDMI 输出频率。测量采用真实板卡，PC 20 秒、板页 10 秒；测试板页时 PC 镜像仍在运行。场景和低功耗状态随实际输入变化，因此这是本轮观测结果，不是所有场景的固定保证。

最终两端浏览器均无测量期 JavaScript/请求错误。首次单连接提速仍有板页长间隔，已保留 `after_fw1` 原始报告；最终数据位于 `measurements/after_fw2`。当前画面采样仍由主循环/MOT与推理或低功耗节奏决定，未独立于算法建立高帧率视频采集器。

## 左右拼接原因与修复

实际综合层级中，下层 `ddr_buffer/bank_switch` 没收到上层宽度960的参数覆盖，仍按1920分配 bank。真实 bank 间距 **8294912 字节**，旧固件却按4147712计算。旧取像地址 `0x017E9400` 实际是 bank1 起点 `0x017E9200` 再偏512字节。

所以每行先读取本行 x=512..1919，再把下一行 x=0..511 接在右侧，接缝约在画面宽度73.33%。新固件继续读同一个真实 bank1，但将起点纠正为 **0x017E9200**；图像行距保持1920字节，未靠裁切、平移或网页重排掩盖接缝。

独立行列标记回归：旧地址1080行全部错误，修正后1080行全部正确；综合参数、源码行号和测试见 `FRAME_LAYOUT_AUDIT.md`、`frame_layout_test.json`。实际浏览器前后截图也已保存。固定 bank 仍未加完成帧读锁，高速运动时的时变撕裂风险不能据此宣称完全消除。

## 提速实现

1. `/api/preview` 一次传回 JSON 状态和同一快照的96×96原始Gray8像素，浏览器直接绘制。保留全部8位灰度，未降低像素分辨率、未插帧；旧 JSON/PNG 接口继续可用。
2. TCP 允许2个MSS在途，按累计ACK推进并重传最老未确认数据；尾部只拆分一次，减少延迟ACK造成的逐包停顿。`NET_TX_SEGMENTS=1` 可回退。
3. 两个独立TCP连接和响应缓存分别服务PC镜像、板端浏览器，公平轮询，避免一个客户端等待时占住另一客户端。`NET_CONN_COUNT=1` 可回退。
4. DDR采样期间分批处理网口消息；关掉默认无用的额外缩略图采样、整图十六进制串口输出和每包调试打印。
5. PC镜像按100ms目标周期跟随新帧，网页按200ms目标周期请求最新完整快照，不积压队列。页面FPS只统计新快照。

MOT核心源码、模型、报警门限、白平衡和红外算法均未修改。本轮仅把网页温度标题改成“红外估算温度”，避免将现有经验估算误称为准确最高温。原有白平衡参数344/280/368及红外未完整校准、45℃限幅等问题仍需后续分别处理；本轮不宣称完成了它们。

## 验证与文件

- 14项发送窗口报文回归、13项多连接回归通过；包含丢包、累计/部分ACK、零窗口、序号回绕、SYN/FIN/RST、满槽和并发响应数据隔离。
- 新数据包的所有9216个像素在C→Python→浏览器之间逐点一致；11项打包预览浏览器检查通过；旧网页交互与旧接口回退检查通过。
- 板端 `MMT_LOAD_PASS DDR_CRC`，启动读取地址、两端页面哈希、画面/轨迹配对和实测报告均保留。
- 新协议：`tools/preview_protocol.py`、`evidence/v30_mot/preview_packet.h`。
- 运行中的源码：`tools/page.html`、`tools/web_monitor.py`、`evidence/v30_mot/main_live30.cc` 与网络头文件。
- 最终固件：`firmware/tinyml_pdti8.bin`，{identity['bytes']}字节，CRC32 **{identity['crc32']}**，SHA256 **{identity['sha256']}**。
- 回退应用：`firmware/rollback_motweb04_fw4.bin`，CRC32 **38DD7DBF**，SHA256 **3F570E52A9C035A9A8157EDCB9D0B4E3644D590BE46704AFF6F84AC909D968AF**；回退时配原 `mot_tracking_web_20261104` 页面/监视器。
- 网络位流仍是 `netfix04_rxq2_seed1.bit`，SHA256 **865458AB2AF51C366AAA2C22DCFA3312F4AB104E90680185BC90F58BDF0E69F5**，未重编RTL；继承的setup余量−1.103ns仍未闭合，不能以本次传输成功替代时序验收。

构建：`py -3 evidence/v30_mot/build_v30.py --project D:\\v30_build\\project --out D:\\v30_build\\out_previewfps04_fw2`。先运行 `tools/embed_page.py` 生成同源网页头文件。官方软件工程和RISC-V工具链需已有；本机Efinity下载工具为2026.1.132。独立测试使用本机VS2022 C工具和Edge/Playwright。
'''
(TARGET/'README.md').write_text(readme,encoding='utf8')
(SOURCE/'README_PREVIEW_FPS_20261104.md').write_text(readme,encoding='utf8')
patch=[]
for folder in ('tools','evidence/v30_mot'):
    for p in sorted((SOURCE/folder).iterdir()):
        if not p.is_file() or p.suffix not in ('.py','.ps1','.h','.cc','.html'):continue
        rel=p.relative_to(SOURCE).as_posix();old=BASELINE/rel
        a=old.read_text(encoding='utf8').splitlines(keepends=True) if old.exists() else []
        b=p.read_text(encoding='utf8').splitlines(keepends=True)
        patch+=difflib.unified_diff(a,b,fromfile='a/'+rel if old.exists() else '/dev/null',tofile='b/'+rel)
(TARGET/'source_vs_motweb04.patch').write_text(''.join(patch),encoding='utf8')
manifest={'active_project':str(SOURCE),'firmware':identity,'manual_motion_test':False,
          'spi_flash_written':False,'page_sha256':digest(SOURCE/'tools/page.html'),
          'before':before,'after':after,'files':{}}
for p in sorted(TARGET.rglob('*')):
    if p.is_file() and p.name!='manifest.json':manifest['files'][p.relative_to(TARGET).as_posix()]=digest(p)
(TARGET/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf8')
archive=TARGET.with_suffix('.zip')
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
    for p in sorted(TARGET.rglob('*')):
        if p.is_file():z.write(p,str(Path(TARGET.name)/p.relative_to(TARGET)))
with zipfile.ZipFile(archive) as z:assert z.testzip() is None
print(json.dumps({'zip':str(archive),'bytes':archive.stat().st_size,'sha256':digest(archive),'files':len(manifest['files'])},ensure_ascii=False))
