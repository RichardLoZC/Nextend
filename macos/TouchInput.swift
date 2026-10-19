import AppKit
import ApplicationServices

/// Only this small vocabulary can cross the authenticated input channel.
struct TouchPacket {
    enum Phase: String { case begin, end, click, rightclick, down, move, hover, up, cancel, scroll
        case spaceLeft = "space-left", spaceRight = "space-right", missionControl = "mission-control", appWindows = "app-windows", zoomIn = "zoom-in", zoomOut = "zoom-out" }
    let epoch: Int
    let phase: Phase
    let x: Double
    let y: Double
    let dx: Double
    let dy: Double

    init(_ json: [String: Any]) throws {
        func number(_ key: String) throws -> Double {
            guard let n = json[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite
            else { throw BridgeError("触屏消息无效。") }
            return n.doubleValue
        }
        let generation = try number("epoch")
        guard generation >= 1, generation <= Double(Int32.max), generation.rounded() == generation,
              let phase = Phase(rawValue: json["phase"] as? String ?? "") else { throw BridgeError("触屏消息无效。") }
        epoch = Int(generation); self.phase = phase
        if phase == .cancel { x = 0; y = 0 } else {
            x = try number("x"); y = try number("y")
            guard (0...1).contains(x), (0...1).contains(y) else { throw BridgeError("触屏消息无效。") }
        }
        if phase == .scroll || phase == .hover || (phase == .move && json["dx"] != nil) {
            dx = try number("dx"); dy = try number("dy")
            guard abs(dx) <= 1, abs(dy) <= 1 else { throw BridgeError("触屏消息无效。") }
        } else { dx = 0; dy = 0 }
    }
}

struct TouchEffect: Equatable {
    enum Kind { case down, move, hover, up, click, rightclick, scroll, spaceLeft, spaceRight, missionControl, appWindows, zoomIn, zoomOut }
    let kind: Kind
    let point: CGPoint
    var scroll: CGPoint = .zero
}

/// Pure state machine. Closing the local gate invalidates all in-flight events.
struct TouchGate {
    private(set) var epoch = 0
    private(set) var enabled = false
    private(set) var trackpad = false
    private(set) var pressed: CGPoint?
    private var relativePoint: CGPoint?
    mutating func setEnabled(_ value: Bool, trackpad: Bool = false) -> [TouchEffect] {
        let effects = release()
        relativePoint = nil; epoch += 1; enabled = value; self.trackpad = trackpad
        return effects
    }
    mutating func release() -> [TouchEffect] {
        guard let point = pressed else { return [] }
        pressed = nil
        return [TouchEffect(kind: .up, point: point)]
    }
    mutating func accept(_ packet: TouchPacket, bounds: CGRect, cursor: CGPoint = .zero, screens: [CGRect] = []) -> [TouchEffect] {
        guard enabled, packet.epoch == epoch else { return [] }
        guard !bounds.isNull, bounds.width >= 1, bounds.height >= 1,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite, bounds.width.isFinite, bounds.height.isFinite else { return release() }
        // CGDisplayBounds is in global desktop points (top-left origin), not
        // encoded pixels. Keep x/y=1 inside the display's exclusive far edge.
        var point = CGPoint(x: bounds.minX + packet.x * max(0, bounds.width - 1),
                            y: bounds.minY + packet.y * max(0, bounds.height - 1))
        if trackpad {
            if packet.phase == .begin { let effects = release(); relativePoint = cursor; return effects }
            point = relativePoint ?? cursor
            if packet.phase == .move || packet.phase == .hover {
                point = CGPoint(x: point.x + packet.dx * 1600, y: point.y + packet.dy * 1068)
            }
            if !screens.isEmpty {
                point = screens.map { CGRect -> CGPoint in
                    CGPoint(x: min(CGRect.maxX - 1, max(CGRect.minX, point.x)), y: min(CGRect.maxY - 1, max(CGRect.minY, point.y)))
                }.min(by: { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) }) ?? point
            }
            relativePoint = point
        }
        switch packet.phase {
        case .begin: return []
        case .end, .cancel: relativePoint = nil; return release()
        case .click, .rightclick:
            guard pressed == nil else { return [] }
            return [TouchEffect(kind: packet.phase == .rightclick ? .rightclick : .click, point: point)]
        case .hover:
            guard trackpad, pressed == nil else { return [] }
            return [TouchEffect(kind: .hover, point: point)]
        case .spaceLeft, .spaceRight, .missionControl, .appWindows, .zoomIn, .zoomOut:
            guard trackpad, pressed == nil else { return [] }
            let kind: TouchEffect.Kind
            switch packet.phase {
            case .spaceLeft: kind = .spaceLeft
            case .spaceRight: kind = .spaceRight
            case .missionControl: kind = .missionControl
            case .appWindows: kind = .appWindows
            case .zoomIn: kind = .zoomIn
            default: kind = .zoomOut
            }
            return [TouchEffect(kind: kind, point: point)]
        case .down:
            let previous = release(); pressed = point
            return previous + [TouchEffect(kind: .down, point: point)]
        case .move:
            guard pressed != nil else { return [] }
            pressed = point; return [TouchEffect(kind: .move, point: point)]
        case .up:
            guard pressed != nil else { return [] }
            pressed = nil; return [TouchEffect(kind: .up, point: point)]
        case .scroll:
            guard pressed == nil else { return [] }
            return [TouchEffect(kind: .scroll, point: point,
                                scroll: CGPoint(x: packet.dx * bounds.width, y: packet.dy * bounds.height))]
        }
    }
}

