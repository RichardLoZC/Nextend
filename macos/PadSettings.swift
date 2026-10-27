import AppKit
import ApplicationServices

struct PadSettings {
    var showFPS = UserDefaults.standard.bool(forKey: "pad.fps.enabled")
    var size = (UserDefaults.standard.object(forKey: "pad.fps.size") as? Int ?? 20).clamped(to: 12...64)
    var font = (UserDefaults.standard.object(forKey: "pad.fps.font") as? Int ?? 1).clamped(to: 0...2)
    var color = UserDefaults.standard.string(forKey: "pad.fps.color") ?? "#FFFFFF"
    var x = (UserDefaults.standard.object(forKey: "pad.fps.x") as? Double ?? 0.03).clamped(to: 0...1)
    var y = (UserDefaults.standard.object(forKey: "pad.fps.y") as? Double ?? 0.03).clamped(to: 0...1)
    var displayArea = PadDisplayArea.load()
    var notch = PadNotch.load()
    var json: [String: Any] {
        var area = displayArea
        if notch.enabled || notch.guides { area.enabled = false }
        return ["type": "pad-settings", "language": AppLanguage.english ? "en" : "zh", "showFPS": showFPS,
         "size": size, "font": font, "color": color, "x": x, "y": y, "safeArea": area.json]
    }
    func save() {
        displayArea.save()
        notch.save()
        let d = UserDefaults.standard
        for (key, value) in ["enabled": showFPS, "size": size, "font": font, "color": color, "x": x, "y": y] as [String: Any] { d.set(value, forKey: "pad.fps." + key) }
    }
}

@MainActor private final class PadNotchPreview: NSView {
    var value = PadNotch() { didSet { needsDisplay = true } }
    var changed: ((PadNotch) -> Void)?
    private var selectedLeft = true
    private var displayRect: NSRect { bounds.insetBy(dx: 6, dy: 8) }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let r = displayRect, n = value.normalized
        NSColor(srgbRed: 0.23, green: 0.42, blue: 0.58, alpha: 1).setFill()
        NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
        let bar = NSRect(x: r.minX, y: r.minY, width: r.width, height: 24)
        NSColor(white: 0.94, alpha: 0.95).setFill(); bar.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.darkGray]
        ("  Finder" as NSString).draw(at: NSPoint(x: r.minX + 8, y: r.minY + 6), withAttributes: attrs)
        let left = r.minX + r.width * n.left, right = r.minX + r.width * n.right
        NSColor.black.setFill(); NSBezierPath(roundedRect: NSRect(x: left, y: r.minY, width: right - left, height: max(18, r.height * n.depth)), xRadius: 7, yRadius: 7).fill()
        ("«  ◉  ☁  ◷" as NSString).draw(at: NSPoint(x: min(right + 6, r.maxX - 65), y: r.minY + 5), withAttributes: attrs)
        for x in [left, right] {
            let path = NSBezierPath(); path.move(to: NSPoint(x: x, y: r.minY)); path.line(to: NSPoint(x: x, y: r.maxY))
            NSColor.systemRed.setStroke(); path.lineWidth = 2; path.stroke()
            NSColor.systemRed.setFill(); NSBezierPath(ovalIn: NSRect(x: x - 5, y: r.maxY - 10, width: 10, height: 10)).fill()
        }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil), r = displayRect
        selectedLeft = abs(p.x - (r.minX + r.width * value.left)) < abs(p.x - (r.minX + r.width * value.right))
        move(event)
    }
    override func mouseDragged(with event: NSEvent) { move(event) }
    private func move(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil), amount = Double((p.x - displayRect.minX) / displayRect.width)
        var n = value
        if selectedLeft { n.left = min(amount, n.right - 0.02) } else { n.right = max(amount, n.left + 0.02) }
        value = n.normalized; changed?(value)
    }
}
private extension Comparable { func clamped(to range: ClosedRange<Self>) -> Self { min(range.upperBound, max(range.lowerBound, self)) } }

