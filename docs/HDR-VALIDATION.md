# Nextend 0.3.0 · HDR 集成验收

日期：2026-10-16。M4 MacBook Air 24 GB、macOS 27.0.1；Xiaomi Pad 7 Ultra、Android 16 / HyperOS 3。**最终构建已通过 USB / 加密无线 HDR 短测、SDR 回退、兼容与清理检查。独立 App 的 HDR 开关和实际连接也已验证。**

## 实测结果

两轮 HDR 都是 3200×2136、1600×1068 逻辑桌面、60 fps 目标、30 秒。测试源是虚拟屏内的 EDR Metal 动态窗口，经过真实 WindowServer 合成和采集。

| 测试 | 编码均值 | Pad 呈现回调均值 | 采集到解码确认往返 P95 |
|---|---:|---:|---:|
| USB HDR | 60.00 fps | 59.96 fps | 57.58 ms |
| 加密 Wi-Fi HDR | 47.11 fps | 46.85 fps | 142.96 ms |

帧率均值排除前三条统计，P95 使用报告全程样本。报告为 `benchmarks/nextend-hdr-usb-final.json` 与 `nextend-hdr-wifi-final.json`。当前推荐 USB、原生清晰度、60 fps；无线已能正确传 HDR，但本轮没有达到 60 fps。

测试画面易压缩，末次统计的平均码率分别约 0.368 / 0.499 Mbps，不能据此判断无线最大吞吐。无线的确认延迟和四帧在途限制会影响出帧；本轮未隔离测量每一项瓶颈。

## 高光和输出格式证据

| 线性源值，SDR 白=1 | 0 | 0.18 | 1 | 2 | 3 | 4 |
|---|---:|---:|---:|---:|---:|---:|
| 原生扩展 sRGB 红通道 | 0 | 0.4612 | 1 | 1.3535 | 1.6123 | 1.8252 |
| 转换后 10-bit Y | 64 | 446 | 721 | 818 | 873 | 912 |

USB 与无线均保留了不同高光等级，没有把 2 / 3 / 4 倍高光截成同一白值。编码器输出通过 HEVC hvcC Main10、亮度与色度均为 10-bit、BT.2020 / HLG / limited 检查；Pad 解码输出为 color-standard=6、color-transfer=7、color-range=2，且收到呈现回调。SurfaceFlinger 同时显示 `P010`、`BT2020_ITU_HLG`。摘录见 `nextend-hdr-surface-final.txt` 与 `nextend-hdr-surface-wifi.txt`。

这些证据证明本机数字 HDR 链路成立，不代表测定了 Pad 的物理峰值亮度、色准或整个广色域。

## 实现范围

链路为 EDR 虚拟屏 → 原生 RGhA 扩展 sRGB 浮点采集 → Metal 线性化、BT.2020 / HLG 转换 → P010 → VideoToolbox Main10 → PDB1 加密 USB / Wi-Fi → MediaCodec Main10 → SurfaceView。

- HDR 虚拟屏使用 transferFunction=1，本机 EDR headroom 为 5；启动和每两秒核对模式、亮度余量和 sRGB ICC 配置。
- HLG 使用 BT.2100 inverse OOTF / OETF、system gamma 1.2；SDR 白位按 203 / 1000 参考映射。高于固定系统峰值的值会被限制，尚无动态 tone mapping。
- Pad 按目标尺寸和帧率声明硬件 Main10 与 HLG 面板能力；编码输入、编码输出、解码输出逐段检查。输出格式进入兼容旧版的 `stats.videoFormat`。
- HDR 失败或输出确认超时可自动回退 SDR，并显示原因；`--require-hdr` 严格失败，不掩盖 HDR 验收问题。
- SDR 保留 HEVC Main / H.264 High、BT.709、8-bit。包标识、私有配对密钥和加密上下文保持原样。

## 回归与异常路径

