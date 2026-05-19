# ClaudeWatch

[![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.0-orange?logo=swift)](https://swift.org/)
[![Python](https://img.shields.io/badge/Python-3.6%2B-blue?logo=python)](https://www.python.org/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Author](https://img.shields.io/badge/Author-John%20Dimou-blueviolet)](https://optimalversion.io)

> **Note for users downloading from GitHub Releases:** macOS may show a security warning because the app is not signed with an Apple Developer certificate. To open the app:
> 1. Try to open the app (it will be blocked)
> 2. Go to **System Settings → Privacy & Security**
> 3. Scroll down and click **"Open Anyway"** next to the ClaudeWatch message
> 4. Click **Open** in the confirmation dialog

A beautiful macOS menu bar app that displays your **Claude Code** usage statistics in real-time. Monitor your session and weekly limits at a glance with a stunning glassmorphic UI.

## Features

<table>
<tr>
<td valign="top" width="62%">

- **Real-time Usage Tracking** — Session, weekly (all models), and weekly (Sonnet) percentages in the menu bar at a glance
- **Last 24h Insights** — Fully dynamic behavioral signals parsed live from `/usage` (long sessions, high context, subagent-heavy runs) with collapsible descriptions
- **Independent Reset Countdowns** — Each tier shows its own reset timestamp plus a live "in Xh Ym" countdown
- **Dynamic Plan/Model Detection** — Header reflects the actual plan and model reported by the CLI (Claude Max, Pro, Team, etc.) — nothing hardcoded
- **GitHub Release Auto-Check** — Polls GitHub on launch; a banner appears when a newer build is available with a one-tap Download button
- **Dynamic Color Indicators** — Progress bars transition green → amber → red based on usage level
- **Configurable Auto-refresh** — 30s / 1m / 2m / 5m / 10m / Never
- **Zero Token Usage** — Reads account stats locally via the Claude CLI; never invokes a model

</td>
<td valign="top" width="38%" align="center">
  <img src="demo-v2.gif" alt="ClaudeWatch Demo" width="300">
</td>
</tr>
</table>

## Requirements

### System Requirements

| Requirement | Version | Notes |
|-------------|---------|-------|
| **macOS** | 13.0 (Ventura) or later | Required for SwiftUI features |
| **Python** | 3.6+ | Usually pre-installed on macOS |
| **Xcode** | 14.0+ | Only needed if building from source |

### Claude Requirements

| Requirement | Description |
|-------------|-------------|
| **Claude Code CLI** | Must be installed and accessible. [Install from claude.ai/code](https://claude.ai/code) |
| **Claude Pro/Max** | Active subscription required (usage limits only apply to paid plans) |
| **Authenticated** | Must be logged into Claude Code CLI (`claude` command should work) |

### Verify Requirements

```bash
# Check Python version
python3 --version

# Check if Claude CLI is installed
which claude

# Test Claude CLI is working
claude --version
```

## Installation

### Option 1: Download Release (Recommended)

1. Download the latest `.app` from [Releases](../../releases)
2. **Move `ClaudeWatch.app` into `/Applications`** — not Desktop, Downloads, or Documents. This step is important: macOS treats the first three as TCC-protected folders, and an app running from inside one will keep re-asking for "access to your Desktop / Documents / Downloads" on every refresh. Installing into `/Applications` keeps the bundle path stable and outside TCC's protected list, so the permission you grant on first launch *sticks*.
3. Open the app (right-click → Open the first time to bypass Gatekeeper)
4. When macOS prompts for folder access on first launch, click **Allow** once. The grant is stored against the app's signature at its `/Applications` path and won't be asked again.

### Option 2: Build from Source

1. Clone this repository:
   ```bash
   git clone https://github.com/JohnDimou/ClaudeWatch.git
   cd ClaudeWatch
   ```

2. Open in Xcode:
   ```bash
   open ClaudeWatch.xcodeproj
   ```

3. Build and run (⌘+R)

Or build from command line:
```bash
xcodebuild -project ClaudeWatch.xcodeproj -scheme ClaudeWatch -configuration Release build
```

The built app will be in `~/Library/Developer/Xcode/DerivedData/ClaudeWatch-*/Build/Products/Release/`

## Usage

1. **Launch the app** - A brain icon appears in your menu bar with usage percentages
2. **View quick stats** - The menu bar shows session and weekly usage
3. **Click for details** - Opens a popup with full usage information
4. **Configure settings** - Click the gear icon to adjust refresh interval

### Menu Bar Display

```
🧠 25% | 22%
   ↑      ↑
   │      └── Weekly usage (all models)
   └── Current session usage
```

### Color Indicators

| Usage Level | Color | Meaning |
|-------------|-------|---------|
| 0-50% | Green | Plenty of capacity remaining |
| 50-75% | Yellow/Orange | Moderate usage |
| 75-100% | Red | Near or at limit |

## Settings

Access settings by clicking the gear icon in the popup:

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Refresh Interval | 30s, 1m, 2m, 5m, 10m, Never | 1 minute | How often to auto-fetch usage data |
| Refresh on Open | On/Off | On | Fetch fresh data when popup opens |

Settings are persisted and remembered between app restarts.

## How It Works

The app uses a Python script to interact with the Claude Code CLI:

1. Spawns Claude CLI in a 200-column pseudo-terminal (pty) so the `/usage` box renders fully
2. Sends the `/usage` slash command and waits for the "Last 24h" section to appear as the signal that rendering is complete
3. Parses the terminal output structurally — section boundaries are detected by the last occurrence of each header, and insights are extracted purely by their `NN%` pattern with no hardcoded wording
4. Displays the results in a native SwiftUI interface

### Update Checking

On launch (and on popover open, respecting a 6-hour cache) the app queries
`api.github.com/repos/JohnDimou/ClaudeWatch/releases/latest`, compares
`tag_name` against the installed `CFBundleShortVersionString` using a semver
compare, and surfaces a banner when a newer stable release is published. The
user taps **Download** to open the release page in their browser — the app
never attempts an in-place install (this distribution is unsigned, so Gatekeeper
would reject any automated replace).

### Important: No Token Usage

**This app does NOT consume any Claude API tokens.** The `/usage` command is a built-in CLI feature that queries your account statistics directly from Anthropic's servers - it does not invoke any AI model. It's equivalent to checking your usage on the Anthropic dashboard.

## Project Structure

```
ClaudeWatch/
├── ClaudeWatch/
│   ├── ClaudeWatchApp.swift    # App entry point & menu bar setup
│   ├── UsageManager.swift          # Usage data fetching, parsing & settings
│   ├── UsagePopoverView.swift      # SwiftUI popup, Last 24h card, update banner
│   ├── UpdateChecker.swift         # GitHub release polling + semver compare
│   └── Info.plist                  # App configuration
├── get_claude_usage.py             # Python script for CLI interaction
├── ClaudeWatch.xcodeproj/       # Xcode project
├── LICENSE                         # MIT License
└── README.md
```

## Troubleshooting

### "Claude CLI not found"
```bash
# Check if Claude is installed
which claude

# If not found, install from:
# https://claude.ai/code

# If installed but not found, it might be in a non-standard path
# The app checks these locations automatically:
# - /usr/local/bin/claude
# - /opt/homebrew/bin/claude
# - ~/.local/bin/claude
# - ~/.npm-global/bin/claude
```

### "Python 3 not found"
```bash
# Check Python version
python3 --version

# If not installed, install via Homebrew:
brew install python3
```

### Usage not updating
- Click the refresh button (circular arrow) in the popup
- Check Settings → ensure refresh interval isn't set to "Never"
- Ensure you have an active Claude Pro/Max subscription
- Verify `claude` works in your terminal

### App won't open (macOS security)
- Right-click the app → Open → Open
- Or: System Settings → Privacy & Security → Open Anyway

### Usage shows 0% for everything
- Make sure you're logged into Claude Code CLI
- Run `claude` in terminal and verify it works
- Check that you have a Pro/Max subscription

### macOS keeps asking for Desktop / Documents / Downloads access

If the same folder-permission dialog keeps coming back every refresh — even after clicking **Allow** — the cause is almost always one of these:

1. **The `.app` is living inside a TCC-protected folder.** If ClaudeWatch.app is on your Desktop, in Downloads, in Documents, or in iCloud Drive, macOS will re-trigger the prompt every poll cycle. **Move it to `/Applications` and relaunch.** This alone fixes 90% of cases.

2. **An older grant is pinned to a stale code-signing hash.** macOS records each permission grant against the app's signature at the time of approval. If you previously installed an older build (or a development build), TCC may still be holding a grant tied to that old hash and refuses to reuse it for the current build. Reset the stale entry from Terminal:
   ```bash
   tccutil reset SystemPolicyDesktopFolder io.optimalversion.claudeusagebar
   tccutil reset SystemPolicyDocumentsFolder io.optimalversion.claudeusagebar
   tccutil reset SystemPolicyDownloadsFolder io.optimalversion.claudeusagebar
   ```
   Then relaunch the app and click **Allow** on the fresh prompt. The new grant will bind to the current signature and stay.

3. **You have an old `ClaudeUsageBar.app` (pre-rebrand) hanging around.** Delete it — it's no longer maintained:
   ```bash
   rm -rf /Applications/ClaudeUsageBar.app
   ```

If after all three steps the prompt **still** returns, please [open an issue](../../issues) with:
- Screenshot of the permission dialog
- macOS version and app version
- Output of `ls -ld /Applications/ClaudeWatch.app` and `codesign -dv /Applications/ClaudeWatch.app 2>&1 | head -5`
- Any relevant setup details (iCloud Drive sync, OneDrive, Jamf/MDM, etc.)

## Privacy & Security

- **Local Only** - All data stays on your machine
- **No External Servers** - The app only communicates with the local Claude CLI
- **No Tracking** - No analytics or telemetry
- **Open Source** - Full source code available for review

## Legal Disclaimer

**NO WARRANTY**: This software is provided "as is", without warranty of any kind, express or implied. Use at your own risk.

**GDPR & DATA PROTECTION**: This app processes data locally on your device only. It does not collect, store, transmit, or share any personal data with third parties. The app only reads usage statistics from the Claude CLI running on your machine. No data leaves your computer. The author assumes no responsibility or liability for any data processing that may occur through the use of the Claude CLI itself - please refer to Anthropic's privacy policy for information about how Claude handles your data.

**LIABILITY**: In no event shall the author be liable for any claim, damages, or other liability arising from the use of this software.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Author

**John Dimou** - [OptimalVersion.io](https://optimalversion.io)

## Acknowledgments

- Inspired by the need to track Claude usage without constantly running `/usage`

---

<p align="center">
  Made by <a href="https://optimalversion.io">John Dimou - OptimalVersion.io</a>
</p>
