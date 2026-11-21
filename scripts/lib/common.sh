#!/bin/bash
# Shared helpers; callers use macOS /bin/bash 3.2 and set -euo pipefail.

keyshift_die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

keyshift_require_macos() {
    [ "$(uname -s)" = Darwin ] || keyshift_die 'This script requires macOS.'
}

keyshift_require() {
    command -v "$1" >/dev/null 2>&1 || keyshift_die "Required tool not found: $1"
}

keyshift_version() {
    local version
    version=$(tr -d '\r\n' < "$1/VERSION")
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        keyshift_die 'VERSION must contain a numeric major.minor.patch version.'
    printf '%s\n' "$version"
}

keyshift_cli_bin_dir() {
    if [ -n "${KEYSHIFT_CLI_BIN_DIR:-}" ]; then
        printf '%s\n' "$KEYSHIFT_CLI_BIN_DIR"
    elif [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
        printf '%s\n' /usr/local/bin
    else
        printf '%s\n' "$HOME/.local/bin"
    fi
}

keyshift_quit() {
    local running attempt
    running=$(osascript -l JavaScript -e \
        'ObjC.import("AppKit"); $.NSRunningApplication.runningApplicationsWithBundleIdentifier("io.github.ozanhakantunca.keyshift").count > 0')
    if [ "$running" = true ]; then
        osascript -e 'tell application id "io.github.ozanhakantunca.keyshift" to quit' ||
            keyshift_die 'Keyshift could not quit. Quit it manually and rerun.'
        for ((attempt = 0; attempt < 50; attempt++)); do
            running=$(osascript -l JavaScript -e \
                'ObjC.import("AppKit"); $.NSRunningApplication.runningApplicationsWithBundleIdentifier("io.github.ozanhakantunca.keyshift").count > 0')
            [ "$running" = false ] && break
            sleep 0.2
        done
        [ "$running" = false ] || keyshift_die 'Keyshift is still running. Quit it manually and rerun.'
    fi
}
