import Foundation
import CryptoKit

/// A verified device, independent of the address or transport used to reach it.
public struct SavedMac: Codable, Identifiable, Sendable {
    public let identity: Data
    public var name: String
    public var relay: ReachRelayConfiguration?
    public var id: String { Self.fingerprint(identity) }
    public static func fingerprint(_ identity: Data) -> String {
        SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }
    public init(identity: Data, name: String, relay: ReachRelayConfiguration? = nil) {
        self.identity = identity; self.name = name; self.relay = relay
    }
    public var isValid: Bool {
        identity.count == 32 && !name.isEmpty && name.utf8.count <= 256 && (relay?.isValid ?? true)
    }
}

/// Names and invitations are saved together in the device-only Keychain, never discovery TXT.
public struct SavedMacStore {
    private let store: ReachIdentityStore
    public init(namespace: String = "com.timothynice.reach.destinations") { store = ReachIdentityStore(namespace: namespace) }
    public func load() -> [SavedMac] {
        guard let data = store.read("macs"), let macs = try? PropertyListDecoder().decode([SavedMac].self, from: data),
              macs.count <= 32, macs.allSatisfy(\.isValid), Set(macs.map(\.id)).count == macs.count else { return [] }
        return macs
    }
    public func save(_ mac: SavedMac) throws {
        guard mac.isValid else { throw ReachSecurityError.invalidIdentity }
        var macs = load().filter { $0.id != mac.id }
        macs.insert(mac, at: 0)
        try store.write("macs", PropertyListEncoder().encode(Array(macs.prefix(32))))
    }
    public func clear() { store.deleteAll() }
}

/// One local attempt, then one relay attempt. Identity verification stops the local timer so
/// a human comparing pairing codes is never interrupted by a transport switch.
@MainActor public final class ReachAutoConnector {
    public enum Route { case local, relay }
    public private(set) var route: Route?
    private var relay: (() -> Void)?
    private var fallback: Task<Void, Never>?
    private let localGrace: Double
    public init(localGrace: Double = 1.5) { self.localGrace = localGrace }
    public func start(local: (() -> Void)?, relay: (() -> Void)?) {
        cancel(); self.relay = relay
        if let local {
            route = .local
            if relay != nil {
                fallback = Task { [weak self] in
                    guard let self else { return }
                    do { try await Task.sleep(for: .seconds(self.localGrace)) } catch { return }
                    guard !Task.isCancelled else { return }
                    _ = self.failed()
                }
            }
            local()
        } else if let relay { route = .relay; relay() }
    }
    public func identityVerified() { fallback?.cancel(); fallback = nil }
    @discardableResult public func failed() -> Bool {
        guard route == .local, let relay else { return false }
        identityVerified(); route = .relay; relay(); return true
    }
    public func cancel() { identityVerified(); relay = nil; route = nil }
    deinit { fallback?.cancel() }
}
