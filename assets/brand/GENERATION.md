# 暗色背景图标

2026-10-19 使用 Codex 内置 imagegen 编辑现有 Nextend 图标。输入为原 `assets/brand/mark.png`；原图的本地备份为 `work/brand/mark-light.png`。保留折叠玻璃标志和圆角轮廓，将浅色底改为石墨深色，并加强玻璃边缘与反光。生成结果保存到 `assets/brand/mark.png`。

随后由 `scripts/build-icons.sh` 使用系统 `sips` 和 `iconutil` 生成 macOS ICNS 和 Android 各密度图标。这一步只做确定性的格式与尺寸转换。

实际编辑提示词：

> Edit this existing Nextend app icon only. Preserve exactly the centered folded translucent teal glass arch/ribbon emblem, its silhouette, proportions, geometry, location and orientation. Preserve the rounded square app-icon tile and its rounded corners and overall dimensions. Change ONLY the pale mint/white tile background (including the background visible through and inside the arch) to deep dark graphite/charcoal with a subtle cool-teal tint, approximately #101b20 to #1d3037. The glass emblem should stand out with luminous pale teal edges, rich translucent jade/teal depth, tasteful bright specular highlights, and crisp dimensional reflections. Maintain premium realistic glass material. Keep the small outer area outside the rounded-square icon transparent and clean, no ragged halos. No text, no additional shapes, no shadow extending far outside the icon, no new symbol. Square high resolution app icon.
