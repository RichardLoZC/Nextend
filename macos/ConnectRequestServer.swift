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
    private let handler: @MainActor (String, String) -> ConnectRequestDecision
    init(handler: @escaping @MainActor (String, String) -> ConnectRequestDecision) { self.handler = handler }
    @MainActor func start() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_port = UInt16(49372).bigEndian
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0, listen(fd, 4) == 0 else { Darwin.close(fd); return }
        lock.lock(); listening = fd; running = true; lock.unlock()
        let advertisement = NetService(domain: "local.", type: "_nextend._tcp.", name: Host.current().localizedName ?? "Nextend Mac", port: 49372)
        advertisement.publish(); service = advertisement
        DispatchQueue.global(qos: .utility).async { self.acceptLoop(fd) }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "Nextend.usb-request"))
        timer.schedule(deadline: .now(), repeating: 5)
        timer.setEventHandler { [weak self] in self?.prepareUSB() }; timer.resume(); usbTimer = timer
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
        defer { lock.lock(); listening = -1; lock.unlock(); Darwin.close(fd) }
        while alive {
            var pollValue = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pollValue, 1, 250) > 0, alive else { continue }
            var peer = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let accepted = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) } }
            guard accepted >= 0 else { continue }
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
        service?.stop(); service = nil; usbTimer?.cancel(); usbTimer = nil
        lock.lock(); running = false
        if client >= 0 { shutdown(client, SHUT_RDWR) }
        if listening >= 0 { shutdown(listening, SHUT_RDWR) }
        let serial = reverseSerial; reverseSerial = nil; lock.unlock()
        if let serial { DispatchQueue.global().async { _ = try? ADB.run(["-s", serial, "reverse", "--remove", "tcp:49372"]) } }
    }
}
