# Notice

Deckmian is a modified version of **Boring Notch** by TheBoredTeam and contributors.

| | |
|---|---|
| Upstream project | https://github.com/TheBoredTeam/boring.notch |
| Upstream base | commit `64b5459` (2026-10-10) |
| License | GPL-3.0 (see [LICENSE](LICENSE)) |
| Third-party code | see [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES) |

## What comes from upstream

The core of the app was built by the Boring Notch authors and is kept as the base:

- Notch window, shape, sizing and open / close behavior.
- Music and Now Playing integration (MediaRemote adapter, Spotify, Apple Music, YouTube Music).
- Shelf, AirDrop, calendar, reminders, mirror and HUD replacement.
- Settings window structure, onboarding and the XPC helper.

## What Deckmian changes

- New tabs: Notes, To-dos, Timer, Shortcuts app and Bluetooth.
- Lock button, glass mode and customizable layout.
- Deckmian name, icon and documentation.
- Removed upstream services: Sparkle auto-updates, upstream links, community and CI metadata.

The full list is in [CHANGELOG.md](CHANGELOG.md).

## Obligations kept

- The GPL-3.0 license and third-party notices are unchanged.
- Original copyright headers in source files are preserved.
- If Deckmian is ever distributed, its source must be made available under GPL-3.0.

## Internal identifiers

Bundle identifiers (`theboringteam.boringnotch`) and internal type and folder names (`boringNotch`, `BoringNotchXPCHelper`) still use the upstream names. Changing the bundle identifier would move the app to a new sandbox container and lose saved settings, notes and to-dos, so it is left as is on purpose.