struct PadDisplayArea {
    var enabled = false
    var top = 0.03
    var right = 0.0
    var bottom = 0.0
    var left = 0.0
    static func normalized(_ value: Double, fallback: Double = 0) -> Double { value.isFinite ? min(0.2, max(0, value)) : fallback }
    static func load() -> Self {
        let d = UserDefaults.standard
        var value = Self(); value.enabled = d.bool(forKey: "pad.safeArea.enabled")
        value.top = normalized(d.object(forKey: "pad.safeArea.top") as? Double ?? 0.03, fallback: 0.03)
        value.right = normalized(d.double(forKey: "pad.safeArea.right"))
        value.bottom = normalized(d.double(forKey: "pad.safeArea.bottom"))
        value.left = normalized(d.double(forKey: "pad.safeArea.left"))
        return value
    }
    var json: [String: Any] { ["enabled": enabled, "top": Self.normalized(top), "right": Self.normalized(right), "bottom": Self.normalized(bottom), "left": Self.normalized(left)] }
    func save() { for (key, value) in json { UserDefaults.standard.set(value, forKey: "pad.safeArea." + key) } }
}

@MainActor private final class PadAreaPreview: NSView {
    var area = PadDisplayArea() { didSet { needsDisplay = true } }
    var panelAspect: CGFloat = 3200.0 / 2136.0 { didSet { needsDisplay = true } }
    var videoAspect: CGFloat = 3200.0 / 2136.0 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let h = min(bounds.height - 12, (bounds.width - 16) / panelAspect)
        let screen = NSRect(x: (bounds.width - h * panelAspect) / 2, y: 6, width: h * panelAspect, height: h)
        NSColor(white: 0.10, alpha: 1).setFill(); NSBezierPath(roundedRect: screen, xRadius: 12, yRadius: 12).fill()
        let safe = area.enabled ? NSRect(x: screen.minX + screen.width * area.left, y: screen.minY + screen.height * area.top,
            width: screen.width * (1 - area.left - area.right), height: screen.height * (1 - area.top - area.bottom)) : screen
        let vw = min(safe.width, safe.height * videoAspect), vh = min(safe.height, safe.width / videoAspect)
        let desktop = NSRect(x: safe.midX - vw / 2, y: area.enabled ? safe.minY : safe.midY - vh / 2, width: vw, height: vh)
        NSColor(srgbRed: 0.30, green: 0.58, blue: 0.74, alpha: 1).setFill(); NSBezierPath(rect: desktop).fill()
        let bar = NSRect(x: desktop.minX, y: desktop.minY, width: desktop.width, height: 16)
        NSColor(white: 0.96, alpha: 0.95).setFill(); NSBezierPath(rect: bar).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor.darkGray]
        (L("  Finder  文件  编辑  显示", "  Finder  File  Edit  View") as NSString).draw(at: NSPoint(x: bar.minX + 7, y: bar.minY + 2), withAttributes: attrs)
        ("12:00" as NSString).draw(at: NSPoint(x: bar.maxX - 33, y: bar.minY + 2), withAttributes: attrs)
        if area.enabled {
            NSColor.systemTeal.setStroke(); let border = NSBezierPath(rect: safe.insetBy(dx: 1, dy: 1)); border.lineWidth = 1.5; border.stroke()
        }
    }
}

