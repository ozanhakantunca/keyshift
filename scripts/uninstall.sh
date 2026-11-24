#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
usage() {
    cat <<'HELP'
Usage: scripts/uninstall.sh [--prefix <dir>] [--purge-config] [--reset-permissions]

Quit Keyshift and remove Keyshift.app plus CLI symlinks pointing to that app.
Default locations: /Applications and ~/Applications. --prefix selects one.
KEYSHIFT_CLI_BIN_DIR selects an additional CLI directory to check.
Dangling keyshift CLI links left by dragging the app to the Trash are removed too.
--purge-config also removes ~/.config/keyshift. Otherwise settings are preserved.
--reset-permissions runs: tccutil reset All io.github.ozanhakantunca.keyshift
  (clears the Accessibility and Input Monitoring grants; without it they stay in
  System Settings > Privacy & Security).
The "Launch at login" entry is not removed by this script (Keyshift has no command
for it); remove it under System Settings > General > Login Items & Extensions.
The login keychain is never modified. You may manually remove the
"Keyshift Self-Signed" signing identity in Keychain Access if no longer needed.
--help shows this help.
HELP
}
prefix=
purge=false
reset_permissions=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            [ "$#" -ge 2 ] && [ -n "$2" ] || keyshift_die '--prefix requires a directory.'
            prefix=$2; shift 2 ;;
        --purge-config) purge=true; shift ;;
        --reset-permissions) reset_permissions=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) keyshift_die "Unknown argument: $1 (see --help)." ;;
    esac
done
keyshift_require_macos
if [ -n "$prefix" ]; then
    [ -d "$prefix" ] || keyshift_die "Installation directory not found: $prefix"
    prefixes=("$(cd "$prefix" && pwd)")
else
    prefixes=(/Applications "$HOME/Applications")
fi
# Verify the bundle identity before removing anything.
for directory in "${prefixes[@]}"; do
    app="$directory/Keyshift.app"
    if [ -e "$app" ] || [ -L "$app" ]; then
        [ ! -L "$app" ] || keyshift_die "Refusing to remove symlinked app: $app"
        identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
        [ "$identifier" = io.github.ozanhakantunca.keyshift ] || keyshift_die "Unexpected bundle identity: $app"
    fi
done
keyshift_quit
removed=()
for directory in "${prefixes[@]}"; do
    app="$directory/Keyshift.app"
    for bin_dir in /usr/local/bin "$HOME/.local/bin" "${KEYSHIFT_CLI_BIN_DIR:-/usr/local/bin}"; do
        link="$bin_dir/keyshift"
        if [ -L "$link" ] && [ "$(readlink "$link")" = "$app/Contents/MacOS/Keyshift" ]; then
            rm "$link"
            removed+=("$link")
        fi
    done
    if [ -d "$app" ]; then
        rm -rf "$app"
        removed+=("$app")
    fi
done
# Links left dangling when the app was removed by hand (e.g. dragged to the Trash).
for bin_dir in /usr/local/bin "$HOME/.local/bin" "${KEYSHIFT_CLI_BIN_DIR:-/usr/local/bin}"; do
    link="$bin_dir/keyshift"
    if [ -L "$link" ] && [ ! -e "$link" ]; then
        case "$(readlink "$link")" in
            */Keyshift.app/Contents/MacOS/Keyshift) rm "$link"; removed+=("$link (dangling)") ;;
        esac
    fi
done
if [ "$purge" = true ]; then
    rm -rf "$HOME/.config/keyshift"
    removed+=("$HOME/.config/keyshift")
fi
reset_done=false
if [ "$reset_permissions" = true ]; then
    if tccutil reset All io.github.ozanhakantunca.keyshift >/dev/null 2>&1; then
        reset_done=true
    else
        printf 'Warning: tccutil could not reset the permissions.\n' >&2
    fi
fi

printf '\nRemoved:\n'
if [ "${#removed[@]}" -eq 0 ]; then printf '  (nothing found)\n'; else printf '  %s\n' "${removed[@]}"; fi
printf 'Left in place:\n'
[ "$purge" = true ] || printf '  Settings: ~/.config/keyshift (use --purge-config to remove)\n'
[ "$reset_done" = true ] ||
    printf '  Accessibility / Input Monitoring grants (use --reset-permissions, or remove Keyshift in System Settings > Privacy & Security)\n'
printf '  Launch at login entry, if enabled: remove it in System Settings > General > Login Items & Extensions\n'
printf '  "Keyshift Self-Signed" signing identity (remove in Keychain Access if no longer needed)\n'
