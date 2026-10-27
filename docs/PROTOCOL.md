# Nextend PDB1 协议

触屏需配套安装 0.6.0；旧客户端仍可协商视频。只支持一个活动接收会话。触屏扩展必须单独协商，并由 Mac 本地开关授权。

## 配对与连接

Android 首次启动在应用私有 `files/pairing.key` 生成 32 字节 SecureRandom 密钥。Mac 使用已授权的 USB ADB 和调试 APK 的 `run-as` 读取该密钥，保存到 `~/Library/Application Support/PadBridge/pairing.key`，文件权限 0600、目录权限 0700。密钥不写日志、不随安装包分发。重新配对会重置密钥并终止旧会话。

USB：Pad 监听 `127.0.0.1:49371`。Mac 为明确选中的一台 USB 设备建立 `adb -s SERIAL forward tcp:0 tcp:49371`，关闭时只移除自己的动态转发。

无线：Pad 在前台且 Surface 可用时，同时启动 USB 与 Wi-Fi 监听器。无线只绑定实际 Wi-Fi 接口的 IPv4 地址，不使用通配地址、蜂窝网络或 VPN 接口；换网时仅重建无线监听器，不中断活动 USB。GUI 无线优先接收 Pad 主动建立的 TCP，并重新进行 PDB1 视频认证。没有新 Pad 移交连接时，8 秒后回退旧版直连；此路径和 CLI 使用原生 IPv4 socket 及可选物理接口（默认 `en0`）。视频会话不会自动从 USB 切到无线。Mac 连接按钮使用选中的方式；Pad 连接按钮优先选择 USB。认证后的 `hello.wifiAddress` 将当前无线地址告知 USB 端，Mac 验证为可用 IPv4 后保存；旧客户端忽略这一可选字段。出站视频连接兼容只限制 Pad 入站连接的 VPN，不修改 VPN 配置。完全阻止局域网访问的 VPN 仍可阻断无线；USB 使用 loopback 与 ADB。

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

收到 `ready` 后立即启动每秒 `ping`/`pong` 保活，覆盖虚拟屏和采集器的准备阶段。准备超过 30 秒会发起取消；系统采集 API 返回后完成清理。3 秒未完成的解码确认、6 秒无任何响应会终止会话并释放虚拟屏。测试时长从采集器成功启动后计时；未知消息与未协商的输入消息被拒绝。HDR 还要求在 8 秒可见时间内收到已验证且有呈现帧的输出格式，否则回退。

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

## 0.6.0 可选触屏扩展

基础 v1 的 `hello.input` 和 `config.input` 仍为 false，保持旧版兼容。新 Pad 在 `hello` 额外声明 `touchVersion:1`；Mac 在 `config` 回传同一字段，Pad 在 `ready` 确认后，才允许新增的控制消息。旧端不声明时只传视频。配置本身不启用触屏。

- Mac → Pad：`touch-mode(epoch,enabled,mode)`；mode 为 `direct` 或 `trackpad`，缺失按 direct 处理。epoch 是从 1 开始、严格递增的 32 位正整数。只有 Mac 本地开关开启、辅助功能权限有效且虚拟屏就绪，enabled 才为 true。
- Pad → Mac：`touch-state(epoch,enabled)` 确认切换。
- Pad → Mac：`touch(epoch,phase,x,y,dx,dy)`。phase 仅允许 `begin/end/click/rightclick/down/move/hover/up/cancel/scroll/space-left/space-right/mission-control/app-windows/zoom-in/zoom-out`；cancel 不带坐标，其他动作使用画面内 0…1 的归一化坐标；scroll、hover 以及触控板 move 附加 -1…1 的 dx/dy。Mac 拒绝布尔值、字符串、非有限数及越界坐标。不存在键码、修饰键、远端指定显示器或全局坐标字段。

Mac 同步关闭本地输入闸门并释放按下状态，然后通知 Pad。每次切换都更换 epoch，排队中的旧消息在关闭及重新开启后均无效。Pad 切换时清空发送队列；单独写线程最多排队 64 条，合并连续 move，保留按下/抬起/取消边界。溢出关闭连接。拖动停留时每 500 ms 发送当前位置，Mac 超过 2 秒未收到后释放按下状态。Mac 对当前代次输入限制每秒 500 条。

直接触屏按实际 SurfaceView 归一化，映射到虚拟屏的逻辑坐标。触控板在 begin 记录当前光标，逐条累加相对移动，并限制在活动显示器范围；不依赖异步系统事件已经生效。end/cancel/开关切换清除锚点。零位移拖动心跳只保活，不重复移动。直接模式拒绝 hover 和系统快捷动作。

