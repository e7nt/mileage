#!/bin/sh
# Installs, upgrades or uninstalls mileage, the macOS menu bar quota tracker.
#
#   curl -fsSL https://mileage.e7nt.com/install.sh | sh                  # install or upgrade
#   curl -fsSL https://mileage.e7nt.com/install.sh | sh -s -- uninstall
#
# Once installed, `mileage --upgrade` and `mileage --uninstall` run this same script.
#
# The MILEAGE_* variables exist so the script can be tested against a local server and
# a scratch directory without touching /Applications.

set -eu

SITE_URL="${MILEAGE_SITE_URL:-https://mileage.e7nt.com}"
DOWNLOAD_URL="${MILEAGE_DOWNLOAD_URL:-https://github.com/e7nt/mileage/releases/download}"
BUNDLE_ID="com.e7nt.mileage"

say() { printf 'mileage: %s\n' "$*"; }

# GitHub's download host sometimes holds a connection open without sending anything, and
# curl would wait on it forever. Give up on a connection that stalls for 15s, and retry.
fetch() { curl -fL --connect-timeout 10 --speed-limit 1 --speed-time 15 --retry 3 --retry-all-errors "$@"; }
fail() { printf 'mileage: %s\n' "$*" >&2; exit 1; }

installed_app() {
    for dir in ${MILEAGE_APP_DIR:-/Applications "$HOME/Applications"}; do
        if [ -d "$dir/Mileage.app" ]; then
            echo "$dir/Mileage.app"
            return
        fi
    done
}

# /Applications is writable for admin users; everyone else gets ~/Applications.
target_app_dir() {
    if [ -n "${MILEAGE_APP_DIR:-}" ]; then
        echo "$MILEAGE_APP_DIR"
    elif [ -w /Applications ]; then
        echo /Applications
    else
        echo "$HOME/Applications"
    fi
}

target_bin_dir() {
    if [ -n "${MILEAGE_BIN_DIR:-}" ]; then
        echo "$MILEAGE_BIN_DIR"
    elif [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
        echo /usr/local/bin
    else
        echo "$HOME/.local/bin"
    fi
}

# The menu bar app's PID, from LaunchServices. Only the GUI app is registered there, so this
# never matches the `mileage --upgrade` process running this script, which `pkill -x Mileage`
# would kill too, since both are the same binary.
app_pid() {
    lsappinfo info -only pid -app "$BUNDLE_ID" | sed -n 's/.*"pid"=\([0-9]*\).*/\1/p'
}

wait_for_exit() {
    attempts=0
    while kill -0 "$1" 2>/dev/null; do
        attempts=$((attempts + 1))
        [ "$attempts" -le 8 ] || return 1
        sleep 0.25
    done
}

# Asks the app to quit, then ends it if it doesn't. It can't answer a quit request while a
# Keychain prompt is open, and an ad-hoc signed upgrade raises one on every new version.
quit_app() {
    pid="$(app_pid)"
    [ -n "$pid" ] || return 0
    osascript -e "with timeout of 5 seconds" -e "tell application id \"$BUNDLE_ID\" to quit" \
        -e "end timeout" >/dev/null 2>&1 || true
    wait_for_exit "$pid" && return 0
    kill "$pid" 2>/dev/null || true
    wait_for_exit "$pid" && return 0
    kill -9 "$pid" 2>/dev/null || true
    wait_for_exit "$pid" || fail "couldn't quit Mileage (pid $pid). Quit it and try again."
}

link_cli() {
    app="$1"
    bin_dir="$(target_bin_dir)"
    mkdir -p "$bin_dir"
    ln -sf "$app/Contents/MacOS/Mileage" "$bin_dir/mileage"
    case ":$PATH:" in
        *":$bin_dir:"*) ;;
        *) say "add $bin_dir to your PATH to use the mileage command" ;;
    esac
}

install_latest() {
    sw_major="$(sw_vers -productVersion | cut -d. -f1)"
    [ "$sw_major" -ge 14 ] || fail "needs macOS 14 or later"

    latest="$(fetch -sS "$SITE_URL/latest.txt" | tr -d '[:space:]')" \
        || fail "could not reach $SITE_URL"
    [ -n "$latest" ] || fail "no release has been published yet"

    app="$(installed_app)"
    if [ -n "$app" ]; then
        current="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist" 2>/dev/null || echo unknown)"
        if [ "$current" = "$latest" ]; then
            link_cli "$app"
            say "already on the latest version ($latest)"
            return
        fi
        say "upgrading $current → $latest"
    else
        app="$(target_app_dir)/Mileage.app"
        say "installing $latest"
    fi

    work_dir="$(mktemp -d)"
    trap 'rm -rf "$work_dir"' EXIT
    zip="Mileage-$latest.zip"
    fetch -sS -o "$work_dir/$zip.sha256" "$DOWNLOAD_URL/v$latest/$zip.sha256" || fail "checksum download failed"
    fetch --progress-bar -o "$work_dir/$zip" "$DOWNLOAD_URL/v$latest/$zip" || fail "download failed"
    (cd "$work_dir" && shasum -a 256 -c "$zip.sha256" >/dev/null) || fail "checksum mismatch, nothing was changed"
    ditto -x -k "$work_dir/$zip" "$work_dir/unpacked"
    [ -d "$work_dir/unpacked/Mileage.app" ] || fail "download didn't contain Mileage.app"

    quit_app
    mkdir -p "$(dirname "$app")"
    rm -rf "$app"
    mv "$work_dir/unpacked/Mileage.app" "$app"
    link_cli "$app"
    open "$app"
    say "Mileage $latest is running from $app"
}

uninstall() {
    app="$(installed_app)"
    [ -n "$app" ] || fail "Mileage isn't installed"
    quit_app
    rm -rf "$app"
    for bin_dir in "$(target_bin_dir)" /usr/local/bin "$HOME/.local/bin"; do
        link="$bin_dir/mileage"
        if [ -L "$link" ] && [ "$(readlink "$link")" = "$app/Contents/MacOS/Mileage" ]; then
            rm -f "$link"
        fi
    done
    say "removed $app (your accounts stay in the Keychain if you reinstall)"
}

# Everything runs from here, so a download cut off mid-script never executes half of it.
main() {
    case "${1:-install}" in
        install | upgrade) install_latest ;;
        uninstall) uninstall ;;
        *) fail "unknown command '$1' (use install, upgrade or uninstall)" ;;
    esac
}

main "$@"
