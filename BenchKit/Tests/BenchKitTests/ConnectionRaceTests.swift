import Foundation
import Testing
@testable import BenchKit

/// Which path the client keeps: Tailscale when it answers, the home
/// network when it doesn't.
@Suite struct ConnectionRaceTests {
    @Test func tailscaleOnlyNeverStartsLocal() {
        let race = ConnectionRace(hasTailscale: true, hasLocal: false)
        #expect(!race.startsLocal(at: 0))
        #expect(!race.startsLocal(at: 100))
    }

    @Test func localOnlyStartsLocalAtZero() {
        let race = ConnectionRace(hasTailscale: false, hasLocal: true)
        #expect(race.startsLocal(at: 0))
    }

    @Test func localStartsAfterHeadStart() {
        let race = ConnectionRace(hasTailscale: true, hasLocal: true)
        #expect(!race.startsLocal(at: 1.0))
        #expect(race.startsLocal(at: 1.5))
    }

    @Test func tailscaleWinsAsSoonAsItAnswers() {
        var race = ConnectionRace(hasTailscale: true, hasLocal: true)
        #expect(race.welcomed(.tailscale, at: 0.4) == .tailscale)
    }

    @Test func tailscaleBeatsLocalInsideHold() {
        var race = ConnectionRace(hasTailscale: true, hasLocal: true)
        #expect(race.welcomed(.local, at: 2.0) == nil)
        #expect(race.tick(at: 2.1) == nil)
        #expect(race.welcomed(.tailscale, at: 2.2) == .tailscale)
    }

    @Test func localWinsAfterHold() {
        var race = ConnectionRace(hasTailscale: true, hasLocal: true)
        #expect(race.welcomed(.local, at: 2.0) == nil)
        #expect(race.tick(at: 2.31) == .local)
    }

    @Test func localWinsAtOnceWithoutTailscale() {
        var race = ConnectionRace(hasTailscale: false, hasLocal: true)
        #expect(race.welcomed(.local, at: 0.5) == .local)
    }

    @Test func localWinsAtOnceWhenTailscaleFailed() {
        var race = ConnectionRace(hasTailscale: true, hasLocal: true)
        let ended = race.failed(.tailscale)
        #expect(!ended)
        #expect(race.startsLocal(at: 0.2))
        #expect(race.welcomed(.local, at: 0.5) == .local)
    }

    @Test func bothFailedEndsTheRace() {
        var race = ConnectionRace(hasTailscale: true, hasLocal: true)
        let localFailed = race.failed(.local)
        #expect(!localFailed)
        let bothFailed = race.failed(.tailscale)
        #expect(bothFailed)

        var localOnly = ConnectionRace(hasTailscale: false, hasLocal: true)
        let localOnlyFailed = localOnly.failed(.local)
        #expect(localOnlyFailed)
    }

    @Test func localGivesUpAtTimeout() {
        let race = ConnectionRace(hasTailscale: true, hasLocal: true)
        #expect(race.startsLocal(at: 1.5 + 8))
        #expect(!race.localTimedOut(at: 1.5 + 7.9))
        #expect(race.localTimedOut(at: 1.5 + 8))

        let localOnly = ConnectionRace(hasTailscale: false, hasLocal: true)
        #expect(!localOnly.localTimedOut(at: 7.9))
        #expect(localOnly.localTimedOut(at: 8))
    }

    /// The clock matters while the home network has yet to start, time out
    /// or sit out its hold. Once it has failed, only Tailscale's own answer
    /// or failure is left, and nothing needs polling.
    @Test func theClockStopsMatteringOnceLocalHasFailed() {
        var race = ConnectionRace(hasTailscale: true, hasLocal: true)
        #expect(race.waitsOnClock)
        _ = race.welcomed(.local, at: 2)
        #expect(race.waitsOnClock)
        _ = race.tick(at: 2.5)
        #expect(!race.waitsOnClock)

        var failed = ConnectionRace(hasTailscale: true, hasLocal: true)
        _ = failed.failed(.local)
        #expect(!failed.waitsOnClock)

        var tailscaleFirst = ConnectionRace(hasTailscale: true, hasLocal: true)
        _ = tailscaleFirst.failed(.tailscale)
        #expect(tailscaleFirst.waitsOnClock)

        let tailscaleOnly = ConnectionRace(hasTailscale: true, hasLocal: false)
        #expect(!tailscaleOnly.waitsOnClock)
    }

