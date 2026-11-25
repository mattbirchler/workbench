#if os(macOS)
import AppKit
#endif
import SwiftUI

/// Claude's checklist, a line per step: a green check when done, an orange
/// ring on the step under way (with how long it's been going), an empty
/// ring for the rest. A long list keeps the last few finished steps and
/// counts the earlier ones.
public struct ChecklistRows: View {
    @Environment(\.companionPalette) private var palette
    public let items: [ChecklistItem]
    public var textSize: CGFloat
    public var spacing: CGFloat
    /// Long steps wrap when true. When false they stay on one line with the
    /// full text on hover: a wrapping list inside a Mac inspector column
    /// sends its layout into a loop that leaves the window blank.
    public var wraps: Bool
    /// Colors from the environment's palette, or the system's.
    public var usesPalette: Bool

    public init(items: [ChecklistItem], textSize: CGFloat = 12, spacing: CGFloat = 5, wraps: Bool = true,
                usesPalette: Bool = false) {
        self.items = items
        self.textSize = textSize
        self.spacing = spacing
        self.wraps = wraps
        self.usesPalette = usesPalette
    }

    private var ink: Color { usesPalette ? palette.ink : .primary }
    private var muted: Color { usesPalette ? palette.inkMuted : .secondary }

    public var body: some View {
        let (hidden, shown) = Self.trimmed(items)
        VStack(alignment: .leading, spacing: spacing) {
            if hidden > 0 {
                Text(hidden == 1 ? "1 earlier step done" : "\(hidden) earlier steps done")
                    .font(.system(size: textSize - 1))
                    .foregroundStyle(muted)
                    .padding(.leading, textSize + 6)
            }
            ForEach(shown) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    mark(item.status)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.label)
                            .font(.system(size: textSize, weight: item.status == .inProgress ? .semibold : .regular))
                            .strikethrough(item.status == .completed, color: muted)
                            .foregroundStyle(item.status == .completed ? muted : ink)
                            .lineLimit(wraps ? nil : 1)
                            .truncationMode(.tail)
                            .help(item.label)
                        if item.status == .inProgress, let started = item.startedAt {
                            ActiveTimer(since: started, activity: .working)
                                .font(.system(size: textSize - 1))
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.label), \(Self.spoken(item.status))")
            }
        }
    }

    private func mark(_ status: ChecklistItem.Status) -> some View {
        Group {
            switch status {
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.done)
            case .inProgress:
                Image(systemName: "smallcircle.filled.circle").foregroundStyle(palette.working)
            case .pending:
                Image(systemName: "circle").foregroundStyle(usesPalette ? AnyShapeStyle(palette.inkMuted.opacity(0.6)) : AnyShapeStyle(.tertiary))
            }
        }
        .font(.system(size: textSize + 1, weight: .medium))
    }

    /// Lists over 8 steps keep 2 finished ones and everything after.
    static func trimmed(_ items: [ChecklistItem]) -> (hidden: Int, shown: [ChecklistItem]) {
        guard items.count > 8 else { return (0, items) }
        let doneIndexes = items.indices.filter { items[$0].status == .completed }
        let keepFrom = doneIndexes.count > 2 ? doneIndexes[doneIndexes.count - 2] : 0
        let hidden = items[..<keepFrom].filter { $0.status == .completed }.count
        let shown = items.enumerated().filter { $0.offset >= keepFrom || $0.element.status != .completed }.map(\.element)
        return (hidden, shown)
    }

    private static func spoken(_ status: ChecklistItem.Status) -> String {
        switch status {
        case .completed: "done"
        case .inProgress: "in progress"
        case .pending: "to do"
        }
    }
}

/// A thin bar showing how much of the checklist is done.
public struct ChecklistProgressBar: View {
    @Environment(\.companionPalette) private var palette
    public let progress: Double
    public var height: CGFloat
    public var tint: Color?
    /// The empty part of the bar, or nil for the system's faint gray.
    public var track: Color?

