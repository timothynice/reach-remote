import Foundation
import Darwin
import CoreVideo
import CoreMedia

/// Paced synthetic encoder probe. Deliberately excludes capture, networking, phone decode and display.
final class Measurements: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [Int64: Double] = [:]
    private var latencies: [Double] = []
    private var bytes = 0
    private var failures = 0
    func submitted(_ index: Int64) {
        lock.lock(); defer { lock.unlock() }
        starts[index] = ProcessInfo.processInfo.systemUptime
    }
    func encoded(_ frame: EncodedDesktopFrame) {
        lock.lock(); defer { lock.unlock() }
        let index = Int64((frame.timestamp * 60).rounded())
        if let started = starts.removeValue(forKey: index) {
            latencies.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
        }
        bytes += frame.bytes.count
    }
    func error() { lock.lock(); failures += 1; lock.unlock() }
    func result(duration: Double, submitted: Int, cpu: Double) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let sorted = latencies.sorted()
        func percentile(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        return ["scope": "synthetic paced NV12 H264 encoding only; not end-to-end latency or battery",
                "width": 1920, "height": 1080, "targetFPS": 60, "durationSeconds": duration,
                "submittedFrames": submitted, "encodedFrames": sorted.count, "unreturnedFrames": starts.count,
                "encoderErrors": failures, "encodedBytes": bytes,
                "averageMbps": Double(bytes) * 8 / duration / 1_000_000,
                "submitToCallbackP50Milliseconds": percentile(0.50), "submitToCallbackP95Milliseconds": percentile(0.95),
                "submitToCallbackMaxMilliseconds": sorted.last ?? 0,
                "processCPUPercentOfOneCore": cpu / duration * 100,
                "host": ProcessInfo.processInfo.operatingSystemVersionString,
                "architecture": "arm64", "logicalProcessors": ProcessInfo.processInfo.processorCount]
    }
}

@main struct EncoderBenchmark {
    static func systemString(_ key: String) -> String {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func main() async throws {
        let seconds = min(120, max(2, Int(CommandLine.arguments.dropFirst().first ?? "15") ?? 15))
        let count = seconds * 60
        let capture = DesktopCapture()
        let results = Measurements()
        capture.onFrame = { results.encoded($0) }
        capture.onError = { _ in results.error() }
        try capture.makeEncoder(width: 1920, height: 1080)
        let cpuStart = cpuSeconds(), started = ProcessInfo.processInfo.systemUptime
        for index in 0..<count {
            // Fresh buffers avoid modifying a surface while VideoToolbox is still reading it.
            var optional: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &optional) == kCVReturnSuccess,
                let pixel = optional else { fatalError("Could not allocate NV12 source") }
            CVPixelBufferLockBaseAddress(pixel, [])
            for plane in 0..<2 {
                memset(CVPixelBufferGetBaseAddressOfPlane(pixel, plane)!, plane == 0 ? Int32(48 + index % 160) : 128,
                       CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane))
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            results.submitted(Int64(index))
            capture.encode(pixel, timestamp: CMTime(value: Int64(index), timescale: 60))
            let until = started + Double(index + 1) / 60 - ProcessInfo.processInfo.systemUptime
            if until > 0 { try await Task.sleep(for: .seconds(until)) }
        }
        // Allow final hardware callbacks to arrive without artificially charging them to input/display latency.
        try await Task.sleep(for: .milliseconds(250))
        let duration = ProcessInfo.processInfo.systemUptime - started
        var report = results.result(duration: duration, submitted: count, cpu: cpuSeconds() - cpuStart)
        report["hardwareEncoder"] = capture.usingHardwareEncoder
        report["hardwareModel"] = systemString("hw.model")
        report["cpuModel"] = systemString("machdep.cpu.brand_string")
        await capture.stop()
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]), encoding: .utf8)!)
        guard report["encoderErrors"] as? Int == 0, report["encodedFrames"] as? Int == count else { exit(1) }
    }
}
