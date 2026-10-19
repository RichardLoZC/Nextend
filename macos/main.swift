import AppKit
import CryptoKit

if CommandLine.arguments.contains("--display-host") {
    MainActor.assumeIsolated { DisplayHost.run() }
    exit(0)
}
if CommandLine.arguments.contains("--self-test") {
    do { try runSelfTests(); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
}
if CommandLine.arguments.contains("--help") {
    print("""
    Nextend: --probe-display | --self-test | --benchmark | --capture-test | --connect
      --fps 60|90|120 --width 3200 --height 2136 --codec auto|hevc|h264 (default: auto)
      --bitrate 45 (Mbps) --seconds 30 --report /absolute/report.json
      --host PAD_IPV4 --interface en0 (wireless; pair through USB first)
      --hdr (request HLG10 with SDR fallback) | --require-hdr (fail instead of fallback)
    Without arguments: native Mac control window.
    """)
    exit(0)
}
let application = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.setActivationPolicy(CommandLine.arguments.count > 1 ? .accessory : .regular)
let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
let appMenu = NSMenu(); appMenu.addItem(withTitle: L("退出 Nextend", "Quit Nextend"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = appMenu
application.mainMenu = menu
application.run()

func runSelfTests() throws {
    func check(_ value: Bool, _ message: String) throws { if !value { throw BridgeError(AppMessage(raw: message)) } }
    let key = Data((0..<32).map(UInt8.init)), salt = Data((32..<96).map(UInt8.init))
    let session = PairCrypto.derive(key: key, salt: salt, direction: "mac-to-pad")
    let body = Data("PadBridge cross-platform test".utf8)
    let packet = try PairCrypto.seal(body, key: session, sequence: 7)
    let expectedKey = "c3d3fda910fc54539d4778b98e44fe396470b6e80c14392726f25ff008488494"
    let expectedPacket = "0000000000000007fd0af527e7afb36d57816eeb4ef21d708a7a1312fbb0170876732ec9e20925d5171cf0030cf6af4b1ce6989325"
    try check(session.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() } == expectedKey, "HKDF golden vector")
    try check(packet.map { String(format: "%02x", $0) }.joined() == expectedPacket, "AES-GCM golden vector")
    try check(try PairCrypto.open(packet, key: session, sequence: 7) == body, "AES-GCM roundtrip")
    var corrupt = packet; corrupt[corrupt.count - 1] ^= 1
    do { _ = try PairCrypto.open(corrupt, key: session, sequence: 7); throw BridgeError("tampering accepted") } catch is CryptoKitError {}
    do { _ = try PairCrypto.open(packet, key: session, sequence: 8); throw BridgeError("replay accepted") } catch let e as BridgeError { try check(e.message == "加密帧序号错误。", "replay rejection") }
    let proof = PairCrypto.proof(key: key, role: "pad", salt: salt)
    try check(PairCrypto.verify(proof, key: key, role: "pad", salt: salt), "HMAC")
    try check(!PairCrypto.verify(proof, key: key, role: "mac", salt: salt), "role separation")
    for fps in [60, 90, 120] { var p = Profile(); p.fps = fps; try p.validate() }
    var hdrProfile = Profile(); hdrProfile.color = .hlg; try hdrProfile.validate()
    hdrProfile.codec = "h264"
    do { try hdrProfile.validate(); throw BridgeError("HDR/H264 accepted") } catch let e as BridgeError { try check(e.message == "HDR 需要 HEVC Main10；H.264 仅支持 SDR。", "HDR requires HEVC") }
    try check(CodecPreference.auto.select(supported: ["h264", "hevc"], color: .sdr) == "hevc", "automatic HEVC priority")
    try check(CodecPreference.auto.select(supported: ["h264"], color: .sdr) == "h264", "legacy SDR fallback")
    try check(CodecPreference.auto.select(supported: ["h264"], color: .hlg) == nil, "no HDR mislabeling")
    try check(CodecPreference.h264.select(supported: ["hevc"], color: .sdr) == "hevc", "unsupported diagnostic preference falls back")
    try check(CodecPreference.auto.select(supported: ["av1"], color: .sdr) == nil, "unknown codecs rejected")
    try check(CodecPreference.h264.select(supported: ["hevc", "h264"], color: .hlg) == "hevc", "HDR always Main10")
    for fps in [60, 90, 120] {
        let native = Profile(fps: fps)
        let lower = Profile(width: 2400, height: 1600, fps: fps)
        try check(native.frameCredits == 4, "native resolution preserves latency bound")
        try check(lower.frameCredits <= 6 && lower.frameCredits == (fps == 60 ? 4 : 6), "high-refresh credits respect receiver capacity")
    }
    var recovery = EncoderRecovery()
    try check(!recovery.stalled(at: 9_000_000_000), "static desktop without drops stays connected")
    recovery.didDrop(at: 10_000_000_000)
    try check(!recovery.stalled(at: 12_000_000_000), "transient frame drop has a recovery window")
    recovery.didDrop(at: 12_000_000_000)
    try check(recovery.stalled(at: 13_000_000_001), "new drops do not extend the deadline")
    recovery.didEncode()
    try check(!recovery.stalled(at: 20_000_000_000) && recovery.dropped == 2, "successful output clears the stall but keeps diagnostics")
    recovery.didDrop(at: 20_000_000_000)
    try check(recovery.stalled(at: 23_000_000_001), "single dropped static frame cannot hang forever")
    try HDRConverter.selfTest()
    try touchSelfTest()
    try reverseConnectionSelfTest()
    try check(AppMessage.translations.count > 100, "bundled English message catalog")
    let nested: AppMessage = "已回退 SDR：\(AppMessage(stringLiteral: "Pad 未就绪。"))"
    try check(nested.render(english: true) == "Fell back to SDR: The Pad is not ready.", "nested English status")
    try check(nested.render(english: false) == "已回退 SDR：Pad 未就绪。", "language switch preserves message")
    let roundTripMessage = try JSONDecoder().decode(AppMessage.self, from: JSONEncoder().encode(nested))
    try check(roundTripMessage.render(english: true) == nested.render(english: true), "helper message preserves localization")
    let untrusted = "remote {999999999999999999999999999999999} {0}"
    try check(AppMessage(raw: untrusted).render(english: true) == untrusted, "remote text is never a format template")
    let parameter: AppMessage = "连接失败：\(untrusted)"
    try check(parameter.render(english: true) == "Connection failed: " + untrusted, "nested argument is literal")
    var invalid = Profile(); invalid.fps = 144
    do { try invalid.validate(); throw BridgeError("invalid profile accepted") } catch let e as BridgeError { try check(e.message.hasPrefix("无效画面配置"), "profile bounds") }
    print("key=" + session.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() })
    print("packet=" + packet.map { String(format: "%02x", $0) }.joined())
    print("proof=" + proof.map { String(format: "%02x", $0) }.joined())
    print("PASS: crypto integrity, replay rejection, role separation, profile validation")
}
