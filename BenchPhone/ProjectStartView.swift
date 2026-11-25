import BenchKit
import SwiftUI

/// A project with no Claude session yet: a friendly place to start one,
/// with a first message if you like, and the other ways into the project.
struct ProjectStartView: View {
    @Environment(CompanionClient.self) private var client
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let project: CompanionProject
    @State private var prompt = ""
    @State private var starting = false
    @State private var glowing = false
    @FocusState private var typing: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                    .padding(.top, 36)
                starter
                    .padding(.top, 28)
                VStack(spacing: 10) {
                    NavigationLink(value: NewAgentRoute(projectID: project.id)) {
                        ActionCard(symbol: "arrow.triangle.branch", title: "New Agent on a Branch",
                                   detail: "The agent works in its own copy, so your files stay put")
                    }
                    if client.canBrowseFiles {
                        NavigationLink(value: FilesRoute(projectID: project.id)) {
                            ActionCard(symbol: "folder", title: "Files", detail: "Look through the project")
                        }
                    }
                    NavigationLink(value: PastSessionsRoute(projectID: project.id)) {
                        ActionCard(symbol: "clock.arrow.circlepath", title: "Past Sessions",
                                   detail: "Pick up a conversation where it left off")
                    }
                }
                .buttonStyle(.cardPress)
                .padding(.top, 28)
                Text("You can also open an agent tab for \(project.name) in Workbench on your Mac.")
                    .font(.footnote)
                    .foregroundStyle(PhoneTheme.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 22)
                    .padding(.horizontal, 12)
            }
            // On an iPad it stays a comfortable column instead of stretching.
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background {
            ZStack {
                PhoneTheme.canvas
                RadialGradient(colors: [PhoneTheme.accent.opacity(glowing ? 0.24 : 0.14), .clear],
                               center: UnitPoint(x: 0.5, y: 0.12), startRadius: 0, endRadius: 380)
            }
            .ignoresSafeArea()
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) { glowing = true }
        }
        // The new tab's session takes this screen's place once the Mac
        // reports it. If it never does, let them try again.
        .task(id: starting) {
            guard starting else { return }
            try? await Task.sleep(for: .seconds(12))
            starting = false
        }
    }

    private var hero: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(PhoneTheme.accent.opacity(0.14))
                    .frame(width: 92, height: 92)
                Circle()
                    .strokeBorder(PhoneTheme.accent.opacity(0.35), lineWidth: 1)
                    .frame(width: 92, height: 92)
                Text("✻\u{FE0E}")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(PhoneTheme.accent)
                    .rotationEffect(.degrees(glowing ? 8 : -8))
            }
            .shadow(color: PhoneTheme.accent.opacity(0.3), radius: 24, y: 8)
            Text("Ready when you are")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(PhoneTheme.ink)
                .padding(.top, 20)
            Text("Start an agent session in \(project.name) and it'll open right here.")
                .font(.body)
                .foregroundStyle(PhoneTheme.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 16)
        }
    }

    /// An optional first message, and the button that starts the tab.
    private var starter: some View {
        VStack(spacing: 12) {
            TextField("What should your agent work on? (optional)", text: $prompt, axis: .vertical)
                .lineLimit(1...5)
                .focused($typing)
                .font(.body)
                .foregroundStyle(PhoneTheme.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous)
                    .strokeBorder(typing ? PhoneTheme.accent.opacity(0.6) : PhoneTheme.hairline))
                .animation(.easeOut(duration: 0.15), value: typing)
            Button(action: start) {
                HStack(spacing: 8) {
                    if starting {
                        ProgressView()
                        Text("Starting Agent")
                    } else {
                        Image(systemName: hasPrompt ? "arrow.up" : "sparkle")
                        Text(hasPrompt ? "Start with This Message" : "Start Agent")
                    }
                }
                .contentTransition(.opacity)
            }
            .buttonStyle(.phonePrimary)
            .disabled(starting)
            .animation(.snappy(duration: 0.2), value: hasPrompt)
            .animation(.snappy(duration: 0.2), value: starting)
            .sensoryFeedback(.impact(weight: .medium), trigger: starting) { _, new in new }
        }
    }

    private var hasPrompt: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func start() {
        typing = false
        starting = true
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        client.newClaudeTab(projectID: project.id, prompt: text.isEmpty ? nil : text)
    }
}

/// One more way into the project: an icon, what it is, and a line on why.
private struct ActionCard: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PhoneTheme.accent)
                .frame(width: 38, height: 38)
                .background(PhoneTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(PhoneTheme.ink)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(PhoneTheme.inkMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PhoneTheme.inkMuted)
        }
        .padding(14)
        .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous).strokeBorder(PhoneTheme.hairline))
        .contentShape(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
    }
}