    public init(progress: Double, height: CGFloat = 4, tint: Color? = nil, track: Color? = nil) {
        self.progress = progress
        self.height = height
        self.tint = tint
        self.track = track
    }

    public var body: some View {
        // Scaled rather than measured, so it never feeds back into layout.
        Capsule().fill(track ?? Color.primary.opacity(0.08))
            .overlay(alignment: .leading) {
                Capsule().fill(tint ?? palette.done)
                    .scaleEffect(x: min(1, max(0, progress)), y: 1, anchor: .leading)
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
        .animation(.snappy, value: progress)
        .accessibilityElement()
        .accessibilityLabel("Checklist progress")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }
}

/// A busy row's checklist, under its timer line: one segment per step,
/// done steps filled in the row's activity color, the current one glowing,
/// and "3/7" at the end. Long lists become one smooth bar.
public struct ChecklistStepsBar: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.motionLevel) private var motionLevel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// The iPhone app has no Motion setting, so the system's is checked too.
    private var reduceMotion: Bool { systemReduceMotion || motionLevel == .still }
    public let items: [ChecklistItem]
    public let activity: ActivityKind

    public init(items: [ChecklistItem], activity: ActivityKind) {
        self.items = items
        self.activity = activity
    }

    private var tint: Color { palette.color(for: activity) ?? palette.done }
    private static let segmentLimit = 12

    public var body: some View {
        HStack(spacing: 7) {
            Group {
                if items.count <= Self.segmentLimit {
                    HStack(spacing: 2) {
                        ForEach(items) { item in segment(item.status) }
                    }
                } else {
                    // Scaled rather than measured, so it never feeds back into layout.
                    Capsule().fill(Color.primary.opacity(0.1))
                        .overlay(alignment: .leading) {
                            Capsule().fill(tint)
                                .scaleEffect(x: min(1, max(0, items.progress)), y: 1, anchor: .leading)
                        }
                }
            }
            .frame(height: 4)
            .frame(maxWidth: .infinity)
            Text("\(items.doneCount)/\(items.count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
                .fixedSize()
        }
        .animation(.snappy, value: items.map(\.status))
        .accessibilityElement()
        .accessibilityLabel("Checklist")
        .accessibilityValue("\(items.doneCount) of \(items.count) steps done")
    }

    @ViewBuilder
    private func segment(_ status: ChecklistItem.Status) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        switch status {
        case .completed:
            shape.fill(tint)
        case .inProgress:
            #if os(macOS)
            // Breathes in Core Animation; a SwiftUI animation that never
            // ends kept the window laying out on every frame.
            shape.fill(tint.opacity(reduceMotion ? 0.5 : 0.3))
                .overlay { if !reduceMotion { LayerMotion(kind: .breathing(NSColor(tint), from: 0, to: 0.35, period: 2.2), cornerRadius: 2) } }
                .overlay(shape.strokeBorder(tint.opacity(0.6), lineWidth: 0.5))
            #else
            // Drawn from the clock, like ActivityMark on iOS, so no
            // animation that never ends sits inside a list row.
            if reduceMotion {
                shape.fill(tint.opacity(0.5))
                    .overlay(shape.strokeBorder(tint.opacity(0.6), lineWidth: 0.5))
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
                    let glow = 0.5 - 0.5 * cos(phase * 2 * .pi)
                    shape.fill(tint.opacity(0.3 + 0.35 * glow))
                        .overlay(shape.strokeBorder(tint.opacity(0.6), lineWidth: 0.5))
                }
            }
            #endif
        case .pending:
            shape.fill(Color.primary.opacity(0.1))
        }
    }
}

extension CompanionProject {
    /// The checklist to show for the project: the one from the session
    /// behind its activity, else any session that has one.
    public var checklist: [ChecklistItem]? {
        let withList = sessions.filter { !($0.checklist ?? []).isEmpty }
        return (withList.first { $0.activity == activity } ?? withList.first)?.checklist
    }
}
