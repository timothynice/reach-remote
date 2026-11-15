import Foundation
// ScreenCaptureKit async lifecycle objects gained Sendable annotations in newer SDKs.
// Access here stays on MainActor; frame/encoder state uses the dedicated queue and locks.
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreVideo
import os

struct EncodedDesktopFrame: Sendable {
    let width: Int
    let height: Int
    let keyframe: Bool
    let parameterSets: [Data]
    let bytes: Data
    let timestamp: Double
    let encoderID: UUID
}

/// Capture and encoding stay off the main thread. Only one encoder session is active.
final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "reach.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    // MainActor owns lifecycle/update ordering. Only one native quality update is in flight.
    private var qualityRevision: UInt64 = 0
    private var applyingQuality = false
    private var pendingQuality: (bitrate: Int, fps: Int, revision: UInt64)?
    // Stream identity and keyframe requests cross framework callback queues through small locks.
    private let outputStreamID = OSAllocatedUnfairLock<ObjectIdentifier?>(initialState: nil)
    private let keyframeRequest = OSAllocatedUnfairLock(initialState: true)
    private var framesPerSecond = 60
    private var encoder: VTCompressionSession?
    private var encoderContext: EncoderContext?
    private let currentEncoderID = OSAllocatedUnfairLock<UUID?>(initialState: nil)
    private final class EncoderContext {
        weak var owner: DesktopCapture?
        let id = UUID()
        let width: Int
        let height: Int
        init(owner: DesktopCapture, width: Int, height: Int) {
            self.owner = owner; self.width = width; self.height = height
        }
    }
    private var frameNumber: Int64 = 0
    private(set) var usingHardwareEncoder = false
    var onFrame: (@Sendable (EncodedDesktopFrame) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    private var bitrate = 6_000_000

    @MainActor
    func start(display: SCDisplay, widthLimit: Int = 1920, framesPerSecond: Int = 60) async throws {
        await stop()
        let width = max(2, min(widthLimit, display.width) / 2 * 2)
        let height = max(2, Int(Double(display.height) * Double(width) / Double(display.width)) / 2 * 2)
        let targetFPS = min(60, max(10, framesPerSecond))
        try queue.sync {
            self.framesPerSecond = targetFPS
            try makeEncoder(width: width, height: height)
        }
        let config = Self.makeConfiguration(width: width, height: height, fps: targetFPS)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = capture
        configuration = config
        let streamID = ObjectIdentifier(capture)
        outputStreamID.withLock { $0 = streamID }
        do { try await capture.startCapture() }
        catch {
            // A failed old start may complete after stop/replacement. Never tear down its successor.
            if stream === capture { await stop() }
            throw error
        }
    }

    @MainActor
    func stop() async {
        qualityRevision &+= 1
        pendingQuality = nil
        let old = stream
        stream = nil
        configuration = nil
        // Detach and invalidate before yielding: a delayed stop must not invalidate a new encoder.
        queue.sync {
            outputStreamID.withLock { $0 = nil }
            currentEncoderID.withLock { $0 = nil }
            if let encoder { VTCompressionSessionInvalidate(encoder) }
            encoder = nil; encoderContext = nil
            frameNumber = 0
            requestKeyframe()
        }
        try? await old?.stopCapture()
    }

    func requestKeyframe() { keyframeRequest.withLock { $0 = true } }
    var keyframeRequester: @Sendable () -> Void {
        let request = keyframeRequest
        return { request.withLock { $0 = true } }
    }

    @MainActor
    private static func makeConfiguration(width: Int, height: Int, fps: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.capturesAudio = false
        config.scalesToFit = true
        return config
    }

    @MainActor
    func setQuality(bitrate: Int, fps: Int) async {
        qualityRevision &+= 1
        pendingQuality = (min(16_000_000, max(500_000, bitrate)), min(60, max(10, fps)), qualityRevision)
        // Reentrant calls replace the pending request. Native updates remain serial, ensuring an
        // older completion cannot undo a newer requested configuration on the same stream.
        guard !applyingQuality else { return }
        applyingQuality = true
        defer { applyingQuality = false }
        while let request = pendingQuality {
            pendingQuality = nil
            let expectedEncoderID = currentEncoderID.withLock { $0 }
            if let previous = configuration, let activeStream = stream {
                // Never mutate an object already handed to ScreenCaptureKit across an await.
                let config = Self.makeConfiguration(width: previous.width, height: previous.height, fps: request.fps)
                do { try await activeStream.updateConfiguration(config) }
                catch { continue }
                guard stream === activeStream, request.revision == qualityRevision else { continue }
                configuration = config
            }
            guard request.revision == qualityRevision else { continue }
            queue.sync {
                guard currentEncoderID.withLock({ $0 == expectedEncoderID }) else { return }
                self.framesPerSecond = request.fps
                self.bitrate = request.bitrate
                if let encoder = self.encoder {
                    VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: request.bitrate as CFNumber)
                    VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: request.fps as CFNumber)
                }
            }
        }
    }

    func makeEncoder(width: Int, height: Int) throws {
        currentEncoderID.withLock { $0 = nil }
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil; encoderContext = nil
        requestKeyframe()
        let context = EncoderContext(owner: self, width: width, height: height)
        encoderContext = context
        let encoderID = context.id
        currentEncoderID.withLock { $0 = encoderID }
        let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let result = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264, encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: { context, _, status, flags, sample in
            guard status == noErr, !flags.contains(.frameDropped), let context, let sample else { return }
            let value = Unmanaged<EncoderContext>.fromOpaque(context).takeUnretainedValue()
            value.owner?.encoded(sample, context: value)
        }, refcon: Unmanaged.passUnretained(context).toOpaque(), compressionSessionOut: &encoder)
        guard result == noErr, let encoder else { throw CaptureError.encoder(result) }
        for (key, value) in [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel as CFTypeRef),
            (kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber),
            (kVTCompressionPropertyKey_ExpectedFrameRate, framesPerSecond as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, 120 as CFNumber)
        ] { VTSessionSetProperty(encoder, key: key, value: value) }
        VTCompressionSessionPrepareToEncodeFrames(encoder)
        var hardware: CFTypeRef?
        let hardwareStatus = withUnsafeMutablePointer(to: &hardware) { pointer in
            VTSessionCopyProperty(encoder, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                  allocator: nil, valueOut: pointer)
        }
        if hardwareStatus == noErr {
            usingHardwareEncoder = hardware as? Bool ?? false
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let streamID = ObjectIdentifier(stream)
        guard outputStreamID.withLock({ $0 == streamID }), type == .screen, sampleBuffer.isValid, encoder != nil, let pixel = sampleBuffer.imageBuffer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           SCFrameStatus(rawValue: raw) != .complete { return }
        encode(pixel, timestamp: sampleBuffer.presentationTimeStamp)
    }

    func encode(_ pixel: CVPixelBuffer, timestamp: CMTime) {
        guard let encoder else { return }
        let force = keyframeRequest.withLock { requested in
            let value = requested; requested = false; return value
        }
        let properties: CFDictionary? = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixel, presentationTimeStamp: timestamp, duration: CMTime(value: 1, timescale: CMTimeScale(framesPerSecond)), frameProperties: properties, sourceFrameRefcon: nil, infoFlagsOut: nil)
        if status != noErr { onError?("Video encoding failed (\(status)).") }
        frameNumber += 1
    }

    func isCurrent(_ frame: EncodedDesktopFrame) -> Bool {
        currentEncoderID.withLock { $0 == frame.encoderID }
    }

    private func encoded(_ sample: CMSampleBuffer, context: EncoderContext) {
        let encoderID = context.id
        guard currentEncoderID.withLock({ $0 == encoderID }), let block = sample.dataBuffer, let description = sample.formatDescription else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var parameters: [Data] = []
        if keyframe {
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var count = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &count, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    parameters.append(Data(bytes: pointer, count: count))
                }
            }
        }
        let count = CMBlockBufferGetDataLength(block)
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!) }
        guard status == noErr else { return }
        onFrame?(EncodedDesktopFrame(width: context.width, height: context.height, keyframe: keyframe, parameterSets: parameters, bytes: data, timestamp: sample.presentationTimeStamp.seconds, encoderID: encoderID))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let streamID = ObjectIdentifier(stream)
        guard outputStreamID.withLock({ $0 == streamID }) else { return }
        onError?(error.localizedDescription)
    }
    enum CaptureError: LocalizedError {
        case encoder(OSStatus)
        var errorDescription: String? { if case let .encoder(code) = self { return "Could not start the video encoder (\(code))." }; return nil }
    }
}
