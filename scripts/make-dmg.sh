#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'HELP'
Usage: scripts/make-dmg.sh

Package the existing dist/Keyshift.app as dist/Keyshift-<VERSION>.dmg (UDZO),
volume name Keyshift, with an /Applications shortcut. Also writes
dist/Keyshift-<VERSION>.dmg.sha256 (shasum -a 256 -c compatible).
Build first with scripts/build-app.sh. This does not notarize the app or DMG.
HELP
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *) keyshift_die "Unknown argument: $1 (see --help)." ;;
    esac
done
keyshift_require_macos
for tool in hdiutil codesign shasum; do keyshift_require "$tool"; done
version=$(keyshift_version "$REPO_ROOT")
app="$REPO_ROOT/dist/Keyshift.app"
[ -d "$app" ] || keyshift_die 'dist/Keyshift.app is missing. Run scripts/build-app.sh first.'
codesign --verify --deep --strict "$app" || keyshift_die 'The app signature is invalid; rebuild before packaging.'
app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[ "$app_version" = "$version" ] || keyshift_die 'App version differs from VERSION; rebuild before packaging.'
stage=$(mktemp -d "$REPO_ROOT/dist/.make-dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/volume"
ditto --noqtn "$app" "$stage/volume/Keyshift.app"
ln -s /Applications "$stage/volume/Applications"
hdiutil create -volname Keyshift -srcfolder "$stage/volume" -format UDZO \
    -ov "$stage/Keyshift-$version.dmg"
hdiutil verify "$stage/Keyshift-$version.dmg"
mv -f "$stage/Keyshift-$version.dmg" "$REPO_ROOT/dist/Keyshift-$version.dmg"
cd "$REPO_ROOT/dist"
shasum -a 256 "Keyshift-$version.dmg" > "$stage/checksum"
mv -f "$stage/checksum" "Keyshift-$version.dmg.sha256"
printf 'Created %s/dist/Keyshift-%s.dmg and .dmg.sha256\n' "$REPO_ROOT" "$version"
