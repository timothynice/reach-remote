import SwiftUI
import UIKit

struct RemoteDesktopView: View {
    @ObservedObject var model: PhoneSession
    @State private var controls = true
    @State private var keyboard = false
    @State private var bottomChromeHeight: CGFloat = 64
    @State private var precision = true
    @State private var scrolling = false
    @AppStorage("reach.alwaysShowScrollRail") private var alwaysShowScrollRail = false
    @State private var viewportReset = 0
    @State private var viewportMode: ViewportMode = .focus
    @State private var selectedPreset: ViewportMode? = .focus
    @State private var hideTask: Task<Void, Never>?
    @State private var showHelp = false
    @State private var showMenu = false
    @State private var displayBrowser = false
    @State private var delayedFailure = false
    @State private var loadingAttempt = 0
    @State private var availableHeight: CGFloat = 600
    @State private var voiceOver = UIAccessibility.isVoiceOverRunning

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            DesktopViewport(model: model, precision: precision, mode: viewportMode, resetID: viewportReset,
                            bottomOcclusion: bottomChromeHeight + 10, topOcclusion: controls ? 60 : 12,
                            browserActive: displayBrowser,
                            onOpenDisplayBrowser: openDisplays, onManualZoom: { selectedPreset = nil }, onInteraction: reveal)
                .ignoresSafeArea(edges: [.top, .leading, .trailing])
                .accessibilityIdentifier("remote-desktop")
                .accessibilityLabel("Remote desktop. Two fingers pan and pinch to zoom. Use the right-edge rail to scroll on your Mac. Three-finger tap opens displays.")
            if !model.receivedFrame && !displayBrowser {
                ReachConnectionLoading(title: loadingTitle, failed: delayedFailure,
                                       detail: delayedFailure ? failureDetail : nil,
                                       retry: { delayedFailure = false; loadingAttempt += 1; model.retryConnection() },
                                       disconnect: { model.disconnect() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
            }
            if (controls || scrolling) && model.receivedFrame && !displayBrowser && !showMenu && (scrolling || alwaysShowScrollRail || (model.lastInteractionPoint != nil && model.scrollTarget != .notScrollable)) {
                GeometryReader { geometry in
                    HStack {
                        Spacer(minLength: 0)
                        RemoteScrollRail(scroll: { delta in
                            model.send(RemoteInput(kind: "scroll", y: -delta))
                        }, active: { active in
                            scrolling = active
                            if active { hideTask?.cancel() } else { reveal() }
                        })
                        .frame(width: 64, height: min(300, max(140, geometry.size.height - bottomChromeHeight - 48)))
                        .padding(.trailing, 2)
                    }.frame(maxHeight: .infinity)
                }
            }
            if showMenu && !displayBrowser {
                Color.black.opacity(0.08).ignoresSafeArea()
                    .contentShape(Rectangle()).onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showMenu = false }; reveal() }
            }
            if !displayBrowser { sessionControls }
            if showMenu && !displayBrowser {
                VStack(alignment: .trailing, spacing: 9) {
                    sessionMenu
                    statusPill
                }
                .padding(.horizontal, 18).padding(.bottom, bottomChromeHeight + 14)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if displayBrowser {
                DisplayBrowserOverlay(model: model, dismiss: closeDisplays)
                    .transition(.opacity).zIndex(4)
            }
        }
        .overlay(alignment: .top) {
            if controls && model.receivedFrame && !displayBrowser {
                displayBrowserPill.padding(.top, 8).transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .background { GeometryReader { geometry in Color.clear.preference(key: SessionHeightKey.self, value: geometry.size.height) } }
        .onPreferenceChange(SessionHeightKey.self) { availableHeight = $0 }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
            voiceOver = UIAccessibility.isVoiceOverRunning
            reveal()
        }
        .onAppear { reveal() }
        .onDisappear { hideTask?.cancel(); model.setKeyboardPresented(false) }
        .onChange(of: keyboard) { _, shown in model.setKeyboardPresented(shown) }
        .onChange(of: model.displaySwitchRevision) { _, _ in selectedPreset = nil }
        .onPreferenceChange(BottomChromeHeightKey.self) { height in
            if abs(bottomChromeHeight - height) > 0.5 { bottomChromeHeight = height }
        }
        .task(id: loadingPhase) {
            delayedFailure = false
            guard !model.receivedFrame, model.peer.pairingCode == nil else { return }
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, !model.receivedFrame, model.peer.pairingCode == nil else { return }
            withAnimation(.easeInOut(duration: 0.2)) { delayedFailure = true }
        }
        .sheet(isPresented: $showHelp) { help }
    }

