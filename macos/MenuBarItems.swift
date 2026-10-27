import AppKit
import ApplicationServices

/// Read only menu-bar elements. Never walk application windows or menu contents.
struct PadMenuBarItem: @unchecked Sendable {
    let element: AXUIElement
    let frame: CGRect // Global Core Graphics points, top-left origin.
    let title: String
    let pid: pid_t
    var system: Bool = false
    func hasSameElement(as other: Self) -> Bool { pid == other.pid && CFEqual(element, other.element) }
    var identity: String { "\(pid):\(Int(frame.minX.rounded())):\(title)" }
}

enum PadMenuBarInventory {
    static func sameLayout(_ lhs: [PadMenuBarItem], _ rhs: [PadMenuBarItem]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { a, b in
            a.hasSameElement(as: b) && a.frame == b.frame && a.system == b.system
        }
    }
    static func uniqueMatch(_ selected: PadMenuBarItem, in items: [PadMenuBarItem]) -> PadMenuBarItem? {
        let matches = items.filter { !$0.system && $0.hasSameElement(as: selected) }
        return matches.count == 1 ? matches[0] : nil
    }
    static func read(display: CGRect) -> [PadMenuBarItem] { Reader().read(display: display) }
    /// Hit-testing is done only after our panels are hidden. macOS 27 can
    /// return the owning application's AXMenuBar rather than its status item.
    static func clickPoint(for selected: PadMenuBarItem, display: CGRect) -> CGPoint? {
        let reader = Reader()
        guard let item = uniqueMatch(selected, in: reader.read(display: display)) else { return nil }
        let point = CGPoint(x: item.frame.midX, y: item.frame.midY)
        let root = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(root, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        var pid: pid_t = 0; AXUIElementGetPid(hit, &pid)
        let role = reader.string(hit, kAXRoleAttribute)
        let hitFrame = reader.frame(hit)
        // AppKit status items can hit-test as their tiny AXWindow. Accept it
        // only when its frame matches the verified item (allow its 1 pt border).
        let statusWindow = role == kAXWindowRole && (hitFrame.map {
            abs($0.minX - item.frame.minX) < 1 && abs($0.minY - item.frame.minY) < 1 &&
            abs($0.width - item.frame.width) < 1 && abs($0.height - item.frame.height) <= 2
        } ?? false)
        guard pid == item.pid, (CFEqual(hit, item.element) || statusWindow ||
                [kAXMenuBarRole, kAXMenuBarItemRole, kAXButtonRole].contains(role)),
              let currentFrame = reader.frame(item.element), currentFrame == item.frame else { return nil }
        return point
    }
    /// A timeout belongs to one AX object, not its descendants. Limit every
    /// request and the entire traversal, which always runs off the main thread.
    private final class Reader {
        private let deadline = ProcessInfo.processInfo.systemUptime + 0.65
        private var timedOut = false
        private func prepare(_ element: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { timedOut = true; return false }
            AXUIElementSetMessagingTimeout(element, Float(min(0.05, remaining)))
            return true
        }
        fileprivate func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
            guard prepare(element) else { return nil }
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name, &result) == .success else { return nil }
            return result
        }
        private func children(_ element: AXUIElement) -> [AXUIElement] {
            Array((attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []).prefix(100))
        }
        fileprivate func string(_ element: AXUIElement, _ name: String) -> String {
            attribute(element, name as CFString) as? String ?? ""
        }
        fileprivate func frame(_ element: AXUIElement) -> CGRect? {
            guard let p = attribute(element, kAXPositionAttribute as CFString), CFGetTypeID(p) == AXValueGetTypeID(),
                  let s = attribute(element, kAXSizeAttribute as CFString), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
                  point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else { return nil }
            return CGRect(origin: point, size: size)
        }
        private func pressable(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
            let role = string(element, kAXRoleAttribute)
            // An AXApplication under MenuBarAgent is a remote host, not a menu item.
            guard role != kAXApplicationRole, depth <= 2 else { return nil }
            // Prefer the named leaf over an anonymous pressable AXGroup.
            if role == kAXGroupRole || role.isEmpty {
                for child in children(element) { if let result = pressable(child, depth: depth + 1) { return result } }
            }
            guard prepare(element) else { return nil }
            var actions: CFArray?
            if AXUIElementCopyActionNames(element, &actions) == .success,
               (actions as? [String] ?? []).contains(kAXPressAction) { return element }
            for child in children(element) { if let result = pressable(child, depth: depth + 1) { return result } }
            return nil
        }
        private func belongs(_ frame: CGRect, to display: CGRect) -> Bool {
            frame.width < display.width / 2 && frame.height <= 90 &&
            frame.minY >= display.minY - 2 && frame.minY <= display.minY + 40 &&
            frame.midX >= display.minX && frame.midX < display.maxX
        }
        func read(display: CGRect) -> [PadMenuBarItem] {
            guard AXIsProcessTrusted() else { return [] }
            let apps = NSWorkspace.shared.runningApplications
            var result: [PadMenuBarItem] = []
            if let agent = apps.first(where: { $0.bundleIdentifier == "com.apple.MenuBarAgent" }) {
                let root = AXUIElementCreateApplication(agent.processIdentifier)
                AXUIElementSetMessagingTimeout(root, 0.15)
                // macOS 27 exposes hosting and presentation trees for the same bar.
                // Join their immediate children by their native positions.
                var hosts: [(CGRect, String, pid_t)] = []
                var wrappers: [AXUIElement] = []
                for window in children(root) where string(window, kAXRoleAttribute) == kAXWindowRole {
                    guard let w = frame(window), w.width > display.width * 0.8,
                          abs(w.minX - display.minX) < 2, abs(w.minY - display.minY) < 2, w.height < 90 else { continue }
                    for item in children(window) {
                        guard let f = frame(item), belongs(f, to: display) else { continue }
                        wrappers.append(item)
                        for child in children(item) where string(child, kAXRoleAttribute) == kAXApplicationRole {
                            var pid: pid_t = 0; AXUIElementGetPid(child, &pid)
                            hosts.append((f, string(child, kAXTitleAttribute), pid))
                        }
                    }
                }
                for wrapper in wrappers {
                    guard let f = frame(wrapper), let action = pressable(wrapper) else { continue }
                    var pid: pid_t = 0; AXUIElementGetPid(action, &pid)
                    let host = hosts.first { abs($0.0.minX - f.minX) < 2 && abs($0.0.width - f.width) < 3 && ($0.2 == pid || pid == agent.processIdentifier) }
                    let description = string(action, kAXDescriptionAttribute)
                    let sourcePID = host?.2 ?? pid
                    let bundle = NSRunningApplication(processIdentifier: sourcePID)?.bundleIdentifier ?? ""
                    let system = sourcePID == agent.processIdentifier ||
                        ["com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.Siri", "com.apple.TextInputMenuAgent"].contains(bundle)
                    // The hosting tree disappears when this display becomes active.
                    // The leaf still belongs to the original application's process.
                    let title = system ? (!description.isEmpty ? description : string(action, kAXTitleAttribute))
                        : (NSRunningApplication(processIdentifier: sourcePID)?.localizedName ?? host?.1 ?? description)
                    result.append(PadMenuBarItem(element: action, frame: f, title: title.isEmpty ? "Menu item" : title, pid: sourcePID, system: system))
                }
            } else {
                // Earlier macOS versions expose each application's own extras bar.
                for app in apps where app.activationPolicy != .prohibited || app.bundleIdentifier == "com.apple.controlcenter" {
                    let root = AXUIElementCreateApplication(app.processIdentifier)
                    AXUIElementSetMessagingTimeout(root, 0.10)
                    guard let bar = attribute(root, kAXExtrasMenuBarAttribute as CFString), CFGetTypeID(bar) == AXUIElementGetTypeID() else { continue }
                    for item in children(bar as! AXUIElement) {
                        guard let f = frame(item), belongs(f, to: display), let action = pressable(item) else { continue }
                        let title = string(action, kAXDescriptionAttribute)
                        result.append(PadMenuBarItem(element: action, frame: f, title: title.isEmpty ? (app.localizedName ?? "Menu item") : title, pid: app.processIdentifier, system: app.bundleIdentifier == "com.apple.controlcenter" || app.bundleIdentifier == "com.apple.systemuiserver"))
                    }
                }
            }
            var seen = Set<String>()
            guard !timedOut else { return [] }
            return result.filter { seen.insert($0.identity).inserted }.sorted { $0.frame.minX < $1.frame.minX }
        }
}
}
