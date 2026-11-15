import AppKit
import SwiftUI

/// Monochrome version of the desktop-and-phone mark on the iPhone welcome screen.
@MainActor
enum ReachMenuIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 23, height: 20), flipped: true) { _ in
            let desktop = NSBezierPath()
            desktop.move(to: NSPoint(x: 15.5, y: 8))
            desktop.line(to: NSPoint(x: 15.5, y: 3.5))
            desktop.curve(to: NSPoint(x: 13.5, y: 1.5), controlPoint1: NSPoint(x: 15.5, y: 2.2), controlPoint2: NSPoint(x: 14.8, y: 1.5))
            desktop.line(to: NSPoint(x: 3, y: 1.5))
            desktop.curve(to: NSPoint(x: 1, y: 3.5), controlPoint1: NSPoint(x: 1.7, y: 1.5), controlPoint2: NSPoint(x: 1, y: 2.2))
            desktop.line(to: NSPoint(x: 1, y: 11.5))
            desktop.curve(to: NSPoint(x: 3, y: 13.5), controlPoint1: NSPoint(x: 1, y: 12.8), controlPoint2: NSPoint(x: 1.7, y: 13.5))
            desktop.line(to: NSPoint(x: 14, y: 13.5))
            desktop.move(to: NSPoint(x: 8.3, y: 13.5)); desktop.line(to: NSPoint(x: 8.3, y: 17))
            desktop.move(to: NSPoint(x: 5, y: 17)); desktop.line(to: NSPoint(x: 11.5, y: 17))
            desktop.lineWidth = 1.35; desktop.lineCapStyle = .round; desktop.lineJoinStyle = .round
            NSColor.white.setStroke(); desktop.stroke()
            let phone = NSBezierPath(roundedRect: NSRect(x: 14, y: 8, width: 7.5, height: 11), xRadius: 1.8, yRadius: 1.8)
            phone.lineWidth = 1.35; phone.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 440
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Keep overflow affordances over the content edge, including with Always Show Scrollbars enabled.
struct HostOverlayScrollStyle: NSViewRepresentable {
    final class Anchor: NSView {
        func configure() {
            var ancestor: NSView? = self
            while let view = ancestor {
                if let scroll = view as? NSScrollView {
                    scroll.scrollerStyle = .overlay
                    scroll.autohidesScrollers = false
                    return
                }
                ancestor = view.superview
            }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.configure() }
        }
    }
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ nsView: Anchor, context: Context) {
        DispatchQueue.main.async { [weak nsView] in nsView?.configure() }
    }
}

struct HostPopover: View {
    @ObservedObject var host: HostModel
    var onHeightChange: ((CGFloat) -> Void)? = nil
    @State private var contentHeight: CGFloat = 440
    var body: some View {
        ScrollView {
            HostPanel(host: host)
                .background(HostOverlayScrollStyle())
                .frame(width: 360)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: PanelHeightKey.self, value: geometry.size.height)
                })
        }
        .scrollIndicators(.visible)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 360, height: min(contentHeight, max(240, (NSScreen.main?.visibleFrame.height ?? 800) - 64)))
        .onPreferenceChange(PanelHeightKey.self) {
            contentHeight = ceil($0)
            onHeightChange?(min(contentHeight, max(240, (NSScreen.main?.visibleFrame.height ?? 800) - 64)))
        }
    }
}

