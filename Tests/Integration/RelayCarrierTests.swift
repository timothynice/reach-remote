import Foundation
import Security

/// Exact DER pin is confined to this executable and an ephemeral localhost fixture.
/// Production ReachPeer always uses URLSession.shared and normal system certificate validation.
final class LocalCertificatePin: NSObject, URLSessionDelegate, @unchecked Sendable {
    let certificate: Data
    init(_ certificate: Data) { self.certificate = certificate }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.host == "127.0.0.1",
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first, SecCertificateCopyData(leaf) as Data == certificate else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

@main struct RelayCarrierTests {
    enum Failure: Error { case timeout(String), assertion(String) }
    @MainActor static func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline { if condition() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        throw Failure.timeout(label)
    }
    @MainActor static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure.assertion(label) }; print("PASS: \(label)")
    }
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let publicConfiguration: ReachRelayConfiguration? = args[1] == "--public" ? try JSONDecoder().decode(ReachRelayConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: args[2]))) : nil
        let session: URLSession
        if publicConfiguration != nil { session = URLSession(configuration: .ephemeral) }
        else {
            let pin = LocalCertificatePin(try Data(contentsOf: URL(fileURLWithPath: args[2])))
            session = URLSession(configuration: .ephemeral, delegate: pin, delegateQueue: nil)
        }
        defer { session.invalidateAndCancel() }
        let prefix = "com.timothynice.reach.tests.relay." + UUID().uuidString
        defer { ["host", "client", "system", "wrong"].forEach { ReachIdentityStore(namespace: prefix + $0).deleteAll() } }
        let host = ReachPeer(role: .host, name: "Relay Mac", storageNamespace: prefix + "host", relaySession: session)
        let phone = ReachPeer(role: .client, name: "Relay Phone", storageNamespace: prefix + "client", relaySession: session)
        defer { host.stopHosting(); phone.disconnect() }
        let url = publicConfiguration?.url ?? URL(string: "wss://127.0.0.1:\(args[1])/tunnel")!, room = publicConfiguration?.room ?? ReachPeer.makeRelayRoom()
        if publicConfiguration == nil {
            var systemRejected = false
            let systemTrust = ReachPeer(role: .client, name: "Untrusted TLS fixture", storageNamespace: prefix + "system")
            systemTrust.onConnectionFailure = { _ in systemRejected = true }
            systemTrust.connectRelay(url: url, room: ReachPeer.makeRelayRoom())
            try await wait("system rejects self-signed fixture") { systemRejected }
            try check(!systemTrust.connected && !systemTrust.hasActiveTransport, "Production system TLS validation rejects self-signed localhost relay")
            systemTrust.disconnect()
            let wrongSession = URLSession(configuration: .ephemeral, delegate: LocalCertificatePin(Data([0])), delegateQueue: nil)
            defer { wrongSession.invalidateAndCancel() }
            var pinRejected = false
            let wrongPin = ReachPeer(role: .client, name: "Wrong pin fixture", storageNamespace: prefix + "wrong", relaySession: wrongSession)
            wrongPin.onConnectionFailure = { _ in pinRejected = true }
            wrongPin.connectRelay(url: url, room: ReachPeer.makeRelayRoom())
            try await wait("wrong certificate pin rejected") { pinRejected }
            try check(!wrongPin.connected && !wrongPin.hasActiveTransport, "Test pin rejects a different certificate")
            wrongPin.disconnect()
        }
        var received = [ReachMessage](), receivedHost = [ReachMessage]()
        phone.onMessage = { received.append($0) }; host.onMessage = { receivedHost.append($0) }
        let automatic = ReachAutoConnector(localGrace: 0.05)
        phone.onConnectionFailure = { _ in _ = automatic.failed() }
        phone.onIdentityVerified = { automatic.identityVerified() }
        host.connectRelay(url: url, room: room)
        automatic.start(local: { phone.connect(host: "127.0.0.1", port: 9) }, relay: { phone.connectRelay(url: url, room: room) })
        try await wait("WSS pairing") { host.requiresApproval && phone.requiresApproval }
        try check(automatic.route == .relay, "Failed local route automatically falls back to actual Swift WSS carrier")
        try check(host.pairingCode == phone.pairingCode, "Swift WSS carrier derives matching pairing codes through TLS relay")
        phone.send(.status("premature"))
        try check(receivedHost.isEmpty && !host.connected, "Relay application traffic blocked before bilateral approval")
        host.approvePairing(); phone.approvePairing()
        try await wait("WSS authentication") { host.connected && phone.connected }
        phone.send(.input(.init(kind: "click", x: 0.5, y: 0.5)))
        try await wait("Relay control delivery") { !receivedHost.isEmpty }
        try check(receivedHost.contains { if case .input = $0 { return true }; return false }, "Encrypted control crosses actual Swift WebSocket carrier")
        // Wait for the approval send to drain before sending video; transport deliberately drops stale video.
        try await Task.sleep(nanoseconds: 100_000_000)
        let bytes = Data(repeating: 42, count: 100_000)
        host.send(.video(.init(data: bytes, parameterSets: [], width: 1920, height: 1080, isKeyframe: false, timestamp: 1)))
        try await wait("Relay video delivery") { received.contains { if case .video = $0 { return true }; return false } }
        try check(received.contains { if case .video(let packet) = $0 { return packet.data == bytes }; return false }, "100KB encrypted video payload crosses actual Swift WSS carrier")
        let savedIdentity = phone.remoteIdentity!
        automatic.cancel(); phone.onConnectionFailure = nil
        phone.disconnect(); try await wait("Relay peer disconnect") { !host.connected }
        try await Task.sleep(nanoseconds: 150_000_000)
        host.connectRelay(url: url, room: room); phone.connectRelay(url: url, room: room, expectedIdentity: savedIdentity)
        try await wait("Relay trusted reconnect") { host.connected && phone.connected }
        try check(!host.requiresApproval && !phone.requiresApproval, "WSS trusted reconnect uses fresh authenticated session")
        phone.disconnect(); try await wait("host free for local selection") { !host.hasActiveTransport }
        automatic.cancel()
        let selection = ReachAutoConnector()
        defer { selection.cancel() }
        phone.onIdentityVerified = { selection.identityVerified() }
        phone.onConnectionFailure = { _ in _ = selection.failed() }
        host.startHosting(); try await wait("local listener") { host.listeningPort != nil }
        host.connectRelay(url: url, room: room)
        selection.start(local: { phone.connect(host: "127.0.0.1", port: host.listeningPort!, expectedIdentity: savedIdentity) },
                        relay: { phone.connectRelay(url: url, room: room, expectedIdentity: savedIdentity) })
        try await wait("same Mac selected locally") { host.connected && phone.connected }
        try check(selection.route == .local && phone.remoteIdentity == savedIdentity, "Nearby route wins over waiting relay for the same pinned Mac")
        phone.disconnect(); try await wait("host free before remote selection") { !host.hasActiveTransport }
        // Local selection abandoned a waiting WSS socket. Its close handshake can still
        // occupy the old room on a busy CI runner. Isolate this independent selection
        // case instead of racing cleanup; a deployed allowlisted check keeps its room.
        let remoteSelectionRoom = publicConfiguration == nil ? ReachPeer.makeRelayRoom() : room
        host.connectRelay(url: url, room: remoteSelectionRoom)
        selection.start(local: nil, relay: { phone.connectRelay(url: url, room: remoteSelectionRoom, expectedIdentity: savedIdentity) })
        try await wait("same Mac selected remotely") { host.connected && phone.connected }
        try check(selection.route == .relay && phone.remoteIdentity == savedIdentity, "Same saved identity reconnects remotely when no nearby route exists")
        print(publicConfiguration == nil ? "PASS: Local TLS fixture verified" : "PASS: Public TLS relay verified from this Mac; cellular desktop interaction remains unverified")
    }
}
