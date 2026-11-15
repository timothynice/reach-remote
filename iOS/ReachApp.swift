import SwiftUI

@main
struct ReachApp: App {
    @StateObject private var session = PhoneSession()
    var body: some Scene {
        WindowGroup { ReachRootView().environmentObject(session).tint(ReachStyle.accent) }
    }
}

enum ReachStyle {
    static let accent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.30, green: 0.64, blue: 1, alpha: 1) : UIColor(red: 0.10, green: 0.37, blue: 0.88, alpha: 1) })
}

struct ReachRootView: View {
    @EnvironmentObject private var model: PhoneSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if model.active { RemoteDesktopView(model: model) }
            else { DeviceListView(model: model) }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.active)
        .transaction { if reduceMotion { $0.animation = nil } }
        .sheet(isPresented: Binding(get: { model.peer.requiresApproval }, set: { _ in /* Pairing ends only through the explicit actions below. */ })) {
            PairingView(model: model).presentationDetents([.medium, .large]).interactiveDismissDisabled()
        }
        .onAppear { if scenePhase == .active { model.setForeground(true) } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.setForeground(true) }
            else if phase == .background { model.setForeground(false) }
        }
    }
}

struct DeviceListView: View {
    @ObservedObject var model: PhoneSession
    @State private var showRemote = false
    @State private var confirmForget = false
    @State private var showSetupHelp = false
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ReachHero()
                            .padding(.top, max(20, min(48, geometry.size.height * 0.06)))
                            .padding(.bottom, 30)
                        nearbyDevices
                        if model.savedMacs.isEmpty && model.otherNearbyHosts.isEmpty {
                            Button {
                                if let relay = ReachRelayConfiguration.load() { model.connectRelay(url: relay.url, room: relay.room) }
                                else { showRemote = true }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "globe").font(.system(size: 17, weight: .light))
                                        .foregroundStyle(ReachHomeStyle.cyan)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(ReachRelayConfiguration.load() == nil ? "Add a Mac from an invitation" : "Your Mac").font(.subheadline)
                                        Text("Connect securely").font(.caption).foregroundStyle(ReachHomeStyle.faint)
                                    }
                                        .foregroundStyle(ReachHomeStyle.muted)
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .regular))
                                        .foregroundStyle(ReachHomeStyle.faint)
                                }
                                .padding(.vertical, 23).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).padding(.top, 15)
                        }
                        Rectangle().fill(ReachHomeStyle.line).frame(height: 0.5)
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "lock").font(.system(size: 11, weight: .regular)).padding(.top, 2)
                            Text("End-to-end encrypted. Paired only with you.")
                                .font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(ReachHomeStyle.faint).padding(.top, 23)
                    }
                    .padding(.horizontal, 26).padding(.bottom, 36)
                    .frame(maxWidth: 620).frame(maxWidth: .infinity)
                    .background(alignment: .topTrailing) {
                        ReachHeroDotField().frame(height: 224).padding(.top, -18)
                    }
                }
            }
            .background(ReachHomeStyle.background)
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add a Mac", systemImage: "plus") { showRemote = true }
                        Button("Connection help", systemImage: "questionmark.circle") { showSetupHelp = true }
                        Button("Forget trusted Macs", role: .destructive) { confirmForget = true }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 18, weight: .regular))
                            .foregroundStyle(ReachHomeStyle.muted).frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Device options")
                }
            }
            .confirmationDialog("Forget trusted Macs?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget trusted Macs", role: .destructive) {
                    model.forgetMacs()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Saved Macs and their connection setup will be removed from this device. Pairing codes must be compared again.")
            }
            .sheet(isPresented: $showRemote) { RemoteConnectionView(model: model) }
            .sheet(isPresented: $showSetupHelp) { ConnectionHelpView() }
        }
    }

    private var nearbyDevices: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("YOUR MACS").font(.caption2.weight(.medium)).tracking(1.6)
                    .foregroundStyle(ReachHomeStyle.faint)
                Spacer()
                if model.savedMacs.isEmpty && model.otherNearbyHosts.isEmpty {
                    ProgressView().controlSize(.mini).tint(ReachHomeStyle.cyan)
                        .accessibilityLabel("Discovering nearby Macs")
                }
            }.padding(.bottom, 17)
            Rectangle().fill(ReachHomeStyle.line).frame(height: 0.5)
            ForEach(model.savedMacs) { mac in
                Button { model.connect(mac) } label: {
                    deviceRow(name: mac.name)
                }
                .buttonStyle(.plain).accessibilityIdentifier("saved-mac-\(mac.id)")
                .accessibilityLabel("Connect to \(mac.name)")
                .accessibilityHint("Reach automatically chooses a secure connection.")
                Rectangle().fill(ReachHomeStyle.line).frame(height: 0.5)
            }
            ForEach(model.otherNearbyHosts) { host in
                Button { model.connect(host) } label: { deviceRow(name: host.name, detail: "Ready to pair") }
                    .buttonStyle(.plain).accessibilityIdentifier("host-\(host.id)")
                    .accessibilityLabel("Connect to \(host.name)")
                    .accessibilityHint("Compare pairing codes on both devices if this is your first connection.")
                Rectangle().fill(ReachHomeStyle.line).frame(height: 0.5)
            }
            if model.savedMacs.isEmpty && model.otherNearbyHosts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Looking for your Mac").font(.subheadline.weight(.medium)).foregroundStyle(ReachHomeStyle.ink)
                    Text("Open Reach in your Mac’s menu bar and connect once on the same Wi-Fi. Your Mac will stay here when you’re away.")
                        .font(.subheadline).foregroundStyle(ReachHomeStyle.muted)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                    Button { showSetupHelp = true } label: {
                        Label("Connection help", systemImage: "questionmark.circle")
                            .font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
                    }.padding(.top, 8).foregroundStyle(ReachHomeStyle.cyan)
                }.padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func deviceRow(name: String, detail: String? = nil) -> some View {
        HStack(spacing: 16) {
            ReachMonitorOutline().stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)).frame(width: 26, height: 26)
                .foregroundStyle(ReachHomeStyle.muted).frame(width: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(name).font(.body.weight(.medium)).foregroundStyle(ReachHomeStyle.ink)
                    .lineLimit(2).multilineTextAlignment(.leading)
                if let detail { Text(detail).font(.caption).foregroundStyle(ReachHomeStyle.faint) }
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .regular)).foregroundStyle(ReachHomeStyle.faint)
        }.padding(.vertical, 22).contentShape(Rectangle())
    }

}

