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
