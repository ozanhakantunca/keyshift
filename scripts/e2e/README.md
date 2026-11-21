# Keyshift end-to-end verification

Run from the repository root as the macOS console user.

```sh
scripts/e2e/run.sh
```

The runner expects the installed Keyshift to be running with the Windows profile.
It builds the Swift 6 helper under `.build-e2e/harness`, signs it with the
existing **Keyshift Self-Signed** certificate, and starts it with Launch Services.
The helper keeps bundle ID `io.github.ozanhakantunca.keyshift.e2e` and install path
`~/KeyshiftE2E/KeyshiftE2E.app` across rebuilds.

The helper checks Accessibility, event posting, Input Monitoring, and Screen
Recording before opening fixtures. It owns the AX calls, capture, HID injection,
and listen-only annotated-session event tap. Ordinary HID cases post individual
modifier changes and key or mouse events from a HID-system event source. The
autorepeat case explicitly sends repeat key-downs about 30 ms apart.

The VNC client uses the loopback Screen Sharing server on port 5900 and Apple
Remote Desktop authentication (RFB security type 30, Diffie-Hellman plus
AES-128-ECB, as in noVNC); legacy type 2 gives a view-only session and is only used
with `run.sh --resume --vnc-legacy vnc`. The user is
`KEYSHIFT_VNC_USER` (default: `$USER`). The password comes from `KEYSHIFT_VNC_PASSWORD`
or a file named by `KEYSHIFT_VNC_PASSWORD_FILE`; it is read at run time and never printed,
logged or written. Screen Sharing must be enabled for that user. It
uses `cryptography` from `~/tools/novnc-venv/bin/python`. Pointer events sent over
this session produce no cursor movement or mouse events on this Mac; no case needs them. It records keysym traffic
and annotated delivery without recording authentication data or remote clipboard
contents.

Results are in `~/KeyshiftE2E/report/`. `report.md` summarizes each case and
links its numbered PNG. `results.json` includes state assertions, HID or RFB
input, the annotated event traces, latency samples summarized as percentiles,
the current input-source translations, and the final Keyshift status. A failed
assertion retains its evidence. Lock, sleep, and reboot are marked parent-owned.

The full command creates a fresh report. To retain the prior report and retry
named groups with the same configuration digest, use, for example:

```sh
scripts/e2e/run.sh --resume finder vnc
```

Groups are `text`, `system`, `finder`, `chrome`, `safari`, `terminal`,
`ghostty`, `exclusions`, `robustness`, `vnc`, and `ui`. Exit status 2 means
at least one case or cleanup check failed or is incomplete.

The runner records existing windows before each fixture, isolates Chrome in
`~/KeyshiftE2E/chrome-profile`, restores the original clipboard and both config
files, and removes its fixture windows, Trash items, and system screenshots.
It reloads the original config, verifies the SHA-256, and checks that Windows
and remapping are active and `UserKeyMapping` is null.

Results can be `pass`, `fail`, `parent`, or `impossible`. A case is marked
`impossible` only after the harness has proved the reason in the same run, and the
reason is written to the report. The only such case is Chrome zoom-in on a layout
with no Command `=` key (a native-key probe proves it). Firefox and Opera are not
installed, so their Ctrl+J rules run against signed fixture apps that carry those bundle
IDs and log the real NSEvents they receive; the fixtures are unregistered and deleted
afterwards. Home/End (Command+arrows; the Spaces shortcuts are back on Control+arrows)
and Win+←/→ window tiling (Keyshift's `tile_left`/`tile_right` Accessibility actions; checked
against `NSScreen.visibleFrame` within `TILE_TOLERANCE` points, window restored afterwards) are
ordinary pass/fail cases.

Win+Ctrl+←/→ (`ctrl+cmd+arrow → ctrl+arrow`) must switch Spaces. The case reads the active Space
and the Space list with SkyLight (`space` helper operation), requires the TextEdit fixture window
to leave and re-enter the screen, and always returns to the original Space. The macOS Spaces
hotkey consumes the event before the annotated tap, so the tap legitimately sees no arrow key.
The case starts from the app that was frontmost before the run, because macOS can bounce a
switch straight back when another app is in front of an empty Space.

Key names in the harness follow the character on the keycap, as Keyshift does
(`adapt_layout`). F1 and F2 are posted without the fn flag, because the HID system
turns fn+F1/F2 into the brightness keys.
