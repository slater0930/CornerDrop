# Corner Drop

Menu bar app: hover a screen corner to see your most recent downloads. Drag them into any app,
click a folder to see what's inside, press Space for Quick Look. New downloads "peek" out of
the corner. Updates itself with [Sparkle](https://sparkle-project.org).

## Build & install

```bash
./build.sh --install   # builds, copies to ~/Applications, relaunches
```

Needs only the Xcode Command Line Tools (Swift 6). Launch with `--show` to open the list
immediately (handy for testing):

```bash
open ~/Applications/CornerDrop.app --args --show
```

## Releasing an update

Commit your changes, then:

```bash
scripts/release.sh 1.2.0 "What changed"
```

This bumps the version, builds and signs the app, zips it, signs the zip with the Sparkle key,
writes `appcast.xml`, uploads the zip as a GitHub Release and pushes. Installed copies pick it
up on their next daily check (or via **Check for Updates…** in the menu bar).

### Keys that live only in this Mac's login keychain

- **Sparkle update key** ("Private key for signing Sparkle updates"): signs every update.
  If it's lost, installed copies can't accept new updates. Back it up:
  `tools/sparkle/bin/generate_keys -x sparkle-private-key.txt` and store the file somewhere safe
  (not in this repo).
- **"Corner Drop Signing" certificate**: code-signs the app so macOS keeps its Downloads
  permission across updates. Without it, `build.sh` falls back to an ad-hoc signature.

## Layout

- `PanelController.swift` – corner detection (cursor polling), floating panel, show/peek/hide, actions, folders
- `FileStore.swift` – FSEvents folder watcher, scanning, filtering, new-file detection
- `Views.swift` – SwiftUI list, rows, folder expansion, scrolling names, trash confirm, thumbnails
- `RowInteractionView.swift` – AppKit hover/click/right-click/drag layer over each row
- `Updater.swift` – Sparkle wrapper
- `SettingsView.swift` – Settings window
- `AppSettings.swift` – persisted preferences
