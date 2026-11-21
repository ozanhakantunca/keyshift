#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'HELP'
Usage: scripts/build-app.sh [--debug] [--arch native|universal]

Build dist/Keyshift.app from any working directory. Defaults: release, universal.
Universal builds compile arm64 and x86_64 separately and combine them with lipo;
this also works with Command Line Tools alone (Swift 6+ is required).

Environment:
  KEYSHIFT_SCRATCH_PATH    SwiftPM scratch root, default .build (relative to repo).
                        Each architecture uses its own subdirectory.
  KEYSHIFT_SIGN_IDENTITY   Signing name/hash; '-' forces ad-hoc signing.
                        Default: Keyshift Self-Signed if present, otherwise '-'.
  KEYSHIFT_SIGN_KEYCHAIN   Optional keychain containing the signing identity.
                        It must also be on the user's keychain search list
                        (man codesign); this script does not change that list.

Keep the SAME certificate/private key across updates to preserve the designated
requirement. Recreating a certificate with the same name changes that identity.
Ad-hoc signatures do not provide a stable identity across changed binaries.

Hardened runtime is OFF and the app is not notarized. Keyshift needs no sandbox
or exception entitlements; Accessibility and Input Monitoring are granted by the user.
SwiftPM resource bundles (*.bundle, e.g. the config presets) are copied into
Keyshift.app/Contents/Resources.
HELP
}

configuration=release
architecture=universal
while [ "$#" -gt 0 ]; do
    case "$1" in
        --debug) configuration=debug; shift ;;
        --arch)
            [ "$#" -ge 2 ] || keyshift_die '--arch requires native or universal.'
            architecture=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) keyshift_die "Unknown argument: $1 (see --help)." ;;
    esac
done
case "$architecture" in native|universal) ;; *) keyshift_die '--arch must be native or universal.' ;; esac
keyshift_require_macos
for tool in swift xcrun lipo codesign security; do keyshift_require "$tool"; done
xcode-select -p >/dev/null 2>&1 || keyshift_die 'Install Command Line Tools: xcode-select --install'
version=$(keyshift_version "$REPO_ROOT")
scratch=${KEYSHIFT_SCRATCH_PATH:-.build}
case "$scratch" in /*) ;; *) scratch="$REPO_ROOT/$scratch" ;; esac
cd "$REPO_ROOT"

# Individual --arch builds avoid SwiftPM's Xcode-dependent universal build path.
if [ "$architecture" = universal ]; then
    architectures=(arm64 x86_64)
else
    native_arch=$(uname -m)
    case "$native_arch" in arm64|x86_64) ;; *) keyshift_die "Unsupported host architecture: $native_arch" ;; esac
    architectures=("$native_arch")
fi
binaries=()
bin_dirs=()
for arch in "${architectures[@]}"; do
    printf 'Building Keyshift: %s / %s\n' "$configuration" "$arch"
    build_args=(--package-path "$REPO_ROOT" --scratch-path "$scratch/$arch" --build-system native --configuration "$configuration" --arch "$arch")
    swift build "${build_args[@]}" --product Keyshift || keyshift_die "Swift build failed for $arch."
    bin_dir=$(swift build "${build_args[@]}" --show-bin-path)
    [ -x "$bin_dir/Keyshift" ] || keyshift_die "Built executable missing: $bin_dir/Keyshift"
    binaries+=("$bin_dir/Keyshift")
    bin_dirs+=("$bin_dir")
done

mkdir -p "$REPO_ROOT/dist"
stage=$(mktemp -d "$REPO_ROOT/dist/.build-app.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/Keyshift.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
if [ "$architecture" = universal ]; then
    lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/Keyshift"
    arch_list=" $(lipo -archs "$app/Contents/MacOS/Keyshift") "
    [[ "$arch_list" = *' arm64 '* ]] && [[ "$arch_list" = *' x86_64 '* ]] ||
        keyshift_die "Universal binary is missing an architecture: $arch_list"
else
    cp "${binaries[0]}" "$app/Contents/MacOS/Keyshift"
fi
chmod 755 "$app/Contents/MacOS/Keyshift"
lipo -info "$app/Contents/MacOS/Keyshift"
build_number=$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || printf '1')
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || build_number=1
sed -e "s/@VERSION@/$version/g" -e "s/@BUILD_NUMBER@/$build_number/g" \
    "$REPO_ROOT/Resources/Info.plist" > "$app/Contents/Info.plist"
if [ -f "$REPO_ROOT/Resources/AppIcon/Keyshift.icns" ]; then
    cp "$REPO_ROOT/Resources/AppIcon/Keyshift.icns" "$app/Contents/Resources/Keyshift.icns"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string Keyshift' "$app/Contents/Info.plist"
fi
# SwiftPM resource bundles (Bundle.module). The generated accessor also checks
# Bundle.main.resourceURL, which is Contents/Resources inside an app bundle.
for dir in "${bin_dirs[@]}"; do
    for bundle in "$dir"/*.bundle; do
        [ -d "$bundle" ] || continue
        ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"
    done
done
# UI translations: Resources/Localization/<lang>.lproj -> Contents/Resources/<lang>.lproj
for lproj in "$REPO_ROOT"/Resources/Localization/*.lproj; do
    [ -d "$lproj" ] || continue
    ditto "$lproj" "$app/Contents/Resources/$(basename "$lproj")"
done
plutil -lint "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

keychain_args=()
if [ -n "${KEYSHIFT_SIGN_KEYCHAIN:-}" ]; then
    [ -f "$KEYSHIFT_SIGN_KEYCHAIN" ] || keyshift_die "Signing keychain not found: $KEYSHIFT_SIGN_KEYCHAIN"
    keychain_args=("$KEYSHIFT_SIGN_KEYCHAIN")
fi
identity=${KEYSHIFT_SIGN_IDENTITY:-}
if [ -z "$identity" ]; then
    # Use all identities, not only -v: a locally self-signed certificate need not
    # be in the user's trust store. codesign verifies its cryptographic validity.
    if [ "${#keychain_args[@]}" -gt 0 ]; then
        identities=$(security find-identity -p codesigning "${keychain_args[0]}")
    else
        identities=$(security find-identity -p codesigning)
    fi
    identity=$(printf '%s\n' "$identities" | awk '/"Keyshift Self-Signed"/ { print $2; exit }')
    identity=${identity:--}
fi
sign_args=(--force --sign "$identity" --identifier io.github.ozanhakantunca.keyshift --timestamp=none)
if [ "${#keychain_args[@]}" -gt 0 ]; then
    sign_args+=(--keychain "${keychain_args[0]}")
fi
if [ "$identity" = - ]; then
    printf 'Signing mode: ad-hoc (-); hardened runtime: off\n'
else
    printf 'Signing mode: certificate (%s); hardened runtime: off\n' "$identity"
fi
codesign "${sign_args[@]}" "$app" || keyshift_die 'Code signing failed. Check the identity, unlocked keychain, user keychain search list, and codesign key access.'
codesign --verify --deep --strict --verbose=2 "$app"
# Replace only after a successful build and signature verification.
rm -rf "$REPO_ROOT/dist/Keyshift.app"
mv "$app" "$REPO_ROOT/dist/Keyshift.app"
printf 'Built %s\n' "$REPO_ROOT/dist/Keyshift.app"
