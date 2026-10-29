import Foundation
import Darwin

/// Logging must never wait for storage on a capture, decoder or UI thread.
final class DiagnosticJournal {
    private let directory: URL
    private let limit: Int
    private let retained: Int
    private let writer = DispatchQueue(label: "Nextend.diagnostics", qos: .utility)
    private let slots = DispatchSemaphore(value: 256)
    private let overflowLock = NSLock()
    private var dropped = 0
    private var totalDropped = 0
    private let healthLock = NSLock()
    private var writeFailures = 0
    private var lastWriteError = ""
    private let formatter = ISO8601DateFormatter()

    init(directory: URL, limit: Int = 1024 * 1024, retained: Int = 4) {
        self.directory = directory; self.limit = max(4096, limit); self.retained = max(2, retained)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }
    func record(_ event: String, session: String? = nil, fields: [String: Any] = [:]) {
        // Bound both queued work and individual records before enqueueing.
        let clean = DiagnosticPrivacy.fields(fields)
        let name = DiagnosticPrivacy.text(event)
        let id = session.flatMap { UUID(uuidString: $0)?.uuidString }
        let date = Date(); let uptime = ProcessInfo.processInfo.systemUptime
        guard slots.wait(timeout: .now()) == .success else {
            overflowLock.lock(); dropped += 1; totalDropped += 1; overflowLock.unlock(); return
        }
        writer.async {
            defer { self.slots.signal() }
            self.overflowLock.lock(); let lost = self.dropped; self.dropped = 0; self.overflowLock.unlock()
            var row: [String: Any] = ["schema": 1, "platform": "macOS", "event": name,
                "timeUTC": self.formatter.string(from: date), "uptimeSeconds": uptime,
                "pid": ProcessInfo.processInfo.processIdentifier, "details": clean]
            if let id { row["session"] = id }
            if lost > 0 { row["droppedLogEvents"] = lost }
            do {
                let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])
                try self.withFileLock { try self.append(data) }
            } catch {
                self.healthLock.lock(); self.writeFailures += 1
                self.lastWriteError = String(describing: type(of: error)); self.healthLock.unlock()
            }
        }
    }
    func flush(timeout: TimeInterval = 3) -> Bool {
        let done = DispatchSemaphore(value: 0)
        writer.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }
    /// Use from a background worker. The lock also covers the display-host process.
    func snapshot(to destination: URL) throws {
        guard flush() else { throw NSError(domain: "Nextend.Diagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: "Diagnostic storage is busy. Try again."]) }
        try withFileLock {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for index in 0..<retained {
                let name = filename(index)
                let source = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: source.path) {
                    // Only the journal allowlist is exported; never preferences or pairing files.
                    let data = try Data(contentsOf: source, options: .mappedIfSafe)
                    guard data.count <= limit else { throw NSError(domain: "Nextend.Diagnostics", code: 2) }
                    try data.write(to: destination.appendingPathComponent(name), options: .atomic)
                }
            }
            healthLock.lock()
            let failures = writeFailures; let lastError = lastWriteError
            healthLock.unlock()
            overflowLock.lock(); let lost = totalDropped; overflowLock.unlock()
            let health: [String: Any] = ["writeFailures": failures, "lastWriteError": lastError,
                "droppedLogEvents": lost, "scope": "current-process", "pid": ProcessInfo.processInfo.processIdentifier]
            try JSONSerialization.data(withJSONObject: health, options: [.sortedKeys]).write(to: destination.appendingPathComponent("storage-status.json"), options: .atomic)
        }
    }
    private func filename(_ index: Int) -> String { index == 0 ? "events.jsonl" : "events.\(index).jsonl" }
    private func withFileLock<T>(_ operation: () throws -> T) throws -> T {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw POSIXError(.EIO) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(lock, LOCK_UN) }
        return try operation()
    }
    private func append(_ data: Data) throws {
        guard data.count <= limit else { throw POSIXError(.EFBIG) }
        let fm = FileManager.default
        let active = directory.appendingPathComponent(filename(0))
        var fd = open(active.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { if fd >= 0 { close(fd) } }
        // Repair an interrupted tail before rotation, including a nearly full journal.
        var originalSize = lseek(fd, 0, SEEK_END)
        guard originalSize >= 0 else { throw POSIXError(.EIO) }
        if originalSize > 0 {
            var last: UInt8 = 0
            if pread(fd, &last, 1, originalSize - 1) == 1 && last != 10 {
                let existing = try Data(contentsOf: active)
                let end = existing.lastIndex(of: 10).map { $0 + 1 } ?? 0
                guard ftruncate(fd, off_t(end)) == 0 else { throw POSIXError(.EIO) }
                originalSize = off_t(end)
            }
        }
        if originalSize + off_t(data.count) > off_t(limit) {
            close(fd); fd = -1
            let oldest = directory.appendingPathComponent(filename(retained - 1))
            if fm.fileExists(atPath: oldest.path) { try fm.removeItem(at: oldest) }
            for index in stride(from: retained - 2, through: 0, by: -1) {
                let old = directory.appendingPathComponent(filename(index))
                if fm.fileExists(atPath: old.path) { try fm.moveItem(at: old, to: directory.appendingPathComponent(filename(index + 1))) }
            }
            fd = open(active.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            originalSize = 0
        }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw POSIXError(.EIO) }
                    offset += count
                }
            }
        } catch {
            _ = ftruncate(fd, originalSize)
            throw error
        }
    }

}

