import Foundation
import Darwin

/// Isolated regressions: no Pad, pairing writes, screen capture or system input.
@MainActor func recoverySelfTest() async throws {
    func check(_ value: Bool, _ message: String) throws {
        if !value { throw BridgeError(AppMessage(raw: message)) }
    }
    let recovery = ConnectionRecovery()
    var helperExited = false, displayRemoved = false
    let hdr = HDRCaptureLifetime()
    recovery.waitUntil { helperExited && displayRemoved }
    recovery.waitUntil { hdr.isStopped }
    try check(!recovery.check(), "cleanup must block while resources are live")
    helperExited = true
    try check(!recovery.check(), "helper exit does not imply display removal")
    displayRemoved = true
    try check(!recovery.check(), "display removal does not imply capture stopped")
    hdr.didStop()
    try check(recovery.check() && !recovery.isPending, "late stop unlocks reconnection without a process restart")
    try check(recovery.check(), "repeated checks remain available")
    print("PASS: late display/HDR cleanup, all-resource gate, repeated recovery")

    let cancellation = ADBCancellation()
    let started = ProcessInfo.processInfo.systemUptime
    let prepare = Task.detached {
        try ADB.prepare(pairingGeneration: -1, cancellation: cancellation) { args, token in
            if args.first == "devices" { return Data("fixture\tdevice usb:1\n".utf8) }
            try token?.wait(0.02)
            return Data()
        }
    }
    try await Task.sleep(for: .milliseconds(100))
    cancellation.cancel(); prepare.cancel()
    do { _ = try await prepare.value; throw BridgeError("cancelled pairing succeeded") }
    catch is CancellationError {}
    try check(ProcessInfo.processInfo.systemUptime - started < 1.5, "pairing cancellation waited for all retries")

    // Even cancellation immediately after forward allocation must remove it.
    let forwardCancel = ADBCancellation()
    var removed = false
    do {
        _ = try ADB.prepare(pairingGeneration: -1, cancellation: forwardCancel) { args, _ in
            if args.first == "devices" { return Data("fixture\tdevice usb:1\n".utf8) }
            if args.contains("exec-out") { return Data(repeating: 9, count: 32) }
            if args.contains("tcp:0") { forwardCancel.cancel(); return Data("53619\n".utf8) }
            if args.contains("--remove") { removed = args.last == "tcp:53619" }
            return Data()
        }
        throw BridgeError("cancelled forward succeeded")
    } catch is CancellationError {}
    try check(removed, "forward ownership lost during cancellation")

    let drained = try await Task.detached {
        try ADB.run(["-c", "import os; os.write(2,b'x'*200000); os.write(1,b'OK')"], timeout: 3, executablePath: "/usr/bin/python3")
    }.value
    try check(drained == Data("OK".utf8), "large stderr blocked stdout")
    let commandCancel = ADBCancellation()
    let command = Task.detached {
        try ADB.run(["-c", "trap '' TERM; while :; do :; done"], cancellation: commandCancel, executablePath: "/bin/sh")
    }
    try await Task.sleep(for: .milliseconds(100))
    let cancelledAt = ProcessInfo.processInfo.systemUptime
    commandCancel.cancel()
    do { _ = try await command.value; throw BridgeError("cancelled command succeeded") }
    catch is CancellationError {}
    try check(ProcessInfo.processInfo.systemUptime - cancelledAt < 1.5, "SIGTERM-resistant command did not terminate")
    print("PASS: pairing cancel, forward rollback, stderr draining, forced child termination")

    func occupiedPort() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError("test socket failed") }
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 1) == 0 else { Darwin.close(fd); throw BridgeError("test bind failed") }
        var n = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &n) } }
        return (fd, UInt16(bigEndian: a.sin_port))
    }
    let (fd, port) = try occupiedPort()
    var reportedFailure = false, reportedRecovery = false
    let server = ConnectRequestServer(port: port, advertise: false, onStatus: { message in
        if message == nil { reportedRecovery = true } else { reportedFailure = true }
    }) { _, _ in .rejected }
    server.start()
    try check(reportedFailure && !server.isListening, "occupied listener port was not reported")
    Darwin.close(fd)
    for _ in 0..<30 {
        if server.isListening { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    try check(server.isListening && reportedRecovery, "listener failed to recover after port became free")
    server.close()
    let (secondFD, secondPort) = try occupiedPort()
    let stopped = ConnectRequestServer(port: secondPort, advertise: false) { _, _ in .rejected }
    stopped.start(); stopped.close(); Darwin.close(secondFD)
    try await Task.sleep(for: .milliseconds(1200))
    try check(!stopped.isListening, "listener retry resurrected a closed server")
    print("PASS: port collision recovery, visible failure/recovery, cancellation of listener retry")
}