    private var displayBrowserPill: some View {
        Button(action: openDisplays) {
            ReachMonitorOutline().stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                .frame(width: 17, height: 17)
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 48, height: 28)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5) }
                .frame(width: 64, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Browse monitors")
        .accessibilityHint("Swipe between your Mac displays, then tap a display to enter it.")
        .accessibilityIdentifier("browse-monitors-pill")
    }

    private var sessionControls: some View {
        VStack(spacing: 8) {
            if controls {
                HStack(spacing: 0) {
                    preset("Focus", symbol: "viewfinder", mode: .focus)
                    preset("Fit width", symbol: "arrow.left.and.right", mode: .width)
                    preset("Fit height", symbol: "arrow.up.and.down", mode: .height)
                    tool("Hide controls", symbol: "chevron.down", selected: false) {
                        showMenu = false
                        withAnimation(.easeOut(duration: 0.2)) { controls = false }
                    }
                    tool("Precision cursor", symbol: "cursorarrow", selected: precision) { precision.toggle() }
                    tool("Keyboard", symbol: "keyboard", selected: keyboard) { keyboard.toggle() }
                    Button {
                        reveal()
                        keyboard = false
                        withAnimation(.easeOut(duration: 0.18)) { showMenu.toggle() }
                    } label: {
                        Image(systemName: "ellipsis").rotationEffect(.degrees(90))
                            .font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44)
                            .background(showMenu ? .white.opacity(0.16) : .clear, in: Capsule()).contentShape(Rectangle())
                    }.accessibilityLabel("Session options").accessibilityIdentifier("session-options")
                }
                .padding(6).background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, keyboard ? 0 : 10)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .background { GeometryReader { geometry in Color.clear.preference(key: BottomChromeHeightKey.self, value: geometry.size.height) } }
            } else {
                Button { reveal() } label: {
                    Image(systemName: "chevron.up").font(.caption.weight(.semibold))
                        .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Capsule()).contentShape(Rectangle())
                }
                .accessibilityLabel("Show controls").padding(.bottom, 8)
                .background { GeometryReader { geometry in Color.clear.preference(key: BottomChromeHeightKey.self, value: geometry.size.height) } }
            }
            if keyboard {
                RemoteKeyboard(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .background { GeometryReader { geometry in Color.clear.preference(key: BottomChromeHeightKey.self, value: geometry.size.height + 8) } }
            }
        }
        .foregroundStyle(.white).frame(maxWidth: .infinity)
    }

    private var sessionMenu: some View {
        ScrollView {
            VStack(spacing: 0) {
            menuAction("Displays", symbol: "rectangle.on.rectangle") { openDisplays() }
            Toggle("Always show scroll rail", isOn: $alwaysShowScrollRail)
                .font(.subheadline).tint(ReachHomeStyle.cyan).padding(.horizontal, 17).padding(.vertical, 11)
            menuAction("Send device clipboard", symbol: "doc.on.clipboard") { model.sendClipboard(); showMenu = false }
            Toggle(isOn: $model.clipboardEnabled) {
                Label("Receive Mac clipboard", systemImage: "doc.on.doc")
                    .font(.subheadline).labelStyle(.titleAndIcon)
            }.tint(ReachHomeStyle.cyan).padding(.horizontal, 17).padding(.vertical, 11)
            Divider().overlay(.white.opacity(0.07)).padding(.horizontal, 16)
            menuAction("Help", symbol: "questionmark.circle") { showMenu = false; showHelp = true }
            menuAction("Disconnect", symbol: "rectangle.portrait.and.arrow.right", destructive: true) { model.disconnect() }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 284, height: min(390, max(140, availableHeight - bottomChromeHeight - 70)))
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.10), lineWidth: 0.5) }
    }
    private var statusPill: some View {
        HStack(spacing: 7) {
            Image(systemName: "display").font(.system(size: 11, weight: .light))
            Text(model.hostName).lineLimit(1)
            Text("·").foregroundStyle(.white.opacity(0.4))
            Image(systemName: "lock.fill").font(.system(size: 8))
            Text(model.peer.connected ? "Encrypted" : "Reconnecting")
            if let latency = model.latency, model.peer.connected { Text("· \(latency) ms RTT").monospacedDigit() }
        }
        .font(.caption2).foregroundStyle(.white.opacity(0.72))
        .padding(.horizontal, 13).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule()).opacity(0.75)
        .frame(maxWidth: 320, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityHint("RTT is network round-trip time, not total screen or input delay.")
    }
    private func menuAction(_ title: String, symbol: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15)).frame(width: 19)
                Text(title).font(.subheadline)
                Spacer(minLength: 0)
            }
            .foregroundStyle(destructive ? Color.red.opacity(0.9) : .white)
            .padding(.horizontal, 17).padding(.vertical, 14).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private var help: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    Text("Choose your saved Mac on any network. Reach selects a local connection or the secure relay automatically. Keep your Mac awake with Reach running.")
                }
                Label("Tap to click", systemImage: "hand.tap")
                Label("Pinch or double-tap to zoom", systemImage: "arrow.up.left.and.arrow.down.right")
                Label("Mouse mode starts on: drag one finger to move the pointer, then tap to click", systemImage: "cursorarrow")
                Label("Two-finger drag pans; pinch to zoom in either mode", systemImage: "arrow.up.left.and.arrow.down.right")
                Label("Click scrollable content to show the right-edge rail. Drag its thumb up or down and hold: farther from the center scrolls faster. Release to stop.", systemImage: "scroll")
                Label("Tap the monitor pill at the top while controls are visible, or use a three-finger tap, to browse displays", systemImage: "display")
                Label("Swipe between display previews, then tap with one, two, or three fingers to enter", systemImage: "hand.tap")
                Label("Hold to right-click; hold and move to drag an item", systemImage: "computermouse")
                Label("Focus, fit width, and fit height are available in the bottom bar", systemImage: "viewfinder")
                Label("Rotate your iPhone or iPad, or resize Reach on iPad, to change the viewport. Fit width and Fit height adapt to the available space.", systemImage: "rectangle.expand.vertical")
            }
            .navigationTitle("Help").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { showHelp = false } }
        }.presentationDetents([.medium, .large])
    }
    private var loadingTitle: String {
        if model.isSwitchingDisplay { return "Opening display" }
        return model.peer.connected ? "Opening your desktop" : "Connecting to your Mac"
    }
    private var failureDetail: String {
        model.message ?? (model.peer.connected ? "Your Mac hasn’t sent a desktop frame yet." : "Make sure your Mac is awake and Reach is open.")
    }
    private var loadingPhase: String {
        "\(model.receivedFrame)-\(model.peer.connected)-\(model.peer.pairingCode == nil)-\(model.displaySwitchRevision)-\(loadingAttempt)"
    }
    private func preset(_ label: String, symbol: String, mode: ViewportMode) -> some View {
        tool(label, symbol: symbol, selected: selectedPreset == mode) {
            viewportMode = mode; selectedPreset = mode; viewportReset += 1
        }
    }
    private func tool(_ label: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { reveal(); action() } label: {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44)
                .background(selected ? .white.opacity(0.16) : .clear, in: Capsule()).contentShape(Rectangle())
        }.accessibilityLabel(label).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func openDisplays() {
        showMenu = false; keyboard = false; hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { displayBrowser = true }
    }
    private func closeDisplays() {
        withAnimation(.easeInOut(duration: 0.2)) { displayBrowser = false }
        reveal()
    }
    private func reveal() {
        guard !displayBrowser else { return }
        withAnimation(.easeOut(duration: 0.2)) { controls = true }
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, !keyboard, !showMenu, !displayBrowser, !scrolling, !voiceOver else { return }
            withAnimation(.easeInOut(duration: 0.25)) { controls = false }
        }
    }
}

