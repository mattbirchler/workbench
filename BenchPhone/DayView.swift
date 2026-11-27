import BenchKit
import SwiftUI

/// The day your Mac's agents have had: a few totals, a timeline with a row
/// per project, the latest news, and where the time went. The Mac reads it
/// from its session files and sends it over.
struct DayView: View {
    @Environment(CompanionClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss
    /// 0 for today, 1 for yesterday.
    @State private var daysBack = 0

    private var day: CompanionDay? { client.days[daysBack] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Day", selection: $daysBack) {
                        Text("Today").tag(0)
                        Text("Yesterday").tag(1)
                    }
                    .pickerStyle(.segmented)
                    if let day, !day.rows.isEmpty {
                        tiles(day)
                        timeline(day)
                        feed(day)
                        shares(day)
                    } else {
                        quiet
                    }
                }
                .padding(16)
            }
            .background(PhoneTheme.canvas)
            .navigationTitle("Overview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: daysBack) {
                while !Task.isCancelled {
                    client.loadDay(daysBack: daysBack)
                    try? await Task.sleep(for: .seconds(20))
                }
            }
        }
    }

    private var quiet: some View {
        HStack(spacing: 10) {
            if day == nil {
                ProgressView()
                Text("Reading the day…")
            } else {
                Image(systemName: "moon.zzz")
                Text(daysBack == 0 ? "No agent has worked yet today. When one does, its day is drawn here." : "No agent worked that day.")
            }
        }
        .font(.subheadline)
        .foregroundStyle(PhoneTheme.inkMuted)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dayCard()
    }

    // MARK: Totals

    private func tiles(_ day: CompanionDay) -> some View {
        let waiting = day.waitingTime
        let prompts = day.promptCount
        return Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                tile(day.rows.count == 1 ? "of agent work in 1 project" : "of agent work across \(day.rows.count) projects") {
                    Text(DayText.duration(day.workingTime))
                }
                tile(prompts == 1 ? "prompt from you" : "prompts from you") {
                    Text(prompts.formatted())
                }
            }
            GridRow {
                tile("lines written and removed by agents") {
                    HStack(spacing: 6) {
                        Text("+\(day.linesAdded.formatted())").foregroundStyle(PhoneTheme.added)
                        Text("−\(day.linesRemoved.formatted())").foregroundStyle(PhoneTheme.error)
                    }
                }
                tile("agents spent waiting on you", tint: waiting >= 60 ? PhoneTheme.waiting : nil) {
                    Text(DayText.duration(waiting))
                }
            }
        }
    }

    private func tile(_ caption: String, tint: Color? = nil, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            value()
                .font(.system(.title2, design: .rounded, weight: .semibold).monospacedDigit())
                .foregroundStyle(PhoneTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.footnote)
                .foregroundStyle(PhoneTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .dayCard(tint: tint)
        .accessibilityElement(children: .combine)
    }

    // MARK: Timeline

    private func timeline(_ day: CompanionDay) -> some View {
        let range = day.hours()
        let length = max(1, range.end.timeIntervalSince(range.start))
        let hours = Int((length / 3600).rounded())
        let step = hours > 12 ? 4 : hours > 7 ? 3 : 2
        let ticks = stride(from: 0, to: hours, by: step).map { range.start.addingTimeInterval(Double($0) * 3600) }
        return VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                ForEach(ticks, id: \.self) { tick in
                    Text(tick.formatted(.dateTime.hour()))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(PhoneTheme.inkMuted)
                        .fixedSize()
                        .offset(x: geo.size.width * tick.timeIntervalSince(range.start) / length)
                }
            }
            .frame(height: 14)
            .accessibilityHidden(true)
            ForEach(day.rows) { row in
                Button { open(row) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PhoneTheme.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(DayText.duration(row.day.workingTime))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(PhoneTheme.inkMuted)
                        }
                        lane(row.day, day: day, range: range, length: length)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.name): \(DayText.duration(row.day.workingTime)) working, \(DayText.duration(row.day.waitingTime)) waiting on you")
                .accessibilityHint("Opens the project")
            }
            legend(day)
        }
        .padding(14)
        .dayCard()
    }

    private func lane(_ project: ProjectDay, day: CompanionDay, range: (start: Date, end: Date), length: TimeInterval) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x = { (date: Date) in width * min(1, max(0, date.timeIntervalSince(range.start) / length)) }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(PhoneTheme.ink.opacity(0.06))
                ForEach(project.work, id: \.self) { span in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(PhoneTheme.working)
                        .frame(width: max(3, x(span.end) - x(span.start)), height: 14)
                        .offset(x: x(span.start))
                }
                ForEach(project.waits, id: \.self) { span in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(PhoneTheme.waiting)
                        .frame(width: max(3, x(span.end) - x(span.start)), height: 14)
                        .offset(x: x(span.start))
                }
                ForEach(project.stops, id: \.self) { finish in
                    Circle()
                        .fill(PhoneTheme.done)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(PhoneTheme.surface, lineWidth: 1.5))
                        .offset(x: x(finish.at) - 4.5)
                }
                if day.daysBack == 0 {
                    Rectangle()
                        .fill(PhoneTheme.ink.opacity(0.85))
                        .frame(width: 2, height: 26)
                        .offset(x: x(day.readAt) - 1)
                }
            }
        }
        .frame(height: 20)
    }

    private func legend(_ day: CompanionDay) -> some View {
        let longest = day.rows.flatMap { row in row.day.waits.map { (row.name, $0) } }.max { $0.1.duration < $1.1.duration }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(PhoneTheme.working).frame(width: 14, height: 8)
                    Text("Working")
                }
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(PhoneTheme.waiting).frame(width: 14, height: 8)
                    Text("Waiting on you")
                }
                HStack(spacing: 5) {
                    Circle().fill(PhoneTheme.done).frame(width: 9, height: 9)
                    Text("Finished")
                }
            }
            if let longest, longest.1.duration >= 5 * 60 {
                Text("Longest wait: \(longest.0), \(DayText.duration(longest.1.duration)) from \(longest.1.start.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.caption)
        .foregroundStyle(PhoneTheme.inkMuted)
    }

    // MARK: Feed

    private struct Event: Identifiable {
        enum Kind { case working, needsYou, waited, finished }
        var id: String
        var at: Date
        var row: CompanionDay.Row
        var kind: Kind
        var text: String?
        var length: TimeInterval = 0
    }

    private func events(_ day: CompanionDay) -> [Event] {
        var events: [Event] = []
        for row in day.rows {
            if row.isWorking, let span = row.day.work.last {
                events.append(Event(id: "s\(row.id)\(span.start.timeIntervalSince1970)", at: span.start, row: row, kind: .working, text: span.text))
            }
            for wait in row.day.waits {
                let stillWaiting = row.isWaiting && day.readAt.timeIntervalSince(wait.end) < 2
                events.append(Event(id: "w\(row.id)\(wait.start.timeIntervalSince1970)", at: wait.start, row: row,
                                    kind: stillWaiting ? .needsYou : .waited, text: wait.text, length: wait.duration))
            }
            // Claude Code's own note for a background report isn't news.
            for finish in row.day.finishes where finish.summary != "No response requested." {
                events.append(Event(id: "f\(row.id)\(finish.at.timeIntervalSince1970)", at: finish.at, row: row, kind: .finished,
                                    text: finish.summary ?? finish.prompt))
            }
        }
        return events.sorted { $0.at > $1.at }
    }

    private func feed(_ day: CompanionDay) -> some View {
        let shown = Array(events(day).prefix(8))
        return VStack(alignment: .leading, spacing: 8) {
            heading("Latest")
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, event in
                    if index > 0 { Divider().overlay(PhoneTheme.hairline) }
                    eventRow(event)
                }
            }
            .padding(.horizontal, 14)
            .dayCard()
        }
        .opacity(shown.isEmpty ? 0 : 1)
    }

    private func eventRow(_ event: Event) -> some View {
        let (color, verb): (Color, String) = switch event.kind {
        case .working: (PhoneTheme.working, "is working.")
        case .needsYou: (PhoneTheme.waiting, "needs you.")
        case .waited: (PhoneTheme.waiting, "waited \(DayText.duration(event.length)) for you.")
        case .finished: (PhoneTheme.done, "finished.")
        }
        return Button { open(event.row) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    (Text("\(event.row.name) \(verb)").fontWeight(.semibold).foregroundStyle(PhoneTheme.ink)
                        + Text(event.text.map { " \($0)" } ?? "").foregroundStyle(PhoneTheme.inkMuted))
                        .font(.subheadline)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Text(event.at.formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PhoneTheme.inkMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the project")
    }

    // MARK: Where the day went

    private func shares(_ day: CompanionDay) -> some View {
        let sorted = day.rows.filter { $0.day.workingTime >= 30 }.sorted { $0.day.workingTime > $1.day.workingTime }
        let top = Array(sorted.prefix(5))
        let rest = sorted.dropFirst(5)
        let most = max(top.first?.day.workingTime ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            heading("Where the day went")
            VStack(alignment: .leading, spacing: 12) {
                ForEach(top) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.name)
                                .font(.subheadline)
                                .foregroundStyle(PhoneTheme.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(DayText.duration(row.day.workingTime))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(PhoneTheme.inkMuted)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(PhoneTheme.ink.opacity(0.08))
                                Capsule().fill(PhoneTheme.working)
                                    .frame(width: max(4, geo.size.width * row.day.workingTime / most))
                            }
                        }
                        .frame(height: 6)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let note = footnote(rest: rest.map(\.day), cost: day.cost) {
                    Divider().overlay(PhoneTheme.hairline)
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(PhoneTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dayCard()
        }
        .opacity(top.isEmpty ? 0 : 1)
    }

    private func footnote(rest: [ProjectDay], cost: Double?) -> String? {
        var parts: [String] = []
        if !rest.isEmpty {
            let time = DayText.duration(rest.reduce(0) { $0 + $1.workingTime })
            parts.append(rest.count == 1 ? "1 more project adds \(time)." : "\(rest.count) more projects add \(time).")
        }
        if let cost, cost >= 0.01 {
            let dollars = cost.formatted(.currency(code: "USD").precision(.fractionLength(cost < 10 ? 2 : 0)))
            parts.append("Today's work would cost about \(dollars) at API prices.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Pieces

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.bold))
            .kerning(0.5)
            .foregroundStyle(PhoneTheme.inkMuted)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func open(_ row: CompanionDay.Row) {
        // Only projects still on the Mac's list can be opened.
        guard client.snapshot?.projects.contains(where: { $0.id == row.id }) == true else { return }
        dismiss()
        navigator.open(projectID: row.id, sessionID: nil)
    }
}

private extension View {
    func dayCard(tint: Color? = nil) -> some View {
        background {
            RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous)
                .fill(PhoneTheme.surface)
                .overlay {
                    if let tint { RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous).fill(tint.opacity(0.12)) }
                }
                .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous).strokeBorder(tint?.opacity(0.5) ?? PhoneTheme.hairline))
        }
    }
}
