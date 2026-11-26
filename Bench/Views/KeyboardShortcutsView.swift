import SwiftUI

/// Help › Keyboard Shortcuts: every key Workbench answers to, in one place.
/// The menus show most of them, but the message box's keys and a few others
/// live nowhere else.
struct KeyboardShortcutsView: View {
    struct Key: Identifiable {
        let action: String
        let keys: String
        var id: String { action }
    }

    struct Group: Identifiable {
        let title: String
        let keys: [Key]
        var id: String { title }
    }

    static var groups: [Group] {
        [
            Group(title: "Projects and tabs", keys: [
                Key(action: "Go to a project or action", keys: "⌘K"),
                Key(action: "Projects in the sidebar", keys: "⌘1 to ⌘9"),
                Key(action: "Next session needing you", keys: "⌘J"),
                Key(action: "Overview", keys: "⇧⌘O"),
                Key(action: "Add a project", keys: "⌘O"),
                Key(action: "Open the project in your editor", keys: "⇧⌘E"),
                Key(action: "New tab", keys: "⌘T"),
                Key(action: "New agent tab", keys: "⌘T twice"),
                Key(action: "New shell tab", keys: "⇧⌘T"),
                Key(action: "New browser tab", keys: "⌃⌘T"),
                Key(action: "Close tab", keys: "⌘W"),
                Key(action: "Save a file you've edited", keys: "⌘S"),
                Key(action: "Next and previous tab", keys: "⇧⌘] and ⇧⌘["),
                Key(action: "Step through tabs", keys: "⌃⇥ and ⌃⇧⇥"),
                Key(action: "Split right or down", keys: "⌘D and ⇧⌘D"),
                Key(action: "Switch pane in a split", keys: "⌘]"),
                Key(action: "New agent on a branch", keys: "⇧⌘N"),
                Key(action: "Brain dump", keys: "⌥⌘N"),
                Key(action: "Past sessions", keys: "⌘Y"),
            ]),
            Group(title: "Talking to your agent", keys: [
                Key(action: "Send", keys: "Return"),
                Key(action: "New line", keys: "⇧Return"),
                Key(action: "Send now, even while the agent is busy", keys: "⌃Return"),
                Key(action: "Stop the agent", keys: "⌘."),
                Key(action: "Stop the agent, with nothing typed", keys: "Esc"),
                Key(action: "Bring back a message you sent", keys: "↑ and ↓"),
                Key(action: "Take the suggestion", keys: "⇥ or →"),
                Key(action: "Allow or deny a request", keys: "Return and Esc"),
                Key(action: "Dictate", keys: "Hold \(Dictation.shared.key.glyph)"),
                Key(action: "Keep dictating hands-free", keys: "Space, while holding"),
            ]),
            Group(title: "Chat and terminal", keys: [
                Key(action: "Show as chat or terminal", keys: "⌥⌘T"),
                Key(action: "Bigger and smaller chat text", keys: "⌘= and ⌘−"),
                Key(action: "Chat text at the usual size", keys: "⌘0"),
            ]),
            Group(title: "Changes and files", keys: [
                Key(action: "Show or hide Changes", keys: "⌥⌘0"),
                Key(action: "Open the pull request", keys: "⇧⌘G"),
                Key(action: "Next and previous change", keys: "⌃⌥↓ and ⌃⌥↑"),
                Key(action: "Find in a file", keys: "⌘F"),
            ]),
            Group(title: "Browser tabs", keys: [
                Key(action: "Type an address or a search", keys: "⌘L"),
                Key(action: "Back and forward", keys: "⌘[ and ⌘]"),
                Key(action: "Reload the page", keys: "⌘R"),
                Key(action: "Find on the page", keys: "⌘F"),
                Key(action: "Zoom in and out", keys: "⌘= and ⌘−"),
                Key(action: "Page at its own size", keys: "⌘0"),
                Key(action: "Copy the page's address", keys: "⇧⌘C"),
            ]),
            Group(title: "Window", keys: [
                Key(action: "Standard or compact project list", keys: "⌥⌘1 and ⌥⌘2"),
                Key(action: "Usage and costs", keys: "⇧⌘U"),
                Key(action: "Settings", keys: "⌘,"),
                Key(action: "This list", keys: "⌘/"),
            ]),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(Self.groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title)
                            .font(.ui(size: Theme.TypeScale.meta, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .accessibilityAddTraits(.isHeader)
                        VStack(spacing: 0) {
                            ForEach(group.keys) { key in
                                HStack(alignment: .firstTextBaseline, spacing: 16) {
                                    Text(key.action)
                                    Spacer(minLength: 8)
                                    Text(key.keys)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                .font(.ui(size: Theme.TypeScale.ui))
                                .padding(.vertical, 5)
                                .accessibilityElement(children: .combine)
                                if key.id != group.keys.last?.id { Divider() }
                            }
                        }
                    }
                }
                Text("Keys for the agent itself work in its terminal as usual.")
                    .font(.ui(size: Theme.TypeScale.meta))
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 360, idealHeight: 620)
    }
}
