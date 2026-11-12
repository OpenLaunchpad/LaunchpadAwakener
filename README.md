# LaunchpadAwakener

macOS 15's Launchpad, back on macOS 26 and macOS 27.

macOS 26 replaced Launchpad with the Apps view in Spotlight, and macOS 27 removed Launchpad's code from the Dock altogether. LaunchpadAwakener rebuilds macOS 15's Launchpad in Swift — the pages of icons, folders, search, drag-to-arrange, jiggle-to-delete and the animations — and picks up the layout macOS 15 left on your disk, so your pages and folders come back the way you had them.

It comes in two forms that share the same Launchpad code:

| | **LaunchpadAwakener** (injected) | **Launchpad** (standalone) |
|---|---|---|
| How it runs | A payload injected into the Dock draws Launchpad with the Dock's own window and layers, as macOS 15 did | An ordinary app draws Launchpad in a full-screen window of its own |
| System Integrity Protection | Must be fully disabled | Left alone |
| Opens from | The Launchpad key, the Dock's Apps icon, hot corners, the Apps app | Its own Dock icon, or a global shortcut you choose |
| Background | macOS 15's blurred wallpaper; Liquid Glass optional on macOS 27 | macOS 15's blurred wallpaper |
| Drag an app onto the Dock | Yes | No — the window covers the Dock |

LaunchpadAwakener carries the standalone app inside it. On a Mac with SIP turned on it injects nothing and offers to install and open the standalone app instead.

## Features

- **Looks and behaves like macOS 15.** Grid sizes, paging, folder animations, search and the open and close transitions were compared frame by frame against a real macOS 15.5. The `springboard-rows`, `springboard-columns` and other `springboard-*` defaults in `com.apple.dock` still apply.
- **Your macOS 15 layout.** On first launch, pages, folders and their order are imported from the database macOS 15 left behind. From then on new apps are added and deleted apps removed, as before.
- **Folders.** Drop one app onto another to make a folder, drag apps out of it, rename it.
- **Keyboard.** Type to search; arrow keys, Return and Esc; Command-arrow keys as in macOS 15. Cut, copy, paste and undo while typing.
- **Input methods** such as Pinyin work in the search field and when renaming a folder.
- **Deleting apps.** Hold Option or long-press an icon to make the icons jiggle; apps from the App Store get a delete button and a confirmation, by the same rule macOS 15 used.
- **Blue dot** on newly installed App Store apps until they are first opened.
- **Drag to the Dock.** Drag an app out of Launchpad onto the Dock to keep it there (injected version).
- **Several displays.** Launchpad opens on the display the Dock is on, like macOS 15.
- **Organize Launchpad** (injected version): a window that moves many apps at once, makes, renames and dissolves folders, sorts by name, and groups apps into folders by their App Store category.
- **Every Dock build.** The Dock's internals are found at runtime instead of by per-build addresses; every Dock build from macOS 26.0 to 27.2 has been checked. Each Dock method is checked against its type encoding before it is called or hooked, and if any one does not match nothing is installed, so the Dock carries on unmodified rather than half patched.

## Requirements

- macOS 26 or macOS 27 on a Mac with Apple silicon. An x86_64 slice is built for Intel Macs still on macOS 26, but it has never been tried.
- For the injected version: System Integrity Protection fully disabled with `csrutil disable`. A partially disabled configuration counts as enabled.
- To build: Xcode 27 (tested with 27.2).

## Installation

