# Briefing

**A morning ritual for macOS.** Every day, on the first wake of your Mac after a time you choose, Briefing fills the screen with your day: the weekday, the time, the weather, the principles you live by, today's calendar and this month's challenge. Read it, press Enter, begin.

No accounts, no tracking, no feeds. Your calendar never leaves your Mac.

Briefing is free. If it makes your mornings better, you can [support it on Ko-fi](https://ko-fi.com/vanodium).

## Download

Get the latest `Briefing-X.Y.Z.dmg` from [Releases](https://github.com/Vanodium/Briefing/releases/latest), open it and drag Briefing into Applications.

Requires **macOS 14 Sonoma or later**, on Apple silicon or Intel.

### Opening it the first time

Briefing is not notarized by Apple (notarization requires a paid Apple developer account), so macOS will refuse to open it the first time. You only need to allow it once:

**macOS 15 Sequoia and later**
1. Open Briefing. macOS says it cannot verify the app — click **Done**.
2. Open **System Settings → Privacy & Security** and scroll down to **Security**.
3. Next to "Briefing was blocked…", click **Open Anyway** and confirm with your password.

**macOS 14 Sonoma**
- Control-click Briefing in Applications, choose **Open**, then **Open** again.

**Or, in Terminal** (any version):
```bash
xattr -dr com.apple.quarantine /Applications/Briefing.app
```

The source is all here: you can read exactly what the app does, or build it yourself (see [Building from source](#building-from-source)) — a copy you build never needs this step.

## First launch

Briefing lives in the menu bar (a small grid icon); there is no Dock icon. On the first launch a short setup walks you through seven steps: a theme, access to Calendar and Reminders, your principles, this month's challenge, and when the dashboard should appear. Return continues, Esc goes back. Run it again any time from the menu → **Show Onboarding…**

## The ritual

1. **Arrival.** The weekday rises out of a dark screen, then the time, the date and the weather.
2. **Enter or Space — open the day.** The upper block glides up and the day arrives piece by piece: your principles, today's calendar and reminders, the month's challenge.
3. **Enter, Space or Esc — sign and begin.** The screen fades away.

For the first 1.5 seconds keys are ignored, so the key you pressed to wake the Mac cannot dismiss it.

The dashboard is an ordinary window: other windows can come in front of it, the menu bar and the Dock stay where they are. Additional displays are dimmed while Briefing is in front.

| Key | Action |
|---|---|
| Enter / Space | open the day, then sign & begin |
| Esc | close · leave edit mode |
| E | amend principles and challenges |
| S | settings |
| ⌃⌥⌘M | show or hide Briefing, from anywhere |

Every key can be changed in **Settings → Shortcuts**.

### Editing

Press **E** on the dashboard. Principles and challenges become text fields; hover a row for Up, Down and Delete; **Add** creates a new one. Changes are saved as you type. On the last day of a month you can set next month's challenges in advance; past months move to an archive file.

## Settings

Menu → **Settings…**, or **S** on the dashboard.

- **General** — open by itself on the first wake of the day, "not before" time, open at login, dim other displays, weather city, updates.
- **Appearance** — ten themes, five dark and five light: First Light, Graphite, Cognac, Blue Hour, Smoke, Daybreak, Dawn, Haze, Mist, Gazette.
- **Blocks** — show, hide and reorder Principles, Today and the month challenge; the weather.
- **Calendars** — which Apple calendars and reminder lists appear. Any account added to your Mac (iCloud, Google, Exchange) shows up here.
- **Shortcuts** — every key above.

## When it opens

Briefing opens by itself once a day, the first time you sit down at the Mac after the "not before" time (07:30 by default):

- waking, unlocking, logging in or the end of the screensaver trigger a check;
- it opens only when it has not been shown today, the time has passed, the screen is unlocked and the display is awake;
- a timer every 30 seconds notices a sleep that macOS forgot to announce;
- with **Open at that time if the Mac is already awake** on, it also opens right at 07:30 if you are already working.

The menu shows whether it has been shown today; **Reset "Shown Today"** lets you try it again. Every decision is written to the log (menu → **Open Log**).

## Your data

Everything is plain JSON you can edit by hand (menu → **Open Data Folder**):

```
~/Library/Application Support/Briefing/
  mindset.json              your principles
  challenges.json           challenges by month: {"months": {"2026-11": ["Drink more water"]}}
  challenges-archive.md     past months
  settings.json             everything in Settings
  state.json                when it was last shown
  weather-cache.json        the last weather, for when there is no network
  Fonts/                    optional fonts (see below)
```

The log is `~/Library/Logs/Briefing.log`.

## Privacy

Briefing has no accounts, no analytics and no servers of its own. It connects to:

- **Open-Meteo** (`api.open-meteo.com`) — your city's coordinates and time zone, to get the weather, while the dashboard is open.
- **Apple** — the city name you type, once, to find its coordinates (macOS geocoding).
- **GitHub** — to check for a new version, only if you allow automatic update checks (or choose Check for Updates). No profile of your Mac is sent.

Your calendar events, reminders, principles and challenges are read and stored only on your Mac.

## Updates

Briefing updates itself from this repository's releases through [Sparkle](https://sparkle-project.org). On the second launch it asks whether to check automatically; you can change that in **Settings → General** or check by hand from the menu. Every update is signed, and installed copies refuse anything that is not.

## Typeface

The dashboard is set in **Neue Haas Grotesk Display** if it is installed, otherwise in **Helvetica Neue**, which ships with every Mac. If you own Neue Haas Grotesk Display Pro, install it normally or put the `.otf` files into `~/Library/Application Support/Briefing/Fonts/` and restart Briefing.

## Troubleshooting

- **"No access to your calendar."** Settings → Calendars → **Allow Access**, or System Settings → Privacy & Security → Calendars / Reminders → Briefing.
- **It did not open this morning.** Open the log: lines starting with `waiting:` say what it was waiting for.
- **Uninstall.** Quit Briefing from the menu, turn it off in System Settings → General → Login Items, and move it to the Trash. Your data stays in `~/Library/Application Support/Briefing/`; delete that folder to remove it too.

## Building from source

Needs macOS 14 and Swift — Xcode, or just the Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/Vanodium/Briefing.git
cd Briefing
./install.sh      # builds, installs into ~/Applications and launches
./uninstall.sh    # removes the app and its login item; your data is kept
```

`./build.sh` alone builds `build/Briefing.app` with a local signature. The first build downloads Sparkle and can take a few minutes.

### Releasing

Once per Mac, `tools/setup-signing.sh` creates the release certificate and Sparkle's update key, and backs both up to `~/Documents/Briefing-signing/`. Keep that backup safe: every future version must be signed with the same keys, or installed copies lose Calendar access and stop updating.

```bash
./release.sh 1.0.1    # builds dist/Briefing-1.0.1.dmg, the update archive and appcast.xml
```

Then commit the version bump and attach the three files to a GitHub release tagged `v1.0.1`; the script prints the command.

## Credits

- Weather data by [Open-Meteo.com](https://open-meteo.com/), licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- Updates by [Sparkle](https://sparkle-project.org), MIT License.

## License

[MIT](LICENSE) © 2026 Vanodium
