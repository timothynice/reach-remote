import UIKit
import AVFoundation
import VideoToolbox

/// Main-thread configuration facade; codec work never runs on the UI thread.
@MainActor
final class DesktopDecoder {
    private let worker = DesktopDecoderWorker()
    var onFrame: ((CMSampleBuffer) -> Void)? {
        get { worker.onFrame }
        set { worker.onFrame = newValue }
    }
    var onError: ((String) -> Void)? {
        get { worker.onError }
        set { worker.onError = newValue }
    }
    func decode(_ packet: VideoPacket) { worker.decode(packet) }
    func reset() { worker.reset() }
}

/// Sendability is confined to this worker: codec state is serial-queue owned; pending/generation/
/// presentation state is protected by pendingLock; callback slots are MainActor isolated.
/// Decode uses synchronous VideoToolbox callbacks (no asynchronous decode flag), so the callback
/// consumes decodingGeneration before the next decode can change it. Pixel buffers are not mutated.
private final class DesktopDecoderWorker: @unchecked Sendable {
    @MainActor init() {}
    private let queue = DispatchQueue(label: "reach.decode", qos: .userInteractive)
    private let pendingLock = NSLock()
    private var pendingCount = 0
    private var needsKeyframe = false
    private var displayPending = false
    private var newestSample: (CMSampleBuffer, UInt64)?
    private var generation: UInt64 = 0
    private var decodingGeneration: UInt64 = 0
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    @MainActor var onFrame: ((CMSampleBuffer) -> Void)?
    @MainActor var onError: ((String) -> Void)?

    func decode(_ packet: VideoPacket) {
        guard packet.codec == "h264", packet.width >= 2, packet.width <= 8192,
              packet.height >= 2, packet.height <= 8192, !packet.data.isEmpty,
              packet.data.count <= 8 * 1024 * 1024 else { report("Invalid video frame"); return }
        pendingLock.lock()
        if pendingCount >= 3 {
            let notify = !needsKeyframe
            needsKeyframe = true
            pendingLock.unlock()
            if notify { report("Recovering video after congestion") }
            return
        }
        let packetGeneration = generation
        pendingCount += 1
        pendingLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            self.pendingCount -= 1
            let skip = packetGeneration != self.generation || (self.needsKeyframe && !packet.isKeyframe)
            if packetGeneration == self.generation && packet.isKeyframe { self.needsKeyframe = false }
            self.pendingLock.unlock()
            if !skip { self.decodingGeneration = packetGeneration; self.decodeOnQueue(packet) }
        }
    }

    func reset() {
        pendingLock.lock()
        generation &+= 1; newestSample = nil; needsKeyframe = true
        pendingLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            if let session = self.session { VTDecompressionSessionInvalidate(session) }
            self.session = nil; self.format = nil; self.parameterSets = []
        }
    }

    private func decodeOnQueue(_ packet: VideoPacket) {
        if !packet.parameterSets.isEmpty && packet.parameterSets != parameterSets {
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil; format = nil; parameterSets = packet.parameterSets
            guard parameterSets.count >= 2, parameterSets[0].count >= 4, parameterSets[1].count >= 2 else { return }
            let status = parameterSets[0].withUnsafeBytes { sps in
                parameterSets[1].withUnsafeBytes { pps in
                    var pointers: [UnsafePointer<UInt8>] = [sps.bindMemory(to: UInt8.self).baseAddress!, pps.bindMemory(to: UInt8.self).baseAddress!]
                    var sizes = [sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: &pointers, parameterSetSizes: &sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                }
            }
            guard status == noErr else { report("Video format error \(status)"); return }
        }
        guard let format else { return }
        if session == nil {
            var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { refcon, _, status, _, pixelBuffer, _, _ in
                guard let refcon, status == noErr, let pixelBuffer else { return }
                let decoder = Unmanaged<DesktopDecoderWorker>.fromOpaque(refcon).takeUnretainedValue()
                var description: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &description)
                guard let description else { return }
                var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
                if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
                    let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                    CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
                }
                decoder.present(sample)
            }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
            let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferMetalCompatibilityKey as String: true]
            let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary, outputCallback: &callback, decompressionSessionOut: &session)
            guard status == noErr else { report("Decoder unavailable (\(status))"); return }
        }
        guard let session else { return }
        var block: CMBlockBuffer?
        let length = packet.data.count
        guard length > 0, CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == noErr, let block else { return }
        let copied = packet.data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) }
        guard copied == noErr else { return }
        var sample: CMSampleBuffer?
        var size = length
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
        if status != noErr { report("Frame decode error \(status)") }
    }
    private func present(_ sample: CMSampleBuffer) {
        pendingLock.lock()
        guard decodingGeneration == generation else { pendingLock.unlock(); return }
        newestSample = (sample, decodingGeneration)
        let schedule = !displayPending
        displayPending = true
        pendingLock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            let newest = self.newestSample
            self.newestSample = nil; self.displayPending = false
            self.pendingLock.unlock()
            if let newest, newest.1 == self.generation { self.onFrame?(newest.0) }
        }
    }
    private func report(_ error: String) { DispatchQueue.main.async { [weak self] in self?.onError?(error) } }
    deinit { if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) } }
}
