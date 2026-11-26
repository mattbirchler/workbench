import BenchKit
import SwiftUI

/// The top of the Overview: the day your agents have had. A few totals, a
/// timeline with a row per project, what's happened since you last looked,
/// and where the time went.
struct OverviewDay: View {
    @Environment(AppStore.self) private var store
    @Environment(TerminalManager.self) private var terminals
    @Environment(ProjectIcons.self) private var icons
    let items: [OverviewItem]
    /// 0 for today, 1 for yesterday.
    let daysBack: Int
    /// When you last left the Overview, as it was when you came back.
    let lastLooked: Date?
    /// Say so when the day is empty. Off when the page has its own empty state.
    var showsQuiet = true

    private var activity: DayActivity { .shared }

    private var dayStart: Date {
        let today = Calendar.current.startOfDay(for: .now)
        return Calendar.current.date(byAdding: .day, value: -daysBack, to: today) ?? today
    }

    /// Projects with anything in the day, in sidebar order.
    private var rows: [(project: Project, day: ProjectDay)] {
        guard activity.day == dayStart else { return [] }
        return store.projects.compactMap { project in activity.projects[project.id].map { (project, $0) } }
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 20) {
            if rows.isEmpty {
                if showsQuiet { quiet }
            } else {
                tiles(rows)
                DayTimelinePanel(rows: rows, dayStart: dayStart, isToday: daysBack == 0, readAt: activity.readAt ?? .now, open: open)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        feed(rows).frame(minWidth: 420, maxWidth: .infinity, alignment: .leading)
                        shares(rows).frame(width: 320)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        feed(rows)
                        shares(rows)
                    }
                }
            }
        }
        .task(id: daysBack) {
            UsageLedger.shared.refresh()
            while !Task.isCancelled {
                await activity.refresh(day: dayStart, sources: store.projects.map { DayActivity.Source(id: $0.id, path: $0.path) }, live: live)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// What each open session is doing now, by its session file.
    private var live: [String: SessionLiveState] {
        guard daysBack == 0 else { return [:] }
        var result: [String: SessionLiveState] = [:]
        for item in items {
            guard let session = item.session,
                  let path = session.details?.transcriptPath ?? AgentSessions.transcriptPath(tabID: item.tab.id) else { continue }
            switch item.activity {
            case .working:
                result[path] = .working
            case .waiting:
                let details = session.details
                result[path] = .waiting(since: details?.questionAt ?? .now, question: details?.plainAction ?? details?.action ?? details?.question)
            default:
                break
            }
        }
        return result
    }

    /// A project's name in a row: an agent's worktree goes by its branch,
    /// under its project's icon.
    static func label(_ project: Project) -> String {
        project.isWorktree ? (project.branch ?? project.name) : project.name
    }

    private func open(_ project: Project) {
        // The tab that needs you, or is working, when there is one.
        let tab = items.first { $0.project.id == project.id && $0.activity == .waiting }
            ?? items.first { $0.project.id == project.id && $0.activity != .idle }
        store.selectedProjectID = project.id
        if let tab { store.selectTab(tab.tab.id, in: project.id) }
    }

    private var quiet: some View {
        HStack(spacing: 10) {
            if activity.day != dayStart {
                ProgressView().controlSize(.small)
                Text("Reading the day…")
            } else {
                Image(systemName: "moon.zzz")
                Text(daysBack == 0 ? "No agent has worked yet today. When one does, its day is drawn here." : "No agent worked that day.")
            }
        }
        .font(.ui(size: 13))
        .foregroundStyle(.secondary)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DayPanel())
    }

    // MARK: Totals

    private func tiles(_ rows: [(project: Project, day: ProjectDay)]) -> some View {
        let waiting = activity.waitingTime
        let prompts = activity.promptCount
        let work = DayTile(caption: rows.count == 1 ? "of agent work in 1 project" : "of agent work across \(rows.count) projects") {
            Text(DayText.duration(activity.workingTime))
        }
        let asked = DayTile(caption: prompts == 1 ? "prompt from you" : "prompts from you") {
            Text(prompts.formatted())
        }
        let lines = DayTile(caption: "lines written and removed by agents") {
            HStack(spacing: 8) {
                Text("+\(activity.linesAdded.formatted())").foregroundStyle(Theme.Status.done)
                Text("−\(activity.linesRemoved.formatted())").foregroundStyle(Theme.Status.failed)
            }
        }
        let waited = DayTile(caption: "agents spent waiting on you", tint: waiting >= 60 ? Theme.Status.waiting : nil) {
            Text(DayText.duration(waiting))
        }
        // Four across, or two rows of two in a narrow window.
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                Group { work; asked; lines; waited }.frame(minWidth: 170)
            }
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { work; asked }
                GridRow { lines; waited }
            }
        }
    }

    // MARK: Feed

    private struct Event: Identifiable {
        enum Kind { case started, needsYou, waited, finished }
        var id: String
        var at: Date
        var project: Project
        var kind: Kind
        var text: String?
        var length: TimeInterval = 0
    }

    private func events(_ rows: [(project: Project, day: ProjectDay)]) -> [Event] {
        let readAt = activity.readAt ?? .now
        var events: [Event] = []
        for (project, day) in rows {
            // Work still going. Finished work is in the feed as its finish.
            if daysBack == 0, let span = day.work.last, readAt.timeIntervalSince(span.end) < 2,
               items.contains(where: { $0.project.id == project.id && $0.activity == .working }) {
                events.append(Event(id: "s\(project.id)\(span.start.timeIntervalSince1970)", at: span.start, project: project, kind: .started, text: span.text))
            }
            for wait in day.waits {
                // Still going when the day was last read.
                let stillWaiting = daysBack == 0 && readAt.timeIntervalSince(wait.end) < 2
                    && items.contains { $0.project.id == project.id && $0.activity == .waiting }
                events.append(Event(id: "w\(project.id)\(wait.start.timeIntervalSince1970)", at: wait.start, project: project,
                                    kind: stillWaiting ? .needsYou : .waited, text: wait.text, length: wait.duration))
            }
            // Claude Code's own note for a background report isn't news.
            for finish in day.finishes where finish.summary != "No response requested." {
                events.append(Event(id: "f\(project.id)\(finish.at.timeIntervalSince1970)", at: finish.at, project: project, kind: .finished,
                                    text: finish.summary ?? finish.prompt))
            }
        }
        return events.sorted { $0.at > $1.at }
    }

    private func feed(_ rows: [(project: Project, day: ProjectDay)]) -> some View {
        let all = events(rows)
        let fresh = daysBack == 0 ? lastLooked.map { looked in all.filter { $0.at > looked } } ?? [] : []
        let shown = Array((fresh.isEmpty ? all : fresh).prefix(8))
        let title: String = if let lastLooked, !fresh.isEmpty, lastLooked >= dayStart {
            "Since you last looked, at \(lastLooked.formatted(date: .omitted, time: .shortened))"
        } else if !fresh.isEmpty {
            "Since you last looked"
        } else {
            "Latest"
        }
        return VStack(alignment: .leading, spacing: 10) {
            DayHeading(title)
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, event in
                    if index > 0 { Divider().opacity(0.6) }
                    row(event)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .background(DayPanel())
        }
    }

    private func row(_ event: Event) -> some View {
        let (color, verb): (Color, String) = switch event.kind {
        case .started: (ActivityBackground.working, "is working.")
        case .needsYou: (Theme.Status.waiting, "needs you.")
        case .waited: (Theme.Status.waiting, "waited \(DayText.duration(event.length)) for you.")
        case .finished: (Theme.Status.done, "finished.")
        }
        return Button { open(event.project) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(event.at.formatted(date: .omitted, time: .shortened))
                    .font(.ui(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                Circle().fill(color).frame(width: 8, height: 8)
                (Text("\(OverviewDay.label(event.project)) \(verb)").fontWeight(.semibold)
                    + Text(event.text.map { " \($0)" } ?? "").foregroundStyle(.secondary))
                    .font(.ui(size: 13))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if event.kind == .needsYou {
                    Text("Answer")
                        .font(.ui(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Status.waiting)
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(event.text ?? "Open \(event.project.name)")
    }

    // MARK: Where the day went

    private func shares(_ rows: [(project: Project, day: ProjectDay)]) -> some View {
        let sorted = rows.filter { $0.day.workingTime >= 30 }.sorted { $0.day.workingTime > $1.day.workingTime }
        let top = Array(sorted.prefix(5))
        let rest = sorted.dropFirst(5)
        let most = max(top.first?.day.workingTime ?? 1, 1)
        let cost = daysBack == 0 ? UsageLedger.shared.cost(since: dayStart) : 0
        return VStack(alignment: .leading, spacing: 10) {
            DayHeading("Where the day went")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(top, id: \.project.id) { project, day in
                    HStack(spacing: 10) {
                        ProjectIcon(project: project, image: icons.image(for: project), size: 16)
                        Text(OverviewDay.label(project))
                            .lineLimit(1)
                            .frame(width: 96, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.08))
                                Capsule().fill(ActivityBackground.working)
                                    .frame(width: max(4, geo.size.width * day.workingTime / most))
                            }
                        }
                        .frame(height: 6)
                        Text(DayText.duration(day.workingTime))
                            .font(.ui(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 54, alignment: .trailing)
                    }
                    .font(.ui(size: 13))
                }
                if !rest.isEmpty || cost >= 0.01 {
                    Divider().opacity(0.6)
                    Text(footnote(rest: rest.map(\.day), cost: cost))
                        .font(.ui(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DayPanel())
        }
    }

    private func footnote(rest: [ProjectDay], cost: Double) -> String {
        var parts: [String] = []
        if !rest.isEmpty {
            let time = DayText.duration(rest.reduce(0) { $0 + $1.workingTime })
            parts.append(rest.count == 1 ? "1 more project adds \(time)." : "\(rest.count) more projects add \(time).")
        }
        if cost >= 0.01 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = "USD"
            formatter.maximumFractionDigits = cost < 10 ? 2 : 0
            let dollars = formatter.string(from: NSNumber(value: cost)) ?? "$\(Int(cost))"
            parts.append("Today's work would cost about \(dollars) at API prices.")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Timeline

/// A row per project across the hours of the day: when its agents worked,
/// when they waited on you, and when they finished.
private struct DayTimelinePanel: View {
    @Environment(ProjectIcons.self) private var icons
    let rows: [(project: Project, day: ProjectDay)]
    let dayStart: Date
    let isToday: Bool
    let readAt: Date
    let open: (Project) -> Void

    private static let labelWidth: CGFloat = 168

    /// The hours on show: from the first activity to a little past now,
    /// and never less than six hours.
    private var range: (start: Date, end: Date) {
        let calendar = Calendar.current
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        let spans = rows.flatMap { $0.day.work + $0.day.waits }
        let first = spans.map(\.start).min() ?? readAt
        let last = isToday ? readAt : (spans.map(\.end).max() ?? readAt)
        func hour(_ date: Date, up: Bool) -> Date {
            let floor = calendar.dateInterval(of: .hour, for: date)?.start ?? date
            return up && floor < date ? floor.addingTimeInterval(3600) : floor
        }
        var start = max(dayStart, hour(first, up: false))
        var end = min(dayEnd, hour(last, up: true).addingTimeInterval(isToday ? 3600 : 0))
        let short = 6 * 3600 - end.timeIntervalSince(start)
        if short > 0 {
            start = max(dayStart, start.addingTimeInterval(-short))
            end = min(dayEnd, start.addingTimeInterval(6 * 3600))
        }
        return (start, end)
    }

    var body: some View {
        let range = range
        let length = max(1, range.end.timeIntervalSince(range.start))
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.labelWidth, height: 1)
                axis(range: range, length: length)
            }
            ForEach(rows, id: \.project.id) { project, day in
                HStack(spacing: 0) {
                    Button { open(project) } label: {
                        HStack(spacing: 8) {
                            ProjectIcon(project: project, image: icons.image(for: project), size: 16)
                            Text(OverviewDay.label(project))
                                .font(.ui(size: 13, weight: project.isWorktree ? .regular : .semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: Self.labelWidth, alignment: .leading)
                    .help("Open \(project.name)")
                    lane(day, range: range, length: length)
                }
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.labelWidth, height: 1)
                legend
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .background(DayPanel())
    }

    private func axis(range: (start: Date, end: Date), length: TimeInterval) -> some View {
        let hours = Int((length / 3600).rounded())
        let step = hours > 16 ? 3 : hours > 9 ? 2 : 1
        let ticks = stride(from: 0, to: hours, by: step).map { range.start.addingTimeInterval(Double($0) * 3600) }
        return GeometryReader { geo in
            ForEach(ticks, id: \.self) { tick in
                Text(tick.formatted(.dateTime.hour()))
                    .font(.ui(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: geo.size.width * tick.timeIntervalSince(range.start) / length)
            }
        }
        .frame(height: 15)
        .accessibilityHidden(true)
    }

    private func lane(_ day: ProjectDay, range: (start: Date, end: Date), length: TimeInterval) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x = { (date: Date) in width * min(1, max(0, date.timeIntervalSince(range.start) / length)) }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.045))
                ForEach(day.work, id: \.self) { span in
                    bar(span, color: ActivityBackground.working, x: x)
                }
                ForEach(day.waits, id: \.self) { span in
                    bar(span, color: Theme.Status.waiting, x: x)
                }
                ForEach(Self.stops(in: day), id: \.self) { finish in
                    Circle()
                        .fill(Theme.Status.done)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5))
                        .offset(x: x(finish.at) - 4.5)
                        .help("Finished at \(finish.at.formatted(date: .omitted, time: .shortened))" + (finish.summary.map { "\n\($0)" } ?? ""))
                }
                if isToday {
                    Rectangle()
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: 2, height: 30)
                        .offset(x: x(readAt) - 1)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(DayText.duration(day.workingTime)) working, \(DayText.duration(day.waitingTime)) waiting on you")
    }

    /// The finishes worth a mark: where the work stopped for a while. In a
    /// back-and-forth, every reply is a finish, and a dot on each hides the bars.
    static func stops(in day: ProjectDay) -> [DayFinish] {
        day.finishes.filter { finish in
            !day.work.contains { $0.start > finish.at && $0.start.timeIntervalSince(finish.at) < 10 * 60 }
        }
    }

    private func bar(_ span: DaySpan, color: Color, x: (Date) -> CGFloat) -> some View {
        let left = x(span.start)
        let time = "\(span.start.formatted(date: .omitted, time: .shortened)) to \(span.end.formatted(date: .omitted, time: .shortened))"
        let what = span.kind == .working ? "Worked" : "Waited on you"
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color)
            .frame(width: max(3, x(span.end) - left), height: 16)
            .offset(x: left)
            .help("\(what) \(DayText.duration(span.duration)), \(time)" + (span.text.map { "\n\($0)" } ?? ""))
    }

    private var legend: some View {
        let longest = rows.flatMap { row in row.day.waits.map { (row.project, $0) } }.max { $0.1.duration < $1.1.duration }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                legendItems
                Spacer(minLength: 12)
                if let longest, longest.1.duration >= 5 * 60 { longestWait(longest.0, longest.1) }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 16) { legendItems }
                if let longest, longest.1.duration >= 5 * 60 { longestWait(longest.0, longest.1) }
            }
        }
        .font(.ui(size: 12))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var legendItems: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(ActivityBackground.working).frame(width: 14, height: 8)
            Text("Working")
        }
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(Theme.Status.waiting).frame(width: 14, height: 8)
            Text("Waiting on you")
        }
        HStack(spacing: 6) {
            Circle().fill(Theme.Status.done).frame(width: 9, height: 9)
            Text("Finished")
        }
        if isToday {
            HStack(spacing: 6) {
                Rectangle().fill(Color.primary.opacity(0.85)).frame(width: 2, height: 12)
                Text("Now")
            }
        }
    }

    private func longestWait(_ project: Project, _ wait: DaySpan) -> some View {
        Text("Longest wait: \(OverviewDay.label(project)), \(DayText.duration(wait.duration)) from \(wait.start.formatted(date: .omitted, time: .shortened))")
            .lineLimit(1)
            .help(wait.text ?? "")
    }
}

// MARK: - Pieces

/// The card behind each part of the day.
private struct DayPanel: View {
    var tint: Color?

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                if let tint { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.1)) }
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint?.opacity(0.5) ?? Color.primary.opacity(0.08)))
    }
}

private struct DayTile<Value: View>: View {
    let caption: String
    var tint: Color?
    @ViewBuilder var value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            value
                .font(.ui(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.ui(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
        .background(DayPanel(tint: tint))
        .accessibilityElement(children: .combine)
    }
}

struct DayHeading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.ui(size: 11, weight: .bold))
            .kerning(0.5)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
