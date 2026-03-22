#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_SYSTEMD_DIR="$HOME/.config/systemd/user"
SERVICE_NAME="ping-monitor-daemon.service"
PLASMOID_PLUGIN_ID="org.kde.plasma.pingmonitor"

upgrade_or_install_plasmoid() {
    local plasmoid_dir="$1"
    local plugin_id="$2"
    local canonical_dir
    canonical_dir="$(realpath "$plasmoid_dir")"
    if kpackagetool6 -t Plasma/Applet --show "$plugin_id" >/dev/null 2>&1; then
        kpackagetool6 -t Plasma/Applet --upgrade "$canonical_dir"
    else
        kpackagetool6 -t Plasma/Applet --install "$canonical_dir"
    fi
}

mkdir -p "$USER_SYSTEMD_DIR"
sed "s|@@REPO_DIR@@|${SCRIPT_DIR}|g" \
    "$SCRIPT_DIR/ping-monitor-daemon.service" \
    > "$USER_SYSTEMD_DIR/$SERVICE_NAME"

systemctl --user daemon-reload
systemctl --user enable "$SERVICE_NAME"
systemctl --user restart "$SERVICE_NAME"

upgrade_or_install_plasmoid "$SCRIPT_DIR" "$PLASMOID_PLUGIN_ID"

echo "Installed ping-monitor daemon and upgraded applet."
