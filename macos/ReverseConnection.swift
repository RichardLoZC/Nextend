import Foundation
import Darwin

/// Exactly one owner closes an accepted descriptor, including failed handoffs.
final class ConnectedSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    func take() throws -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { throw BridgeError("连接已取消。") }
        let value = fd; fd = -1; return value
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd); fd = -1 }
    }
    deinit { close() }
}

/// One local Connect action may accept one authenticated outbound Pad socket.
/// Idle polls never create a session. Timeout closes this slot before fallback.
final class ReverseConnectionWaiter: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: ConnectedSocket?
    private var reserved = false
    private var finished = false
    private var cancelled = false
    var isWaiting: Bool {
        condition.lock(); defer { condition.unlock() }
        return !finished && pending == nil && !reserved
    }
    /// Reserve before sending the ACK. A deadline cannot switch to direct TCP
    /// while the Pad is already being told to use this socket for video.
    func reserve() -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !finished, pending == nil, !reserved else { return false }
        reserved = true; return true
    }
    @discardableResult func offer(_ socket: ConnectedSocket) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !finished, pending == nil, reserved else { socket.close(); return false }
        reserved = false; pending = socket; condition.broadcast(); return true
    }
    func take(timeout: TimeInterval = 8) throws -> ConnectedSocket? {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while pending == nil && !finished {
            if reserved { condition.wait() }
            else if !condition.wait(until: deadline), !reserved { break }
        }
        finished = true
        if cancelled { throw CancellationError() }
        let socket = pending; pending = nil; return socket
    }
    func cancel() {
        condition.lock(); defer { condition.unlock() }
        cancelled = true; finished = true; pending?.close(); pending = nil; condition.broadcast()
    }
    deinit { cancel() }
}

struct ConnectRequestDecision {
    let accepted: Bool
    let reverse: ReverseConnectionWaiter?
    static let rejected = ConnectRequestDecision(accepted: false, reverse: nil)
}