@MainActor final class PadSettingsPanel: NSWindowController, NSWindowDelegate {
    private var value: PadSettings
    private let changed: (PadSettings) -> Void
    private let fps = NSSwitch()
    private let font = NSPopUpButton()
    private let size = NSSlider(value: 20, minValue: 12, maxValue: 64, target: nil, action: nil)
    private let color = NSColorWell()
    private let x = NSSlider(value: 0.03, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let y = NSSlider(value: 0.03, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let sizeLabel = glassText("", size: 13)
    private let avoid = NSSwitch()
    private let edges = (0..<4).map { _ in NSSlider(value: 0, minValue: 0, maxValue: 20, target: nil, action: nil) }
    private let edgeLabels = (0..<4).map { _ in glassText("", size: 12, muted: true) }
    private let preview = PadAreaPreview()
    private let notchEnabled = NSSwitch()
    private let notchGuides = NSSwitch()
    private let notchEdges = (0..<3).map { _ in NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil) }
    private let notchLabels = (0..<3).map { _ in glassText("", size: 12, muted: true) }
    private let notchPreview = PadNotchPreview()
    private let notchStatus = glassText("", size: 12, muted: true)
    let diagnostics = glassText("—", size: 12, muted: true)
    init(value: PadSettings, changed: @escaping (PadSettings) -> Void) {
        self.value = value; self.changed = changed
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("Pad 设置", "Pad settings"); panel.isReleasedWhenClosed = false; panel.delegate = self
        let body = GlassBackdropView(); panel.contentView = body
        fps.state = value.showFPS ? .on : .off
        font.addItems(withTitles: [L("无衬线", "Sans serif"), L("等宽", "Monospace"), L("衬线", "Serif")]); font.selectItem(at: value.font)
        size.doubleValue = Double(value.size); sizeLabel.stringValue = "\(value.size) sp"
        x.doubleValue = value.x; y.doubleValue = value.y
        if let rgb = UInt32(value.color.dropFirst(), radix: 16) { color.color = NSColor(srgbRed: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1) }
        func row(_ name: String, _ control: NSControl, extra: NSView? = nil) -> NSView {
            let title = glassText(name, size: 13); title.widthAnchor.constraint(equalToConstant: 120).isActive = true
            control.target = self; control.action = #selector(update); control.setAccessibilityLabel(name)
            control.widthAnchor.constraint(equalToConstant: 210).isActive = true
            let result = glassStack([title, control] + (extra.map { [$0] } ?? []), vertical: false, spacing: 12)
            result.heightAnchor.constraint(equalToConstant: 32).isActive = true; return result
        }
        let fpsRows = [(L("显示 FPS", "Show FPS"), fps as NSControl), (L("字体", "Font"), font), (L("字号", "Size"), size), (L("颜色", "Color"), color), (L("水平位置", "Horizontal position"), x), (L("垂直位置", "Vertical position"), y)].map { row($0.0, $0.1) } + [sizeLabel]
        avoid.state = value.displayArea.enabled ? .on : .off
        let amounts = [value.displayArea.top, value.displayArea.right, value.displayArea.bottom, value.displayArea.left]
        for (slider, amount) in zip(edges, amounts) { slider.doubleValue = amount * 100; slider.isContinuous = true }
        let help = glassText(L("为整幅画面设置留白。启用刘海图标折叠或校准线时，自动暂停这些边距。", "Add margins around the entire image. Cutout folding and calibration temporarily suspend these margins."), size: 12, muted: true)
        help.maximumNumberOfLines = 3; help.widthAnchor.constraint(equalToConstant: 440).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 170).isActive = true; preview.widthAnchor.constraint(equalToConstant: 440).isActive = true
        var areaRows: [NSView] = [row(L("画面边缘留白", "Image margins"), avoid), help, preview]
        let names = [L("上边距", "Top margin"), L("右边距", "Right margin"), L("下边距", "Bottom margin"), L("左边距", "Left margin")]
        for i in 0..<4 { edgeLabels[i].widthAnchor.constraint(equalToConstant: 48).isActive = true; areaRows.append(row(names[i], edges[i], extra: edgeLabels[i])) }
        let reset = NSButton(title: L("恢复默认", "Reset margins"), target: self, action: #selector(resetMargins)); reset.bezelStyle = .rounded
        areaRows += [reset]
        notchEnabled.state = value.notch.enabled ? .on : .off; notchGuides.state = value.notch.guides ? .on : .off
        let notchHelp = glassText(L("打开校准线，看着 Pad 调整左右边界，对齐物理刘海。点击预览拖动红线也可调整。图标从刘海右侧折叠到下方面板，桌面保持满屏。", "Show guides and align the left and right edges with the physical cutout on your Pad. You can also drag the preview's red lines. Hidden icons open below the cutout; the desktop stays full size."), size: 12, muted: true)
        notchHelp.maximumNumberOfLines = 4; notchHelp.widthAnchor.constraint(equalToConstant: 440).isActive = true
        notchPreview.widthAnchor.constraint(equalToConstant: 440).isActive = true; notchPreview.heightAnchor.constraint(equalToConstant: 150).isActive = true
        var notchRows: [NSView] = [row(L("图标折叠", "Fold menu-bar icons"), notchEnabled), row(L("在 Pad 显示校准线", "Show guides on Pad"), notchGuides), notchHelp, notchPreview]
        let notchNames = [L("刘海左边界", "Cutout left edge"), L("刘海右边界", "Cutout right edge"), L("刘海深度", "Cutout depth")]
        for i in 0..<3 {
            notchEdges[i].isContinuous = true; notchLabels[i].widthAnchor.constraint(equalToConstant: 60).isActive = true
            if i == 2 { notchEdges[i].minValue = 1; notchEdges[i].maxValue = 15 }
            notchRows.append(row(notchNames[i], notchEdges[i], extra: notchLabels[i]))
        }
        notchStatus.maximumNumberOfLines = 2; notchStatus.widthAnchor.constraint(equalToConstant: 440).isActive = true
        let access = NSButton(title: L("菜单栏控制权限…", "Menu-bar access…"), target: self, action: #selector(menuBarAccess)); access.bezelStyle = .rounded
        notchRows += [notchStatus, access]
        notchPreview.changed = { [weak self] n in
            guard let self else { return }; self.value.notch = n; self.refreshNotch(); self.value.save(); self.changed(self.value)
        }
        let tabs = NSTabView(); tabs.translatesAutoresizingMaskIntoConstraints = false
        for (title, rows) in [(L("刘海与菜单栏", "Cutout & menu bar"), notchRows), ("FPS", fpsRows), (L("画面留白", "Image margins"), areaRows)] {
            let tab = NSTabViewItem(identifier: title); tab.label = title
            let page = NSView(); let content = glassStack(rows, spacing: 10); content.translatesAutoresizingMaskIntoConstraints = false
            page.addSubview(content); NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 16), content.topAnchor.constraint(equalTo: page.topAnchor, constant: 18)])
            tab.view = page; tabs.addTabViewItem(tab)
        }
        diagnostics.maximumNumberOfLines = 3; diagnostics.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(tabs); body.addSubview(diagnostics)
        NSLayoutConstraint.activate([tabs.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 18), tabs.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -18), tabs.topAnchor.constraint(equalTo: body.topAnchor, constant: 16), tabs.bottomAnchor.constraint(equalTo: diagnostics.topAnchor, constant: -12), diagnostics.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 28), diagnostics.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -28), diagnostics.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -18)])
        refreshPreview(); refreshNotch()
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowWillClose(_ notification: Notification) { stopGuides() }
    override func close() { stopGuides(); super.close() }
    private func stopGuides() {
        guard value.notch.guides else { return }; value.notch.guides = false; notchGuides.state = .off; changed(value)
    }
    @objc private func menuBarAccess() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if !AXIsProcessTrusted() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
        refreshNotch()
    }
    private func refreshNotch() {
        value.notch = value.notch.normalized; notchPreview.value = value.notch
        for (i, amount) in [value.notch.left, value.notch.right, value.notch.depth].enumerated() {
            notchEdges[i].doubleValue = amount * 100; notchLabels[i].stringValue = String(format: "%.1f%%", amount * 100)
        }
        notchStatus.stringValue = AXIsProcessTrusted()
            ? L("设置自动保存。关闭此窗口会收起校准线。", "Settings save automatically. Closing this window hides the guides.")
            : L("折叠图标需要 Nextend 的辅助功能权限，校准线可直接使用。", "Folding needs Nextend's Accessibility access. Guides work without it.")
    }
    func updatePreview(panelWidth: Int, panelHeight: Int, videoWidth: Int, videoHeight: Int) {
        guard panelWidth > 0, panelHeight > 0, videoWidth > 0, videoHeight > 0 else { return }
        preview.panelAspect = CGFloat(panelWidth) / CGFloat(panelHeight); preview.videoAspect = CGFloat(videoWidth) / CGFloat(videoHeight)
    }
    private func refreshPreview() {
        preview.area = value.displayArea
        for i in 0..<4 { edges[i].isEnabled = value.displayArea.enabled; edgeLabels[i].stringValue = String(format: "%.1f%%", edges[i].doubleValue) }
    }
    @objc private func resetMargins() {
        value.displayArea = PadDisplayArea(); avoid.state = .off
        for (slider, amount) in zip(edges, [3.0, 0, 0, 0]) { slider.doubleValue = amount }
        refreshPreview(); value.save(); changed(value)
    }
    @objc private func update() {
        value.showFPS = fps.state == .on; value.font = font.indexOfSelectedItem; value.size = Int(size.doubleValue.rounded())
        value.x = x.doubleValue; value.y = y.doubleValue
        if let rgb = color.color.usingColorSpace(.sRGB) { value.color = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded())) }
        value.displayArea.enabled = avoid.state == .on
        let amounts = edges.map { ($0.doubleValue * 10).rounded() / 1000 }
        value.displayArea.top = amounts[0]; value.displayArea.right = amounts[1]; value.displayArea.bottom = amounts[2]; value.displayArea.left = amounts[3]
        value.notch.enabled = notchEnabled.state == .on; value.notch.guides = notchGuides.state == .on
        value.notch.left = notchEdges[0].doubleValue / 100; value.notch.right = notchEdges[1].doubleValue / 100; value.notch.depth = notchEdges[2].doubleValue / 100
        sizeLabel.stringValue = "\(value.size) sp"; refreshPreview(); refreshNotch(); value.save(); changed(value)
    }
}
