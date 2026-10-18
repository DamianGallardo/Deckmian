# Architecture

How Deckmian is organized, and the recipe for adding a new notch tab.

## Quick path: add a tab

1. Add a case to `NotchViews` in `boringNotch/enums/generic.swift` (and to `label`, `icon`, `enableKey` in `boringNotch/models/LayoutCustomization.swift`).
2. Add an enable key under its own `// MARK:` in `boringNotch/models/Constants.swift`.
3. Create `boringNotch/components/<Feature>/` with a store (`@MainActor final class ...: ObservableObject`, `static let shared`) and a view.
4. Render it in the `switch coordinator.currentView` in `boringNotch/ContentView.swift`.
5. Filter it in `TabSelectionView` and add it to the tab-bar condition in `BoringHeader`.
6. Add a settings page in `boringNotch/components/Settings/SettingsView.swift`.
7. **Register every new `.swift` file in `boringNotch.xcodeproj/project.pbxproj`** (see below), then build.

## Layout

| Path | Role |
|------|------|
| `boringNotch/ContentView.swift` | Notch content: closed live activities, open tab switch, auto-close logic |
| `boringNotch/BoringViewCoordinator.swift` | Shared UI state: current tab, sneak peek, `isEditingText`, `isNotchLocked` |
| `boringNotch/models/BoringViewModel.swift` | Open / close state and sizing |
| `boringNotch/components/Notch/` | Header, notch shape, `NotchBackground` (glass mode), `NotchTextInputModifier` |
| `boringNotch/components/Tabs/` | Tab bar |
| `boringNotch/components/<Feature>/` | One folder per feature (Notes, Todos, Timer, SystemShortcuts, Bluetooth, Shelf, …) |
| `boringNotch/models/Constants.swift` | All `Defaults` keys |
| `boringNotch/models/LayoutCustomization.swift` | Tab and Home widget metadata and ordering |
| `boringNotch/components/Settings/` | Settings window and pages |
| `BoringNotchXPCHelper/` | Unsandboxed helper for privileged work |

## Key decisions

| Topic | Decision |
|-------|----------|
| Sandbox | The app is sandboxed. Anything that runs a CLI (`/usr/bin/shortcuts`, `/usr/sbin/system_profiler`) goes through the XPC helper. Edit **both** protocol copies (`BoringNotchXPCHelper/` and `boringNotch/XPCHelperClient/`). |
| Project files | App folders are classic Xcode groups: new files need a `PBXFileReference`, `PBXBuildFile`, group child and an entry in the app Sources phase. The `BoringNotchXPCHelper` and `private` folders are synchronized and pick up files automatically. |
| Settings | Use the `Defaults` package; read values in views with `@Default` so changes apply live. |
| User content | Stored as files in Application Support under `boringNotch/<Feature>/` (inside the sandbox container). |
| Keyboard input | The notch panel only becomes key on tabs where `NotchViews.acceptsKeyboardInput` is true, and only when the user clicks a text field. Use `.notchTextInput(isFocused:)` on text controls. |
| Auto-close | Every auto-close path checks `coordinator.preventsAutoClose` (editing text or locked). Explicit closes (shortcut, swipe up) always work and clear the lock. |
| Closed-notch activities | Battery / HUD first, then Bluetooth peek, then Timer, then music. Each activity also adds a branch to the closed width calculation in `ContentView`. |
| Header | The notch cover sits between two equal-width side groups (`minWidth: 0`) so it stays centered over the hardware notch; tabs shrink to fit. |
| Glass mode | Open notch uses `glassEffect` on macOS 26 and a behind-window `VisualEffectView` before that. The closed notch stays black to blend with the hardware. |

## Gotchas

- Quit Deckmian before rebuilding; replacing the binary of a running app kills it.
- The media source "YouTube Music" only talks to the YouTube Music desktop app. Use "Now Playing" for browsers.
- Most third-party Bluetooth devices do not report battery to macOS; battery UI is optional.
