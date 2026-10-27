import Foundation
import Darwin

/// Explicit cancellation also reaches synchronous commands on detached workers.
final class ADBCancellation: @unchecked Sendable {
    private let condition = NSCondition()
    private var cancelled = false
    var isCancelled: Bool { condition.lock(); defer { condition.unlock() }; return cancelled }
    func cancel() { condition.lock(); cancelled = true; condition.broadcast(); condition.unlock() }
    func check() throws { if isCancelled { throw CancellationError() } }
    func wait(_ seconds: TimeInterval) throws {
        condition.lock()
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !cancelled && condition.wait(until: deadline) {}
        let ended = cancelled; condition.unlock()
        if ended { throw CancellationError() }
    }
}

enum ADB {
    static let package = "dev.padbridge"
    static var executable: String {
        [ProcessInfo.processInfo.environment["ADB"] ?? "", "/opt/homebrew/bin/adb", "/usr/local/bin/adb",
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/adb"
    }
    static func run(_ arguments: [String], cancellation: ADBCancellation? = nil,
                    timeout: TimeInterval = 15, executablePath: String? = nil) throws -> Data {
        try cancellation?.check()
        let process = Process(); process.executableURL = URL(fileURLWithPath: executablePath ?? executable); process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        let out = output.fileHandleForReading, err = errors.fileHandleForReading
        defer { try? out.close(); try? err.close() }
        try process.run()
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        for fd in [out.fileDescriptor, err.fileDescriptor] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var data = Data(), diagnostics = Data()
        var failure: Error?
        var stopAt: TimeInterval?
        var killed = false
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        // Drain both pipes while waiting; a full stderr must not deadlock stdout.
        func drain(_ handle: FileHandle, into result: inout Data) {
            var bytes = [UInt8](repeating: 0, count: 8192)
            for _ in 0..<16 {
                let n = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return }
                if result.count + n <= 1_048_576 { result.append(contentsOf: bytes.prefix(n)) }
                else if failure == nil { failure = BridgeError("ADB 输出过大，已停止命令。") }
            }
        }
        while true {
            drain(out, into: &data); drain(err, into: &diagnostics)
            let now = ProcessInfo.processInfo.systemUptime
            if failure == nil {
                if cancellation?.isCancelled == true { failure = CancellationError() }
                else if now >= deadline { failure = BridgeError("ADB 命令超时，请检查 USB 连接后重试。") }
            }
            if !process.isRunning { break }
            if failure != nil {
                if stopAt == nil { process.terminate(); stopAt = now }
                else if !killed && now - stopAt! >= 0.25 { kill(process.processIdentifier, SIGKILL); killed = true }
            }
            var descriptors = [pollfd(fd: out.fileDescriptor, events: Int16(POLLIN), revents: 0), pollfd(fd: err.fileDescriptor, events: Int16(POLLIN), revents: 0)]
            _ = poll(&descriptors, nfds_t(descriptors.count), 25)
            // EOF pipes are continuously readable while a child is still exiting.
            if descriptors.allSatisfy({ $0.revents & Int16(POLLHUP) != 0 }) { Thread.sleep(forTimeInterval: 0.01) }
        }
        process.waitUntilExit()
        drain(out, into: &data); drain(err, into: &diagnostics)
        if let failure { throw failure }
        try cancellation?.check()
        guard process.terminationStatus == 0 else {
            let message = String(data: diagnostics, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ADB failed"
            throw BridgeError(AppMessage(raw: message.isEmpty ? "ADB failed" : message))
        }
        return data
    }
    static func usbDevice(cancellation: ADBCancellation? = nil) throws -> String {
        try usbDevice(from: run(["devices", "-l"], cancellation: cancellation))
    }
    private static func usbDevice(from data: Data) throws -> String {
        let output = String(data: data, encoding: .utf8) ?? ""
        let devices = output.split(separator: "\n").filter { $0.contains("\tdevice ") || $0.contains(" device ") }
            .filter { $0.contains("usb:") }.compactMap { $0.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) }
        guard devices.count == 1, let serial = devices.first else { throw BridgeError("请连接一台已授权 USB 调试的 Pad（当前检测到 \(devices.count) 台）。") }
        return serial
    }
    typealias Command = ([String], ADBCancellation?) throws -> Data
    static func prepare(pairingGeneration: Int, cancellation: ADBCancellation = ADBCancellation(),
                        command: Command = { try run($0, cancellation: $1) }) throws -> (port: UInt16, serial: String, key: Data) {
        try cancellation.check(); try Task.checkCancellation()
        let serial = try usbDevice(from: command(["devices", "-l"], cancellation))
        _ = try command(["-s", serial, "shell", "am", "start", "-n", package + "/.MainActivity"], cancellation)
        var key = Data()
        for _ in 0..<20 {
            try cancellation.check(); try Task.checkCancellation()
            do {
                let candidate = try command(["-s", serial, "exec-out", "run-as", package, "cat", "files/pairing.key"], cancellation)
                if candidate.count == 32 { key = candidate; break }
            } catch is CancellationError { throw CancellationError() }
            catch { /* The service may still be creating its pairing key. */ }
            try cancellation.wait(0.15)
        }
        guard key.count == 32 else { throw BridgeError("请先安装并打开 Nextend Android 调试版。") }
        try cancellation.check(); try Task.checkCancellation()
        // Let this short side-effecting command report its allocated port even
        // during cancellation, so rollback never loses ownership of a forward.
        let output = try command(["-s", serial, "forward", "tcp:0", "tcp:49371"], nil)
        guard let port = UInt16(String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") else { throw BridgeError("ADB 动态端口转发失败。") }
        do {
            try cancellation.check(); try Task.checkCancellation()
            try PairStore.save(key, expectedGeneration: pairingGeneration)
        } catch { _ = try? command(["-s", serial, "forward", "--remove", "tcp:\(port)"], nil); throw error }
        return (port, serial, key)
    }
    static func removeForward(serial: String, port: UInt16) { _ = try? run(["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 3) }
}

enum PairStore {
    private static let lock = NSLock()
    private static var epoch = 0
    static var generation: Int { lock.lock(); defer { lock.unlock() }; return epoch }
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PadBridge", isDirectory: true)
    }
    static func save(_ key: Data, expectedGeneration: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard epoch == expectedGeneration else { throw BridgeError("配对已撤销，请通过 USB 重新连接。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("pairing.key")
        try key.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        UserDefaults.standard.set(false, forKey: "pairingRevoked")
    }
    static func revoke() {
        lock.lock(); defer { lock.unlock() }; epoch += 1
        // Fail closed even if deleting the old file fails (e.g. read-only disk).
        UserDefaults.standard.set(true, forKey: "pairingRevoked")
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("pairing.key"))
    }
    static func load() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard !UserDefaults.standard.bool(forKey: "pairingRevoked") else { throw BridgeError("请先通过 USB 完成配对。") }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("pairing.key")), data.count == 32 else { throw BridgeError("请先通过 USB 完成配对。") }
        return data
    }
}
