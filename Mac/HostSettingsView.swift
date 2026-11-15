import AppKit
import SwiftUI

enum HostSettingsPage: String, CaseIterable, Identifiable {
    case general = "General", remote = "Remote Access", help = "Help"
    var id: String { rawValue }
}

@MainActor
final class HostSettingsSelection: ObservableObject {
    @Published var page: HostSettingsPage = .general
}

/// A retained window keeps confirmations alive when the menu bar popover dismisses.
@MainActor
final class HostSettingsWindow {
    static let shared = HostSettingsWindow()
    private var window: NSWindow?
    private let selection = HostSettingsSelection()
    func show(_ page: HostSettingsPage) {
        selection.page = page
        if window == nil {
            let height = min(660, (NSScreen.main?.visibleFrame.height ?? 800) - 100)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: height),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Reach Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HostSettingsView(host: .shared, selection: selection))
            window.minSize = NSSize(width: 480, height: 440)
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HostSettingsView: View {
    @ObservedObject var host: HostModel
    @ObservedObject var selection: HostSettingsSelection
    @State private var confirmation: DestructiveAction?
    @State private var showDiagnostics = false
    @State private var remoteMessage = ""
    private enum DestructiveAction { case forgetDevices, removeRelay }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: $selection.page) {
                ForEach(HostSettingsPage.allCases) { page in Text(page.rawValue).tag(page) }
            }.pickerStyle(.segmented).labelsHidden().padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch selection.page {
                    case .general: general
                    case .remote: remote
                    case .help: help
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .background(HostOverlayScrollStyle())
            }.scrollIndicators(.visible).scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(confirmation == .forgetDevices ? "Forget all trusted devices?" : "Remove remote access?",
               isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
               presenting: confirmation) { action in
            Button("Cancel", role: .cancel) { confirmation = nil }
            Button(action == .forgetDevices ? "Forget devices" : "Remove remote access", role: .destructive) {
                if action == .forgetDevices { host.peer.forgetTrustedDevices() }
                else { host.removeRelay(); remoteMessage = "Remote access removed. Local pairing is still available." }
                confirmation = nil
            }
        } message: { action in
            Text(action == .forgetDevices
                 ? "The current session will end. Every device will need to pair with this Mac again."
                 : "The current connection will end. Devices will only be able to reach this Mac on the local network until remote access is configured again.")
        }
    }

    private var general: some View {
        Group {
            heading("Your Mac, ready for you", detail: "Manage permissions and the devices you trust.")
            section("Permissions") {
                HostPermissionRow(title: "Screen Recording", detail: "View your desktop securely on iPhone or iPad.", allowed: host.screenAllowed, action: host.requestScreen)
                Divider()
                HostPermissionRow(title: "Accessibility", detail: "Control the mouse and keyboard remotely.", allowed: host.inputAllowed, action: host.requestInput)
            }
            section("About Reach") {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")")
                Text("Your Mac. Within reach.").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                Label("Danger Zone", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.red)
                Text("Forget every trusted iPhone and iPad. This ends the current session and requires pairing again.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Forget all trusted devices…", role: .destructive) { confirmation = .forgetDevices }
                    .buttonStyle(.bordered)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.red.opacity(0.25)))
        }
    }

    private var remote: some View {
        Group {
            heading("Reach beyond your Wi-Fi", detail: "Optional setup for your own secure relay. Local connections work without it.")
            section("Remote access") {
                Label(ReachRelayConfiguration.load() == nil ? "Not configured" : "Remote access configured",
                      systemImage: ReachRelayConfiguration.load() == nil ? "globe" : "checkmark.shield")
                    .font(.subheadline.weight(.medium))
                Text("Configure this once on your Mac. Paired devices receive the setup securely and choose local or remote access automatically.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Secure relay address").font(.caption.weight(.medium))
                    TextField("wss://relay.example.com", text: $host.relayURL).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Secure relay address")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Registered private room").font(.caption.weight(.medium))
                    SecureField("Enter a room to save or replace setup", text: $host.relayRoom).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Registered private room")
                }
                Text("Use a registered private room from your relay administrator. Existing room credentials stay hidden.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Save remote access") {
                    remoteMessage = host.connectRelay() ? "Remote access saved. Your paired devices will receive the setup when they connect." : host.status
                }.buttonStyle(.borderedProminent)
                    .disabled(!host.enabled || host.relayURL.isEmpty || host.relayRoom.isEmpty)
                if !host.enabled { Text("Turn on Allow connections in the menu bar to save setup.").font(.caption).foregroundStyle(.secondary) }
                if !remoteMessage.isEmpty { Text(remoteMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            DisclosureGroup("Connection diagnostics", isExpanded: $showDiagnostics) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(host.peer.state)
                    if !host.videoDiagnostics.isEmpty { Text(host.videoDiagnostics) }
                }.font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
            }
            if ReachRelayConfiguration.load() != nil {
                section("Remove remote access") {
                    Text("Disconnect the current session and remove this Mac’s saved relay setup. Local access remains available.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Remove remote access…", role: .destructive) { confirmation = .removeRelay }
                }
            }
        }
    }

    private var help: some View {
        Group {
            heading("Pair once. Connect anywhere.", detail: "A few simple steps to reach your Mac.")
            section("1. Get your Mac ready") {
                Text("Allow Screen Recording and Accessibility in General, then turn on Allow connections in the menu bar. Keep your Mac awake with Reach running.")
            }
            section("2. Pair your iPhone or iPad") {
                Text("Open Reach on the same Wi-Fi and select this Mac. Compare the six-digit codes on both devices and approve only if they match. Guest Wi-Fi networks may block discovery.")
            }
            section("3. Select your Mac anywhere") {
                Text("Your paired Mac stays in the app. Reach chooses a local connection first and uses your configured relay when you’re away.")
                Text("For first pairing from another network, copy a private pairing invitation from the Mac’s menu bar panel and paste it into Add a Mac on your device. Share invitations only with your own devices.")
            }
            Button("Set up remote access") { selection.page = .remote }
        }.font(.callout)
    }

    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}
