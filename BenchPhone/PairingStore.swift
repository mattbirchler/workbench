import BenchKit
import Foundation
import Observation
import Security

/// The Macs this phone is paired with, in the keychain, and which one it
/// talks to right now.
@Observable
final class PairingStore {
    private(set) var macs: [PairingInfo] = []
    private(set) var selectedHost: String?
    /// What each Mac called itself the last time we connected, by host.
    private(set) var names: [String: String] = [:]
    /// Debug pairings from the environment stay out of the keychain.
    @ObservationIgnored private var isEphemeral = false
    /// Showing sample projects instead of a Mac. Not saved.
    var isDemo = false

    /// The Mac to connect to.
    var info: PairingInfo? {
        macs.first { $0.host == selectedHost } ?? macs.first
    }

    private struct Saved: Codable {
        var macs: [PairingInfo]
        var selected: String?
        var names: [String: String]
    }

    private static let key = "me.birchtree.BenchPhone.macs"
    /// Where the first version kept its single pairing.
    private static let legacyKey = "me.birchtree.BenchPhone.pairing"

    init() {
        #if DEBUG
        // For screenshots: BENCH_DEMO=1 opens the demo.
        isDemo = ProcessInfo.processInfo.environment["BENCH_DEMO"] != nil
        // For screenshots in the simulator: BENCH_PAIR_URL=bench://pair?host=…&token=…
        // Several, separated by spaces, pair several Macs; the first is
        // selected. Wins over whatever the keychain has, and isn't saved.
        if let text = ProcessInfo.processInfo.environment["BENCH_PAIR_URL"] {
            macs = text.split(separator: " ").compactMap { URL(string: String($0)).flatMap(PairingInfo.init(url:)) }
            selectedHost = macs.first?.host
            isEphemeral = true
            NotificationKeys.save(macs)
            return
        }
        #endif
        if let data = Keychain.load(Self.key), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            macs = saved.macs
            selectedHost = saved.selected
            names = saved.names
        } else if let data = Keychain.load(Self.legacyKey), let single = try? JSONDecoder().decode(PairingInfo.self, from: data) {
            macs = [single]
            selectedHost = single.host
            save()
            Keychain.delete(Self.legacyKey)
        }
        // Pairings from before sealed notifications need their keys too.
        NotificationKeys.save(macs)
    }

    /// Adds a Mac, or refreshes its token if it's already here, and
    /// switches to it. A Mac already here under another host (it gained or
    /// changed its tailnet name) is replaced in its place: its name, saved
    /// project list and queued prompts move to the new host.
    func pair(_ info: PairingInfo) {
        isDemo = false
        let old = info.local.flatMap { local in
            macs.first { $0.local?.mac == local.mac && $0.host != info.host }?.host
        }
        let isNew = old == nil && !macs.contains { $0.host == info.host }
        Analytics.capture(.pairingCompleted, ["new_mac": isNew, "macs": macs.count + (isNew ? 1 : 0)])
        if let old {
            // In the old one's place. A stray entry already under the new
            // host would be a second copy, so it goes.
            macs.removeAll { $0.host == info.host }
            if let index = macs.firstIndex(where: { $0.host == old }) { macs[index] = info }
            if let name = names.removeValue(forKey: old) { names[info.host] = name }
            SnapshotCache.standard.move(from: old, to: info.host)
            QueueStoreCore.move(folder: QueueStoreCore.standardFolder, from: old, to: info.host)
        } else {
            macs.removeAll { $0.host == info.host }
            macs.append(info)
        }
        selectedHost = info.host
        save()
    }

    func select(host: String) {
        guard macs.contains(where: { $0.host == host }), host != selectedHost else { return }
        selectedHost = host
        save()
    }

    /// Forgets one Mac. If it was the current one, the next one takes over.
    func unpair(host: String) {
        macs.removeAll { $0.host == host }
        names[host] = nil
        SnapshotCache.standard.remove(host: host)
        QueueStoreCore.forget(folder: QueueStoreCore.standardFolder, host: host)
        if selectedHost == host { selectedHost = macs.first?.host }
        save()
    }

    /// Reorders the Macs, from the list in Settings.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        macs.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Moves one Mac a place earlier (-1) or later (1).
    func move(host: String, by step: Int) {
        guard let from = macs.firstIndex(where: { $0.host == host }),
              macs.indices.contains(from + step) else { return }
        macs.swapAt(from, from + step)
        save()
    }

    func remember(name: String, for host: String) {
        guard !name.isEmpty, names[host] != name else { return }
        names[host] = name
        save()
    }

    /// "Matt's Mac mini", or the first label of the host until the Mac
    /// has introduced itself.
    func name(for host: String) -> String {
        names[host] ?? String(host.split(separator: ".").first ?? Substring(host))
    }

    /// Keeps what a Mac said about its room on the relay with its pairing.
    func setRelay(_ relay: RelayEndpoint?, for host: String) {
        guard let index = macs.firstIndex(where: { $0.host == host }), macs[index].relay != relay else { return }
        macs[index].relay = relay
        save()
    }

    private func save() {
        NotificationKeys.save(macs)
        guard !isEphemeral else { return }
        if macs.isEmpty {
            Keychain.delete(Self.key)
        } else if let data = try? JSONEncoder().encode(Saved(macs: macs, selected: selectedHost, names: names)) {
            Keychain.save(data, for: Self.key)
        }
    }
}

private enum Keychain {
    static func save(_ data: Data, for key: String) {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
