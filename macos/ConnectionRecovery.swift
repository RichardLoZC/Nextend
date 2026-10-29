import Foundation

/// Owned by Session during teardown, then by the app until every resource has
/// actually stopped. A timeout ends the UI wait, not ownership of the resource.
final class ConnectionRecovery {
    private var checks: [@MainActor () -> Bool] = []
    @MainActor var isPending: Bool { !checks.isEmpty }
    @MainActor func waitUntil(_ released: @escaping @MainActor () -> Bool) { checks.append(released) }
    @MainActor @discardableResult func check() -> Bool {
        checks.removeAll { $0() }
        return checks.isEmpty
    }
}

/// Wi-Fi TCP recovery can take longer than three seconds even when decoding is healthy.
/// Keep a finite video deadline; socket and control liveness checks remain in force.
enum VideoLinkDeadline {
    static func nanoseconds(wireless: Bool) -> UInt64 { wireless ? 8_000_000_000 : 3_000_000_000 }
    static func expired(sentAt: UInt64, now: UInt64, wireless: Bool) -> Bool {
        now >= sentAt && now - sentAt > nanoseconds(wireless: wireless)
    }
}
