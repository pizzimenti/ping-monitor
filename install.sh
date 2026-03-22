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
    local show_output
    local installed_path
    local canonical_installed
    canonical_dir="$(realpath "$plasmoid_dir")"
    show_output="$(run_as_user kpackagetool6 -t Plasma/Applet --show "$plugin_id" 2>/dev/null || true)"
    installed_path="$(printf '%s\n' "$show_output" | sed -n 's/^[[:space:]]*Path[[:space:]]*:[[:space:]]*//p' | head -n1)"
    if [[ -n "$installed_path" && -e "$installed_path" ]]; then
        canonical_installed="$(realpath "$installed_path")"
        if [[ "$canonical_installed" == "$canonical_dir" ]]; then
            echo "Plasma widget already installed from source path: $canonical_dir"
            return 0
        fi
    fi
    if [[ -n "$installed_path" ]]; then
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
