import Foundation
import OSLog

/// Local lifecycle metadata only. Never pass identities, names, room secrets, codes,
/// screen content, clipboard data, input events, or network URLs to this logger.
@MainActor public enum ReachDiagnostics {
    private static let logger = Logger(subsystem: "com.timothynice.reach", category: "connection")
    public static var logURL: URL {
        #if os(macOS)
        return URL(fileURLWithPath: "/tmp/Reach-diagnostics.log")
        #else
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Reach", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Diagnostics.log")
        #endif
    }
    public static func record(component: String, event: String, metadata: String = "") {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(component) \(event) \(metadata)\n"
        logger.notice("\(line, privacy: .public)")
        let url = logURL
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 256 * 1024 {
            try? FileManager.default.removeItem(at: url)
        }
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url, options: .atomic); return }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf: data) } catch { }
    }
    static func errorCode(_ error: Error) -> String {
        let value = error as NSError
        // Domains and numeric codes contain no payload or endpoint values.
        return "domain=\(value.domain) code=\(value.code)"
    }
}
