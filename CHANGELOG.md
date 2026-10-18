# Changelog

All changes relative to the upstream base, Boring Notch commit `64b5459` (see [NOTICE.md](NOTICE.md)).

## 0.1.0 — 2026-10-18

### Added

- **Notes** tab: a plain-text scratchpad saved automatically.
- **To-dos** tab: add, complete, delete and clear completed items.
- **Timer** tab: presets, fine tuning, pause / resume, sound when finished, and a live activity in the closed notch.
- **Shortcuts app** tab: pin macOS Shortcuts and run them from the notch through the XPC helper.
- **Bluetooth** tab: connected devices, disconnect on hover, optional battery levels, and a peek when a device connects or disconnects.
- **Lock button** in the open notch header to keep the notch open.
- **Glass mode** with adjustable tint for the open notch.
- **Layout** settings: tab order and Home widget order, visibility, spacing and dividers.
- Deckmian app icon.
- Documentation: README, NOTICE, architecture guide and this changelog.

### Changed

- App renamed to Deckmian in the product name and visible UI.
- Tab bar and header buttons restyled; tabs shrink to fit beside the notch.
- Notch cover in the header now stays centered over the hardware notch.
- Shared keyboard-focus handling for text input in the notch.

### Removed

- Sparkle auto-updates (the feed pointed at upstream releases).
- Upstream links, team branding, release name and upgrade tips.
- Upstream community and CI metadata (`.github`, contributing, security policy, Crowdin, devcontainer, appcast).
