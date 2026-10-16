# Nextend

**把 Android 平板变成 Mac 的拓展屏。**

[English](README.md) · [下载版本](https://github.com/RichardLoZC/Nextend/releases) · [实现结构](docs/ARCHITECTURE.md)

当前版本 **0.5.0**。原生 Mac / Android 应用，采用液态玻璃界面和 n 形玻璃桥图标。支持真正的 HiDPI 拓展桌面、USB / 配对加密无线、HEVC / H.264 硬件编解码和 HLG 10-bit HDR。

## 这版改动

- 连接方式统一在 Mac 选择，Pad 自动接受 USB 或已配对的加密无线连接；换网时更新无线监听。
- 自动协商硬件编码：优先 HEVC，兼容回退 H.264；HDR 使用 HEVC Main10。Mac 不再显示编码下拉框。
- Mac 右上角一键切换中文 / English。
- 修正硬件临时丢帧导致立刻断线的问题，补充高刷瓶颈测试。

原有功能继续保留：

- Mac 关闭窗口后继续在后台传输；可从 Dock 或菜单栏重新打开。只有断开、退出、休眠或链路中断才结束连接。
- Pad 投屏时隐藏调试信息，点按画面后在菜单内查看。
- 可选 FPS 浮层，显示真实呈现回调帧率。可拖到任意位置，设置颜色、字体与字号，重启后保留。
- 两端可独立切换中文 / English，切换时保持当前连接。
- 清理装饰性小字，仅保留必要的状态、选项与使用提示。

## 安装与使用

从 [Releases](https://github.com/RichardLoZC/Nextend/releases) 下载配套 Mac ZIP 和 Android APK，或自行构建。这是开发版本：Mac 为临时签名、未公证；Android 为可调试构建，当前 USB 配对依赖 `adb run-as`。

1. Pad 开启 USB 调试、允许这台 Mac；部分小米设备需要单独允许 USB 安装。安装并打开 Nextend，投屏期间保持前台。
2. 将 `Nextend.app` 放到 `/Applications` 或 `~/Applications` 后打开，点击“屏幕录制权限”，在系统设置允许 Nextend，按提示退出重开。
3. 在 Mac 选择“USB 有线”并点击“连接”，Pad 无需选择模式。用“排列显示器”调整位置，然后把窗口拖到新桌面。
4. 完成 USB 配对后，断开并在 Mac 选“加密无线”。Mac 会记住 USB 握手中返回的 Pad 无线地址，也可手动输入 Pad 等待页显示的地址；选择实际网卡，默认 `en0`。换网后 Pad 自动更新监听，Mac 可通过 USB 重连刷新地址或手动输入。VPN 需允许局域网流量。USB / 无线切换仅在 Mac 完成；已连接时先断开。
5. HDR 需先断开，在 Mac 打开 HDR 再连接。“HDR · HLG 10-bit”表示输出格式已确认；不可用时自动回退 SDR 并给出原因。

Mac 右上角按钮直接切换语言，菜单栏也提供切换入口。Pad 点按视频或 FPS 可打开菜单，里面有语言和 FPS 设置；拖动 FPS 只调整位置，不向 Mac 发送触控。

关闭 Mac 窗口保持连接；“断开连接”停止会话；“退出 Nextend”停止并退出，虚拟屏窗口由 macOS 收回。Pad 离开前台、Mac 休眠或网络中断也会停止连接，恢复后手动重连。

## 设备与限制

实际验证设备为 M4 MacBook Air、macOS 27.0.1 与 Xiaomi Pad 7 Ultra、Android 16。运行要求 Apple Silicon、macOS 14+、Android 11+；其他组合尚未实测。

60 / 90 / 120 fps 是目标档位，不是稳定性能保证，建议先用 USB、60 fps。静态桌面可能减少出帧。HDR 采用 BT.2020 / HLG、HEVC Main10、有限范围、10-bit 4:2:0；不支持 PQ / HDR10、Dolby Vision，尚未测量物理屏幕亮度与色准。没有音频或输入回传、自动发现和自动重连。

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
python3 tests/transport_switch.py
python3 tests/listener_recovery.py
```

显示与传输测试须串行。生命周期测试临时创建虚拟屏；HDR 回退测试需要本机已有配对；协议测试需要 Pad 打开并处于等待页及 Python `cryptography`；双传输和监听恢复测试还需要可达的同一 Wi-Fi 网络。监听恢复测试会重启 Pad 应用、临时占用无线端口，以验证恢复能力。

`--capture-test` 测真实采集，`--benchmark` 只测合成画面；命令参数见 `Nextend --help`。FPS 来自实际呈现回调，不等于面板刷新率，也不是光学延迟。

[0.5.0 验证与高刷分析](docs/RELEASE-0.5.md)、[0.4.0 验证记录](docs/RELEASE-0.4.md)、[0.3.0 HDR 结果](docs/HDR-VALIDATION.md)、[早期 SDR 结果](docs/VALIDATION.md) 分别记录各版本证据，短测不能代替长期稳定性验收。

## 许可与设计

源码使用 GPL-3.0，见 [LICENSE](LICENSE) 和 [上游来源](THIRD_PARTY_NOTICES.md)。本项目不是 OpenDisplay 官方发行版，应配套使用 Nextend 两端。

可复用的[液态玻璃 skill](skills/liquid-glass-interface/SKILL.md)包含原生与网页规范及示例；[协议](docs/PROTOCOL.md)与[架构](docs/ARCHITECTURE.md)说明传输实现。
