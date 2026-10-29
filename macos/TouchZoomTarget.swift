import AppKit
import ApplicationServices

/// A direct pinch must reach the window under its original contact point,
/// rather than whichever app happens to have keyboard focus on another screen.
/// All accessibility IPC runs on the bounded zoom worker, outside video handling.
struct TouchZoomTarget {
    let window: AXUIElement
    let application: NSRunningApplication
    private let appElement: AXUIElement

    static func resolve(at point: CGPoint) -> TouchZoomTarget? {
        let reader = Reader(budget: 0.12)
        let system = AXUIElementCreateSystemWide()
        guard reader.prepare(system) else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        let window: AXUIElement
        if let value = reader.attribute(hit, kAXWindowAttribute as CFString), CFGetTypeID(value) == AXUIElementGetTypeID() {
            window = value as! AXUIElement
        } else if reader.attribute(hit, kAXRoleAttribute as CFString) as? String == kAXWindowRole {
            window = hit
        } else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid > 0,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.activationPolicy == .regular else { return nil }
        return TouchZoomTarget(window: window, application: app, appElement: AXUIElementCreateApplication(pid))
    }
    /// Called with the input authorization lock held. Requests have a shared
    /// deadline so an unresponsive app cannot hold that lock indefinitely.
    func requestFocus() -> Bool {
        let reader = Reader(budget: 0.08)
        guard !application.isTerminated, reader.prepare(window),
              AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else { return false }
        if reader.prepare(window) { _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue) }
        return application.activate(options: [])
    }
    func isFocused() -> Bool {
        let reader = Reader(budget: 0.04)
        guard !application.isTerminated, application.isActive,
              let focused = reader.attribute(appElement, kAXFocusedWindowAttribute as CFString),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        return CFEqual(window, focused)
    }
    /// Application activation is asynchronous. Never wait on the capture/UI
    /// thread and never fall back to a global keyboard event if focus fails.
    func waitForFocus() -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.16
        repeat {
            if isFocused() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }
    private final class Reader {
        private let deadline: TimeInterval
        init(budget: TimeInterval) { deadline = ProcessInfo.processInfo.systemUptime + budget }
        func prepare(_ element: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            AXUIElementSetMessagingTimeout(element, Float(min(0.03, remaining)))
            return true
        }
        func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
            guard prepare(element) else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
            return value
        }
    }
}
