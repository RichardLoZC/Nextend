# Nextend 0.8.4：双指滚动与捏合

- Mac build 16；Android build 18，保留原安装身份和配对。
- 直接触屏双指接触立即定位鼠标到初始中心，后续滚动只改变内容，鼠标位置固定。
- 直接触屏与触控板均支持双指张开/捏合，映射到应用的 Command +/−，不是原生连续 magnify 事件；效果取决于应用支持。
- 双指同向移动识别为滚动，距离变化占主导识别为缩放，识别后锁定直到抬指。短暂抖动仍可双指轻点右键。
- 首次抬指包含的最终位移也会被处理，避免快速捏合误发右键。
- 直接缩放定位并确认触点所属窗口，以进程定向投递快捷键，找不到窗口或激活失败则取消该次缩放；不使用隐式点击。
- AX 查询由容量和时间均受限的 worker 执行。新手势、后续点击/拖动、关闭触屏、连接结束及显示器/权限失效会撤销旧任务。
- 两端应共同升级。旧 Mac 能解析消息，但不支持直接模式缩放和双指接触时立即定位。

## 验证

Android 单元测试、Mac 状态机及恢复/日志测试、Pad 真机手势包验证与窗口定向投递的结果记录在 `work/touch-gestures-20261028/`。未完成项以 verification.json 为准，不以本说明代替测试证据。

本轮是本地安装候选版。公开 NAS 更新清单和 GitHub Release 尚未变更。


## 2026-10-28 真机验收结果

- Mac / Pad 均已安装，屏幕录制与辅助功能原授权已从系统界面重新登记。
- Android 62 项单测、两种输入模式各 6 组 Pad 真实 MotionEvent / 加密触屏协议测试通过。
- Mac 原生测试窗口验证了跨应用、同应用不同窗口的缩放定向，新拖动及关闭输入时撤销排队任务，滚动固定鼠标。
- 真实 USB 与 Wi-Fi 桌面的独立浏览器各 3 项测试通过：双指滚动改变页面，鼠标保持起点；张开放大；捏合缩小。浏览器使用临时独立配置，仅打开本地测试页。
- 同一 Mac GUI 进程完成 USB → Wi-Fi 切换；USB 已观察至少 389 秒，Wi-Fi 已观察至少 125 秒且保留连接。未把短时验收声称为整天稳定性测试。
- 此轮为 3200 × 2136 / 60 fps / SDR。Wi-Fi 视频实际走无线，测试手势通过 USB ADB 注入；不把它称为已拔线人工手势验收。
- 安装包与验收记录位于 `outputs/gestures-0.8.4/` 和 `work/touch-gestures-20261028/verification/`。公开更新清单和 GitHub Release 未改变。

交互式测试为可选入口，不放入默认自动测试，避免中断用户桌面：`tests/touch_gestures_device.py`（Pad 空闲）、`tests/test_touch_zoom_focus.py`（独立 Mac 测试窗口）、`tests/touch_browser_device.mjs`（Nextend 已连接且开启直接触屏）。先编译并提供 `tests/android/NextendTouchInput.java` 的 shell 测试 JAR；测试结束会移除 Pad 临时 JAR并关闭独立窗口。详细结果以 verification.json 为准。
