# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.1] - 2026-11-24

### Fixed

- Caps Lock and modifier mappings left on the keyboard by a crash or forced quit are cleaned up at
  the next launch, and Keyshift restores them when it is stopped with a signal.
- A remapped key or mouse button no longer stays held down when Keyshift is paused or macOS
  briefly disables its event tap.
- Settings no longer rewrites a config file that has errors, which could silently delete the
  broken parts. Keyshift keeps five backups, and a file that failed to parse is kept as
  `config.yaml.invalid.bak`.
- A syntax error in the config file no longer turns remapping off: the previous configuration
  stays active until the file is fixed.
- A config file that is a symbolic link stays a link when Settings saves it.
- Editing a rule while the config file changes on disk can no longer change or delete a
  different rule.
- Scrolling with a modifier held no longer triggers that modifier's tap-alone action.
- Mappings on the keypad Clear key now match.
- The self-test no longer sends its test shortcut to the frontmost app.

### Added

- A warning for Caps Lock and modifier mappings that cannot fire. These keys can only be remapped
  to a single key, in rules that apply everywhere.
- A notice while macOS Secure Input (password fields, secure keyboard entry) pauses remapping,
  in Settings, the menu and `keyshift status`.
- The Karabiner import report lists every imported shortcut that runs a shell command.
- `scripts/uninstall.sh --reset-permissions`, and a summary of what uninstalling leaves behind.

### Security

- Shell commands started by a shortcut no longer inherit Keyshift's Accessibility and Input
  Monitoring permissions. A command that needs those permissions must be granted them itself.
- Shell shortcuts are ignored when the config file or its folder can be written by other users.
- Config files over 2 MB and YAML that expands to an excessive number of entries are rejected.
- Releases are built only from commits on `main` that pass the test suite, and a release without
  the signing certificate fails instead of being published with a different signature.

### Changed

- Opening an app by name is faster, and the Karabiner-Elements check no longer starts a process
  every few seconds.

## [0.1.0] - 2026-11-22

First public release. Keyshift brings familiar Windows and Linux shortcuts to macOS 13 Ventura
and later. The DMG includes a universal app for Apple silicon and Intel Macs.

### Added

- Windows, Linux and Terminal presets. The Windows preset includes Ctrl shortcuts, Finder
  navigation, window tiling and desktop switching, with exceptions for games, virtual machines
  and remote desktops.
- Keyboard and mouse remapping with macOS's event tap and keyboard-level mappings for bare
  modifiers and Caps Lock. No kernel or DriverKit extension is needed.
- English and Turkish settings with profiles, a shortcut recorder, conflict warnings, an event
  viewer and guided setup for Accessibility and Input Monitoring.
- App-specific rules based on bundle IDs, groups or path fragments such as Steam's
  `/steamapps/common/`, with optional text-field focus conditions.
- Layout-aware key names and a readable YAML configuration that reloads on save.
- Karabiner-Elements import with a report for reviewing converted and skipped rules.
- A `keyshift` command-line tool for checking configuration, switching profiles and testing remaps.
