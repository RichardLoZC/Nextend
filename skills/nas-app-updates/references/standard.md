# nas-app-updates/1 发布契约

## 清单与目录

新项目采用 NewsHunter 已使用的签名信封形式，增加明确的 channel。信封为 JSON：

```json
{"algorithm":"RS256","payload":"BASE64_UTF8_JSON","signature":"BASE64_RSA_SHA256_SIGNATURE"}
```

签名输入是 payload 解码后的**原始 UTF-8 字节**，不是客户端重新序列化的 JSON。使用 RSA 至少 2048 位（新钥匙建议 3072），PKCS#1 v1.5 + SHA-256；算法字段严格为 RS256，不接受降级。公钥为 APK 内的 X.509 SubjectPublicKeyInfo DER；服务器和构建机可使用 PEM。

payload 示例：

```json
{
  "schema": 1,
  "application": "com.example.app",
  "channel": "stable",
  "published_at": 1792420000,
  "notes": "本次变化",
  "platforms": {
    "android": {
      "build": 12,
      "version": "1.2.0",
      "path": "updates/Example-Android-12.apk",
      "size": 123456,
      "sha256": "64位小写十六进制",
      "minSdk": 30,
      "packageName": "com.example.app",
      "signerSha256": "已安装证书的公开指纹"
    }
  }
}
```

application 为产品更新身份；各平台保留自己既有包名。Android 与 macOS 的构建号可以独立递增。不能把产品版本字符串当整数版本比较。路径只能是更新根目录内预期的不可变文件名；不接受 URL、绝对路径、`..`、反斜杠、查询串或片段。

清单上限 64 KiB，更新说明 4000 字符。安装包上限按应用实际体积设定并同时写入客户端和发布器，不能为了兼容而取消限制。通用工具上限 200 MiB；Nextend 为 64 MiB，NewsHunter 旧客户端为 12 MiB。

目录角色：

- 私有工程／源码归档：与公开下载目录分离，采用明确文件白名单。NAS 不保存安装私钥和更新签名私钥。
- 私有暂存与发布状态：上传临时文件、锁、公钥、历史清单；不能暴露为 HTTP 静态目录。
- 公开或鉴权下载根：仅安装包、当前签名清单、必要下载页面。关闭目录索引与脚本执行，不挂载完整源码或私有目录。
- 已安装客户端：内置更新公钥、更新地址；保留数据。秘密通过系统凭据存储，不写日志。

## 通用工具输入

`prepare` 的 spec 使用以上 payload 的 application/channel/notes/platforms；不提供 schema、size、sha256、published_at，它们由工具生成。每个平台加 `file` 指向已验证的本地安装包；其余平台字段原样进入签名清单。包名、构建号、版本、SDK/架构和签名必须先用 aapt/apksigner 或 Info.plist/codesign 从真实包提取验证。

`prepare` 已存在的输出目录只能重用相同包与元数据。未发布的实验包另用输出目录；已对用户发布的构建号永不复用。

```sh
python3 release_bundle.py commit \
  --bundle /private/staging/UUID \
  --root /download-root/app \
  --state /private/app-publish \
  --public-key /private/app-publish/update-public-key.pem \
  --application com.example.app
```

`commit` 在 NAS 执行，使用 Python 3.9+、OpenSSL 和 POSIX 文件锁。公共 root 和私有 state 必须是预先核对的独立目录。通过已信任的 SSH 主机身份上传；禁止关闭主机校验。首次建立 NAS 公钥来自当前客户端内置公钥，已存在不同公钥必须停止，另作密钥轮换迁移。

锁覆盖读取旧清单、比较版本、发布包、替换清单全过程。旧清单按内容哈希存档。跨文件系统上传时先复制到目标所在目录的临时文件、fsync，再 rename；不要依赖跨卷 rename 成功。清单失败前遗留的完整包不等于已发布；重试可复用。

当前清单需要 `Cache-Control: no-store` 或 `max-age=0` 等明确的重新验证策略；不可变文件可以长缓存。不要在签名路径中依赖临时 CDN 跳转。客户端拒绝跨源／降级跳转；确需迁移地址时先发布兼容客户端，再切旧源。

## 旧协议兼容

已发客户端只认识旧 schema 时，保留旧入口和字段。用迁移版客户端先加入新验签和新入口，再转换发布流程；必要时一次构建生成两份清单，但两者必须指向同一已验证安装包。不能把“统一”理解为删除在用的 stable.json、替换包名或重置签名。

SMB 是私有 NAS 的兼容传输：复用现有账号和经过验证的主机路径，不能在清单中夹带凭据。无签名 SMB 清单可登记为旧例外，不应作为新项目默认。迁移它需要客户端升级，单改服务器 JSON 不会增加客户端验签能力。

回退业务代码：保留当前数据格式兼容性，用更高构建号重新构建签名发布。恢复旧活动清单只对尚未升级设备隐藏问题版本，不能当作已升级设备的降级机制。
