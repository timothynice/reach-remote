import Foundation
import CryptoKit

@main struct CoreSecurityTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name); checks += 1
        }
        func rejected(_ name: String, _ action: () throws -> Void) {
            do { try action(); fatalError("Accepted: \(name)") } catch { checks += 1 }
        }
        let host = try ReachCipher(role: "host", name: "Mac", identity: .init())
        let phone = try ReachCipher(role: "client", name: "Phone", identity: .init())
        rejected("hello before commitment") { try host.accept(phone.hello) }
        try host.acceptCommitment(phone.commitment); try phone.acceptCommitment(host.commitment)
        rejected("duplicate commitment") { try host.acceptCommitment(phone.commitment) }
        try host.accept(phone.hello); try phone.accept(host.hello)
        check(host.code == phone.code, "SAS agreement")
        check(host.code?.count == 6, "SAS format")
        let message = Data("desktop input".utf8)
        let first = try phone.seal(message)
        check(try host.open(first) == message, "Phone to host")
        rejected("replayed record") { _ = try host.open(first) }
        let reply = try host.seal(Data("frame".utf8))
        check(try phone.open(reply) == Data("frame".utf8), "Host to phone")
        let second = try phone.seal(message)
        var tampered = second.data; tampered[tampered.startIndex] ^= 1
        rejected("ciphertext tamper") { _ = try host.open(ReachRecord(sequence: second.sequence, data: tampered)) }
        check(try host.open(second) == message, "Failed authentication does not consume receive sequence")
        rejected("reflected direction") { _ = try phone.open(try phone.seal(message)) }
        let later = try phone.seal(message)
        rejected("out of order") { _ = try host.open(later) }
        rejected("duplicate hello") { try host.accept(phone.hello) }
        let unsigned = ReachHello(version: 1, role: phone.hello.role, name: "Imposter", identity: phone.hello.identity, ephemeral: phone.hello.ephemeral, nonce: phone.hello.nonce, signature: phone.hello.signature)
        rejected("signed name tamper") { try unsigned.verify() }
        let freshHost = try ReachCipher(role: "host", name: "Mac", identity: .init())
        try freshHost.acceptCommitment(host.commitment)
        rejected("same role") { try freshHost.accept(host.hello) }
        let mismatch = try ReachCipher(role: "host", name: "Other", identity: .init())
        try mismatch.acceptCommitment(Data(repeating: 0, count: 32))
        rejected("hello mismatches prior commitment") { try mismatch.accept(phone.hello) }
        rejected("application before handshake") { _ = try freshHost.seal(message) }
        let valid = try ReachFramer.frame(message)
        var parser = ReachFramer()
        check(try parser.append(valid.prefix(2)).isEmpty, "Split header")
        check(try parser.append(valid.dropFirst(2).prefix(3)).isEmpty, "Split payload")
        check(try parser.append(valid.dropFirst(5)) == [message], "Reassembly")
        check(try parser.append(valid + valid) == [message, message], "Coalesced frames")
        var bad = ReachFramer()
        rejected("oversize frame") { _ = try bad.append(Data([127, 255, 255, 255])) }
        rejected("empty frame") { _ = try ReachFramer.frame(Data()) }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let payload = ReachMessage.video(VideoPacket(data: Data(repeating: 42, count: 100_000), parameterSets: [Data([1,2])], width: 1920, height: 1080, isKeyframe: true, timestamp: 1))
        let wire = try encoder.encode(payload)
        check(wire.count < 101_000, "Binary video encoding avoids base64 expansion")
        if case .video(let result) = try PropertyListDecoder().decode(ReachMessage.self, from: wire) {
            check(result.data.count == 100_000 && result.isKeyframe, "Video roundtrip")
        } else { fatalError("Wrong video case") }
        let field = RemoteRect(x: 0.2, y: 0.6, width: 0.4, height: 0.2)
        let caret = RemoteRect(x: 0.3, y: 0.65, width: 0.001, height: 0.02)
        let focus = RemoteFocus(field: field, caret: caret)
        check(focus.isValid, "Normalized field and caret valid")
        let focusWire = try encoder.encode(ReachMessage.focus(focus))
        if case .focus(let result) = try PropertyListDecoder().decode(ReachMessage.self, from: focusWire) {
            check(result == focus, "Focus geometry binary roundtrip")
        } else { fatalError("Wrong focus case") }
        let tracking = try encoder.encode(ReachMessage.focusTracking(true))
        if case .focusTracking(let enabled) = try PropertyListDecoder().decode(ReachMessage.self, from: tracking) {
            check(enabled, "Focus tracking request roundtrip")
        } else { fatalError("Wrong tracking case") }
        check(!RemoteRect(x: .nan, y: 0, width: 0.1, height: 0.1).isValid, "NaN focus rejected")
        check(!RemoteRect(x: 0, y: .infinity, width: 0.1, height: 0.1).isValid, "Infinite focus rejected")
        check(!RemoteRect(x: -0.1, y: 0, width: 0.1, height: 0.1).isValid, "Negative focus rejected")
        check(!RemoteRect(x: 0.9, y: 0, width: 0.2, height: 0.1).isValid, "Out-of-display focus rejected")
        check(!RemoteRect(x: 0, y: 0, width: 0, height: 0.1).isValid, "Empty focus rejected")
        check(!RemoteFocus(field: field, caret: RemoteRect(x: 1, y: 1, width: 1, height: 1)).isValid, "Invalid caret rejected")
        check(RemoteFocus(field: field).isValid, "Field-only focus accepted")
        check(ReachMessage.input(.init(kind: "move", x: 0.4, y: 0.8)).isValid(from: "client"), "Valid pointer")
        check(!ReachMessage.input(.init(kind: "move", x: .nan)).isValid(from: "client"), "NaN pointer rejected")
        check(!ReachMessage.input(.init(kind: "move", x: 2)).isValid(from: "client"), "Out-of-range pointer rejected")
        check(!ReachMessage.input(.init(kind: "launch")).isValid(from: "client"), "Unknown input kind rejected")
        check(!ReachMessage.input(.init(kind: "scroll", y: 2001)).isValid(from: "client"), "Excess scroll rejected")
        check(!ReachMessage.input(.init(kind: "keyDown", keyCode: 128)).isValid(from: "client"), "Invalid key rejected")
        check(!ReachMessage.input(.init(kind: "keyDown", modifiers: UInt64.max)).isValid(from: "client"), "Invalid flags rejected")
        check(!ReachMessage.input(.init(kind: "text", text: String(repeating: "a", count: 16_385))).isValid(from: "client"), "Excess text rejected")
        check(!ReachMessage.input(.init(kind: "click")).isValid(from: "host"), "Host cannot inject client input")
        check(!ReachMessage.pong(.infinity).isValid(from: "host"), "Infinite RTT rejected before integer conversion")
        check(!ReachMessage.ping(.nan).isValid(from: "client"), "NaN ping rejected")
        check(!ReachMessage.clipboard(String(repeating: "a", count: 1_000_001)).isValid(from: "host"), "Excess clipboard rejected")
        check(!ReachMessage.status(String(repeating: "a", count: 4097)).isValid(from: "host"), "Excess status rejected")
        check(!ReachMessage.quality(.init(width: 1920, height: 1080, fps: 1000, bitrate: 6_000_000)).isValid(from: "client"), "Excess frame rate rejected")
        check(!ReachMessage.displays([.init(id: 1, name: "A", width: 100, height: 100), .init(id: 1, name: "B", width: 100, height: 100)]).isValid(from: "host"), "Duplicate display IDs rejected")
        check(!ReachMessage.displays([.init(id: 1, name: "A", width: -1, height: 100)]).isValid(from: "host"), "Invalid display dimensions rejected")
        check(!ReachMessage.video(.init(data: Data([1]), parameterSets: [], width: Int.max, height: 1080, isKeyframe: false, timestamp: 0)).isValid(from: "host"), "Overflow video dimensions rejected")
        check(!ReachMessage.video(.init(data: Data([1]), parameterSets: [], width: 1920, height: 1080, isKeyframe: false, timestamp: .nan)).isValid(from: "host"), "NaN video time rejected")
        check(!ReachMessage.video(.init(data: Data([1]), parameterSets: [], width: 1920, height: 1080, isKeyframe: false, timestamp: 0, codec: "unknown")).isValid(from: "host"), "Unknown codec rejected")
        check(!ReachMessage.video(.init(data: Data(), parameterSets: [], width: 1920, height: 1080, isKeyframe: false, timestamp: 0)).isValid(from: "host"), "Empty video rejected")
        var transition = ReachFramer()
        let firstVideo = Data(repeating: 1, count: 100_000)
        try transition.ingest(ReachFramer.frame(message) + ReachFramer.frame(firstVideo))
        check(try transition.nextFrame(maximumFrameSize: 16_384) == message, "Preapproval small frame extracted")
        check(try transition.nextFrame(maximumFrameSize: ReachFramer.maximumSize) == firstVideo, "Coalesced video accepted after approval changes bound")
        var handshakeFramer = ReachFramer()
        rejected("Oversize unauthenticated header rejected before allocation") { _ = try handshakeFramer.append(Data([0, 1, 0, 0]), maximumFrameSize: 16_384) }
        rejected("Relay credentials in URL rejected") { _ = try ReachRelayConfiguration(url: URL(string: "wss://user:pass@example.com/tunnel")!, room: String(repeating: "a", count: 64)) }
        rejected("Relay query ambiguity rejected") { _ = try ReachRelayConfiguration(url: URL(string: "wss://example.com/tunnel?room=other")!, room: String(repeating: "a", count: 64)) }
        let relayConfig = try ReachRelayConfiguration(url: URL(string: "wss://example.com/tunnel")!, room: String(repeating: "A", count: 64))
        check(relayConfig.room == String(repeating: "a", count: 64), "Relay room normalized to server-compatible ASCII hex")
        print("PASS: \(checks) security, framing, and binary protocol checks")
    }
}
