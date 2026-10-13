# TodayBar

macOS menu bar app showing today's calendar events and reminders, with a full-screen alert before meetings.

## Features
- Today's events and reminders in a menu bar panel; click a row to open it in Calendar / Reminders
- Next event in the menu bar title (calendars selectable)
- One-click **Join** for Zoom, Meet, Teams and Webex links
- Full-screen alert (by default only for events with a Zoom/Meet/Teams/Webex link; configurable) with alarm sound, snooze (30s), cancel, mute
- Complete reminders from the panel
- Silence the alarm during Focus / Do Not Disturb, screen sharing or mirroring, and quiet hours; optionally hide the alert while sharing
- Per-calendar visibility, light/dark theme, launch at login

## Install
Download `TodayBar-x.y.z.zip` from [Releases](https://github.com/bartek-sarul/todaybar/releases), unzip, move `TodayBar.app` to `/Applications`.
The app is ad-hoc signed (not notarized): on first launch right-click → Open, or run `xattr -dr com.apple.quarantine /Applications/TodayBar.app`.

## Build
Requires macOS 14+ and the Xcode command line tools.

```sh
./build.sh        # builds TodayBar.app
open TodayBar.app
```

Grant Calendar and Reminders access on first launch.

## Notes
- Focus detection reads `~/Library/DoNotDisturb/DB/Assertions.json`; grant TodayBar **Full Disk Access** or it is ignored.
- Screen share detection is a heuristic: mirrored display or Zoom's `CptHost` process. Browser-based sharing is not detected.

## Contributing
Work on a `feature/*` or `fix/*` branch and open a PR to `main`. CI must pass.
Releases are cut from PRs: add one label before merging — `release:major`, `release:minor` or `release:patch`.
No label = no release. The version is the previous tag bumped accordingly; a zip is attached to the GitHub release.

## License
Proprietary, all rights reserved. See [LICENSE](LICENSE).
