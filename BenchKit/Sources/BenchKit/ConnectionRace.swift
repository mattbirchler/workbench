import Foundation

/// How the client reached the Mac.
public enum ConnectionPath: Sendable, Equatable {
    case tailscale, local, relay
}

/// Picks between Tailscale, the home network and the relay. Tailscale goes
/// first and wins whenever it answers in time; the home network starts
/// after a head start and wins only once Tailscale has had a moment more to
/// answer. The relay is the fallback: it starts last and wins only when
/// neither direct path answers shortly after it does, since they're faster
/// and the relay's traffic costs something.
/// Pure: the client feeds it times and results.
public struct ConnectionRace: Sendable {
    /// How long Tailscale goes alone before the home network starts too.
    public static let headStart: TimeInterval = 1.5
    /// How long the home network gets, from when it starts, before it
    /// counts as failed. Bonjour finds nothing on Wi-Fi that keeps devices
    /// apart, and that mustn't hang the client.
    public static let localTimeout: TimeInterval = 8
    /// After the home network answers, how long Tailscale still gets.
    public static let holdForTailscale: TimeInterval = 0.3

    /// With only the home network to wait for, how long it goes alone
    /// before the relay starts too. Bonjour at home answers well inside it.
    public static let relayHeadStart: TimeInterval = 0.5
    /// After the relay answers, how long a direct path still gets.
    public static let holdForDirect: TimeInterval = 0.7

    public let hasTailscale: Bool
    public let hasLocal: Bool
    public let hasRelay: Bool
    private var relayFailed = false
    private var relayWelcomedAt: TimeInterval?
    private var tailscaleFailed = false
    private var localFailed = false
    private var localWelcomedAt: TimeInterval?
    private var decided: ConnectionPath?

    public init(hasTailscale: Bool, hasLocal: Bool, hasRelay: Bool = false) {
        self.hasTailscale = hasTailscale
        self.hasLocal = hasLocal
        self.hasRelay = hasRelay
    }

    /// True once neither direct path can still answer.
    private var directIsOut: Bool {
        (!hasTailscale || tailscaleFailed) && (!hasLocal || localFailed)
    }

    /// When the relay starts: right away with no direct path left, with
    /// the home network when Tailscale is still trying, and a moment after
    /// the home network when that's all there is.
    public func startsRelay(at elapsed: TimeInterval) -> Bool {
        guard hasRelay else { return false }
        if directIsOut { return true }
        return elapsed >= (hasTailscale && !tailscaleFailed ? Self.headStart : Self.relayHeadStart)
    }

    /// When the home network starts: right away without Tailscale or once
    /// it has failed, after the head start otherwise.
    private var localStart: TimeInterval {
        hasTailscale && !tailscaleFailed ? Self.headStart : 0
    }

    public func startsLocal(at elapsed: TimeInterval) -> Bool {
        hasLocal && elapsed >= localStart
    }

    /// True once the home network has had all its time. Measured from the
    /// head start, so a Tailscale failure that starts it early doesn't
    /// shorten it.
    public func localTimedOut(at elapsed: TimeInterval) -> Bool {
        elapsed >= (hasTailscale ? Self.headStart : 0) + Self.localTimeout
    }

    /// A path finished its hello. Returns the winner once there is one.
    public mutating func welcomed(_ path: ConnectionPath, at elapsed: TimeInterval) -> ConnectionPath? {
        if let decided { return decided }
        switch path {
        case .tailscale:
            decided = .tailscale
        case .local:
            localWelcomedAt = elapsed
            return tick(at: elapsed)
        case .relay:
            relayWelcomedAt = elapsed
            return tick(at: elapsed)
        }
        return decided
    }

    /// Lets the hold for Tailscale run out.
    public mutating func tick(at elapsed: TimeInterval) -> ConnectionPath? {
        if let decided { return decided }
        if let localWelcomedAt {
            if !hasTailscale || tailscaleFailed || elapsed - localWelcomedAt >= Self.holdForTailscale {
                decided = .local
            }
            // The home network has answered, so the relay isn't needed
            // even if it answered first.
            return decided
        }
        if let relayWelcomedAt, directIsOut || elapsed - relayWelcomedAt >= Self.holdForDirect {
            decided = .relay
        }
        return decided
    }

    /// True while time alone can still move the race on: the home network
    /// has yet to start, time out, or sit out its hold for Tailscale. Once
    /// it has failed, only Tailscale answering or failing can end it.
    public var waitsOnClock: Bool {
        decided == nil && ((hasLocal && !localFailed) || (hasRelay && !relayFailed))
    }

    /// A path gave up. True when every path there was has.
    public mutating func failed(_ path: ConnectionPath) -> Bool {
        switch path {
        case .tailscale: tailscaleFailed = true
        case .local: localFailed = true
        case .relay: relayFailed = true
        }
        return directIsOut && (!hasRelay || relayFailed)
    }
}
