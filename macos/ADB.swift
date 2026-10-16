import Foundation

enum ADB {
    static let package = "dev.padbridge"
    static var executable: String {
        [ProcessInfo.processInfo.environment["ADB"] ?? "", "/opt/homebrew/bin/adb", "/usr/local/bin/adb",
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/adb"
    }
    static func run(_ arguments: [String]) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let pipe = Pipe(); let errors = Pipe(); process.standardOutput = pipe; process.standardError = errors
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ADB failed"
            throw BridgeError(AppMessage(raw: message.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return data
    }
    static func usbDevice() throws -> String {
        let output = String(data: try run(["devices", "-l"]), encoding: .utf8) ?? ""
        let devices = output.split(separator: "\n").filter { $0.contains("\tdevice ") || $0.contains(" device ") }
            .filter { $0.contains("usb:") }.compactMap { $0.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) }
        guard devices.count == 1, let serial = devices.first else { throw BridgeError("请连接一台已授权 USB 调试的 Pad（当前检测到 \(devices.count) 台）。") }
        return serial
    }
    static func prepare() throws -> (port: UInt16, serial: String, key: Data) {
        let serial = try usbDevice()
        _ = try run(["-s", serial, "shell", "am", "start", "-n", package + "/.MainActivity"])
        var key = Data()
        for _ in 0..<20 {
            if let candidate = try? run(["-s", serial, "exec-out", "run-as", package, "cat", "files/pairing.key"]), candidate.count == 32 { key = candidate; break }
            Thread.sleep(forTimeInterval: 0.15)
        }
        guard key.count == 32 else { throw BridgeError("请先安装并打开 Nextend Android 调试版。") }
        let output = try run(["-s", serial, "forward", "tcp:0", "tcp:49371"])
        guard let port = UInt16(String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") else { throw BridgeError("ADB 动态端口转发失败。") }
        do { try PairStore.save(key) } catch { removeForward(serial: serial, port: port); throw error }
        return (port, serial, key)
    }
    static func removeForward(serial: String, port: UInt16) { _ = try? run(["-s", serial, "forward", "--remove", "tcp:\(port)"]) }
}

enum PairStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PadBridge", isDirectory: true)
    }
    static func save(_ key: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("pairing.key")
        try key.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func load() throws -> Data {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("pairing.key")), data.count == 32 else { throw BridgeError("请先通过 USB 完成配对。") }
        return data
    }
}
