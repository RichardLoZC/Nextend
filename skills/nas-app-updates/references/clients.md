# 平台接入

## Android

使用当前系统支持的安装 API。新实现优先 PackageInstaller 会话；小型既有应用可以使用受限 ContentProvider 与系统 APK 安装器。二者都必须申请 REQUEST_INSTALL_PACKAGES，检查 canRequestPackageInstalls，并尊重系统用户确认。

校验顺序：验清单发布公钥 → 应用/通道/平台/SDK/构建号/路径与大小上限 → 流式下载到私有临时文件 → 实际大小与 SHA-256 → APK 包名、versionCode、versionName、minSdk 和已安装签名证书集合。使用 SigningInfo；仅比较签名数组的非空集合，不能允许任意一个签名匹配便通过。钥匙轮换另使用明确验证的签名 lineage，不自行放宽匹配。

拒绝超长 Content-Length 以及实际超过上限的数据；Content-Length 缺省仍按实际字节计数。限制网络连接、读取和整轮耗时；支持取消并关闭连接。缓存命中也再次校验，未验证半包不续传。使用不同构建号/哈希的不可变缓存文件，避免安装器读取时被另一次下载替换。

自定义 Provider 必须非 exported，仅授予所选 APK 的临时读取权限，拒绝写入和任意路径；不要暴露整个 files/cache。调用系统安装器前再次校验。用户未允许安装时，引导到该应用的安装来源设置；返回后由用户再次确认，不自动循环弹窗。

生命周期：界面销毁或任务取消后，旧回调不能弹出安装窗口；新一次操作不能被旧任务 finally 清理。下载期间检查业务状态，开始投屏/播放时暂停更新，不结束业务服务。没有必要就不新增长驻更新服务。

首次引入自更新能力，旧客户端仍需一次手动或已授权 ADB 覆盖安装。只拿到了新 APK 不能声称旧设备已获得更新能力。真实升级验收包括安装前后包名、签名、构建号、配对和偏好；安装取消也要保留旧 App。

官方 API（实现时重新核对）：
- [PackageInstaller](https://developer.android.com/reference/android/content/pm/PackageInstaller)
- [SigningInfo](https://developer.android.com/reference/android/content/pm/SigningInfo)
- [安全共享文件](https://developer.android.com/training/secure-file-sharing)

## macOS

完整 `.app` ZIP 先验签名清单与包哈希，再校验 Bundle ID、版本、架构、系统下限和 codesign。Developer ID / 公证状态按实际签名报告；ad hoc 代码签名本身不证明发布者身份，必须依靠独立的受信更新清单公钥。不要用仅 Bundle ID 匹配的签名要求绕过 TCC。

解包器要拒绝路径穿越、符号链接逃逸和异常展开体积；清单中的压缩包大小不能代替解压后的边界。验证完成后再进入安装阶段。安装目录不可写时提供明确路径指引，不自动请求全盘管理员权限。

替换前检查目标是当前应用本身且无符号链接逃逸，在同一卷暂存。旧应用退出后保留可恢复副本、原子替换、启动新版。记录安装结果；`open` 命令成功只说明启动请求被接受，不等于业务健康。失败恢复旧版并报告原因，不能删除唯一旧版后再试。

涉及屏幕录制、辅助功能等系统权限时，重新签名可能要求用户再次授权。不能保证无感更新；保留系统提示，绝不放宽代码身份或直接改 TCC 数据库。

只托管了 Mac ZIP 而未接入更新器时，交付必须写“Mac 下载包”，不能宣称 Mac 已自更新。