enum DiagnosticPrivacy {
    private static let patterns: [(NSRegularExpression, String)] = [
        (#"(?i)(?:device|serial(?:number|no)?)\s*[:=]?\s*["'][^"']+["']"#, "<device>"),
        ("(?i)(?:pairing[._ -]?key|password|secret|token|cookie)\\s*[:=]\\s*[^\\s,;]+", "<redacted>"),
        ("\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b", "<ip>"),
        ("(?i)(?:[0-9a-f]{0,4}:){2,}[0-9a-f:%._-]*", "<address>"),
        ("/Users/[^/\\s]+", "/Users/<user>"),
        ("\\b[A-Za-z0-9+/_=-]{32,}\\b", "<identifier>")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    static func text(_ value: String) -> String {
        var result = String(value.prefix(1024))
        for (pattern, replacement) in patterns {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
        }
        return result
    }
    static func fields(_ value: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in value.keys.sorted().prefix(24) {
            let lower = key.lowercased()
            if ["password", "secret", "token", "cookie", "serial", "ssid", "address", "host", "path", "key"].contains(where: lower.contains) { continue }
            let name = String(key.prefix(64))
            switch value[key] {
            case let number as NSNumber:
                result[name] = number.doubleValue.isFinite ? number : NSNull()
            case let text as String: result[name] = self.text(text)
            default: break
            }
        }
        return result
    }
}

enum Diagnostics {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Nextend", isDirectory: true)
    static let journal = DiagnosticJournal(directory: directory)
    static func event(_ event: String, session: String? = nil, _ fields: [String: Any] = [:]) {
        journal.record(event, session: session, fields: fields)
    }
    static func launch() {
        let bundle = Bundle.main
        event("app.launch", ["version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "role": CommandLine.arguments.contains("--display-host") ? "display-host" : "application"])
    }
    static func export(to destination: URL, completion: @escaping (Error?) -> Void) {
        event("diagnostics.export")
        DispatchQueue.global(qos: .utility).async {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("nextend-diagnostics-" + UUID().uuidString + ".noindex")
            defer { try? FileManager.default.removeItem(at: temp) }
            do {
                let folder = temp.appendingPathComponent("Nextend-diagnostics")
                try journal.snapshot(to: folder)
                let info = """
                Nextend diagnostic log, schema 1.
                Timestamps are UTC; session IDs match both updated clients.
                Includes connection events and sampled metrics. Retains up to 4 MiB per device.
                No screen images, video, touch coordinates, pairing keys or automatic uploads.
                storage-status.json reports dropped events and write failures for this process.
                Some error text is redacted. Older app sessions may have no logs.
                """
                try info.write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
                let archive = temp.appendingPathComponent("diagnostics.zip")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", folder.path, archive.path]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw NSError(domain: "Nextend.Diagnostics", code: 3) }
                try Data(contentsOf: archive).write(to: destination, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                DispatchQueue.main.async { completion(nil) }
            } catch { DispatchQueue.main.async { completion(error) } }
        }
    }
}