struct PairingView: View {
    @ObservedObject var model: PhoneSession
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "lock.shield").font(.system(size: 36, weight: .light)).foregroundStyle(ReachStyle.accent).accessibilityHidden(true)
                Text("Make a secure connection").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("Check that this code matches the code on your Mac. Approve only if both are identical.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text(model.peer.pairingCode ?? "••••••")
                    .font(.system(size: 36, weight: .medium, design: .monospaced)).tracking(5)
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .accessibilityLabel("Pairing code")
                    .accessibilityValue(model.peer.pairingCode?.map(String.init).joined(separator: " ") ?? "Waiting")
                    .accessibilityIdentifier("pairing-code")
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 12) { pairingActions }
                } else {
                    HStack(spacing: 16) { pairingActions }
                }
            }.padding(30).frame(maxWidth: 540).frame(maxWidth: .infinity)
        }.scrollBounceBehavior(.basedOnSize)
    }
    @ViewBuilder private var pairingActions: some View {
        Button(role: .cancel) { model.peer.rejectPairing(); model.disconnect() } label: {
            Text("Cancel").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.bordered)
        Button { model.peer.approvePairing() } label: {
            Text("Codes match").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.borderedProminent)
    }
}

private struct ConnectionHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Pair once") {
                    Label("Open Reach on your Mac and allow connections. Keep your Mac awake.", systemImage: "display")
                    Label("For first pairing, use the same Wi-Fi network and allow Local Network access on your iPhone or iPad. Guest networks may prevent discovery.", systemImage: "wifi")
                    Text("Select your Mac, compare the six-digit codes on both devices, and approve only if they match. Reach saves your Mac and its configured remote access securely.")
                }
                Section("Select your Mac anywhere") {
                    Text("Your saved Mac stays in the list when you leave home. Select it as usual: Reach tries a local connection first and uses its secure relay when needed. You don’t need to switch modes, enter an address, or configure your router.")
                    Text("Remote access must be configured once on the Mac. If you’re pairing from another network, choose Device options → Add a Mac and paste a private pairing invitation from Reach on your Mac.")
                }
                Section("If you can’t connect") {
                    Text("Make sure your Mac is awake, Reach is running, and Allow connections is on. Screen Recording shares the desktop; Accessibility enables mouse and keyboard control. After granting Screen Recording, reopen Reach if macOS asks.")
                    Text("For nearby discovery, allow Local Network access on this device. Internet connections also require remote access configured on the Mac and an available relay.")
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: { Text("Open Settings").frame(minHeight: 44).contentShape(Rectangle()) }
                }
                Section("iPhone and iPad") {
                    Text("Reach supports both portrait and landscape. On iPad, you can also resize the app or use it alongside another app; the desktop viewport follows the available space. Pinch to zoom and use Fit width or Fit height for your current layout.")
                }
                Section("While connected") {
                    Text("Open Session options → Help for gestures, keyboard controls, scrolling, and monitor switching.")
                }
            }
            .navigationTitle("Connection help").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
