# Nextend 0.8.1：连接恢复修复

发布日期：2026-10-25（Asia/Shanghai）。Mac build 13，Android build 15。按 `nas-app-updates/1` 发布，沿用原 Bundle ID、Android 安装证书、清单公钥和更新地址。

## 已修复的六项问题

| 问题 | 新行为 |
| --- | --- |
| Mac 清理超时后永久要求重启 | 超时后保留待释放资源，持续检查 helper 退出、对应虚拟屏移除和 HDR 停止确认；条件全部满足才恢复连接入口。等待期间可点“重新检查”，不会跳过资源保护。 |
| USB 启动取消仍跑完配对重试 | 取消标记传到同步 ADB 命令，停止配对轮询；同时排空 stdout/stderr，超时或取消时终止子进程，必要时强制结束。已分配 forward 仍回滚。 |
| Pad 异常时先发送错误，卡住关闭 | 网络错误直接关闭；每次写入有独立截止时间。解码/HDR 错误异步报告，最迟 250 ms 关闭，接收工作线程最多等待 300 ms。 |
| 无线发现/解析失败不重试 | 有上限的退避间隔持续重试，串行解析，处理缺失回调，忽略旧轮次回调；手动重试保留可用地址，网络变化清缓存。 |
| Mac 请求监听失败无恢复 | 监听失败可见，自动退避重试；端口恢复后重新监听；退出会取消重试。 |
| Pad 丢弃断开原因 | 保留最近的会话错误，区分各传输监听错误；监听恢复仅清对应提示，手动重试或成功连接清旧会话错误。 |

## 验证结果

| 检查 | 结果与证据 |
| --- | --- |
| Mac 编译、签名及原有自测 | 通过；`work/reconnect-fix/mac-build-final.log`、`mac-signature.log`、`mac-self-test.log`。 |
| Mac 恢复回归 | 通过：迟到的资源释放、所有资源共同确认、USB 取消、forward 回滚、大量 stderr、拒绝 SIGTERM 的子进程、端口冲突解除、关闭后不复活；`mac-recovery-test.log`。 |
| 本机真实虚拟屏生命周期 | 4 场景通过：stdin EOF、SIGTERM、启动中 EOF、父进程 SIGKILL；在线显示器列表从 `[1]` 恢复为 `[1]`；`outputs/benchmarks/nextend-display-lifecycle.json`。 |
| Android 构建与单测 | 47 项通过，0 失败，0 错误；含真实回环 Socket 握手、写入阻塞关闭、错误报告与 HDR 回退顺序、状态提示保留；`outputs/test-results/android/`、`work/reconnect-fix/android-tests.json`。 |
| 无线发现隔离回归 | 用生产 `PadConnectRequest.kt` 加可控 Android NSD/Looper 替身验证重试、缓存、串行解析、服务消失、旧回调、回调超时；`work/reconnect-fix/discovery-passed.log`。 |
| 发布工具 | 17 项通过，包含签名/哈希、降级、同构建号冲突、并发、失败、快照提交、ZIP 路径及符号链接、执行权限恢复；`work/reconnect-fix/publisher-test.log`。 |
| 独立代码复核 | Mac 生命周期、Android 恢复与状态、安装包安全三个方向复核；发现的提示和缓存回归均修正，无剩余发布阻塞项。 |
| NAS 发布与公网回读 | Mac 13 / Android 15 已发布。使用旧 Pad 的 `Nextend/0.8.0` User-Agent 下载；清单 RS256 有效、`max-age=0`，两包大小及 SHA-256 匹配。下载后的 Mac ZIP 解压验签与恢复自测再次通过；`work/reconnect-fix/public-downloads/verification.json`。 |

## 分发和构建环境修复

旧下载地址曾返回 HTTP 403。Apache 日志指向容器内 `uploads/apps` 父目录无法遍历，以及 Nextend 公共目录/文件缺少读取权限。本次仅恢复父目录的遍历权限和 Nextend 公共分发文件的读取权限；未公开私有发布状态、源码归档或密钥。对外地址已回读为 HTTP 200。

Mountain Duck 会添加 `.duckversions` 并把执行权限变为 0600。Android 编译和源码归档已排除历史目录。源码仍位于当前项目；编译器临时产物使用系统本地临时目录，最终 APK、测试报告、Mac APP/ZIP 和源码包回存项目。Mac 仅对生成的应用副本在本地临时目录签名、验签与执行测试，发布 ZIP 保留正确执行位且不带历史目录、FinderInfo 或资源叉。签名规则未放宽。

## 未验证及安装状态

用户本轮暂不方便连接真实 Pad。因此未做 Xiaomi Pad 的 USB/无线连续重连、长时间休眠恢复和真实 OTA 安装验收，未将隔离测试写成真机结果。Mac 的虚拟屏生命周期是本机实测，但不等于真实 Pad 的完整连接复现。

本轮发布安装包，没有覆盖正在运行的已安装 Mac App，也没有操作其他项目正在运行的 Android 模拟器。Mac 仍通过下载 ZIP 更新，Pad 可从“应用更新”获取新版；macOS 原有隐私授权可能需要用户按系统提示重新确认。系统真正不释放资源时继续阻止新会话，避免重复虚拟屏。

## 固定下载入口

- 下载页：https://gzlinkbio.icu/wp-content/uploads/apps/nextend/
- Pad：https://gzlinkbio.icu/wp-content/uploads/apps/nextend/updates/Nextend-Android-15.apk
- Mac：https://gzlinkbio.icu/wp-content/uploads/apps/nextend/updates/Nextend-Mac-13.zip
- 活动清单：https://gzlinkbio.icu/wp-content/uploads/apps/nextend/updates/manifest.json

源码归档保存在 NAS 私有发布目录，具体文件名、哈希与当前发布状态见 `outputs/CURRENT.json`。公网验收来自当前 Mac 网络，未声称完成蜂窝网络测试。
