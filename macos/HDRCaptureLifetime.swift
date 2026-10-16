import CoreGraphics
import Foundation

/// A started CGDisplayStream must remain alive until its final .stopped callback.
/// The callback retains this token; the token retains the stream while active.
/// Even a failed/timed-out stop cannot free a stream that may still call back.
final class HDRCaptureLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var retainedStream: CGDisplayStream?
    private var stopped = false
    private var waiter: CheckedContinuation<Bool, Never>?
    func retainUntilStopped(_ stream: CGDisplayStream) {
        lock.lock(); retainedStream = stream; lock.unlock()
    }
    func didStop() {
        lock.lock(); stopped = true; retainedStream = nil
        let pending = waiter; waiter = nil; lock.unlock()
        pending?.resume(returning: true)
    }
    func didFailToStart() { didStop() }
    private func finishWait(_ success: Bool) {
        lock.lock(); let pending = waiter; waiter = nil; lock.unlock()
        pending?.resume(returning: success)
    }
    func stop(_ stream: CGDisplayStream) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if stopped { lock.unlock(); continuation.resume(returning: true); return }
            waiter = continuation; lock.unlock()
            if stream.stop() != .success { finishWait(false); return }
            // Permit UI/ADB teardown to finish even if a macOS driver fails to
            // acknowledge stop. didStop still owns the retained stream release.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { self.finishWait(false) }
        }
    }
}
