import BenchKit
import Observation
import SwiftUI

/// The Commit, Push and Open PR sent from here, by project. Kept while the
/// app runs, so leaving Changes and coming back still says how the last
/// one went.
@MainActor
@Observable
final class ChangesActionRuns {
    static let shared = ChangesActionRuns()
    var byProject: [UUID: ChangesActionRun] = [:]
}

/// Under the Changes list: what to do with the work next. One main button
/// for the next step (Commit, then Push, then Open PR) with the others
/// beside it, and above them how the last one is going or went. The agent
/// on the Mac does the git work, as the Mac's own buttons have it do.
struct ChangesActionBar: View {
    @Environment(CompanionClient.self) private var client
    @Environment(Navigator.self) private var navigator
    let projectID: UUID

    private var project: CompanionProject? { client.snapshot?.projects.first { $0.id == projectID } }
    private var changes: ChangesSnapshot? { client.changes[projectID] }
    private var run: ChangesActionRun? { ChangesActionRuns.shared.byProject[projectID] }
    private var session: CompanionSession? { project?.sessions.first { $0.id == run?.sessionID } }

    /// What can be done now. Nothing while one is under way, or while the
    /// list is an old one with no Mac to send to.
    private var actions: [ChangesAction] {
        guard let changes, let project, run?.isOver != false, !client.isShowingSaved else { return [] }
        return ChangesAction.available(in: changes, pullRequest: project.pullRequest)
    }

    /// The project's pull request, shown while no run has more to say.
    private var pullRequest: CompanionPullRequest? {
        if case .succeeded(.pullRequest)? = run?.phase { return nil }
        return project?.pullRequest
    }

