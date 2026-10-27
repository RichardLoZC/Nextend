import AppKit
import ApplicationServices
import ScreenCaptureKit

struct PadNotch: Equatable {
    var enabled = false
    var left = 0.44
    var right = 0.56
    var depth = 0.035
    // Guides are session UI state: reopening the app never leaves red lines on.
    var guides = false
    var normalized: Self {
        var result = self
        result.left = left.isFinite ? min(0.88, max(0.02, left)) : 0.44
        result.right = right.isFinite ? min(0.96, max(result.left + 0.02, right)) : max(0.56, result.left + 0.02)
        result.depth = depth.isFinite ? min(0.15, max(0.01, depth)) : 0.035
        return result
    }
    static func load() -> Self {
        let d = UserDefaults.standard
        return Self(enabled: d.bool(forKey: "pad.notch.enabled"),
                    left: d.object(forKey: "pad.notch.left") as? Double ?? 0.44,
                    right: d.object(forKey: "pad.notch.right") as? Double ?? 0.56,
                    depth: d.object(forKey: "pad.notch.depth") as? Double ?? 0.035).normalized
    }
    func save() {
        let n = normalized, d = UserDefaults.standard
        d.set(n.enabled, forKey: "pad.notch.enabled"); d.set(n.left, forKey: "pad.notch.left")
        d.set(n.right, forKey: "pad.notch.right"); d.set(n.depth, forKey: "pad.notch.depth")
    }
    func foldFrame(in screen: CGRect, barHeight: CGFloat) -> CGRect {
        let n = normalized
        return CGRect(x: min(screen.maxX - 30, screen.minX + screen.width * n.right + 6), y: screen.minY, width: 28, height: barHeight)
    }
    func hidden(_ frames: [CGRect], in screen: CGRect, barHeight: CGFloat) -> [Int] {
        let edge = foldFrame(in: screen, barHeight: barHeight).maxX + 2
        return frames.indices.filter { i in
            let f = frames[i]
            return !f.isEmpty && f.minX < edge && f.midX >= screen.minX && f.midX < screen.maxX &&
                f.minY >= screen.minY - 2 && f.minY < screen.minY + barHeight && f.maxY <= screen.minY + barHeight + 4
        }
    }
}

@MainActor private final class NotchGuidesView: NSView {
    var notch = PadNotch() { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let n = notch.normalized
        let left = bounds.width * n.left, right = bounds.width * n.right
        let band = NSRect(x: left, y: bounds.height * (1 - n.depth), width: right - left, height: bounds.height * n.depth)
        NSColor.systemRed.withAlphaComponent(0.15).setFill(); band.fill()
        for (x, label) in [(left, L("左边界", "Left edge")), (right, L("右边界", "Right edge"))] {
            let path = NSBezierPath(); path.move(to: NSPoint(x: x, y: 0)); path.line(to: NSPoint(x: x, y: bounds.height))
            NSColor.black.withAlphaComponent(0.7).setStroke(); path.lineWidth = 3; path.stroke()
            NSColor.systemRed.setStroke(); path.lineWidth = 1.5; path.stroke()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.8)]
            (label as NSString).draw(at: NSPoint(x: x + 7, y: bounds.height * 0.72), withAttributes: attrs)
        }
    }
}

