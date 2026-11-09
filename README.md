# ThoughtStream

A native Mac chat app for watching work as it happens. Built with an AppKit shell and a native, virtualized AppKit feed, local Codex and Claude Code connections, with their existing account sign-ins.

[Download the signed Mac beta](https://github.com/ricburton/thoughtstream-releases/releases) · [Report a problem](https://github.com/ricburton/thoughtstream-releases/issues)

This repository contains application source. Release downloads and the signed update feed live in [thoughtstream-releases](https://github.com/ricburton/thoughtstream-releases). Account credentials, chats and signing keys are kept outside the repository. Connect your own provider account after installation.

## Run

Requires macOS 14+, Apple Command Line Tools, Python 3.11+, Node and npm.

For a fresh clone, fetch the checksum-pinned Ruff dependencies and generate the icon first. These generated/binary assets are excluded from Git; their provenance and licenses remain in the repository.

```sh
python3 Scripts/Prepare-Source-Build.py
bash Build-and-Open.command
```

The launcher builds `build/ThoughtStream.app`, bundles the pinned native Codex 0.164.0 runtime, verifies the download's SHA-512 checksum, and signs the app. Automatic development restarts are currently paused; keep the pause marker in place. Use `--no-open` to build without installing or restarting; it still updates shared build caches. Install a completed build with `Scripts/Install-and-Restart.py <app> --no-open` to leave running chats untouched. During concurrent work, use `bash Scripts/Build-Isolated.sh` for an isolated compile check. Building the app requires Node and npm for the bundled code-analysis tools; users of the packaged app do not need Node installed separately. The feed uses native Swift attributed text, tables, image views, and controls. WebKit is created only for authored HTML previews; no JavaScript or CSS is bundled for the main feed.

See [local scripts and build utilities](Scripts/README.md) for the exact builder, output paths, packaging, icon generation, analysis commands, and focused verification.

The default is **GPT-6.1 Sol · High · Standard**. Model, effort and tier are sent explicitly for new turns, including resumed chats. The speed picker uses the connected runtime's advertised capabilities and preserves a saved speed if it temporarily disappears. Before sending at an accelerated speed, ThoughtStream retries availability checks; if the tier remains unavailable, the message stays unsent with an explanation instead of silently falling back to Standard. Changes in the settings controls are remembered.

Start a **New chat**, or **Open project…** for work in an existing folder. The app can use an existing ChatGPT sign-in managed by Codex. Otherwise, **Connect ChatGPT** opens the official browser sign-in flow. It does not ask for an API key or copy browser cookies.

## Share with a friend

For the signed beta and future in-app updates, use `python3 Scripts/Release-Beta.py --publish`.
This requires a Developer ID Application identity, saved notarization credentials,
and the ThoughtStream update key in Keychain. See [beta release setup](Scripts/RELEASING.md).
It builds an isolated snapshot, signs and notarizes the app, and publishes its signed
Sparkle feed and downloads to the separate beta release repository. It never installs
or launches the main app. A prepared build is not a notarized release until Apple's
submission and Gatekeeper checks pass.

Run `python3 Scripts/Package-For-Friend.py` to build an Apple Silicon release in an isolated cache directory without installing it or restarting your running app. It creates a dated `~/Downloads/ThoughtStream-Friend-Release-…` folder containing `ThoughtStream Install`, a compressed ZIP, a SHA-256 checksum, and a build manifest. The install folder contains the app, an Applications shortcut, and `START HERE.txt`. It includes pinned, checksum-verified Codex and Node runtimes and the offline analysis tools; it never copies account credentials, conversations, or project data from your home folder. Packaging outside the cloud-managed source directory avoids iCloud metadata interfering with signing.

The recipient needs an M1-or-newer Mac running macOS 14+, and their own account with Codex access. They unzip the download, drag the app to Applications, and connect ChatGPT in Settings. This is an ad-hoc-signed personal beta, not an Apple-notarized release; the included guide explains the one-time **Privacy & Security → Open Anyway** step. Start with Standard speed and select a model available to their account. Claude Code remains an optional, separately installed provider.

## Claude Code

Choose **Claude Code** in the sidebar's provider menu. Switching a conversation that already has history opens a new chat; existing chats retain their provider. Model, effort and speed selections are remembered separately for Codex and Claude. Claude shows Standard and Fast; Fast is available for supported Opus models and uses usage credits. Sonnet and Haiku use Standard. The choice applies to the next turn through Claude Code’s session settings.

Fable 5.2 is available in the Claude model picker and is the default for a fresh Claude setup. Both providers discover their models automatically and cache the list between launches; stale catalogs refresh when the picker opens. Choose **Refresh Models** to check immediately, or **Add Model…** to save a provider model ID and optional display name without rebuilding ThoughtStream. Custom entries survive discovery updates, and existing conversations keep their chosen model. Catalog refreshes do not submit a prompt or reconnect an active chat.

Open **Settings → Connect Claude** to use your installed `claude` executable and its existing sign-in. If you are signed out, ThoughtStream opens Claude Code's official sign-in in Terminal and connects when you finish in your browser. Connecting selects Claude in the sidebar and preserves existing Codex conversations. Claude streams replies and tool activity into the native feed, supports image attachments, interruption, conversation resumption and forks, and discovers local Claude conversations when you open their project folder.

Claude's approval mode follows Claude Code permissions, rather than the Codex workspace sandbox. Requests needing approval appear in ThoughtStream. Full access uses Claude's `bypassPermissions` mode; changing the access control stops both providers' connected runtimes.

## Everyday use

- Choose **View → Layout → Tabs Only** for a single chat area with one tab bar. Use **+** or **⌘T** to open a tab, **⌘W** to close it, and **⌘⇧T** to reopen it. Closing the last tab leaves the workspace ready for a new chat. Open tabs and the selected chat are remembered per project. Choose **View → Layout → Panes** to restore the previous pane layout; the layout choice is remembered across launches.

- Each project remembers its selected chats in both panes, split width, active pane, and each pane’s own open/closed tabs. Closing a tab affects only that pane. Returning to a project or relaunching restores that workspace, including drafts, text size, search, browsing positions, and Follow live settings. Window geometry is also saved.
- The left sidebar lists open chats above Projects. Expand a project to browse its conversation history, select its name to restore its workspace, and use Open project… to add another folder. New chats stay in the selected project and explicitly join the matching ChatGPT/Codex desktop project when first sent. Saved project roots are matched by canonical folder path, with the most specific root preferred. If no unique root matches, choose an existing project or create one; that folder's choice is remembered. A folder name alone never silently assigns a chat to a project.
- Every pane has a slim Highlights column with response snippets and typed sections (reasoning, JSON, HTML, Python, code and images). Click a highlight to jump to that part of the full feed; the down-arrow returns to live output.
- One chronological stream keeps progress, reasoning summaries, commands, outputs, file changes and replies visible.
- **Split stream** opens a separate chat with its own draft, Send/Steer and Stop controls. Switching chat tabs preserves each draft.
- Markdown renders headings, lists, tables, links, blockquotes, inline code and fenced code.
- JSON renders as a colored tree, fully expanded by default. Empty objects stay on one line and blank lines are removed without hiding any fields. Flat maps of short values, including category flags, flow left to right and wrap across the pane with every key and value visible.
- Completed tool results (such as Claude's WebFetch or Read) show only their result text, formatted as Markdown under the tool's name, instead of the raw JSON envelope. **Copy raw JSON** still copies the original record.
- Images appear inline, including tool image blocks, base64 data, image URLs, Markdown images and local image paths. macOS decodes additional formats such as HEIC and TIFF; large images are capped at 80 MB. Open image shows a larger window.
- HTML/CSS renders in resizable preview cards, with source disclosure and independent pop-out windows. HTML inside JSON values is recognized too. Preview scripts are disabled and previews cannot access local files or the app’s native bridge.
- Python heredocs and literal `python -c` commands display as extracted, formatted Python with native syntax coloring and real Ruff diagnostics. The copied Python is the displayed, formatted source; original commands remain in protocol exports. Python Markdown fences use the same renderer. Linting is static: it never executes the snippet, reads project lint configuration, or modifies the original command. The native Ruff executable is bundled for Apple Silicon and Intel.
- The feed fills the available pane width. Each stream has **− / +** text controls (8–28) and a reset button; the chosen size is remembered. Smaller text also reduces content spacing.
- **Return** sends; **Shift-Return** inserts a newline. During a turn it steers the ongoing work. **Stop** requests interruption.
- Each tab reveals a small × close button on hover. **⌘W** closes the active tab; **⌘⇧T** reopens the last closed tab. Closing a tab preserves its history and draft, and closed tabs stay closed after restart.
- **⌘N** (or **⌘T**) starts a chat in the focused pane; **⌘O** opens a project; **⌘F** searches the stream; **⌘+ / ⌘−** change text size.
- **⌘P** (or **⌘\**) splits the focused pane to the right, starts a new chat, and focuses its composer.
- **⌘⇧[ / ⌘⇧]** switch to the previous or next chat in tab order, continuing into adjacent panes and wrapping at either end. Keyboard focus follows to the destination composer.
- The sliders button reveals model, reasoning effort and speed settings. Model options come from the connected runtime; faster tiers depend on account availability and may use more allowance.
- **More** contains split stream, pending requests, protocol export and fork.
- Select text and choose **Ask about selection** to bring it into your next message.
- **Follow live** starts enabled and follows incoming activity in the stream and Overview. It lingers on reasoning summaries for 6–18 seconds, depending on length, and renews that pause when more reasoning arrives. New code keeps its nine-second reading pause. Later activity continues arriving during these pauses. Turning Follow live on or using the down-arrow jumps straight to the bottom; scrolling upward takes manual control.
- An optional sample is explicitly simulated and runs no commands.
- **Style → Matrix** (⌃⌘2) is an experimental green-phosphor look: monospace text, new words arriving white-hot, and digital rain behind the feed that falls in the characters the model is streaming. **Style → Standard** (⌃⌘1) restores the system look.
- Offline Mode checks uncached HTTPS traffic and rechecks five seconds after each failed offline check. A successful check or incoming live model data clears the indicator and resumes queued chats immediately. Local tool output and saved history do not count as network recovery.
- Restarting or reconnecting never inserts a continuation message. Codex runs behind a private local socket, so an active chat process can survive the window closing and the next launch rejoins its original thread. Local reconnection works while Internet probes are offline; network recovery does not require restarting the app. Idle runtimes are stopped on quit. If the runtime itself was killed, ThoughtStream restores its saved history without automatically starting another turn. Claude reconnects its saved conversation without sending a prompt.

The app keeps its legacy storage location and bundle identifier to preserve existing chats and settings. Chats are stored at `~/Library/Application Support/UnfoldNative/Sessions`. General chats use the sibling `Workspace` folder. Saved sessions resume their original provider conversation when you reconnect. ThoughtStream does not import ChatGPT web history or hosted connectors.

## Permissions

On the first real turn, choose workspace or full access. Workspace access is the default button and asks for elevated command/file actions. Full access lets Codex act with your Mac user's file and network permissions without additional command/file approvals. The visible access control lets you change this choice; changing it stops connected runtimes. macOS privacy permissions still apply.

## Optional validation

Development iterations skip the test suite by request; build the app directly with the launcher. The existing suite is available to run explicitly.

- Swift debug and release builds.
- Legacy WebKit renderer checks are retained behind the UNFOLD_WEB_RENDERER build condition and are inactive for the native feed.
- Tests for stream ordering and Unicode, access policies, persisted session restoration, completed/failed turns, and protocol redaction.
- An opt-in live integration test connects to the local Codex executable and asks for one short reply with no tools or file access.

```sh
swift test
UNFOLD_LIVE_TEST=1 swift test --filter SessionTests/testLiveChatGPTStreamWhenEnabled
```

The live test uses the current Codex ChatGPT sign-in and a small amount of its allowance. It stores its local test feed in a temporary directory, which it removes afterward. Codex may retain the underlying test thread.

## Scope

This is a personal beta. Notarized releases use the release pipeline above; local development builds are not notarized. The bundled runtime is pinned. Sparkle checks the signed beta feed and provides Check for Updates; installation requires approval and an update restart waits for active work to finish. Large history paging, attachments and comprehensive accessibility coverage are future work. Python syntax coloring is native Swift; formatting and linting use Ruff. Inline linting covers literal snippets up to 256 KiB, not file-path-only commands or dynamically generated shell code. Other code syntax coloring is lexical. Markdown and JSON formatting use Swift and NSAttributedString; legacy web-renderer source is excluded from the app bundle. Ruff’s provenance and license are in `Sources/Unfold/Tools`.

ThoughtStream displays available reasoning summaries and observable activity. The model's private internal reasoning is not supplied. UI batching improves local rendering behavior; model response speed still depends on the selected model, service tier and network.

Protocol exports apply basic credential redaction, but command output may contain secrets; inspect an export before sharing it. A crash can lose the newest unflushed batch. Disconnecting a runtime cannot undo completed changes or guarantee that independent child processes terminate.

Claude protocol references: [programmatic use](https://code.claude.com/docs/en/headless) and the [official Agent SDK transport](https://github.com/anthropics/claude-agent-sdk-python).

Official Codex protocol reference: [Codex app-server](https://learn.chatgpt.com/docs/app-server). For commercial distribution, evaluate [Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server) rather than treating local app-server authentication as a hosted service integration.
