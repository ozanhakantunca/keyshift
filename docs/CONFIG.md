# Keyshift config format (v1)

File: `~/.config/keyshift/config.yaml` (override with `KEYSHIFT_CONFIG`). The app watches it and
reloads on save. The settings UI reads and writes the same file (comments are not preserved when the
UI saves; a `config.yaml.bak` of the previous version is kept).

```yaml
version: 1
profile: Windows            # selected profile name
settings:
  tap_timeout_ms: 500
  menu_bar_icon: true
  launch_at_login: true

app_groups:                 # referenced by name in only/except
  terminals: [com.mitchellh.ghostty, com.apple.Terminal, com.googlecode.iterm2]
  browsers: [com.google.Chrome, com.apple.Safari, org.mozilla.firefox]
  games:                    # entries with a "/" are path fragments (see Scope)
    - /steamapps/common/
    - /Epic Games/
    - /League of Legends.app/

profiles:
  - name: Windows
    rules:
      - name: Windows Ctrl shortcuts
        except: [terminals, games]   # or: only: [...]; omitted = everywhere
        map:
          ctrl+[c v x z a s n f w t b i]: cmd+$1   # bracket expansion, $1 = the expanded key
          ctrl+y: cmd+shift+z
          alt+f4: cmd+q

      - name: Text navigation
        passthrough: [shift]          # default [shift]; [] disables; e.g. [shift, alt]
        map:
          home: cmd+left              # shift+home → cmd+shift+left automatically
          end: cmd+right
          ctrl+home: cmd+up

      - name: Finder
        only: [com.apple.finder]
        focus: not_text_input         # any (default) | text_input | not_text_input
        map:
          f2: return
          return: cmd+o
          delete: cmd+backspace

      - name: Launchers
        enabled: true                 # default true
        map:
          left_cmd: { tap: launchpad }          # tap alone → action; held → still cmd
          ctrl+alt+t: { open: Ghostty }         # app name, bundle id or path
          ctrl+shift+esc: { open: "Activity Monitor" }
          cmd+l: { system: lock_screen }
          ctrl+alt+g: { url: "https://github.com" }
          ctrl+alt+s: { shell: "say hello" }
          f5: [cmd+r]                           # list = key sequence
          caps_lock: none                       # disable
          ctrl+left_click: cmd+left_click       # mouse
```

## Grammar

- **Combo**: `mod+mod+key`, case-insensitive. Modifiers: `ctrl|control`, `alt|opt|option`, `shift`,
  `cmd|command|win|super|meta`, `fn`. Keys: see `KeyNames` in `Sources/Core/Keys.swift`
  (`backspace` = ⌫, `delete` = forward delete ⌦, `return|enter`, `left_cmd`, `code:110` …).
  Mouse triggers/targets: `left_click right_click middle_click button4 button5`.
- **Bracket expansion**: a single `[a b c]` group in the left side expands to one mapping per item;
  `$1` on the right side is replaced by the item. Items are space- or comma-separated.
- **Action values**: a combo string; a list of combos (sequence); `none`; or a one-key map:
  `{ open: X }`, `{ url: X }`, `{ shell: X }`, `{ system: X }`, `{ tap: <action> }` (only on a bare
  modifier key; `<action>` is a combo, a system action name, or a nested map).
  `system` names: launchpad, mission_control, app_windows, show_desktop, spotlight, lock_screen,
  sleep_display, logout, screenshot, screenshot_area, screenshot_window, notification_center, force_quit,
  tile_left, tile_right, tile_top, tile_bottom, maximize, center (move/resize the focused window to that
  part of the screen's visible area via Accessibility; fullscreen and non-resizable windows are left alone).
- **Scope**: `only` / `except` lists of bundle ids, path fragments or app group names (an entry that
  names a group in `app_groups` expands to it; groups may mix bundle ids and path fragments). Both present = error.
  - A **bundle id** (`com.apple.finder`) matches the frontmost app exactly, case-insensitively.
  - An entry containing **`/`** is a **path fragment**: it matches when it occurs anywhere, case-insensitively,
    in the frontmost app's bundle path (`/Applications/Foo.app`, or the executable path for apps without
    a bundle). Use it for apps without a stable bundle id, e.g. everything installed by Steam
    (`/steamapps/common/`), Epic (`/Epic Games/`) or a single app (`/League of Legends.app/`).
    It is a plain substring, not a glob or regex.
- **Order**: rules top to bottom, mappings in file order; first match wins. Exact modifier
  match beats passthrough match across the whole profile.

## Modifier & Caps Lock remaps

A bare key mapped to a single bare key uses macOS's keyboard-level `UserKeyMapping` when
either key is a modifier or Caps Lock. Put these mappings in enabled rules with global scope
and `focus: any` in the active profile.

```yaml
map:
  caps_lock: escape
  left_ctrl: left_cmd
```

Keyboard-level mappings apply before the event tap, including when other modifiers are held.
The first eligible mapping for a physical key wins. The event tap sees the resulting key and
handles chord and tap-alone rules. Keyshift restores the previous keyboard mappings when
remapping is paused, while a shortcut is being recorded, and on quit.

## Errors

Parsing is tolerant: an invalid mapping/rule is skipped and reported as a diagnostic
(`line`, `message`), the rest of the config still loads. The UI and `keyshift check` show diagnostics.

## Importing from Karabiner-Elements

`keyshift import-karabiner` converts `karabiner.json` profiles. Besides keys and actions it understands:

- `frontmost_application_if` / `_unless` with `bundle_identifiers` and `file_paths`. A `file_paths` regex
  that is just a literal (`/steamapps/common/`, `/League of Legends\.app/`, optionally anchored with `^`/`$`)
  becomes a path fragment; any other regex is dropped with a warning (a condition left with nothing usable skips
  the manipulator).
- `variable_if` / `variable_unless` on `accessibility.focused_ui_element.role_string`: text roles
  (`AXTextField`, `AXTextArea`, `AXComboBox`, `AXSearchField`, `AXSecureTextField`) become `focus: text_input`;
  list-like roles (`AXOutline`, `AXList`, `AXBrowser`, `AXScrollArea`, `AXLayoutArea`, `AXCollection`, `AXTable`,
  `AXGroup`, `AXImage`, `AXCell`, `AXRow`) become `focus: not_text_input`. Karabiner configs usually repeat a
  manipulator once per role; manipulators that end up identical are merged into one mapping, while the same
  trigger with different text / non-text actions keeps both mappings.
- `print_screen` is imported as `f13` (the same key code on Mac keyboards).

Other variables, `input_source_*` and device conditions are skipped and listed in the report.
