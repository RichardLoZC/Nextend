# Nextend 的 NAS 托管与更新

采用 `nas-app-updates/1`。后续任务使用项目内 [nas-app-updates skill](../skills/nas-app-updates/SKILL.md)；全局安装位置为 `~/.codex/skills/nas-app-updates`，可通过 `$nas-app-updates` 调用。两份技能保持一致，修改通用工具时同步 `ops/release_bundle.py` 和技能中的脚本副本。

## 固定入口

| 用途 | 地址或路径 |
| --- | --- |
| 下载页 | https://linkbio.gz.cn/wp-content/uploads/apps/nextend/ |
| 客户端清单 | https://linkbio.gz.cn/wp-content/uploads/apps/nextend/updates/manifest.json |
| NAS 公共目录 | `/volume1/docker/linkbio-wordpress/data/uploads/apps/nextend` |
| NAS 私有发布状态 | `/volume1/@home/ORL/.nextend-updates` |
| NAS 私有源码归档 | `/volume1/@home/ORL/.nextend-updates/source` |
| SSH 主机 | 已信任的 `dx4600` 配置 |
| 本地部署配置 | `work/releases/deploy.local.json`，不入库 |
| 安装签名 | `~/.local/share/nextend/signing/install.keystore`，仅本机 |
| 清单签名 | `~/.local/share/nextend/signing/updates.pem`，仅本机 |
| 验证公钥 | `ops/update-public-key.pem` 和 APK 内 `update-public-key.der` |

NAS 复用已有 HTTPS 服务的独立静态目录。活动清单使用 `max-age=0`；带构建号的安装包可缓存。公开目录只有下载页、图标、签名清单和安装包，禁止目录索引与脚本访问。配对密钥、用户设置、安装私钥和更新私钥不上传到此目录。

Pad 版本 0.8.0 起，默认每 6 小时在空闲前台检查更新；手动检查不受此限。首次使用需先覆盖安装此版本。安装仍需用户在系统安装器确认。Mac 当前只提供下载包。

## 每次发布

1. 保留包名、原安装证书、配对和设置。递增修改平台的整数构建号；已发布构建号不能重新使用。
2. 更新版本、发布说明并构建。图标变化时先运行 `./scripts/build-icons.sh`；常规验证运行 `./scripts/test.sh --offline`。设备集成测试串行，不能中断正在使用的拓展屏。
3. 准备不可变发布目录，核对包内真实身份与签名：

```sh
python3 ops/publish_release.py --notes-file ops/release-notes.txt
```

4. 已获 NAS 发布授权后，使用同一份包发布：

```sh
python3 ops/publish_release.py --notes-file ops/release-notes.txt --publish
```

部署配置包含 `sshHost`、`remoteRoot`、`remoteState`，对应上表；不保存密码。脚本校验已信任 SSH 主机，上传到私有 UUID 暂存目录，NAS 验清单签名和所有文件，再在锁内比较版本、保存旧清单、放入不可变包，最后原子替换活动清单。失败后旧清单仍有效；相同字节可重试。首次保存服务器公钥也在锁内原子完成，已有不同公钥必须停止。

5. 从客户端 HTTPS 地址回读清单和两端安装包，重新验签、检查大小及 SHA-256。用应用真实 User-Agent 测试；只检查 NAS 文件或挂载目录不能代表下载已生效。首次上线需走完整的客户端安装流程。
6. 更新下载页指向当前构建，更新 `outputs/CURRENT.json` 与版本记录，生成不含秘密的源码归档并复制到 NAS 私有归档目录。

构建号回退会被服务器和客户端拒绝。需要回退业务代码时，发布更高构建号，保持用户数据兼容。

## 已有项目的兼容边界

[三项目审计](../skills/nas-app-updates/references/legacy-audit.md) 记录了实际差异。Plumivo 尚未验证清单签名，NewsHunter 服务器提交脚本尚需补公钥验签和旧清单留档。本任务未迁移它们的运行代码，也没有替换它们的 URL、认证或旧 schema。

Nextend 与 Plumivo 的现有 Android 安装证书来自历史调试证书。当前固定使用原证书，确保覆盖安装；新应用应使用独立安装密钥。Nextend USB 配对仍依赖 `run-as`，所以保留可调试构建。Mac 为临时签名，未公证，更新后可能需要重新确认原屏幕录制和辅助功能权限。

## File Provider 工作区（0.8.1 起）

Mountain Duck 的 `.duckversions` 不进入编译、安装包或源码归档。源码和最终交付仍在项目内；Android 的中间编译产物、Mac 已生成应用的签名/执行副本使用系统临时目录，结束后清理。此处不另建源码工程副本。

Mac 挂载中的 `.app` 可能被文件提供器改变权限或加入历史目录，不能直接作为安装包复制。`ops/mac_bundle.py` 提取生成应用的有效文件、恢复主程序执行位，`publish_release.py` 验签后生成无历史目录和扩展属性的 ZIP。对外 ZIP 是安装与验收对象。原签名身份和 TCC 规则保持不变。

发布后使用固定回读入口，参数换成实际构建号：

```sh
python3 ops/verify_public_release.py --bundle outputs/releases/android-16-mac-13 --output work/releases/public-16-13
```

如果出现 HTTP 403，检查 Web 服务容器实际所见的目录遍历/读取权限与 Apache 日志；NAS 主机的权限显示不一定等于容器所见。只修复已授权公共目录的必要读取权限，不修改私有状态或签名目录。
