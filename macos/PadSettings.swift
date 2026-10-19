import AppKit

struct PadSettings {
    var showFPS = UserDefaults.standard.bool(forKey: "pad.fps.enabled")
    var size = (UserDefaults.standard.object(forKey: "pad.fps.size") as? Int ?? 20).clamped(to: 12...64)
    var font = (UserDefaults.standard.object(forKey: "pad.fps.font") as? Int ?? 1).clamped(to: 0...2)
    var color = UserDefaults.standard.string(forKey: "pad.fps.color") ?? "#FFFFFF"
    var x = (UserDefaults.standard.object(forKey: "pad.fps.x") as? Double ?? 0.03).clamped(to: 0...1)
    var y = (UserDefaults.standard.object(forKey: "pad.fps.y") as? Double ?? 0.03).clamped(to: 0...1)
    var json: [String: Any] {
        ["type": "pad-settings", "language": AppLanguage.english ? "en" : "zh", "showFPS": showFPS,
         "size": size, "font": font, "color": color, "x": x, "y": y]
    }
    func save() {
        let d = UserDefaults.standard
        for (key, value) in ["enabled": showFPS, "size": size, "font": font, "color": color, "x": x, "y": y] as [String: Any] { d.set(value, forKey: "pad.fps." + key) }
    }
}
private extension Comparable { func clamped(to range: ClosedRange<Self>) -> Self { min(range.upperBound, max(range.lowerBound, self)) } }

@MainActor final class PadSettingsPanel: NSWindowController {
    private var value: PadSettings
    private let changed: (PadSettings) -> Void
    private let fps = NSSwitch()
    private let font = NSPopUpButton()
    private let size = NSSlider(value: 20, minValue: 12, maxValue: 64, target: nil, action: nil)
    private let color = NSColorWell()
    private let x = NSSlider(value: 0.03, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let y = NSSlider(value: 0.03, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let sizeLabel = glassText("", size: 13)
    let diagnostics = glassText("—", size: 12, muted: true)
    init(value: PadSettings, changed: @escaping (PadSettings) -> Void) {
        self.value = value; self.changed = changed
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 410), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("Pad 设置", "Pad settings"); panel.isReleasedWhenClosed = false
        let body = GlassBackdropView(); panel.contentView = body
        fps.state = value.showFPS ? .on : .off
        font.addItems(withTitles: [L("无衬线", "Sans serif"), L("等宽", "Monospace"), L("衬线", "Serif")]); font.selectItem(at: value.font)
        size.doubleValue = Double(value.size); sizeLabel.stringValue = "\(value.size) sp"
        x.doubleValue = value.x; y.doubleValue = value.y
        if let rgb = UInt32(value.color.dropFirst(), radix: 16) { color.color = NSColor(srgbRed: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1) }
        var rows: [NSView] = []
        for (name, control) in [(L("显示 FPS", "Show FPS"), fps as NSControl), (L("字体", "Font"), font), (L("字号", "Size"), size), (L("颜色", "Color"), color), (L("水平位置", "Horizontal position"), x), (L("垂直位置", "Vertical position"), y)] {
            let title = glassText(name, size: 13); title.widthAnchor.constraint(equalToConstant: 130).isActive = true
            control.target = self; control.action = #selector(update); control.setAccessibilityLabel(name)
            control.widthAnchor.constraint(equalToConstant: 180).isActive = true
            let row = glassStack([title, control], vertical: false, spacing: 20); row.heightAnchor.constraint(equalToConstant: 32).isActive = true; rows.append(row)
        }
        diagnostics.maximumNumberOfLines = 3
        rows += [sizeLabel, diagnostics]
        let content = glassStack(rows, spacing: 12); content.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 28), content.topAnchor.constraint(equalTo: body.topAnchor, constant: 24), content.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -28)])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func update() {
        value.showFPS = fps.state == .on; value.font = font.indexOfSelectedItem; value.size = Int(size.doubleValue.rounded())
        value.x = x.doubleValue; value.y = y.doubleValue
        if let rgb = color.color.usingColorSpace(.sRGB) {
            value.color = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        }
        sizeLabel.stringValue = "\(value.size) sp"; value.save(); changed(value)
    }
}
