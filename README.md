# Rafale

**Drop a folder of installers, type your password once, walk away.**
Rafale reads every `.dmg`, `.pkg` and `.zip` you give it, tells you what each one would do to your Mac, then installs the whole batch in a row. The app is 5.2 MB and idles at 0 % CPU and 44 MB of memory.

Rafale replaces the ritual of a fresh macOS install: open an image, drag the app, eject, open the next package, click Continue five times, type the password again. *Rafale* is French for a burst — a volley fired in one go.

- **One password for the whole batch.** Everything that needs root is grouped into a single authorization, however many packages are queued.
- **You see before you install.** Version, signature, notarization, installed size and what is already on the Mac, for every file, before anything runs.
- **Nothing gets downgraded by accident.** Items that are already installed in the same or a newer version are left unchecked.
- **Unsigned software is never installed silently.** Anything Gatekeeper would not accept is unchecked by default and needs an explicit confirmation.
- **Read what a package runs as root.** The pre- and post-install scripts of a `.pkg` are one click away.
- **Replay the same batch later.** Save the queue as a named list and load it again on the next reinstall.
- **Native and light.** Swift and SwiftUI, no Electron, no background daemon left on the system.

### Support the project

Free and open-source 🙂 — if you feel like it, buy me a few tokens:

[![Buy me tokens](docs/buy-me-tokens.png)](https://paypal.me/lbenh)

**Contents:** [The queue](#the-queue) · [Analysis](#analysis) · [Installation run](#installation-run) · [Saved lists](#saved-lists) · [Keyboard shortcuts](#keyboard-shortcuts) · [macOS integration](#macos-integration) · [Installing Rafale](#installing-rafale) · [Building](#building) · [Releasing](#releasing) · [Known limits](#known-limits) · [Project layout](#project-layout)

## The queue

- Drop files or whole folders on the window or on the Dock icon, or use **Add** (⌘O). Folders are walked recursively; app bundles and packages are not entered.
- Each file is one row: name, type (`PKG`, `DMG → App`, `DMG → PKG`, `ZIP → App`…), version, what is already installed, signature, size and status.
- Columns sort on click, can be reordered and resized; their layout is remembered.
- The checkbox decides whether a row is part of the next run. Space toggles the selection.
- The details pane shows identifiers, destination, package components, notes and the log of the last run.
- The queue survives a relaunch.

## Analysis

- **Packages** — identifier, version, installed size and scripts are read from the package table of contents without unpacking the payload. When the package declares an application bundle, its version is shown instead of the package version, which vendors often leave at `1.0`.
- **Disk images** — mounted read-only and hidden from Finder, inspected, then unmounted. A license agreement embedded in the image is accepted automatically, and the row says so. Encrypted images are reported, not opened.
- **Archives** — the zip directory is listed first; only archives that contain an app or a package are extracted.
- **Already installed** — apps are compared with the copy in `/Applications`, packages with their receipts: *not installed yet*, *update*, *same version* or *newer one installed*.
- **Signature** — *Notarized*, *Signed*, *Not notarized* or *Unsigned*, with the developer name. The verdict is read from Gatekeeper and still holds when assessments are disabled on the Mac.
- **Interactive installers** — an image that only contains an installer application cannot be automated. It is flagged and opened for you when the run ends.

## Installation run

- Apps are copied next to their destination and swapped in, so a failed copy never leaves a half-written app.
- An app that is running is not overwritten: Rafale offers to quit it or to leave it out of the run.
- Packages and apps that need elevated rights go through one administrator prompt.
- Progress is shown per row, with the phase reported by the macOS installer.
- A failure does not stop the run; the row keeps the error and can be retried.
- **Stop** lets the current operation finish and skips the rest.
- Optionally, installed files are moved to the Trash when they succeed.

## Saved lists

- **Lists → Save Queue as List…** stores the files of the current queue under a name.
- Loading a list adds its files to the queue and reports the ones that are missing.
- Lists live in `~/Library/Application Support/Rafale/lists.json`.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘O | Add files or a folder |
| ⌘↩ | Install checked items |
| ⌘S | Save the queue as a list |
| ⇧⌘⌫ | Clear the queue |
| Space | Check or uncheck the selection |
| ⌫ | Remove the selection from the queue |
| ⌘+ / ⌘- / ⌘0 | Zoom in, zoom out, actual size |

## macOS integration

- Interface in English and French, following the system language.
- Menu bar icon: open the window, install the queue, add files, about, check for updates, quit. Rafale keeps running when its window is closed.
- Window size and position, column layout and zoom level (70 % to 200 %) are remembered.
- Automatic updates through Sparkle.

## Installing Rafale

1. Download the latest `Rafale-x.y.z.zip` from the releases page and move `Rafale.app` to `/Applications`.
2. Rafale is not notarized. On first launch, right-click the app and choose **Open**, or allow it in **System Settings → Privacy & Security**.
3. To replace apps that other developers signed, macOS asks for **App Management**. Grant it in **System Settings → Privacy & Security → App Management**; otherwise those replacements fail.

## Building

Requires Xcode command line tools with Swift 5.9 or later.

```bash
./build.sh
```

The app is assembled in `build/Rafale.app`. To sign with your own certificate, write its name in a local `.identite` file or run `IDENTITE="Certificate Name" ./build.sh`; without either, the build is ad hoc signed. The icon is drawn by `tools/make-icns.sh`.

## Releasing

```bash
./release.sh 0.2.0
```

Bumps the version, builds, zips, signs the archive with the Sparkle key from the keychain, generates `appcast.xml`, tags and creates the GitHub release.

## Known limits

- Rafale is not sandboxed and not notarized; it cannot be distributed through the Mac App Store.
- Interactive installers, encrypted disk images and password-protected archives are not automated.
- The administrator prompt is the standard macOS one and is shown under the name `osascript`.
- A package that requires a restart is installed, but Rafale does not restart the Mac.
- There is no uninstaller and no download from a URL.
- Files cannot be dropped on the menu bar icon; use the window or the Dock icon.

## Project layout

| Path | Role |
|---|---|
| `Sources/Rafale/Analyzer.swift` | Reads packages, disk images and archives; signature checks |
| `Sources/Rafale/BatchRunner.swift` | Runs a batch: app copies, single elevated script, progress |
| `Sources/Rafale/AppModel.swift` | Queue, saved lists, session |
| `Sources/Rafale/QueueTable.swift` | Queue table and its cells |
| `Sources/Rafale/ContentView.swift` | Main window, toolbar, details pane |
| `Sources/Rafale/RafaleApp.swift` | App entry, menus, menu bar item, About window, updater |
| `Sources/Rafale/Models.swift`, `Support.swift` | Data types, shell and localization helpers |
| `Resources/` | `Info.plist`, icons, translations |
| `tools/` | Icon drawing scripts |
| `build.sh`, `release.sh` | Build and release |
