# 原生实现

## macOS

AppKit 在 macOS 26 及以上可使用 `NSGlassEffectView`，通过 `contentView` 装载内容，并设置 `cornerRadius`、`style` 和克制的 `tintColor`。较早版本使用 `NSVisualEffectView` 或不透明填色回退；以本地 SDK 定义核对 API。SwiftUI 使用目标 SDK 的 `glassEffect`，不要为视觉修改最低系统版本而不说明。

监听 `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`。`accessibilityDisplayShouldReduceTransparency` 或 `accessibilityDisplayShouldIncreaseContrast` 开启时提高不透明度/改为实色；减少动态效果时取消自定义位移动画。保留按钮的键盘操作、焦点环、禁用状态与 accessibility label。浅色调色板如不具备深色设计，应明确固定浅色外观，不能混用自动深色文字和浅色底。

圆角裁切应只作用于材质或内容层，外阴影放在未裁切的父容器。不要为每行状态、每个数字再次创建模糊视图。布局以内容约束为主，在最小尺寸和较长译文下实际检查。

## Android

普通 Activity 内的背景模糊能力取决于系统版本、窗口与合成路径。`RenderEffect` 对一个 View 的效果并不自动等于采样其背后内容；不要声称使用它就得到背景折射。

可使用 Drawable / Compose Brush 的半透明渐变、1 dp 明亮边缘与轻阴影近似玻璃，采用不透明背景确保可读性。保留原生 Button/TextView 的语义；对选中项设置可访问状态，最低触控区域建议 48 dp。支持字体放大，并使用滚动容器避免固定高度裁切。动态效果跟随系统设置。

自绘中复用 Paint 时，每次 shader 填充前重置 alpha 和 style；Paint 的透明度会乘到 shader 上，上一次半透明描边的状态不能泄漏到下一帧背景。特别检查“不透明等待遮罩”在重复重绘、显示/隐藏后仍完全覆盖旧视频。

视频画面保持 SurfaceView / 原有渲染路径。控制层独立叠加、隐藏后不保留昂贵特效。等待/断开时使用不透明遮罩阻止旧视频合成瓦片残留。切换连接模式应遵循原有生命周期，不为了视觉动画推迟资源释放。

## 验证边界

截图可以证明布局，不能证明 HDR、真实折射、亮度或性能。原生材质、渐变近似和全链路色彩支持分别验收。先完成现有功能的代表性交互再交付。
