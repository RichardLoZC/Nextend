# 实现结构

`macos/` 是无需完整 Xcode 的原生 AppKit 应用，使用 Swift 编译器和系统框架构建。`android/` 是 Kotlin Activity / foreground Service / SurfaceView 应用，无 Compose 或外部网络依赖。

```
SDR 虚拟屏 → ScreenCaptureKit NV12 BT.709 ──────────────┐
HDR EDR 虚拟屏 → CGDisplayStream RGhA → Metal P010 HLG ──┤
                                                      ↓
                             VideoToolbox → AES-GCM → USB / Wi-Fi
                                                      ↓
                             MediaCodec Main / Main10 → SurfaceView
```

Mac 虚拟屏用稳定 vendor/product/serial 身份；逻辑尺寸为流分辨率的一半。`NativeVirtualDisplay` 在同一可执行文件的 `--display-host` 辅助进程内创建并配置屏幕，UI 进程通过私有管道控制；辅助进程不接触配对密钥或视频。创建后等待 WindowServer 发布模式再选择，启用后检查并纠正模式。断开时终止辅助进程，并确认显示器离线，窗口由 macOS 重新安置。

默认采集缓冲池深度 6、编码前最多 4 帧未确认；90/120 fps 且像素数不超过 2400×1600 时，采用池深度 8、最多 6 帧未确认。4 帧额度可覆盖原生 60 Hz 约 50 ms 的解码确认往返，避免每隔数帧因额度不足而跳帧。禁止 B 帧，要求硬件编码器。HEVC 初始化失败可退回 H.264，Pad 对具体画面尺寸/帧率声明硬解能力。Pad codec 回调在独立 HandlerThread，接收线程不负责等待下一帧才排空输出。

每个 Mac `Session` 只使用一次。断开、错误、Mac 睡眠或 Pad 服务退出会终止链路并释放资源；唤醒或重新插线后可再次点击连接。0.7.0 起，Pad 的 connectedDevice 前台服务拥有两路 Receiver 与 SessionLease，Activity 只借出 Surface。切换应用不再关闭传输或虚拟屏。Pad 同时监听 USB loopback 与实际 Wi-Fi IPv4，断线后可从 Mac 选择任一路径重连；不会自动开始新的传输。

