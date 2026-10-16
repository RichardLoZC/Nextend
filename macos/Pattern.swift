import Foundation
import CoreVideo

/// Generates BT.709 video-range NV12 bars, a gray ramp, and a moving luminance marker.
/// This exercises encode/transport/decode without Screen Recording permission.
final class PatternSource {
    private let width: Int
    private let height: Int
    private var pool: CVPixelBufferPool?
    private let hdr: Bool
    init(profile: Profile) throws {
        width = profile.width; height = profile.height
        hdr = profile.color == .hlg
        let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { throw BridgeError("无法分配测试画面。") }
    }
    func frame(_ number: UInt64) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else { throw BridgeError("测试画面内存不足。") }
        CVPixelBufferLockBaseAddress(output, []); defer { CVPixelBufferUnlockBaseAddress(output, []) }
        if hdr {
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0) / 2
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(output, 1) / 2
            let yBase = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt16.self)
            let uvBase = CVPixelBufferGetBaseAddressOfPlane(output, 1)!.assumingMemoryBound(to: UInt16.self)
            // HLG code ramp: black, near-black, midtone, SDR white, highlights.
            let values: [UInt16] = [64, 180, 502, 721, 830, 940]
            let marker = Int(number * 23 % UInt64(width - 32))
            for y in 0..<height { for x in 0..<width {
                yBase[y * yStride + x] = (y > height * 3 / 4 && x >= marker && x < marker + 24 ? 940 : values[min(5, x * 6 / width)]) << 6
            } }
            for y in 0..<(height / 2) { for x in 0..<width { uvBase[y * uvStride + x] = 512 << 6 } }
            CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            return output
        }
        let ys: [UInt8] = [235, 219, 188, 173, 78, 63, 32, 16]
        let us: [UInt8] = [128, 16, 154, 42, 214, 102, 240, 128]
        let vs: [UInt8] = [128, 138, 16, 26, 230, 240, 118, 128]
        var yRow = [UInt8](repeating: 16, count: width)
        var grayRow = yRow
        var uvRow = [UInt8](repeating: 128, count: width)
        let position = Int(number * 23 % UInt64(width - 32))
        for x in 0..<width {
            yRow[x] = ys[min(7, x * 8 / width)]
            grayRow[x] = UInt8(16 + x * 219 / (width - 1))
            if x >= position && x < position + 24 { yRow[x] = number % 2 == 0 ? 235 : 16 }
        }
        for x in stride(from: 0, to: width, by: 2) { let bar = min(7, x * 8 / width); uvRow[x] = us[bar]; uvRow[x + 1] = vs[bar] }
        let yBase = CVPixelBufferGetBaseAddressOfPlane(output, 0)!
        let uvBase = CVPixelBufferGetBaseAddressOfPlane(output, 1)!
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0); let uvStride = CVPixelBufferGetBytesPerRowOfPlane(output, 1)
        yRow.withUnsafeBytes { row in grayRow.withUnsafeBytes { gray in
            for y in 0..<height { memcpy(yBase.advanced(by: y * yStride), y < height * 3 / 4 ? row.baseAddress! : gray.baseAddress!, width) }
        } }
        uvRow.withUnsafeBytes { row in
            for y in 0..<(height / 2) {
                if y < height * 3 / 8 { memcpy(uvBase.advanced(by: y * uvStride), row.baseAddress!, width) }
                else { memset(uvBase.advanced(by: y * uvStride), 128, width) }
            }
        }
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return output
    }
}
