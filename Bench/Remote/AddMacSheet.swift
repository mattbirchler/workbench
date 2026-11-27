import AppKit
import BenchKit
import SwiftUI

/// Pairs this Mac with Bench on another Mac: paste the link that Bench's
/// settings there copies.
struct AddMacSheet: View {
    @Environment(RemoteMacs.self) private var macs
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var problem: String?
    /// The link that `problem` is about, when it's worth adding anyway (the
    /// other Mac might just be asleep).
    @State private var addAnyway: PairingInfo?
    @State private var check: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a Mac or Server")
                    .font(.ui(size: 15, weight: .semibold))
                Text("On the other Mac, open Workbench › Settings › Remote Access, turn on Let my iPhone and other Macs connect, and choose Copy Pairing Link. Paste it here. Both Macs need to be on your Tailscale network.\n\nFor a Linux server, run workbench-host pair there and paste the link it prints.")
                    .font(.ui(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("bench://pair?host=…&token=…", text: $link)
                .textFieldStyle(.roundedBorder)
                .font(.ui(size: 12, design: .monospaced))
                .onSubmit(connect)
                .onChange(of: link) { problem = nil; addAnyway = nil }
            if let problem {
                Text(problem)
                    .font(.ui(size: 12))
                    .foregroundStyle(Theme.Status.failed)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                if check != nil {
                    ProgressView().controlSize(.small)
                    Text("Checking the connection…")
                        .font(.ui(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    check?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if let info = addAnyway, check == nil {
                    Button("Add Anyway") { add(info) }
                        .help("Keep trying in the sidebar, for when the other Mac is asleep or Workbench is closed there.")
                }
                Button("Connect", action: connect)
                    .buttonStyle(.prominent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || check != nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            // The link is probably on the clipboard already.
            if let text = NSPasteboard.general.string(forType: .string), text.hasPrefix("bench://pair") { link = text }
        }
    }

    private func connect() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let info = PairingInfo(url: url) else {
            problem = "That isn't a Workbench pairing link. It starts with bench://pair."
            return
        }
        problem = nil
        addAnyway = nil
        check = Task {
            let found = await Self.problem(with: info)
            guard !Task.isCancelled else { return }
            check = nil
            if let found {
                problem = found.message
                addAnyway = found.canAddAnyway ? info : nil
            } else {
                add(info)
            }
        }
    }

    private func add(_ info: PairingInfo) {
        macs.add(info)
        dismiss()
    }

    /// Why the link won't work, or nil once Workbench on the other Mac has
    /// let us in. Checks what Tailscale on this Mac knows first, then makes
    /// one real connection.
    private static func problem(with info: PairingInfo) async -> (message: String, canAddAnyway: Bool)? {
        // A link with no tailnet name (a server reached through the relay)
        // has nothing for Tailscale to say about.
        if !info.isLocalOnly, let found = await Tailscale.status()?.pairingProblem(host: info.host) {
            return (found.message, found != .thisDevice)
        }
        let client = CompanionClient(deviceName: Host.current().localizedName ?? "Mac", features: [CompanionFeature.relay])
        defer { client.disconnect() }
        client.connect(info)
        // Long enough for Serve to fetch a first certificate on the other end.
        let deadline = Date.now.addingTimeInterval(30)
        while Date.now < deadline, !Task.isCancelled {
            if client.status == .connected { return nil }
            if let problem = client.problem { return (problem, true) }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return ("Workbench there didn't answer. For a Mac, check that it's awake, that Workbench is open, and that the companion is on in its settings. For a server, check that workbench-host is running.", true)
    }
}