/// The lock makes the Mac switch and teardown synchronous authorization barriers.
/// No remote display IDs, global coordinates, key codes or modifiers are accepted.
/// Trackpad actions map only to the fixed shortcuts below.
final class TouchInputController: @unchecked Sendable {
    private let lock = NSLock()
    private var gate = TouchGate()
    private var displayID: CGDirectDisplayID?
    private let source = CGEventSource(stateID: .privateState)
    private var lastClick: (time: TimeInterval, point: CGPoint)?
    private var clickCount: Int64 = 0
    private var lastPacketTime = ProcessInfo.processInfo.systemUptime
    private var windowStart: TimeInterval = 0
    private var packetCount = 0
    func attach(display: CGDirectDisplayID) {
        lock.lock(); defer { lock.unlock() }; displayID = display
    }
    func setEnabled(_ value: Bool, trackpad: Bool = false) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        post(gate.setEnabled(value && displayID != nil && AXIsProcessTrusted(), trackpad: trackpad))
        lastClick = nil; clickCount = 0
        return ["type": "touch-mode", "epoch": gate.epoch, "enabled": gate.enabled, "mode": trackpad ? "trackpad" : "direct"]
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        post(gate.setEnabled(false)); displayID = nil
    }
    func receive(_ json: [String: Any]) throws {
        let packet = try TouchPacket(json)
        lock.lock(); defer { lock.unlock() }
        guard gate.enabled, packet.epoch == gate.epoch else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - windowStart >= 1 { windowStart = now; packetCount = 0 }
        packetCount += 1
        guard packetCount <= 500 else { post(gate.setEnabled(false)); throw BridgeError("触屏消息过于频繁。") }
        guard AXIsProcessTrusted(), let id = displayID, CGDisplayIsActive(id) != 0, CGDisplayIsInMirrorSet(id) == 0 else {
            post(gate.setEnabled(false)); throw BridgeError("触屏权限或拓展屏已不可用。")
        }
        lastPacketTime = now
        var ids = [CGDirectDisplayID](repeating: 0, count: 32); var count: UInt32 = 0
        CGGetActiveDisplayList(32, &ids, &count)
        let screens = ids.prefix(Int(count)).map { CGDisplayBounds($0) }.filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
        post(gate.accept(packet, bounds: CGDisplayBounds(id), cursor: CGEvent(source: nil)?.location ?? .zero, screens: screens))
    }
    /// A lost UP must not leave a button held during a half-open connection.
    func checkLiveness() {
        lock.lock(); defer { lock.unlock() }
        if gate.pressed != nil && ProcessInfo.processInfo.systemUptime - lastPacketTime > 2 { post(gate.release()) }
    }
    private func post(_ effects: [TouchEffect]) {
        func mouse(_ type: CGEventType, _ point: CGPoint, clicks: Int64 = 1, button: CGMouseButton = .left) {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            event?.flags = []; event?.setIntegerValueField(.mouseEventClickState, value: clicks)
            event?.post(tap: .cghidEventTap)
        }
        func shortcut(_ key: CGKeyCode, flags: CGEventFlags) {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
                event?.flags = flags; event?.post(tap: .cghidEventTap)
            }
        }
        for effect in effects {
            switch effect.kind {
            case .down: lastClick = nil; mouse(.leftMouseDown, effect.point)
            case .hover: mouse(.mouseMoved, effect.point, clicks: 0)
            case .rightclick: lastClick = nil; mouse(.rightMouseDown, effect.point, button: .right); mouse(.rightMouseUp, effect.point, button: .right)
            case .spaceLeft: shortcut(123, flags: .maskControl)
            case .spaceRight: shortcut(124, flags: .maskControl)
            case .missionControl: shortcut(126, flags: .maskControl)
            case .appWindows: shortcut(125, flags: .maskControl)
            case .zoomIn: shortcut(24, flags: .maskCommand)
            case .zoomOut: shortcut(27, flags: .maskCommand)
            case .move: mouse(.leftMouseDragged, effect.point)
            case .up: mouse(.leftMouseUp, effect.point)
            case .click:
                let now = ProcessInfo.processInfo.systemUptime
                if let previous = lastClick, now - previous.time <= NSEvent.doubleClickInterval,
                   hypot(previous.point.x - effect.point.x, previous.point.y - effect.point.y) < 8 {
                    clickCount = clickCount == 1 ? 2 : 1
                } else { clickCount = 1 }
                mouse(.leftMouseDown, effect.point, clicks: clickCount); mouse(.leftMouseUp, effect.point, clicks: clickCount)
                lastClick = (now, effect.point)
            case .scroll:
                mouse(.mouseMoved, effect.point, clicks: 0)
                // Match the Mac's natural-scrolling preference. Quartz wheel
                // deltas have the opposite sign to finger displacement.
                let natural = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
                let direction = natural ? -1.0 : 1.0
                let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                    wheel1: Int32((effect.scroll.y * direction).rounded()), wheel2: Int32((effect.scroll.x * direction).rounded()), wheel3: 0)
                event?.location = effect.point; event?.flags = []; event?.post(tap: .cghidEventTap)
            }
        }
    }
}
