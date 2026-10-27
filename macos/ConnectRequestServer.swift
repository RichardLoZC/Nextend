import Foundation
import Darwin

/// A request selects no settings. Only the paired key can ask the GUI to run its
/// existing Connect action. The TCP source is the sole Wi-Fi callback address.
final class ConnectRequestServer: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var listening: Int32 = -1
    private var client: Int32 = -1
    private var service: NetService?
    private var usbTimer: DispatchSourceTimer?
    private var reverseSerial: String?
    @MainActor private var enabled = false
    @MainActor private var retryTask: Task<Void, Never>?
    @MainActor private var retryAttempt = 0
    private let port: UInt16
    private let advertise: Bool
    private let onStatus: @MainActor (AppMessage?) -> Void
    private var hasListener: Bool { lock.lock(); defer { lock.unlock() }; return listening >= 0 }
    var isListening: Bool { lock.lock(); defer { lock.unlock() }; return running }
    private let handler: @MainActor (String, String) -> ConnectRequestDecision
    init(port: UInt16 = 49372, advertise: Bool = true,
         onStatus: @escaping @MainActor (AppMessage?) -> Void = { _ in },
         handler: @escaping @MainActor (String, String) -> ConnectRequestDecision) {
        self.port = port; self.advertise = advertise; self.onStatus = onStatus; self.handler = handler
    }
    @MainActor func start() {
        guard !enabled else { return }
        enabled = true; openListener()
    }
    @MainActor private func retry(_ error: Int32) {
        guard enabled else { return }
        service?.stop(); service = nil; usbTimer?.cancel(); usbTimer = nil
        retryTask?.cancel()
        let delay = min(30, 1 << min(retryAttempt, 5)); retryAttempt += 1
        onStatus("Pad 连接请求服务暂不可用，正在自动重试（错误 \(error)）。")
        retryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.enabled else { return }
            self.openListener()
        }
    }
    @MainActor private func openListener() {
        guard enabled, !hasListener else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { retry(errno); return }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_port = port.bigEndian
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0, listen(fd, 4) == 0 else { let error = errno; Darwin.close(fd); retry(error); return }
        lock.lock(); listening = fd; running = true; lock.unlock()
        retryAttempt = 0; retryTask = nil; onStatus(nil)
        if advertise {
            let advertisement = NetService(domain: "local.", type: "_nextend._tcp.", name: Host.current().localizedName ?? "Nextend Mac", port: Int32(port))
            advertisement.publish(); service = advertisement
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "Nextend.usb-request"))
            timer.schedule(deadline: .now(), repeating: 5)
            timer.setEventHandler { [weak self] in self?.prepareUSB() }; timer.resume(); usbTimer = timer
        }
        DispatchQueue.global(qos: .utility).async { self.acceptLoop(fd) }
    }
    private var alive: Bool { lock.lock(); defer { lock.unlock() }; return running }
    private func prepareUSB() {
        guard alive, let serial = try? ADB.usbDevice() else { return }
        guard let result = try? ADB.run(["-s", serial, "reverse", "--list"]) else { return }
        let existing = String(data: result, encoding: .utf8) ?? ""
        if !existing.contains("tcp:49372 tcp:49372") {
            guard (try? ADB.run(["-s", serial, "reverse", "--no-rebind", "tcp:49372", "tcp:49372"])) != nil else { return }
        }
        lock.lock(); reverseSerial = serial; let keep = running; lock.unlock()
        if !keep { _ = try? ADB.run(["-s", serial, "reverse", "--remove", "tcp:49372"]) }
    }
    private func acceptLoop(_ fd: Int32) {
        var failure: Int32 = 0
        defer {
            lock.lock(); listening = -1; running = false; lock.unlock(); Darwin.close(fd)
            let error = failure
            Task { @MainActor [weak self] in self?.retry(error) }
        }
        while alive {
            var pollValue = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let polled = poll(&pollValue, 1, 250)
            if !alive { break }
            if polled < 0 { if errno == EINTR { continue }; failure = errno; break }
            if pollValue.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { failure = ECONNABORTED; break }
            guard polled > 0 else { continue }
            var peer = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let accepted = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) } }
            guard accepted >= 0 else {
                if errno == EINTR || errno == EAGAIN { continue }
                failure = errno; break
            }
            lock.lock(); client = accepted; let keep = running; lock.unlock()
            guard keep, let key = try? PairStore.load() else { lock.lock(); client = -1; lock.unlock(); Darwin.close(accepted); continue }
            var channel: SecureChannel?
            do {
                var reservation: ReverseConnectionWaiter?
                // Failed ACK/handoff cancels the session rather than racing a
                // direct connection against a Pad already awaiting reverse video.
                defer { reservation?.cancel() }
                channel = try SecureChannel(requestFD: accepted, key: key)
                let body = try channel!.receive()
                guard body.first == 1, body.count <= 512,
                      let request = try JSONSerialization.jsonObject(with: body.dropFirst()) as? [String: Any],
                      let command = request["type"] as? String, ["connect", "resume"].contains(command), request.count == 1 else { throw BridgeError("连接请求无效。") }
                var raw = peer.sin_addr; var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &raw, &buffer, socklen_t(buffer.count)) != nil else { throw BridgeError("连接地址无效。") }
                let host = String(cString: buffer)
                let decision = DispatchQueue.main.sync { MainActor.assumeIsolated {
                    alive && (try? PairStore.load()) == key ? handler(host, command) : .rejected
                } }
                var acceptedDecision = decision.accepted
                if decision.accepted, let target = decision.reverse {
                    if target.reserve() { reservation = target } else { acceptedDecision = false }
                }
                try channel!.sendJSON(["type": "connect-result", "accepted": acceptedDecision, "reverse": reservation != nil])
                if let target = reservation {
                    guard alive, (try? PairStore.load()) == key else { throw CancellationError() }
                    // Stop exposing the FD to server shutdown before transferring ownership.
                    lock.lock(); client = -1; lock.unlock()
                    target.offer(try channel!.detachSocket())
                    reservation = nil
                }
            } catch { /* Authentication failures never trigger UI actions. */ }
            // Clear the shutdown target before SecureChannel releases its FD.
            lock.lock(); client = -1; lock.unlock(); if let channel { channel.close() } else { Darwin.close(accepted) }; channel = nil
        }
    }
    @MainActor func close() {
        enabled = false; retryTask?.cancel(); retryTask = nil
        service?.stop(); service = nil; usbTimer?.cancel(); usbTimer = nil
        lock.lock(); running = false
        if client >= 0 { shutdown(client, SHUT_RDWR) }
        if listening >= 0 { shutdown(listening, SHUT_RDWR) }
        let serial = reverseSerial; reverseSerial = nil; lock.unlock()
        if let serial { DispatchQueue.global().async { _ = try? ADB.run(["-s", serial, "reverse", "--remove", "tcp:49372"]) } }
    }
}