    var body: some View {
        let actions = actions
        VStack(spacing: 10) {
            if let run {
                ChangesRunCard(run: run, session: session, macName: client.macName,
                               openSession: session.map { session in { navigator.open(projectID: projectID, sessionID: session.id) } },
                               dismiss: { ChangesActionRuns.shared.byProject[projectID] = nil })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let pullRequest {
                PullRequestCard(number: pullRequest.number, title: pullRequest.title, detail: Self.checks(pullRequest), url: pullRequest.url)
            }
            if run?.phase == .needsYou, let session {
                Button { navigator.open(projectID: projectID, sessionID: session.id) } label: {
                    Label("Answer \(session.agentTitle)", systemImage: "arrow.turn.down.right")
                }
                .buttonStyle(.phonePrimary)
            } else if !actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                        ChangesActionButton(action: action, isMain: index == 0) { start(action) }
                    }
                }
            }
        }
        .animation(.snappy, value: run?.phase)
        .padding(.horizontal, 16)
        .padding(.top, isEmpty(actions) ? 0 : 10)
        .padding(.bottom, isEmpty(actions) ? 0 : 8)
        .frame(maxWidth: .infinity)
        .background { if !isEmpty(actions) { PhoneTheme.canvas.ignoresSafeArea(edges: .bottom) } }
        .overlay(alignment: .top) { if !isEmpty(actions) { PhoneTheme.hairline.frame(height: 1) } }
        // Sent, then how it came out: the same taps as starting an agent
        // and answering one.
        .sensoryFeedback(trigger: run?.phase) { old, new in
            switch new {
            case .running?: old == .needsYou ? nil : .impact(weight: .medium)
            case .needsYou?: .warning
            case .succeeded?: .success
            case .failed?: .error
            case nil: nil
            }
        }
        .onChange(of: project, initial: true) { _, _ in refresh() }
        .onChange(of: changes) { _, _ in refresh() }
        .onChange(of: run?.sessionID.flatMap { client.sendProblems[$0] }) { _, _ in refresh() }
        .onChange(of: client.lastProblem) { _, _ in refresh() }
        // The agent stopped: read the repo now rather than on the Mac's
        // next pass, where it can.
        .onChange(of: run?.isSettling) { _, settling in
            if settling == true, client.canControlBranches { client.refreshChanges(projectID: projectID) }
        }
        // Nothing arrives when nothing changes, so give up on the clock.
        .task(id: run?.nextCheck) {
            guard let date = run?.nextCheck else { return }
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            refresh()
        }
        #if DEBUG
        // For screenshots: BENCH_CHANGES_TAP=commit|push|pullRequest taps
        // that button once the list is in, and "commit,push" taps the
        // second when the first has gone through.
        .task(id: actions) {
            let wanted = (ProcessInfo.processInfo.environment["BENCH_CHANGES_TAP"] ?? "").split(separator: ",").compactMap { ChangesAction(rawValue: String($0)) }
            guard Self.debugTaps < wanted.count, actions.contains(wanted[Self.debugTaps]) else { return }
            try? await Task.sleep(for: .seconds(Self.debugTaps == 0 ? 1 : 2.5))
            guard !Task.isCancelled else { return }
            Self.debugTaps += 1
            start(wanted[Self.debugTaps - 1])
        }
        #endif
    }

    #if DEBUG
    private static var debugTaps = 0
    #endif

    private func isEmpty(_ actions: [ChangesAction]) -> Bool {
        run == nil && pullRequest == nil && actions.isEmpty
    }

    /// "3 of 3 checks passed", for the pull request's card.
    private static func checks(_ pr: CompanionPullRequest) -> String? {
        switch pr.state {
        case .merged: return "Merged"
        case .closed: return "Closed"
        case .draft: return "Draft"
        case .open: break
        }
        switch pr.checks {
        case .failing: return pr.failingNames.isEmpty ? "Checks failing" : "Failing: \(pr.failingNames.joined(separator: ", "))"
        case .pending: return pr.totalCount > 0 ? "\(pr.passedCount) of \(pr.totalCount) checks passed so far" : "Checks running"
        case .passing: return pr.totalCount > 0 ? "\(pr.passedCount) of \(pr.totalCount) checks passed" : "Checks passed"
        case .none: return nil
        }
    }

    /// Sends the action's words to an agent in the project: the session
    /// that's open here, or else its newest that can take a message, or a
    /// new tab when it has none.
    private func start(_ action: ChangesAction) {
        guard let project, let changes else { return }
        let runs = ChangesActionRuns.shared
        guard client.status == .connected else {
            runs.byProject[projectID] = ChangesActionRun(action: action, problem: "Not connected to \(client.macName ?? "your Mac").")
            return
        }
        let prompt = action.filledPrompt(for: changes)
        let sessions = project.sessions
        guard let target = sessions.first(where: { $0.id == navigator.selectedSession && $0.canReply })
                ?? sessions.last(where: \.canReply) ?? sessions.last else {
            client.newClaudeTab(projectID: projectID, prompt: prompt)
            runs.byProject[projectID] = ChangesActionRun(action: action, sessionID: nil, project: project, changes: changes)
            return
        }
        guard target.canReply else {
            runs.byProject[projectID] = ChangesActionRun(
                action: action, problem: target.replyProblem ?? "\(target.agentTitle) can't take a message right now.")
            return
        }
        client.reply(sessionID: target.id, text: prompt)
        runs.byProject[projectID] = ChangesActionRun(action: action, sessionID: target.id, project: project, changes: changes)
    }

    /// Reads how the run stands from what the Mac last sent.
    private func refresh() {
        guard var run, !run.isOver else { return }
        run.update(project: project, changes: changes,
                   sendProblem: run.sessionID.flatMap { client.sendProblems[$0] },
                   startProblem: run.sessionID == nil ? client.lastProblem : nil)
        if run != self.run { ChangesActionRuns.shared.byProject[projectID] = run }
    }
}

/// One of the bar's buttons: the next step filled and as wide as there's
/// room for, the others quiet at the size of their words.
private struct ChangesActionButton: View {
    let action: ChangesAction
    let isMain: Bool
    let tap: () -> Void

    var body: some View {
        if isMain {
            Button(action: tap) { Label(action.name, systemImage: action.symbol) }
                .buttonStyle(.phonePrimary)
                .accessibilityHint(hint)
        } else {
            Button(action: tap) {
                Text(action.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PhoneTheme.ink)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                    .background(PhoneTheme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(PhoneTheme.hairline))
                    .contentShape(Capsule())
            }
            .buttonStyle(.pressable)
            .accessibilityHint(hint)
        }
    }

    private var hint: String {
        switch action {
        case .commit: "Asks the agent on your Mac to commit these changes"
        case .push: "Asks the agent on your Mac to push this branch"
        case .pullRequest: "Asks the agent on your Mac to open a pull request"
        }
    }
}

