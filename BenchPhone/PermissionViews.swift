import BenchKit
import SwiftUI

/// What an agent is asking to do, and the buttons that answer it. Shared
/// by the card above the message box and the rows of the project list, so
/// allowing something looks and feels the same from either.

extension CompanionSession {
    /// The question without the command on the end of it ("Claude wants
    /// to run"), for where the command is shown in a block of its own.
    var permissionTitle: String {
        let fallback = "\(agentTitle) needs your permission"
        guard let question, !question.isEmpty else { return fallback }
        guard let command, !command.isEmpty, let colon = question.firstIndex(of: ":") else { return question }
        let title = question[..<colon].trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? fallback : title
    }

    /// The one question that can be answered with a tap: a single choice
    /// between a few plain options. Anything with previews, several
    /// answers or a plan to read is answered in the chat.
    var quickQuestion: CompanionQuestion? {
        guard let questions, questions.count == 1, let question = questions.first,
              !question.multiSelect, !question.hasPreviews,
              question.question != CompanionQuestion.planApprovalText,
              (2...4).contains(question.options.count) else { return nil }
        return question
    }
}

/// A command as it will run: monospaced, on a block of its own. All of
/// it, before you allow it: a long one scrolls rather than hiding its
/// later lines, unless `lineLimit` asks for a short look.
struct CommandBlock: View {
    let command: String
    /// A few lines only, for a row in a list. Nil shows it all.
    var lineLimit: Int?
    /// How tall the command is when laid out at the block's width.
    @State private var textHeight: CGFloat = 0

    var body: some View {
        Group {
            if let lineLimit {
                text.lineLimit(lineLimit)
            } else {
                // Sized from the text's own height: a frame with only a
                // most-height takes all it's offered.
                ScrollView {
                    text
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
                }
                .scrollDisabled(textHeight <= 150)
                .frame(height: min(max(textHeight, 16), 150))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(PhoneTheme.raised, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.control, style: .continuous).strokeBorder(PhoneTheme.hairline))
        .accessibilityLabel("Command: \(command)")
    }

    private var text: some View {
        Text(command)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(PhoneTheme.ink.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Deny and Allow, side by side. Allow is the larger and sits on the
/// right, under the thumb. What you tapped shows at once, since the Mac
/// can take a second to act on it.
struct PermissionButtons: View {
    /// Anything new here while the buttons are up means the Mac is asking
    /// again (or never heard), so they come back.
    let session: CompanionSession
    /// Smaller, for a row in the project list.
    var compact = false
    let answer: (Bool) -> Void
    /// What you just tapped, shown until the Mac takes the card away.
    @State private var chosen: Bool?

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                Button { choose(false) } label: { Text("Deny") }
                    .buttonStyle(AnswerButtonStyle(fill: PhoneTheme.ink.opacity(0.1), ink: PhoneTheme.ink, compact: compact))
                    .frame(maxWidth: compact ? 96 : 120)
                Button { choose(true) } label: { Text("Allow") }
                    .buttonStyle(AnswerButtonStyle(fill: PhoneTheme.palette.done, ink: .white, compact: compact))
            }
            .opacity(chosen == nil ? 1 : 0)
            .disabled(chosen != nil)
            .accessibilityHidden(chosen != nil)
            if let chosen {
                Label(chosen ? "Allowed" : "Denied", systemImage: chosen ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font((compact ? Font.subheadline : .body).weight(.semibold))
                    .foregroundStyle(chosen ? PhoneTheme.palette.done : PhoneTheme.inkMuted)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: chosen)
        .sensoryFeedback(trigger: chosen) { _, new in
            switch new {
            case true?: .success
            case false?: .impact(weight: .light)
            case nil: nil
            }
        }
        .onChange(of: session) { chosen = nil }
        .task(id: chosen) {
            guard chosen != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { chosen = nil }
        }
    }

    private func choose(_ allow: Bool) {
        chosen = allow
        answer(allow)
    }
}

/// A capsule that answers something: filled, and as wide as it's allowed.
struct AnswerButtonStyle: ButtonStyle {
    let fill: Color
    let ink: Color
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font((compact ? Font.subheadline : .body).weight(.semibold))
            .foregroundStyle(ink)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: compact ? 38 : 46)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The options of a question you can answer with one tap, for a row in
/// the project list. The one you tapped is marked until the Mac moves on.
struct QuickAnswers: View {
    let session: CompanionSession
    let question: CompanionQuestion
    let pick: (Int) -> Void
    @State private var chosen: Int?

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                Button {
                    chosen = index
                    pick(index)
                } label: {
                    HStack(spacing: 8) {
                        Text(option.label)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(PhoneTheme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if chosen == index {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(PhoneTheme.palette.done)
                                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                    .background(PhoneTheme.raised, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.control, style: .continuous)
                        .strokeBorder(chosen == index ? PhoneTheme.palette.done.opacity(0.6) : PhoneTheme.hairline))
                    .contentShape(RoundedRectangle(cornerRadius: PhoneTheme.Radius.control, style: .continuous))
                }
                .buttonStyle(.cardPress)
                .accessibilityHint("Answers \(session.agentTitle)'s question")
            }
        }
        .disabled(chosen != nil)
        .animation(.easeOut(duration: 0.15), value: chosen)
        .sensoryFeedback(.success, trigger: chosen) { _, new in new != nil }
        .onChange(of: session) { chosen = nil }
        .task(id: chosen) {
            guard chosen != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { chosen = nil }
        }
    }
}
