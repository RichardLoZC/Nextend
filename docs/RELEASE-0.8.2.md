# Nextend Android 0.8.2 · 域名迁移

2026-10-26 已发布 Android 0.8.2 / build 16，更新源为 `https://linkbio.gz.cn/wp-content/uploads/apps/nextend/updates/manifest.json`。原 `gzlinkbio.icu` 下载页、清单和安装包继续提供服务，旧版可原路发现并安装迁移版本。Mac 保持 0.8.1 / build 13，ZIP 与此前线上版本完全一致。

保留原包标识、安装证书、清单公钥及配对存储。没有修改投屏协议或用户设置。发布脚本可用 `--mac-app /Applications/Nextend.app` 验证现有正式安装，避免生成第二份 Mac 应用。

验证结果：Android 离线构建与现有单元测试通过；准备和 NAS 原子发布通过。新旧域名均完整回读两端安装包，签名清单、大小、SHA-256 与发布包一致，清单缓存为 `max-age=0`。新域名下载的 Mac ZIP 通过代码签名检查及恢复自检。

| 文件 | SHA-256 |
| --- | --- |
| Android build 16 APK，2,842,240 B | `85cb92634acdf83f8371358f535ef3997a702061386ea076157e025d37ae5363` |
| Mac build 13 ZIP，2,560,205 B | `f85f750c8203f69f40f58f2879a70f376860d335e33832437e41c930b517e66e` |
| 签名清单 | `c3715d96bca5547996849d7bb0110437f732649b19afe010c58c5a2ba0307cdc` |

发布目录：`outputs/releases/android-16-mac-13`。回读证据：`work/domain-migration-20261026/public-new-16-13`、`public-old-16-13`。

Pad 未连接；真实覆盖升级、配对及投屏保留、跨网络访问仍待验收。本机网络访问公网域名不代表蜂窝网络通过。旧域名将在设备全部确认后另行停用。
