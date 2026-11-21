# Testing

## Automated

```sh
swift test                 # unit tests: engine, config parser, presets, importer, conflicts
keyshift check             # validate ~/.config/keyshift/config.yaml (or KEYSHIFT_CONFIG)
keyshift selftest          # quick Ctrl+C → Command+C probe
keyshift selftest --suite  # live Windows preset suite in the running app
```

CI (`.github/workflows/ci.yml`) runs `swift build`, `swift test`, validates every file in `Presets/`
and builds a universal `Keyshift.app`.

What the unit tests cover: the engine is pure logic (key events in, actions out), so rule matching,
exact-vs-passthrough precedence, tap/hold and scoping are tested without macOS permissions.

## Live suite

Launch the installed Keyshift app in a logged-in macOS session with Accessibility and Input
Monitoring granted. Enable remapping and select the Windows preset. Run `keyshift selftest --suite`
from a shell. The CLI sends the request to the running app over IPC. The app prints the observed
results through the CLI and exits the command with status 1 if any row is `FAIL`. Accessibility
checks report `WARN` when app activation or text focus cannot be verified. The HID check reports
`SKIP` when no keyboard service is available. Warnings and skips do not change the exit code.

The suite checks the loaded profile against the Windows preset’s shortcuts, per-app and game-path
scopes, Finder focus rules, dry-run actions, modifier taps, mouse remaps, autorepeat, and key release
after the input modifiers change. Two probe-only mappings also verify that emitted key events reach
the observer. The active session tap swallows marked input and output before delivery to apps.
The two real Accessibility checks briefly open a blank TextEdit document and a Finder window at
home, then close the probe windows and return focus to the previous app. When Apple Events
permission is unavailable, the checks use Launch Services.

The HID check temporarily applies Caps Lock → Escape in memory and uses `hidutil` to verify the
mapping and its restoration. The suite leaves the config file and active profile unchanged.

## Manual checklist

Build with `scripts/build-app.sh`, then run `dist/Keyshift.app` (grant Accessibility and Input Monitoring).

- [ ] Onboarding shows both permissions; after granting, `keyshift status` reports the engine running.
- [ ] Windows preset: Ctrl+C/V/X/Z in TextEdit; Ctrl+Shift+Z redo; Ctrl+←/→ word jump, Shift extends the selection; Home/End.
- [ ] Finder: F2 renames, Enter opens, Delete trashes — but not while renaming (text field focused).
- [ ] Terminal (not in Secure Keyboard Entry): Ctrl+C still interrupts; Ctrl+Shift+C/V copy and paste.
- [ ] Browser: Ctrl+L, Ctrl+T, Ctrl+Shift+T, Ctrl+1…9, F5.
- [ ] Tapping left ⌘ alone opens Spotlight; ⌘C still copies.
- [ ] Editing `config.yaml` reloads within a second; an invalid rule is reported by `keyshift check` and the rest still works.
- [ ] Switching profile from the menu bar and `keyshift profile <name>` takes effect immediately.
- [ ] `keyshift import-karabiner` on a sample `karabiner.json` produces a loadable profile.
- [ ] Password field: remaps do not apply (expected, see README → Limitations).
- [ ] Rebuilding with the same signing identity keeps the granted permissions.

## Release check

1. `VERSION` and the top `CHANGELOG.md` section match; tag `vX.Y.Z`.
2. `scripts/build-app.sh && scripts/make-dmg.sh`; `lipo -archs` shows `x86_64 arm64`.
3. `codesign --verify --deep --strict dist/Keyshift.app`; open the DMG, copy, run the `xattr` command and launch.
