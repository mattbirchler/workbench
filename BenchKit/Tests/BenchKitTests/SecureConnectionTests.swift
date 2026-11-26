import Foundation
import Testing
@testable import BenchKit

struct SecureConnectionTests {
    @Test func recognizesTLSFailures() {
        // What URLSession reports when Serve fails the handshake.
        #expect(SecureConnection.isFailure(NSError(domain: NSURLErrorDomain, code: -1200)))
        #expect(SecureConnection.isFailure(URLError(.serverCertificateUntrusted)))
    }

    @Test func otherFailuresDoNotCount() {
        #expect(!SecureConnection.isFailure(URLError(.cannotFindHost)))
        #expect(!SecureConnection.isFailure(URLError(.timedOut)))
        #expect(!SecureConnection.isFailure(NSError(domain: "other", code: -1200)))
    }
}

@MainActor
struct CompanionClientProblemTests {
    @Test func tlsFailureGetsAPlainExplanation() {
        let message = CompanionClient.plain(NSError(domain: NSURLErrorDomain, code: -1200))
        #expect(message.contains("HTTPS Certificates"))
    }

    @Test func otherFailuresKeepTheirWording() {
        let lookup = NSError(domain: NSURLErrorDomain, code: -1003, userInfo: [NSLocalizedDescriptionKey: "A server with the specified hostname could not be found."])
        #expect(CompanionClient.plain(lookup).contains("Is Tailscale connected"))
    }

    @Test func aTimeoutGetsAPlainExplanation() {
        #expect(CompanionClient.plain(URLError(.timedOut)).contains("didn't answer in time"))
    }
}

@MainActor
struct CompanionClientRepairTests {
    @Test func aRejectedCodeNeedsRepairUntilWelcomed() {
        let client = CompanionClient(deviceName: "Test")
        #expect(!client.needsRepair)
        client.apply(.error("Couldn't read that message."))
        #expect(!client.needsRepair)
        client.apply(.error(PairingInfo.rejectedMessage))
        #expect(client.needsRepair)
        client.apply(.welcome(macName: "Mac", protocolVersion: companionProtocolVersion))
        #expect(!client.needsRepair)
    }

    @Test func aNewPairingClearsNeedsRepair() {
        let client = CompanionClient(deviceName: "Test")
        client.connect(PairingInfo(host: "repair-test.invalid", token: "old"))
        client.apply(.error(PairingInfo.rejectedMessage))
        #expect(client.needsRepair)
        client.connect(PairingInfo(host: "repair-test.invalid", token: "old"))
        #expect(client.needsRepair)
        client.connect(PairingInfo(host: "repair-test.invalid", token: "new"))
        #expect(!client.needsRepair)
        client.disconnect()
    }

    private func untilFailed(_ client: CompanionClient) async {
        for _ in 0..<200 where !(client.status == .disconnected && client.hasFailedToReach) {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// A code the Mac turned down won't work next time either, and on the
    /// home network each try counts toward its guess limit: no tries by
    /// itself until a new pairing or a pull to refresh.
    @Test func aRejectedCodeStopsReconnecting() async {
        let client = CompanionClient(deviceName: "Test")
        client.connect(PairingInfo(host: "repair-test.invalid", token: "old"))
        client.apply(.error(PairingInfo.rejectedMessage))
        await untilFailed(client)
        #expect(client.hasFailedToReach)
        #expect(!client.isReconnectScheduled)
        #expect(client.problem == PairingInfo.rejectedMessage)
        client.disconnect()
    }

    @Test func otherFailuresStillReconnect() async {
        let client = CompanionClient(deviceName: "Test")
        client.connect(PairingInfo(host: "repair-test.invalid", token: "old"))
        await untilFailed(client)
        #expect(client.hasFailedToReach)
        #expect(client.isReconnectScheduled)
        client.disconnect()
    }

    /// Scanning a new code for the same Mac drops the try still using the
    /// old one, so its hello never goes out.
    @Test func aNewCodeReplacesTheTryInFlight() async {
        let client = CompanionClient(deviceName: "Test")
        client.connect(PairingInfo(host: "repair-test.invalid", token: "old"))
        let first = client.currentSocket
        #expect(first != nil)
        client.connect(PairingInfo(host: "repair-test.invalid", token: "new"))
        #expect(client.currentSocket != nil)
        #expect(client.currentSocket !== first)
        // Closing a socket takes a moment.
        let old = first as? URLSessionWebSocketTask
        for _ in 0..<40 where old?.state == .running { try? await Task.sleep(for: .milliseconds(25)) }
        #expect(old != nil)
        #expect(old?.state != .running)
        client.disconnect()
    }

    /// A home network Mac whose certificate is no longer the one paired.
    @Test func aChangedCertificateAsksForANewScan() {
        let client = CompanionClient(deviceName: "Test")
        client.failed(PinnedSession.Mismatch())
        #expect(client.needsRepair)
        #expect(client.problem == "This Mac's code has changed. Scan it again.")
        #expect(!client.isReconnectScheduled)
    }
}