@MainActor private final class NotchPanel: NSPanel {
    var acceptsKeys = false
    override var canBecomeKey: Bool { acceptsKeys }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class MenuCoverView: NSView {
    var background: CGImage? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        if let background, let context = NSGraphicsContext.current?.cgContext {
            context.draw(background, in: bounds)
        } else { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
    }
}

/// Owns only panels on the session's virtual display. Main-display menu items
/// and their system ordering are never changed.
@MainActor final class PadNotchController: NSObject {
    private let displayID: CGDirectDisplayID
    private var value = PadNotch()
    private let guides = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let guideView = NotchGuidesView()
    private let bar = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let barBackground = MenuCoverView()
    private var covers: [NotchPanel] = []
    private let fold = NSButton()
    private let drawer = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var timer: Timer?
    private var refreshing = false
    private var capturing = false
    private var opening = false
    private var drawerRequest = 0
    private var selectionRequest = 0
    private var selecting = false
    private var closed = false
    private var generation = 0
    private var items: [PadMenuBarItem] = []
    private var hiddenItems: [PadMenuBarItem] = []
    private var drawerItems: [PadMenuBarItem] = []
    private var inventoryBounds = CGRect.zero
    private var image: CGImage?
    private var imageBounds = CGRect.zero
    private var imageItems: [PadMenuBarItem] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var buttons: [NSButton] = []
    private let reader = DispatchQueue(label: "Nextend.menu-bar-reader", qos: .utility)
    var status: String {
        if !value.enabled { return L("对齐两条红线后，开启菜单栏图标折叠。", "Align the two red lines, then enable menu-bar folding.") }
        if !AXIsProcessTrusted() { return L("折叠图标需要辅助功能权限；校准线仍可使用。", "Menu-bar folding needs Accessibility access. Calibration remains available.") }
        return L("点击 Pad 刘海右侧的 « 展开图标。", "Click « to the right of the Pad cutout to expand icons.")
    }
    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        super.init()
        for panel in [guides, bar, drawer] {
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            panel.hasShadow = false
        }
        guides.ignoresMouseEvents = true; guides.contentView = guideView
        bar.contentView = barBackground
        fold.isBordered = false; fold.imagePosition = .imageOnly; setFoldExpanded(false)
        fold.target = self; fold.action = #selector(toggleDrawer)
        fold.setAccessibilityLabel(L("展开刘海遮挡的菜单栏图标", "Show menu-bar icons hidden by the cutout"))
        barBackground.addSubview(fold)
        drawer.acceptsKeys = true; drawer.title = L("菜单栏图标", "Menu-bar icons")
        drawer.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1); drawer.hasShadow = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelInteraction() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .keyDown && event.keyCode == 53 { self?.cancelInteraction() }
                else if event.window !== self?.drawer && event.window !== self?.bar { self?.cancelInteraction() }
            }
            return event
        }
    }
    private var screen: NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }
    }
    private var barHeight: CGFloat {
        let top = CGDisplayBounds(displayID).minY
        let measured = items.map { $0.frame.maxY - top }.filter { $0 >= 20 && $0 <= 80 }.max() ?? 30
        return max(measured, min(80, screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 30))
    }
    func update(_ notch: PadNotch) {
        guard !closed else { return }
        value = notch.normalized; generation += 1; hideDrawer(); layout(); refresh()
    }
    private func layout() {
        guard !closed, CGDisplayIsActive(displayID) != 0, CGDisplayIsInMirrorSet(displayID) == 0, let screen else { guides.orderOut(nil); hideBar(); hideDrawer(); return }
        if value.guides {
            guides.setFrame(screen.frame, display: false); guideView.notch = value; guides.orderFrontRegardless()
        } else { guides.orderOut(nil) }
        guard value.enabled, AXIsProcessTrusted(), !selecting else { hideBar(); hideDrawer(); return }
        let cg = CGDisplayBounds(displayID), h = barHeight
        if cg != inventoryBounds { items = []; image = nil; inventoryBounds = cg; hideDrawer() }
        guard !items.isEmpty else { hideBar(); hideDrawer(); return }
        var button = value.foldFrame(in: cg, barHeight: h)
        // At extreme calibrations the reserved position may collide with a
        // system indicator. Put the control below the bar instead of covering it.
        if items.contains(where: { $0.system && $0.frame.intersects(button) }) {
            button.origin.y = cg.minY + max(h, cg.height * value.depth) + 4
        }
        // Recording, microphone, battery, Wi-Fi and other system indicators
        // remain native. Only application icons enter the Nextend drawer.
        hiddenItems = value.hidden(items.map(\.frame), in: cg, barHeight: h).map { items[$0] }.filter { !$0.system }
        let rect = NSRect(x: button.minX, y: screen.frame.maxY - (button.minY - cg.minY) - h, width: button.width, height: h)
        bar.setFrame(rect, display: true)
        fold.frame = NSRect(x: 0, y: 0, width: button.width, height: h)
        fold.toolTip = L("展开 \(hiddenItems.count) 个菜单栏图标", "Show \(hiddenItems.count) menu-bar icons")
        while covers.count > hiddenItems.count { covers.removeLast().close() }
        while covers.count < hiddenItems.count {
            let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.hasShadow = false
            panel.collectionBehavior = bar.collectionBehavior; panel.level = bar.level
            panel.contentView = MenuCoverView(); covers.append(panel)
        }
        for (cover, item) in zip(covers, hiddenItems) {
            cover.setFrame(NSRect(x: item.frame.minX, y: screen.frame.maxY - h, width: item.frame.width, height: h), display: true)
            (cover.contentView as? MenuCoverView)?.background = barBackground.background
            cover.orderFrontRegardless()
        }
        // The fold button is above any application icon crossing its boundary.
        bar.orderFrontRegardless()
    }
    private func refresh() {
        guard !closed else { return }
        layout()
        guard value.enabled, AXIsProcessTrusted(), !refreshing, !opening, !selecting, !drawer.isVisible, let screen else { return }
        refreshing = true
        let bounds = CGDisplayBounds(displayID), revision = generation, screenID = displayID
        reader.async { [weak self] in
            let items = PadMenuBarInventory.read(display: bounds)
            Task { @MainActor [weak self] in
                guard let self else { return }; self.refreshing = false
                guard !self.closed, self.generation == revision, self.displayID == screenID else { return }
                guard !self.drawer.isVisible, !self.opening, !self.selecting,
                      CGDisplayBounds(screenID) == bounds else { return }
                if !PadMenuBarInventory.sameLayout(self.imageItems, items) { self.image = nil }
                self.items = items; self.layout()
            }
        }
        // ScreenCaptureKit excludes our panels, so thumbnails contain the real
        // status icons even while the folded strip covers them on the display.
        guard !capturing else { return }; capturing = true
        let height = barHeight, scale = screen.backingScaleFactor, capturedItems = items
        Task { [weak self] in
            guard let self else { return }
            defer { self.capturing = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard !self.closed, self.generation == revision,
                      let target = content.displays.first(where: { $0.displayID == screenID }) else { return }
                let own = Set([self.bar.windowNumber, self.guides.windowNumber, self.drawer.windowNumber] + self.covers.map(\.windowNumber))
                let excluded = content.windows.filter { own.contains(Int($0.windowID)) }
                let config = SCStreamConfiguration(); config.width = Int(bounds.width * scale); config.height = Int(height * scale)
                config.sourceRect = CGRect(x: 0, y: 0, width: bounds.width, height: height)
                config.showsCursor = false
                let shot = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: target, excludingWindows: excluded), configuration: config)
                let verifiedItems = await withCheckedContinuation { continuation in
                    self.reader.async { continuation.resume(returning: PadMenuBarInventory.read(display: bounds)) }
                }
                guard !self.closed, self.generation == revision, CGDisplayBounds(screenID) == bounds,
                      PadMenuBarInventory.sameLayout(capturedItems, verifiedItems),
                      PadMenuBarInventory.sameLayout(capturedItems, self.items) else { return }
                self.imageItems = capturedItems
                self.image = shot; self.imageBounds = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: height)
                // Sample the blank strip immediately before the native extras
                // bar. Repeating its vertical gradient removes icon silhouettes
                // without introducing an opaque gray block over the wallpaper.
                if let first = self.items.map({ $0.frame.minX }).min() {
                    let x = max(0, min(CGFloat(shot.width) - 4, (first - bounds.minX - 8) * scale))
                    self.barBackground.background = shot.cropping(to: CGRect(x: x, y: 0, width: 3, height: CGFloat(shot.height)))
                    if let background = self.barBackground.background,
                       let color = NSBitmapImageRep(cgImage: background).colorAt(x: 0, y: background.height / 2)?.usingColorSpace(.sRGB) {
                        let brightness = color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722
                        self.fold.contentTintColor = brightness > 0.45 ? .black : .white
                    }
                    for cover in self.covers { (cover.contentView as? MenuCoverView)?.background = self.barBackground.background }
                }
            } catch { /* Native app icons remain available when thumbnails fail. */ }
        }
    }
    @objc private func toggleDrawer() {
        if drawer.isVisible || opening { hideDrawer(); return }
        guard !closed, value.enabled, !selecting, screen != nil, AXIsProcessTrusted() else { return }
        opening = true; drawerRequest += 1
        let request = drawerRequest, revision = generation, bounds = CGDisplayBounds(displayID)
        reader.async { [weak self] in
            let current = PadMenuBarInventory.read(display: bounds)
            Task { @MainActor [weak self] in
                guard let self, self.drawerRequest == request else { return }
                self.opening = false
                guard !self.closed, self.generation == revision, self.value.enabled,
                      CGDisplayBounds(self.displayID) == bounds else { return }
                if !PadMenuBarInventory.sameLayout(self.imageItems, current) { self.image = nil }
                self.items = current; self.layout()
                guard self.bar.isVisible else { return }
                self.showDrawer()
            }
        }
    }
    private func showDrawer() {
        guard let screen else { return }
        drawerItems = hiddenItems
        let material = NSVisualEffectView(); material.material = .hudWindow; material.state = .active
        material.appearance = NSAppearance(named: .darkAqua)
        material.wantsLayer = true; material.layer?.cornerRadius = 12; material.layer?.masksToBounds = true
        buttons.removeAll()
        let columns = min(8, max(1, hiddenItems.count)), rows = max(1, (hiddenItems.count + columns - 1) / columns)
        let width = hiddenItems.isEmpty ? 330.0 : CGFloat(columns) * 44 + 20
        let height = hiddenItems.isEmpty ? 56.0 : CGFloat(rows) * 44 + 20
        for (index, item) in hiddenItems.enumerated() {
            let button = NSButton(frame: NSRect(x: 10 + CGFloat(index % columns) * 44, y: height - 10 - CGFloat(index / columns + 1) * 44, width: 44, height: 44))
            button.image = thumbnail(item) ?? NSRunningApplication(processIdentifier: item.pid)?.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: item.title)
            button.contentTintColor = .white
            button.imageScaling = .scaleProportionallyDown; button.imagePosition = .imageOnly; button.isBordered = false
            button.toolTip = item.title; button.setAccessibilityLabel(item.title); button.tag = index
            button.target = self; button.action = #selector(selectItem(_:)); material.addSubview(button); buttons.append(button)
        }
        if hiddenItems.isEmpty {
            let label = NSTextField(wrappingLabelWithString: L("暂无被遮挡图标。先点击 Pad 桌面，再展开此栏。", "No hidden icons. Click the Pad desktop, then reopen this bar."))
            label.frame = NSRect(x: 14, y: 10, width: width - 28, height: 36); label.font = .systemFont(ofSize: 12); material.addSubview(label)
        }
        drawer.contentView = material
        let x = min(screen.frame.maxX - width - 8, max(screen.frame.minX + 8, screen.frame.minX + screen.frame.width * value.right - width / 2))
        let top = screen.frame.maxY - max(barHeight, screen.frame.height * value.depth) - 8
        drawer.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
        setFoldExpanded(true); drawer.makeKeyAndOrderFront(nil)
        if let first = buttons.first { drawer.makeFirstResponder(first) }
    }
    private func thumbnail(_ item: PadMenuBarItem) -> NSImage? {
        guard let image, imageBounds.width > 0 else { return nil }
        let sx = CGFloat(image.width) / imageBounds.width, sy = CGFloat(image.height) / imageBounds.height
        let f = item.frame.intersection(imageBounds)
        guard !f.isNull, let crop = image.cropping(to: CGRect(x: (f.minX - imageBounds.minX) * sx, y: (f.minY - imageBounds.minY) * sy, width: f.width * sx, height: f.height * sy)) else { return nil }
        // Extract the original symbol from its menu-bar background. Inactive
        // displays dim their icons; a template restores contrast in the drawer.
        let input = NSBitmapImageRep(cgImage: crop)
        guard let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: crop.width, pixelsHigh: crop.height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let background = input.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else {
            return NSImage(cgImage: crop, size: f.size)
        }
        var symbolPixels = 0
        for y in 0..<crop.height { for x in 0..<crop.width {
            guard let c = input.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let background = input.colorAt(x: 0, y: y)?.usingColorSpace(.deviceRGB) ?? background
            let difference = max(abs(c.redComponent - background.redComponent), abs(c.greenComponent - background.greenComponent), abs(c.blueComponent - background.blueComponent))
            let alpha = min(1, max(0, difference - 0.035) * 5)
            if alpha > 0.15 { symbolPixels += 1 }
            output.setColor(NSColor(deviceRed: 1, green: 1, blue: 1, alpha: alpha), atX: x, y: y)
        } }
        guard symbolPixels >= 8 else { return nil }
        let result = NSImage(size: CGSize(width: min(34, f.width), height: min(32, f.height))); result.addRepresentation(output); result.isTemplate = true
        return result
    }
    @objc private func selectItem(_ sender: NSButton) {
        guard drawerItems.indices.contains(sender.tag), !closed, value.enabled, !selecting, AXIsProcessTrusted() else { return }
        let selected = drawerItems[sender.tag]; hideDrawer()
        // AXPress can succeed without opening macOS 27's remote status menu.
        // Hide our panels first, then re-resolve this exact AX item and hit-test
        // its current position. Ambiguous or changed targets are never clicked.
        selecting = true; selectionRequest += 1; hideBar()
        let request = selectionRequest, revision = generation, bounds = CGDisplayBounds(displayID)
        reader.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            let point = PadMenuBarInventory.clickPoint(for: selected, display: bounds)
            let checkedAt = ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak self] in
                guard let self, self.selectionRequest == request else { return }
                guard !self.closed, self.value.enabled, self.generation == revision,
                      AXIsProcessTrusted(), CGDisplayIsActive(self.displayID) != 0,
                      CGDisplayIsInMirrorSet(self.displayID) == 0, CGDisplayBounds(self.displayID) == bounds,
                      ProcessInfo.processInfo.systemUptime - checkedAt < 0.1, let point, bounds.contains(point) else {
                    self.selecting = false; self.refresh(); return
                }
                let source = CGEventSource(stateID: .privateState)
                for type: CGEventType in [.mouseMoved, .leftMouseDown, .leftMouseUp] {
                    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { continue }
                    event.setIntegerValueField(.mouseEventClickState, value: 1); event.post(tap: .cghidEventTap)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, self.selectionRequest == request else { return }
                    self.selecting = false; self.refresh()
                }
            }
        }
    }
    private func setFoldExpanded(_ expanded: Bool) {
        fold.image = NSImage(systemSymbolName: expanded ? "chevron.right.2" : "chevron.left.2", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
    }
    private func cancelInteraction() {
        hideDrawer()
        if selecting { selectionRequest += 1; selecting = false; layout() }
    }
    private func hideBar() { bar.orderOut(nil); covers.forEach { $0.orderOut(nil) } }
    private func hideDrawer() { drawerRequest += 1; opening = false; drawer.orderOut(nil); setFoldExpanded(false) }
    func close() {
        guard !closed else { return }; closed = true; generation += 1
        timer?.invalidate(); timer = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        guides.close(); bar.close(); drawer.close(); covers.forEach { $0.close() }; covers = []
        items = []; hiddenItems = []; drawerItems = []; image = nil
    }
    deinit { timer?.invalidate() }
}
