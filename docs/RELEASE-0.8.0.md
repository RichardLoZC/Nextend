# 0.8.0：暗色图标与 NAS 自更新

发布于 2026-10-19。Android 为 0.8.0（build 14），macOS arm64 为 0.8.0（build 12）。下载入口：https://gzlinkbio.icu/wp-content/uploads/apps/nextend/ 。本次没有创建 GitHub Release。

## 变化

两端图标使用暗色背景，保留原折叠玻璃标志；生成记录见 `assets/brand/GENERATION.md`。Pad 等待页新增“应用更新”，默认每 6 小时在前台空闲时检查 NAS，可关闭自动检查，也可随时手动检查。下载需要用户发起，显示进度和取消。开始投屏、离开界面时暂停更新并关闭更新弹窗。

更新器验证内置公钥对应的 RS256 清单、应用和通道、递增构建号、SDK、文件路径、实际大小与 SHA-256，再核对 APK 包名、版本和原安装证书。缓存与安装前再次校验。APK 只通过受限只读 Provider 交给 Android 系统安装器；不静默安装。网络连接、读取和整轮操作均设有时间限制。

NAS 在锁内重新验签并校验文件，先发布不可变安装包，最后原子替换清单；保留历史清单，拒绝降级和同构建号不同包。Mac 本次只提供托管下载包，没有新增 Mac 更新器。

## 已执行的验证

| 验证 | 结果 |
| --- | --- |
| Mac 构建与原有 self-test | 通过；`work/releases/build-test.log` |
| Android 最终 build 14 构建与单测 | 40 项通过，0 失败；`work/releases/android-build-14.log` 与 Gradle XML |
| 发布工具测试 | 13 项通过，覆盖真实 RSA 验签、哈希破坏、路径与符号链接、降级、同构建号冲突、幂等、并发、磁盘失败、公钥首次固定与已验清单快照发布；`work/releases/publisher-final-tests.log` |
| HTTPS 回读 | 清单 HTTP 200、RS256 有效、`Cache-Control: max-age=0`；两端包大小和 SHA-256 与签名清单一致；`work/releases/public-verification.json` |
| 应用内完整升级 | 专用 Android 15 平板模拟器由 build 12 经真实 NAS 下载、安装来源授权、系统确认升级到 build 14；系统显示 App installed，重开正常，更新状态保留；`work/releases/ota-emulator.json` |
| Xiaomi Pad 7 Ultra 初始接入 | Android 16，原 0.7.0（build 10）经 ADB 覆盖到 build 14；配对文件和原设置 SHA-256 前后一致；`work/releases/pad-bootstrap.json` |
| Pad 在线检查与授权 | 新版已从真实 HTTPS 清单记录最高 build 14；按本次用户授权开启 REQUEST_INSTALL_PACKAGES，系统 appops 读取为 allow |
| Mac 安装及权限 | 安装到 `~/Applications/Nextend.app`，Bundle version 与 codesign 校验通过；恢复原屏幕录制和辅助功能授权，重启后应用识别授权；`work/releases/mac-install.json`、`work/releases/mac-permissions.json` |
| 升级后 USB 投屏 | 2026-10-20，GUI 连接 3200×2136、60 fps 目标、HEVC SDR 成功；Pad 实际显示拓展桌面并回报解码与呈现数据。静态桌面的 1–2 fps 不代表动态帧率测试 |
| Skill | 项目版与 `~/.codex/skills/nas-app-updates` 同步，结构校验通过；内含相同的已测试发布工具 |

此次线上验收来自当前 Mac 网络和设备网络，未进行蜂窝网络测试。模拟器的更新安装验证不等同于 Xiaomi 安装器的完整在线升级；真实 Pad 本次执行的是引入自更新能力所需的首次覆盖安装。既有投屏后台恢复与刘海功能的验证记录见 0.7.x 文档。

模拟器升级后再次手动检查，界面显示“已是最新版本：0.8.0”。Mac 临时签名变化导致原隐私权限条目失效；通过系统设置重新添加当前安装文件，并在用户完成 Touch ID 后恢复，未修改其他应用授权。

收尾另观察到一次“控制连接超时”，手动重连后桌面、呈现数据和「«」折叠入口恢复，后续复查仍保持连接。同期 Pad 日志出现显示 Surface 分离，但尚未确认超时原因，列为待复查项；本次不据此声称长时间稳定性通过，也没有放宽连接超时阈值。

## 发布文件

| 文件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `updates/Nextend-Android-14.apk` | 2820548 | `d7355beebf25fc3d4f5e810f8404b7a6c3dfdf36423aabfddfc0ad1562f1a373` |
| `updates/Nextend-Mac-12.zip` | 2556881 | `1052133a1b919ffdfdddcbc289515b4bc675889301a7349323d4064404910998` |
| `updates/manifest.json` | 1733 | `03bf204498394253ca8651c77b073d742bcb7572e913fde20c5fd355855d7bbd` |

安装证书沿用原指纹 `0cfc9abe6e9c4dc5ae625d0c81ee11de70f8fa97b23eeb7b5806cf390d2631d1`，固定在本机构建机目录。更新清单使用独立 RSA 3072 位密钥，私钥不进入项目或 NAS。

## 统一标准的范围

已建立 [可复用 skill](../skills/nas-app-updates/SKILL.md) 和 [Nextend 发布入口](NAS-UPDATES.md)。Plumivo、NewsHunter 的审计结果见 [兼容记录](../skills/nas-app-updates/references/legacy-audit.md)：前者尚缺清单签名验证，后者 NAS 提交过程尚缺加密验签与历史清单留档。本次只读核对它们，未迁移其现有客户端或运行服务，不能称为三个项目已经完全一致。
