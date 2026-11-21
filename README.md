<p align="center">
  <img src="Resources/AppIcon/Keyshift.png" width="128" alt="Keyshift icon">
</p>

<h1 align="center">Keyshift</h1>

<p align="center">
  A free, open-source keyboard remapper for macOS that brings Windows and Linux shortcuts to your Mac.
  <br>
  <a href="README.tr.md">Türkçe</a> ·
  <a href="https://github.com/ozanhakantunca/keyshift/releases">Download</a>
</p>

---

Keyshift is a lightweight alternative to Karabiner-Elements for everyday shortcuts. Use a preset
to get started, then adjust the keys you want from the menu bar.

## Features

- **Keyboard and mouse remapping** with macOS's event tap (CGEventTap), with no kernel or DriverKit
  extension required. Global single-key remaps involving a modifier or Caps Lock use macOS's
  keyboard-level mapping, the same mechanism as `hidutil`.
- **Settings in English and Turkish** with profiles, rules, a shortcut recorder, conflict warnings
  for overlapping rules and macOS shortcuts, and an event viewer.
- **Per-app rules** by bundle ID, app group or path fragment such as `/steamapps/common/`. Rules can
  also apply only when an editable text field has focus or only when it doesn't.
- **Windows, Linux and Terminal presets** for familiar desktop shortcuts and terminal editing.
- **Layout-aware key names** follow the active keyboard layout, including Turkish Q and other non-US
  layouts.
- **Karabiner import** for existing rules and a **YAML config** that reloads on save.
- **Local processing** with no built-in network requests or telemetry.

Requires macOS 13 Ventura or later. The release includes a universal binary for Apple silicon and
Intel.

## Install

### Download (DMG)

