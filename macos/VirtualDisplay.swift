// Adapted from peetzweg/opendisplay (Philip Poloczek), GPL-3.0.
import AppKit
import CoreGraphics

// Runs only inside --display-host. Mode changes can pin a virtual display to
// its creating process on recent macOS; the UI must not own this native object.
@MainActor final class NativeVirtualDisplay {
    private let display: CGVirtualDisplay
    private let settings: CGVirtualDisplaySettings
    private var profile: Profile
    private var timer: Timer?
    private var refusals = 0
    private var closed = false
    var onHDRInvalid: ((AppMessage) -> Void)?
    var id: CGDirectDisplayID { display.displayID }
    static var supportsHDR: Bool {
        CGVirtualDisplayMode.instancesRespond(to: NSSelectorFromString("initWithWidth:height:refreshRate:transferFunction:"))
    }
    static func requireInteractiveConsole() throws {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return }
        if info["CGSSessionScreenIsLocked"] as? Bool == true || info[kCGSessionOnConsoleKey as String] as? Bool == false {
            throw BridgeError("Mac 已锁定或当前用户不在前台，请解锁后再连接拓展屏。")
        }
    }

    init(profile: Profile) throws {
        try Self.requireInteractiveConsole()
        self.profile = profile
        if profile.color == .hlg && !Self.supportsHDR { throw BridgeError("当前 macOS 没有 HDR 虚拟屏接口。") }
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(.main)
        descriptor.name = "Nextend · Xiaomi Pad"
        descriptor.maxPixelsWide = 3840; descriptor.maxPixelsHigh = 3840
        descriptor.sizeInMillimeters = CGSize(width: 281, height: 188)
        if profile.color == .hlg {
            descriptor.redPrimary = CGPoint(x: 0.64, y: 0.33)
            descriptor.greenPrimary = CGPoint(x: 0.30, y: 0.60)
            descriptor.bluePrimary = CGPoint(x: 0.15, y: 0.06)
            descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        }
        descriptor.vendorID = 0x5042; descriptor.productID = 0x0001; descriptor.serialNum = 0x25032
        descriptor.terminationHandler = { _, _ in log("系统释放了 Nextend 虚拟屏") }
        guard let created = CGVirtualDisplay(descriptor: descriptor) else { throw BridgeError("系统未能创建虚拟屏，请先断开其他 Nextend 连接。") }
        display = created
        settings = CGVirtualDisplaySettings(); settings.hiDPI = 1
        // Value 1 is the private API's EDR mode, verified on this macOS with
        // NSScreen headroom and an extended-linear test pattern. Guard selector.
        settings.modes = [profile.color == .hlg
            ? CGVirtualDisplayMode(width: UInt(profile.width / 2), height: UInt(profile.height / 2), refreshRate: Double(profile.fps), transferFunction: 1)
            : CGVirtualDisplayMode(width: UInt(profile.width / 2), height: UInt(profile.height / 2), refreshRate: Double(profile.fps))]
        guard display.apply(settings) else { throw BridgeError("当前 macOS 拒绝创建虚拟屏。") }
        startEnforcing()
    }
    private func startEnforcing() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.refusals < 3 else { return }
                do { try self.enforce(); self.refusals = 0 }
                catch {
                    self.refusals += 1; log(error.localizedDescription)
                    self.onHDRInvalid?(error.appMessage)
                }
            }
        }
    }
    func suspendEnforcement() { timer?.invalidate(); timer = nil; onHDRInvalid = nil }
    func prepareSDRFallback(_ replacement: Profile) throws {
        try Self.requireInteractiveConsole()
        guard !closed, replacement.color == .sdr,
              replacement.width == profile.width, replacement.height == profile.height,
              replacement.fps == profile.fps else { throw BridgeError("SDR 回退的虚拟屏配置不匹配。") }
        suspendEnforcement()
        profile = replacement; refusals = 0
        settings.modes = [CGVirtualDisplayMode(width: UInt(profile.width / 2), height: UInt(profile.height / 2), refreshRate: Double(profile.fps))]
        guard display.apply(settings) else { throw BridgeError("系统无法将当前虚拟屏切回 SDR。") }
        startEnforcing()
    }
    func waitUntilReady() async throws {
        var last: Error = BridgeError("虚拟屏尚未就绪。")
        for _ in 0..<40 {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            do {
                try enforce()
                return
            } catch { last = error }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw last
    }
    func enforce() throws {
        guard !closed else { throw CancellationError() }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode],
              let desired = modes.first(where: { $0.width == profile.width / 2 && $0.height == profile.height / 2 &&
                  $0.pixelWidth == profile.width && $0.pixelHeight == profile.height && abs($0.refreshRate - Double(profile.fps)) < 1 })
        else {
            let actual = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []).map { "\($0.width)x\($0.height)pt/\($0.pixelWidth)x\($0.pixelHeight)px@\($0.refreshRate)" }.joined(separator: ", ")
            throw BridgeError("macOS 未提供 \(profile.width)×\(profile.height) HiDPI @ \(profile.fps) Hz 模式。现有：\(actual)")
        }
        let current = CGDisplayCopyDisplayMode(id)
        if current?.pixelWidth != desired.pixelWidth || current?.width != desired.width || current?.pixelHeight != desired.pixelHeight || abs((current?.refreshRate ?? 0) - desired.refreshRate) > 0.5 || CGDisplayIsInMirrorSet(id) == 1 {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success else { throw BridgeError("无法配置虚拟屏。") }
            CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
            CGConfigureDisplayWithDisplayMode(config, id, desired, nil)
            guard CGCompleteDisplayConfiguration(config, .forSession) == .success else { throw BridgeError("macOS 拒绝切换 HiDPI 刷新率。") }
        }
        if profile.color == .hlg {
            guard headroom > 1 else { throw BridgeError("虚拟屏未获得 HDR 亮度范围。") }
            try validateHDRColorSpace()
        }
    }
    func describe() -> [String: Any] {
        let mode = CGDisplayCopyDisplayMode(id)
        return ["id": id, "width": mode?.width ?? 0, "height": mode?.height ?? 0,
                "pixelWidth": mode?.pixelWidth ?? 0, "pixelHeight": mode?.pixelHeight ?? 0,
                "refreshHz": mode?.refreshRate ?? 0, "mirrored": CGDisplayIsInMirrorSet(id) == 1,
                "edrHeadroom": headroom, "requestedColor": profile.color.rawValue]
    }
    private var headroom: CGFloat {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?.maximumExtendedDynamicRangeColorComponentValue ?? 1
    }
    private func validateHDRColorSpace() throws {
        // Default float capture uses the display profile. Refuse a changed ICC
        // profile instead of treating unknown primaries / transfer as sRGB.
        let source = CGDisplayCopyColorSpace(id)
        guard let target = CGColorSpace(name: CGColorSpace.extendedSRGB) else { throw BridgeError("无法读取 HDR 虚拟屏色彩配置。") }
        for rgb: [CGFloat] in [[0.8,0.1,0.1], [0.1,0.8,0.1], [0.1,0.1,0.8], [0.18,0.18,0.18], [0.5,0.5,0.5]] {
            guard let color = CGColor(colorSpace: source, components: rgb + [1]),
                  let components = color.converted(to: target, intent: .relativeColorimetric, options: nil)?.components,
                  components.count == 4, zip(components.prefix(3), rgb).allSatisfy({ abs($0 - $1) < 0.02 })
            else { throw BridgeError("虚拟屏 ICC 配置与 HDR 采集的 sRGB 来源不匹配。") }
        }
    }
    func close() { closed = true; suspendEnforcement() }
    deinit { timer?.invalidate() }
}
