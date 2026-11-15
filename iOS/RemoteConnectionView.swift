import SwiftUI

/// An optional first-pairing path when the Mac is not on the same local network.
struct RemoteConnectionView: View {
    @ObservedObject var model: PhoneSession
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = ""
    @State private var room = ""
    @State private var error: String?
    @State private var showAdvanced = false
    private var configuration: ReachRelayConfiguration? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        guard let value = try? ReachRelayConfiguration(url: url, room: room.trimmingCharacters(in: .whitespacesAndNewlines)), value.isValid else { return nil }
        return value
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "display").font(.system(size: 30, weight: .thin)).foregroundStyle(ReachStyle.accent)
                        Text("Pair once. Connect anywhere.").font(.title2.weight(.semibold))
                        Text("The easiest way to add your Mac is to select it while both devices are on the same Wi-Fi. If you’re away, paste a private pairing invitation copied from Reach on your Mac.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
                Section {
                    Button { pasteInvitation() } label: { Label("Paste Mac invitation", systemImage: "doc.on.clipboard") }
                    if configuration != nil { Label("Invitation ready", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                } footer: {
                    Text("After pairing, select your saved Mac on any network. Reach chooses the connection automatically. Keep your invitation private.")
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.subheadline) } }
                Section {
                    Button("Pair with Mac") { connect() }.frame(maxWidth: .infinity).fontWeight(.semibold)
                }.disabled(configuration == nil)
                Section {
                    DisclosureGroup("Advanced setup", isExpanded: $showAdvanced) {
                        TextField("Secure relay address", text: $endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .accessibilityIdentifier("relay-url").accessibilityLabel("Secure relay address")
                        SecureField("Private room", text: $room).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("relay-room").accessibilityLabel("Private relay room")
                    }
                }
            }
            .navigationTitle("Add a Mac").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
    private func pasteInvitation() {
        error = nil
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            error = "Copy a pairing invitation from Reach on your Mac first."; return
        }
        if let parts = URLComponents(string: text), parts.scheme == "reach", parts.host == "relay", let items = parts.queryItems {
            endpoint = items.first(where: { $0.name == "url" })?.value ?? ""
            room = items.first(where: { $0.name == "room" })?.value ?? ""
        } else if let index = text.lastIndex(of: "#") {
            endpoint = String(text[..<index]); room = String(text[text.index(after: index)...])
        } else { endpoint = ""; room = "" }
        if configuration == nil { error = "This isn’t a complete Reach invitation. Copy a new one from your Mac." }
    }
    private func connect() {
        guard let configuration else { return }
        do { try configuration.save() }
        catch { self.error = "Couldn’t securely save this invitation. Try again."; return }
        dismiss(); model.connectRelay(url: configuration.url, room: configuration.room)
    }
}
