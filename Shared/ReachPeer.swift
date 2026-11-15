import Foundation
import Network
import Combine
import CryptoKit

public struct DiscoveredHost: Identifiable {
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint
    public let identityID: String?
    public init(id: String, name: String, endpoint: NWEndpoint, identityID: String? = nil) { self.id = id; self.name = name; self.endpoint = endpoint; self.identityID = identityID }
}

@MainActor public final class ReachPeer: ObservableObject {
    public enum Role: String { case host, client }
    @Published public private(set) var discoveredHosts: [DiscoveredHost] = []
    @Published public private(set) var state = "Not connected"
    @Published public private(set) var pairingCode: String?
    @Published public private(set) var requiresApproval = false
    @Published public private(set) var connected = false
    @Published public private(set) var remoteName = ""
    @Published public private(set) var listeningPort: UInt16?
    public var hasActiveTransport: Bool { connection != nil || webSocket != nil }
    public var onMessage: ((ReachMessage) -> Void)?
    public var remoteIdentity: Data? { cipher?.remoteIdentity }
    public private(set) var supportsConnectionProfile = false
    public var onIdentityVerified: (() -> Void)?
    private var expectedIdentity: Data?
    public var onAuthenticated: (() -> Void)?
    public var onDisconnected: (() -> Void)?
    public var onConnectionFailure: ((String) -> Void)?
    public var onVideoDropped: (() -> Void)?
    private let role: Role
    private let name: String
    private let store: ReachIdentityStore
    private let relaySession: URLSession
    private var connection: NWConnection?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var webSocket: URLSessionWebSocketTask?
    private var cipher: ReachCipher?
    private var framer = ReachFramer()
    private let encoder: PropertyListEncoder = { let encoder = PropertyListEncoder(); encoder.outputFormat = .binary; return encoder }()
    private let decoder = PropertyListDecoder()
    private var locallyApproved = false
    private var remotelyApproved = false
    private var sending = false
    private var queue = [(Data, Bool)]()
    private var queuedBytes = 0
    private var timeout: Task<Void, Never>?
    private var epoch = UUID()
    private var keepAlive: Task<Void, Never>?
    private var lastReceived = Date()
    private var sentVideoFrames = 0
    private var receivedVideoFrames = 0
    private var preauthenticationBytes = 0
    public var diagnosticsURL: URL { ReachDiagnostics.logURL }
    private func diagnose(_ event: String, detail: String = "") {
        ReachDiagnostics.record(component: "peer.\(role.rawValue)", event: event, metadata: "session=\(epoch.uuidString.prefix(8)) connected=\(connected) localApproved=\(locallyApproved) remoteApproved=\(remotelyApproved) queuedBytes=\(queuedBytes) \(detail)")
    }
    public init(role: Role, name: String, storageNamespace: String = "com.timothynice.reach.identity") {
        self.role = role; self.name = name; self.store = ReachIdentityStore(namespace: storageNamespace); self.relaySession = .shared
    }
    #if REACH_TESTING
    /// Tests may pin an ephemeral localhost certificate without changing production trust evaluation.
    init(role: Role, name: String, storageNamespace: String, relaySession: URLSession) {
        self.role = role; self.name = name; self.store = ReachIdentityStore(namespace: storageNamespace); self.relaySession = relaySession
    }
    #endif

