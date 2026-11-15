import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

final class Results: @unchecked Sendable {
    let encoded = DispatchSemaphore(value: 0)
    let decoded = DispatchSemaphore(value: 0)
    var frame: EncodedDesktopFrame?
    var image: CVPixelBuffer?
}

@main
struct CodecSmokeTest {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "ReachCodecTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func wait(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult { semaphore.wait(timeout: .now() + 10) }
    static func run() async throws {
        let width = 320, height = 240
        let capture = DesktopCapture()
        let results = Results()
        capture.onFrame = { frame in results.frame = frame; results.encoded.signal() }
        try capture.makeEncoder(width: width, height: height)
        var pixel: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        try check(status == kCVReturnSuccess && pixel != nil, "Create synthetic NV12 frame")
        let source = pixel!
        CVPixelBufferLockBaseAddress(source, [])
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(source, plane)!
            memset(base, 128, CVPixelBufferGetBytesPerRowOfPlane(source, plane) * CVPixelBufferGetHeightOfPlane(source, plane))
        }
        CVPixelBufferUnlockBaseAddress(source, [])
        capture.encode(source, timestamp: CMTime(value: 1, timescale: 60))
        try check(wait(results.encoded) == .success, "Real VideoToolbox H.264 encoder produced no frame")
        let frame = results.frame!
        try check(frame.keyframe && frame.parameterSets.count == 2 && !frame.bytes.isEmpty, "First frame must include IDR and SPS/PPS")
        try check(frame.width == width && frame.height == height, "Encoded dimensions preserved")
        var description: CMFormatDescription?
        let sps = frame.parameterSets[0], pps = frame.parameterSets[1]
        let descriptionStatus = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        try check(descriptionStatus == noErr, "Decode parameter sets")
        var session: VTDecompressionSession?
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { context, _, status, _, image, _, _ in
            guard status == noErr, let context, let image else { return }
            let value = Unmanaged<Results>.fromOpaque(context).takeUnretainedValue()
            value.image = image
            value.decoded.signal()
        }, decompressionOutputRefCon: Unmanaged.passUnretained(results).toOpaque())
        let created = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description!, decoderSpecification: nil,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &session)
        try check(created == noErr && session != nil, "Create real H.264 decoder")
        defer { VTDecompressionSessionInvalidate(session!) }
        var block: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: frame.bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: frame.bytes.count, flags: 0, blockBufferOut: &block)
        try check(blockStatus == noErr, "Allocate compressed frame")
        let copied = frame.bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: frame.bytes.count) }
        try check(copied == noErr, "Copy AVCC payload")
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: 1, timescale: 60), decodeTimeStamp: .invalid)
        var count = frame.bytes.count
        let sampleStatus = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &count, sampleBufferOut: &sample)
        try check(sampleStatus == noErr, "Create compressed sample buffer")
        let decoded = VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sample!, flags: [._EnableAsynchronousDecompression], frameRefcon: nil, infoFlagsOut: nil)
        try check(decoded == noErr, "Decode AVCC frame")
        VTDecompressionSessionWaitForAsynchronousFrames(session!)
        try check(wait(results.decoded) == .success, "Decoder returned no image")
        let image = results.image!
        try check(CVPixelBufferGetWidth(image) == width && CVPixelBufferGetHeight(image) == height, "Decoded dimensions")
        CVPixelBufferLockBaseAddress(image, .readOnly)
        let luma = Int(CVPixelBufferGetBaseAddressOfPlane(image, 0)!.load(as: UInt8.self))
        CVPixelBufferUnlockBaseAddress(image, .readOnly)
        try check(abs(luma - 128) <= 8, "Decoded pixel luminance \(luma) differs from source")
        try capture.makeEncoder(width: width, height: height)
        try check(!capture.isCurrent(frame), "Replacing an encoder must invalidate queued frames even at the same dimensions")
        capture.encode(source, timestamp: CMTime(value: 2, timescale: 60))
        try check(wait(results.encoded) == .success, "Replacement encoder produced no frame")
        let replacement = results.frame!
        try check(replacement.encoderID != frame.encoderID && capture.isCurrent(replacement) && replacement.keyframe,
                  "Replacement encoder must have a new generation and start with a keyframe")
        await capture.stop()
        try check(!capture.isCurrent(replacement), "Stopping must invalidate queued frame delivery")
        print("PASS: real VideoToolbox H.264 encode→AVCC→decode, IDR/SPS/PPS, 320×240 dimensions, luma \(luma). Synthetic source; screen capture not tested.")
    }
    static func main() async {
        do { try await run() } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