/// How a Commit, Push or Open PR is going, or how it went.
private struct ChangesRunCard: View {
    let run: ChangesActionRun
    let session: CompanionSession?
    let macName: String?
    /// Shows the session doing the work, when there is one.
    var openSession: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        if case .succeeded(.pullRequest(let number, let title, let url)) = run.phase {
            PullRequestCard(number: number, title: title ?? "Pull request opened", detail: title == nil ? nil : "Opened just now",
                            url: url, isNew: true, dismiss: dismiss)
        } else {
            HStack(alignment: .top, spacing: 12) {
                mark
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PhoneTheme.ink)
                    if let detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(isFailure ? PhoneTheme.error : PhoneTheme.inkMuted)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !run.isOver || isFailure, let openSession, let session {
                        Button(action: openSession) {
                            HStack(spacing: 3) {
                                Text(run.isOver ? "See What \(session.agentTitle) Said" : "Watch \(session.agentTitle) Work")
                                Image(systemName: "chevron.right").imageScale(.small)
                            }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(PhoneTheme.accent)
                            .padding(.top, 4)
                            .touchArea(vertical: 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 4)
                if run.isOver { CardDismissButton(action: dismiss) }
            }
            .padding(14)
            .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous)
                .strokeBorder(isFailure ? PhoneTheme.error.opacity(0.35) : PhoneTheme.hairline))
            .accessibilityElement(children: .contain)
        }
    }

    private var isFailure: Bool {
        if case .failed = run.phase { true } else { false }
    }

    @ViewBuilder
    private var mark: some View {
        switch run.phase {
        case .running: ActivityMark(activity: .working, size: 18)
        case .needsYou: ActivityMark(activity: .waiting, size: 16)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(PhoneTheme.done)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.body).foregroundStyle(PhoneTheme.error)
        }
    }

    private var title: String {
        let agent = session?.agentTitle ?? "Claude"
        switch (run.phase, run.action) {
        case (.running, .commit): return "Committing"
        case (.running, .push): return "Pushing"
        case (.running, .pullRequest): return "Opening a pull request"
        case (.needsYou, _): return "\(agent) needs you"
        case (.succeeded(.committed), _): return "Committed"
        case (.succeeded(.pushed), _): return "Pushed"
        case (.succeeded(.pullRequest), _): return "Pull request opened"
        case (.succeeded(.finished), _): return "\(agent) finished"
        case (.failed, .commit): return "Couldn't commit"
        case (.failed, .push): return "Couldn't push"
        case (.failed, .pullRequest): return "Couldn't open a pull request"
        }
    }

    private var detail: String? {
        switch run.phase {
        case .running:
            if run.isSettling { return "Checking how it went" }
            if let session, [.working, .remoteWorking].contains(session.activity), let doing = session.actionText { return doing }
            return "Sent to \(session?.agentTitle ?? "Claude") on \(macName ?? "your Mac")"
        case .needsYou:
            return session?.question ?? "It stopped to ask you something."
        case .succeeded(.committed(let subject)): return subject
        case .succeeded(.pushed(let upstream)): return upstream.map { "To \($0)" }
        case .succeeded(.finished(let summary)): return summary
        case .succeeded(.pullRequest): return nil
        case .failed(let why): return why
        }
    }
}

/// A pull request as a card: its number, title and how it stands. Tapping
/// it opens the pull request.
private struct PullRequestCard: View {
    @Environment(\.openURL) private var openURL
    let number: Int?
    let title: String
    var detail: String?
    let url: URL
    /// Just opened from here: a green check rather than the branch mark.
    var isNew = false
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Button { openURL(url) } label: {
                HStack(spacing: 12) {
                    Image(systemName: isNew ? "checkmark.circle.fill" : "arrow.triangle.pull")
                        .font(isNew ? .title3 : .body.weight(.semibold))
                        .foregroundStyle(PhoneTheme.done)
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let number {
                                Text("#\(number)")
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(PhoneTheme.accent)
                            }
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PhoneTheme.ink)
                                .lineLimit(1)
                        }
                        if let detail {
                            Text(detail).font(.footnote).foregroundStyle(PhoneTheme.inkMuted).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PhoneTheme.inkMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel([number.map { "Pull request \($0)" }, title, detail].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("Opens the pull request")
            if let dismiss { CardDismissButton(action: dismiss) }
        }
        .padding(14)
        .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous).strokeBorder(PhoneTheme.hairline))
    }
}

/// The small x that puts a finished card away.
private struct CardDismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(PhoneTheme.inkMuted)
                .frame(width: 24, height: 24)
                .touchArea(horizontal: 10, vertical: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
    }
}
