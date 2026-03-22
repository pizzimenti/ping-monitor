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
    local show_output
    local installed_path
    local canonical_installed
    canonical_dir="$(realpath "$plasmoid_dir")"
    show_output="$(kpackagetool6 -t Plasma/Applet --show "$plugin_id" 2>/dev/null || true)"
    installed_path="$(printf '%s\n' "$show_output" | sed -n 's/^[[:space:]]*Path[[:space:]]*:[[:space:]]*//p' | head -n1)"
    if [[ -n "$installed_path" && -e "$installed_path" ]]; then
        canonical_installed="$(realpath "$installed_path")"
        if [[ "$canonical_installed" == "$canonical_dir" ]]; then
            echo "Plasma widget already installed from source path: $canonical_dir"
            return 0
        fi
    fi
    if [[ -n "$installed_path" ]]; then
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

echo "Installed ping-monitor daemon and refreshed applet registration."
