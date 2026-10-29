import AppKit
import Darwin

// Private pipes carry display control only. Pairing keys and video never enter
// this helper. EOF also covers an abrupt parent crash, including SIGKILL.
private func readDisplayLines(_ handle: FileHandle, line: @escaping (Data) -> Void, ended: @escaping () -> Void) {
    DispatchQueue(label: "Nextend.display-control-reader").async {
        var buffered = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
                // FileHandle.read(upToCount:) may wait to fill its requested
                // length. A control line must be delivered immediately.
                let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                buffered.append(contentsOf: bytes.prefix(count))
                while let newline = buffered.firstIndex(of: 10) {
                    guard buffered.distance(from: buffered.startIndex, to: newline) <= 8192 else { ended(); return }
                    let value = Data(buffered[..<newline]); buffered.removeSubrange(...newline)
                    line(value)
                }
                guard buffered.count <= 8192 else { ended(); return }
        }
        ended()
    }
}

@MainActor final class VirtualDisplay {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var profile: Profile
    private var details: [String: Any] = [:]
    private var failure: AppMessage?
    private var closed = false
    private var revision = 0
    private var readyRevision = -1
    private var hostEnded = false
    private(set) var id: CGDirectDisplayID = 0
    var onHDRInvalid: ((AppMessage) -> Void)?
    var canReconfigureForSDR: Bool { !closed && !hostEnded && id != 0 && process.isRunning }
    static var supportsHDR: Bool { NativeVirtualDisplay.supportsHDR }
    static func requireInteractiveConsole() throws { try NativeVirtualDisplay.requireInteractiveConsole() }