| 检查 | 结果与证据 |
|---|---|
| HDR 第一帧被拒绝，紧接 EOF | 通过；自动重连 SDR 并移除虚拟屏，`nextend-hdr-runtime-fallback.json` |
| 新 Mac 请求 HDR → 旧 Pad 0.2.0 | 通过；协商为 SDR，随后恢复安装 Pad 0.3.0，`nextend-new-mac-old-pad.json` |
| 旧 Mac 0.2.0 → 当前 Pad 0.3.0 | 通过；早期兼容测试记录 `nextend-old-mac-new-pad.json`，当前 APK 未再变更 |
| SDR HEVC / H.264 实际桌面 | 15 秒 / 5 秒通过，`nextend-sdr-hevc-final.json` / `nextend-sdr-h264-final.json` |
| 启动中取消 / 传输中取消 | 通过；报告为预期中止，无 ADB 转发和显示残留，`nextend-hdr-regressions.json` |
| 辅助进程 EOF / SIGTERM / 启动中 EOF / 父进程 SIGKILL | 四项通过，系统显示列表恢复原状，`nextend-display-lifecycle.json` |
| 最新 Mac 自测 | Metal HLG 白位、高光、neutral chroma、协议加密、篡改和重放拒绝通过 |
| 当前 Android APK | 6 项单元测试、8 组真机协议测试通过，含非法 HDR 组合、旧版统计、输入注入和超时 |
| 独立 App 界面 | 开 HDR 自动选 HEVC；选 H.264 关闭 HDR；连接时设置禁用；无线连接确认 HLG；断开后设置恢复，`nextend-hdr-ui.json` |

早期锁屏前置拒绝测试已验证 0 编码帧、无新增 ADB 转发，保留 `nextend-locked-start-guard.json`；未为最终打包再次锁定用户的 Mac。早期 HDR 探测、被系统控制遮罩遮挡的失败画面和最终二进制证据分开保留，不计入本轮通过结果。

## 资源清理与权限

虚拟屏创建和模式设置已放入独立辅助进程，UI 通过私有管道控制，父进程结束时 EOF 会使辅助进程退出。正常断开等待辅助进程退出并核对系统 online 列表，必要时只终止本会话所属辅助进程。清理等待不因用户取消而跳过。HDR 回退尽量保留正常辅助进程，已失效的进程必须清理后才能创建 SDR 屏。

本轮还修正了清理误报：已移除显示 ID 的 `CGDisplayIsOnline` 返回 -1，原先只判断是否为 0 不正确。最终用显示列表确认。结束后显示列表恢复为仅内置屏，未由程序重启 WindowServer、注销或重启 Mac。

最终临时签名构建的旧录屏记录曾显示开启却实际失效；已通过系统界面移除旧条目、加入当前项目的 Nextend.app，并由用户完成 Touch ID。独立 App 随后实际连接成功。局域网权限也已刷新。再次修改并重建 App 时，macOS 可能要求重新授权。

## 使用与边界

断开后打开 HDR，推荐 USB / 原生清晰度 / 60 fps；连接后等待“HDR · HLG 10-bit”。Pad 必须保持 Nextend 在前台，退到后台会主动停止接收。静态桌面不持续出帧，界面显示 0 fps 不等于断线。

内容本身需要 HDR 信息，普通 SDR 窗口不会凭空增加高光细节。90 / 120 fps 仍为实验目标。本版没有 PQ / HDR10、Dolby Vision、音频或触控回传。未做 HDR 半小时长测；此前半小时数据属于旧版 SDR。延迟终点是解码输出确认并包含返回传输，不是屏幕发光时间。

私有 CGVirtualDisplay HDR 接口和已弃用的 CGDisplayStream 需要在 macOS 升级后重新验证。本机结果不外推到未测试系统。Mac 为临时签名、未公证开发构建，Android 为 USB 调试配对使用的调试 APK。

## 技术依据

- [Apple：HDR 屏幕采集](https://developer.apple.com/videos/play/wwdc2024/10088/)
- [Android：HDR 视频呈现与 SurfaceView](https://developer.android.com/media/grow/hdr-playback)
- [ITU-R BT.2100](https://www.itu.int/rec/R-REC-BT.2100)
- [ITU-R BT.2408 参考白位](https://www.itu.int/dms_pub/itu-r/opb/rep/R-REP-BT.2408-8-2024-PDF-E.pdf)
- [PhotonPort API 路线参考](https://github.com/lotgood/photonport)，锁定提交及来源见 `THIRD_PARTY_NOTICES.md`
- [虚拟屏生命周期的独立测量](https://pkg.go.dev/github.com/go-macos/virtualdisplay@v0.5.0)，本项目另外验证了辅助进程退出后的显示列表
