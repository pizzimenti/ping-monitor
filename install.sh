#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_SYSTEMD_DIR="$HOME/.config/systemd/user"
SERVICE_NAME="ping-monitor-daemon.service"

mkdir -p "$USER_SYSTEMD_DIR"
sed "s|@@REPO_DIR@@|${SCRIPT_DIR}|g" \
    "$SCRIPT_DIR/ping-monitor-daemon.service" \
    > "$USER_SYSTEMD_DIR/$SERVICE_NAME"

systemctl --user daemon-reload
systemctl --user enable --now "$SERVICE_NAME"

kpackagetool6 -t Plasma/Applet --upgrade "$SCRIPT_DIR" 2>/dev/null \
    || kpackagetool6 -t Plasma/Applet --install "$SCRIPT_DIR"

echo "Installed ping-monitor daemon and upgraded applet."
