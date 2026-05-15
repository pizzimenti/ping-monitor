#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_SYSTEMD_DIR="$HOME/.config/systemd/user"
SERVICE_NAME="ping-monitor-daemon.service"
PLASMOID_PLUGIN_ID="org.kde.plasma.pingmonitor"
LEGACY_LIB_DIR="/usr/local/lib/ping-monitor"
LEGACY_HELPER_BIN="/usr/local/bin/ping-monitor-plasmoid-source"

needs_root_cleanup() {
    [[ -e "$LEGACY_HELPER_BIN" || -d "$LEGACY_LIB_DIR" ]]
}

# The plasmoid no longer uses a daemon — it spawns its own short-lived `ping`
# forks from QML. Old installs left behind a systemd --user unit and a couple
# of files under /usr/local. Tear them down idempotently before upgrading.
teardown_legacy_user_daemon() {
    if systemctl --user list-unit-files "$SERVICE_NAME" >/dev/null 2>&1; then
        systemctl --user disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    else
        # Even if list-unit-files doesn't show it, try stop in case it's
        # transient/loaded but not enabled.
        systemctl --user stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    if [[ -f "$USER_SYSTEMD_DIR/$SERVICE_NAME" ]]; then
        rm -f -- "$USER_SYSTEMD_DIR/$SERVICE_NAME"
        systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
}

teardown_legacy_root_files() {
    [[ -e "$LEGACY_HELPER_BIN" ]] && rm -f -- "$LEGACY_HELPER_BIN"
    [[ -d "$LEGACY_LIB_DIR" ]] && rm -rf -- "$LEGACY_LIB_DIR"
    return 0
}

upgrade_or_install_plasmoid() {
    local plasmoid_dir="$1"
    local plugin_id="$2"
    local canonical_dir
    local user_plasmoid_dir="$HOME/.local/share/plasma/plasmoids/$plugin_id"
    canonical_dir="$(realpath "$plasmoid_dir")"

    # If a dev symlink at ~/.local/share/plasma/plasmoids/<id> points back at
    # *this* checkout, remove the symlink itself before invoking kpackagetool6.
    # Otherwise `kpackagetool6 --upgrade` follows the symlink and rm -rf's the
    # source repo. We only touch links pointing at this checkout — an unrelated
    # symlinked install (e.g. another working tree) is left alone and we bail
    # out so the user can resolve it manually.
    if [[ -L "$user_plasmoid_dir" ]]; then
        local installed_target
        installed_target="$(realpath "$user_plasmoid_dir")"
        if [[ "$installed_target" == "$canonical_dir" ]]; then
            echo "Removing dev symlink $user_plasmoid_dir -> $(readlink "$user_plasmoid_dir")"
            rm -f -- "$user_plasmoid_dir"
        else
            echo "Refusing to remove unrelated symlink $user_plasmoid_dir -> $(readlink "$user_plasmoid_dir")" >&2
            echo "Resolved target ($installed_target) does not match this checkout ($canonical_dir)." >&2
            return 1
        fi
    fi

    if [[ -d "$user_plasmoid_dir" ]]; then
        kpackagetool6 -t Plasma/Applet --upgrade "$canonical_dir"
    else
        kpackagetool6 -t Plasma/Applet --install "$canonical_dir"
    fi
}

# Phase 1: user-level teardown of the old daemon. Always safe to run as the
# invoking user — no privileges required.
teardown_legacy_user_daemon

# Phase 2: root-owned legacy files under /usr/local. Only re-exec under pkexec
# when something is actually there to remove, so a clean install never asks
# for a polkit prompt.
if needs_root_cleanup; then
    if [[ $EUID -ne 0 ]]; then
        echo "Removing legacy /usr/local helper files (requires elevation)..."
        pkexec rm -rf -- "$LEGACY_HELPER_BIN" "$LEGACY_LIB_DIR"
    else
        teardown_legacy_root_files
    fi
fi

# Phase 3: install/upgrade the plasmoid as the invoking user. If we somehow
# got here as root (e.g. a manual `sudo bash install.sh`), bail — kpackagetool6
# would write into root's home, not the user's.
if [[ $EUID -eq 0 ]]; then
    echo "Refusing to run kpackagetool6 as root; re-run install.sh as your user." >&2
    exit 1
fi

upgrade_or_install_plasmoid "$SCRIPT_DIR" "$PLASMOID_PLUGIN_ID"

echo "Installed ping-monitor plasmoid (no daemon; the widget owns its ping forks)."
