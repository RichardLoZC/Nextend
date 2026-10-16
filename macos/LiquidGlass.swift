import AppKit
import QuartzCore

enum GlassPalette {
    static let ink = NSColor(srgbRed: 0.08, green: 0.20, blue: 0.19, alpha: 1)
    static let muted = NSColor(srgbRed: 0.30, green: 0.41, blue: 0.39, alpha: 1)
    static let accent = NSColor(srgbRed: 0.10, green: 0.39, blue: 0.34, alpha: 1)
    static let mint = NSColor(srgbRed: 0.70, green: 0.88, blue: 0.82, alpha: 1)
}

func glassText(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, muted: Bool = false) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = muted ? GlassPalette.muted : GlassPalette.ink
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    return label
}

func glassStack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 12) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = vertical ? .vertical : .horizontal
    stack.alignment = vertical ? .leading : .centerY
    stack.spacing = spacing
    return stack
}

final class GlassBackdropView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [NSColor(srgbRed: 0.91, green: 0.95, blue: 0.91, alpha: 1),
                            NSColor(srgbRed: 0.72, green: 0.85, blue: 0.82, alpha: 1),
                            NSColor(srgbRed: 0.85, green: 0.92, blue: 0.91, alpha: 1)])?.draw(in: bounds, angle: -30)
        let wave = NSBezierPath()
        wave.move(to: NSPoint(x: -100, y: bounds.height * 0.60))
        wave.curve(to: NSPoint(x: bounds.width + 150, y: bounds.height * 0.44), controlPoint1: NSPoint(x: bounds.width * 0.37, y: -120), controlPoint2: NSPoint(x: bounds.width * 0.62, y: bounds.height + 150))
        wave.line(to: NSPoint(x: bounds.width + 150, y: -100)); wave.line(to: NSPoint(x: -100, y: -100)); wave.close()
        NSColor.white.withAlphaComponent(0.27).setFill(); wave.fill()
        NSColor.white.withAlphaComponent(0.55).setStroke(); wave.lineWidth = 1; wave.stroke()
    }
}

// Only the outer shell has a material. Nested rows remain plain and readable.
final class GlassSurface: NSView {
    let content = NSView()
    private var material: NSView!
    private var accessibilityObserver: NSObjectProtocol?
    init(radius: CGFloat = 28) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = GlassPalette.ink.cgColor; layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 22; layer?.shadowOffset = CGSize(width: 0, height: -9)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular; glass.cornerRadius = radius
            glass.tintColor = GlassPalette.mint.withAlphaComponent(0.06)
            glass.contentView = content; material = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .underWindowBackground; effect.blendingMode = .withinWindow; effect.state = .active
            effect.wantsLayer = true; effect.layer?.cornerRadius = radius; effect.layer?.masksToBounds = true
            effect.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: effect.leadingAnchor), content.trailingAnchor.constraint(equalTo: effect.trailingAnchor), content.topAnchor.constraint(equalTo: effect.topAnchor), content.bottomAnchor.constraint(equalTo: effect.bottomAnchor)])
            material = effect
        }
        addSubview(material); material.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([material.leadingAnchor.constraint(equalTo: leadingAnchor), material.trailingAnchor.constraint(equalTo: trailingAnchor), material.topAnchor.constraint(equalTo: topAnchor), material.bottomAnchor.constraint(equalTo: bottomAnchor)])
        content.wantsLayer = true; content.layer?.cornerRadius = radius
        content.layer?.borderWidth = 0.7; content.layer?.borderColor = NSColor.white.withAlphaComponent(0.65).cgColor
        updateAccessibility()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.updateAccessibility() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) } }
    private func updateAccessibility() {
        let solid = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        content.layer?.backgroundColor = (solid ? NSColor(srgbRed: 0.93, green: 0.96, blue: 0.94, alpha: 1) : .clear).cgColor
    }
    func embed(_ view: NSView, padding: CGFloat = 24) {
        content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding), view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding), view.topAnchor.constraint(equalTo: content.topAnchor, constant: padding), view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -padding)])
    }
}

final class GlassActionButton: NSButton {
    var primary = false { didSet { needsDisplay = true } }
    private var hovered = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); isBordered = false; focusRingType = .exterior
        setButtonType(.momentaryPushIn)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: max(90, (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width + 30), height: 42) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 15, yRadius: 15)
        let pressed = cell?.isHighlighted == true
        let fill = primary ? GlassPalette.accent : NSColor.white.withAlphaComponent(hovered ? 0.72 : 0.44)
        fill.withAlphaComponent(isEnabled ? (pressed ? 0.75 : fill.alphaComponent) : 0.25).setFill(); shape.fill()
        NSColor.white.withAlphaComponent(primary ? 0.22 : 0.85).setStroke(); shape.lineWidth = 1; shape.stroke()
        let color = primary ? NSColor.white : GlassPalette.ink
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: color.withAlphaComponent(isEnabled ? 1 : 0.42)]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2), withAttributes: attributes)
    }
}

final class DeviceBridgeView: NSView {
    var connected = false { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 350, height: 180) }
    override func draw(_ dirtyRect: NSRect) {
        let scale = min(bounds.width / 400, bounds.height / 190)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: (bounds.width-400*scale)/2, yBy: (bounds.height-190*scale)/2)
        transform.scale(by: scale); transform.concat()
        func device(_ rect: NSRect, radius: CGFloat, light: Bool) {
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            let shadow = NSShadow(); shadow.shadowColor = GlassPalette.ink.withAlphaComponent(0.14); shadow.shadowBlurRadius = 18; shadow.shadowOffset = NSSize(width: 0, height: -6)
            NSGraphicsContext.saveGraphicsState(); shadow.set(); NSColor.white.withAlphaComponent(0.85).setFill(); path.fill(); NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState(); path.addClip()
            NSGradient(colors: light ? [GlassPalette.mint, NSColor(srgbRed: 0.87, green: 0.97, blue: 0.94, alpha: 1)] : [GlassPalette.accent, NSColor(srgbRed: 0.17, green: 0.47, blue: 0.47, alpha: 1)])?.draw(in: rect, angle: 35)
            let ribbon = NSBezierPath(); ribbon.move(to: NSPoint(x: rect.minX-20, y: rect.midY-30)); ribbon.curve(to: NSPoint(x: rect.maxX+20, y: rect.midY+10), controlPoint1: NSPoint(x: rect.midX, y: rect.maxY+25), controlPoint2: NSPoint(x: rect.midX, y: rect.minY-40)); ribbon.lineWidth = 26; NSColor.white.withAlphaComponent(0.22).setStroke(); ribbon.stroke()
            NSGraphicsContext.restoreGraphicsState(); NSColor.white.withAlphaComponent(0.9).setStroke(); path.lineWidth=2; path.stroke()
        }
        device(NSRect(x: 23, y: 58, width: 222, height: 129), radius: 12, light: false)
        let base = NSBezierPath(roundedRect: NSRect(x: 5, y: 47, width: 258, height: 9), xRadius: 4, yRadius: 4)
        NSColor.white.withAlphaComponent(0.8).setFill(); base.fill()
        device(NSRect(x: 218, y: 30, width: 162, height: 115), radius: 16, light: true)
        let dot = NSBezierPath(ovalIn: NSRect(x: 291, y: 134, width: 3, height: 3)); GlassPalette.ink.withAlphaComponent(0.35).setFill(); dot.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
