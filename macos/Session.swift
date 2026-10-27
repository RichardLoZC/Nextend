import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo

struct SessionOptions {
    var profile = Profile()
    var codecPreference = CodecPreference.auto
    var wireless = false
    var host = ""
    var interface = "en0"
    var synthetic = false
    var capturePattern = false
    var seconds: Double = 0
    var reportPath: String?
    var requireHDR = false
    var fallbackReason: AppMessage?
    var requestedHDR = false
    var touchEnabled = false
    var trackpad = false
    var padSettings = PadSettings()
}

// Lifecycle is on MainActor; active video state is confined to `queue`.
// Stop and channel publication are protected by stateLock. Startup is awaited
// before queue teardown, so encoder/options never change during active use.
final class Session: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var options: SessionOptions
    private let reverseConnection: ReverseConnectionWaiter?
    private let pairingGeneration = PairStore.generation
    @MainActor private var pairingRevoked = false
    private let queue = DispatchQueue(label: "PadBridge.pipeline", qos: .userInteractive)
    private let sender = DispatchQueue(label: "PadBridge.writer", qos: .userInteractive)
    private var maxInFlight: Int { options.profile.frameCredits }
    private let stateLock = NSLock()
    private var stopping = false
    private var fallbackCancelled = false
    private var active = false // pipeline queue only
    private var storedChannel: SecureChannel?
    private var channel: SecureChannel? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return storedChannel }
        set { stateLock.lock(); defer { stateLock.unlock() }; storedChannel = newValue }
    }
    private var forward: (serial: String, port: UInt16)?
    private var encoder: VideoEncoder?
    private var stream: SCStream?
    private var hdrStream: CGDisplayStream?
    private var hdrConverter: HDRConverter?
    @MainActor private var hdrCaptureStarted = false
    private let hdrLifetime = HDRCaptureLifetime()
    let cleanupRecovery = ConnectionRecovery()
    private var display: VirtualDisplay?
    private var capturePattern: CapturePattern?
    private var tick: DispatchSourceTimer?
    private var controlTimer: DispatchSourceTimer?
    private var patternTimer: DispatchSourceTimer?
    private var lastSubmitted: UInt64 = 0
    private var nextSequence: UInt64 = 0
    private var pending: [UInt64: UInt64] = [:]
    private var forceKeyframe = true
    private var viewerVisible = true // optional Pad stats field; legacy receivers stay visible
    private var latestBuffer: CVPixelBuffer?
    private var cachedReplay = CachedFrameReplay()
    private var visibleSinceNS: UInt64?
    private var visibleDurationNS: UInt64 = 0
    private var captured: UInt64 = 0
    private var sourceFrames: UInt64 = 0
    private var lastTickSource: UInt64 = 0
    private var encoderRecovery = EncoderRecovery()
    private var encoded: UInt64 = 0
    private var rendered: UInt64 = 0
    private var skipped: UInt64 = 0
    private var bytes: UInt64 = 0
    private var pathSamples: [Double] = []
    private var encodeSamples: [Double] = []
    private var decodeSamples: [Double] = []
    private var rows: [[String: Any]] = []
    private var displayDescription: [String: Any] = [:]
    private var remote: [String: Any] = [:]
    private var encodedColor: [String: Any] = [:]
    private var decoderColor: [String: Any] = [:]
    private var captureEvidence: [String: Any] = [:]
    private var sourceEvidence: [String: Any] = [:]
    private var verifiedHDR = false
    private var highlightVerified = false
    private var startedNS: UInt64 = 0
    private var lastTickNS: UInt64 = 0
    private var lastTickEncoded: UInt64 = 0
    private var lastRemoteNS: UInt64 = 0
    private var writeFailureReason: AppMessage? // pipeline queue; reader/watchdog owns terminal errors
    private var ready = false
    private let touchInput = TouchInputController()
    private var pairResetPending = false // pipeline queue
    private var touchNegotiated = false // pipeline queue
    @MainActor private var touchReady = false
    @MainActor private var controlsReady = false
    @MainActor private var trackpadRequested = false
    @MainActor private var requestedSettings = PadSettings()
    @MainActor private var notchController: PadNotchController?
    @MainActor private var touchRequested = false
    @MainActor private var startupTask: Task<Void, Never>?
    enum StatusKind { case information, preparing, connected, hdrVerified, metrics }
    var onStatus: ((AppMessage, StatusKind) -> Void)?
    var onMetrics: (([String: Any]) -> Void)?
    var onPeerAddress: ((String) -> Void)?
    var onFinish: ((Bool) -> Void)?
    var onFallback: ((AppMessage, VirtualDisplay?) -> Void)?
    var onPeerStats: (([String: Any]) -> Void)?
    var onPairReset: (() -> Void)?
    var onTouchUnavailable: ((AppMessage) -> Void)?
    init(options: SessionOptions, retainedDisplay: VirtualDisplay? = nil, reverseConnection: ReverseConnectionWaiter? = nil) {
        self.options = options; self.display = retainedDisplay; self.reverseConnection = reverseConnection
    }
    private var isStopping: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stopping }
    private func status(_ text: AppMessage, kind: StatusKind = .information) { log(text.text); DispatchQueue.main.async { self.onStatus?(text, kind) } }

    @MainActor func launch() {
        touchRequested = options.touchEnabled; trackpadRequested = options.trackpad; requestedSettings = options.padSettings
        startupTask = Task { await self.start() }
    }
    @MainActor func setTouchEnabled(_ enabled: Bool, trackpad: Bool? = nil) {
        guard !pairingRevoked else { return }
        touchRequested = enabled
        if let trackpad { trackpadRequested = trackpad }
        guard touchReady, !isStopping else { return }
        guard queue.sync(execute: { touchNegotiated }) else {
            if enabled { touchRequested = false; onTouchUnavailable?("请更新 Pad 端以使用触屏。") }
            return
        }
        let command = touchInput.setEnabled(enabled, trackpad: trackpadRequested)
        if enabled && command["enabled"] as? Bool != true {
            touchRequested = false; onTouchUnavailable?("请在系统设置中允许 Nextend 使用辅助功能，然后开启触屏。")
        }
        sender.async { [weak self] in
            guard let self, !self.isStopping, let channel = self.channel else { return }
            do { try channel.sendJSON(command) } catch { self.writeFailed(error) }
        }
    }
    @MainActor func updatePadSettings(_ value: PadSettings) {
        requestedSettings = value
        notchController?.update(value.notch)
        guard controlsReady, !isStopping else { return }
        sendControl(value.json)
    }
    @MainActor func resetPairing() {
        pairingRevoked = true
        stateLock.lock(); fallbackCancelled = true; stateLock.unlock()
        touchRequested = false; touchInput.close(); touchReady = false
        // Revocation is local and immediate. A peer cannot veto it by withholding ACK.
        PairStore.revoke(); onPairReset?()
        guard !isStopping else { return }
        guard controlsReady else { cancel(reason: "配对已撤销，请通过 USB 重新连接。"); return }
        queue.sync { pairResetPending = true }; sendControl(["type": "reset-pairing"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.isStopping else { return }
            if self.queue.sync(execute: { self.pairResetPending }) { self.cancel(reason: "配对已撤销，请通过 USB 重新连接。") }
        }
    }
    private func sendControl(_ value: [String: Any]) {
        sender.async { [weak self] in
            guard let self, !self.isStopping, let channel = self.channel else { return }
            do { try channel.sendJSON(value) } catch { self.writeFailed(error) }
        }
    }
    @MainActor private func start() async {
        do {
            try options.profile.validate()
            try VirtualDisplay.requireInteractiveConsole()
            if !options.synthetic && !CGPreflightScreenCaptureAccess() {
                throw BridgeError("需要屏幕录制权限：点击“屏幕录制权限”，在系统设置中允许 Nextend，然后重启应用。")
            }
            status(options.wireless ? "正在连接加密无线…" : "正在建立 USB 转发并配对…")
            let initial = options; let initialGeneration = pairingGeneration; let reverse = reverseConnection
            let adbCancellation = ADBCancellation()
            let connectTask = Task.detached { () -> (SecureChannel, (String, UInt16)?) in
                try Task.checkCancellation()
                if initial.wireless {
                    if let socket = try reverse?.take() {
                        try Task.checkCancellation()
                        return (try SecureChannel(connected: socket, key: PairStore.load()), nil)
                    }
                    try Task.checkCancellation()
                    return (try SecureChannel(host: initial.host, port: 49371, key: PairStore.load(), interface: initial.interface), nil)
                }
                let setup = try ADB.prepare(pairingGeneration: initialGeneration, cancellation: adbCancellation)
                do {
                    // Activity startup may precede Surface creation by a few hundred milliseconds.
                    var last: Error = BridgeError("Pad 未就绪。")
                    for _ in 0..<10 {
                        try Task.checkCancellation()
                        do { return (try SecureChannel(host: "127.0.0.1", port: setup.port, key: setup.key, interface: nil), (setup.serial, setup.port)) }
                        catch { last = error; try await Task.sleep(for: .milliseconds(200)) }
                    }
                    throw last
                } catch { ADB.removeForward(serial: setup.serial, port: setup.port); throw error }
            }
            let connection = try await withTaskCancellationHandler(operation: { try await connectTask.value }, onCancel: { adbCancellation.cancel(); connectTask.cancel() })
            let channel = connection.0
            if let value = connection.1 { forward = (value.0, value.1) }
            self.channel = channel
            guard !isStopping else { channel.close(); return }
            let hello = try await Task.detached { try Self.json(channel.receive()) }.value
            guard !isStopping else { return }
            if hello["type"] as? String == "busy" { throw BridgeError("Pad 已连接其他会话，请先在 Mac 断开。") }
            guard hello["type"] as? String == "hello", hello["version"] as? Int == 1,
                  hello["input"] as? Bool == false else { throw BridgeError("Pad 协议版本不匹配。") }
            if !options.wireless, let address = hello["wifiAddress"] as? String, Self.validPeerAddress(address) {
                onPeerAddress?(address)
            }
            let requested = options.profile
            let capabilities = try await Task.detached {
                try channel.sendJSON(["type": "probe", "version": 1, "width": requested.width, "height": requested.height, "fps": requested.fps])
                return try Self.json(channel.receive())
            }.value
            guard !isStopping else { return }
            guard capabilities["type"] as? String == "capabilities", let codecs = capabilities["codecs"] as? [String] else { throw BridgeError("Pad 能力协商失败。") }
            if options.profile.color == .hlg {
                let colors = capabilities["colors"] as? [String] ?? []
                if !colors.contains(VideoColor.hlg.rawValue) || !codecs.contains("hevc") || !VirtualDisplay.supportsHDR {
                    try selectSDR("Mac 或 Pad 不支持当前配置的 HLG / Main10")
                }
                if #unavailable(macOS 15.0) { try selectSDR("HDR 采集需要 macOS 15 或更新版本") }
            }
            guard let codec = options.codecPreference.select(supported: codecs, color: options.profile.color)
            else { throw BridgeError("Pad 硬件不支持所选分辨率和帧率，请降低刷新率或分辨率。") }
            options.profile.codec = codec
            if options.profile.color == .hlg {
                do { encoder = try makeEncoder() }
                catch {
                    try selectSDR("Mac Main10 编码器初始化失败：\(error.appMessage)")
                    encoder = try makeSDREncoder(codecs: codecs)
                }
            } else { encoder = try makeSDREncoder(codecs: codecs) }
            let p = options.profile
            let supportsTouch = hello["touchVersion"] as? Int == 1
            var config: [String: Any] = ["type": "config", "version": 1, "width": p.width, "height": p.height,
                "fps": p.fps, "codec": p.codec, "color": p.color.rawValue, "bitDepth": p.color.bitDepth, "input": false]
            if supportsTouch { config["touchVersion"] = 1 }
            if hello["controlsVersion"] as? Int == 1 { config["controlsVersion"] = 1 }
            let response = try await Task.detached {
                try channel.sendJSON(config); return try Self.json(channel.receive())
            }.value
            guard response["type"] as? String == "ready" else {
                if response["type"] as? String == "hdr-error" { failHDR(AppMessage(raw: response["message"] as? String ?? "Pad HDR decoder initialization failed")); return }
                throw BridgeError(AppMessage(raw: response["message"] as? String ?? "Pad did not confirm the decoder configuration."))
            }
            if p.color == .hlg && (response["color"] as? String != p.color.rawValue || response["bitDepth"] as? Int != 10) {
                failHDR("Pad 未明确确认 HLG 10-bit 配置"); return
            }
            guard !isStopping else { channel.close(); return }
            controlsReady = config["controlsVersion"] as? Int == 1 && response["controlsVersion"] as? Int == 1
            queue.sync { touchNegotiated = supportsTouch && response["touchVersion"] as? Int == 1 }
            startControlLoop(channel)
            do {
                if let inherited = display, !inherited.canReconfigureForSDR {
                    display = nil
                    guard await inherited.closeAndWait() else {
                        cleanupRecovery.waitUntil { inherited.isReleased }
                        throw BridgeError("HDR 辅助进程未完成清理，无法启动 SDR。")
                    }
                    try Task.checkCancellation()
                }
                if let display { try display.prepareSDRFallback(p) }
                else { display = try VirtualDisplay(profile: p) }
                try await display!.waitUntilReady()
            } catch {
                if p.color == .hlg && !isStopping { failHDR(error.appMessage); return }
                throw error
            }
            guard !isStopping else { return }
            displayDescription = display!.describe()
            display?.onHDRInvalid = { [weak self] reason in self?.failHDR(reason) }
            if options.capturePattern { capturePattern = try CapturePattern(displayID: display!.id, fps: p.fps, hdr: p.color == .hlg) }
            log("Display: \(displayDescription); decoder: \(response["decoder"] ?? "unknown")")
            status("正在准备桌面采集…", kind: .preparing)
            if !options.synthetic && p.color == .hlg {
                do { try prepareHDRCapture(displayID: display!.id, profile: p) }
                catch { failHDR(error.appMessage); return }
            } else if !options.synthetic {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard !isStopping else { return }
                guard let screen = content.displays.first(where: { $0.displayID == display?.id }) else { throw BridgeError("采集 API 尚未发现虚拟屏。") }
                let config = SCStreamConfiguration()
                config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                config.colorSpaceName = CGColorSpace.itur_709
                config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
                config.width = p.width; config.height = p.height
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(p.fps * 2))
                // Capture surfaces also remain held by VideoToolbox. Give the
                // pool headroom independently of the end-to-end credit limit.
                config.queueDepth = maxInFlight + 2
                config.showsCursor = true; config.capturesAudio = false
                let capture = SCStream(filter: SCContentFilter(display: screen, excludingWindows: []), configuration: config, delegate: self)
                try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                stream = capture
            }
            guard !isStopping else { return }
            // Accept the first complete frame even if it arrives before
            // startCapture returns; a static desktop may not emit it again.
            queue.sync { active = true }
            if let hdrStream {
                hdrLifetime.retainUntilStopped(hdrStream)
                guard hdrStream.start() == .success else { hdrLifetime.didFailToStart(); failHDR("系统无法启动 HDR 浮点采集"); return }
                hdrCaptureStarted = true
            }
            if let stream {
                do { try await stream.startCapture() }
                catch { if p.color == .hlg { failHDR(error.appMessage); return }; throw error }
            }
            guard !isStopping else { return }
            queue.sync {
                startedNS = monotonicNS(); lastTickNS = startedNS
                visibleSinceNS = viewerVisible ? startedNS : nil
                lastTickEncoded = encoded; lastTickSource = sourceFrames; ready = true
            }
            try queue.sync { try startTimers() }
            touchInput.attach(display: display!.id); touchReady = true
            if !options.synthetic {
                notchController = PadNotchController(displayID: display!.id)
                notchController?.update(requestedSettings.notch)
            }
            status("\(p.width) × \(p.height) · \(p.fps) fps 目标 · \(p.codec.uppercased()) · \(p.color.title)", kind: .connected)
            if let reason = options.fallbackReason { status("已回退 SDR：\(reason)") }
            // The status callbacks above are queued on main. Report a missing
            // touch capability after them so the reason stays visible.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.setTouchEnabled(self.touchRequested); self.updatePadSettings(self.requestedSettings)
            }
        } catch { stop(reason: error.appMessage, success: false) }
    }
    private func selectSDR(_ reason: AppMessage) throws {
        if options.requireHDR { throw BridgeError("HDR 必须可用：\(reason)") }
        options.profile.color = .sdr; options.fallbackReason = reason
        status("已回退 SDR：\(reason)")
    }
    private func failHDR(_ reason: AppMessage) {
        stop(reason: "HDR 不可用：\(reason)", success: false, fallback: options.profile.color == .hlg && !options.requireHDR ? reason : nil)
    }
    private func makeEncoder() throws -> VideoEncoder {
        try VideoEncoder(profile: options.profile) { [weak self] result in
            guard let self else { return }
            self.queue.async { self.didEncode(result) }
        }
    }
    private func makeSDREncoder(codecs: [String]) throws -> VideoEncoder {
        do { return try makeEncoder() }
        catch where codecs.contains(options.profile.codec == "hevc" ? "h264" : "hevc") {
            options.profile.codec = options.profile.codec == "hevc" ? "h264" : "hevc"
            status("编码器初始化失败，已切换为 \(options.profile.codec.uppercased())。")
            return try makeEncoder()
        }
    }
    private static func validPeerAddress(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }), let first = UInt8(parts[0]) else { return false }
        return first > 0 && first < 224 && first != 127 && !(first == 169 && UInt8(parts[1]) == 254)
    }
    @MainActor private func prepareHDRCapture(displayID: CGDirectDisplayID, profile: Profile) throws {
        // SCK's canonical preset on macOS 27 emits P3/PQ 4:4:4, and overrides
        // did not produce trustworthy HLG on this virtual screen. Use the EDR
        // composite in its validated native sRGB profile, then own the HLG map.
        // Setting CGDisplayStream.colorSpace clips EDR to 1.0 on this macOS.
        hdrConverter = try HDRConverter(width: profile.width, height: profile.height)
        let properties: [CFString: Any] = [CGDisplayStream.showCursor: true,
            CGDisplayStream.minimumFrameTime: 1.0 / Double(profile.fps * 2), CGDisplayStream.queueDepth: 6]
        let lifetime = hdrLifetime
        guard let capture = CGDisplayStream(dispatchQueueDisplay: displayID, outputWidth: profile.width, outputHeight: profile.height,
            pixelFormat: Int32(kCVPixelFormatType_64RGBAHalf), properties: properties as CFDictionary, queue: queue,
            handler: { [weak self] state, _, surface, _ in
                if state == .stopped { lifetime.didStop(); return }
                guard let self else { return }
                guard self.active, state == .frameComplete, let surface else { return }
                self.sourceFrames += 1
                guard self.pending.count < self.maxInFlight else { self.skipped += 1; return }
                let started = monotonicNS()
                autoreleasepool {
                    do {
                        var unmanaged: Unmanaged<CVPixelBuffer>?
                        guard CVPixelBufferCreateWithIOSurface(nil, surface, nil, &unmanaged) == kCVReturnSuccess,
                              let buffer = unmanaged?.takeRetainedValue(), let converter = self.hdrConverter else { throw BridgeError("HDR 采集表面不可用。") }
                        if self.sourceEvidence.isEmpty || self.captured == 59 {
                            self.sourceEvidence = Self.describeBuffer(buffer); log("HDR 浮点源：\(self.sourceEvidence)")
                        }
                        self.submit(try converter.convert(buffer), capturedNS: started)
                    } catch { self.failHDR(error.appMessage) }
                }
            }) else { throw BridgeError("系统拒绝创建 HDR 浮点采集。") }
        hdrStream = capture
    }
    private func beginReader(_ channel: SecureChannel) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            do {
                while let self, !self.isStopping {
                    let message = try Self.json(channel.receive())
                    // Bound reader work; a peer cannot queue unlimited input
                    // ahead of the local off switch or teardown.
                    self.queue.sync { self.handle(message) }
                }
            } catch {
                // Preserve arrival order: an HDR rejection must be handled
                // before the EOF caused by the receiver closing that socket.
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.stop(reason: self.writeFailureReason ?? error.appMessage, success: false)
                }
            }
        }
    }
    private func startControlLoop(_ channel: SecureChannel) {
        // WindowServer and ScreenCaptureKit preparation can exceed the Pad's
        // packet deadline. Keep the authenticated control channel alive while
        // preparing capture, without counting startup as measured video time.
        queue.sync {
            lastRemoteNS = monotonicNS()
            let startupDeadline = lastRemoteNS + 30_000_000_000
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self, !self.isStopping else { return }
                let now = monotonicNS()
                self.touchInput.checkLiveness()
                if now - self.lastRemoteNS > 6_000_000_000 {
                    self.stop(reason: self.writeFailureReason ?? "控制连接超时，已释放虚拟屏。可重新连接。", success: false); return
                }
                if !self.ready && now >= startupDeadline {
                    self.stop(reason: "屏幕采集准备超时，请重试连接。", success: false); return
                }
                self.sender.async { [weak self] in
                    guard let self, !self.isStopping else { return }
                    do { try channel.sendJSON(["type": "ping"]) }
                    catch { self.writeFailed(error) }
                }
            }
            timer.resume(); controlTimer = timer
        }
        beginReader(channel)
    }
    private static func json(_ body: Data) throws -> [String: Any] {
        guard body.count > 1, body.count <= 65536, body.first == 1,
              let object = try JSONSerialization.jsonObject(with: body.dropFirst()) as? [String: Any]
        else { throw BridgeError("控制消息无效。") }
        return object
    }
    private func startTimers() throws {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.sample() }; timer.resume(); tick = timer
        if options.synthetic {
            let source = try PatternSource(profile: options.profile)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / options.profile.fps), leeway: .microseconds(100))
            timer.setEventHandler { [weak self] in
                guard let self, self.active else { return }
                self.sourceFrames += 1
                guard self.pending.count < self.maxInFlight else { self.skipped += 1; return }
                do { self.submit(try source.frame(self.nextSequence), capturedNS: monotonicNS()) }
                catch { self.stop(reason: error.appMessage, success: false) }
            }
            timer.resume(); patternTimer = timer
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard active else { return }
        sourceFrames += 1
        submit(buffer, capturedNS: monotonicNS())
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { stop(reason: "屏幕采集停止：\(error.appMessage)", success: false) }
    private func submit(_ buffer: CVPixelBuffer, capturedNS: UInt64) {
        guard active else { return }
        latestBuffer = buffer
        guard viewerVisible else { return }
        captured += 1
        if captureEvidence.isEmpty || (options.capturePattern && captured == 60) {
            captureEvidence = Self.describeBuffer(buffer)
            if options.capturePattern && options.profile.color == .hlg,
               let luma = captureEvidence["centerLuma10Bit"] as? [Int], luma.count == 6 {
                highlightVerified = zip(luma, [64, 446, 721, 818, 873, 912]).allSatisfy { abs($0 - $1) <= 4 }
            }
            log("采集格式：\(captureEvidence)")
        }
        // Never discard encoded reference frames: apply backpressure before encoding.
        // The display refresh / synthetic timer already sets the cadence.
        // An additional wall-clock gate drops valid frames after timer jitter.
        guard pending.count < maxInFlight else { skipped += 1; return }
        nextSequence += 1; lastSubmitted = capturedNS; pending[nextSequence] = capturedNS
        let force = forceKeyframe || cachedReplay.needed; forceKeyframe = false
        cachedReplay.submitted(nextSequence)
        do { try encoder?.encode(buffer, sequence: nextSequence, capturedNS: capturedNS, forceKeyframe: force) }
        catch { if options.profile.color == .hlg { failHDR(error.appMessage) } else { stop(reason: error.appMessage, success: false) } }
    }
    private func replayLatestIfNeeded() {
        guard active, cachedReplay.canSubmit(visible: viewerVisible, credits: maxInFlight - pending.count, hasFrame: latestBuffer != nil),
              let latestBuffer else { return }
        submit(latestBuffer, capturedNS: monotonicNS())
    }
    private func didEncode(_ result: Result<EncoderOutput, Error>) {
        guard active else { return }
        switch result {
        case .failure(let error):
            if options.profile.color == .hlg { failHDR(error.appMessage) } else { stop(reason: error.appMessage, success: false) }
        case .success(.dropped(let sequence)):
            pending.removeValue(forKey: sequence); encoderRecovery.didDrop(at: monotonicNS()); forceKeyframe = true
            cachedReplay.dropped(sequence)
            // Bound retry cadence if the hardware encoder repeatedly drops the recovery frame.
            queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in self?.replayLatestIfNeeded() }
        case .success(.frame(let frame)):
            encoderRecovery.didEncode()
            encoded += 1; bytes += UInt64(frame.bytes.count)
            if encodedColor.isEmpty { encodedColor = frame.colorInfo; log("编码格式：\(encodedColor)") }
            encodeSamples.append(Double(frame.encodedNS - frame.capturedNS) / 1e6)
            if encodeSamples.count > 6000 { encodeSamples.removeFirst(1000) }
            var body = Data([2]); body.appendBE(frame.sequence); body.appendBE(frame.capturedNS)
            body.append(frame.keyframe ? 1 : 0); body.append(frame.bytes)
            guard let channel else { return }
            sender.async { [weak self] in
                do { try channel.sendBody(body) } catch { self?.writeFailed(error) }
            }
        }
    }
    private func writeFailed(_ error: Error) {
        queue.async { [weak self] in
            guard let self, !self.isStopping else { return }
            // Keep receiving the peer's final rejection. A writer's EPIPE must
            // not overtake hdr-error. EOF / the existing bounded watchdog ends
            // the session if the peer sends no terminal message.
            if self.writeFailureReason == nil { self.writeFailureReason = error.appMessage }
        }
    }
    private func handle(_ json: [String: Any]) {
        guard !isStopping else { return }
        lastRemoteNS = monotonicNS()
        switch json["type"] as? String {
        case "touch":
            guard touchNegotiated else { stop(reason: "拒绝未协商的触屏消息。", success: false); return }
            do { try touchInput.receive(json) } catch { stop(reason: error.appMessage, success: false) }
        case "touch-state":
            guard touchNegotiated else { stop(reason: "拒绝未协商的触屏消息。", success: false); return }
        case "pair-reset":
            guard pairResetPending else { stop(reason: "拒绝未知控制消息。", success: false); return }
            pairResetPending = false
            stop(reason: "配对已撤销，请通过 USB 重新连接。", success: true)
        case "hdr-error": failHDR(AppMessage(raw: json["message"] as? String ?? "Pad HDR output failed"))
        case "ack":
            guard let seq = (json["seq"] as? NSNumber)?.uint64Value, let start = pending.removeValue(forKey: seq) else { stop(reason: "Pad 返回无效帧确认。", success: false); return }
            cachedReplay.acknowledged(seq, decoded: json["decoded"] as? Bool == true)
            if json["decoded"] as? Bool == true {
                rendered += 1; pathSamples.append(Double(monotonicNS() - start) / 1e6)
                if pathSamples.count > 6000 { pathSamples.removeFirst(1000) }
                if let delay = json["receiveToDecodeMs"] as? Double, delay.isFinite, delay >= 0 {
                    decodeSamples.append(delay)
                    if decodeSamples.count > 6000 { decodeSamples.removeFirst(1000) }
                }
            } else { skipped += 1; forceKeyframe = true }
            if cachedReplay.needed {
                queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in self?.replayLatestIfNeeded() }
            }
        case "keyframe":
            forceKeyframe = true
            // Static desktops may have no new SCStream frame after a Surface is recreated.
            cachedReplay.request(); replayLatestIfNeeded()
        case "stats":
            if let visible = json["viewerVisible"] as? Bool, visible != viewerVisible {
                let now = monotonicNS()
                if let since = visibleSinceNS { visibleDurationNS += now - since }
                visibleSinceNS = visible && ready ? now : nil
                viewerVisible = visible
                // A deliberate background pause is not a hardware-encoder stall.
                encoderRecovery.didEncode()
                if visible {
                    forceKeyframe = true
                    cachedReplay.request(); replayLatestIfNeeded()
                }
            }
            remote = json
            DispatchQueue.main.async { self.onPeerStats?(json) }
            if let format = json["videoFormat"] as? [String: Any] {
                decoderColor = format
                if options.profile.color == .hlg, format["color"] as? String == VideoColor.hlg.rawValue,
                   format["verified"] as? Bool == true, (format["rendered"] as? Int ?? 0) > 0,
                   encodedColor["main10"] as? Bool == true, !verifiedHDR {
                    verifiedHDR = true; status("HDR 已启用：HEVC Main10 · BT.2020 · HLG · Pad 输出格式已确认", kind: .hdrVerified)
                }
            }
        case "pong": break
        case "error": stop(reason: AppMessage(raw: json["message"] as? String ?? "Pad decoder failed."), success: false)
        default: stop(reason: "拒绝未知控制消息。", success: false)
        }
    }
    private func sample() {
        guard active else { return }
        let now = monotonicNS(); let elapsed = Double(now - startedNS) / 1e9
        // A static desktop may never emit a replacement for a dropped frame.
        // End a stalled session even after a single drop, rather than report a
        // connected black/stale picture forever. A successful output resets it.
        if viewerVisible && encoderRecovery.stalled(at: now) {
            let reason: AppMessage = "硬件编码器丢帧后未恢复，请降低帧率或分辨率。"
            if options.profile.color == .hlg { failHDR(reason) } else { stop(reason: reason, success: false) }
            return
        }
        if pending.values.contains(where: { now - $0 > 3_000_000_000 }) {
            if options.profile.color == .hlg && !verifiedHDR { failHDR("HDR 解码未在 3 秒内确认首帧"); return }
            stop(reason: "视频链路超时，已释放虚拟屏。可重新连接。", success: false); return
        }
        var row = remote
        row["seconds"] = elapsed; row["encodeFps"] = Double(encoded - lastTickEncoded) * 1e9 / Double(now - lastTickNS)
        row["sourceFps"] = Double(sourceFrames - lastTickSource) * 1e9 / Double(now - lastTickNS)
        row["sourceFrames"] = sourceFrames; row["encoderDropped"] = encoderRecovery.dropped; row["maxInFlight"] = maxInFlight
        row["pending"] = pending.count; row["captured"] = captured; row["encoded"] = encoded; row["skippedBeforeEncodeOrDecoder"] = skipped
        row["captureToDecodeAckP50Ms"] = percentile(pathSamples, 0.5); row["captureToDecodeAckP95Ms"] = percentile(pathSamples, 0.95)
        row["encodeP50Ms"] = percentile(encodeSamples, 0.5); row["megabitsPerSecond"] = Double(bytes) * 8 / elapsed / 1e6
        row["padDecodeP50Ms"] = percentile(decodeSamples, 0.5)
        row["color"] = options.profile.color.rawValue; row["hdrVerified"] = verifiedHDR
        row["fallbackReason"] = options.fallbackReason?.text ?? ""
        rows.append(row); if rows.count > 7200 { rows.removeFirst(600) }
        let metrics = row
        DispatchQueue.main.async { [weak self] in self?.onMetrics?(metrics) }
        lastTickNS = now; lastTickEncoded = encoded; lastTickSource = sourceFrames
        log(String(format: "编码 %.1f fps · Pad 呈现回调 %.1f fps · 解码往返 P95 %.1f ms · 队列 %d/%d", row["encodeFps"] as? Double ?? 0, remote["renderFps"] as? Double ?? 0, percentile(pathSamples, 0.95), pending.count, maxInFlight))
        let visibleSeconds = Double(visibleDurationNS + (visibleSinceNS.map { now - $0 } ?? 0)) / 1e9
        if options.profile.color == .hlg && !verifiedHDR && visibleSeconds > 8 { failHDR("8 秒内未收到 Pad HDR 输出确认"); return }
        if options.seconds > 0 && elapsed >= options.seconds {
            let highlightsOK = options.profile.color != .hlg || !options.capturePattern || highlightVerified
            stop(reason: highlightsOK ? "测试完成。" : "HDR 高光阶梯未通过，检查测试窗口是否被遮挡或源画面被截断。",
                 success: rendered > 0 && (options.profile.color != .hlg || verifiedHDR) && highlightsOK)
        }
    }
    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }
    /// User stop/sleep revokes a previously scheduled fallback even during teardown.
    func cancel(reason: AppMessage = "已断开，虚拟屏上的窗口由 macOS 收回。", success: Bool = true) {
        stateLock.lock(); fallbackCancelled = true; stateLock.unlock()
        stop(reason: reason, success: success)
    }
    func stop(reason: AppMessage = "已断开，虚拟屏上的窗口由 macOS 收回。", success: Bool = true, fallback: AppMessage? = nil) {
        stateLock.lock()
        if stopping { stateLock.unlock(); return }
        stopping = true; stateLock.unlock()
        reverseConnection?.cancel()
        touchInput.close()
        channel?.close()
        Task { @MainActor in
            self.notchController?.close(); self.notchController = nil
            self.display?.suspendEnforcement()
            self.startupTask?.cancel()
            // ADB can create a forward before returning it. Wait for ownership
            // transfer / rollback before reporting completion or allowing quit.
            await self.startupTask?.value
            self.startupTask = nil
            self.channel?.close()
            self.display?.suspendEnforcement()
            var cleanupFailure: AppMessage?
            if let hdrStream = self.hdrStream, self.hdrCaptureStarted {
                // CGDisplayStreamStop returns before the final callback. Keep
                // the stream alive until .stopped, as required by its contract.
                self.queue.sync { self.active = false }
                if !(await self.hdrLifetime.stop(hdrStream)) {
                    let lifetime = self.hdrLifetime
                    self.cleanupRecovery.waitUntil { lifetime.isStopped }
                    cleanupFailure = "正在等待 HDR 采集停止；确认后会自动恢复连接入口。"
                }
                self.hdrCaptureStarted = false
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.queue.async {
                    self.active = false; self.tick?.cancel(); self.tick = nil; self.controlTimer?.cancel(); self.controlTimer = nil
                    self.patternTimer?.cancel(); self.patternTimer = nil
                    self.encoder?.close(); self.encoder = nil; self.pending.removeAll(); self.latestBuffer = nil
                    self.hdrConverter = nil
                    continuation.resume()
                }
            }
            if let stream = self.stream { try? await stream.stopCapture() }
            self.capturePattern?.close(); self.capturePattern = nil
            self.stream = nil; self.hdrStream = nil
            if let forward = self.forward {
                self.forward = nil
                await Task.detached { ADB.removeForward(serial: forward.serial, port: forward.port) }.value
            }
            self.stateLock.lock(); let canFallback = !self.fallbackCancelled; self.stateLock.unlock()
            if self.cleanupRecovery.check(), canFallback, let fallback, let onFallback = self.onFallback {
                // Keep the owned display through an HDR → SDR transition.
                // Reapplying SDR settings avoids WindowServer's asynchronous
                // destroy/recreate race for the same monitor identity.
                let retainedDisplay = self.display; self.display = nil
                self.queue.sync { self.writeReport(reason: reason, success: false) }
                log(reason.text); self.onStatus?(reason, .information)
                onFallback(fallback, retainedDisplay)
                return
            }
            if let retiredDisplay = self.display {
                self.display = nil
                if !(await retiredDisplay.closeAndWait()) {
                    self.cleanupRecovery.waitUntil { retiredDisplay.isReleased }
                    cleanupFailure = "正在等待 macOS 释放虚拟屏；确认后会自动恢复连接入口。"
                }
            }
            let released = self.cleanupRecovery.check()
            let finalReason = released ? reason : (cleanupFailure ?? reason)
            let completed = success && self.ready && released
            self.queue.sync { self.writeReport(reason: finalReason, success: completed) }
            log(finalReason.text); self.onStatus?(finalReason, .information)
            self.onFinish?(completed)
        }
    }
    private func writeReport(reason: AppMessage, success: Bool) {
        guard let path = options.reportPath else { return }
        let p = options.profile
        let report: [String: Any] = ["success": success, "reason": reason.text, "test": options.synthetic ? "synthetic-encode-transport-decode" : (options.capturePattern ? "desktop-capture-pattern" : "desktop-capture"),
            "timestampUTC": ISO8601DateFormatter().string(from: Date()), "width": p.width, "height": p.height, "targetFps": p.fps,
            "codec": p.codec, "transport": options.wireless ? "wifi-encrypted" : "usb-adb-encrypted", "color": p.color.rawValue,
            "requestedHDR": options.requestedHDR, "hdrVerified": verifiedHDR, "fallbackReason": options.fallbackReason?.text ?? "",
            "hdrHighlightVerified": highlightVerified,
            "captureFormat": captureEvidence, "encodedFormat": encodedColor, "decoderFormat": decoderColor,
            "sourceCapture": sourceEvidence, "captureBackend": options.synthetic ? "synthetic" : (p.color == .hlg ? "CGDisplayStream-extended-sRGB" : "ScreenCaptureKit"),
            "virtualDisplay": displayDescription, "encoded": encoded, "decodedAcknowledgements": rendered,
            "captureToDecodeAckP50Ms": percentile(pathSamples, 0.5), "captureToDecodeAckP95Ms": percentile(pathSamples, 0.95),
            "note": "renderFps is MediaCodec OnFrameRendered callbacks; acknowledgement delay ends at decoder output release and includes return transport. Neither measures photons or physical color accuracy. Synthetic tests do not measure ScreenCaptureKit.", "samples": rows]
        do { let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]); try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
        catch { log("无法写入测试报告：\(error)") }
    }
    private static func describeBuffer(_ buffer: CVPixelBuffer) -> [String: Any] {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let chars = (0..<4).map { UInt8((format >> (24 - $0 * 8)) & 255) }
        var evidence: [String: Any] = ["pixelFormat": String(bytes: chars, encoding: .ascii) ?? "unknown"]
        for (name, key) in [("primaries", kCVImageBufferColorPrimariesKey), ("transfer", kCVImageBufferTransferFunctionKey), ("matrix", kCVImageBufferYCbCrMatrixKey)] {
            evidence[name] = CVBufferCopyAttachment(buffer, key, nil) as? String ?? "unknown"
        }
        if format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange {
            CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
                let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                let row = base.advanced(by: (height / 2) * stride).assumingMemoryBound(to: UInt16.self)
                evidence["centerLuma10Bit"] = (0..<6).map { Int(row[(2 * $0 + 1) * width / 12] >> 6) }
            }
        }
        if format == kCVPixelFormatType_64RGBAHalf {
            CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
                let row = base.advanced(by: (height / 2) * stride).assumingMemoryBound(to: UInt16.self)
                evidence["centerExtendedSRGBRed"] = (0..<6).map { Double(Float16(bitPattern: row[(2 * $0 + 1) * width / 12 * 4])) }
            }
        }
        return evidence
    }
}
