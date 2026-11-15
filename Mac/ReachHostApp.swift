import SwiftUI
import AppKit
// Older SDKs omit Sendable annotations on shareable-content results. Host access stays MainActor-owned.
@preconcurrency import ScreenCaptureKit
import Combine
@preconcurrency import ApplicationServices

@main
struct ReachHostApp: App {
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var delegate
    @StateObject private var host = HostModel.shared
    var body: some Scene {
        MenuBarExtra("Reach", systemImage: "rectangle.portrait.and.arrow.right") {
            ScrollView { HostPanel(host: host) }.scrollIndicators(.visible)
                .frame(width: 340, height: min(700, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
        }.menuBarExtraStyle(.window)
        Window("Reach", id: "reach-host") {
            ScrollView { HostPanel(host: host) }.scrollIndicators(.visible)
                .frame(width: 380, height: min(700, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
        }.windowResizability(.contentSize)
    }
}

@MainActor
final class HostAppDelegate: NSObject, NSApplicationDelegate {
    private var onboarding: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--scroll-target-smoke") {
            Task { await runScrollTargetSmoke() }
            return
        }
        if CommandLine.arguments.contains("--capture-smoke") {
            Task { await runCaptureSmoke() }
            return
        }
        if CommandLine.arguments.contains("--capture-quality-smoke") {
            Task { await runCaptureSmoke(exerciseQuality: true) }
            return
        }
        #endif
        guard !CGPreflightScreenCaptureAccess() || !AXIsProcessTrusted() || !UserDefaults.standard.bool(forKey: "hostWelcomed") else { return }
        UserDefaults.standard.set(true, forKey: "hostWelcomed")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Welcome to Reach"
        let height = min(680, (NSScreen.main?.visibleFrame.height ?? 800) - 100)
        window.contentView = NSHostingView(rootView: ScrollView {
            HostPanel(host: HostModel.shared).frame(width: 400)
        }.scrollIndicators(.visible).frame(width: 400, height: height))
        window.setContentSize(NSSize(width: 400, height: height))
        window.isReleasedWhenClosed = false
        window.center()
        onboarding = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    #if DEBUG
    private func runScrollTargetSmoke() async {
        // A self-owned, synthetic fixture: no remote input is posted and no user content is read.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Reach scroll detection test"
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 440))
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 110, width: 480, height: 310))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy
        scroll.borderType = .bezelBorder
        let document = NSTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 2000))
        document.isEditable = false
        document.isSelectable = true
        document.isVerticallyResizable = false
        document.string = String(repeating: "Reach synthetic scrolling fixture.\n", count: 100)
        scroll.documentView = document
        let button = NSButton(title: "Ordinary button", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 25, width: 180, height: 38)
        button.bezelStyle = .rounded
        root.addSubview(scroll)
        root.addSubview(button)
        window.contentView = root
        window.center()
        onboarding = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        root.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 300_000_000)

        let tracker = DesktopScrollTarget()
        func normalizedLocation(in view: NSView) -> (Double, Double, CGRect) {
            let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            let cocoaPoint = window.convertPoint(toScreen: view.convert(center, to: nil))
            // Cocoa is bottom-left; AX and CG are top-left relative to the primary display.
            let global = CGPoint(x: cocoaPoint.x, y: CGDisplayBounds(CGMainDisplayID()).height - cocoaPoint.y)
            var displayID = CGMainDisplayID()
            var count: UInt32 = 0
            CGGetDisplaysWithPoint(global, 1, &displayID, &count)
            let display = CGDisplayBounds(displayID)
            return ((global.x - display.minX) / display.width, (global.y - display.minY) / display.height, display)
        }
        var current = ScrollTargetState.unknown
        var elapsed: Double?
        var started = ProcessInfo.processInfo.systemUptime
        tracker.onState = { state in
            current = state
            if state != .unknown { elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000 }
        }
        let (scrollX, scrollY, scrollDisplay) = normalizedLocation(in: scroll.contentView)
        tracker.clicked(x: scrollX, y: scrollY, display: scrollDisplay)
        try? await Task.sleep(nanoseconds: 350_000_000)
        let scrollResult = current
        let scrollElapsed = elapsed ?? (ProcessInfo.processInfo.systemUptime - started) * 1000
        current = .unknown
        elapsed = nil
        started = ProcessInfo.processInfo.systemUptime
        let (buttonX, buttonY, buttonDisplay) = normalizedLocation(in: button)
        tracker.clicked(x: buttonX, y: buttonY, display: buttonDisplay)
        try? await Task.sleep(nanoseconds: 350_000_000)
        let buttonResult = current
        let buttonElapsed = elapsed ?? (ProcessInfo.processInfo.systemUptime - started) * 1000
        tracker.cancel()
        let status: String
        if scrollResult == .scrollable && buttonResult == .notScrollable { status = "pass" }
        else if scrollResult == .unknown || buttonResult == .unknown { status = "inconclusive" }
        else { status = "fail" }
        let result: [String: Any] = [
            "status": status,
            "accessibilityPermission": AXIsProcessTrusted(),
            "screenPermission": CGPreflightScreenCaptureAccess(),
            "scrollAreaState": scrollResult.rawValue,
            "buttonState": buttonResult.rawValue,
            "scrollAreaElapsedMilliseconds": Int(scrollElapsed),
            "buttonElapsedMilliseconds": Int(buttonElapsed)
        ]
        if let json = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: URL(fileURLWithPath: "/tmp/reach-scroll-target-smoke.json"), options: .atomic)
        }
        NSApplication.shared.terminate(nil)
    }

    private func runCaptureSmoke(exerciseQuality: Bool = false) async {
        let capture = DesktopCapture()
        let stats = CaptureSmokeStats()
        var result: [String: Any] = ["screenPermission": CGPreflightScreenCaptureAccess(), "accessibilityPermission": AXIsProcessTrusted()]
        capture.onFrame = { frame in stats.record(frame) }
        capture.onError = { error in stats.recordError(error) }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw NSError(domain: "Reach", code: 1, userInfo: [NSLocalizedDescriptionKey: "No displays available"])
            }
            try await capture.start(display: display)
            if exerciseQuality {
                try await Task.sleep(for: .milliseconds(500))
                let beforeRestart = stats.snapshot()["frames"] as? Int ?? 0
                let update = Task { @MainActor in
                    await capture.setQuality(bitrate: 1_000_000, fps: 20)
                }
                await Task.yield()
                await capture.stop()
                try await capture.start(display: display)
                await update.value
                await capture.setQuality(bitrate: 3_000_000, fps: 30)
                try await Task.sleep(for: .milliseconds(750))
                await capture.setQuality(bitrate: 6_000_000, fps: 60)
                try await Task.sleep(for: .milliseconds(750))
                result["qualityUpdateRestartExercised"] = true
                result["framesAfterRestart"] = (stats.snapshot()["frames"] as? Int ?? 0) - beforeRestart
            } else {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            await capture.stop()
            result.merge(stats.snapshot()) { _, new in new }
        } catch { result["error"] = error.localizedDescription }
        if let json = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            let path = exerciseQuality ? "/tmp/reach-capture-quality-smoke.json" : "/tmp/reach-capture-smoke.json"
            try? json.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        NSApplication.shared.terminate(nil)
    }
    #endif
}