@MainActor
final class HostPanelWindow {
    static let shared = HostPanelWindow()
    private var window: NSWindow?
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 440),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Reach"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HostPopover(host: .shared) { [weak window] height in
                guard let window, abs(window.contentLayoutRect.height - height) > 1 else { return }
                window.setContentSize(NSSize(width: 360, height: height))
            })
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct ReachPanelBrand: View {
    var body: some View {
        HStack(spacing: 12) {
            Image("ReachArtwork").resizable().interpolation(.high)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Reach").font(.system(size: 23, weight: .semibold, design: .rounded))
                Text("Your Mac. Within reach.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct HostPanel: View {
    @ObservedObject var host: HostModel
    @State private var copiedInvitation = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ReachPanelBrand()
            HStack(alignment: .top, spacing: 12) {
                ReachMonitorOutline().stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 25, height: 25).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(Host.current().localizedName ?? "My Mac").font(.headline).lineLimit(2)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(host.enabled ? (host.streaming ? Color.green : Color.accentColor) : Color.secondary)
                            .frame(width: 6, height: 6).accessibilityHidden(true)
                        Text(host.enabled ? host.status : "Connections paused")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

            if host.peer.requiresApproval, let code = host.peer.pairingCode {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Pair your device", systemImage: "lock.shield").font(.headline)
                    Text("Compare this code on both devices. Trust only a device you recognize.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(code).font(.system(size: 30, weight: .medium, design: .monospaced))
                        .tracking(3).textSelection(.enabled).accessibilityLabel("Pairing code \(code)")
                    HStack {
                        Button("Decline") { host.peer.rejectPairing() }
                        Spacer()
                        Button("Trust device") { host.peer.approvePairing() }.buttonStyle(.borderedProminent)
                    }
                }.padding(14).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            if !host.screenAllowed || !host.inputAllowed {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Finish setting up").font(.headline)
                    HostPermissionRow(title: "Screen Recording", detail: "See your desktop on your device.", allowed: host.screenAllowed, action: host.requestScreen)
                    HostPermissionRow(title: "Accessibility", detail: "Control your mouse and keyboard.", allowed: host.inputAllowed, action: host.requestInput)
                }
            }
            VStack(spacing: 14) {
                Toggle(isOn: Binding(get: { host.enabled }, set: { host.setEnabled($0) })) {
                    Text("Allow connections").frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                Toggle(isOn: $host.clipboardEnabled) {
                    Text("Sync text clipboard").frame(maxWidth: .infinity, alignment: .leading)
                }
                    .help("Share copied text with your connected trusted device.")
            }.toggleStyle(.switch).controlSize(.small)
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect from your iPhone or iPad").font(.subheadline.weight(.medium))
                Text("Open Reach and select this Mac. Pair once on the same Wi-Fi; Reach remembers the connection.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if ReachRelayConfiguration.load() != nil {
                    Button { copyInvitation() } label: {
                        Label(copiedInvitation ? "Invitation copied" : "Copy pairing invitation", systemImage: copiedInvitation ? "checkmark" : "doc.on.doc")
                    }.font(.caption).padding(.top, 3)
                    .help("Private invitation for pairing from another network. Share only with your own device.")
                }
            }
            if host.peer.connected {
                Button("Disconnect device") { host.peer.disconnect() }.frame(maxWidth: .infinity)
            }
            Divider()
            HStack(spacing: 14) {
                Button { HostSettingsWindow.shared.show(.general) } label: { Label("Settings…", systemImage: "gearshape") }
                Button { HostSettingsWindow.shared.show(.help) } label: { Image(systemName: "questionmark.circle") }
                    .accessibilityLabel("Connection help").help("Connection help")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.foregroundStyle(.secondary)
            }.buttonStyle(.plain).font(.caption).frame(minHeight: 24)
        }.padding(20)
    }
    private func copyInvitation() {
        guard let configuration = ReachRelayConfiguration.load() else { return }
        var invitation = URLComponents()
        invitation.scheme = "reach"; invitation.host = "relay"
        invitation.queryItems = [URLQueryItem(name: "url", value: configuration.url.absoluteString), URLQueryItem(name: "room", value: configuration.room)]
        guard let value = invitation.string else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedInvitation = true
    }
}

struct HostPermissionRow: View {
    let title: String
    let detail: String
    let allowed: Bool
    let action: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: allowed ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(allowed ? Color.green : Color.orange).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if !allowed { Button("Allow", action: action).controlSize(.small).accessibilityLabel("Allow \(title)") }
        }
    }
}
