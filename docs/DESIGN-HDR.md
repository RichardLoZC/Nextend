# Nextend · 设计、性能与 HDR

2026-10-16。Nextend 0.3.0 开发验收，原名 PadBridge。副标题：**桌面，多一面。** 用户选定第 2 款 n 形折叠玻璃桥，已制作 Mac icns 与 Android 多密度图标；5 个原始方案均保留。

## 界面与可复用技能

参考用户指定的「领百奥官网」液态玻璃设计：清透面板、明亮细边、柔和背景、克制的投影和统一圆角。只对外层容器施加材质，内层设置保持可读。

Mac 使用 macOS 26 原生 NSGlassEffectView，旧系统回退 NSVisualEffectView；减少透明度或提高对比度时改为实色。Android 使用渐变、透明填色与细边近似这一语言，视频仍通过原有 SurfaceView 呈现。Android 效果不声称具有真实背景折射。两端均没有常驻装饰动画。

Mac 将连接、清晰度、刷新率、编码集中为一组，连接时锁定设置并显示实时统计；Pad 提供 USB / 加密无线选项与等待状态，传输时隐藏主控制面板。90 / 120 fps 仍标为实验档；HDR 开关已接通 HLG 10-bit，连接时锁定，并显示等待验证、HDR 已确认或 SDR 回退状态。

已创建全局技能 `liquid-glass-interface`，包括网页 CSS / JS / 交互示例及 macOS / Android 实现指南。后续项目可输入：

> 使用 $liquid-glass-interface 优化当前界面，保留原有功能。

技能默认配色可替换，不绑定 Nextend、绿色或双栏布局。交付包中的技能目录可复制到另一台机器的 Codex skills 目录。

## 51 fps 能否说明无线带宽不足

不能。此前无线测试实际编码数据率约 **0.537 Mbps**，45 Mbps 是编码器目标；测试画面易压缩，没有测出 Wi-Fi 的最大吞吐。

| 场景 | Pad 呈现回调均值 | 末次往返 P95 |
|---|---:|---:|
| USB，3200×2136，目标 60 | 59.77 fps | 54.17 ms |
| USB，3200×2136，目标 120 | 63.74 fps | 69.50 ms |
| USB，2400×1600，目标 120 | 76.19 fps | 56.23 ms |
| Wi-Fi，3200×2136，目标 60 | 50.67 fps | 133.73 ms |

无线结果更明显的问题是确认延迟和波动，在最多 4 帧未确认的机制下会限制出帧。编码时间也是高刷限制之一；这些数据不能把原因归结为某个单一部件。有线在当前原生 60 fps 测试中稳定，120 fps 档并未达到 120 fps。

此前半小时 USB 实测排除首分钟后约 59.96 fps。用户手摸 Pad 未感到升温，Android 系统也未报告热压力；这两项均不是物理温度测量。新版视觉更新只补做短测，旧版长测结果保持原始归属。

若继续定位无线极限，下一步是同一动态内容下同时记录实际发送速率、编码耗时、确认延迟与队列占用，再用受控局域网吞吐测试区分网络与处理限制。无需为这次界面更新重新进行半小时长测。

## HDR 已接入 HLG / HEVC Main10

0.3.0 已接通 HDR 虚拟屏、浮点采集、Metal 色彩转换、HEVC Main10 编码、加密传输、Android 硬解和 SurfaceView 输出。最终构建通过 USB / 无线各 30 秒真实桌面高光测试：SDR 白位及 2 / 3 / 4 倍高光在采集转换后仍为不同的 10-bit 值，Pad Surface 的 dataspace 为 BT.2020 HLG。USB 呈现回调均值 59.96 fps、P95 57.58 ms；无线为 46.85 fps、142.96 ms。异常 HDR 回退、旧版兼容、取消及虚拟屏清理也通过，详见 `HDR-VALIDATION.md`。此前半小时 SDR 数据仍归属旧版，不能当作 HDR 长测。

原计划采用 ScreenCaptureKit 的 canonical HDR 预设。本机 macOS 27.0.1 实测输出是 10-bit 4:4:4 P3 / PQ；强制 HLG 覆盖没有得到可信的一致标记，因此没有直接接到 HLG 编码器。当前使用原生配置的 RGhA 浮点 CGDisplayStream，自行完成扩展 sRGB → 线性 BT.2020 → HLG → P010。显式给捕获器指定线性色域曾截断高光，已根据真实阶梯值修正。[Apple HDR 采集说明](https://developer.apple.com/videos/play/wwdc2024/10088/)

HDR 使用 HEVC Main10、BT.2020、HLG、有限范围、4:2:0。SDR 白位按照 203 nits 参考、1000 nits 系统映射进行编码；这不是对 Pad 实际峰值亮度的测量。HDR 面板能力声明、编码输出和解码输出都检查；Android 保留 SurfaceView，输出格式不匹配时停止显示。[Android HDR 呈现说明](https://developer.android.com/media/grow/hdr-playback)

支持开启 HDR 不等于把所有 SDR 窗口变成 HDR。内容本身需要提供超出 SDR 白位的亮度信息。本版不包含 PQ / HDR10、Dolby Vision，也未完成校色仪测量或全色域色准验收。HDR 虚拟屏使用私有 API，浮点捕获 API 已弃用，需在系统升级后重新验证。

## 兼容与分发

为保持既有配对，应用标识 `dev.padbridge.mac` / `dev.padbridge`、私有配对目录与协议常量保持不变，用户可见名称和安装文件改为 Nextend。无需重置配对。

Mac 当前仍是临时签名、未公证的本机开发构建；修改构建可能需要系统重新确认原有屏幕录制权限。Android 仍是用于 USB `run-as` 配对的调试构建。正式发布签名与免调试 USB 接入不属于此次 HDR 集成。
