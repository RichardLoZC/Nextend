# Nextend PDB1 协议

建议配套安装 0.5.0；旧客户端仍可协商 SDR。只支持一个活动接收会话，不接受远端键鼠或触控指令。

## 配对与连接

Android 首次启动在应用私有 `files/pairing.key` 生成 32 字节 SecureRandom 密钥。Mac 使用已授权的 USB ADB 和调试 APK 的 `run-as` 读取该密钥，保存到 `~/Library/Application Support/PadBridge/pairing.key`，文件权限 0600、目录权限 0700。密钥不写日志、不随安装包分发。重新配对会重置密钥并终止旧会话。

USB：Pad 监听 `127.0.0.1:49371`。Mac 为明确选中的一台 USB 设备建立 `adb -s SERIAL forward tcp:0 tcp:49371`，关闭时只移除自己的动态转发。

无线：Pad 在前台且 Surface 可用时，同时启动 USB 与 Wi-Fi 监听器。无线只绑定实际 Wi-Fi 接口的 IPv4 地址，不使用通配地址、蜂窝网络或 VPN 接口；换网时仅重建无线监听器，不中断活动 USB。Mac 使用原生 IPv4 socket 和可选择的物理接口（默认 `en0`），不经过 HTTP/SOCKS 代理。不进行广播、不自动从 USB 切到无线；连接方式由 Mac 选择。认证后的 `hello.wifiAddress` 将当前无线地址告知 USB 端，Mac 验证为可用 IPv4 后保存；旧客户端忽略这一可选字段。全隧道 VPN 仍可阻断局域网。

每个监听器最多处理一个候选连接；两个监听器分别完成认证后，竞争同一会话所有权。已有会话时，新认证连接收到加密 `busy` 后关闭；不能抢占或修改旧解码器。所有权在原解码器实际释放后才归还。未经认证的连接不占用解码器、不修改连接界面。

## 认证

每个数据包先发送 uint32 大端长度，再发送内容。常规包上限 16 MiB；握手先按 36、64、32 字节上限验证。Pad 对整个认证过程设置 5 秒截止时间，Mac 对等待 Pad 身份证明设置 5 秒截止时间；常规包设 8 秒总读取时限，防止滴灌字节无限延长单次读取。

1. Mac → Pad：ASCII `PDB1` + 32 字节新随机 nonce M。
2. Pad → Mac：32 字节新随机 nonce P + HMAC-SHA256(K, `PadBridge/v1/pad` || M || P)。
3. Mac → Pad：HMAC-SHA256(K, `PadBridge/v1/mac` || M || P)。

证明使用固定时间比较。认证失败立即断开。双方以 M || P 为 HKDF-SHA256 salt，K 为 IKM，分别以 `PadBridge/v1/mac-to-pad` 和 `PadBridge/v1/pad-to-mac` 为 info 派生两个 256 bit AES 密钥。

每方向从序号 0 开始。加密记录是 uint64 大端序号 || AES-GCM 密文 || 16 字节 tag。nonce 为 4 字节零 || 序号，AAD 为序号。只接受严格连续序号；每会话双方随机 nonce 改变派生密钥。采用随机共享密钥，不是人类可猜密码；不声称前向保密，也未接受独立密码学审计。

## 加密内容

第一个字节为类型：

- `1`：UTF-8 JSON 控制消息，上限 64 KiB。
- `2`：uint64 视频序号 || uint64 Mac 单调时钟纳秒 || uint8 关键帧标志 || Annex-B 视频数据。视频数据上限 4 MiB。

认证后：Pad `hello` → Mac `probe(width,height,fps)` → Pad `capabilities(codecs,colors)` → Mac `config` → Pad `ready`。能力按请求的分辨率和帧率查询硬件解码器，避免用原生 60 fps 能力代替高刷或低分辨率能力。

流配置支持以下组合，均为有限范围、4:2:0：

| color | bitDepth | codec / profile |
|---|---:|---|
| `bt709-limited-sdr` | 8 | HEVC Main 或 H.264 High |
| `bt2020-limited-hlg10` | 10 | HEVC Main10 |

`colors` 缺失时 Mac 只使用 SDR。旧 Mac 不发送 `bitDepth` 时按 8 处理；未知色彩、HDR + H.264、错误位深均拒绝。HDR 的 `ready` 必须明确回传相同 color 和 10-bit。关键帧附带 H.264 SPS/PPS 或 HEVC VPS/SPS/PPS。配置中的 codec 必须在当前 probe 的声明列表中。Mac 界面自动优先 HEVC；只有已声明支持 H.264 的 SDR 会话才可兼容回退，HDR 永远不使用 H.264。

Pad 的输出格式证据放在既有 `stats.videoFormat` 字段，含 `color`、`verified`、`rendered` 与实际 MediaFormat 字段；不增加会让旧 Mac 拒绝的新统计消息类型。HDR 初始化或输出格式不匹配发送 `hdr-error`，停止显示并关闭链路；仅协商到 HDR 的新 Mac 会收到该消息。Mac 等清理完成后以 SDR 重连一次，`--require-hdr` 禁止回退。

Mac 在编码前限制未确认帧数：默认 4；90/120 fps 且不超过 2400×1600 像素时为 6，始终不超过 Pad 解码器的 6 帧记账上限。丢弃发生在编码前，避免丢掉已编码的参考帧。VideoToolbox 的临时 frameDropped 归还对应额度并请求下一关键帧；3 秒内没有成功输出则明确结束，避免静态桌面丢首帧后永久黑屏。Pad 解码输出交给 Surface 后发送 `ack(seq,decoded,receiveToDecodeMs)` 归还额度；解码输入不足时丢弃到下一关键帧，并发送 `keyframe` 请求。`OnFrameRenderedListener` 单独产生统计，绝不控制发送额度。

收到 `ready` 后立即启动每秒 `ping`/`pong` 保活，覆盖虚拟屏和采集器的准备阶段。准备超过 30 秒会发起取消；系统采集 API 返回后完成清理。3 秒未完成的解码确认、6 秒无任何响应会终止会话并释放虚拟屏。测试时长从采集器成功启动后计时；未知消息与输入注入消息被拒绝。HDR 还要求在 8 秒内收到已验证且有呈现帧的输出格式，否则回退。

## 统计口径

- `sourceFps`：Mac 收到完整采集帧的速度；合成测试中为生成定时器的实际回调速度。
- `encoderDropped`：VideoToolbox 报告的累计丢帧数。
- `encodeFps`：Mac 编码输出速度。
- `decodeFps`：Pad 解码输出释放速度。
- `renderFps`：Android 帧呈现回调速度；回调可能延迟、批量到达或缺失，不能等同于每次物理面板扫描。
- `captureToDecodeAckP50/P95Ms`：Mac 取得采集缓冲到收到 Pad 解码输出确认的往返时间，包含传输返回路径，不包含可靠的屏幕发光测量。
- `padDecodeP50Ms`：Pad 收齐视频内容到释放解码输出的耗时。延迟分位数使用最近不超过 6000 帧的滚动样本。
- 合成画面测试不经过桌面采集；桌面采集测试单独标识。HDR 的 `hdrVerified` 需要 Main10 码流、BT.2020 / HLG 解码格式及非零呈现计数；`hdrHighlightVerified` 只用于实际 HDR 测试窗口的灰阶和高光取样，不是面板测光。

真实端到端延迟需要高速摄像验证；色准需要外部测量，截图不能证明物理屏幕色准。
