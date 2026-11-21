#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
usage() {
    cat <<'HELP'
Usage: scripts/uninstall.sh [--prefix <dir>] [--purge-config]

Quit Keyshift and remove Keyshift.app plus CLI symlinks pointing to that app.
Default locations: /Applications and ~/Applications. --prefix selects one.
KEYSHIFT_CLI_BIN_DIR selects an additional CLI directory to check.
--purge-config also removes ~/.config/keyshift. Otherwise settings are preserved.
The login keychain is never modified. You may manually remove the
"Keyshift Self-Signed" signing identity in Keychain Access if no longer needed.
--help shows this help.
HELP
}
prefix=
purge=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            [ "$#" -ge 2 ] && [ -n "$2" ] || keyshift_die '--prefix requires a directory.'
            prefix=$2; shift 2 ;;
        --purge-config) purge=true; shift ;;
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
for directory in "${prefixes[@]}"; do
    app="$directory/Keyshift.app"
    for bin_dir in /usr/local/bin "$HOME/.local/bin" "${KEYSHIFT_CLI_BIN_DIR:-/usr/local/bin}"; do
        link="$bin_dir/keyshift"
        if [ -L "$link" ] && [ "$(readlink "$link")" = "$app/Contents/MacOS/Keyshift" ]; then
            rm "$link"
            printf 'Removed %s\n' "$link"
        fi
    done
    if [ -d "$app" ]; then
        rm -rf "$app"
        printf 'Removed %s\n' "$app"
    fi
done
if [ "$purge" = true ]; then
    rm -rf "$HOME/.config/keyshift"
    printf 'Removed Keyshift configuration.\n'
fi
printf 'Signing identity preserved; remove manually in Keychain Access if desired.\n'
