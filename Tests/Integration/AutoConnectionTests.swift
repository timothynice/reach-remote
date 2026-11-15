import Foundation

@main struct AutoConnectionTests {
    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor static func main() async throws {
        var local = 0, remote = 0
        let connector = ReachAutoConnector(localGrace: 0.02)
        connector.start(local: { local += 1 }, relay: { remote += 1 })
        precondition(local == 1 && remote == 0)
        try await waitUntil { remote >= 1 }
        precondition(connector.route == .relay && remote == 1)
        precondition(!connector.failed() && remote == 1)
        connector.start(local: { local += 1 }, relay: { remote += 1 })
        connector.identityVerified()
        try await Task.sleep(for: .milliseconds(60))
        precondition(connector.route == .local && remote == 1, "Pairing must not be interrupted")
        precondition(connector.failed() && remote == 2, "A verified but broken local connection still falls back")
        connector.start(local: { local += 1 }, relay: { remote += 1 })
        precondition(connector.failed() && remote == 3)
        try await Task.sleep(for: .milliseconds(60))
        precondition(remote == 3, "Failure plus timer must not start two relays")
        connector.start(local: { local += 1 }, relay: { remote += 1 })
        connector.cancel()
        try await Task.sleep(for: .milliseconds(60))
        precondition(remote == 3 && connector.route == nil)
        connector.start(local: { local += 1 }, relay: { remote += 1 })
        connector.start(local: nil, relay: { remote += 1 })
        try await Task.sleep(for: .milliseconds(60))
        precondition(remote == 4 && connector.route == .relay, "New attempt invalidates old timer")
        connector.start(local: { local += 1 }, relay: nil)
        precondition(!connector.failed())
        connector.start(local: nil, relay: nil)
        precondition(connector.route == nil)
        let prefix = "com.timothynice.reach.tests.destinations." + UUID().uuidString
        let store = SavedMacStore(namespace: prefix)
        defer { store.clear() }
        let identity = Data(repeating: 1, count: 32), another = Data(repeating: 2, count: 32)
        let relay = try ReachRelayConfiguration(url: URL(string: "wss://example.com/tunnel")!, room: String(repeating: "a", count: 64))
        try store.save(SavedMac(identity: identity, name: "Mac"))
        try store.save(SavedMac(identity: identity, name: "Renamed Mac", relay: relay))
        let reloaded = SavedMacStore(namespace: prefix).load()
        precondition(reloaded.count == 1 && reloaded[0].name == "Renamed Mac" && reloaded[0].relay?.room == relay.room)
        try store.save(SavedMac(identity: another, name: "Renamed Mac"))
        precondition(store.load().count == 2, "Equal names must not merge distinct identities")
        precondition(!SavedMac(identity: Data(), name: "Bad").isValid)
        precondition(ReachMessage.connectionProfile(relay).isValid(from: "host"))
        precondition(!ReachMessage.connectionProfile(relay).isValid(from: "client"))
        struct LegacyApproval: Codable { let approved: Bool?; let message: ReachMessage? }
        let legacy = try PropertyListEncoder().encode(LegacyApproval(approved: true, message: nil))
        let upgraded = try PropertyListDecoder().decode(ReachSecurePayload.self, from: legacy)
        precondition(upgraded.approved == true && upgraded.supportsConnectionProfile == nil)
        let modern = try PropertyListEncoder().encode(ReachSecurePayload(approved: true, supportsConnectionProfile: true))
        let legacyDecoded = try PropertyListDecoder().decode(LegacyApproval.self, from: modern)
        precondition(legacyDecoded.approved == true)
        store.clear(); precondition(store.load().isEmpty)
        print("PASS: local-first, timed fallback, pairing grace, immediate failure, retry deduplication, cancellation, relay-only, unavailable, identity-based persistence, and profile roles")
    }
}
