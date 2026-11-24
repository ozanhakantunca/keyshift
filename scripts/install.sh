#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'HELP'
Usage: scripts/install.sh [--prefix <dir>] [--no-launch] [--with-cli]

Build release for the current architecture, gracefully quit a running Keyshift,
and install Keyshift.app to /Applications (fallback: ~/Applications if unwritable).
  --prefix <dir>  Install into this directory; no fallback for an explicit path.
  --no-launch     Install without launching (useful for tests).
  --with-cli      Link keyshift into /usr/local/bin or ~/.local/bin.
  --help          Show this help.
  KEYSHIFT_CLI_BIN_DIR overrides the CLI directory (including for prefix tests).

Requires Command Line Tools with Swift 6+: xcode-select --install
Respects build-app.sh's KEYSHIFT_SCRATCH_PATH, KEYSHIFT_SIGN_IDENTITY, and
KEYSHIFT_SIGN_KEYCHAIN. Install a stable certificate with create-signing-cert.sh
first to keep the same signing identity on subsequent local builds.
HELP
}

prefix=
launch=true
with_cli=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            [ "$#" -ge 2 ] && [ -n "$2" ] || keyshift_die '--prefix requires a directory.'
            prefix=$2; shift 2 ;;
        --with-cli) with_cli=true; shift ;;
        --no-launch) launch=false; shift ;;
        -h|--help) usage; exit 0 ;;
        *) keyshift_die "Unknown argument: $1 (see --help)." ;;
    esac
done
keyshift_require_macos
xcode-select -p >/dev/null 2>&1 || keyshift_die 'Command Line Tools are missing. Run: xcode-select --install'
keyshift_require swift
if [ -z "$prefix" ]; then
    prefix=/Applications
    if [ ! -d "$prefix" ] || [ ! -w "$prefix" ] ||
        { [ -e "$prefix/Keyshift.app" ] && [ ! -w "$prefix/Keyshift.app" ]; }; then
        prefix="$HOME/Applications"
        printf 'Using writable fallback: %s\n' "$prefix"
    fi
fi
mkdir -p "$prefix" || keyshift_die "Cannot create installation directory: $prefix"
prefix=$(cd "$prefix" && pwd)
[ -w "$prefix" ] || keyshift_die "Installation directory is not writable: $prefix"
"$SCRIPT_DIR/build-app.sh" --arch native

keyshift_quit

stage=$(mktemp -d "$prefix/.keyshift-install.XXXXXX")
trap 'rm -rf "$stage"' EXIT
# Do not copy inherited download quarantine into a locally built installation.
ditto --noqtn "$REPO_ROOT/dist/Keyshift.app" "$stage/Keyshift.app"
codesign --verify --deep --strict "$stage/Keyshift.app"
destination="$prefix/Keyshift.app"
if [ -e "$destination" ] || [ -L "$destination" ]; then
    mv "$destination" "$stage/previous.app" || keyshift_die "Cannot replace $destination"
fi
if ! mv "$stage/Keyshift.app" "$destination"; then
    if [ -e "$stage/previous.app" ] || [ -L "$stage/previous.app" ]; then
        mv "$stage/previous.app" "$destination"
    fi
    keyshift_die "Cannot install $destination"
fi
printf 'Installed %s\n' "$destination"
cli_failed=false
if [ "$with_cli" = true ]; then
    # A CLI problem must not stop the app from launching; report it at the end instead.
    if (
        cli_dir=$(keyshift_cli_bin_dir)
        mkdir -p "$cli_dir" || keyshift_die "Cannot create $cli_dir"
        cli_dir=$(cd "$cli_dir" && pwd) || keyshift_die "Cannot enter $cli_dir"
        cli_link="$cli_dir/keyshift"
        target="$destination/Contents/MacOS/Keyshift"
        if [ -e "$cli_link" ] || [ -L "$cli_link" ]; then
            # Replace only a symlink that points at some Keyshift install (e.g. another prefix).
            if [ -L "$cli_link" ]; then
                case "$(readlink "$cli_link")" in
                    */Keyshift.app/Contents/MacOS/Keyshift) ;;
                    *) keyshift_die "Refusing to replace unrelated CLI path: $cli_link" ;;
                esac
            else
                keyshift_die "Refusing to replace unrelated CLI path: $cli_link"
            fi
            ln -sfn "$target" "$cli_link" || keyshift_die "Cannot replace $cli_link"
        else
            ln -s "$target" "$cli_link" || keyshift_die "Cannot create $cli_link"
        fi
        printf 'CLI installed: %s\n' "$cli_link"
        case ":$PATH:" in
            *":$cli_dir:"*) ;;
            *) printf 'Add %s to PATH, for example: export PATH="%s:$PATH"\n' "$cli_dir" "$cli_dir" ;;
        esac
    ); then :; else cli_failed=true; fi
fi
if [ "$launch" = true ]; then
    open "$destination" || keyshift_die "Installed, but could not launch $destination"
else
    printf 'Launch skipped (--no-launch).\n'
fi
if [ "$cli_failed" = true ]; then
    keyshift_die 'Keyshift was installed, but the CLI link could not be created (see above).'
fi
