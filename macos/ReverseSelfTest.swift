import Foundation
import Darwin

private final class ReverseTestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func run(_ body: () throws -> Void) { do { try body() } catch { lock.lock(); self.error = error; lock.unlock() } }
    func verify() throws { lock.lock(); defer { lock.unlock() }; if let error { throw error } }
}

/// Local socket-pair tests only: no application launch, pairing file or OS input.
func reverseConnectionSelfTest() throws {
    func check(_ value: Bool, _ name: String) throws {
        if !value { throw BridgeError(AppMessage(raw: "Reverse connection: " + name)) }
    }
    func pair() throws -> [Int32] {
        var fds: [Int32] = [-1, -1]
        try check(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "socket pair")
        for fd in fds {
            var one: Int32 = 1, timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        }
        return fds
    }
    do {
        let fds = try pair(); defer { Darwin.close(fds[1]) }
        let owner = ConnectedSocket(fds[0]); let moved = try owner.take()
        owner.close()
        try check(fcntl(moved, F_GETFD) >= 0, "old owner cannot close transferred descriptor")
        do { _ = try owner.take(); throw NSError(domain: "duplicate take", code: 1) } catch is BridgeError {}
        Darwin.close(moved)
    }
    do {
        let waiter = ReverseConnectionWaiter()
        try check(try waiter.take(timeout: 0) == nil && !waiter.reserve(), "expired slot cannot be reserved")
        let fds = try pair(); defer { Darwin.close(fds[1]) }
        try check(!waiter.offer(ConnectedSocket(fds[0])) && fcntl(fds[0], F_GETFD) == -1, "late socket is closed")
    }
    do {
        let waiter = ReverseConnectionWaiter(), result = ReverseTestResult(), done = DispatchSemaphore(value: 0)
        try check(waiter.reserve() && !waiter.reserve(), "only one ACK reservation")
        DispatchQueue.global().async {
            result.run {
                guard let socket = try waiter.take(timeout: 0) else { throw BridgeError("reserved slot fell back") }
                socket.close()
            }
            done.signal()
        }
        try check(done.wait(timeout: .now() + .milliseconds(50)) == .timedOut, "ACK reservation survives deadline")
        let fds = try pair(); defer { Darwin.close(fds[1]) }
        try check(waiter.offer(ConnectedSocket(fds[0])), "reserved handoff commits")
        try check(done.wait(timeout: .now() + 2) == .success, "handoff wakes waiter")
        try result.verify()
    }
    do {
        let waiter = ReverseConnectionWaiter(), result = ReverseTestResult(), done = DispatchSemaphore(value: 0)
        try check(waiter.reserve(), "cancellation setup")
        DispatchQueue.global().async {
            result.run {
                do { _ = try waiter.take(timeout: 0); throw BridgeError("cancelled slot accepted") }
                catch is CancellationError {}
            }
            done.signal()
        }
        waiter.cancel()
        try check(done.wait(timeout: .now() + 2) == .success, "cancel wakes reserved waiter")
        try result.verify()
    }

    func rawWrite(_ fd: Int32, _ body: Data) throws {
        var packet = Data(); packet.appendBE(UInt32(body.count)); packet.append(body)
        try packet.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                try check(count > 0, "test peer write"); offset += count
            }
        }
    }
    func exact(_ fd: Int32, _ size: Int) throws -> Data {
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < size {
                let count = recv(fd, bytes.baseAddress!.advanced(by: offset), size - offset, 0)
                try check(count > 0, "test peer read"); offset += count
            }
        }
        return data
    }
    func rawRead(_ fd: Int32) throws -> Data {
        let length = Int(try exact(fd, 4).uintBE(0, 4))
        try check(length > 0 && length <= 4096, "bounded test packet")
        return try exact(fd, length)
    }
    let key = Data((0..<32).map(UInt8.init)), fds = try pair()
    let result = ReverseTestResult(), done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        defer { Darwin.close(fds[1]); done.signal() }
        result.run {
            let nonce = PairCrypto.random(32)
            try rawWrite(fds[1], Data("PDR1".utf8) + nonce)
            let challenge = try rawRead(fds[1]), requestSalt = nonce + challenge.prefix(32)
            try check(challenge.count == 64 && PairCrypto.verify(challenge.suffix(32), key: key, role: "request-mac", salt: requestSalt), "request identity")
            try rawWrite(fds[1], PairCrypto.proof(key: key, role: "request-pad", salt: requestSalt))
            let request = Data([1]) + Data("{\"type\":\"resume\"}".utf8)
            try rawWrite(fds[1], PairCrypto.seal(request, key: PairCrypto.derive(key: key, salt: requestSalt, direction: "request-pad-to-mac"), sequence: 0))
            let ack = try PairCrypto.open(rawRead(fds[1]), key: PairCrypto.derive(key: key, salt: requestSalt, direction: "request-mac-to-pad"), sequence: 0)
            let json = try JSONSerialization.jsonObject(with: ack.dropFirst()) as? [String: Any]
            try check(json?["reverse"] as? Bool == true, "authenticated handoff ACK")
            let hello = try rawRead(fds[1])
            try check(hello.count == 36 && hello.prefix(4) == Data("PDB1".utf8), "fresh video handshake")
            let videoNonce = PairCrypto.random(32), videoSalt = hello.suffix(32) + videoNonce
            try check(videoSalt != requestSalt, "independent request and video nonces")
            try rawWrite(fds[1], videoNonce + PairCrypto.proof(key: key, role: "pad", salt: videoSalt))
            try check(try PairCrypto.verify(rawRead(fds[1]), key: key, role: "mac", salt: videoSalt), "fresh video identity")
            try rawWrite(fds[1], PairCrypto.seal(Data([1]) + Data("{\"type\":\"hello\"}".utf8), key: PairCrypto.derive(key: key, salt: videoSalt, direction: "pad-to-mac"), sequence: 0))
            let stop = try PairCrypto.open(rawRead(fds[1]), key: PairCrypto.derive(key: key, salt: videoSalt, direction: "mac-to-pad"), sequence: 0)
            try check(String(data: stop.dropFirst(), encoding: .utf8)?.contains("stop") == true, "video control survives old channel close")
        }
    }
    let request = try SecureChannel(requestFD: fds[0], key: key)
    try check(try request.receive().first == 1, "request received")
    try request.sendJSON(["type": "connect-result", "accepted": true, "reverse": true])
    let transferred = try request.detachSocket(); request.close()
    let video = try SecureChannel(connected: transferred, key: key); defer { video.close() }
    try check(try video.receive().first == 1, "video received after transfer")
    try video.sendJSON(["type": "stop"])
    try check(done.wait(timeout: .now() + 3) == .success, "peer finishes")
    try result.verify()
    print("PASS: reverse ownership, deadline reservation, cancellation, PDR1-to-PDB1 key separation")
}
