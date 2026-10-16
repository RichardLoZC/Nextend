# 实现结构

`macos/` 是无需完整 Xcode 的原生 AppKit 应用，使用 Swift 编译器和系统框架构建。`android/` 是 Kotlin Activity / SurfaceView 应用，无 Compose 或外部网络依赖。

```
SDR 虚拟屏 → ScreenCaptureKit NV12 BT.709 ──────────────┐
HDR EDR 虚拟屏 → CGDisplayStream RGhA → Metal P010 HLG ──┤
                                                      ↓
                             VideoToolbox → AES-GCM → USB / Wi-Fi
                                                      ↓
                             MediaCodec Main / Main10 → SurfaceView
```

Mac 虚拟屏用稳定 vendor/product/serial 身份；逻辑尺寸为流分辨率的一半。`NativeVirtualDisplay` 在同一可执行文件的 `--display-host` 辅助进程内创建并配置屏幕，UI 进程通过私有管道控制；辅助进程不接触配对密钥或视频。创建后等待 WindowServer 发布模式再选择，启用后检查并纠正模式。断开时终止辅助进程，并确认显示器离线，窗口由 macOS 重新安置。

采集缓冲池深度 6；编码前限制整条链路最多 4 帧未确认。4 帧额度可覆盖原生 60 Hz 约 50 ms 的解码确认往返，避免每隔数帧因额度不足而跳帧。禁止 B 帧，要求硬件编码器。HEVC 初始化失败可退回 H.264，Pad 对具体画面尺寸/帧率声明硬解能力。Pad codec 回调在独立 HandlerThread，接收线程不负责等待下一帧才排空输出。

每个 Mac `Session` 只使用一次。断开、错误、Mac 睡眠或 Pad Activity 退出会终止链路并释放资源；唤醒或重新插线后可再次点击连接。不在断线后自动打开网络接口。

无线视频连接期间，Pad 请求 Android 的前台 Wi-Fi 低延迟锁；断开或 Activity 暂停时释放。设备决定该请求的实际效果。本机短测从约 50.2 fps 变为 50.7 fps，单次对比不足以证明改善。它不用于 USB，也不改变 VPN 或系统网络配置。参考 [Android Wi-Fi 低延迟模式](https://developer.android.com/reference/android/net/wifi/WifiManager#WIFI_MODE_FULL_LOW_LATENCY)。

等待连接时，用不透明背景视图覆盖视频 Surface。真机上仅调整 SurfaceView 的 alpha 会残留部分旧帧，因此保持 Surface 可供后续解码使用，并在连接状态变化时切换遮罩。

## 已纳入本版

- 真正拓展屏与 2 倍 HiDPI。
- 60/90/120 Hz 虚拟屏和对应编解码配置。
- 原生 3200×2136 与 2400×1600 选项。
- H.264 / HEVC 硬件编解码，BT.709 SDR 与 HLG 10-bit HDR。
- USB 自动转发与配对；无线直接 IP、物理接口选择、配对加密。
- 菜单内性能详情、可选且可拖动的 FPS 浮层、合成测试源、JSON 测试报告。
- 连接超时、流控、关键帧恢复、停止和睡眠时资源释放。
- Mac 端拒绝输入回传；Pad 点击只控制本地界面。

## 后续验收和扩展

此前 SDR 按用户要求使用半小时持续负载作为初步验收；0.3.0 HDR 本轮使用 USB / 无线各 30 秒真实桌面测试。更长时间、实际 VPN 开关/切换、物理拔插、睡眠唤醒、不同画面复杂度和热状态仍需专项测试。短测结果不能代替这些验收。

AOA 免 USB 调试、扫码发现、自动重连、PQ / HDR10、Dolby Vision 与完整广色域验收尚未完成。HDR 使用真实浮点源、Main10 码流检查、MediaCodec 输出格式及 Surface dataspace 证据；细节见 `HDR-VALIDATION.md`。这仍不是物理屏幕峰值亮度或色准测量。

`CGVirtualDisplay` 为 macOS 私有 API，系统升级后需要重跑模式探测；不用于 App Store 提交。

## HDR 资源和失败处理

HLG 请求在编解码协商前检查 Pad 的 HLG 面板与目标尺寸/帧率的硬件 Main10 能力。缺少新能力字段视为旧版 SDR。失败时先完成采集、编码及连接清理，保留正常的辅助进程和虚拟屏，重新应用 SDR 模式并重连一次。若辅助进程未就绪或已经退出，先确认它清理完成，再创建 SDR 辅助进程；SDR HEVC 初始化失败可继续尝试 H.264。用户断开、退出或休眠会撤销待执行回退。

浮点采集只接受 RGhA，与经过校验的扩展 sRGB 显示配置配合使用；每两秒重查虚拟屏模式、EDR headroom 与 ICC，不匹配就停止 HDR。Metal 输出池最多 8 张 P010，进入转换前就检查 4 帧在途额度。CGDisplayStream 必须等最终 `.stopped` 回调后释放；超时不会继续重连。解码器确认 BT.2020 / HLG / limited 后才释放视频帧给 Surface。

发送失败不能抢在接收端 `hdr-error` 前关闭会话；先保留错误，让读线程按到达顺序处理最终拒绝和 EOF，现有有界超时负责兜底。

最终断开关闭控制管道并向所属辅助进程发 SIGTERM，等待进程结束和屏幕从 online 列表移除。5 秒后若进程仍存活，终止该进程并再等最多 3 秒。等待使用不受任务取消影响的延迟，避免取消连接时跳过清理。仍未移除则报告失败并停止允许重连，提示重开应用。

辅助进程创建屏幕后立即发布显示 ID；启动中取消且尚未收到 ID 时，按固定 vendor/product/serial 核对列表。启动前拒绝已经存在的同身份屏幕。父进程异常退出会关闭管道，辅助进程收到 EOF 即退出。不能把释放对象引用等同于系统已移除屏幕，也不能将 `CGDisplayIsOnline` 的非零结果一律当作在线：本机对已移除 ID 返回 -1，因此使用 `CGGetOnlineDisplayList` 做最终确认。

## 0.4.0 界面状态

Mac 窗口不拥有连接生命周期；关闭最后一个窗口不会退出，菜单栏和 Dock 可恢复窗口。显式退出仍等待 Session 清理。活动连接通过 ProcessInfo activity 避免 App Nap，系统休眠仍按原逻辑断开。

Mac Session 通过结构化 StatusKind 通知连接状态，界面不再解析中文字符串前缀。AppMessage 保留翻译键与参数，切换语言时重新渲染既有状态和错误，避免因翻译而触发业务逻辑。

Pad 的语言切换只重建控制面板，不重建 SurfaceView、Activity 或 Receiver。统计与状态分开回调。FPS 来源为 MediaCodec OnFrameRenderedListener 在一个统计周期内的回调数除以单调时钟经过时间。菜单、浮层和 Mac 使用相同的统计来源；面板 Hz 单独显示。没有视频时隐藏浮层；连接开始时清空旧数值。

FPS 在静止的透明 View 中绘制，拖动只更新绘制坐标，避免平移文字控件和视频 Surface 叠加时的重布局。拖动期间保留当前文字，松手后显示最新样本。徽标在手指上方显示，靠近底边时逐渐取消抬升，以便放到屏幕边缘。徽标外的普通触摸交给底层视频，点按徽标仍打开菜单。

FPS 位置按父视图可移动范围归一化保存，拖动、字体改变及屏幕尺寸变化后限制在可见范围。用户偏好仅保存在 Android 私有 SharedPreferences；配对密钥仍与这些界面设置分开。
