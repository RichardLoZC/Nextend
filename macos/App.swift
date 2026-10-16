import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var session: Session?
    private let statusLabel = glassText("", size: 13, muted: true)
    private let rate = NSSegmentedControl(labels: ["60 fps", "90 fps", "120 fps"], trackingMode: .selectOne, target: nil, action: nil)
    private let resolution = NSPopUpButton()
    private let hdr = NSSwitch()
    private let colorLabel = glassText("SDR · BT.709", size: 12, weight: .medium)
    private let transport = NSSegmentedControl(labels: ["", ""], trackingMode: .selectOne, target: nil, action: nil)
    private let language = GlassActionButton()
    private let ip = NSTextField(string: UserDefaults.standard.string(forKey: "padIP") ?? "")
    private let interface = NSTextField(string: UserDefaults.standard.string(forKey: "interface") ?? "en0")
    private var connectButton: NSButton!
    private let connectionHeading = glassText("", size: 19, weight: .semibold)
    private let deviceArt = DeviceBridgeView()
    private let metricLabels = (0..<3).map { _ in glassText("—", size: 27, weight: .medium) }
    private var wirelessFields: NSView?
    private var settingControls: [NSControl] = []
    private var localizedBindings: [() -> Void] = []
    private var statusItem: NSStatusItem?
    private var activity: NSObjectProtocol?
    private enum ConnectionState { case idle, connecting, connected, finished(Bool) }
    private var connectionState: ConnectionState = .idle
    private var lastMessage: AppMessage = "用 USB 连接并打开 Nextend，即可开始。"
    private var activeWireless = false
    private var outputColor = VideoColor.sdr
    private var hdrVerified = false
    private var fallbackUsed = false
    private var restartRequired = false
    private var quitting = false
    private var signalSources: [DispatchSourceSignal] = []
    private let arguments = CommandLine.arguments

    func applicationDidFinishLaunching(_ notification: Notification) {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                if self?.session == nil, self?.arguments.contains("--probe-display") == true { exit(128 + number) }
                self?.session?.cancel(reason: "收到退出信号，连接已中止。", success: false)
                NSApp.terminate(nil)
            }
            source.resume(); signalSources.append(source)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.screensDidSleepNotification, object: nil)
        if arguments.contains("--probe-display") { probe(); return }
        if arguments.contains("--benchmark") || arguments.contains("--connect") || arguments.contains("--capture-test") {
            do { start(try cliOptions(), cli: true) }
            catch { log(error.localizedDescription); exit(1) }
            return
        }
        makeWindow()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Nextend")
        refreshLanguage()
    }
    private func cliOptions() throws -> SessionOptions {
        var options = SessionOptions(); options.synthetic = arguments.contains("--benchmark")
        options.capturePattern = arguments.contains("--capture-test")
        let valued = ["--fps", "--width", "--height", "--codec", "--bitrate", "--seconds", "--report", "--host", "--interface"]
        for key in valued where arguments.contains(key) {
            guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { throw BridgeError("\(key) 缺少参数。") }
        }
        func value(_ key: String, _ fallback: String) -> String { arguments.firstIndex(of: key).map { arguments[$0 + 1] } ?? fallback }
        guard let fps = Int(value("--fps", "60")), let width = Int(value("--width", "3200")), let height = Int(value("--height", "2136")),
              let bitrate = Int(value("--bitrate", "45")), let seconds = Double(value("--seconds", (options.synthetic || options.capturePattern) ? "30" : "0")), seconds.isFinite, seconds >= 0,
              (5...120).contains(bitrate) else { throw BridgeError("命令行参数无效。") }
        guard let preference = CodecPreference(rawValue: value("--codec", "auto")) else { throw BridgeError("编码参数需要 auto、hevc 或 h264。") }
        options.codecPreference = preference
        options.profile = Profile(width: width, height: height, fps: fps, bitrate: bitrate * 1_000_000, codec: preference == .h264 ? "h264" : "hevc")
        options.requestedHDR = arguments.contains("--hdr") || arguments.contains("--require-hdr")
        options.profile.color = options.requestedHDR ? .hlg : .sdr
        options.requireHDR = arguments.contains("--require-hdr")
        options.seconds = seconds; options.reportPath = arguments.contains("--report") ? value("--report", "") : nil
        options.wireless = arguments.contains("--host"); options.host = value("--host", ""); options.interface = value("--interface", "en0")
        try options.profile.validate(); return options
    }
    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 690), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Nextend"; window.center(); window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 880, height: 710)
        window.appearance = NSAppearance(named: .aqua); window.titlebarAppearsTransparent = true
        let background = GlassBackdropView(); window.contentView = background
        func fill(_ stack: NSStackView) -> NSStackView {
            for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            return stack
        }
        func label(_ zh: String, _ en: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, muted: Bool = false) -> NSTextField {
            let view = glassText(L(zh, en), size: size, weight: weight, muted: muted)
            localizedBindings.append { view.stringValue = L(zh, en) }
            return view
        }
        func action(_ zh: String, _ en: String, _ selector: Selector, primary: Bool = false) -> GlassActionButton {
            let button = GlassActionButton(); button.target = self; button.action = selector; button.primary = primary
            localizedBindings.append { button.title = L(zh, en); button.invalidateIntrinsicContentSize(); button.needsDisplay = true }
            return button
        }
        func group(_ zh: String, _ en: String, _ control: NSView) -> NSStackView {
            fill(glassStack([label(zh, en, size: 12, weight: .medium, muted: true), control], spacing: 7))
        }
        let mark = NSImageView(); mark.image = NSImage(named: "AppIcon"); mark.imageScaling = .scaleProportionallyUpOrDown
        mark.setAccessibilityLabel("Nextend"); mark.widthAnchor.constraint(equalToConstant: 40).isActive = true; mark.heightAnchor.constraint(equalToConstant: 40).isActive = true
        language.target = self; language.action = #selector(languageChanged)
        language.setAccessibilityLabel("语言 / Language")
        language.widthAnchor.constraint(equalToConstant: 84).isActive = true
        language.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let headerSpace = NSView(); headerSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = glassStack([mark, glassText("Nextend", size: 23, weight: .semibold), headerSpace, language], vertical: false, spacing: 14)
        header.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let metricTitles = [("编码 · fps", "Encoded · fps"), ("Pad 呈现 · fps", "Pad rendered · fps"), ("解码往返 P95 · ms", "Decode RTT P95 · ms")]
        let metrics = NSStackView(views: zip(metricLabels, metricTitles).map { value, titles in
            glassStack([value, label(titles.0, titles.1, size: 10, muted: true)], spacing: 5)
        })
        metrics.orientation = .horizontal; metrics.distribution = .fillEqually; metrics.spacing = 10
        metrics.heightAnchor.constraint(equalToConstant: 67).isActive = true
        let divider = NSBox(); divider.boxType = .separator
        statusLabel.maximumNumberOfLines = 4; statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 65).isActive = true
        let status = fill(glassStack([connectionHeading, statusLabel], spacing: 8))
        let hero = fill(glassStack([label("拓展桌面", "Extend your desktop", size: 30, weight: .semibold), deviceArt, metrics, divider, status], spacing: 21))
        deviceArt.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let left = GlassSurface(); left.embed(hero, padding: 28)
        rate.selectedSegment = 0; rate.segmentStyle = .rounded
        transport.selectedSegment = 0; transport.segmentStyle = .rounded; transport.target = self; transport.action = #selector(transportChanged)
        for segment in 0..<2 { transport.setWidth(133, forSegment: segment) }
        for segment in 0..<3 { rate.setWidth(88, forSegment: segment) }
        resolution.addItems(withTitles: ["3200 × 2136", "2400 × 1600"])
        resolution.controlSize = .large; resolution.font = .systemFont(ofSize: 13)
        for field in [ip, interface] { field.font = .monospacedSystemFont(ofSize: 12, weight: .regular); field.bezelStyle = .roundedBezel; field.heightAnchor.constraint(equalToConstant: 30).isActive = true }
        let addresses = glassStack([group("Pad IP", "Pad IP", ip), group("网卡", "Interface", interface)], vertical: false, spacing: 10)
        interface.widthAnchor.constraint(equalToConstant: 70).isActive = true
        ip.widthAnchor.constraint(equalTo: addresses.widthAnchor, constant: -80).isActive = true
        addresses.isHidden = true; wirelessFields = addresses
        hdr.state = .off; hdr.target = self; hdr.action = #selector(hdrChanged)
        let hdrInfo = NSButton(title: "HDR", target: self, action: #selector(showHDRInfo)); hdrInfo.bezelStyle = .inline
        let colorRow = glassStack([colorLabel, NSView(), hdrInfo, hdr], vertical: false, spacing: 8)
        connectButton = action("连接", "Connect", #selector(connect), primary: true); connectButton.keyEquivalent = "\r"
        connectButton.heightAnchor.constraint(equalToConstant: 45).isActive = true
        let spacer = NSView(); spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 12).isActive = true
        let rightContents = fill(glassStack([
            label("连接与画质", "Connection & quality", size: 18, weight: .semibold), transport,
            group("分辨率", "Resolution", resolution), group("目标帧率", "Target frame rate", rate),
            addresses, colorRow, spacer, connectButton
        ], spacing: 20))
        let right = GlassSurface(); right.embed(rightContents); right.widthAnchor.constraint(equalToConstant: 338).isActive = true
        let main = glassStack([left, right], vertical: false, spacing: 18)
        NSLayoutConstraint.activate([left.heightAnchor.constraint(equalTo: main.heightAnchor), right.heightAnchor.constraint(equalTo: main.heightAnchor), left.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -356)])
        main.setContentHuggingPriority(.defaultLow, for: .vertical)
        let permission = action("屏幕录制权限", "Screen recording", #selector(permission))
        let arrangement = action("排列显示器", "Arrange displays", #selector(arrangement))
        let footer = glassStack([permission, arrangement, NSView()], vertical: false, spacing: 10)
        footer.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let root = fill(glassStack([header, main, footer], spacing: 18))
        root.translatesAutoresizingMaskIntoConstraints = false; background.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 24), root.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -24), root.topAnchor.constraint(equalTo: background.topAnchor, constant: 18), root.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -20)])
        settingControls = [rate, transport, resolution, ip, interface, hdr]
        refreshLanguage(); showWindow()
    }
    @objc private func languageChanged() { AppLanguage.select(english: !AppLanguage.english); refreshLanguage() }
    private func refreshLanguage() {
        localizedBindings.forEach { $0() }
        language.title = AppLanguage.english ? "中文" : "English"; language.needsDisplay = true
        language.setAccessibilityLabel(AppLanguage.english ? "切换到中文" : "Switch to English")
        transport.setLabel(L("USB 有线", "USB"), forSegment: 0); transport.setLabel(L("加密无线", "Encrypted Wi-Fi"), forSegment: 1)
        rate.toolTip = L("60 fps 已验证；90 / 120 fps 为实验档，实际帧率取决于设备与网络。", "60 fps has been tested. 90 / 120 fps are experimental; actual rates depend on the device and network.")
        ip.placeholderString = L("Pad 的 IPv4 地址", "Pad IPv4 address")
        hdr.setAccessibilityLabel(L("启用 HDR", "Enable HDR"))
        hdr.toolTip = L("HEVC Main10 / HLG；不可用时回退 SDR。", "HEVC Main10 / HLG; falls back to SDR if unavailable.")
        renderConnection(); rebuildMenus()
    }
    private func renderConnection() {
        statusLabel.stringValue = lastMessage.text
        switch connectionState {
        case .idle: connectionHeading.stringValue = L("等待连接", "Ready to connect")
        case .connecting: connectionHeading.stringValue = L("正在连接", "Connecting")
        case .connected: connectionHeading.stringValue = L("已连接", "Connected") + " · " + (activeWireless ? L("加密无线", "Encrypted Wi-Fi") : "USB")
        case .finished(let success): connectionHeading.stringValue = success ? L("已断开", "Disconnected") : L("连接已结束", "Connection ended")
        }
        if case .connected = connectionState { connectButton?.title = L("断开连接", "Disconnect") }
        else { connectButton?.title = session == nil ? L("连接", "Connect") : L("取消连接", "Cancel") }
        connectButton?.needsDisplay = true
        if session != nil {
            colorLabel.stringValue = outputColor == .hlg ? (hdrVerified ? "HDR · HLG 10-bit" : L("HDR · 正在验证", "HDR · Verifying")) : (fallbackUsed ? L("SDR · 已回退", "SDR · Fallback") : "SDR · BT.709")
        } else { colorLabel.stringValue = hdr.state == .on ? L("HDR · 连接后验证", "HDR · Verify on connect") : "SDR · BT.709" }
    }
    private func rebuildMenus() {
        func item(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
            let value = NSMenuItem(title: title, action: action, keyEquivalent: key); value.target = self; return value
        }
        let menu = NSMenu(); menu.autoenablesItems = false
        let state = item(connectionHeading.stringValue, nil); state.isEnabled = false; menu.addItem(state)
        menu.addItem(item(L("打开 Nextend", "Open Nextend"), #selector(showWindow)))
        let disconnect = item(L("断开连接", "Disconnect"), #selector(disconnect)); disconnect.isEnabled = session != nil; menu.addItem(disconnect)
        menu.addItem(.separator())
        menu.addItem(item(AppLanguage.english ? "切换到中文" : "Switch to English", #selector(languageChanged)))
        let tests = item(L("诊断", "Diagnostics"), nil); tests.submenu = NSMenu(); tests.submenu?.autoenablesItems = false
        for (name, selector) in [(L("桌面采集测试 · 30 秒", "Desktop capture test · 30 s"), #selector(desktopTest)), (L("合成测试 · 30 秒", "Synthetic test · 30 s"), #selector(testPattern))] {
            let test = item(name, selector); test.isEnabled = session == nil && !restartRequired; tests.submenu?.addItem(test)
        }
        menu.addItem(tests); menu.addItem(.separator())
        menu.addItem(item(L("退出 Nextend", "Quit Nextend"), #selector(quit), key: "q"))
        statusItem?.menu = menu
        let root = NSMenu(); let appItem = NSMenuItem(); root.addItem(appItem)
        appItem.submenu = menu.copy() as? NSMenu; NSApp.mainMenu = root
    }
    @objc private func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func transportChanged() { wirelessFields?.isHidden = transport.selectedSegment == 0 }
    @objc private func hdrChanged() { renderConnection() }
    @objc private func showHDRInfo() {
        let alert = NSAlert(); alert.messageText = "HDR · HLG 10-bit"
        alert.informativeText = L("使用 HEVC Main10 和 HLG。建议先用 USB、60 fps；不可用时自动回退 SDR 并显示原因。\n\nHDR 内容才具有更亮的高光。当前不提供 HDR10 / Dolby Vision。更改画质需先断开连接。", "Uses HEVC Main10 and HLG. Start with USB at 60 fps. If HDR is unavailable, Nextend falls back to SDR and shows the reason.\n\nBrighter highlights require HDR content. HDR10 and Dolby Vision are not supported. Disconnect before changing quality settings.")
        alert.addButton(withTitle: L("知道了", "OK")); alert.beginSheetModal(for: window)
    }
    private func uiOptions(synthetic: Bool) -> SessionOptions {
        var options = SessionOptions(); options.synthetic = synthetic; options.seconds = synthetic ? 30 : 0
        options.profile.fps = [60, 90, 120][rate.selectedSegment]
        options.requestedHDR = hdr.state == .on; options.profile.color = options.requestedHDR ? .hlg : .sdr
        if resolution.indexOfSelectedItem == 1 { options.profile.width = 2400; options.profile.height = 1600 }
        options.wireless = transport.selectedSegment == 1; options.host = ip.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        options.interface = interface.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(options.host, forKey: "padIP"); UserDefaults.standard.set(options.interface, forKey: "interface")
        return options
    }
    @objc private func connect() { if let session { connectButton.isEnabled = false; session.cancel() } else { start(uiOptions(synthetic: false), cli: false) } }
    @objc private func testPattern() { start(uiOptions(synthetic: true), cli: false) }
    @objc private func desktopTest() { var options = uiOptions(synthetic: false); options.capturePattern = true; options.seconds = 30; start(options, cli: false) }
    @objc private func disconnect() { session?.cancel() }
    @objc private func sleeping() { session?.cancel(reason: "Mac 已进入睡眠，虚拟屏已释放；唤醒后点击连接恢复。") }
    @objc private func permission() {
        _ = CGRequestScreenCaptureAccess()
        if !CGPreflightScreenCaptureAccess() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
        lastMessage = "在系统设置中允许 Nextend 录制屏幕，然后退出并重启本应用。"; renderConnection()
    }
    @objc private func arrangement() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!) }
    private func start(_ options: SessionOptions, cli: Bool, retainedDisplay: VirtualDisplay? = nil) {
        guard session == nil, !restartRequired else { return }
        let session = Session(options: options, retainedDisplay: retainedDisplay); self.session = session
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Nextend desktop streaming")
        connectionState = .connecting; activeWireless = options.wireless; outputColor = options.profile.color; hdrVerified = false; fallbackUsed = options.fallbackReason != nil
        connectButton?.isEnabled = true; settingControls.forEach { $0.isEnabled = false }
        renderConnection(); rebuildMenus()
        session.onPeerAddress = { [weak self, weak session] address in
            guard let self, let session, self.session === session else { return }
            self.ip.stringValue = address; UserDefaults.standard.set(address, forKey: "padIP")
        }
        session.onStatus = { [weak self, weak session] message, kind in
            guard let self, let session, self.session === session else { return }
            switch kind {
            case .metrics: return
            case .connected: self.connectionState = .connected; self.deviceArt.connected = true; self.rebuildMenus()
            case .hdrVerified: self.hdrVerified = true
            default: break
            }
            self.lastMessage = message; self.renderConnection(); self.rebuildMenus()
        }
        session.onMetrics = { [weak self, weak session] values in
            guard let self, let session, self.session === session else { return }
            self.outputColor = values["color"] as? String == VideoColor.hlg.rawValue ? .hlg : .sdr
            self.hdrVerified = values["hdrVerified"] as? Bool == true
            self.fallbackUsed = !(values["fallbackReason"] as? String ?? "").isEmpty
            for (label, key) in zip(self.metricLabels, ["encodeFps", "renderFps", "captureToDecodeAckP95Ms"]) { label.stringValue = (values[key] as? Double).map { String(format: "%.1f", $0) } ?? "—" }
            self.renderConnection()
        }
        session.onFinish = { [weak self, weak session] success in
            guard let self, let session else { return }
            self.session = nil; self.endActivity(); self.restartRequired = session.needsRestart
            self.connectButton?.isEnabled = !self.restartRequired; self.settingControls.forEach { $0.isEnabled = true }
            self.connectionState = .finished(success); self.deviceArt.connected = false; self.metricLabels.forEach { $0.stringValue = "—" }
            self.renderConnection(); self.rebuildMenus()
            if cli { exit(success ? 0 : 1) } else if self.quitting { NSApp.terminate(nil) }
        }
        session.onFallback = { [weak self] reason, retainedDisplay in
            guard let self else { return }; self.session = nil; self.endActivity()
            if self.quitting { NSApp.terminate(nil); return }
            var fallback = options; fallback.profile.color = .sdr; fallback.fallbackReason = reason
            self.start(fallback, cli: cli, retainedDisplay: retainedDisplay)
        }
        session.launch()
    }
    private func endActivity() { if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil } }
    private func probe() {
        Task {
            var results: [[String: Any]] = []
            for fps in [60, 90, 120] {
                do {
                    var profile = Profile(); profile.fps = fps
                    if arguments.contains("--hdr") { profile.color = .hlg }
                    var display: VirtualDisplay? = try VirtualDisplay(profile: profile)
                    try await display!.waitUntilReady()
                    let description = display!.describe(); results.append(description); log("PROBE \(description)")
                    guard await display!.closeAndWait() else { throw BridgeError("探测后虚拟屏未释放。") }
                    display = nil
                } catch { results.append(["requestedHz": fps, "error": error.localizedDescription]) }
            }
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
            exit(results.contains { $0["error"] != nil } ? 1 : 0)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        // Cancel this attempt and terminate after asynchronous display cleanup.
        quitting = true; session.cancel(); return .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }; return true
    }
}
