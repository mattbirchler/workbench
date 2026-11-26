import SwiftUI

/// What's left of the sidebar when it's collapsed: a thin column of
/// project icons, so you can still see your projects and switch between
/// them. Each icon shows what its agents are doing; hover for the name.
struct ProjectRail: View {
    @Environment(AppStore.self) private var store

    static let width: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            // The traffic lights sit over the top of the rail.
            Color.clear
                .frame(height: WindowChrome.bandHeight)
                .background(WindowTitleArea())
            RailOverviewButton()
                .padding(.top, 6)
            Divider()
                .frame(width: 24)
                .padding(.vertical, 8)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(projects) { project in
                        RailProjectButton(project: project, isSelected: isSelected(project))
                        ForEach(store.worktrees(of: project.id)) { worktree in
                            RailProjectButton(project: worktree, isSelected: isSelected(worktree))
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            .animation(.snappy(duration: 0.2), value: projects.map(\.id))
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The sidebar's listed projects on this Mac, in its order, plus the
    /// selected one if it's tucked away under Inactive.
    private var projects: [Project] {
        var list = store.listedEntries
            .filter { $0.host == nil }
            .compactMap { store.project($0.projectID) }
            .filter { !$0.isWorktree }
        if let selected = store.selectedProjectID.flatMap({ store.project(store.rootID(of: $0)) }),
           !list.contains(where: { $0.id == selected.id }) {
            list.append(selected)
        }
        return list
    }

    private func isSelected(_ project: Project) -> Bool {
        !store.showsPage && store.selectedRemote == nil && project.id == store.selectedProjectID
    }
}

/// One project in the rail: its icon, with a dot for its agents' activity.
/// Worktrees get a smaller icon so they read as belonging to the one above.
private struct RailProjectButton: View {
    @Environment(AppStore.self) private var store
    @Environment(TerminalManager.self) private var terminals
    @Environment(ProjectIcons.self) private var icons
    let project: Project
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        let activity = terminals.activity(for: project)
        let size: CGFloat = project.isWorktree ? 20 : 28
        ProjectIcon(project: project, image: icons.image(for: project), size: size)
            .frame(width: 38, height: project.isWorktree ? 28 : 38)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color(nsColor: .controlBackgroundColor)
                          : Color.primary.opacity(isHovering ? 0.07 : 0))
                    .shadow(color: .black.opacity(isSelected ? 0.14 : 0), radius: 3, y: 1)
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if activity != .idle {
                    ActivityIndicator(activity: activity, size: 10)
                        .padding(2)
                        .background(Circle().fill(.background))
                        .offset(x: 4, y: -4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { store.selectedProjectID = project.id }
            .onHover { isHovering = $0 }
            .help(name)
            .task { icons.reload(project) }
            .animation(.easeOut(duration: 0.15), value: isSelected)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    /// A worktree goes by its branch, like in the sidebar.
    private var name: String {
        project.isWorktree ? (project.branch ?? project.name) : project.name
    }
}

/// The Overview, at the top of the rail, with how many agents are waiting.
private struct RailOverviewButton: View {
    @Environment(AppStore.self) private var store
    @Environment(TerminalManager.self) private var terminals
    @State private var isHovering = false

    var body: some View {
        let waiting = OverviewView.items(store: store, terminals: terminals).filter { $0.activity == .waiting }.count
        let selected = store.showsOverview
        Image(systemName: "square.grid.2x2")
            .font(.ui(size: 14, weight: .medium))
            .frame(width: 38, height: 32)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color(nsColor: .controlBackgroundColor) : Color.primary.opacity(isHovering ? 0.07 : 0))
                    .shadow(color: .black.opacity(selected ? 0.14 : 0), radius: 3, y: 1)
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if waiting > 0 {
                    Text("\(waiting)")
                        .font(.ui(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color(light: .white, dark: .black))
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(Theme.Status.waiting))
                        .offset(x: 4, y: -4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { store.showOverview(from: .rail) }
            .onHover { isHovering = $0 }
            .help(waiting > 0 ? "Overview: \(waiting) waiting for you" : "Overview: every agent session at a glance")
    }
}