Pad 单指点按/双击，直接模式单指拖动；双指轻点与滑动分别产生右键和滚动。触控板支持三指拖动，也支持单指轻点后再次按住拖动；后者使用 Android 双击的时间及距离阈值，第二次接触移动后才发送 down。取消、模式切换及尺寸变化清除轻点记录。四指滑动和双指捏合映射到固定的 Mac 快捷键。第一个手指抬起后，其余手指不能重新变成点击或拖动。Activity 暂停、Surface 尺寸变化、Mac 停止/休眠/回退先取消输入。FPS 浮层不截获触摸。

## Mac 设置扩展

`hello/config/ready` 三方以 `controlsVersion:1` 协商。Mac 发送 `pad-settings(language,showFPS,size,font,color,x,y)`；language 仅 zh/en，showFPS 是布尔值，size 是 12…64 整数，font 为 0…2 整数，color 为 #RRGGBB，位置为有限的 0…1 数值。Pad 验证后在当前会话 UI 回调应用。未协商或非法值断开。

Mac 确认重新配对后立即撤销本地密钥和输入、禁止 HDR 回退，并发送 `reset-pairing`。Pad 原子持久化新密钥后才发送 `pair-reset`；Mac 最多等待 2 秒。ADB 配对保存使用代次锁，撤销前开始的准备任务不能重新写入旧授权。Pad 在握手及获取会话所有权后重新核对密钥，旧认证不能跨越撤销。

## Pad 发起连接（PDR1）

Mac GUI 监听 TCP 49372，并发布 `_nextend._tcp` Bonjour 服务；USB 存在时维护该端口的 ADB reverse。Pad Connect 先尝试 USB，再尝试发现的 IPv4 Mac。发现结果不构成信任。两端仍需首次 USB 配对，Mac 必须运行。

握手同样使用长度前缀、新随机 nonce 和配对密钥：Pad 发送 PDR1 + nonce P，Mac 回 nonce M + proof(request-mac,P||M)，Pad 回 proof(request-pad,P||M)。HKDF info 使用独立的 request-mac-to-pad / request-pad-to-mac，不能与视频通道互换。控制包上限 4096 字节，每次读有总截止时间。

请求仅允许一个 `type` 字段，值为 `connect` 或 `resume`。认证后 Mac 在主线程再次核对当前配对密钥。

- `connect` 来自 Pad 的显式点击。Mac 空闲时启动本地连接，loopback 来源选择 USB，其他已认证来源选择无线；沿用本地画质和触屏设置。已有会话、退出或重启待处理时拒绝。
- `resume` 来自前台 Pad 的空闲轮询，只能接续 Mac 已明确启动的无线会话，包括同一次连接的 HDR 回退。它不能创建会话、启用输入或修改设置；USB loopback 的 resume 一律拒绝。

回复为 `connect-result(accepted,reverse)`。reverse 为 true 时，Mac 在发送回复前预留等待槽，防止超时回退与移交交叉。成功后移交同一 TCP 的唯一所有权，关闭旧请求对象不会关闭视频 FD；失败或取消会释放等待者并关闭连接。视频仍使用新的 PDB1 nonce、认证证明和方向密钥，请求密钥不用于视频。

Pad 每两秒探测已发现的 Mac；手动请求在同一锁内抢占轮询。接收器 socket 和共享 Surface lease 都空闲时才请求移交。接管同步完成，失败由请求方关闭 socket。0.7.0 中请求与监听由 DisplayService 持有，Activity 暂停和 Surface 重建保留已有会话；服务重启和连接状态变更取消旧代次；解码器未释放前不消费下一次回退的连接槽。

Pad 不能提供回连地址、指定画质或启用触屏。旧版直连回退只使用本地保存或已认证 TCP 来源地址。请求被接受后 20 秒仍无视频时，Pad 显示超时提示。

## 0.7.0 可选后台与安全区字段

`stats.viewerVisible` 表示 Pad 有有效输出 Surface。缺失时 Mac 按 true 兼容旧端；为 false 时新 Mac 暂停编码并继续控制保活。Pad 在无 Surface 时仍接收并负 ACK 视频，旧 Mac 因而可以继续传输。Surface 恢复使用已有 keyframe 请求，未增加消息类型；Mac 缓存最近采集帧，以支持静态桌面恢复。`stats` 还可附带 panelWidth/panelHeight/videoWidth/videoHeight，供设置预览使用。

`pad-settings.safeArea` 为可选对象，包含 enabled 布尔值及 top/right/bottom/left 四个有限数值，每边范围 0…0.2，以完整 Pad 视口比例表示。非法值拒绝；旧 Mac 省略时保留已保存校准，旧 Pad 忽略额外字段。设置仍经过 controlsVersion:1 协商与既有认证。四边避让不修改传输分辨率、画面比例或触控协议，实际 SurfaceView 的完整视频区域映射到整张 Mac 虚拟屏。
