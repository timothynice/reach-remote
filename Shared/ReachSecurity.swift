import Foundation
import CryptoKit
import Security

struct ReachHello: Codable {
    let version: Int
    let role: String
    let name: String
    let identity: Data
    let ephemeral: Data
    let nonce: Data
    let signature: Data
    var signedData: Data {
        var result = Data("Reach-v1|\(role)|".utf8)
        for value in [Data(name.utf8), identity, ephemeral, nonce] {
            var length = UInt32(value.count).bigEndian
            result.append(Data(bytes: &length, count: 4)); result.append(value)
        }
        return result
    }
    func verify() throws {
        guard version == 1, ["host", "client"].contains(role), name.utf8.count <= 256, nonce.count == 32,
              identity.count == 32, ephemeral.count == 32, signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: identity), key.isValidSignature(signature, for: signedData) else { throw ReachSecurityError.invalidIdentity }
    }
}

struct ReachRecord: Codable { var sequence: UInt64; var data: Data }
struct ReachEnvelope: Codable { var commitment: Data?; var hello: ReachHello?; var record: ReachRecord? }
struct ReachSecurePayload: Codable { var approved: Bool?; var message: ReachMessage?; var supportsConnectionProfile: Bool? }

/// Fresh ephemeral keys per connection; separate directional keys and monotonic authenticated records.
final class ReachCipher {
    let hello: ReachHello
    private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    private var remoteCommitment: Data?
    var commitment: Data { Data(SHA256.hash(data: hello.signedData + hello.signature)) }
    func acceptCommitment(_ value: Data) throws {
        guard remoteCommitment == nil, value.count == 32 else { throw ReachSecurityError.invalidHandshake }
        remoteCommitment = value
    }
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var outgoing: UInt64 = 0
    private var incoming: UInt64 = 0
    private(set) var remoteIdentity: Data?
    private(set) var code: String?
    init(role: String, name: String, identity: Curve25519.Signing.PrivateKey) throws {
        var random = Data(count: 32)
        let status = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw ReachSecurityError.invalidHandshake }
        let unsigned = ReachHello(version: 1, role: role, name: String(name.prefix(64)), identity: identity.publicKey.rawRepresentation, ephemeral: ephemeral.publicKey.rawRepresentation, nonce: random, signature: Data())
        hello = ReachHello(version: 1, role: unsigned.role, name: unsigned.name, identity: unsigned.identity, ephemeral: unsigned.ephemeral, nonce: unsigned.nonce, signature: try identity.signature(for: unsigned.signedData))
    }
    func accept(_ remote: ReachHello) throws {
        guard sendKey == nil, remote.role != hello.role,
              remoteCommitment == Data(SHA256.hash(data: remote.signedData + remote.signature)) else { throw ReachSecurityError.invalidHandshake }
        try remote.verify()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote.ephemeral))
        let transcript = hello.role == "host" ? hello.signedData + remote.signedData : remote.signedData + hello.signedData
        let digest = Data(SHA256.hash(data: transcript))
        let codeNumber = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        code = String(format: "%06u", codeNumber)
        let h2c = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: digest, sharedInfo: Data("Reach-host-to-client-v1".utf8), outputByteCount: 32)
        let c2h = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: digest, sharedInfo: Data("Reach-client-to-host-v1".utf8), outputByteCount: 32)
        sendKey = hello.role == "host" ? h2c : c2h; receiveKey = hello.role == "host" ? c2h : h2c
        remoteIdentity = remote.identity
    }
    private func nonce(_ sequence: UInt64) throws -> AES.GCM.Nonce {
        var value = sequence.bigEndian
        return try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + Data(bytes: &value, count: 8))
    }
    func seal(_ data: Data) throws -> ReachRecord {
        guard let sendKey, outgoing < UInt64.max else { throw ReachSecurityError.unauthenticated }
        let sequence = outgoing; outgoing += 1
        let box = try AES.GCM.seal(data, using: sendKey, nonce: nonce(sequence), authenticating: Data("Reach-record-v1".utf8))
        return ReachRecord(sequence: sequence, data: box.ciphertext + box.tag)
    }
    func open(_ record: ReachRecord) throws -> Data {
        guard let receiveKey else { throw ReachSecurityError.unauthenticated }
        guard record.sequence == incoming, record.data.count >= 16, incoming < UInt64.max else { throw ReachSecurityError.replay }
        let box = try AES.GCM.SealedBox(nonce: nonce(record.sequence), ciphertext: record.data.dropLast(16), tag: record.data.suffix(16))
        let result = try AES.GCM.open(box, using: receiveKey, authenticating: Data("Reach-record-v1".utf8))
        incoming += 1
        return result
    }
}

final class ReachIdentityStore {
    private let service: String
    init(namespace: String = "com.timothynice.reach.identity") { self.service = namespace }
    func deleteAll() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
    func read(_ account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess else { return nil }
        return value as? Data
    }
    func write(_ account: String, _ value: Data) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if update == errSecItemNotFound {
            var insert = query; insert[kSecValueData as String] = value; insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw ReachSecurityError.keychain(status) }
        } else if update != errSecSuccess { throw ReachSecurityError.keychain(update) }
    }
    func identity() throws -> Curve25519.Signing.PrivateKey {
        if let data = read("private-key") { return try Curve25519.Signing.PrivateKey(rawRepresentation: data) }
        let key = Curve25519.Signing.PrivateKey(); try write("private-key", key.rawRepresentation); return key
    }
    private func account(_ key: Data) -> String { "trusted-" + SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined() }
    func isTrusted(_ key: Data) -> Bool { read(account(key)) == key }
    func trust(_ key: Data) throws { try write(account(key), key) }
    func revokeAll() {
        // Revocation leaves the local identity intact and removes every paired key.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return }
        for item in items {
            if let account = item[kSecAttrAccount as String] as? String, account.hasPrefix("trusted-") {
                SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
            }
        }
    }
}

public extension ReachRelayConfiguration {
    static func load() -> ReachRelayConfiguration? {
        let store = ReachIdentityStore(namespace: "com.timothynice.reach.relay")
        guard let data = store.read("configuration"), let decoded = try? PropertyListDecoder().decode(Self.self, from: data) else { return nil }
        return try? Self(url: decoded.url, room: decoded.room)
    }
    func save() throws {
        try ReachIdentityStore(namespace: "com.timothynice.reach.relay").write("configuration", PropertyListEncoder().encode(self))
    }
    static func clear() { ReachIdentityStore(namespace: "com.timothynice.reach.relay").deleteAll() }
}
