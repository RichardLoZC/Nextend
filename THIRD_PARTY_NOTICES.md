# 上游来源

Nextend 使用 GPL-3.0。完整许可证见 `LICENSE`。

- `peetzweg/opendisplay`，锁定提交 `b9eec1f232fb5ea571c87e8392379a84f47b237f`，GPL-3.0，原作者 Philip Poloczek。`macos/CGVirtualDisplayPrivate.h` 直接复用并修改注释；`macos/VirtualDisplay.swift`、`macos/VideoEncoder.swift` 根据上游虚拟显示器和 VideoToolbox / Annex-B 实现改写。私有 API 声明的历史来源包括 Khaos Tian 的 VirtualDisplayExp，保留于头文件注释。
- `josepacelli/opendisplay-android`，锁定提交 `608adea3eb7d2012aead297bcdbef96a848f2a2d`，GPL-3.0。用于核对 MediaCodec / Surface 接收路线和上游协议。Nextend Android 接收器为配套新实现，增加了 HEVC、加密协商和不同的队列确认机制。
- `lotgood/photonport`，锁定提交 `3d3a12aa00ff84ae1962723d64fcca25d2528989`，GPL-3.0。参考其 EDR 虚拟屏 `transferFunction: 1` 与 CGDisplayStream 浮点采集路线；在本机独立验证。Nextend 的扩展 sRGB → BT.2020 / HLG Metal 转换、协议与验证逻辑为本项目实现，未引入其完整客户端或依赖。
- Gradle Wrapper 脚本及 JAR 来自上述 Android 仓库；Gradle 为 Apache-2.0。Wrapper 中保留原版权头。

Nextend 使用独立的 `PDB1` 协议。它不是 OpenDisplay 官方发行版，也不与未修改的 OpenDisplay 客户端互通；应成对安装本项目的 Mac / Android 版本。

上游链接：

- https://github.com/peetzweg/opendisplay
- https://github.com/josepacelli/opendisplay-android
- https://github.com/lotgood/photonport
- https://github.com/gradle/gradle/blob/master/LICENSE
