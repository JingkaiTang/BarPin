# BarPin

BarPin is a macOS menu bar utility that provides app-hosting “bubble” controls.

It turns frequently used apps into menu-bar-associated bubble entries: click to show/hide quickly, keep size preferences, and maintain a consistent visual link to the menu bar.

Chinese version: [README.md](README.md)

![BarPin Screenshot](assets/barpin-screenshot.png)

## Features

- Multiple independent pins (one menu bar icon per app)
- Per-pin optional hotkeys
- Hotkey conflict detection (conflicts are blocked)
- Smart toggle behavior:
  - If app is frontmost: hide
  - If app is in background: bring to front
  - If no visible window: reopen and position
- Per-app window size memory
- Icon modes (App icon / Pin icon, Gray / Color)
- Chinese/English language switch
- Debug log toggle
- Built-in management panel for all pins (add/remove/hotkey/icon settings)

## Important First-Launch Note

BarPin is currently distributed without Apple Developer ID signing and notarization.
On first launch, macOS may show warnings like “damaged” or “cannot verify developer”.
This is expected behavior from macOS security policy.

To allow launch manually:

1. In Finder, right-click (or Control-click) `BarPin.app`, then choose “Open”.
2. Click “Open” again in the confirmation dialog.
3. If still blocked, go to “System Settings > Privacy & Security” and click “Open Anyway”.

After one successful manual approval, future launches are usually normal.

> Update note: for unsigned/unnotarized builds, replacing `BarPin.app` may be treated as a new app identity by macOS. You may need to re-approve launch and Accessibility access. If an old BarPin entry exists under Accessibility, remove it first and add the new one again.

## Permissions

BarPin uses Accessibility APIs to move/resize/focus external app windows.
Grant permission in:

- System Settings > Privacy & Security > Accessibility

## Run

This project is a SwiftPM executable.
Run from Xcode or:

```bash
swift run
```

## Automated Testing

### Logic Checks (CI-friendly)

```bash
swift run BarPinCoreChecks
```

### Local E2E (manage window reopen flow)

```bash
APP_PATH=dist/BarPin.app scripts/e2e_barpin.sh
```

Notes:
- The script requires macOS Accessibility/Automation permissions for System Events.
- It validates that reopening BarPin while running reliably brings up the management window.

## Structure

- `Package.swift`: SwiftPM config
- `Sources/BarPin/main.swift`: main application logic
