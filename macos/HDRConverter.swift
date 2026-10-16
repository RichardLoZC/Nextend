import Foundation
import Metal
import CoreVideo

/// Extended sRGB (SDR white = 1) → video-range HLG / BT.2020 P010.
/// BT.2100 inverse OOTF + OETF, BT.2408 reference white 203/1000.
/// VirtualDisplay fixes and validates its ICC profile; CG capture's default
/// float surface preserves EDR. An explicit capture color conversion clips it.
final class HDRConverter {
    private let device: MTLDevice
    private let commands: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var cache: CVMetalTextureCache?
    private var pool: CVPixelBufferPool?
    private let width: Int
    private let height: Int

    init(width: Int, height: Int) throws {
        self.width = width; self.height = height
        guard let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue() else { throw BridgeError("HDR 转换需要 Metal。") }
        self.device = device; self.commands = commands
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        float hlg(float x) {
            x=clamp(x,0.0f,1.0f);
            return x<=1.0f/12.0f ? sqrt(3.0f*x) : 0.17883277f*log(12.0f*x-0.28466892f)+0.55991073f;
        }
        float linearize(float x) {
            float a=abs(x);
            return copysign(a<=0.04045f ? a/12.92f : pow((a+0.055f)/1.055f,2.4f),x);
        }
        float3 encode(float3 signal) {
            float3 linear=float3(linearize(signal.r),linearize(signal.g),linearize(signal.b));
            float3 rgb2020=float3(dot(linear,float3(0.627404f,0.329283f,0.043313f)),
                dot(linear,float3(0.069097f,0.919540f,0.011362f)),
                dot(linear,float3(0.016391f,0.088013f,0.895595f)));
            float3 display=max(rgb2020,0.0f)*0.203f;
            float y=dot(display,float3(0.2627f,0.6780f,0.0593f));
            float3 scene=y>0 ? display*pow(y,1.0f/1.2f-1.0f) : float3(0);
            return float3(hlg(scene.r),hlg(scene.g),hlg(scene.b));
        }
        kernel void convert(texture2d<float,access::read> src [[texture(0)]],
                            texture2d<uint,access::write> luma [[texture(1)]],
                            texture2d<uint,access::write> chroma [[texture(2)]], uint2 pos [[thread_position_in_grid]]) {
            uint2 base=pos*2;
            if(base.x+1>=src.get_width() || base.y+1>=src.get_height()) return;
            float3 total=0;
            for(uint dy=0;dy<2;dy++) for(uint dx=0;dx<2;dx++) {
                uint2 p=base+uint2(dx,dy); float3 rgb=encode(src.read(p).rgb); total+=rgb;
                float y=dot(rgb,float3(0.2627f,0.6780f,0.0593f));
                luma.write(uint(round(64.0f+876.0f*y))<<6,p);
            }
            float3 rgb=total*0.25f; float y=dot(rgb,float3(0.2627f,0.6780f,0.0593f));
            float2 cbcr=float2((rgb.b-y)/1.8814f,(rgb.r-y)/1.4746f);
            uint2 code=uint2(clamp(round(512.0f+896.0f*cbcr),64.0f,960.0f));
            chroma.write(uint4(code<<6,0,0),pos);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "convert") else { throw BridgeError("HDR 转换着色器不可用。") }
        pipeline = try device.makeComputePipelineState(function: function)
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess else { throw BridgeError("HDR 纹理缓存分配失败。") }
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { throw BridgeError("HDR 像素池分配失败。") }
    }
    func convert(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_64RGBAHalf,
              CVPixelBufferGetWidth(source) == width, CVPixelBufferGetHeight(source) == height,
              let pool, let cache else { throw BridgeError("HDR 浮点采集格式发生变化。") }
        var output: CVPixelBuffer?
        let limit = [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limit, &output) == kCVReturnSuccess, let output else { throw BridgeError("HDR 缓冲已达到上限。") }
        func texture(_ buffer: CVPixelBuffer, _ format: MTLPixelFormat, _ w: Int, _ h: Int, _ plane: Int) throws -> CVMetalTexture {
            var result: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format, w, h, plane, &result) == kCVReturnSuccess, let result else { throw BridgeError("HDR Metal 纹理映射失败。") }
            return result
        }
        let src = try texture(source, .rgba16Float, width, height, 0)
        let y = try texture(output, .r16Uint, width, height, 0)
        let uv = try texture(output, .rg16Uint, width / 2, height / 2, 1)
        guard let command = commands.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw BridgeError("HDR GPU 命令分配失败。") }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(CVMetalTextureGetTexture(src), index: 0)
        encoder.setTexture(CVMetalTextureGetTexture(y), index: 1)
        encoder.setTexture(CVMetalTextureGetTexture(uv), index: 2)
        encoder.dispatchThreads(MTLSize(width: width / 2, height: height / 2, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        withExtendedLifetime((src, y, uv, source)) { command.commit(); command.waitUntilCompleted() }
        guard command.status == .completed, command.error == nil else { throw BridgeError("HDR GPU 转换失败。") }
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return output
    }
    static func referenceCode(linear: Double) -> Int {
        let scene = pow(max(0, min(linear * 0.203, 1)), 1 / 1.2)
        let signal = scene <= 1 / 12 ? sqrt(3 * scene) : 0.17883277 * log(12 * scene - 0.28466892) + 0.55991073
        return Int((64 + 876 * signal).rounded())
    }
    static func selfTest() throws {
        var input: CVPixelBuffer?
        let attrs = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, 12, 4, kCVPixelFormatType_64RGBAHalf, attrs, &input) == kCVReturnSuccess, let input else { throw BridgeError("HDR 测试分配失败。") }
        let levels: [Float] = [0, 0.18, 1, 2, 3, 4]
        CVPixelBufferLockBaseAddress(input, [])
        let rowBytes = CVPixelBufferGetBytesPerRow(input)
        for y in 0..<4 {
            let row = CVPixelBufferGetBaseAddress(input)!.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
            for x in 0..<12 {
                let linear = levels[x / 2]
                let signal = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
                for component in 0..<3 { row[x * 4 + component] = Float16(signal).bitPattern }
                row[x * 4 + 3] = Float16(1).bitPattern
            }
        }
        CVPixelBufferUnlockBaseAddress(input, [])
        let converter = try HDRConverter(width: 12, height: 4)
        let result = try converter.convert(input)
        CVPixelBufferLockBaseAddress(result, .readOnly); defer { CVPixelBufferUnlockBaseAddress(result, .readOnly) }
        let y = CVPixelBufferGetBaseAddressOfPlane(result, 0)!.assumingMemoryBound(to: UInt16.self)
        let uv = CVPixelBufferGetBaseAddressOfPlane(result, 1)!.assumingMemoryBound(to: UInt16.self)
        let expected = [64, 446, 721, 818, 873, 912]
        for i in 0..<6 {
            guard abs(Int(y[i * 2] >> 6) - expected[i]) <= 1, uv[i * 2] >> 6 == 512, uv[i * 2 + 1] >> 6 == 512 else { throw BridgeError("HDR GPU 高光 / 白位转换检查失败。") }
        }
        log("PASS: Metal HLG reference white=721, highlight steps=818/873/912, neutral chroma=512")
    }
}