无线视频连接期间，Pad 请求 Android 的前台 Wi-Fi 低延迟锁；断开时释放；后台活动会话另持有 partial wake lock。设备决定该请求的实际效果。本机短测从约 50.2 fps 变为 50.7 fps，单次对比不足以证明改善。它不用于 USB，也不改变 VPN 或系统网络配置。参考 [Android Wi-Fi 低延迟模式](https://developer.android.com/reference/android/net/wifi/WifiManager#WIFI_MODE_FULL_LOW_LATENCY)。

等待连接时，用不透明背景视图覆盖视频 Surface。真机上仅调整 SurfaceView 的 alpha 会残留部分旧帧，因此保持 Surface 可供后续解码使用，并在连接状态变化时切换遮罩。

## 已纳入本版

- 真正拓展屏与 2 倍 HiDPI。
- 60/90/120 Hz 虚拟屏和对应编解码配置。
- 原生 3200×2136 与 2400×1600 选项。
- H.264 / HEVC 硬件编解码，BT.709 SDR 与 HLG 10-bit HDR。
- USB 自动转发与配对；无线直接 IP、物理接口选择、配对加密。
- Mac 内性能详情、可选的 FPS 浮层、合成测试源、JSON 测试报告。
- 连接超时、流控、关键帧恢复、停止和睡眠时资源释放。
- 触屏默认关闭。0.6.0 的可选扩展在现有认证连接中传输，Mac 本地开关与辅助功能权限共同授权；旧端仅传视频。

## 后续验收和扩展

此前 SDR 按用户要求使用半小时持续负载作为初步验收；0.3.0 HDR 本轮使用 USB / 无线各 30 秒真实桌面测试。更长时间、实际 VPN 开关/切换、物理拔插、睡眠唤醒、不同画面复杂度和热状态仍需专项测试。短测结果不能代替这些验收。

AOA 免 USB 调试、扫码发现、自动重连、PQ / HDR10、Dolby Vision 与完整广色域验收尚未完成。HDR 使用真实浮点源、Main10 码流检查、MediaCodec 输出格式及 Surface dataspace 证据；细节见 `HDR-VALIDATION.md`。这仍不是物理屏幕峰值亮度或色准测量。

`CGVirtualDisplay` 为 macOS 私有 API，系统升级后需要重跑模式探测；不用于 App Store 提交。

## HDR 资源和失败处理

HLG 请求在编解码协商前检查 Pad 的 HLG 面板与目标尺寸/帧率的硬件 Main10 能力。缺少新能力字段视为旧版 SDR。失败时先完成采集、编码及连接清理，保留正常的辅助进程和虚拟屏，重新应用 SDR 模式并重连一次。若辅助进程未就绪或已经退出，先确认它清理完成，再创建 SDR 辅助进程；SDR HEVC 初始化失败可继续尝试 H.264。用户断开、退出或休眠会撤销待执行回退。

浮点采集只接受 RGhA，与经过校验的扩展 sRGB 显示配置配合使用；每两秒重查虚拟屏模式、EDR headroom 与 ICC，不匹配就停止 HDR。Metal 输出池最多 8 张 P010，进入转换前就检查当前 4/6 帧在途额度。CGDisplayStream 必须等最终 `.stopped` 回调后释放；超时不会继续重连。解码器确认 BT.2020 / HLG / limited 后才释放视频帧给 Surface。

发送失败不能抢在接收端 `hdr-error` 前关闭会话；先保留错误，让读线程按到达顺序处理最终拒绝和 EOF，现有有界超时负责兜底。

最终断开关闭控制管道并向所属辅助进程发 SIGTERM，等待进程结束和屏幕从 online 列表移除。5 秒后若进程仍存活，终止该进程并再等最多 3 秒。等待使用不受任务取消影响的延迟，避免取消连接时跳过清理。仍未移除则报告失败并停止允许重连，提示重开应用。

辅助进程创建屏幕后立即发布显示 ID；启动中取消且尚未收到 ID 时，按固定 vendor/product/serial 核对列表。启动前拒绝已经存在的同身份屏幕。父进程异常退出会关闭管道，辅助进程收到 EOF 即退出。不能把释放对象引用等同于系统已移除屏幕，也不能将 `CGDisplayIsOnline` 的非零结果一律当作在线：本机对已移除 ID 返回 -1，因此使用 `CGGetOnlineDisplayList` 做最终确认。

## 0.4.0 界面状态

Mac 窗口不拥有连接生命周期；关闭最后一个窗口不会退出。0.5.1 起，主窗口关闭时将 activation policy 改为 accessory，隐藏 Dock 运行图标，保留状态栏与 Session；从状态栏或“应用程序”重新打开时先恢复 regular，再显示并激活原窗口。最小化不改变 activation policy。显式退出仍等待 Session 清理。活动连接通过 ProcessInfo activity 避免 App Nap，系统休眠仍按原逻辑断开。

Mac Session 通过结构化 StatusKind 通知连接状态，界面不再解析中文字符串前缀。AppMessage 保留翻译键与参数，切换语言时重新渲染既有状态和错误，避免因翻译而触发业务逻辑。

Mac 通过已协商的 pad-settings 消息同步 Pad 语言与 FPS 样式、位置。Pad 仅重建等待页，不重建 SurfaceView、Activity 或 Receiver。FPS 来源为 MediaCodec OnFrameRenderedListener 回调数除以单调时钟经过时间；Mac 单独显示面板 Hz。FPS 在透明 View 内绘制，不截获触摸；位置限制在可见范围，用户偏好保存在 Mac UserDefaults 与 Pad 私有 SharedPreferences。配对密钥独立存储。

## 0.5.0 自动连接与编码

Pad 的两个接收器独立认证，共享 SessionLease，只有持有者能创建解码器。无效认证或第二个连接不能覆盖活动连接状态。Wi-Fi 网络回调只替换受影响的无线接收器；0.7.0 起，Activity 暂停取消触控，停止可见或 Surface 销毁只释放解码输出；两路接收器由服务持有，继续保活。监听异常退出后移除失效实例，以 0.5/1/2/4/8 秒最多重试 5 次；过期代次或地址变化取消旧重试。接收器代次与身份检查忽略已撤销的回调。解码器清理超过等待时限时仍持有所有权，直到实际释放才允许后续会话。

Mac 的主界面只选择传输、分辨率、目标帧率和 HDR；编码由具体配置的硬件能力协商。默认优先 HEVC，SDR 编码器初始化失败可尝试另一种已声明的编码；CLI 的 auto / hevc / h264 用于诊断。HDR 仅接受 HEVC Main10。语言入口为直接切换按钮，不影响正在运行的 Session。

真实高刷表现取决于采集内容、像素数、编解码能力与传输路径。不要通过扩大队列宣称性能提升；本机 3200×2136 对照中扩大队列没有提高吞吐，仅增加延迟，因此原生分辨率保留 4 帧上限。2400×1600 高刷采集的短测则受益于 6 帧额度，代价是小幅增加往返延迟；只对这一较低像素范围启用，120 fps 也不超过 6。见 RELEASE-0.5.md。

## 0.6.0 输入与连接请求

Mac 的开启触屏开关和直接触屏/触控板选择在连接中生效。TouchInputController 用锁建立同步授权边界；TouchGate 处理代次、绝对/相对坐标和释放。相对移动累加在本地锚点，避免事件投递延迟使光标回跳。开关默认关闭；App 的辅助功能权限及活动虚拟屏必须有效。

Pad TouchGesture 独立识别单指、双指点击/滚动、三指拖动和四指滑动。TouchTapHistory 保留一次完成的轻点，让下一次附近接触在移动时开始单指拖动；时间和距离遵循 Android 双击阈值。TouchSurface 处理取消、指针 ID 和尺寸变化，并在取消或重新配置时清除轻点记录。TouchSender 使用最多 64 条的有界写队列，合并移动时累加相对位移，保留动作边界；拖动心跳使用零增量。系统取消会释放拖动，但无法阻止厂商系统先截获多指手势。

ConnectRequestServer 处理独立认证的 PDR1 请求，Bonjour 仅用于发现。Pad 显式 Connect 优先选择 USB 视频，成功的无线请求使用来源地址更新 Mac；画质和输入授权保持在 Mac。GUI 的无线 Session 等待 Pad 的出站连接，8 秒没有移交才使用旧版直连。空闲 resume 轮询只接续已存在的等待槽，不能自行启动 Session。ACK 前预留等待槽，移交后使用全新 PDB1 握手。Pad 同步转移 socket 所有权，并以接收器空闲和 Surface lease 释放作为就绪条件；HDR 回退也遵循这个条件。Pad 请求和 UI 回调各自带代次，在暂停、Surface 重建及开始/结束连接时失效。PairStore 的代次锁防止撤销前的 ADB 准备重新保存授权。具体消息见 PROTOCOL.md。

## 0.7.0 后台恢复与安全区

Activity.onStop 在解绑前等待 Surface 输出释放；Surface 销毁也有释放屏障。MediaCodec 的创建、释放、输入和回调由同一个 HandlerThread 串行处理。Surface 代次阻止旧回调访问新输出，挂起时以 decoded=false ACK 归还所有在途帧额度；解码器真正释放后才归还 SessionLease。服务在无界面且无连接时停止，显式断开、划掉任务、网络失效仍释放会话。通知权限由等待页按钮主动请求。

Pad 在原有 stats 消息里报告 viewerVisible，新 Mac 在隐藏期间暂停编码，保留一张最新采集帧。返回时请求关键帧，静态桌面也能重放；恢复帧遇到背压、编码器丢帧或 Pad 负 ACK 时保留恢复请求，按有限频率重试，成功解码 ACK 才完成。HDR 首次验证的八秒只计算可见时间。

PadDisplayArea 保存四边 0–20% 的相对留白。DisplayArea.fit 在剩余区域内等比缩放完整视频，启用时对齐安全区上沿，使菜单栏位于手动避让范围下方。FPS 使用同一区域；触控按实际 SurfaceView 尺寸归一化。调整尺寸先取消当前手势。Mac 原生预览使用 Pad 面板与视频尺寸比例；它是布局预览，物理刘海仍由用户观察校准。旧 Mac 省略 safeArea 时，Pad 保留已保存的校准。

## Pad 菜单栏折叠（Mac 0.7.1）

Session 在虚拟屏采集就绪后创建 PadNotchController，断开时关闭该显示器上的校准线、遮罩和图标面板。PadNotch 保存归一化的左右边界与深度；校准线是临时 UI 状态。启用折叠或校准时，PadSettings 将现有 safeArea.enabled 下发为 false，保持桌面坐标与物理屏幕一致，无需新增 Android 协议。

MenuBarItems 仅枚举目标显示器菜单栏的有限 AX 层级。macOS 27 从 MenuBarAgent 的呈现与宿主节点取得图标；较早系统走各应用的 extras menu bar。读取在串行后台队列中执行，每个 AX 对象设置短超时，并限制整轮读取时间。PadNotchController 仅遮盖普通应用图标；系统指示保留原位。ScreenCaptureKit 排除自身浮层后获取菜单栏缩略图，仅在前后元素身份和位置一致时使用。缩略图仅保存在内存。

点击按 AX 元素身份唯一匹配，不用应用名称代替图标身份。遮罩隐藏后重新读取位置、执行命中校验，再检查显示器、授权、请求序号和设置版本。无法确认目标或用户已取消时，不发送点击。显示器重排、设置更新和断连均使旧请求失效。
