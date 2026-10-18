# Deckmian

Deckmian is a personal notch app for macOS. It turns the MacBook notch into an interactive panel for media, files, productivity tools and system controls.

> Deckmian started from the main foundations of [Boring Notch](https://github.com/TheBoredTeam/boring.notch) (GPL-3.0) and adds its own features on top. See [NOTICE.md](NOTICE.md) for what comes from upstream and what was added here.

## Quick path

1. Install Xcode (macOS 14 SDK or later) and accept its license.
2. Create the local signing identity (once per Mac), then trust it for code signing:

   ```bash
   ./Configuration/signing/create-local-signing-cert.sh ~/.deckmian-signing
   security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db ~/.deckmian-signing/cert.pem
   ```

   A stable signature keeps macOS permissions (Accessibility, Screen Recording, Calendar…) across rebuilds. Ad-hoc builds lose them every time.

3. Build:

   ```bash
   xcodebuild -project Deckmian.xcodeproj -scheme Deckmian -configuration Debug \
     -destination 'platform=macOS' -derivedDataPath ../DerivedData build
   ```

   If macOS asks for keychain access for `codesign`, enter your login password and choose **Always Allow**.

4. Open `../DerivedData/Build/Products/Debug/Deckmian.app` and hover over the notch.

> Quit Deckmian before rebuilding. macOS kills a running app when its binary is replaced.

## Features

| Area | Feature | Origin |
|------|---------|--------|
| Media | Now Playing, artwork, controls, visualizer | Upstream |
| Files | Shelf with AirDrop | Upstream |
| Calendar | Events and reminders | Upstream |
| Camera | Mirror preview | Upstream |
| System | Volume / brightness / backlight HUD replacement | Upstream |
| Productivity | **Notes** tab | Deckmian |
| Productivity | **To-dos** tab | Deckmian |
| Productivity | **Timer** tab with closed-notch live activity | Deckmian |
| Automation | **Shortcuts app** tab (runs your macOS Shortcuts) | Deckmian |
| Devices | **Bluetooth** tab with connect / disconnect peek | Deckmian |
| Behavior | **Lock button** that keeps the notch open | Deckmian |
| Appearance | **Glass mode** (translucent open notch) | Deckmian |
| Appearance | **Customizable layout** (tab order, Home widgets) | Deckmian |
| Branding | Deckmian name and icon, no auto-updates | Deckmian |

## Settings

Everything new can be turned on or off in **Settings**:

| Page | What you control |
|------|------------------|
| Notes / To-dos / Timer / Bluetooth | Enable each tab and its options |
| Shortcuts app | Which Shortcuts appear in the notch and their order |
| Layout | Tab order and Home widget order, spacing, dividers |
| Appearance | Glass mode and glass tint |
| General → Lock | Show or hide the lock button |

## Updating

Deckmian has no auto-update mechanism. Pull your changes and rebuild from source.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the app is organized and how to add a tab.
- [CHANGELOG.md](CHANGELOG.md) — what changed relative to the upstream base.
- [NOTICE.md](NOTICE.md) — origin, license and credits.

## License

GPL-3.0, inherited from Boring Notch. See [LICENSE](LICENSE) and [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).