#if DEBUG
private final class CaptureSmokeStats: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var width = 0
    private var height = 0
    private var bytes = 0
    private var keyframes = 0
    private var error = ""
    func record(_ frame: EncodedDesktopFrame) {
        lock.lock(); defer { lock.unlock() }
        count += 1; width = frame.width; height = frame.height; bytes += frame.bytes.count
        if frame.keyframe { keyframes += 1 }
    }
    func recordError(_ value: String) { lock.lock(); error = value; lock.unlock() }
    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["frames": count, "width": width, "height": height, "encodedBytes": bytes, "keyframes": keyframes, "error": error]
    }
}
#endif

@MainActor
final class HostModel: ObservableObject {
    static let shared = HostModel()
    let peer = ReachPeer(role: .host, name: Host.current().localizedName ?? "My Mac")
    @Published var screenAllowed = CGPreflightScreenCaptureAccess()
    @Published var inputAllowed = AXIsProcessTrusted()
    @Published var status = "Ready when you are"
    @Published var displays: [SCDisplay] = []
    @Published var selectedDisplay: UInt32 = CGMainDisplayID()
    @Published var clipboardEnabled = false
    @Published var streaming = false
    @Published var videoDiagnostics = ""
    @Published var enabled = true
    @Published var relayURL = UserDefaults.standard.string(forKey: "relayURL") ?? ""
    @Published var relayRoom = ""
    private let capture = DesktopCapture()
    private let input = DesktopInput()
    private let focusTracker = DesktopFocusTracker()
    private let scrollTarget = DesktopScrollTarget()
    private var permissionTimer: Timer?
    private var clipboardTimer: Timer?
    private var clipboardChange = NSPasteboard.general.changeCount
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var captureGeneration = 0
    private var switchingDisplay = false
    private var restartPending = false
    private var targetWidth = 1920
    private var targetFPS = 60
    private var targetBitrate = 6_000_000
    private var qualityRestart: Task<Void, Never>?
    private var qualityUpdate: Task<Void, Never>?
    private var selectionRestart: Task<Void, Never>?
    private var focusPoll: Task<Void, Never>?
    private var lastRemoteKeyframe = -Double.infinity
    private var observedFrames = 0
    private var droppedFrames = 0
    private var healthyIntervals = 0
    private var totalFrames = 0
    private var relayRestore: Task<Void, Never>?
    private var sleeping = false

