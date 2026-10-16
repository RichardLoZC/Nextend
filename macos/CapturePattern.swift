import AppKit
import QuartzCore
import Metal

/// A window on the virtual display, captured by ScreenCaptureKit like any app.
/// Kept separate from the NV12 synthetic source so benchmarks identify the path.
@MainActor final class CapturePattern {
    private let window: NSWindow
    private var link: CADisplayLink?
    init(displayID: CGDirectDisplayID, fps: Int, hdr: Bool = false) throws {
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID })
        else { throw BridgeError("无法定位测试虚拟屏。") }
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.title = L("Nextend 桌面采集测试", "Nextend desktop capture test")
        window.level = .floating
        if hdr {
            let view = try HDRPatternView(hdrFrame: NSRect(origin: .zero, size: screen.frame.size))
            window.contentView = view
            window.setFrame(screen.frame, display: true); window.orderFrontRegardless()
            view.configure(scale: screen.backingScaleFactor)
            let link = view.displayLink(target: view, selector: #selector(HDRPatternView.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(fps), maximum: Float(fps), preferred: Float(fps))
            link.add(to: .main, forMode: .common); self.link = link
            log("HDR 测试窗口：线性 sRGB 灰阶 0 / 0.18 / 1 / 2 / 3 / 4，SDR 白位 = 1")
            return
        }
        let view = CapturePatternView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        view.installAnimation()
        log("capture pattern screen=\(screen.frame) window=\(window.frame) visible=\(window.isVisible)")
        let link = view.displayLink(target: view, selector: #selector(CapturePatternView.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(fps), maximum: Float(fps), preferred: Float(fps))
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func close() { link?.invalidate(); link = nil; window.close() }
    deinit { link?.invalidate() }
}

/// Known EDR values rendered into WindowServer, not injected after capture.
/// The middle horizontal line is sampled by Session to detect SDR clipping.
@MainActor private final class HDRPatternView: NSView {
    private let metalLayer = CAMetalLayer()
    private let device: MTLDevice
    private let commands: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var frameNumber: UInt32 = 0
    init(hdrFrame frame: NSRect) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue() else { throw BridgeError("HDR 测试需要 Metal。") }
        self.device = device; self.commands = commands
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 p [[position]]; float2 uv; };
        vertex V vertexMain(uint id [[vertex_id]]) {
            float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
            return {float4(p[id],0,1), p[id]*0.5+0.5};
        }
        fragment float4 fragmentMain(V v [[stage_in]], constant uint &frame [[buffer(0)]]) {
            float steps[6] = {0.0,0.18,1.0,2.0,3.0,4.0};
            float l = steps[min(uint(v.uv.x*6),5u)];
            if(v.uv.y<0.15) l = 4.0*v.uv.x;
            if(v.uv.y>0.85) l = abs(v.uv.x-float(frame%240)/240.0)<0.015 ? 4.0 : 0.05;
            return float4(l,l,l,1);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
        descriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        super.init(frame: frame)
        wantsLayer = true; layer = metalLayer
        metalLayer.device = device; metalLayer.pixelFormat = .rgba16Float
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        metalLayer.wantsExtendedDynamicRangeContent = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(scale: CGFloat) {
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
    @objc func tick(_ sender: CADisplayLink) {
        guard let drawable = metalLayer.nextDrawable(), let command = commands.makeCommandBuffer() else { return }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .dontCare; descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        frameNumber &+= 1
        encoder.setRenderPipelineState(pipeline); encoder.setFragmentBytes(&frameNumber, length: 4, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); encoder.endEncoding()
        command.present(drawable); command.commit()
    }
}

@MainActor private final class CapturePatternView: NSView {
    var frameNumber = 0
    private let marker = CALayer()
    private let counter = CATextLayer()
    private var lastLogNS = monotonicNS()
    private var lastLogFrame = 0
    func installAnimation() {
        marker.backgroundColor = NSColor.systemOrange.cgColor
        marker.frame = CGRect(x: 0, y: 50, width: 30, height: bounds.height * 0.12)
        counter.frame = CGRect(x: 45, y: bounds.height * 0.19, width: 700, height: 32)
        counter.fontSize = 22
        counter.contentsScale = window?.backingScaleFactor ?? 2
        counter.foregroundColor = NSColor.white.cgColor
        layer?.addSublayer(marker); layer?.addSublayer(counter)
        let travel = CABasicAnimation(keyPath: "position.x")
        travel.fromValue = 20; travel.toValue = bounds.width - 20
        travel.duration = 2; travel.autoreverses = true; travel.repeatCount = .infinity
        travel.timingFunction = CAMediaTimingFunction(name: .linear)
        marker.add(travel, forKey: "desktop-motion")
    }
    @objc func tick(_ sender: CADisplayLink) {
        frameNumber += 1
        // Keep the test's static text and gradients cached. Redrawing millions
        // of pixels in AppKit for every tick measures the test generator's CPU
        // rasterizer rather than normal desktop composition / capture.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if frameNumber % 6 == 0 { counter.string = L("桌面动画帧计数", "Animation frame") + " \(frameNumber)" }
        CATransaction.commit()
        let now = monotonicNS()
        if now - lastLogNS >= 5_000_000_000 {
            log(String(format: "测试窗口时钟回调 %.1f fps（移动图层由合成器驱动）", Double(frameNumber - lastLogFrame) * 1e9 / Double(now - lastLogNS)))
            lastLogNS = now; lastLogFrame = frameNumber
        }
    }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill(); bounds.fill()
        let colors: [NSColor] = [.white, .yellow, .cyan, .green, .magenta, .red, .blue, .black]
        for (i, color) in colors.enumerated() {
            color.setFill(); NSRect(x: CGFloat(i) * bounds.width / 8, y: bounds.height * 0.6, width: bounds.width / 8, height: bounds.height * 0.4).fill()
        }
        for i in 0..<256 {
            NSColor(calibratedWhite: Double(i) / 255, alpha: 1).setFill()
            NSRect(x: CGFloat(i) * bounds.width / 256, y: bounds.height * 0.48, width: bounds.width / 256 + 1, height: bounds.height * 0.12).fill()
        }
        let text = L("Nextend · 真实桌面采集", "Nextend · Desktop capture") + "\nScreenCaptureKit → HEVC/H.264 → USB/Wi-Fi → MediaCodec\nlet display = 3200 × 2136;  ABC 0123456789"
        (text as NSString).draw(at: NSPoint(x: 45, y: bounds.height * 0.23), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 22, weight: .medium), .foregroundColor: NSColor.white])
        for x in stride(from: 0, to: Int(bounds.width), by: 4) {
            (x % 8 == 0 ? NSColor.white : NSColor.black).setFill()
            NSRect(x: x, y: 15, width: 4, height: 18).fill()
        }
    }
}