1. Download `Keyshift-0.1.0.dmg` from [GitHub Releases](https://github.com/ozanhakantunca/keyshift/releases)
   and drag **Keyshift** into **Applications**.
2. The app is signed with a self-signed certificate and does not have Apple notarization, so the
   first launch is blocked. Open it once, then go to **System Settings → Privacy & Security** and
   click **Open Anyway**. On macOS 13 and 14, you can also right-click the app in Finder and choose
   **Open**. [Apple's Gatekeeper instructions](https://support.apple.com/en-us/102445),
   [change in macOS 15](https://developer.apple.com/news/?id=saqachfa). Or run:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Keyshift.app
   ```

### Build from source

Needs Xcode Command Line Tools with Swift 6 or later (`xcode-select --install`).

```sh
git clone https://github.com/ozanhakantunca/keyshift
cd keyshift
./scripts/create-signing-cert.sh   # once, to keep permissions across rebuilds
./scripts/install.sh --with-cli    # build, install and link the keyshift command
```

### Permissions

On first launch, Keyshift walks you through two permissions in **System Settings → Privacy & Security**.

- **Accessibility** lets Keyshift send remapped shortcuts and control windows.
- **Input Monitoring** lets Keyshift read the keys you press.

If Keyshift detects Karabiner-Elements running, it shows a warning in Settings and in the menu bar.
Quit Karabiner-Elements or turn off its rules to avoid double remapping.

## Usage

Choose a preset in the welcome window. Use the menu-bar icon to switch profiles, pause remapping
or open **Settings**. The Linux preset includes GNOME-style shortcuts. The Terminal preset adds
word and line navigation and Ctrl+Shift+C/V in supported terminals, where Ctrl+C still interrupts.

### Coming from Windows

Choose the **Windows** preset. On a PC keyboard in Windows mode, **Win is ⌘** and **Alt is ⌥**.

| Keys | Action |
|---|---|
| Ctrl+C/V/X and other common Ctrl shortcuts | Send their ⌘ equivalents outside the preset's terminal, game, VM and remote desktop exceptions |
| Home/End, Ctrl+←/→, Ctrl+Backspace | Go to the start/end of a line, move by word, delete the previous word |
| Alt+F4 | Close the window in supported apps |
| F2, Enter, Delete, Backspace in Finder | Rename, open, move to Trash, go to the parent folder while browsing files |
| Tap left Win | Open Spotlight |
| Win+E, Win+L, Win+D | Open Finder, lock the screen, show the desktop |
| Win+←/→, Win+Ctrl+←/→ | Tile the window left/right, switch desktops using the macOS Mission Control shortcuts |
| Print Screen (if it sends F13) | Take a screenshot |
| Ctrl+Shift+Esc | Open Activity Monitor |
| Ctrl+L/J, F5, Ctrl+1–9 in supported browsers | Focus the address bar, open downloads where mapped, reload, select tabs |

## Configuration

Open **Settings** from the menu bar to edit profiles and rules. The same settings live in the
human-readable `~/.config/keyshift/config.yaml` file. Keyshift watches it and reloads on save.
For example, this profile maps F2 to Rename while you're browsing files in Finder.

```yaml
version: 1
profile: My shortcuts
profiles:
  - name: My shortcuts
    rules:
      - name: Rename in Finder
        only: [com.apple.finder]
        focus: not_text_input
        map:
          f2: return
```

See the [configuration reference](docs/CONFIG.md) for scopes, key names and actions.

## Command line

If you installed with `--with-cli`, run:

```sh
keyshift status                  # show profile, engine and permissions
keyshift reload                  # reload config in the running app
keyshift check [path]            # validate YAML and show conflicts
keyshift profile [name]          # list or switch profiles
keyshift import-karabiner [path]   # import karabiner.json
keyshift selftest [--suite]       # probe remapping or run the live Windows suite
keyshift open [section]          # open Settings
keyshift --help                  # show all options
```

The importer defaults to `~/.config/karabiner/karabiner.json`. Add `--dry-run` to preview the report,
then review the imported rules in Settings before switching profiles.

## Troubleshooting

- **A shortcut does nothing.** Check the active profile, permissions and the Settings conflict
  warnings. Use the event viewer to see what Keyshift receives. macOS Secure Input can block remaps
  in password fields and when Secure Keyboard Entry is on in a terminal.
- **Win does nothing or Win and Alt are swapped.** Set a PC keyboard's Windows/Mac switch to
  **Windows mode** for the Windows preset. On a gaming keyboard, check for a **Win Lock**, often
  toggled with **Fn+Win**.
- **The `"` and `<` keys are swapped.** On an ISO keyboard these are the keys next to 1 and left
  Shift. Go to **System Settings → Keyboard → Change Keyboard Type**, select **ISO**, then reconnect
  the keyboard. [Apple's keyboard type guide](https://support.apple.com/guide/mac-help/mchlp2886/mac).
- **Ctrl+= doesn't zoom in in Chrome on Turkish Q.** The layout has no unshifted `=` key for this
  mapping. Ctrl+Minus and Ctrl+0 still zoom out and reset zoom.
- **Permissions keep coming back after a rebuild.** Use the same local signing identity for each
  build, or run `tccutil reset All io.github.ozanhakantunca.keyshift`, relaunch and grant them again.

## Uninstall

Quit Keyshift and move it from Applications to the Trash. From a source checkout,
`./scripts/uninstall.sh` also removes the CLI link. Add `--purge-config` to remove
`~/.config/keyshift`.

## Compared with Karabiner-Elements

Keyshift handles shortcuts in your logged-in session, with an event tap and a plain YAML file.
Karabiner-Elements uses a DriverKit virtual keyboard and supports device-specific rules. Keyshift's
rules apply across keyboards, and event-tap rules are limited to the desktop session. Check the
import report for rules that need manual changes. [Karabiner-Elements documentation](https://karabiner-elements.pqrs.org/docs/).

## Contributing

CI runs unit tests, and `scripts/e2e` tests with real input in a macOS session. See the
[testing guide](docs/TESTING.md), [end-to-end harness](scripts/e2e/README.md) and
[contribution guide](CONTRIBUTING.md).

## License

[GPL-3.0](LICENSE)
