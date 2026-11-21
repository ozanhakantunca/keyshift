# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