    public func startHosting() {
        guard listener == nil else { return }
        diagnose("listener_start")
        do {
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.includePeerToPeer = true
            let identityID = SavedMac.fingerprint(try store.identity().publicKey.rawRepresentation)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.service = NWListener.Service(name: name, type: "_reach._tcp", txtRecord: NWTXTRecord(["id": identityID]))
            listener.stateUpdateHandler = { [weak self] value in
                Task { @MainActor in
                    guard let self else { return }
                    if case .ready = value { self.diagnose("listener_ready"); self.listeningPort = self.listener?.port?.rawValue; if !self.connected { self.state = "Ready for your devices" } }
                    if case .failed(let error) = value { self.state = "Discovery: \(error.localizedDescription)" }
                }
            }
            listener.newConnectionHandler = { [weak self] candidate in
                Task { @MainActor in
                    guard let self else { candidate.cancel(); return }
                    guard self.connection == nil, self.webSocket == nil || self.cipher == nil else { candidate.cancel(); return }
                    if self.webSocket != nil { self.disconnect() }
                    self.attach(candidate)
                }
            }
            listener.start(queue: .main)
        } catch { state = error.localizedDescription }
    }
    public func stopHosting() {
        let old = listener; listener = nil; listeningPort = nil; old?.cancel(); disconnect()
    }
    public func browse() {
        guard browser == nil else { return }
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp); parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_reach._tcp", domain: nil), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.discoveredHosts = results.compactMap { result in
                    if case .service(let name, _, _, _) = result.endpoint {
                        var identityID: String?
                        if case .bonjour(let txt) = result.metadata, case .string(let value) = txt.getEntry(for: "id"),
                           value.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) { identityID = value }
                        return DiscoveredHost(id: String(describing: result.endpoint), name: name, endpoint: result.endpoint, identityID: identityID)
                    }
                    return nil
                }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }
        browser.stateUpdateHandler = { [weak self] value in
            if case .failed(let error) = value { Task { @MainActor in self?.state = "Local discovery: \(error.localizedDescription)" } }
        }
        browser.start(queue: .main)
    }
    public func connect(to host: DiscoveredHost, expectedIdentity: Data? = nil) {
        disconnect()
        self.expectedIdentity = expectedIdentity
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp); parameters.includePeerToPeer = true
        attach(NWConnection(to: host.endpoint, using: parameters))
    }
    public func connect(host: String, port: UInt16, expectedIdentity: Data? = nil) {
        guard let port = NWEndpoint.Port(rawValue: port), !host.isEmpty else { state = "Enter a valid host and port"; return }
        connect(to: DiscoveredHost(id: host, name: host, endpoint: .hostPort(host: .init(host), port: port)), expectedIdentity: expectedIdentity)
    }
    private func attach(_ candidate: NWConnection) {
        resetSession(); connection = candidate; state = "Connecting securely…"
        diagnose("tcp_attached")
        let session = epoch
        candidate.stateUpdateHandler = { [weak self] status in
            Task { @MainActor in
                guard let self, self.epoch == session else { return }
                switch status {
                case .ready: self.diagnose("tcp_ready"); self.beginHandshake(); self.receive(candidate, session: session)
                case .failed(let error): self.diagnose("tcp_failed", detail: ReachDiagnostics.errorCode(error)); self.fail(error.localizedDescription)
                case .cancelled: self.diagnose("tcp_cancelled"); self.fail("Disconnected")
                case .waiting: self.state = "Waiting for network…"
                default: break
                }
            }
        }
        candidate.start(queue: .main)
        armTimeout(seconds: 10)
    }
    public static func makeRelayRoom() -> String {
        let first = Curve25519.Signing.PrivateKey().rawRepresentation
        return first.map { String(format: "%02x", $0) }.joined()
    }
    /// Both endpoints use outbound WSS. Desktop, input and approval records are encrypted; discovery metadata remains visible to the relay.
    public func connectRelay(url: URL, room: String, expectedIdentity: Data? = nil) {
        guard let configuration = try? ReachRelayConfiguration(url: url, room: room) else { state = "Use a wss:// relay and a 64-character room secret"; return }
        disconnect()
        resetSession()
        self.expectedIdentity = expectedIdentity
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        parts.queryItems = [URLQueryItem(name: "room", value: configuration.room), URLQueryItem(name: "role", value: role.rawValue)]
        guard let target = parts.url else { return }
        let socket = relaySession.webSocketTask(with: target)
        socket.maximumMessageSize = ReachFramer.maximumSize + 4
        webSocket = socket; state = "Waiting for your other device…"
        diagnose("relay_waiting")
        socket.resume()
        receiveSocket(socket, session: epoch)
        armTimeout(seconds: 120)
    }
    private func receiveSocket(_ socket: URLSessionWebSocketTask, session: UUID) {
        Task { [weak self] in
            do {
                let message = try await socket.receive()
                guard let self, self.epoch == session else { return }
                switch message {
                case .data(let data): try self.consume(data)
                case .string(let string):
                    if let data = string.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], value["type"] as? String == "ready", self.cipher == nil { self.beginHandshake() }
                @unknown default: break
                }
                self.receiveSocket(socket, session: session)
            } catch {
                guard let self, self.epoch == session else { return }
                self.fail("Relay disconnected: \(error.localizedDescription)")
            }
        }
    }
    private func receive(_ candidate: NWConnection, session: UUID) {
        candidate.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.epoch == session else { return }
                do {
                    if let data { try self.consume(data) }
                    if let error { self.fail(error.localizedDescription) }
                    else if complete { self.diagnose("tcp_remote_closed"); self.fail("Your Mac disconnected") }
                    else { self.receive(candidate, session: session) }
                } catch { self.diagnose("secure_receive_failed", detail: ReachDiagnostics.errorCode(error)); self.fail("Secure connection rejected") }
            }
        }
    }
    private func beginHandshake() {
        diagnose("handshake_begin")
        do {
            let cipher = try ReachCipher(role: role.rawValue, name: name, identity: store.identity())
            self.cipher = cipher
            state = "Verifying device…"
            try enqueue(encoder.encode(ReachEnvelope(commitment: cipher.commitment)), video: false)
            armTimeout(seconds: 10)
        } catch { fail("Unable to load secure device identity: \(error.localizedDescription)") }
    }
    private func consume(_ bytes: Data) throws {
        try framer.ingest(bytes)
        while let frame = try framer.nextFrame(maximumFrameSize: connected ? ReachFramer.maximumSize : 16_384) {
            if !connected {
                preauthenticationBytes += frame.count + 4
                guard preauthenticationBytes <= 65_536 else { throw ReachSecurityError.invalidFrame }
            }
            let envelope = try decoder.decode(ReachEnvelope.self, from: frame)
            guard let cipher else { throw ReachSecurityError.invalidHandshake }
            if let commitment = envelope.commitment {
                guard envelope.hello == nil, envelope.record == nil else { throw ReachSecurityError.invalidHandshake }
                try cipher.acceptCommitment(commitment)
                diagnose("commitment_accepted")
                try enqueue(encoder.encode(ReachEnvelope(hello: cipher.hello)), video: false)
            } else if let hello = envelope.hello {
                guard envelope.record == nil else { throw ReachSecurityError.invalidHandshake }
                try cipher.accept(hello)
                guard expectedIdentity == nil || expectedIdentity == hello.identity else { throw ReachSecurityError.invalidIdentity }
                onIdentityVerified?()
                armTimeout() // Allow time for human comparison only after a valid signed hello.
                diagnose("hello_accepted", detail: "trusted=\(store.isTrusted(hello.identity))")
                remoteName = hello.name
                pairingCode = cipher.code
                if store.isTrusted(hello.identity) { approvePairing() }
                else { requiresApproval = true; state = "Compare this code on both devices" }
            } else if let record = envelope.record {
                let payload = try decoder.decode(ReachSecurePayload.self, from: cipher.open(record))
                if payload.approved == true {
                    guard payload.message == nil else { throw ReachSecurityError.invalidHandshake }
                    guard !remotelyApproved else { throw ReachSecurityError.invalidHandshake }
                    supportsConnectionProfile = payload.supportsConnectionProfile == true
                    remotelyApproved = true; diagnose("remote_approval_received"); try finishPairing()
                } else if let message = payload.message {
                    guard connected, payload.approved == nil else { throw ReachSecurityError.unauthenticated }
                    guard message.isValid(from: role == .host ? "client" : "host") else { throw ReachSecurityError.invalidFrame }
                    if case .video = message {
                        receivedVideoFrames += 1
                        if receivedVideoFrames == 1 { diagnose("first_video_received") }
                    }
                    switch message {
                    case .ping(let time): send(.pong(time))
                    default: onMessage?(message)
                    }
                } else { throw ReachSecurityError.invalidHandshake }
            } else { throw ReachSecurityError.invalidHandshake }
            lastReceived = Date() // Only a fully validated record keeps the session alive.
        }
    }
    public func approvePairing() {
        guard let cipher, cipher.remoteIdentity != nil, !locallyApproved else { return }
        do {
            locallyApproved = true; requiresApproval = false
            diagnose("local_approval")
            try sendSecure(ReachSecurePayload(approved: true, supportsConnectionProfile: true), video: false)
            state = "Waiting for confirmation…"
            try finishPairing()
        } catch { diagnose("pairing_failed", detail: ReachDiagnostics.errorCode(error)); fail("Pairing failed") }
    }
    private func finishPairing() throws {
        guard locallyApproved && remotelyApproved, !connected, let key = cipher?.remoteIdentity else { return }
        try store.trust(key)
        diagnose("trust_persisted")
        connected = true; pairingCode = nil; timeout?.cancel(); state = "Connected · end-to-end encrypted"
        lastReceived = Date()
        let session = epoch
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self, self.epoch == session else { return }
                if Date().timeIntervalSince(self.lastReceived) > 15 { self.fail("Connection lost. Reconnect when your Mac is available."); return }
                self.send(.ping(Date().timeIntervalSince1970))
            }
        }
        diagnose("authenticated")
        onAuthenticated?()
    }
    public func rejectPairing() {
        guard requiresApproval else { diagnose("stale_pairing_dismissal_ignored"); return }
        diagnose("pairing_rejected"); disconnect()
    }
    public func forgetTrustedDevices() { store.revokeAll(); disconnect() }
    public func send(_ message: ReachMessage) {
        guard connected else { return }
        guard message.isValid(from: role.rawValue) else { diagnose("invalid_outgoing_message_ignored"); return }
        do {
            let video: Bool
            if case .video = message { video = true } else { video = false }
            // A skipped inter-frame requires an encoder keyframe; notify rather than retaining stale video.
            if video && (sending || !queue.isEmpty) { onVideoDropped?(); return }
            try sendSecure(ReachSecurePayload(message: message), video: video)
            if video { sentVideoFrames += 1; if sentVideoFrames == 1 { diagnose("first_video_sent") } }
        } catch { diagnose("secure_send_failed", detail: ReachDiagnostics.errorCode(error)); fail("Could not send secure message") }
    }
    #if REACH_TESTING
    /// Adversarial integration fixture: bypass local validation, preserving real record encryption/framing.
    func sendPayloadForTesting(_ payload: ReachSecurePayload) throws {
        try sendSecure(payload, video: false)
    }
    #endif
    private func sendSecure(_ payload: ReachSecurePayload, video: Bool) throws {
        guard let cipher else { throw ReachSecurityError.unauthenticated }
        let record = try cipher.seal(encoder.encode(payload))
        try enqueue(encoder.encode(ReachEnvelope(record: record)), video: video)
    }
    private func enqueue(_ data: Data, video: Bool) throws {
        let frame = try ReachFramer.frame(data)
        guard queuedBytes + frame.count <= ReachFramer.maximumSize else { throw ReachSecurityError.invalidFrame }
        queue.append((frame, video)); queuedBytes += frame.count; flush()
    }
    private func flush() {
        guard !sending, !queue.isEmpty else { return }
        sending = true
        let (data, _) = queue.removeFirst(); queuedBytes -= data.count
        let session = epoch
        let completed: @Sendable (Error?) -> Void = { [weak self] error in
            Task { @MainActor in
                guard let self, self.epoch == session else { return }
                self.sending = false
                if let error { self.fail(error.localizedDescription) } else { self.flush() }
            }
        }
        if let connection { connection.send(content: data, completion: .contentProcessed { completed($0) }) }
        else if let socket = webSocket {
            Task { do { try await socket.send(.data(data)); completed(nil) } catch { completed(error) } }
        } else { completed(ReachSecurityError.unauthenticated) }
    }
    private func armTimeout(seconds: UInt64 = 60) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.fail("Connection timed out. Try again.")
        }
    }
    private func resetSession() {
        epoch = UUID(); timeout?.cancel(); keepAlive?.cancel(); cipher = nil; framer = ReachFramer()
        supportsConnectionProfile = false
        locallyApproved = false; remotelyApproved = false; connected = false; requiresApproval = false; pairingCode = nil
        queue.removeAll(); queuedBytes = 0; sending = false; sentVideoFrames = 0; receivedVideoFrames = 0; preauthenticationBytes = 0
    }
    public func disconnect(file: StaticString = #fileID, line: UInt = #line) {
        diagnose("disconnect_requested", detail: "caller=\(file):\(line) sentVideo=\(sentVideoFrames) receivedVideo=\(receivedVideoFrames)")
        let wasActive = connected
        resetSession(); expectedIdentity = nil
        let old = connection; connection = nil; old?.cancel()
        let socket = webSocket; webSocket = nil; socket?.cancel(with: .normalClosure, reason: nil)
        state = role == .host && listener != nil ? "Ready for your devices" : "Not connected"
        if wasActive { onDisconnected?() }
    }
    private func fail(_ reason: String) {
        let category: String
        switch reason {
        case "Your Mac disconnected": category = "remote_closed"
        case "Secure connection rejected": category = "security_rejected"
        case "Pairing failed": category = "pairing_failed"
        case "Could not send secure message": category = "send_failed"
        case "Connection timed out. Try again.": category = "timeout"
        case "Connection lost. Reconnect when your Mac is available.": category = "heartbeat_expired"
        default: category = "network_or_identity_error"
        }
        diagnose("connection_failed", detail: "reason=\(category)"); disconnect(); state = reason; onConnectionFailure?(reason) }
}
