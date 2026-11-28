<img src=".bench/icon.png" alt="Workbench icon" width="128" height="128">

# Workbench

Workbench is a lean Mac terminal I made for working across a bunch of projects
with Claude Code at once. Pick a project in the sidebar and you get terminals
that open in its folder, plus a panel on the right that shows what's changing
in git. OpenAI's Codex works in Workbench too (it's in beta).

The terminals are [libghostty](https://github.com/ghostty-org/ghostty), so
Workbench picks up your existing Ghostty config: font, theme, keybindings, all
of it.

If you just want to use the app, grab it from
[workbenchapp.dev](https://workbenchapp.dev). The rest of this README covers
building it yourself and a few features that are easier to explain in text.

## Building

```sh
make ghostty   # once: downloads Zig, builds libghostty into vendor/
make build     # builds Workbench.app into build/
make run       # builds and launches
```

Requires Xcode 27 and xcodegen (`brew install xcodegen`).

To sign with your own Apple developer team, copy
`Config/Local.xcconfig.example` to `Config/Local.xcconfig` and fill it in.
That file is gitignored. With no team, the Mac app is signed to run on your
Mac only. The iPhone app needs a team and a bundle id prefix of your own.

A copy you build yourself never checks for updates and sends no analytics.
Only builds I sign do that (see `Analytics/OfficialBuild.swift`).

## Codex (beta)

Workbench is built for Claude Code first, but it can also run Codex in the same
kind of tab. You get the same chat, permission cards, past sessions, recaps and iPhone app,
with Codex's own models and effort levels in the message box. It's offered on
any Mac with `codex` installed. Pick which agent new tabs run in Settings >
Agents, or open one of each from the ＋ menu. Settings > Accounts lists your
Codex sign-ins beside your Claude ones, and each project can use its own.

A few things are still Claude-only for now: Codex's multiple-choice questions and plans
are answered in its terminal, and attaching pictures and switching permission
modes from the chat don't work with Codex yet. See
[docs/codex.md](docs/codex.md) for how it works and what's missing.

## Project icons

The sidebar shows `.bench/icon.png` from a project's folder (most image
formats work). Right-click a project and pick **Ask Claude to Set Icon** to
have Claude find or make one, or **Choose Icon…** to pick a file yourself.
Without one, Workbench uses an Xcode `AppIcon` image or a web favicon/logo if it
finds one, and falls back to the project's initial.

## Deploys

After a pull request merges, Workbench follows the deploy of its merge commit
and shows "Deploying", "Deployed" or "Deploy failed" beside the project's
branch, with a notification when it finishes. It reads the deployments that
hosts like Railway, Vercel, Netlify and Render post to GitHub, through `gh`, so
there's no account to connect. Repos that never deploy just show nothing.

## Commit, Push, Open PR

Under the branch in the Changes panel are three buttons: **Commit**, **Push**
and **Open PR**. Each sends a message to the project's Claude tab (or opens
one), and Claude does the git work, so the same buttons work whether a repo
lives on GitHub, GitLab or somewhere else. Commit greys out when there's
nothing to commit, Push when everything's pushed, and Open PR turns into a
link once the branch has a pull request. The messages are yours to edit, and
you can add your own, in Settings under Shortcuts.

## Editing files

A file tab is a small editor: click in the text and type, then press ⌘S.
Nothing is written until you save. The tab shows "Edited" and a dot while
there are unsaved changes, and closing it or quitting asks first. If Claude
changes the file while you have unsaved edits, yours stay put and a banner
offers **Reload** (take the file on disk) or **Keep Mine**. With no unsaved
edits the tab follows the disk as it always has.

## iPhone companion

Workbench can mirror your sessions to an iPhone over your home network,
Tailscale, or the Workbench relay: read each
conversation as a chat, reply, allow or deny a tool, browse changes and diffs,
and get a notification when Claude needs you or finishes. Turn it on in
Workbench's settings and scan the pairing code with the phone app.

```sh
make phone-install   # builds the phone app and installs it on your iPhone
```

The phone app needs iOS 27. At home it finds the Mac on your network. To
reach it from anywhere, turn on the Workbench relay in Settings > Remote Access (no
account, and the relay can't read what passes through), or sign the Mac in to
Tailscale. The relay's code is in [`relay-live`](relay-live), with how to
host your own.

## The `bench` command

Every tab Workbench opens has `bench` on its PATH, so you (or Claude, from a
Claude tab) can drive the app from the shell. `bench help` lists every
command, and `bench help <command>` has one command's options and examples.

```sh
# Agents
bench agent "Fix the login crash"     # a new agent on its own branch and worktree
bench agent --issue 412               # an agent that starts from a GitHub issue
bench agent --with codex "Add tests"  # an agent that runs Codex instead of Claude
bench status                          # what each agent is doing, and its pull request
bench send fix/login "Go ahead."      # send a message to an agent (--all for every one)
bench read fix/login                  # the last thing an agent said, in full
bench wait --all                      # wait until the agents stop working
bench stop fix/login                  # interrupt an agent
bench remove fix/login                # remove a finished agent and its worktree
bench sessions                        # this project's past conversations
bench resume 3f2a                     # pick one back up in a new tab

# Showing things
bench open Sources/Login.swift        # a file in a tab
bench open --diff Sources/Login.swift # its changes (--review for the whole branch)
bench open localhost:3000             # a page in a browser tab
bench run npm run dev                 # a command in a shell tab you can see and stop
bench run --shortcut Build            # one of your shortcuts
bench shortcuts                       # your shortcuts, and which are running
bench ports                           # what this project's servers are listening on
bench show fix/login                  # bring an agent or project to the front
bench notify "Tests pass, PR is up"   # a notification on this Mac and your iPhone
bench notify --phone "Deploy done"    # just the phone (or --mac for just the Mac)

# Where things stand
bench usage                           # how much of your Claude plan is used
bench pr                              # this branch's pull request, checks and deploy

# The project list
bench projects                        # Workbench's projects and agents
bench add ~/Code/thing                # add a folder as a project
bench rename "Recipes"                # rename this project in the sidebar
bench pin                             # pin it (bench unpin to undo)
bench base develop                    # compare its changes against another branch
```

Agents go by their branch name. Commands act on the project they're run in,
or on another with `--project <name or folder>`, and the ones that report
something take `--json`.

Claude is told about `bench` when Workbench starts it, so you can say "start
three agents on these bugs and tell me on my phone when they're done" and it
just works, no extra explaining needed. One session's message to another is always
marked with where it came from. A session can't answer another's permission
requests, merge, or throw away an agent's unsaved work: those stay with you.

## License

Workbench is open source under the [MIT License](LICENSE).