    init() {
        peer.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        peer.onAuthenticated = { [weak self] in
            guard let self, self.enabled else { return }
            self.scrollTarget.reset()
            if self.peer.supportsConnectionProfile { self.peer.send(.connectionProfile(ReachRelayConfiguration.load())) }
            Task { await self.beginStreaming() }
        }
        peer.onMessage = { [weak self] message in self?.receive(message) }
        scrollTarget.onState = { [weak self] state in
            guard let self, self.peer.connected else { return }
            self.peer.send(.scrollTarget(state))
            ReachDiagnostics.record(component: "host", event: "scroll_target_classified", metadata: "state=\(state.rawValue)")
        }
        focusTracker.onGeometryAvailable = { caret in
            ReachDiagnostics.record(component: "host", event: "focus_geometry_available", metadata: "caret=\(caret)")
        }
        focusTracker.onFocus = { [weak self] focus in
            guard let self, self.peer.connected else { return }
            self.peer.send(.focus(focus))
        }
        peer.onDisconnected = { [weak self] in self?.scheduleRelayRestore() }
        peer.onConnectionFailure = { [weak self] _ in self?.scheduleRelayRestore() }
        peer.onVideoDropped = { [weak self] in
            self?.capture.requestKeyframe()
            self?.droppedFrames += 1
        }
        peer.$connected.dropFirst().sink { [weak self] connected in
            guard let self else { return }
            if !connected {
                self.input.releaseAll()
                self.focusPoll?.cancel(); self.qualityUpdate?.cancel(); self.qualityUpdate = nil
                self.qualityRestart?.cancel()
                self.focusTracker.setEnabled(false)
                self.scrollTarget.cancel()
                self.captureGeneration += 1
                self.streaming = false
                Task { await self.capture.stop() }
                self.status = "Ready when you are"
            }
        }.store(in: &cancellables)
        let deliverySlot = DispatchSemaphore(value: 1)
        let requestKeyframe = capture.keyframeRequester
        capture.onFrame = { [weak self] frame in
            guard deliverySlot.wait(timeout: .now()) == .success else {
                requestKeyframe()
                return
            }
            Task { @MainActor in
                defer { deliverySlot.signal() }
                guard let self, self.peer.connected, self.streaming, self.capture.isCurrent(frame) else { return }
                self.observedFrames += 1
                self.totalFrames += 1
                self.peer.send(.video(VideoPacket(data: frame.bytes, parameterSets: frame.parameterSets,
                    width: frame.width, height: frame.height, isKeyframe: frame.keyframe, timestamp: frame.timestamp, codec: "h264")))
            }
        }
        capture.onError = { [weak self] error in
            Task { @MainActor in self?.status = error; self?.streaming = false }
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions(); self?.adaptQuality() }
        }
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkClipboard() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = true
                self.peer.send(.status("Mac is going to sleep"))
                self.peer.disconnect()
                self.input.releaseAll()
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = false
                self.status = "Awake and ready"
                if self.enabled {
                    self.peer.startHosting()
                    if let config = ReachRelayConfiguration.load() { self.peer.connectRelay(url: config.url, room: config.room) }
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.loadDisplays()
                if self.peer.connected { await self.beginStreaming() }
            }
        })
        peer.startHosting()
        if let config = ReachRelayConfiguration.load() {
            relayURL = config.url.absoluteString
            relayRoom = config.room
            peer.connectRelay(url: config.url, room: config.room)
        }
        if screenAllowed { Task { await loadDisplays() } }
    }

    func requestScreen() {
        if !CGRequestScreenCaptureAccess() { openSettings("Privacy_ScreenCapture") }
        refreshPermissions()
        if screenAllowed { Task { await loadDisplays() } }
    }

    func requestInput() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        inputAllowed = AXIsProcessTrustedWithOptions(options)
        if !inputAllowed { openSettings("Privacy_Accessibility") }
    }

    private func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }

    private func refreshPermissions() {
        let previous = screenAllowed
        screenAllowed = CGPreflightScreenCaptureAccess()
        inputAllowed = AXIsProcessTrusted()
        if screenAllowed && !previous {
            Task { await loadDisplays(); if peer.connected { await beginStreaming() } }
        }
        if !screenAllowed && streaming {
            streaming = false
            Task { await capture.stop() }
            peer.send(.status("Screen Recording permission is required on the Mac"))
        }
    }

    func loadDisplays() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            displays = content.displays
            if !displays.contains(where: { $0.displayID == selectedDisplay }), let first = displays.first { selectedDisplay = first.displayID }
            sendDisplays()
        } catch { status = "Allow Screen Recording, then reopen Reach if macOS asks. \(error.localizedDescription)" }
    }

    private func sendDisplays() {
        peer.send(.displays(displays.map { display in
            let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }?.localizedName ?? "Display \(display.displayID)"
            let bounds = CGDisplayBounds(display.displayID)
            return RemoteDisplay(id: display.displayID, name: name, width: display.width, height: display.height,
                                 frame: DisplayFrame(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
                                 isCurrent: display.displayID == selectedDisplay)
        }))
    }

    func beginStreaming() async {
        guard enabled, peer.connected else { return }
        guard !switchingDisplay else { restartPending = true; return }
        switchingDisplay = true
        streaming = false
        input.releaseAll()
        defer {
            switchingDisplay = false
            if restartPending {
                restartPending = false
                Task { await beginStreaming() }
            }
        }
        guard screenAllowed else { status = "Screen Recording permission needed"; peer.send(.status(status)); return }
        captureGeneration += 1
        let generation = captureGeneration
        await loadDisplays()
        guard generation == captureGeneration, peer.connected,
              let display = displays.first(where: { $0.displayID == selectedDisplay }) else { return }
        input.displayFrame = CGDisplayBounds(display.displayID)
        focusTracker.setDisplay(input.displayFrame)
        do {
            try await capture.start(display: display, widthLimit: targetWidth, framesPerSecond: targetFPS)
            await capture.setQuality(bitrate: targetBitrate, fps: targetFPS)
            guard generation == captureGeneration, peer.connected else { await capture.stop(); return }
            streaming = true
            capture.requestKeyframe()
            status = inputAllowed ? "Connected · end-to-end encrypted" : "Viewing · allow Accessibility for control"
            peer.send(.status(status))
        } catch { streaming = false; status = error.localizedDescription; peer.send(.status(status)) }
    }

    private func receive(_ message: ReachMessage) {
        guard enabled, peer.connected else { return }
        switch message {
        case .input(let event):
            guard streaming, !switchingDisplay else { return }
            switch event.kind {
            case "move", "down", "up", "click", "rightClick": input.pointer(action: event.kind, x: event.x, y: event.y, button: event.button)
            case "scroll": input.scroll(dx: event.x, dy: event.y)
            case "text": input.text(event.text)
            case "keyDown": input.key(code: event.keyCode, modifiers: event.modifiers, down: true)
            case "keyUp": input.key(code: event.keyCode, modifiers: event.modifiers, down: false)
            default: break
            }
            if ["click", "rightClick", "up"].contains(event.kind) {
                scrollTarget.clicked(x: event.x, y: event.y, display: input.displayFrame)
            } else if event.kind == "move" {
                scrollTarget.pointerMoved(x: event.x, y: event.y, display: input.displayFrame)
            }
            if ["click", "up", "text", "keyUp"].contains(event.kind) {
                // The AX focus change follows event delivery; the repeating poll catches later layout.
                focusPoll?.cancel()
                focusPoll = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 70_000_000)
                    guard !Task.isCancelled, self.peer.connected else { return }
                    self.focusTracker.poll()
                }
            }
        case .focusTracking(let active): focusTracker.setEnabled(active)
        case .selectDisplay(let id):
            guard displays.contains(where: { $0.displayID == id }) else { return }
            streaming = false
            selectedDisplay = id
            scrollTarget.reset()
            if selectionRestart == nil {
                selectionRestart = Task {
                    await beginStreaming()
                    selectionRestart = nil
                }
            } else { restartPending = true }
        case .requestKeyframe:
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastRemoteKeyframe >= 0.5 {
                lastRemoteKeyframe = now
                capture.requestKeyframe()
            }
        case .quality(let quality):
            targetFPS = min(60, max(10, quality.fps))
            targetBitrate = min(16_000_000, max(500_000, quality.bitrate))
            let width = min(1920, max(640, quality.width)) / 2 * 2
            if qualityUpdate == nil {
                qualityUpdate = Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, peer.connected else { qualityUpdate = nil; return }
                    await capture.setQuality(bitrate: targetBitrate, fps: targetFPS)
                    qualityUpdate = nil
                }
            }
            if abs(width - targetWidth) > targetWidth / 5 {
                targetWidth = width
                qualityRestart?.cancel()
                qualityRestart = Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled else { return }
                    await beginStreaming()
                }
            }
        case .clipboard(let text):
            guard clipboardEnabled, text.utf8.count <= 1_000_000 else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            clipboardChange = NSPasteboard.general.changeCount
        case .ping(let time): peer.send(.pong(time))
        default: break
        }
    }

    private func checkClipboard() {
        guard clipboardEnabled, peer.connected else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != clipboardChange else { return }
        clipboardChange = pasteboard.changeCount
        if let string = pasteboard.string(forType: .string), string.utf8.count <= 1_000_000 { peer.send(.clipboard(string)) }
    }

    private func adaptQuality() {
        defer { observedFrames = 0; droppedFrames = 0 }
        videoDiagnostics = streaming ? "\(totalFrames) frames processed · \(targetFPS) fps target · \(String(format: "%.1f", Double(targetBitrate) / 1_000_000)) Mb/s" : ""
        guard streaming, observedFrames > 10 else { return }
        let oldBitrate = targetBitrate
        let oldFPS = targetFPS
        if Double(droppedFrames) / Double(observedFrames) > 0.08 {
            healthyIntervals = 0
            targetBitrate = max(700_000, targetBitrate * 3 / 4)
            targetFPS = targetBitrate < 1_500_000 ? 20 : 30
        } else if droppedFrames == 0 {
            healthyIntervals += 1
            if healthyIntervals >= 5 {
                targetBitrate = min(6_000_000, targetBitrate * 6 / 5)
                if targetBitrate >= 4_000_000 { targetFPS = 60 }
                healthyIntervals = 0
            }
        }
        if oldBitrate != targetBitrate || oldFPS != targetFPS {
            Task { await capture.setQuality(bitrate: targetBitrate, fps: targetFPS) }
        }
    }

    private func scheduleRelayRestore() {
        relayRestore?.cancel()
        guard enabled, !sleeping, ReachRelayConfiguration.load() != nil else { return }
        relayRestore = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, enabled, !sleeping, !peer.hasActiveTransport,
                  let config = ReachRelayConfiguration.load() else { return }
            peer.connectRelay(url: config.url, room: config.room)
        }
    }

    func connectRelay() {
        guard enabled else { return }
        guard let url = URL(string: relayURL), url.scheme == "wss" else { status = "Enter a secure wss:// relay URL"; return }
        do { try ReachRelayConfiguration(url: url, room: relayRoom).save() }
        catch { status = "Could not save relay settings: \(error.localizedDescription)"; return }
        UserDefaults.standard.set(relayURL, forKey: "relayURL")
        peer.connectRelay(url: url, room: relayRoom)
    }

    func removeRelay() {
        ReachRelayConfiguration.clear()
        relayRestore?.cancel()
        relayURL = ""
        relayRoom = ""
        UserDefaults.standard.removeObject(forKey: "relayURL")
        peer.disconnect()
        if enabled { peer.startHosting() }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if value {
            peer.startHosting()
            if let config = ReachRelayConfiguration.load() { peer.connectRelay(url: config.url, room: config.room) }
        } else {
            peer.stopHosting()
            input.releaseAll()
            captureGeneration += 1
            Task { await capture.stop() }
            streaming = false
        }
    }
}

