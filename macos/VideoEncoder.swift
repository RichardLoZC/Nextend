// VideoToolbox / Annex-B handling adapted from OpenDisplay, GPL-3.0.
import Foundation
import VideoToolbox
import CoreMedia

struct EncodedFrame {
    let sequence: UInt64
    let capturedNS: UInt64
    let encodedNS: UInt64
    let keyframe: Bool
    let bytes: Data
    let colorInfo: [String: Any]
}

enum EncoderOutput {
    case frame(EncodedFrame)
    case dropped(UInt64)
}

final class VideoEncoder {
    private var session: VTCompressionSession?
    private let profile: Profile
    private let output: (Result<EncoderOutput, Error>) -> Void
    init(profile: Profile, output: @escaping (Result<EncoderOutput, Error>) -> Void) throws {
        try profile.validate()
        self.profile = profile; self.output = output
        var spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
                    kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var status = VTCompressionSessionCreate(allocator: nil, width: Int32(profile.width), height: Int32(profile.height),
            codecType: profile.codec == "hevc" ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if status != noErr {
            spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
            status = VTCompressionSessionCreate(allocator: nil, width: Int32(profile.width), height: Int32(profile.height),
                codecType: profile.codec == "hevc" ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
            log("低延迟率控不可用，使用硬件实时编码。")
        }
        guard status == noErr, let session else { throw BridgeError("硬件编码器初始化失败：\(status)") }
        do {
            try property(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
            try property(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
            try property(kVTCompressionPropertyKey_ProfileLevel, profile.color == .hlg ? kVTProfileLevel_HEVC_Main10_AutoLevel : (profile.codec == "hevc" ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel))
            try property(kVTCompressionPropertyKey_AverageBitRate, profile.bitrate as CFNumber)
            try property(kVTCompressionPropertyKey_ExpectedFrameRate, profile.fps as CFNumber)
            _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
            try property(kVTCompressionPropertyKey_MaxKeyFrameInterval, (profile.fps * 2) as CFNumber)
            _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
            try property(kVTCompressionPropertyKey_ColorPrimaries, profile.color == .hlg ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2)
            try property(kVTCompressionPropertyKey_TransferFunction, profile.color == .hlg ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_ITU_R_709_2)
            try property(kVTCompressionPropertyKey_YCbCrMatrix, profile.color == .hlg ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
            guard prepared == noErr else { throw BridgeError("编码器准备失败：\(prepared)") }
        } catch { close(); throw error }
    }
    private func property(_ key: CFString, _ value: CFTypeRef) throws {
        guard let session else { return }
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw BridgeError("编码器不支持 \(key)：\(status)") }
    }
    func encode(_ buffer: CVPixelBuffer, sequence: UInt64, capturedNS: UInt64, forceKeyframe: Bool) throws {
        guard let session else { throw BridgeError("编码器已停止。") }
        if profile.color == .hlg {
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                  CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String == kCVImageBufferColorPrimaries_ITU_R_2020 as String,
                  CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String,
                  CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String
            else { throw BridgeError("HDR 采集缓冲并非 10-bit BT.2020 HLG，拒绝错误标记。") }
        }
        let properties = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let callback = output
        let hdr = profile.color == .hlg
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer,
            presentationTimeStamp: CMTime(value: Int64(sequence), timescale: CMTimeScale(profile.fps)),
            duration: CMTime(value: 1, timescale: CMTimeScale(profile.fps)), frameProperties: properties, infoFlagsOut: nil) { status, flags, sample in
                guard status == noErr else {
                    callback(.failure(BridgeError("编码帧失败或被硬件丢弃：\(status)"))); return
                }
                // A real-time encoder may skip input under load. No encoded
                // reference frame was discarded; return its sender credit.
                if flags.contains(.frameDropped) { callback(.success(.dropped(sequence))); return }
                guard let sample else { callback(.failure(BridgeError("编码输出缺少格式。"))); return }
                do {
                    let key = !(((CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])?.first?[kCMSampleAttachmentKey_NotSync]) as? Bool ?? false)
                    let colorInfo = try Self.colorInfo(sample, requireHDR: hdr)
                    callback(.success(.frame(EncodedFrame(sequence: sequence, capturedNS: capturedNS, encodedNS: monotonicNS(), keyframe: key, bytes: try Self.annexB(sample, keyframe: key), colorInfo: colorInfo))))
                } catch { callback(.failure(error)) }
            }
        guard status == noErr else { throw BridgeError("提交硬件编码失败：\(status)") }
    }
    func close() {
        if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(session) }
        session = nil
    }
    deinit { close() }
    private static func colorInfo(_ sample: CMSampleBuffer, requireHDR: Bool) throws -> [String: Any] {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { throw BridgeError("编码输出缺少格式。") }
        let ext = (CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? NSDictionary()
        let primaries = ext[kCMFormatDescriptionExtension_ColorPrimaries] as? String ?? "unknown"
        let transfer = ext[kCMFormatDescriptionExtension_TransferFunction] as? String ?? "unknown"
        let matrix = ext[kCMFormatDescriptionExtension_YCbCrMatrix] as? String ?? "unknown"
        let fullRange = ext[kCMFormatDescriptionExtension_FullRangeVideo] as? Bool ?? false
        let atoms = ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [String: Data]
        let hvcc = atoms?["hvcC"]
        // HEVCDecoderConfigurationRecord: profile_idc and bitDepthLuma/ChromaMinus8.
        let main10 = hvcc.map { $0.count >= 23 && ($0[1] & 31) == 2 && ($0[17] & 7) == 2 && ($0[18] & 7) == 2 } ?? false
        if requireHDR && (!main10 || fullRange || primaries != kCVImageBufferColorPrimaries_ITU_R_2020 as String || transfer != kCVImageBufferTransferFunction_ITU_R_2100_HLG as String || matrix != kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) {
            throw BridgeError("HDR 编码输出未通过 Main10 / HLG / BT.2020 检查。")
        }
        return ["primaries": primaries, "transfer": transfer, "matrix": matrix, "fullRange": fullRange, "main10": main10]
    }
    private static func annexB(_ sample: CMSampleBuffer, keyframe: Bool) throws -> Data {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { throw BridgeError("编码帧缺少内容。") }
        let hevc = CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC
        var output = Data(); let start = Data([0, 0, 0, 1])
        var headerLength: Int32 = 4
        for index in 0..<(hevc ? 3 : 2) {
            var ptr: UnsafePointer<UInt8>?; var length = 0
            let status = hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &ptr, parameterSetSizeOut: &length, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &headerLength)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &ptr, parameterSetSizeOut: &length, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &headerLength)
            guard status == noErr, let ptr else { throw BridgeError("编码帧参数集无效。") }
            if keyframe { output.append(start); output.append(Data(bytes: ptr, count: length)) }
        }
        guard headerLength == 4 else { throw BridgeError("不支持的 NAL 长度格式。") }
        let total = CMBlockBufferGetDataLength(block)
        var data = Data(count: total)
        let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: $0.baseAddress!) }
        guard status == noErr else { throw BridgeError("无法读取编码数据。") }
        var offset = 0
        while offset < total {
            guard offset + 4 <= total else { throw BridgeError("不完整的 NAL 长度。") }
            let length = Int(data.uintBE(offset, 4)); offset += 4
            guard length > 0, offset + length <= total else { throw BridgeError("不完整的 NAL 数据。") }
            output.append(start); output.append(data.subdata(in: offset..<(offset + length))); offset += length
        }
        return output
    }
}
