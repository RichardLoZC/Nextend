# Nextend

**把 Android 平板变成 Mac 的拓展屏。**

[English](README.md) · [NAS 下载](https://linkbio.gz.cn/wp-content/uploads/apps/nextend/) · [实现结构](docs/ARCHITECTURE.md)

当前版本为 **Android 0.8.2 / build 16、Mac 0.8.1 / build 13**。Android 更新源迁至 linkbio.gz.cn，Mac 安装包保持原字节。新旧域名并行保留，等待 Pad 实机升级验收；见 [迁移验证](docs/RELEASE-0.8.2.md)。原生 Mac / Android 应用支持真正的 HiDPI 拓展桌面、USB / 配对加密无线、HEVC / H.264 硬件编解码和 HLG 10-bit HDR。

## 这版改动

- Pad 等待页“应用更新”支持手动检查；默认每 6 小时在空闲前台检查一次，可关闭。用户选择下载，签名与安装包校验通过后交给 Android 系统确认安装；开始投屏时暂停更新。
- Mac 和 Pad 使用暗色背景图标，保留原有玻璃标志。安装包由 NAS 托管；Mac 当前提供下载包，尚未内置更新器。
- 新增统一 [NAS 发布与自更新 skill](skills/nas-app-updates/SKILL.md)，沿用固定签名、不可变安装包、NAS 验签与原子发布流程。
- Pad 切换到其他应用时保留连接与 Mac 虚拟屏；画面不可见时暂停编解码，返回后恢复画面。
- Mac“Pad 设置 → 刘海与菜单栏”提供两条竖线校准刘海边界。刘海右侧的「«」展开被收起的应用图标，桌面保持满屏；原有四边留白移到“画面留白”。
- 快速切回时主动恢复关键帧；排队或丢帧不会让静态桌面永久黑屏。
- Pad 等待页可主动允许后台通知，随后能从通知返回或断开；未授权仍可从 Mac 断开。

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

从 [NAS 下载页](https://linkbio.gz.cn/wp-content/uploads/apps/nextend/) 下载配套 Mac ZIP 和 Android APK，或自行构建。[GitHub Releases](https://github.com/RichardLoZC/Nextend/releases) 保留早期版本。这是开发版本：Mac 为临时签名、未公证；Android 为可调试构建，当前 USB 配对依赖 `adb run-as`。

0.7.x 及更早 Pad 版本需要先覆盖安装一次 0.8.0，之后可在等待页“应用更新”检查 NAS 新版。首次在 Android 为 Nextend 允许“安装此来源应用”，返回后点击“安装更新”。覆盖安装保留配对和设置，不要卸载旧 App。

1. Pad 开启 USB 调试、允许这台 Mac；部分小米设备需要单独允许 USB 安装。安装并打开 Nextend。切换应用可保留连接，返回 Nextend 后继续显示。
2. 将 `Nextend.app` 放到 `/Applications` 后打开，点击“屏幕录制权限”，在系统设置允许 Nextend，按提示退出重开。
3. 在 Mac 选择“USB 有线”并点击“连接”，Pad 无需选择模式。用“排列显示器”调整位置，然后把窗口拖到新桌面。
4. 完成 USB 配对后，断开并在 Mac 选“加密无线”。Mac 会记住 USB 握手中返回的 Pad 无线地址，也可手动输入 Pad 的地址；选择实际网卡，默认 `en0`。换网后 Pad 自动更新监听，Mac 可通过 USB 重连刷新地址或手动输入。新版优先由 Pad 主动建立无线视频通道，无需 Mac 反向拨入 Pad。VPN 若阻止所有局域网访问仍可能影响无线；USB 不经过这条路由。已连接时先断开再切换。
5. HDR 需先断开，在 Mac 打开 HDR 再连接。“HDR · HLG 10-bit”表示输出格式已确认；不可用时自动回退 SDR 并给出原因。

Mac 右上角按钮切换中英文，并同步到 Pad。“Pad 设置 → 刘海与菜单栏”可打开校准线，看着 Pad 拖动预览中的两条红线，或调整左右边界、深度滑块。开启“图标折叠”后，刘海右侧的「«」在刘海下方展开应用图标，点选后打开该应用的原生菜单。此功能需要 Nextend 的辅助功能权限；校准线无需该权限。系统录屏、网络、电池等指示保留原位。参数自动保存，关闭设置窗口会收起校准线。物理遮挡无法通过系统截图自动测量，需要人工对齐。

“画面留白”保留整幅画面四边 0–20% 的边距设置；开启图标折叠或校准线时自动暂停留白，确保校准与满屏画面一致。FPS 标签可调整显示、字体、字号、颜色与位置。Pad 没有投屏菜单。“重新配对”位于 Mac 状态栏菜单中。

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

关闭 Mac 窗口保持连接，并隐藏 Dock 中的运行图标；从状态栏选择“打开 Nextend”后恢复窗口和 Dock 图标。最小化仍保留 Dock 图标。“断开连接”停止会话；“退出 Nextend”停止并退出，虚拟屏窗口由 macOS 收回。Pad 切换应用保留当前会话；不可见时停止画面解码，并让新版 Mac 暂停编码，返回后重建输出并恢复。Mac 休眠、网络断开、强制停止或划掉 Pad 的 Nextend 任务仍会结束连接，恢复后手动重连。厂商省电策略或系统终止进程也可能断开。

## 设备与限制

实际验证设备为 M4 MacBook Air、macOS 27.0.1 与 Xiaomi Pad 7 Ultra、Android 16。运行要求 Apple Silicon、macOS 14+、Android 11+；其他组合尚未实测。

60 / 90 / 120 fps 是目标档位，不是稳定性能保证，建议先用 USB、60 fps。静态桌面可能减少出帧。HDR 采用 BT.2020 / HLG、HEVC Main10、有限范围、10-bit 4:2:0；不支持 PQ / HDR10、Dolby Vision，尚未测量物理屏幕亮度与色准。没有音频、通用键盘回传和自动重连；Bonjour 仅发现 Mac，不能替代配对认证。

虚拟屏依赖 macOS 私有 API，HDR 浮点采集使用已弃用的 CGDisplayStream，系统升级后需复验。原包标识和配对存储保留 PadBridge 名称，确保升级沿用配对。

若新版 Mac 显示“开关已开但无权限”，在系统屏幕录制设置中移除旧 Nextend，重新加入当前应用并退出重开。临时签名绑定每次构建的代码哈希，不能靠放宽签名要求保留权限。无线另需“本地网络”权限；若更新后开关已开但无线访问失败，可将已有的 Nextend 本地网络权限关闭再开启，然后重试。

## 构建与验证

需要含 macOS 26+ SDK 的 Command Line Tools、JDK 17、Android SDK 36 和 ADB；无需完整 Xcode。macOS 26 之前使用材质回退。

```sh
bash scripts/build-macos.sh
bash scripts/build-android.sh
bash scripts/install-usb.sh
python3 ops/publish_release.py --notes-file ops/release-notes.txt
```

将 `outputs/Nextend-0.8.1-macOS-arm64.zip` 解压到本机临时目录。退出已安装的旧 App，保留旧版备份，再用 Finder 将解压后的 `Nextend.app` 替换到 `/Applications/`；不要直接解压合并到旧 `.app`。从应用程序目录打开新版。

NAS 挂载可能改写执行权限并附带历史目录；请通过已验证的 ZIP 安装，不直接复制挂载中的 `.app`。编译和测试使用本机临时产物，源码与最终包仍在当前项目。

覆盖安装前先退出旧应用。请从“应用程序”目录运行；直接放在“文稿”内运行时，VideoToolbox 可能等待受保护目录的访问许可。

可设置 `JAVA_HOME`、`ANDROID_HOME`、`ADB`；Android 有缓存时可传 `--offline`。依赖固定为 Gradle 8.13、AGP 8.11.1、Kotlin 2.2.0。

```sh
bash scripts/test.sh --offline
python3 scripts/test-macos.py --display-lifecycle
python3 tests/hdr_fallback.py
python3 tests/device_protocol.py
python3 tests/touch_protocol.py
python3 tests/background_lifecycle.py
python3 tests/background_video.py --report work/test-results/background-video.json
python3 tests/connect_request.py
python3 tests/transport_switch.py
python3 tests/listener_recovery.py
```

显示与传输测试须串行。生命周期测试临时创建虚拟屏；HDR 回退测试需要本机已有配对；协议测试需要 Pad 打开并处于等待页及 Python `cryptography`；双传输和监听恢复测试还需要可达的同一 Wi-Fi 网络。监听恢复测试会重启 Pad 应用、临时占用无线端口，以验证恢复能力。

`connect_request.py` 另需 Mac 图形应用保持运行且未连接，并完成过 USB 配对。它只测试无效请求，不发起投屏、不发送系统输入。

`--capture-test` 测真实采集，`--benchmark` 只测合成画面；命令参数见 `Nextend --help`。FPS 来自实际呈现回调，不等于面板刷新率，也不是光学延迟。

[0.8.1 连接恢复验证](docs/RELEASE-0.8.1.md)、[0.8.0 NAS 自更新验证](docs/RELEASE-0.8.0.md)、[0.7.1 刘海折叠说明](docs/RELEASE-0.7.1.md)、[0.7.0 后台与安全区验证](docs/RELEASE-0.7.md)、[0.6.0 触控与连接验证](docs/RELEASE-0.6.md)、[0.5.0 验证与高刷分析](docs/RELEASE-0.5.md)、[0.4.0 验证记录](docs/RELEASE-0.4.md)、[0.3.0 HDR 结果](docs/HDR-VALIDATION.md)、[早期 SDR 结果](docs/VALIDATION.md) 分别记录各版本证据，短测不能代替长期稳定性验收。

## 许可与设计

源码使用 GPL-3.0，见 [LICENSE](LICENSE) 和 [上游来源](THIRD_PARTY_NOTICES.md)。本项目不是 OpenDisplay 官方发行版，应配套使用 Nextend 两端。

可复用的[液态玻璃 skill](skills/liquid-glass-interface/SKILL.md)包含原生与网页规范及示例；[协议](docs/PROTOCOL.md)与[架构](docs/ARCHITECTURE.md)说明传输实现。

后续发布使用 [NAS 更新说明](docs/NAS-UPDATES.md) 和 [nas-app-updates skill](skills/nas-app-updates/SKILL.md)。
