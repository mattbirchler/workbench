# Workbench support

Workbench is a free Mac app for running Claude Code, with an iPhone app that connects to it. Download the Mac app from the [latest release](https://github.com/mattbirchler/bench-releases/releases/latest).

## Getting started

1. Install [Claude Code](https://claude.com/product/claude-code) and sign in.
2. Open Workbench and add a project folder. Workbench > Settings > Setup shows anything that's missing.

## Using the iPhone app

1. Get the [Workbench iPhone app](https://apps.apple.com/us/app/workbench-manage-your-agents/id6827762868) from the App Store.
2. On the Mac, open Workbench > Settings > Remote Access and turn on the switch at the top (**Let my iPhone and other Macs connect**).
3. In the iPhone app, tap Scan Code and scan the code on your Mac.

That's all you need at home: on the same Wi-Fi, your iPhone connects straight to your Mac.

## Connecting away from home

There are two ways to reach your Mac from anywhere. You can use either, or both.

- **Tailscale.** Install [Tailscale](https://tailscale.com) on your Mac and your iPhone, and sign in to the same account. Your devices talk straight to each other, with nothing in between.
- **The Workbench relay.** On the Mac, open Settings > Remote Access and turn on **Workbench relay**. There's no account and nothing else to install. Messages pass through a relay server, encrypted on your devices so the relay can't read them. A device that's already paired picks it up the next time it connects at home.

Workbench always tries your home network and Tailscale first, and uses the relay only when neither answers. The [relay page](https://workbenchapp.dev/relay.html) says what the relay can and can't see, and how to host your own.

To look around first, tap **Try a Demo** on the iPhone app's first screen.

## Using another Mac

You can work in a second Mac's projects from the same sidebar.

1. Both Macs on the same network can skip this step. To connect from anywhere, set up Tailscale or the Workbench relay on the Mac you want to reach (see Connecting away from home).
2. On the Mac you want to reach, open Workbench > Settings > Remote Access, turn on the switch at the top, and click **Copy Pairing Link**. The link starts with `bench://pair`.
3. Send that link to the other Mac (with Universal Clipboard, a note, or a message to yourself).
4. On the other Mac, click **+** next to This Mac at the top of the sidebar, paste the link, and click **Connect**.

The pairing link holds a secret, so keep it to yourself. Click **Make a New Code** to replace it.

## Common problems

**"Can't find the Mac."** At home, check that both devices are on the same Wi-Fi. Away from home, check that Tailscale is connected on both devices, or that **Workbench relay** is on in Settings > Remote Access on the Mac and its Relay row under Status says Connected.

**"Found the Mac, but Workbench isn't answering."** Make sure Workbench is open on the Mac and **Let my iPhone and other Macs connect** is on in Settings > Remote Access.

**No notifications on your phone.** Turn on notifications in the iPhone app's Settings. Then, on the Mac, right-click each project you want to hear about and choose **Send Notifications to iPhone**. A bell shows on projects that notify.

**Claude tabs say Claude Code isn't installed.** Install it, then open a new Claude tab. Settings > Setup shows where Workbench looked.

**Pull requests don't show up.** Install the [GitHub CLI](https://cli.github.com) and run `gh auth login` in a terminal.

## Contact

Email [matt@birchtree.me](mailto:matt@birchtree.me) with what happened and your Mac's macOS version.
