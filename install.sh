#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
USER_SYSTEMD_DIR="$HOME/.config/systemd/user"
SERVICE_NAME="ping-monitor-daemon.service"
PLASMOID_PLUGIN_ID="org.kde.plasma.pingmonitor"
TARGET_LIB_DIR="/usr/local/lib/ping-monitor"
TARGET_PLASMOID_SOURCE="/usr/local/bin/ping-monitor-plasmoid-source"

if [[ $EUID -ne 0 ]]; then
    exec pkexec bash "$SELF" "$@"
fi

run_as_user() {
    if [[ -n "${PKEXEC_UID:-}" ]]; then
        sudo -u "#${PKEXEC_UID}" XDG_RUNTIME_DIR="/run/user/${PKEXEC_UID}" HOME="$HOME" "$@"
    else
        "$@"
    fi
}

upgrade_or_install_plasmoid() {
    local plasmoid_dir="$1"
    local plugin_id="$2"
    local canonical_dir
    local user_plasmoid_dir="$HOME/.local/share/plasma/plasmoids/$plugin_id"
    canonical_dir="$(realpath "$plasmoid_dir")"

    # If a dev symlink (e.g. ~/.local/share/plasma/plasmoids/<id> -> source repo)
    # exists, remove the symlink itself before invoking kpackagetool6. Otherwise
    # `kpackagetool6 --upgrade` follows the symlink and rm -rf's the source repo.
    if [[ -L "$user_plasmoid_dir" ]]; then
        echo "Removing dev symlink $user_plasmoid_dir -> $(readlink "$user_plasmoid_dir")"
        run_as_user rm -f -- "$user_plasmoid_dir"
    fi

    if [[ -d "$user_plasmoid_dir" ]]; then
        run_as_user kpackagetool6 -t Plasma/Applet --upgrade "$canonical_dir"
    else
        run_as_user kpackagetool6 -t Plasma/Applet --install "$canonical_dir"
    fi
}

if [[ -n "${PKEXEC_UID:-}" ]]; then
    HOME="$(getent passwd "$PKEXEC_UID" | cut -d: -f6)"
    export HOME
    export XDG_DATA_HOME="${HOME}/.local/share"
    USER_SYSTEMD_DIR="$HOME/.config/systemd/user"
fi

install -d -m755 "$TARGET_LIB_DIR"
install -Dm755 "$SCRIPT_DIR/ping-monitor-plasmoid-source.py" "$TARGET_LIB_DIR/ping-monitor-plasmoid-source.py"
install -Dm755 /dev/stdin "$TARGET_PLASMOID_SOURCE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec python3 "/usr/local/lib/ping-monitor/ping-monitor-plasmoid-source.py" "$@"
EOF

mkdir -p "$USER_SYSTEMD_DIR"
sed "s|@@REPO_DIR@@|${SCRIPT_DIR}|g" \
    "$SCRIPT_DIR/ping-monitor-daemon.service" \
    > "$USER_SYSTEMD_DIR/$SERVICE_NAME"

run_as_user systemctl --user daemon-reload
run_as_user systemctl --user enable "$SERVICE_NAME"
run_as_user systemctl --user restart "$SERVICE_NAME"

upgrade_or_install_plasmoid "$SCRIPT_DIR" "$PLASMOID_PLUGIN_ID"

echo "Installed ping-monitor daemon, plasmoid source helper, and refreshed applet registration."
