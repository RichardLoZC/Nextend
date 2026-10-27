# 2026-10-19 已有项目审计快照

此表是读取实际源码和发布脚本后的结果，不代表已迁移全部项目。Plumivo 与 NewsHunter 正在其他聊天开发，本任务只读核对，不跨任务修改它们的正在运行代码。

| 项目 | 已有分发方式 | 清单／安装验证 | 发布 | 兼容结论 |
| --- | --- | --- | --- | --- |
| Plumivo | 配置 NAS SMB，亦支持 HTTPS；复用媒体 NAS 账号与线路 | schema 1 stable.json；大小、SHA-256、包名、构建号、版本、SDK/ABI、安装证书；清单自身没有 RSA 签名 | 上传临时包、NAS 哈希检查、锁、不可变包、原子切清单、旧清单留档 | 发布事务已接近统一基线；签名清单迁移需要先更新客户端 |
| NewsHunter | 私有 HTTPS /newshunter-api/；设备 bearer 凭据 | RS256 签名信封、内置公钥、哈希和大小；Android 包名/版本/证书，Mac Bundle ID/version/codesign | NAS 加锁，先不可变 APK/ZIP 后原子 manifest；服务器 commit_update.py 只检查签名字段存在，未做加密验签 | 客户端已有发布者验签；服务器应补公钥验签、旧清单留档；保留私有鉴权与旧 schema |
| Nextend（本次接入） | 独立 HTTPS 安装包目录，公开只读；配对和投屏数据不进入服务器 | RS256、内置独立更新公钥、流式大小/哈希、Android 身份与原安装证书 | 复用工具：NAS 真正验签、锁、版本守卫、不可变包、原子清单、历史留档 | Android 应用内更新；Mac 仅托管下载包 |

三个项目都不能在普通 Android 上绕过系统确认静默安装。自动发现更新与自动下载安装是不同能力。

共同的历史限制：Nextend 与 Plumivo 现有安装证书指纹相同，来自这台构建机曾用的 Android 调试证书。为保持覆盖安装，各项目已将原证书固定在各自受限签名目录；这不是新应用应采用的共享密钥方案。Nextend 当前 USB 配对依赖 run-as，所以暂保留 debuggable 构建。不要为消除这一例外而强迫用户卸载。

Nextend 标准配置：`ops/publish_release.py`，`ops/release_bundle.py`，`ops/expected-android-signer.sha256`；秘密不在公开工程。NAS 挂载路径和真正服务目录是不同命名空间，必须分别确认。

复核定位（如迁移后失效，按项目名称重新查找，勿另建副本）：

- Plumivo：`/Users/abu/Documents/Codex/2026-10-10/zai/work/qingying-native`，`ops/publish_release.py`、`AppUpdates.java`、`UpdateManifest.java`、`UpdateInstaller.java`。
- NewsHunter：`/Users/abu/Documents/Codex/2026-10-19/new-chat/work/macmini`，`scripts/publish_app_release.py`、`apps/android/.../Updates.java`、`apps/macos/Updater.swift`；NAS `/volume1/docker/newshunter-private/commit_update.py`。
- Nextend：`/Users/abu/Library/CloudStorage/MountainDuck-MyCloud·NAS云盘/Nextend`。

尚未执行的旧项目迁移不应被写成已修复。后续用户在这些项目要求统一更新时，先读对应当前代码与该项目约定，再增量迁移；不需要把媒体、新闻、认证和业务架构都改成一样。
