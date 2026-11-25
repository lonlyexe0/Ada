# Ada 🏝️

**A Dynamic Island for your MacBook's notch** — now playing with synced lyrics, swipe to skip, charging alerts, and a live activity for Claude Code.

**English** · [Türkçe](README.tr.md)

*Ada* means "island" in Turkish. It sits on top of your MacBook's notch and quietly grows into a small island when something happens: a song starts, you plug in the charger, or Claude Code finishes a task.

<p align="center">
  <img src="docs/images/music.png" width="49%" alt="Music playing: artwork, equalizer and the song title under the notch">
  <img src="docs/images/claude-working.png" width="49%" alt="Claude is working: mini mascot and elapsed time">
</p>
<p align="center">
  <img src="docs/images/expanded.png" width="82%" alt="Expanded panel: Claude row, player controls and synced lyrics">
</p>
<p align="center">
  <img src="docs/images/claude-waiting.png" width="49%" alt="Claude is waiting for your approval">
  <img src="docs/images/claude-done.png" width="49%" alt="Claude is done">
</p>

> The screenshots are rendered by the app itself (`--snapshot`) with demo data. The lyrics in them are placeholder text.

## Features

### 🎵 Music
- **Compact view while playing**: album art on the left, an equalizer tinted with the artwork's color on the right, and *song · artist* right under the notch.
- **Hover to expand**: artwork, title, ⏮ ⏯ ⏭ and a draggable progress bar. Click the artwork to bring the player to the front.
- **Synced lyrics** from [LRCLIB](https://lrclib.net). The current line is highlighted and the lines scroll with the song. If a song has no lyrics, the section simply doesn't appear.
- **Two-finger swipe** on the expanded panel: right → next track, left → previous. The trackpad gives a light tick when the swipe is far enough.
- **Smart idle**: after the music has been paused for 2 minutes, the panel goes back to the clock and date, with a "Last played ▶" button to resume.
- Works with the **Music** app (Apple Music) and the **Spotify** app.

### 🤖 Claude Code live activity
A pixel mascot tells you what [Claude Code](https://claude.com/claude-code) is doing. It works through Claude Code hooks (see [setup](#claude-code-integration-optional)).

| When | On the notch |
|---|---|
| You send a prompt | Mini mascot walking on the left, elapsed time (`1:23`) on the right |
| Claude needs your approval | The mascot comes out with a bouncing **?**: "waiting for your approval for Bash" |
| Claude finishes | An orange line glows and the mascot comes out: "done · *folder*" for 10 seconds, then a ✓ badge stays until you look |

Hover over the notch to see a Claude row at the top of the panel. Click **Aç** (Open) to bring the Claude app to the front. The ✓ badge goes away when you open the panel, switch to Claude, or send a new prompt.

### ⚡ Also
- **Charging alert**: "⚡ Charging 72%" when you plug in.
- **Terminal messages**: `ada "build finished"` shows up on the notch.
- **Launch at login** and a menu bar icon with toggles.
- **Lightweight**: about 35 MB of RAM and ~1% CPU when idle. Always-on animations run on Core Animation, not the app.

> **Note:** the app's own interface text is in Turkish for now.

## Requirements
- A MacBook with a notch. On other Macs, Ada appears as a small pill at the top center.
- macOS 14 or later (developed on macOS 27).
- Xcode, **or** just the Command Line Tools: `xcode-select --install` (Swift 5.9+).
- The Music app or the Spotify app for now playing.

## Install
```bash
git clone https://github.com/lonlyexe0/Ada.git
cd Ada
./build.sh
```
`build.sh` compiles the app, installs it as `~/Applications/Ada.app` and launches it. On first launch Ada adds itself to Login Items; you can turn this off from the menu bar icon.

When macOS asks **"Ada wants to control Music"**, click **Allow**. That's how Ada reads the current song.

- Quit: menu bar capsule icon → **Ada'dan çık** (Quit Ada).
- Build only, without installing: `./build.sh --no-run`.

## Claude Code integration (optional)
Copy the `"hooks"` section from [`scripts/claude-hooks.json`](scripts/claude-hooks.json) into `~/.claude/settings.json`. If you already have hooks there, merge them instead of replacing.

| Hook | What it sends to Ada |
|---|---|
| `UserPromptSubmit` | Claude started working → mini mascot + timer |
| `PostToolUse` | A tool finished → back to "working" (e.g. after you approve something) |
| `Notification` | Claude needs your approval → mascot with "?" |
| `Stop` | Claude finished → notification + ✓ badge |

Each hook call takes about 0.07 s and the first three run in the background, so they don't slow Claude down. Claude Code may need a new session to pick up the new hooks.

## Terminal messages (optional)
```bash
mkdir -p ~/.local/bin
cp scripts/ada ~/.local/bin/ && chmod +x ~/.local/bin/ada
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc   # then open a new terminal window

ada "lab7 finished!"
python3 long_job.py; ada "Job done"
```

## Menu bar
The capsule icon in the menu bar has:
- **Mac açılınca başlat**: launch at login
- **Claude maskotunu göster**: show the Claude mascot (the line and the text still appear when it's off)
- **Ada'dan çık**: quit

## Troubleshooting
| Problem | Try |
|---|---|
| The song doesn't show up | `open -n -W --stdout /tmp/ada.txt ~/Applications/Ada.app --args --probe; cat /tmp/ada.txt` asks Music step by step and prints what it answers. |
| You denied the Music permission | System Settings → Privacy & Security → Automation → Ada → Music, or `tccutil reset AppleEvents local.ada.island` |
| Does a song have lyrics? | Same probe command with `--probe --song "Song" --artist "Artist"` (prints only the line count) |
| See the design without opening a window | `build/Ada.app/Contents/MacOS/Ada --snapshot snapshots` renders every state as PNG |
| Is launch at login on? | `open -n -W --stdout /tmp/ada.txt ~/Applications/Ada.app --args --login-status; cat /tmp/ada.txt` |
| Did a message or hook reach Ada? | `tail ~/Library/Logs/Ada.log` (only the event type is logged, never content) |

## How it works
- **Now playing**: AppleScript queries the Music / Spotify app every 1.5 s, plus an instant update when the app broadcasts a change. Commands like play/pause and seek also go through AppleScript.
- **Lyrics**: [LRCLIB](https://lrclib.net) (free, no API key). It tries an exact match first (title, artist, album, duration), then a search; it skips versions whose length differs by more than 10 s.
- **Messages and hooks**: `Ada --say` / `Ada --claude-event` post a system-wide distributed notification, and the running Ada picks it up.
- **The window**: a borderless, click-through panel above the menu bar, sized to the notch using `NSScreen.safeAreaInsets` and `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`.
- **Animations**: the equalizer and the mascot are Core Animation layers, so they cost almost no CPU. Driving them with SwiftUI's `TimelineView` re-rendered the whole window on every frame (~6% CPU even when idle).
- **No Xcode needed**: it builds with SwiftPM and the Command Line Tools. With only the Command Line Tools on the macOS 27 SDK, SwiftUI's `@State` macro isn't available, so the code doesn't use `@State`.

## Privacy
- **Lyrics**: the song's title, artist, album and duration are sent to lrclib.net. Nothing else leaves your Mac (apart from Spotify's own artwork URLs).
- **Claude Code hooks**: Ada reads only the session id, the folder name and the notification text. It never reads your prompts or Claude's answers.
- **Log file**: only event types and message lengths are written, never their content.
- No analytics, no accounts.

## Limitations
- Music playing in a browser (YouTube, Spotify Web) isn't shown. Since macOS 15.4, Apple restricts the system's now-playing data to its own apps.
- The app is signed ad hoc, so build it yourself with `./build.sh` rather than downloading a prebuilt copy.
- The "waiting for approval" state appears only for Claude Code permission prompts.

## Project structure
| File | What it does |
|---|---|
| `AdaMain.swift` | Entry point and command-line flags (`--say`, `--claude`, `--probe`, `--snapshot`, ...) |
| `AppDelegate.swift` | Menu bar icon and menu, launch at login |
| `IslandController.swift` | Window above the notch, mouse tracking, states and sizes, swipe gestures |
| `IslandViews.swift` | All SwiftUI views of the island (compact states, expanded panel) |
| `Components.swift` | Notch shape, equalizer, battery, buttons, progress bar |
| `NowPlaying.swift` | Reading and controlling the current song |
| `AppleScript.swift` | The AppleScripts sent to Music / Spotify |
| `Lyrics.swift` | LRCLIB client, LRC parser, scrolling lyrics view |
| `Mascot.swift` | The pixel mascot (big and mini) on Core Animation |
| `ClaudeActivity.swift` | What Claude is doing: working, waiting, or done |
| `Messages.swift` | Terminal and Claude messages, `~/Library/Logs/Ada.log` |
| `Battery.swift` | Battery level and charger events |
| `Snapshot.swift` / `Probe.swift` | `--snapshot` and `--probe` developer tools |

## Disclaimer
Ada is an unofficial fan project, not affiliated with or endorsed by Apple or Anthropic. "Claude" is a trademark of Anthropic, and the pixel mascot is a fan-made tribute. Song lyrics belong to their respective owners; none are bundled with this project. They're fetched at runtime from LRCLIB.