Download `LaunchpadAwakener-<version>.zip` from [Releases](https://github.com/OpenLaunchpad/LaunchpadAwakener/releases) and unzip it. The app is notarized and carries the standalone app inside it. You can also build both from source (see [Building](#building)).

### Injected version

> [!WARNING]
> Disabling System Integrity Protection lowers the security of the whole Mac, and LaunchpadAwakener runs code inside the Dock. Only do this on a Mac where you accept both.

1. Disable SIP: shut down, hold the power button until the startup options appear, choose **Options**, open **Utilities › Terminal**, run `csrutil disable` and restart.
2. Copy `LaunchpadAwakener.app` to `/Applications` and open it. It lives in the menu bar; its window says what it is waiting for.
3. Allow its background item in **System Settings › General › Login Items & Extensions**. This installs the privileged helper that does the injection and cannot be skipped.
4. Press the Launchpad key, click Apps in the Dock, or use a hot corner.

The app injects the Dock again every time the Dock restarts. Its window and menu also have **Restart Dock**, **Organize Launchpad**, and **Open the system's Apps instead** for going back to the system's Apps without quitting.

### Standalone version

On a Mac with SIP on, open LaunchpadAwakener and click **Install Launchpad**: it copies the standalone app it carries into `/Applications` and opens it. A source build also produces `Launchpad.app` on its own, to copy to `/Applications` yourself.

- Click its Dock icon to show Launchpad again.
- Its settings (**Settings…** in the Dock icon's menu) set a global shortcut and **Launch at login**.
- It never asks for screen recording permission; without it the blurred background is drawn from the desktop picture file.

## Preferences

Launchpad reads macOS 15's `springboard-*` defaults from `com.apple.dock`, such as `springboard-rows` and `springboard-columns`. One is new: on macOS 27 the injected version can put the Dock's Liquid Glass behind the pages instead of the blurred wallpaper.

```bash
defaults write com.apple.dock springboard-background -string glass
defaults delete com.apple.dock springboard-background   # back to the blur
```

## If something goes wrong

Launchpad takes over the whole screen. If it stops responding, from an SSH session or any terminal you can still reach:

```bash
touch /tmp/LaunchpadAwakener.disabled   # every way of opening Apps goes back to the system's; Launchpad closes on the next event
killall Dock                             # injected version: restart the Dock
pkill -x Launchpad                       # standalone version: quit it
```

The file is in `/tmp`, so restarting the Mac clears it. The standalone version also has a watchdog: when its main thread stops answering for three seconds, it pulls its window off the screen through the window server.

Logs:

```bash
/usr/bin/log show --info --last 5m --predicate 'subsystem == "com.MxIris.LaunchpadAwakener"'
```

## Known limitations

- The pinch gesture is not confirmed to work. On macOS 26 and 27.0 the Dock handles the pinch itself and still opens the system's Apps.
- Three-finger swipes between pages have not been tried on real hardware.
- No Liquid Glass background on macOS 26; it falls back to the blur.
- The delete confirmation is a system popover, so it looks like macOS 26 and 27 rather than macOS 15.
- Launchpad opens only on the Dock's display, as in macOS 15; this has not yet been verified with a second display attached.
- On the newest chips, macOS 27's Dock may run its new `arm64e.x1` slice; injecting into it has not been tried.
- Organize Launchpad has no undo.
- The standalone app's own windows are in English only; Launchpad itself follows the system language.

## How it works

macOS 26 and 27 both route every way of opening Launchpad — the Launchpad key, the Dock's Apps icon, hot corners and the Apps app — through a single Dock method, `-[Spotlight sendLaunchAppsBrowsing]`. The payload replaces that method and draws macOS 15's Launchpad, rewritten in Swift after macOS 15.5's own class structure, with the Dock's window and layer classes.

| Binary | Role |
|---|---|
| `LaunchpadAwakener.app` | Menu bar app: installs the helper, injects the Dock and re-injects it after restarts, shows status, organizes the layout |
| Privileged daemon | Root helper registered through `SMAppService` that performs the injection. It carries an arm64e slice, which injecting into an arm64e process such as the Dock requires |
| Payload | Loaded into the Dock: the hooks, and the Dock's side of the Launchpad host |
| Text input helper | A LaunchAgent inside the app that hosts the search and rename fields off screen, so input methods work inside the Dock; it also shows the delete confirmation |
| `Launchpad.app` | The standalone version: the same Launchpad in a window of its own |

Launchpad itself (`LaunchpadAwakenerSpringboardCore`) knows nothing about the Dock. It asks its host — the Dock or the standalone app — for the window, layer classes, wallpaper and icon style.

Calls into the Dock go through declarations whose type encodings are checked against the running Dock before first use, and hooks are installed as one atomic batch. A mismatch means nothing is installed, instead of a Dock that runs half hooked.

## Building

```bash
git clone https://github.com/OpenLaunchpad/LaunchpadAwakener.git
cd LaunchpadAwakener
./RunScript.sh --no-launch --configuration Release
```

This builds `LaunchpadAwakener.app`, with the standalone app embedded in it, into `DerivedData/arm64e/Build/Products/Release/` (`--derived-data <path>` puts it elsewhere). `--scheme LaunchpadAwakenerStandalone` builds only `Launchpad.app`. Without `--no-launch` the script opens the app it built. Set the signing team to your own first (`DEVELOPMENT_TEAM` in the project's build settings).

Build with `RunScript.sh` rather than a plain `xcodebuild`:

- The daemon needs an arm64e slice, which only the generic destination `generic/platform=macOS` produces. A build that silently drops it looks successful until injection fails, so the script checks every slice after building.
- Xcode 27's new package build system drops x86_64 from local packages that also build arm64e. The script turns it off for its own builds.

To build in Xcode itself, set the run destination to **Any Mac** rather than **My Mac**, and run `defaults write com.apple.dt.Xcode IDEEnableNewPackagePIFBuilder -bool NO` once — this affects every project.

Debug builds include safeguards for development; among them, Launchpad closes itself after 20 seconds without input.

> [!CAUTION]
> When working on the code, run it on a spare Mac or a virtual machine. Launchpad takes over the screen and the keyboard, and when it goes wrong the whole machine can stop accepting input.

### Tests

```bash
cd LaunchpadAwakenerPackage
swift test
```

The tests never put a window on screen and never touch the Dock.

### Project structure

| Directory | Contents |
|---|---|
| `LaunchpadAwakener/`, `LaunchpadAwakenerDaemon/`, `LaunchpadAwakenerPayload/`, `LaunchpadAwakenerTextInput/`, `LaunchpadAwakenerStandalone/` | Thin shells for the five binaries |
| `LaunchpadAwakenerPackage/` | All the code, split into modules by which binary links them |
| `Documentations/` | Proposals, implementation notes and the glossary ([index](Documentations/README.md), in Chinese) |

## Acknowledgements

- [swift-helper-service](https://github.com/Mx-Iris/swift-helper-service) and [MachInjector](https://github.com/MxIris-Reverse-Engineering/MachInjector) — the privileged helper and the injection
- [FrameworkToolbox](https://github.com/Mx-Iris/FrameworkToolbox) — logging, and the checked Objective-C runtime calls and hooks
- [UIFoundation](https://github.com/Mx-Iris/UIFoundation), [AppKitPlus](https://github.com/AppKitSupportProgram/AppKitPlus-Release), [swift-navigation](https://github.com/pointfreeco/swift-navigation) and [SnapKit](https://github.com/SnapKit/SnapKit) — the AppKit interface
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — the standalone app's global shortcut

## License

LaunchpadAwakener is free software, released under the GNU General Public License v3.0. See [LICENSE](LICENSE).

LaunchpadAwakener is not affiliated with or endorsed by Apple. Launchpad, Dock and macOS are trademarks of Apple Inc.
