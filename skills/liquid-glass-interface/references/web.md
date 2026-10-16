# 网页材质

`assets/liquid-glass.css` 提供可覆盖的颜色、透明度、模糊、圆角与阴影变量。背景需要有柔和明暗变化，才能看见材质；不必增加图片或动画背景。文字层位于高光层之上。`backdrop-filter` 缺失时默认实色。

使用 `.lg-panel` 作外层面板，`.lg-toolbar` 作选项组，原生 button 配合 `aria-pressed` 表达单选式设置。脚本只负责组内选中和高亮位置，业务值变更由页面监听 `glasschange`。如果控件是真正的分页导航，改用链接和 `aria-current`；如果是 tabs，完整实现 tablist/tab/tabpanel 及箭头键行为，不直接套用示例按钮语义。

把 `data-glass-theme="dark"` 放在父节点可使用深色材质；`data-glass-solid` 可由产品设置显式开启实色模式。系统 `prefers-reduced-transparency` 的浏览器支持不一致，因此仍应提供可用的实色底色。`forced-colors` 以系统 Canvas/CanvasText 和可见边框降级。脚本不开启循环动画或全局鼠标跟踪。

演示页的颜色与文案仅为说明；移植时删除不需要的演示内容。验证模糊开启和关闭两种情况下文字的对比度，普通文字目标至少 4.5:1；大字至少 3:1。不能仅靠白色描边或透明度区分状态。
