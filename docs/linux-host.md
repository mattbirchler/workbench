# Workbench on a Linux server

`workbench-host` is Workbench with no window. Install it on a Linux machine
and that machine shows up in Workbench on your Mac and iPhone like another
Mac: its projects, its Claude Code sessions, the conversation, and the
questions Claude asks.

It is one file with nothing to install beside it, so it runs on any 64-bit
Intel or ARM Linux, whatever the distribution. Nothing runs as root.

## Install

On the Linux machine:

```sh
curl -fsSL https://raw.githubusercontent.com/mattbirchler/workbench/main/scripts/install-host.sh | sh
```

That puts `workbench-host` in `~/.local/bin` and, where there is systemd,
sets it running in the background so it starts with the machine.

Claude Code has to be installed and signed in on that machine too. Run
`claude` there once: it gives you a link to open in a browser anywhere, and
a code to paste back.

## Pair

```sh
workbench-host add ~/code/my-project
workbench-host pair
```

`pair` shows a QR code and a link.

- **iPhone:** scan the code with the Workbench app. Or choose Enter Details
  and paste the link.
- **Mac:** click the + beside This Mac in the sidebar and paste the link.

How the devices reach the machine depends on what it has:

- **Tailscale.** If the machine is on your tailnet, `pair` sets up Tailscale
  Serve and the link uses the machine's tailnet name. Only your own devices
  can reach it. If Serve needs permission, `pair` prints the one command to
  run with sudo.
- **The Workbench relay.** `workbench-host pair --relay` needs nothing
  installed and no open port. The machine and your devices each connect out
  to the relay, and everything between them is sealed with keys made from
  the pairing code, which the relay never sees.

Anyone with the link can run commands on that machine as you. Treat it like
a password.

## Commands

| | |
| --- | --- |
| `workbench-host status` | Whether it's running, and what it still needs |
| `workbench-host add <folder>` | Add a project (you can also add them from the app) |
| `workbench-host projects` | List the projects |
| `workbench-host pair [--relay]` | Show the pairing code and link |
| `workbench-host service install` | Keep it running in the background |
| `workbench-host service remove` | Stop doing that |
| `workbench-host serve` | Run it in the foreground |

Logs: `journalctl --user -u workbench-host`. Its files live in
`~/.local/share/workbench-host`.

## What works, and what doesn't yet

Works: projects, starting and resuming Claude sessions, the conversation as
it happens, replies and queued messages, stopping a turn, allow and deny,
answering Claude's questions, plan approval, permission modes, and
notifications on your phone when a session needs you or finishes.

Not yet: the changes panel and diffs, browsing and editing files, shells,
worktree agents, shortcuts, side questions, usage, and Codex. The apps hide
or explain these for a server.

Sessions run inside the host. Restarting it (an update, a reboot) ends the
running turns, and each session is resumed with its conversation when the
host starts again.

## How it works

The host speaks the same connection the iPhone app and other Macs already
use to reach Workbench on a Mac, so the apps needed almost no changes. In
place of a terminal window it runs each Claude Code session in a terminal
with no screen (Ghostty's terminal engine, `libghostty-vt`), which lets it
drive Claude Code exactly as the Mac app does: reading the screen for
questions, typing replies, pressing keys. Claude Code's hooks and its
session files supply the rest.

The code is in `host/`, and shares `BenchKit/` with the apps.

## Building it yourself

On Linux with Swift 6 installed:

```sh
./scripts/build-host-terminal.sh x86_64-linux-musl   # or aarch64-linux-musl
cd host && swift build && swift test
```

`scripts/build-host-linux.sh` builds the static release files for both chip
types. It needs Swift's static Linux SDK.
