# Nextend

**把 Android 平板变成 Mac 的拓展屏。**

[English](README.md) · [下载版本](https://github.com/RichardLoZC/Nextend/releases) · [实现结构](docs/ARCHITECTURE.md)

当前开发版本 **0.6.0**，触屏需配套更新 Mac 和 Android。原生 Mac / Android 应用，采用液态玻璃界面和 n 形玻璃桥图标。支持真正的 HiDPI 拓展桌面、USB / 配对加密无线、HEVC / H.264 硬件编解码和 HLG 10-bit HDR。

## 这版改动

- Mac 的“开启触屏”开关默认关闭，连接中可切换直接触屏或触控板。触控板模式保留拓展桌面画面。
- 双指轻点右键、滑动滚动；触控板增加单指轻点后拖动、三指拖动、四指桌面操作和捏合缩放。
- Pad 菜单取消，FPS 和诊断集中到 Mac“Pad 设置”；Pad 等待页新增“连接”。
- Mac 关闭窗口后隐藏 Dock 图标，保留状态栏入口和后台连接；重新打开窗口时恢复 Dock 图标。
- 连接方式统一在 Mac 选择，Pad 自动接受 USB 或已配对的加密无线连接；换网时更新无线监听。
- 自动协商硬件编码：优先 HEVC，兼容回退 H.264；HDR 使用 HEVC Main10。Mac 不再显示编码下拉框。
- Mac 右上角一键切换中文 / English。
- 修正硬件临时丢帧导致立刻断线的问题，补充高刷瓶颈测试。

原有功能继续保留：

- Mac 关闭窗口后继续在后台传输；可从状态栏或“应用程序”重新打开。只有断开、退出、休眠或链路中断才结束连接。
- Pad 投屏时没有菜单；设置和诊断集中在 Mac。Pad 等待页可以主动连接已配对的 Mac。
- 可选 FPS 浮层，显示真实呈现回调帧率。在 Mac“Pad 设置”中调整任意位置、颜色、字体与字号，重启后保留。
- Mac 一键切换中文 / English，并同步到 Pad，切换时保持当前连接。
- 清理装饰性小字，仅保留必要的状态、选项与使用提示。

## 安装与使用

从 [Releases](https://github.com/RichardLoZC/Nextend/releases) 下载配套 Mac ZIP 和 Android APK，或自行构建。这是开发版本：Mac 为临时签名、未公证；Android 为可调试构建，当前 USB 配对依赖 `adb run-as`。

1. Pad 开启 USB 调试、允许这台 Mac；部分小米设备需要单独允许 USB 安装。安装并打开 Nextend，投屏期间保持前台。
2. 将 `Nextend.app` 放到 `/Applications` 或 `~/Applications` 后打开，点击“屏幕录制权限”，在系统设置允许 Nextend，按提示退出重开。
3. 在 Mac 选择“USB 有线”并点击“连接”，Pad 无需选择模式。用“排列显示器”调整位置，然后把窗口拖到新桌面。
4. 完成 USB 配对后，断开并在 Mac 选“加密无线”。Mac 会记住 USB 握手中返回的 Pad 无线地址，也可手动输入 Pad 的地址；选择实际网卡，默认 `en0`。换网后 Pad 自动更新监听，Mac 可通过 USB 重连刷新地址或手动输入。新版优先由 Pad 主动建立无线视频通道，无需 Mac 反向拨入 Pad。VPN 若阻止所有局域网访问仍可能影响无线；USB 不经过这条路由。已连接时先断开再切换。
5. HDR 需先断开，在 Mac 打开 HDR 再连接。“HDR · HLG 10-bit”表示输出格式已确认；不可用时自动回退 SDR 并给出原因。

Mac 右上角按钮切换中英文，并同步到 Pad。“Pad 设置”包含 FPS 显示、字体、字号、颜色、水平与垂直位置，以及性能诊断。Pad 没有投屏菜单。“重新配对”位于 Mac 状态栏菜单中。

首次仍从 Mac 通过 USB 配对。之后可在 Pad 等待页点击“连接”：优先尝试 USB，请求成功后实际视频也使用 USB，即使 Mac 上次选择了无线。USB 不可用时通过 Bonjour 发现 Mac，使用配对密钥请求加密无线。画质沿用 Mac 设置，Mac 必须保持运行，窗口可以关闭。无线视频复用 Pad 主动建立的 TCP 连接，并重新认证；无需关闭仅限制入站连接的 VPN。

首次开启触屏，需在 macOS“系统设置 → 隐私与安全性 → 辅助功能”允许 Nextend，再打开“开启触屏”。退出 Mac 应用后开关恢复关闭。

| 手势 | 直接触屏 | 触控板 |
|---|---|---|
| 单指 | 在拓展屏点按、双击、拖动 | 相对移动 Mac 光标；轻点、双击；轻点后再次按住拖动 |
| 双指 | 轻点右键，滑动滚动 | 轻点右键，滑动滚动，捏合缩放 |
| 三指 | — | 按住鼠标左键拖动 |
| 四指 | — | 左右切换桌面，上滑窗口总览，下滑 App 窗口 |

触控板可移动到 Mac 的所有活动显示器。捏合映射到 Command +/−，四指滑动映射到 Control + 方向键，效果取决于应用和 macOS 快捷键设置。暂不模拟压力、旋转、原生连续缩放，也不声称覆盖 Apple 触控板的全部手势。滚动方向跟随 Mac 的自然滚动偏好。

实测 Pad 7 Ultra 的三指及以上手势仍被小米系统拦截，单指和双指操作正常。三指拖动被拦截时，可单指轻点一次，随即在附近再次按住并移动，抬手结束拖动。

普通 Android App 没有禁用全部厂商手势的通用接口。小米官方为部分设备提供“Game Turbo → 游戏免打扰 → 增强体验 → 限制截图手势”的方法，但用户在当前 Pad 找不到这个入口。此方法也不保证禁用分屏等其他手势。Nextend 不修改全局手势设置。参见[小米说明](https://www.mi.com/global/support/faq/details/KA-673391/)。

关闭 Mac 窗口保持连接，并隐藏 Dock 中的运行图标；从状态栏选择“打开 Nextend”后恢复窗口和 Dock 图标。最小化仍保留 Dock 图标。“断开连接”停止会话；“退出 Nextend”停止并退出，虚拟屏窗口由 macOS 收回。Pad 离开前台、Mac 休眠或网络中断也会停止连接，恢复后手动重连。

## 设备与限制

实际验证设备为 M4 MacBook Air、macOS 27.0.1 与 Xiaomi Pad 7 Ultra、Android 16。运行要求 Apple Silicon、macOS 14+、Android 11+；其他组合尚未实测。

60 / 90 / 120 fps 是目标档位，不是稳定性能保证，建议先用 USB、60 fps。静态桌面可能减少出帧。HDR 采用 BT.2020 / HLG、HEVC Main10、有限范围、10-bit 4:2:0；不支持 PQ / HDR10、Dolby Vision，尚未测量物理屏幕亮度与色准。没有音频、通用键盘回传和自动重连；Bonjour 仅发现 Mac，不能替代配对认证。

虚拟屏依赖 macOS 私有 API，HDR 浮点采集使用已弃用的 CGDisplayStream，系统升级后需复验。原包标识和配对存储保留 PadBridge 名称，确保升级沿用配对。

若新版 Mac 显示“开关已开但无权限”，在系统屏幕录制设置中移除旧 Nextend，重新加入当前应用并退出重开。临时签名绑定每次构建的代码哈希，不能靠放宽签名要求保留权限。无线另需“本地网络”权限；若更新后开关已开但无线访问失败，可将已有的 Nextend 本地网络权限关闭再开启，然后重试。

## 构建与验证

需要含 macOS 26+ SDK 的 Command Line Tools、JDK 17、Android SDK 36 和 ADB；无需完整 Xcode。macOS 26 之前使用材质回退。

```sh
./scripts/build-macos.sh
./scripts/build-android.sh
./scripts/install-usb.sh
mkdir -p "$HOME/Applications"
ditto outputs/Nextend.app "$HOME/Applications/Nextend.app"
open "$HOME/Applications/Nextend.app"
```

覆盖安装前先退出旧应用。请从“应用程序”目录运行；直接放在“文稿”内运行时，VideoToolbox 可能等待受保护目录的访问许可。

可设置 `JAVA_HOME`、`ANDROID_HOME`、`ADB`；Android 有缓存时可传 `--offline`。依赖固定为 Gradle 8.13、AGP 8.11.1、Kotlin 2.2.0。

```sh
./scripts/test.sh --offline
python3 tests/display_lifecycle.py
python3 tests/hdr_fallback.py
python3 tests/device_protocol.py
python3 tests/touch_protocol.py
python3 tests/connect_request.py
python3 tests/transport_switch.py
python3 tests/listener_recovery.py
```

显示与传输测试须串行。生命周期测试临时创建虚拟屏；HDR 回退测试需要本机已有配对；协议测试需要 Pad 打开并处于等待页及 Python `cryptography`；双传输和监听恢复测试还需要可达的同一 Wi-Fi 网络。监听恢复测试会重启 Pad 应用、临时占用无线端口，以验证恢复能力。

`connect_request.py` 另需 Mac 图形应用保持运行且未连接，并完成过 USB 配对。它只测试无效请求，不发起投屏、不发送系统输入。

`--capture-test` 测真实采集，`--benchmark` 只测合成画面；命令参数见 `Nextend --help`。FPS 来自实际呈现回调，不等于面板刷新率，也不是光学延迟。

[0.6.0 触控与连接验证](docs/RELEASE-0.6.md)、[0.5.0 验证与高刷分析](docs/RELEASE-0.5.md)、[0.4.0 验证记录](docs/RELEASE-0.4.md)、[0.3.0 HDR 结果](docs/HDR-VALIDATION.md)、[早期 SDR 结果](docs/VALIDATION.md) 分别记录各版本证据，短测不能代替长期稳定性验收。

## 许可与设计

源码使用 GPL-3.0，见 [LICENSE](LICENSE) 和 [上游来源](THIRD_PARTY_NOTICES.md)。本项目不是 OpenDisplay 官方发行版，应配套使用 Nextend 两端。

可复用的[液态玻璃 skill](skills/liquid-glass-interface/SKILL.md)包含原生与网页规范及示例；[协议](docs/PROTOCOL.md)与[架构](docs/ARCHITECTURE.md)说明传输实现。
