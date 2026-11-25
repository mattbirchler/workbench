import BenchKit
import SwiftUI
import VisionKit

/// First run: scan the QR code from Bench's settings on the Mac. Also the
/// "Add a Mac" sheet, where it gets a Cancel button.
struct PairView: View {
    var isSheet = false
    @Environment(PairingStore.self) private var pairing
    @Environment(\.dismiss) private var dismiss
    @State private var showsScanner = false
    @State private var showsManual = false
    @State private var host = ""
    @State private var token = ""
    @State private var problem: String?

    var body: some View {
        pairingStack
            .sensoryFeedback(.error, trigger: problem) { _, new in new != nil }
    }

    private var pairingStack: some View {
        NavigationStack {
            Group {
                if isSheet {
                    pairPage
                } else {
                    PhoneWelcome { pairPage }
                }
            }
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
            }
            .sheet(isPresented: $showsScanner) {
                CodeScanner { text in
                    showsScanner = false
                    accept(text)
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showsManual) {
                NavigationStack {
                    Form {
                        Section {
                            TextField("Mac's tailnet name", text: $host)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .foregroundStyle(PhoneTheme.ink)
                            TextField("Pairing token", text: $token)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .foregroundStyle(PhoneTheme.ink)
                        } footer: {
                            Text("The name looks like matts-macbook-pro.tail1234.ts.net. Both values are in the code Workbench shows. To pair with a Mac that doesn't use Tailscale, scan its code instead.")
                        }
                        .listRowBackground(PhoneTheme.surface)
                    }
                    .scrollContentBackground(.hidden)
                    .background(PhoneTheme.canvas)
                    .navigationTitle("Pair Manually")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showsManual = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Pair") {
                                showsManual = false
                                pairing.pair(PairingInfo(host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                                                         token: token.trimmingCharacters(in: .whitespacesAndNewlines)))
                                if isSheet { dismiss() }
                            }
                            .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || token.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
        }
    }

    private var pairPage: some View {
        WelcomePage {
            VStack(spacing: 26) {
                Spacer()
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 58, weight: .light))
                    .foregroundStyle(PhoneTheme.accent)
                VStack(spacing: 10) {
                    Text(isSheet ? "Add a Mac" : "Pair with your Mac")
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                    Text(isSheet
                         ? "Open Workbench on the other Mac, choose Workbench › Settings › Remote Access, and scan the code it shows. You can switch between Macs from the project list."
                         : "It connects to Workbench on your Mac over Tailscale, so only your own devices can reach it.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(PhoneTheme.inkMuted)
                        .padding(.horizontal, 24)
                }
                if !isSheet {
                    VStack(alignment: .leading, spacing: 14) {
                        PairStep(number: 1, text: "Install Tailscale on your Mac and \(Device.name), signed in to the same account.")
                        PairStep(number: 2, text: "In Workbench on your Mac, turn on Let my iPhone connect. It's in the welcome, or Settings › Remote Access.")
                        PairStep(number: 3, text: "Scan the code it shows.")
                    }
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous).fill(PhoneTheme.surface))
                    .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous).strokeBorder(PhoneTheme.hairline))
                    .padding(.horizontal, 24)
                }
                if let problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(PhoneTheme.error)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Spacer()
                VStack(spacing: 14) {
                    Button {
                        showsScanner = true
                    } label: {
                        Label("Scan Code", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(.phonePrimary)
                    .disabled(!DataScannerViewController.isSupported)
                    HStack(spacing: 24) {
                        Button("Enter Details") { showsManual = true }
                        if !isSheet {
                            Button("Try a Demo") { pairing.isDemo = true }
                        }
                    }
                    .font(.callout.weight(.medium))
                    .tint(PhoneTheme.ink)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
        }
        .foregroundStyle(PhoneTheme.ink)
    }

    private func accept(_ text: String) {
        guard let url = URL(string: text), let info = PairingInfo(url: url) else {
            problem = "That code isn't from Workbench. Look for it under Workbench › Settings on your Mac."
            return
        }
        problem = nil
        pairing.pair(info)
        if isSheet { dismiss() }
    }
}

/// A numbered step in the pairing instructions.
private struct PairStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(PhoneTheme.onAccent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(PhoneTheme.accent))
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The camera, looking for one QR code.
private struct CodeScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var delivered = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for item in added {
                if case .barcode(let code) = item, let text = code.payloadStringValue {
                    delivered = true
                    scanner.stopScanning()
                    found(text)
                    return
                }
            }
        }
    }
}
