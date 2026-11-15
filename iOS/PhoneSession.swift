import SwiftUI
import Combine
import UIKit

@MainActor
final class PhoneSession: ObservableObject {
    let peer = ReachPeer(role: .client, name: UIDevice.current.name)
    let decoder = DesktopDecoder()
    @Published var desktopSize = CGSize(width: 1920, height: 1080)
    @Published var displays: [RemoteDisplay] = []
    @Published var selectedDisplay: UInt32?
    @Published private(set) var displayPreviews: [UInt32: UIImage] = [:]
    var orderedDisplays: [RemoteDisplay] { DisplayNavigation.ordered(displays: displays) }
    var acceptsFrames: Bool { peer.connected && pendingDisplay == nil && !isSwitchingDisplay }
    private var queuedDisplay: RemoteDisplay?
    func storePreview(_ image: UIImage, for display: UInt32) {
        guard active, displays.contains(where: { $0.id == display }) else { return }
        displayPreviews[display] = image
    }
    @Published private(set) var displaySwitchRevision = 0
    @Published private(set) var isSwitchingDisplay = false
    private var pendingDisplay: UInt32?
    private var displaySwitchTimeout: Task<Void, Never>?
    @Published var active = false
    @Published var receivedFrame = false
    @Published var hostName = "Your Mac"
    @Published var message: String?
    @Published var latency: Int?
    @Published var clipboardEnabled = false
    @Published private(set) var scrollTarget: ScrollTargetState = .unknown
    @Published private(set) var remoteFocus: RemoteFocus?
    @Published private(set) var focusRevision = 0
    @Published private(set) var keyboardPresented = false
    private(set) var lastInteractionPoint: CGPoint?
    private var subscriptions: Set<AnyCancellable> = []
    @Published private(set) var savedMacs = SavedMacStore().load()
    private let destinations = SavedMacStore()
    private let connector = ReachAutoConnector()
    private var selectedMac: SavedMac?
    var otherNearbyHosts: [DiscoveredHost] {
        peer.discoveredHosts.filter { host in !savedMacs.contains { $0.id == host.identityID } }
    }
    private var lastHost: DiscoveredHost?
    private var lastRelay: (URL, String)?
    private let retry = SessionRetry()
    private var retryCount = 0
    private var hasAuthenticated = false
    private var foreground = true
    private var initiatingConnection = false
    private var lastKeyframeRequest = -Double.infinity
    private var deliveryIntervalStart = ProcessInfo.processInfo.systemUptime
    private var previousDelivery: Double?
    private var deliveredFrames = 0
    private var maximumDeliveryGap = 0.0
    init() {
        peer.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        peer.$connected.removeDuplicates().dropFirst().sink { [weak self] connected in
            guard let self else { return }
            if connected { self.retryCount = 0 }
            else if self.active && self.hasAuthenticated {
                self.receivedFrame = false; self.decoder.reset()
                self.scrollTarget = .unknown; self.remoteFocus = nil; self.latency = nil
                self.reconnect()
            }
        }.store(in: &subscriptions)
        peer.onIdentityVerified = { [weak self] in self?.connector.identityVerified() }
        peer.onAuthenticated = { [weak self] in
            self?.rememberAuthenticatedMac()
            self?.displaySwitchTimeout?.cancel()
            self?.hasAuthenticated = true
            self?.pendingDisplay = nil
            self?.isSwitchingDisplay = false
            self?.peer.send(.requestKeyframe)
            if let self, self.keyboardPresented { self.peer.send(.focusTracking(true)) }
        }
        peer.onConnectionFailure = { [weak self] _ in
            guard let self, self.active, self.foreground, !self.initiatingConnection else { return }
            if !self.connector.failed(), self.selectedMac != nil || self.hasAuthenticated { self.reconnect() }
        }
        peer.onMessage = { [weak self] message in self?.receive(message) }
        decoder.onError = { [weak self] error in
            guard let self else { return }
            self.message = error
            // A burst of bad/dropped frames should not turn into a keyframe request storm.
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastKeyframeRequest >= 0.5 {
                self.lastKeyframeRequest = now
                self.peer.send(.requestKeyframe)
            }
        }
        peer.browse()
    }
    private func prepareConnection(name: String) {
        retry.cancel(); connector.cancel(); hasAuthenticated = false; retryCount = 0
        peer.disconnect()
        decoder.reset(); lastKeyframeRequest = -Double.infinity
        scrollTarget = .unknown; lastInteractionPoint = nil; remoteFocus = nil; latency = nil
        displayPreviews = [:]; queuedDisplay = nil; displays = []; selectedDisplay = nil
        displaySwitchTimeout?.cancel(); pendingDisplay = nil; isSwitchingDisplay = false
        active = true; hostName = name; message = nil; receivedFrame = false
        UIApplication.shared.isIdleTimerDisabled = true
    }
    func connect(_ mac: SavedMac) {
        prepareConnection(name: mac.name)
        selectedMac = mac; lastHost = nil; lastRelay = nil
        connectRememberedDestination()
    }
    func connect(_ host: DiscoveredHost) {
        if let mac = savedMacs.first(where: { $0.id == host.identityID }) { connect(mac); return }
        prepareConnection(name: host.name)
        selectedMac = nil; lastRelay = nil; lastHost = host
        connectRememberedDestination()
    }
    func connectRelay(url: URL, room: String) {
        prepareConnection(name: "Your Mac")
        selectedMac = nil; lastHost = nil; lastRelay = (url, room)
        connectRememberedDestination()
    }
    private func rememberAuthenticatedMac() {
        connector.identityVerified()
        guard peer.connected, let identity = peer.remoteIdentity else { return }
        let prior = savedMacs.first { $0.identity == identity }
        let relay = connector.route == .relay ? lastRelay.flatMap { try? ReachRelayConfiguration(url: $0.0, room: $0.1) } : prior?.relay
        let mac = SavedMac(identity: identity, name: peer.remoteName, relay: relay)
        persist(mac)
    }
    private func persist(_ mac: SavedMac) {
        do {
            try destinations.save(mac); savedMacs = destinations.load(); selectedMac = mac; hostName = mac.name
        } catch { message = "Couldn’t save this Mac securely. Try connecting again." }
    }
    func forgetMacs() {
        disconnect(); peer.forgetTrustedDevices(); ReachRelayConfiguration.clear()
        destinations.clear(); savedMacs = []
    }
    func disconnect() {
        displayPreviews = [:]; queuedDisplay = nil
        displaySwitchTimeout?.cancel(); pendingDisplay = nil; isSwitchingDisplay = false
        setKeyboardPresented(false)
        scrollTarget = .unknown
        remoteFocus = nil; lastInteractionPoint = nil
        active = false; retry.cancel(); connector.cancel(); selectedMac = nil; lastHost = nil; lastRelay = nil
        peer.disconnect(); decoder.reset(); receivedFrame = false; latency = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }
    func retryConnection() {
        guard active else { return }
        retry.cancel(); retryCount = 0
        displaySwitchTimeout?.cancel(); pendingDisplay = nil; queuedDisplay = nil; isSwitchingDisplay = false
        receivedFrame = false; message = nil; decoder.reset()
        connectRememberedDestination()
    }
    /// Established sessions stop sending video/input while the app is backgrounded.
    /// Keep the destination/trust so foregrounding can reconnect without another device selection.
    func setForeground(_ foreground: Bool) {
        self.foreground = foreground
        guard active else { return }
        if !foreground {
            retry.cancel(); connector.cancel()
            peer.disconnect(); decoder.reset(); receivedFrame = false
            UIApplication.shared.isIdleTimerDisabled = false
        } else {
            UIApplication.shared.isIdleTimerDisabled = true
            if peer.connected { peer.send(.requestKeyframe) }
            else { retryConnection() }
        }
    }
    private func reconnect() {
        guard foreground, !initiatingConnection, !retry.pending, selectedMac != nil || lastHost != nil || lastRelay != nil else { return }
        retryCount += 1
        let delay = SessionRecovery.delay(attempt: retryCount)
        retry.schedule(after: delay) { [weak self] in
            guard let self, self.active, self.foreground else { return }
            self.connectRememberedDestination()
        }
    }
    private func connectRememberedDestination() {
        guard active, foreground else { return }
        retry.cancel()
        let mac = selectedMac
        let nearby = mac.flatMap { saved in peer.discoveredHosts.first { $0.identityID == saved.id } } ?? (mac == nil ? lastHost : nil)
        let relay = mac?.relay ?? (mac == nil ? lastRelay.flatMap { try? ReachRelayConfiguration(url: $0.0, room: $0.1) } : nil)
        let localAction: (() -> Void)? = nearby.map { host in
            { [weak self] in
                guard let self else { return }
                self.initiatingConnection = true
                defer { self.initiatingConnection = false }
                ReachDiagnostics.record(component: "client", event: "automatic_route", metadata: "route=local")
                self.peer.connect(to: host, expectedIdentity: mac?.identity)
            }
        }
        let relayAction: (() -> Void)? = relay.map { configuration in
            { [weak self] in
                guard let self else { return }
                self.retry.cancel(); self.initiatingConnection = true
                defer { self.initiatingConnection = false }
                self.lastRelay = (configuration.url, configuration.room)
                ReachDiagnostics.record(component: "client", event: "automatic_route", metadata: "route=relay")
                self.peer.connectRelay(url: configuration.url, room: configuration.room, expectedIdentity: mac?.identity)
            }
        }
        connector.start(local: localAction, relay: relayAction)
        if localAction == nil && relayAction == nil {
            message = "Your Mac isn’t nearby. Connect once on the same Wi-Fi with remote access enabled on your Mac."
            reconnect()
        }
    }
    func didPresentFrame() {
        guard pendingDisplay == nil, !isSwitchingDisplay else { return }
        if !receivedFrame {
            receivedFrame = true
            deliveryIntervalStart = ProcessInfo.processInfo.systemUptime
            deliveredFrames = 0; previousDelivery = nil; maximumDeliveryGap = 0
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let previousDelivery { maximumDeliveryGap = max(maximumDeliveryGap, now - previousDelivery) }
        previousDelivery = now; deliveredFrames += 1
        let elapsed = now - deliveryIntervalStart
        if elapsed >= 5 {
            // These are decoded buffers enqueued to the display layer, not measured visible refreshes.
            ReachDiagnostics.record(component: "client", event: "decoded_frame_delivery",
                metadata: "frames=\(deliveredFrames) intervalMs=\(Int(elapsed * 1000)) maxGapMs=\(Int(maximumDeliveryGap * 1000)) rttMs=\(latency ?? -1)")
            deliveryIntervalStart = now; deliveredFrames = 0; maximumDeliveryGap = 0
        }
    }
    func setKeyboardPresented(_ presented: Bool) {
        guard keyboardPresented != presented else { return }
        keyboardPresented = presented
        peer.send(.focusTracking(presented))
        if !presented { remoteFocus = nil }
        focusRevision += 1
    }
    func send(_ input: RemoteInput) {
        guard peer.connected, receivedFrame, !isSwitchingDisplay else { return }
        if ["click", "down", "rightClick"].contains(input.kind) {
            scrollTarget = .unknown
            lastInteractionPoint = CGPoint(x: input.x, y: input.y)
            remoteFocus = nil
            focusRevision += 1
        }
        peer.send(.input(input))
    }
    func key(_ code: UInt16, modifiers: UInt64 = 0) {
        send(RemoteInput(kind: "keyDown", keyCode: code, modifiers: modifiers))
        send(RemoteInput(kind: "keyUp", keyCode: code, modifiers: modifiers))
    }
    func text(_ string: String) { send(RemoteInput(kind: "text", text: string)) }
    func neighbor(toward direction: DisplayDirection) -> RemoteDisplay? {
        guard !isSwitchingDisplay, let selectedDisplay else { return nil }
        return DisplayNavigation.neighbor(from: selectedDisplay, toward: direction, displays: displays)
    }
    func select(_ display: RemoteDisplay) {
        guard peer.connected else { return }
        if isSwitchingDisplay { queuedDisplay = display; return }
        guard display.id != selectedDisplay || !receivedFrame else { return }
        queuedDisplay = nil
        scrollTarget = .unknown
        remoteFocus = nil; lastInteractionPoint = nil; focusRevision += 1
        pendingDisplay = display.id; selectedDisplay = display.id; isSwitchingDisplay = true
        receivedFrame = false; displaySwitchRevision += 1
        decoder.reset(); peer.send(.selectDisplay(display.id))
        displaySwitchTimeout?.cancel()
        displaySwitchTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.isSwitchingDisplay else { return }
            self.pendingDisplay = nil; self.isSwitchingDisplay = false
            self.message = "This display did not respond. Choose a display to try again."
            if let queued = self.queuedDisplay { self.queuedDisplay = nil; self.select(queued) }
        }
    }
    func sendClipboard() {
        if let text = UIPasteboard.general.string { peer.send(.clipboard(String(text.prefix(1_000_000)))) }
    }
    private func receive(_ message: ReachMessage) {
        switch message {
        case .video(let video):
            guard pendingDisplay == nil else { return }
            displaySwitchTimeout?.cancel()
            isSwitchingDisplay = false
            let size = CGSize(width: video.width, height: video.height)
            if desktopSize != size { desktopSize = size }
            if let queued = queuedDisplay, queued.id != selectedDisplay {
                queuedDisplay = nil; select(queued); return
            }
            queuedDisplay = nil
            decoder.decode(video)
        case .displays(let displays):
            self.displays = displays
            if let current = displays.first(where: { $0.isCurrent == true }) {
                if pendingDisplay == nil || pendingDisplay == current.id {
                    selectedDisplay = current.id; pendingDisplay = nil
                }
            } else if let pendingDisplay, displays.contains(where: { $0.id == pendingDisplay }) {
                self.pendingDisplay = nil
            } else if selectedDisplay == nil { selectedDisplay = displays.first?.id }
        case .connectionProfile(let relay):
            guard peer.connected, let identity = peer.remoteIdentity else { return }
            persist(SavedMac(identity: identity, name: peer.remoteName, relay: relay))
        case .clipboard(let text): if clipboardEnabled { UIPasteboard.general.string = text }
        case .pong(let sent):
            let milliseconds = max(0, Date().timeIntervalSince1970 - sent) * 1000
            if milliseconds.isFinite && milliseconds <= 60_000 { latency = Int(milliseconds) }
        case .ping(let time): peer.send(.pong(time))
        case .status(let status): self.message = status
        case .scrollTarget(let state): scrollTarget = state
        case .focus(let focus):
            guard keyboardPresented, focus.isValid else { return }
            remoteFocus = focus
            focusRevision += 1
        default: break
        }
    }
}
