import Foundation
import CryptoKit
import Darwin

final class SecureChannel {
    static let maxPacket = 16 * 1024 * 1024
    private let fd: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var stopped = false
    private var ownsFD = true
    private var sendSequence: UInt64 = 0
    private var receiveSequence: UInt64 = 0
    private var sendKey: SymmetricKey!
    private var receiveKey: SymmetricKey!
    private var packetMaximum = SecureChannel.maxPacket

    init(host: String, port: UInt16, key: Data, interface: String?) throws {
        guard key.count == 32 else { throw BridgeError("配对密钥无效，请重新通过 USB 配对。") }
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError("无法创建网络连接。") }
        do {
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout.size(ofValue: one)))
            var timeout = timeval(tv_sec: 8, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            if let interface, !interface.isEmpty {
                var index = if_nametoindex(interface)
                guard index > 0, setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout.size(ofValue: index))) == 0
                else { throw BridgeError("无法绑定接口 \(interface)。") }
            }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw BridgeError("请输入 Pad 的 IPv4 地址。") }
            // Nonblocking connect makes the initial connection deadline independent of OS TCP retries.
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            if result != 0 {
                guard errno == EINPROGRESS else { throw BridgeError("连接失败：\(String(cString: strerror(errno)))") }
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&p, 1, 5000) > 0 else { throw BridgeError("连接超时。请检查 Pad 模式、IP 和 VPN 的局域网放行设置。") }
                var err: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                guard err == 0 else { throw BridgeError("Pad 尚未监听或网络阻断：\(String(cString: strerror(err)))") }
            }
            _ = fcntl(fd, F_SETFL, flags)
            try authenticateVideo(key: key)
        } catch { ownsFD = false; Darwin.close(fd); throw error }
    }

    /// PDR1 only negotiates the handoff. Video always uses a fresh PDB1 nonce/key.
    init(connected socket: ConnectedSocket, key: Data) throws {
        fd = try socket.take()
        do {
            guard key.count == 32 else { throw BridgeError("配对密钥无效，请重新通过 USB 配对。") }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout.size(ofValue: one)))
            var timeout = timeval(tv_sec: 8, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            try authenticateVideo(key: key)
        } catch { ownsFD = false; Darwin.close(fd); throw error }
    }
    private func authenticateVideo(key: Data) throws {
        let localNonce = PairCrypto.random(32)
        try writeRaw(Data("PDB1".utf8) + localNonce)
        let reply = try readRaw(maximum: 64, timeoutSeconds: 5)
        guard reply.count == 64 else { throw BridgeError("配对协议版本不匹配。") }
        let salt = localNonce + reply.prefix(32)
        guard PairCrypto.verify(reply.suffix(32), key: key, role: "pad", salt: salt) else { throw BridgeError("Pad 身份验证失败，请用 USB 重新配对。") }
        try writeRaw(PairCrypto.proof(key: key, role: "mac", salt: salt))
        sendKey = PairCrypto.derive(key: key, salt: salt, direction: "mac-to-pad")
        receiveKey = PairCrypto.derive(key: key, salt: salt, direction: "pad-to-mac")
    }

    func detachSocket() throws -> ConnectedSocket {
        stateLock.lock(); defer { stateLock.unlock() }
        guard ownsFD, !stopped else { throw BridgeError("连接已取消。") }
        ownsFD = false; stopped = true
        return ConnectedSocket(fd)
    }

    /// Separate domain and keys: a connection request cannot be replayed as video/control.
    init(requestFD: Int32, key: Data) throws {
        fd = requestFD; packetMaximum = 4096
        do {
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            let hello = try readRaw(maximum: 36, timeoutSeconds: 3)
            guard hello.count == 36, hello.prefix(4) == Data("PDR1".utf8), key.count == 32 else { throw BridgeError("连接请求无效。") }
            let nonce = PairCrypto.random(32), salt = Data(hello.suffix(32)) + nonce
            try writeRaw(nonce + PairCrypto.proof(key: key, role: "request-mac", salt: salt))
            guard PairCrypto.verify(try readRaw(maximum: 32, timeoutSeconds: 3), key: key, role: "request-pad", salt: salt) else { throw BridgeError("连接请求认证失败。") }
            sendKey = PairCrypto.derive(key: key, salt: salt, direction: "request-mac-to-pad")
            receiveKey = PairCrypto.derive(key: key, salt: salt, direction: "request-pad-to-mac")
        } catch { ownsFD = false; throw error }
    }

    deinit { if ownsFD { Darwin.close(fd) } }
    func close() {
        stateLock.lock(); defer { stateLock.unlock() }
        if ownsFD && !stopped { stopped = true; shutdown(fd, SHUT_RDWR) }
    }
    private func readExactly(_ count: Int, deadline: UInt64) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let now = monotonicNS()
                guard now < deadline else { throw BridgeError("数据包读取超过总时限。") }
                let remaining = deadline - now
                var timeout = timeval(tv_sec: Int(remaining / 1_000_000_000), tv_usec: Int32(max(1, (remaining % 1_000_000_000) / 1000)))
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
                let n = recv(fd, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw BridgeError(n == 0 ? "Pad 已断开连接。" : "读取超时或连接中断。") }
                offset += n
            }
        }
        return result
    }
    private func readRaw(maximum: Int = SecureChannel.maxPacket, timeoutSeconds: UInt64 = 8) throws -> Data {
        let deadline = monotonicNS() + timeoutSeconds * 1_000_000_000
        let header = try readExactly(4, deadline: deadline); let count = Int(header.uintBE(0, 4))
        guard count > 0, count <= maximum else { throw BridgeError("收到超出限制的数据包。") }
        return try readExactly(count, deadline: deadline)
    }
    private func writeRaw(_ body: Data) throws {
        guard !body.isEmpty, body.count <= Self.maxPacket else { throw BridgeError("发送帧超出大小限制。") }
        var packet = Data(); packet.appendBE(UInt32(body.count)); packet.append(body)
        try packet.withUnsafeBytes { buffer in
            var offset = 0
            while offset < packet.count {
                let n = send(fd, buffer.baseAddress!.advanced(by: offset), packet.count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw BridgeError("发送超时或 USB 已断开。") }
                offset += n
            }
        }
    }
    func sendBody(_ body: Data) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        guard sendSequence < UInt64.max else { throw BridgeError("会话序号耗尽，请重新连接。") }
        try writeRaw(PairCrypto.seal(body, key: sendKey, sequence: sendSequence)); sendSequence += 1
    }
    func sendJSON(_ object: [String: Any]) throws {
        try sendBody(Data([1]) + JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    func receive() throws -> Data {
        let result = try PairCrypto.open(readRaw(maximum: packetMaximum, timeoutSeconds: packetMaximum == 4096 ? 3 : 8), key: receiveKey, sequence: receiveSequence)
        guard receiveSequence < UInt64.max else { throw BridgeError("会话序号耗尽。") }
        receiveSequence += 1; return result
    }
}
