# Nextend 本地开发目录

2026-10-19 起，Nextend 在以下目录继续开发：

```text
/Users/abu/Library/CloudStorage/MountainDuck-MyCloud·NAS云盘/Nextend
```

以上是 2026-10-19 迁入时的路径。2026-10-26 起，当前访问路径为 `/Users/abu/Library/CloudStorage/MountainDuck-MyCloud·新域名验证/Nextend`，仍是 NAS 上的同一工程（`/home/ORL/MyCloud/Nextend`）。后续任务先核对当前挂载，开发约定见根目录的 `AGENTS.md`。

## 迁移内容

保留 Mac 与 Android 源码、构建脚本、测试、文档、品牌资源、项目内技能、完整 `.git` 历史，以及 `outputs/` 中的当前安装包、校验文件、设计资料和性能记录。`work/` 保留最终验收记录、清理记录和已压缩的历史资料。

迁入基线为 `main` 分支的 `49a502000b2cc55d90be3c57bf75e3638bc53f91`，版本为 0.6.0，构建号为 9。原有 Git 远端配置保留。

跳过了可再生成的 Python 缓存和已停用的 `work/PadMirror.app`。没有迁移或修改系统中已安装的 Nextend 应用、配对信息和权限设置。

## 原目录

```text
/Users/abu/Documents/Codex/2026-10-16/codex-threads-01a1437a-b0ad-7541-ac3c
```

原目录保留迁移提示和指向新目录的兼容链接，历史文件链接仍可访问。原目录不再保存独立的项目文件副本。Git 的本地 `core.worktree` 设置固定为新目录，使从旧路径执行的 Git 命令也使用新目录。

## 核验与常用入口

迁移时逐文件核对 SHA-256、文件大小与权限，并核对 Git 提交、仓库完整性以及 0.6.0 安装包校验值。详细清单见 `work/migration-2026-10-19.json`。

- 使用与构建说明：`README.zh-CN.md`、`README.md`。
- 当前发布文件：`outputs/CURRENT.json`。
- 0.6.0 验收：`docs/RELEASE-0.6.md`。
- Mac 构建：`bash scripts/build-macos.sh`。
- Android 构建：`bash scripts/build-android.sh`。

本次迁移没有重建应用，也没有运行设备集成测试。
