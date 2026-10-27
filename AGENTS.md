# Nextend 开发约定

## 工作目录

Nextend 的固定开发目录是：

```text
/Users/abu/Library/CloudStorage/MountainDuck-MyCloud·新域名验证/Nextend
```

2026-10-26 起使用“新域名验证”挂载；此前的“NAS云盘”“NAS恢复连接”指向同一 NAS 工程。NAS 上的原项目路径为 `/home/ORL/MyCloud/Nextend`，以上是当前 Mac 的访问路径。

后续任务先进入此目录。源码修改、构建、测试、文档和交付文件均在此目录及其子目录内完成。不要在旧聊天的临时目录或其他位置另建 Nextend 项目副本。Mountain Duck 会改动构建产物的权限和历史目录，因此构建脚本可使用系统本地临时目录存放编译产物、签名及测试副本；源码仍在此项目，最终安装包与报告回存 `outputs/`。

## 项目与验证

- `macos/`：Mac 端 Swift 源码；`android/`：Pad 端 Kotlin 源码。
- `assets/`、`docs/`、`skills/`：品牌资源、项目文档和项目内技能。
- `scripts/`、`tests/`：构建脚本和测试；`outputs/`：安装包和报告；`work/`：本地工作文件。
- 构建入口：`bash scripts/build-macos.sh`、`bash scripts/build-android.sh`。
- 常规验证入口：`bash scripts/test.sh --offline`；Android 缓存不足时按 README 使用联网构建。
- 设备集成测试需要 Pad 与相应网络条件，并且必须串行执行。先阅读 `README.zh-CN.md` 的“构建与验证”，避免中断正在使用的拓展屏。
- 唯一正式安装路径为 `/Applications/Nextend.app`；不要同时在 `~/Applications` 安装第二份。项目构建与覆盖安装是两个步骤；按当前任务要求执行。旧版优先保存为 ZIP；需保留 `.app` 的测试/回滚副本放入隐藏的 `.noindex` 目录。临时测试结束后注销对应 Launch Services 注册，避免应用列表累积副本。清理和验收须同时匹配 `Nextend*.app` 以及 `dev.padbridge.*` 包标识，包含更新测试与刘海测试程序；不能只检查正式 App 的包标识。

应用副本清理必须在系统 Apps 启动器中实际搜索验收；`mdfind` 和 Launch Services 只剩一条，不代表启动器已刷新。若仍有问号图标，先确认窗口所属进程，再针对该界面刷新并复核，不能仅凭索引结果宣布完成。

## NAS 发布与更新

- 后续发布或修改自更新时，先使用 `skills/nas-app-updates/SKILL.md`，按 `docs/NAS-UPDATES.md` 的固定入口执行，不另造一套发布流程。
- 当前版本、构建号和安装状态以 `outputs/CURRENT.json` 及对应版本记录为准。构建号一经发布不得复用。
- 安装与清单签名私钥只保留在本机构建机受限目录，不进入项目、源码包或 NAS；原签名缺失时停止，不能生成新签名覆盖。
- 公共安装包、私有发布状态和工程归档分开。发布到 NAS 后必须从客户端 HTTPS 地址回读校验。

## 迁移记录

2026-10-19 从旧聊天临时目录迁入，保留 Git 历史和 0.6.0 发布文件。目录说明见 `docs/WORKSPACE.md`，逐文件校验记录见 `work/migration-2026-10-19.json`。
