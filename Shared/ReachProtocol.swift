import Foundation

public struct VideoPacket: Codable, Sendable {
    public var data: Data
    public var parameterSets: [Data]
    public var width: Int
    public var height: Int
    public var isKeyframe: Bool
    public var timestamp: Double
    public var codec: String
    public init(data: Data, parameterSets: [Data], width: Int, height: Int, isKeyframe: Bool, timestamp: Double, codec: String = "h264") {
        self.data = data; self.parameterSets = parameterSets; self.width = width; self.height = height
        self.isKeyframe = isKeyframe; self.timestamp = timestamp; self.codec = codec
    }
}
public struct RemoteInput: Codable, Sendable {
    public var kind: String
    public var x: Double
    public var y: Double
    public var button: Int
    public var keyCode: UInt16
    public var modifiers: UInt64
    public var text: String
    public init(kind: String, x: Double = 0, y: Double = 0, button: Int = 0, keyCode: UInt16 = 0, modifiers: UInt64 = 0, text: String = "") {
        self.kind = kind; self.x = x; self.y = y; self.button = button; self.keyCode = keyCode; self.modifiers = modifiers; self.text = text
    }
}
public struct RemoteDisplay: Codable, Identifiable, Sendable {
    public var id: UInt32
    public var name: String
    public var width: Int
    public var height: Int
    public var frame: DisplayFrame?
    public var isCurrent: Bool?
    public init(id: UInt32, name: String, width: Int, height: Int, frame: DisplayFrame? = nil, isCurrent: Bool? = nil) {
        self.id = id; self.name = name; self.width = width; self.height = height
        self.frame = frame; self.isCurrent = isCurrent
    }
}
public struct StreamQuality: Codable, Sendable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var bitrate: Int
    public init(width: Int, height: Int, fps: Int, bitrate: Int) { self.width = width; self.height = height; self.fps = fps; self.bitrate = bitrate }
}
/// A rectangle in selected-display coordinates, normalized to the unit square.
public struct RemoteRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy { $0.isFinite } &&
        x >= 0 && y >= 0 && width > 0 && height > 0 &&
        x <= 1 && y <= 1 && width <= 1 && height <= 1 &&
        x + width <= 1.000001 && y + height <= 1.000001
    }
}
/// Focus metadata contains geometry only, never the text being edited.
public struct RemoteFocus: Codable, Sendable, Equatable {
    public var field: RemoteRect
    public var caret: RemoteRect?
    public init(field: RemoteRect, caret: RemoteRect? = nil) { self.field = field; self.caret = caret }
    public var isValid: Bool { field.isValid && (caret?.isValid ?? true) }
}
/// Capability only; no document text or accessibility content crosses the connection.
public enum ScrollTargetState: String, Codable, Sendable { case scrollable, notScrollable, unknown }

/// Outbound relay configuration, kept in the device-only Keychain rather than preferences.
/// The room is a bearer secret: never log it or include it in diagnostics.
public struct ReachRelayConfiguration: Codable, Sendable {
    public let url: URL
    public let room: String
    public init(url: URL, room: String) throws {
        guard url.scheme == "wss", url.host?.isEmpty == false, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, room.utf8.count == 64, room.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw ReachSecurityError.invalidHandshake }
        self.url = url; self.room = room.lowercased()
    }
    public var isValid: Bool { (try? Self(url: url, room: room)) != nil && url.absoluteString.utf8.count <= 2048 }
}

public enum ReachMessage: Codable, Sendable {
    case video(VideoPacket), input(RemoteInput), displays([RemoteDisplay]), selectDisplay(UInt32)
    case focusTracking(Bool), focus(RemoteFocus), scrollTarget(ScrollTargetState)
    case connectionProfile(ReachRelayConfiguration?)
    case clipboard(String), requestKeyframe, ping(Double), pong(Double), status(String), quality(StreamQuality)
}