struct HostPanel: View {
    @ObservedObject var host: HostModel
    @State private var showRemote = false
    @State private var confirmRevoke = false
    @State private var showConnectionHelp = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 30, weight: .light)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reach").font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text("Your Mac. Within reach.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(host.streaming ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(Host.current().localizedName ?? "My Mac").font(.headline)
                Text(host.enabled ? host.status : "Connections paused").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let code = host.peer.pairingCode, host.peer.requiresApproval {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Pair your device", systemImage: "lock.shield").font(.headline)
                    Text("Confirm this code matches Reach on your iPhone or iPad. Only approve a device you recognize.").font(.callout).foregroundStyle(.secondary)
                    Text(code).font(.system(size: 32, weight: .medium, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button("Decline") { host.peer.rejectPairing() }
                        Spacer()
                        Button("Trust this device") { host.peer.approvePairing() }.buttonStyle(.borderedProminent)
                    }
                }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
            }
            if !host.screenAllowed || !host.inputAllowed {
                VStack(alignment: .leading, spacing: 13) {
                    Text("A little permission. Full freedom.").font(.headline)
                    permission("Screen Recording", detail: "See your desktop securely on your iPhone or iPad.", allowed: host.screenAllowed, action: host.requestScreen)
                    permission("Accessibility", detail: "Control your mouse and keyboard remotely.", allowed: host.inputAllowed, action: host.requestInput)
                }
            }
            Divider()
            Toggle("Allow connections", isOn: Binding(get: { host.enabled }, set: { host.setEnabled($0) }))
            Toggle("Sync text clipboard", isOn: $host.clipboardEnabled)
                .help("When enabled, text copied on this Mac is sent to the connected trusted device.")
            VStack(alignment: .leading, spacing: 8) {
                Text("Select this Mac in Reach on your iPhone or iPad.").font(.callout)
                Text("Pair once on the same Wi-Fi. Your device remembers this Mac and chooses the connection automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                if ReachRelayConfiguration.load() != nil {
                    Button("Copy pairing invitation") {
                        guard let configuration = ReachRelayConfiguration.load() else { return }
                        var invitation = URLComponents()
                        invitation.scheme = "reach"; invitation.host = "relay"
                        invitation.queryItems = [URLQueryItem(name: "url", value: configuration.url.absoluteString), URLQueryItem(name: "room", value: configuration.room)]
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(invitation.string ?? "", forType: .string)
                    }.font(.caption)
                }
            }
            DisclosureGroup("Advanced connection setup", isExpanded: $showRemote) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Remote access is configured once here, then shared securely with paired devices. Use a registered private room from your relay administrator. Your iPhone or iPad chooses local or remote automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Secure relay address", text: $host.relayURL).textFieldStyle(.roundedBorder)
                    SecureField("Registered private room", text: $host.relayRoom).textFieldStyle(.roundedBorder)
                    Button("Save connection setup") { host.connectRelay() }.disabled(host.relayURL.isEmpty || host.relayRoom.isEmpty)
                    Button("Remove remote access setup") { host.removeRelay() }.font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text(host.peer.state).font(.caption).foregroundStyle(.secondary)
                    if !host.videoDiagnostics.isEmpty { Text(host.videoDiagnostics).font(.caption2).foregroundStyle(.secondary) }
                }.padding(.top, 10)
            }.font(.caption)
            Button("Connection help") { showConnectionHelp = true }.font(.caption)
                .popover(isPresented: $showConnectionHelp) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Pair once. Connect anywhere.").font(.headline)
                        Text("Allow Screen Recording and Accessibility, then open Reach on your iPhone or iPad on the same Wi-Fi. Select this Mac and compare the pairing codes.")
                        Text("After pairing, select the same saved Mac wherever you are. Reach chooses local access or your configured relay automatically. Keep this Mac awake with Reach running and Allow connections on.")
                        Text("For first pairing away from home, copy a pairing invitation here and paste it through Add a Mac on your device. Advanced connection setup is only needed to configure or change remote access on this Mac.")
                        Button("Done") { showConnectionHelp = false }
                    }.font(.callout).padding(20).frame(width: 330)
                }
            Button("Forget all trusted devices…") { confirmRevoke = true }.font(.caption).foregroundStyle(.secondary)
                .confirmationDialog("Forget all trusted devices?", isPresented: $confirmRevoke) {
                    Button("Forget devices", role: .destructive) { host.peer.forgetTrustedDevices() }
                } message: { Text("The current session will end. Each device must be paired again.") }
            HStack {
                if host.peer.connected { Button("Disconnect") { host.peer.disconnect() } }
                Spacer()
                Button("Quit Reach") { NSApplication.shared.terminate(nil) }.foregroundStyle(.secondary)
            }.font(.callout)
        }.padding(22)
    }
    private func permission(_ title: String, detail: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: allowed ? "checkmark.circle.fill" : "circle").foregroundStyle(allowed ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !allowed { Button("Allow", action: action).buttonStyle(.bordered) }
        }
    }
}
