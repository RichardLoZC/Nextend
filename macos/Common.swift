import Foundation
import CryptoKit
import Security

struct BridgeError: LocalizedError {
    let text: AppMessage
    init(_ message: AppMessage) { text = message }
    var message: String { text.render(english: false) }
    var errorDescription: String? { text.text }
}

func monotonicNS() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func log(_ message: String) { print("[Nextend] \(message)"); fflush(stdout) }

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    func uintBE(_ offset: Int, _ count: Int) -> UInt64 {
        subdata(in: offset..<(offset + count)).reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

enum VideoColor: String {
    case sdr = "bt709-limited-sdr"
    case hlg = "bt2020-limited-hlg10"
    var title: String { self == .hlg ? "HDR · HLG 10-bit" : "SDR · BT.709" }
    var bitDepth: Int { self == .hlg ? 10 : 8 }
}

struct Profile {
    var width = 3200
    var height = 2136
    var fps = 60
    var bitrate = 45_000_000
    var codec = "hevc"
    var color: VideoColor = .sdr
    // Lower-resolution high-refresh capture benefits from a small extra window.
    // At native resolution it only adds encoder latency. Never exceed the Pad's
    // six-frame decoder accounting limit, including at a 120 fps target.
    var frameCredits: Int { fps > 60 && width * height <= 2400 * 1600 ? 6 : 4 }
    func validate() throws {
        guard color != .hlg || codec == "hevc" else { throw BridgeError("HDR 需要 HEVC Main10；H.264 仅支持 SDR。") }
        guard [60, 90, 120].contains(fps), width >= 640, width <= 3840,
              height >= 480, height <= 2160, width % 4 == 0, height % 4 == 0,
              ["hevc", "h264"].contains(codec), (color != .hlg || codec == "hevc"),
              (5_000_000...120_000_000).contains(bitrate)
        else { throw BridgeError("无效画面配置：需要偶数 HiDPI 尺寸和 60/90/120 fps。") }
    }
}

/// The GUI always uses automatic selection. Explicit preferences exist only
/// for CLI diagnostics; negotiation still requires a compatible hardware path.
enum CodecPreference: String {
    case auto, hevc, h264
    func select(supported: [String], color: VideoColor) -> String? {
        let order = color == .hlg ? ["hevc"] : (self == .h264 ? ["h264", "hevc"] : ["hevc", "h264"])
        return order.first { supported.contains($0) }
    }
}

struct EncoderRecovery {
    private(set) var dropped: UInt64 = 0
    private var firstDropNS: UInt64?
    mutating func didDrop(at now: UInt64) {
        dropped += 1
        if firstDropNS == nil { firstDropNS = now }
    }
    mutating func didEncode() { firstDropNS = nil }
    func stalled(at now: UInt64) -> Bool {
        guard let first = firstDropNS, now >= first else { return false }
        return now - first > 3_000_000_000
    }
}

enum PairCrypto {
    static let context = "PadBridge/v1/"
    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess)
        return Data(bytes)
    }
    static func proof(key: Data, role: String, salt: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data((context + role).utf8) + salt, using: SymmetricKey(data: key)))
    }
    static func verify(_ proof: Data, key: Data, role: String, salt: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data((context + role).utf8) + salt, using: SymmetricKey(data: key))
    }
    static func derive(key: Data, salt: Data, direction: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: salt,
                               info: Data((context + direction).utf8), outputByteCount: 32)
    }
    static func nonce(_ sequence: UInt64) throws -> AES.GCM.Nonce {
        var bytes = Data(repeating: 0, count: 4); bytes.appendBE(sequence)
        return try AES.GCM.Nonce(data: bytes)
    }
    static func seal(_ body: Data, key: SymmetricKey, sequence: UInt64) throws -> Data {
        var aad = Data(); aad.appendBE(sequence)
        let box = try AES.GCM.seal(body, using: key, nonce: nonce(sequence), authenticating: aad)
        return aad + box.ciphertext + box.tag
    }
    static func open(_ packet: Data, key: SymmetricKey, sequence: UInt64) throws -> Data {
        guard packet.count >= 25, packet.uintBE(0, 8) == sequence else { throw BridgeError("加密帧序号错误。") }
        let box = try AES.GCM.SealedBox(nonce: nonce(sequence), ciphertext: packet.dropFirst(8).dropLast(16), tag: packet.suffix(16))
        return try AES.GCM.open(box, using: key, authenticating: packet.prefix(8))
    }
}