    // MARK: The relay

    /// Away from home with no Tailscale: the home network gets a moment,
    /// then the relay starts, answers, and wins after a short hold.
    @Test func theRelayWinsWhenTheHomeNetworkDoesntAnswer() {
        var race = ConnectionRace(hasTailscale: false, hasLocal: true, hasRelay: true)
        #expect(race.startsLocal(at: 0))
        #expect(!race.startsRelay(at: 0.4))
        #expect(race.startsRelay(at: 0.5))
        do { let got = race.welcomed(.relay, at: 0.9); #expect(got == nil) }
        do { let got = race.tick(at: 1.5); #expect(got == nil) }
        do { let got = race.tick(at: 1.6); #expect(got == .relay) }
    }

    /// At home the home network answers during the relay's hold, and wins.
    @Test func aDirectPathThatAnswersInTimeBeatsTheRelay() {
        var race = ConnectionRace(hasTailscale: false, hasLocal: true, hasRelay: true)
        do { let got = race.welcomed(.relay, at: 0.9); #expect(got == nil) }
        do { let got = race.welcomed(.local, at: 1.2); #expect(got == .local) }

        var both = ConnectionRace(hasTailscale: true, hasLocal: true, hasRelay: true)
        #expect(!both.startsRelay(at: 1.4))
        #expect(both.startsRelay(at: 1.5))
        do { let got = both.welcomed(.relay, at: 1.8); #expect(got == nil) }
        do { let got = both.welcomed(.tailscale, at: 2.0); #expect(got == .tailscale) }
    }

    /// The home network answered and is waiting out its hold for Tailscale.
    /// The relay answering in that time doesn't take the connection.
    @Test func theRelayNeverBeatsAHomeNetworkThatHasAnswered() {
        var race = ConnectionRace(hasTailscale: true, hasLocal: true, hasRelay: true)
        do { let got = race.welcomed(.local, at: 1.7); #expect(got == nil) }
        do { let got = race.welcomed(.relay, at: 1.8); #expect(got == nil) }
        do { let got = race.tick(at: 2.6); #expect(got == .local) }
    }

    /// With every direct path out, the relay starts and wins at once.
    @Test func theRelayGoesStraightAwayOnceNothingElseIsLeft() {
        var only = ConnectionRace(hasTailscale: false, hasLocal: false, hasRelay: true)
        #expect(only.startsRelay(at: 0))
        do { let got = only.welcomed(.relay, at: 0.3); #expect(got == .relay) }

        var race = ConnectionRace(hasTailscale: true, hasLocal: true, hasRelay: true)
        do { let got = race.failed(.tailscale); #expect(!got) }
        #expect(!race.startsRelay(at: 0.1))
        do { let got = race.failed(.local); #expect(!got) }
        #expect(race.startsRelay(at: 0.1))
        do { let got = race.welcomed(.relay, at: 0.4); #expect(got == .relay) }
    }

    @Test func everythingFailingIncludesTheRelay() {
        var race = ConnectionRace(hasTailscale: true, hasLocal: true, hasRelay: true)
        do { let got = race.failed(.tailscale); #expect(!got) }
        do { let got = race.failed(.local); #expect(!got) }
        #expect(race.waitsOnClock)
        do { let got = race.failed(.relay); #expect(got) }
        #expect(!race.waitsOnClock)
    }

    /// Without a relay nothing changes.
    @Test func noRelayNoChange() {
        var race = ConnectionRace(hasTailscale: true, hasLocal: true)
        #expect(!race.startsRelay(at: 100))
        do { let got = race.failed(.tailscale); #expect(!got) }
        do { let got = race.failed(.local); #expect(got) }
    }
}