/// Validate authenticated messages before they reach input APIs, geometry or codec allocation.
/// These bounds are deliberately wider than Reach's current 1920px / 60fps stream.
public extension ReachMessage {
    func isValid(from sender: String) -> Bool {
        guard sender == "host" || sender == "client" else { return false }
        switch self {
        case .video(let packet):
            return sender == "host" && packet.codec == "h264" &&
                (2...16_384).contains(packet.width) && (2...16_384).contains(packet.height) &&
                packet.width * packet.height <= 67_108_864 && packet.timestamp.isFinite && packet.timestamp >= 0 &&
                !packet.data.isEmpty && packet.data.count <= 6 * 1024 * 1024 &&
                packet.parameterSets.count <= 2 && packet.parameterSets.allSatisfy { !$0.isEmpty && $0.count <= 65_536 }
        case .input(let event):
            guard sender == "client", event.x.isFinite, event.y.isFinite,
                  (0...1).contains(event.button), event.keyCode <= 127,
                  event.modifiers & ~UInt64(0x00FF0000) == 0, event.text.utf16.count <= 16_384 else { return false }
            switch event.kind {
            case "move", "down", "up", "click", "rightClick": return (0...1).contains(event.x) && (0...1).contains(event.y)
            case "scroll": return abs(event.x) <= 2000 && abs(event.y) <= 2000
            case "text", "keyDown", "keyUp": return true
            default: return false
            }
        case .displays(let displays):
            return sender == "host" && displays.count <= 32 && Set(displays.map(\.id)).count == displays.count &&
                displays.allSatisfy { $0.name.utf8.count <= 256 && (1...32_768).contains($0.width) &&
                    (1...32_768).contains($0.height) && ($0.frame?.isValid ?? true) }
        case .selectDisplay, .focusTracking, .requestKeyframe: return sender == "client"
        case .focus(let focus): return sender == "host" && focus.isValid
        case .scrollTarget: return sender == "host"
        case .connectionProfile(let relay): return sender == "host" && (relay?.isValid ?? true)
        case .clipboard(let text): return text.utf8.count <= 1_000_000
        case .ping(let time), .pong(let time): return time.isFinite && time >= 0
        case .status(let text): return text.utf8.count <= 4096
        case .quality(let quality):
            return sender == "client" && (2...16_384).contains(quality.width) && (2...16_384).contains(quality.height) &&
                (10...60).contains(quality.fps) && (500_000...16_000_000).contains(quality.bitrate)
        }
    }
}

/// Incremental, bounded network framing. All integers are network byte order.
public struct ReachFramer {
    public static let maximumSize = 8 * 1024 * 1024
    private var buffer = Data()
    public init() {}
    /// Separate ingestion and extraction lets the peer tighten the bound before approval,
    /// then accept a coalesced first video frame immediately after the approval record.
    mutating func ingest(_ data: Data) throws {
        guard data.count <= Self.maximumSize + 4, buffer.count + data.count <= Self.maximumSize * 2 + 8 else { throw ReachSecurityError.invalidFrame }
        buffer.append(data)
    }
    mutating func nextFrame(maximumFrameSize: Int) throws -> Data? {
        guard (1...Self.maximumSize).contains(maximumFrameSize) else { throw ReachSecurityError.invalidFrame }
        guard buffer.count >= 4 else { return nil }
        let size = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0 && size <= maximumFrameSize else { throw ReachSecurityError.invalidFrame }
        guard buffer.count >= size + 4 else { return nil }
        let frame = Data(buffer.dropFirst(4).prefix(size))
        buffer.removeFirst(size + 4)
        return frame
    }
    public mutating func append(_ data: Data, maximumFrameSize: Int = Self.maximumSize) throws -> [Data] {
        try ingest(data)
        var frames = [Data]()
        while let frame = try nextFrame(maximumFrameSize: maximumFrameSize) { frames.append(frame) }
        return frames
    }
    public static func frame(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumSize else { throw ReachSecurityError.invalidFrame }
        let value = UInt32(data.count)
        return Data([UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) + data
    }
}
public enum ReachSecurityError: Error { case invalidFrame, invalidIdentity, invalidHandshake, unauthenticated, replay, keychain(OSStatus) }
