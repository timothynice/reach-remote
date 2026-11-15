import Foundation

@main struct PeerIntegrationTests {
    enum Failure: Error { case timeout(String), assertion(String) }
    @MainActor static func wait(_ label: String, seconds: Double = 10, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure.timeout(label)
    }
    @MainActor static func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw Failure.assertion(name) }
        print("PASS: \(name)")
    }
    @MainActor static func main() async throws {
        let prefix = "com.timothynice.reach.tests." + UUID().uuidString
        let hostStore = prefix + ".host", phoneStore = prefix + ".phone", untrustedStore = prefix + ".stranger"
        defer { [hostStore, phoneStore, untrustedStore].forEach { ReachIdentityStore(namespace: $0).deleteAll() } }
        let host = ReachPeer(role: .host, name: "Integration Mac", storageNamespace: hostStore)
        let phone = ReachPeer(role: .client, name: "Integration Phone", storageNamespace: phoneStore)
        var receivedAtHost = [ReachMessage](), receivedAtPhone = [ReachMessage]()
        host.onMessage = { receivedAtHost.append($0) }
        phone.onMessage = { receivedAtPhone.append($0) }
        host.startHosting()
        defer { host.stopHosting(); phone.disconnect() }
        try await wait("listener ready") { host.listeningPort != nil }
        phone.connect(host: "127.0.0.1", port: host.listeningPort!)
        try await wait("pairing prompts") { host.requiresApproval && phone.requiresApproval }
        try check(host.pairingCode == phone.pairingCode && host.pairingCode?.count == 6, "TCP peers derive matching SAS")
        phone.send(.status("premature"))
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(receivedAtHost.isEmpty && !host.connected && !phone.connected, "Application data blocked before approval")
        host.approvePairing()
        host.rejectPairing() // Emulate a sheet binding dismissal after the approval action.
        try check(host.hasActiveTransport, "Stale sheet dismissal preserves pending approved transport")
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(!host.connected && !phone.connected, "One-sided approval cannot authorize session")
        phone.approvePairing()
        phone.rejectPairing() // SwiftUI may write isPresented=false after approval.
        try await wait("authenticated") { host.connected && phone.connected }
        phone.rejectPairing()
        try check(phone.connected, "Stale pairing dismissal preserves authenticated session")
        phone.send(.status("phone-to-host")); host.send(.status("host-to-phone"))
        try await wait("bidirectional messages") { !receivedAtHost.isEmpty && !receivedAtPhone.isEmpty }
        if case .status(let value) = receivedAtHost.first { try check(value == "phone-to-host", "Encrypted phone-to-host delivery") }
        else { throw Failure.assertion("Host status") }
        if case .status(let value) = receivedAtPhone.first { try check(value == "host-to-phone", "Encrypted host-to-phone delivery") }
        else { throw Failure.assertion("Phone status") }
        phone.send(.focusTracking(true))
        try await wait("focus tracking request") { receivedAtHost.contains { if case .focusTracking(true) = $0 { return true }; return false } }
        let focus = RemoteFocus(field: RemoteRect(x: 0.2, y: 0.7, width: 0.5, height: 0.1), caret: RemoteRect(x: 0.3, y: 0.72, width: 0.001, height: 0.02))
        host.send(.focus(RemoteFocus(field: RemoteRect(x: .nan, y: 0, width: 1, height: 1))))
        host.send(.focus(focus))
        try await wait("focus metadata delivery") { receivedAtPhone.contains { if case .focus(let value) = $0 { return value == focus }; return false } }
        try check(receivedAtPhone.filter { if case .focus = $0 { return true }; return false }.count == 1, "Encrypted focus tracking and validated field/caret geometry roundtrip")
        for state in [ScrollTargetState.scrollable, .notScrollable, .unknown] {
            host.send(.scrollTarget(state))
            try await wait("scroll target metadata") { receivedAtPhone.contains { if case .scrollTarget(let value) = $0 { return value == state }; return false } }
        }
        try check(receivedAtPhone.filter { if case .scrollTarget = $0 { return true }; return false }.count == 3, "Encrypted three-state scroll capability roundtrip")
        try await Task.sleep(nanoseconds: 100_000_000)
        let video = Data((0..<100_000).map { UInt8($0 & 255) })
        host.send(.video(.init(data: video, parameterSets: [Data([1, 2, 3])], width: 1920, height: 1080, isKeyframe: true, timestamp: 42)))
        try await wait("video delivery") { receivedAtPhone.contains { if case .video = $0 { return true }; return false } }
        if case .video(let packet) = receivedAtPhone.last {
            try check(packet.data == video && packet.parameterSets == [Data([1,2,3])] && packet.timestamp == 42, "100KB encrypted binary video roundtrip")
        } else { throw Failure.assertion("Video") }
        phone.disconnect()
        try await wait("host disconnect") { !host.connected }
        phone.connect(host: "127.0.0.1", port: host.listeningPort!)
        try await wait("trusted reconnect") { host.connected && phone.connected }
        try check(!host.requiresApproval && !phone.requiresApproval, "Keychain trust enables fresh-key authenticated reconnect")
        try check(host.supportsConnectionProfile && phone.supportsConnectionProfile, "Encrypted approval negotiates profile support")
        let savedIdentity = phone.remoteIdentity!
        let profile = try ReachRelayConfiguration(url: URL(string: "wss://example.com/tunnel")!, room: String(repeating: "a", count: 64))
        host.send(.connectionProfile(profile))
        try await wait("encrypted connection profile") { receivedAtPhone.contains { if case .connectionProfile(let config) = $0 { return config?.room == profile.room }; return false } }
        try check(true, "Relay invitation crosses only the authenticated encrypted session")
        phone.disconnect(); try await wait("disconnect before pin check") { !host.connected }
        var mismatchedIdentityRejected = false
        phone.onConnectionFailure = { _ in mismatchedIdentityRejected = true }
        phone.connect(to: .init(id: "test", name: "Same Mac name", endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: host.listeningPort!)!)), expectedIdentity: Data(repeating: 0, count: 32))
        try await wait("wrong saved identity rejected") { mismatchedIdentityRejected }
        try check(!phone.connected && !phone.requiresApproval, "A trusted host with the wrong pinned identity cannot connect or request re-pairing")
        phone.onConnectionFailure = nil
        try await wait("host free after pin rejection") { !host.hasActiveTransport }
        phone.connect(to: .init(id: "test", name: "Renamed Mac", endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: host.listeningPort!)!)), expectedIdentity: savedIdentity)
        try await wait("correct pin reconnect") { host.connected && phone.connected }
        try check(true, "Saved identity reconnect succeeds independently of advertised name")
        let hostCount = receivedAtHost.count
        try phone.sendPayloadForTesting(ReachSecurePayload(message: .input(.init(kind: "move", x: .nan))))
        try await wait("malformed authenticated input closes transport") { !host.connected && !phone.connected }
        try check(receivedAtHost.count == hostCount, "Malformed encrypted input rejected before host dispatch")
        phone.connect(host: "127.0.0.1", port: host.listeningPort!)
        try await wait("reconnect after malformed input") { host.connected && phone.connected }
        let phoneCount = receivedAtPhone.count
        try host.sendPayloadForTesting(ReachSecurePayload(message: .pong(.infinity)))
        try await wait("nonfinite authenticated pong closes transport") { !host.connected && !phone.connected }
        try check(receivedAtPhone.count == phoneCount, "Infinite encrypted RTT rejected before client dispatch")
        phone.connect(host: "127.0.0.1", port: host.listeningPort!)
        try await wait("reconnect after malformed pong") { host.connected && phone.connected }
        try phone.sendPayloadForTesting(ReachSecurePayload(approved: true, message: .status("ambiguous")))
        try await wait("ambiguous authenticated payload closes transport") { !host.connected && !phone.connected }
        try check(!receivedAtHost.contains { if case .status("ambiguous") = $0 { return true }; return false }, "Ambiguous approval-plus-message envelope rejected")
        phone.connect(host: "127.0.0.1", port: host.listeningPort!)
        try await wait("reconnect after ambiguous payload") { host.connected && phone.connected }
        host.forgetTrustedDevices()
        try await wait("phone disconnected") { !phone.connected }
        phone.connect(host: "127.0.0.1", port: host.listeningPort!)
        try await wait("revocation re-prompts") { host.requiresApproval }
        try check(!host.connected, "Revoked trust requires Mac confirmation")
        host.rejectPairing()
        try await wait("rejection closes phone") { !phone.connected && phone.pairingCode == nil }
        let stranger = ReachPeer(role: .client, name: "Untrusted", storageNamespace: untrustedStore)
        defer { stranger.disconnect() }
        stranger.connect(host: "127.0.0.1", port: host.listeningPort!)
        try await wait("stranger pairing") { host.requiresApproval && stranger.requiresApproval }
        stranger.approvePairing()
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(!host.connected && !stranger.connected, "Unknown identity cannot inherit previous device approval")
        host.rejectPairing()
        try await wait("stranger rejected") { stranger.pairingCode == nil }
        try check(!host.connected && !stranger.connected, "Rejecting pairing closes unauthenticated session")
        host.stopHosting()
        try check(host.listeningPort == nil, "Stopping host closes listener")
        print("PASS: Real TCP integration complete; isolated test Keychain entries removed")
    }
}