    init(profile: Profile) throws {
        try Self.requireInteractiveConsole(); try profile.validate()
        guard let online = Self.onlineDisplays(), !online.contains(where: Self.isNextendDisplay) else {
            throw BridgeError("已有 Nextend 虚拟屏，请先断开现有连接。")
        }
        self.profile = profile
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--display-host", String(profile.width), String(profile.height), String(profile.fps), profile.color.rawValue]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        readDisplayLines(output.fileHandleForReading, line: { [weak self] data in
            guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            Task { @MainActor [weak self] in self?.received(message) }
        }, ended: { [weak self] in
            Task { @MainActor [weak self] in
                self?.hostEnded = true
                self?.failed("虚拟屏辅助进程已结束。")
            }
        })
    }
    private func received(_ message: [String: Any]) {
        // Creation precedes mode readiness. Keep its ID even when cancellation
        // raced this message, so teardown can still verify actual removal.
        if let created = message["created"] as? UInt32, created != 0 { id = created }
        guard !closed else { return }
        if let encoded = message["localizedError"] as? String,
           let error = try? JSONDecoder().decode(AppMessage.self, from: Data(encoded.utf8)) { failed(error); return }
        if let error = message["error"] as? String { failed(AppMessage(raw: error)); return }
        guard message["revision"] as? Int == revision,
              let description = message["display"] as? [String: Any],
              let number = description["id"] as? UInt32, number != 0 else { return }
        id = number; details = description; readyRevision = revision
    }
    private func failed(_ reason: AppMessage) {
        guard !closed, failure == nil else { return }
        failure = reason; onHDRInvalid?(reason)
    }
    private func send(_ command: String) throws {
        guard !closed, process.isRunning else { throw BridgeError("虚拟屏辅助进程不可用。") }
        let data = try JSONSerialization.data(withJSONObject: ["command": command, "revision": revision])
        try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
    }
    func waitUntilReady() async throws {
        for _ in 0..<60 {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            if let failure { throw BridgeError(failure) }
            if readyRevision == revision { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw BridgeError("等待虚拟屏辅助进程超时。")
    }
    func describe() -> [String: Any] { details }
    func suspendEnforcement() {
        onHDRInvalid = nil
        // Shutdown remains possible even if the control pipe has already died.
        try? send("suspend")
    }
    func prepareSDRFallback(_ replacement: Profile) throws {
        try Self.requireInteractiveConsole()
        guard !closed, replacement.color == .sdr,
              replacement.width == profile.width, replacement.height == profile.height,
              replacement.fps == profile.fps else { throw BridgeError("SDR 回退的虚拟屏配置不匹配。") }
        profile = replacement; revision += 1; failure = nil
        try send("sdr")
    }
    func close() {
        guard !closed else { return }
        closed = true; onHDRInvalid = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
    func closeAndWait() async -> Bool {
        close()
        // SIGTERM is reset to its default in the helper. The parent waits for
        // process death AND WindowServer removal before allowing a reconnect.
        for _ in 0..<20 {
            if isReleased { return true }
            await cleanupDelay()
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        for _ in 0..<12 {
            if isReleased { return true }
            await cleanupDelay()
        }
        return isReleased
    }
    // Keep this object after a timeout so a late WindowServer removal can be
    // observed without creating a second display or restarting the app.
    var isReleased: Bool { closed && !process.isRunning && removedFromOnlineList() }
    private func cleanupDelay() async {
        // This can run inside a cancelled startup task. Cleanup must still
        // wait for real time to pass instead of swallowing CancellationError.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250)) { continuation.resume() }
        }
    }
    private func removedFromOnlineList() -> Bool {
        // CGDisplayIsOnline returns -1 for a retired ID on this macOS, not 0.
        // Query the list rather than treating any nonzero result as online.
        guard let ids = Self.onlineDisplays() else { return false }
        if id != 0 { return !ids.contains(id) }
        // Startup may be cancelled before the child publishes its ID. This
        // identity was absent before launch; require it to remain absent now.
        return !ids.contains(where: Self.isNextendDisplay)
    }
    private static func isNextendDisplay(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == 0x5042 && CGDisplayModelNumber(id) == 1 && CGDisplaySerialNumber(id) == 0x25032
    }
    private static func onlineDisplays() -> [CGDirectDisplayID]? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count) + 8)
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return Array(ids.prefix(Int(count)))
    }
    deinit {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

@MainActor enum DisplayHost {
    nonisolated private static func finish(_ code: Int32) -> Never {
        Diagnostics.event("display_host.exit", ["status": code])
        _ = Diagnostics.journal.flush(timeout: 0.3)
        Darwin.exit(code)
    }
    private static var display: NativeVirtualDisplay?
    private static var profile = Profile()
    private static var revision = 0
    private static func emit(_ value: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: value)
            try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
        } catch { finish(1) }
    }
    private static func emitError(_ error: AppMessage) {
        Diagnostics.event("display_host.error", ["message": error.text])
        guard let data = try? JSONEncoder().encode(error), let encoded = String(data: data, encoding: .utf8) else { finish(1) }
        emit(["error": error.text, "localizedError": encoded])
    }
    private static func reportReady() async {
        do {
            guard let display else { throw BridgeError("虚拟屏尚未创建。") }
            try await display.waitUntilReady()
            display.onHDRInvalid = { reason in emitError(reason) }
            emit(["revision": revision, "display": display.describe()])
        } catch { emitError(error.appMessage) }
    }
    private static func receive(_ message: [String: Any]) {
        guard let command = message["command"] as? String else { return }
        if command == "suspend" { display?.suspendEnforcement(); return }
        guard command == "sdr", let next = message["revision"] as? Int, next == revision + 1,
              profile.color == .hlg, let display else { emitError("虚拟屏控制命令无效。"); return }
        revision = next; profile.color = .sdr
        do { try display.prepareSDRFallback(profile) }
        catch { emitError(error.appMessage); return }
        Task { await reportReady() }
    }
    static func run() {
        // The GUI installs dispatch signal handlers; ignored POSIX signals are
        // inherited across exec, so restore termination in this child.
        signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGPIPE, SIG_IGN)
        let arguments = CommandLine.arguments
        guard arguments.count == 6, let width = Int(arguments[2]), let height = Int(arguments[3]),
              let fps = Int(arguments[4]), let color = VideoColor(rawValue: arguments[5]) else { finish(2) }
        profile.width = width; profile.height = height; profile.fps = fps; profile.color = color
        let application = NSApplication.shared; application.setActivationPolicy(.prohibited)
        do {
            try profile.validate(); display = try NativeVirtualDisplay(profile: profile)
            emit(["created": display!.id])
        }
        catch { emitError(error.appMessage); finish(1) }
        readDisplayLines(FileHandle.standardInput, line: { data in
            guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { finish(2) }
            Task { @MainActor in receive(message) }
        }, ended: { finish(0) })
        Task { await reportReady() }
        application.run()
    }
}