private struct SessionHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 600
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct BottomChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

struct RemoteKeyboard: View {
    let model: PhoneSession
    @State private var modifiers: UInt64 = 0
    private let command: UInt64 = 1 << 20
    private let option: UInt64 = 1 << 19
    private let control: UInt64 = 1 << 18
    private let shift: UInt64 = 1 << 17
    var body: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 6) {
                    key("esc", code: 53); key("tab", code: 48)
                    modifier("⌃", flag: control, label: "Control")
                    modifier("⌥", flag: option, label: "Option")
                    modifier("⇧", flag: shift, label: "Shift")
                    modifier("⌘", flag: command, label: "Command")
                    key("←", code: 123); key("↓", code: 125); key("↑", code: 126); key("→", code: 124)
                }.padding(.horizontal, 12)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    shortcut("Copy", code: 8); shortcut("Paste", code: 9); shortcut("Undo", code: 6); shortcut("Select all", code: 0); shortcut("Spotlight", code: 49)
                }.padding(.horizontal, 12)
            }
            KeyboardInput(modifiers: modifiers, text: { text in
                // macOS shortcuts use virtual keycodes; ordinary Unicode uses text events.
                let codes: [String: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49]
                if modifiers != 0, let code = codes[text.lowercased()] { model.key(code, modifiers: modifiers); modifiers = 0 }
                else if text == "\n" { model.key(36) }
                else { model.text(text) }
            }, delete: { model.key(51, modifiers: modifiers) }).frame(width: 1, height: 1).accessibilityHidden(true)
        }.padding(.vertical, 8).background(.ultraThinMaterial)
    }
    private func key(_ title: String, code: UInt16) -> some View {
        Button { model.key(code, modifiers: modifiers); modifiers = 0 } label: {
            Text(title).font(.system(size: 15, weight: .medium))
                .frame(minWidth: 44, minHeight: 44)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(["esc": "Escape", "tab": "Tab", "←": "Left arrow", "↓": "Down arrow", "↑": "Up arrow", "→": "Right arrow"][title] ?? title)
    }
    private func modifier(_ title: String, flag: UInt64, label: String) -> some View {
        Button { modifiers ^= flag } label: {
            Text(title).font(.system(size: 19)).frame(width: 44, height: 44)
                .background(modifiers & flag != 0 ? ReachStyle.accent : .white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label).accessibilityValue(modifiers & flag != 0 ? "On" : "Off")
    }
    private func shortcut(_ title: String, code: UInt16) -> some View {
        Button { model.key(code, modifiers: command) } label: {
            Text(title).font(.caption.weight(.medium)).padding(.horizontal, 14).frame(minHeight: 44)
                .background(.white.opacity(0.07), in: Capsule()).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct KeyboardInput: UIViewRepresentable {
    var modifiers: UInt64
    var text: (String) -> Void
    var delete: () -> Void
    func makeUIView(context: Context) -> RemoteInputView { let view = RemoteInputView(); view.insert = text; view.remove = delete; DispatchQueue.main.async { view.becomeFirstResponder() }; return view }
    func updateUIView(_ view: RemoteInputView, context: Context) { view.insert = text; view.remove = delete }
    static func dismantleUIView(_ view: RemoteInputView, coordinator: ()) { view.resignFirstResponder() }
}
final class RemoteInputView: UIView, UIKeyInput {
    var insert: ((String) -> Void)?
    var remove: (() -> Void)?
    var hasText: Bool { true }
    override var canBecomeFirstResponder: Bool { true }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var keyboardType: UIKeyboardType = .default
    func insertText(_ text: String) { insert?(text) }
    func deleteBackward() { remove?() }
}
