# Ping Monitor

KDE Plasma 6 system-tray widget that quietly watches latency to:
- Cloudflare (`1.1.1.1`)
- Google DNS (`8.8.8.8`)
- Your default gateway (auto-detected via `ip -4 route`)

A colored satellite icon in the panel summarizes connectivity state at a
glance; click it for a popup with the rolling-window latency chart.

## Features

- **At-a-glance status** via a four-tier colored icon driven by
  Kirigami theme colors:
  - `good` (positive / green) — both public targets up, fastest
    internet RTT ≤ 150 ms.
  - `warn` (neutral / amber) — one of the public targets timing out,
    or fastest RTT > 150 ms.
  - `alert` (negative / red) — both public targets unreachable. Plasma
    is asked to surface the icon via `NeedsAttentionStatus`.
  - `disabled` (theme text @ 45 % opacity) — no recent samples yet.
- **Expansion-driven cadence.** Three `ping -c 1 -W 1` forks per cycle,
  at 1 s while the popup is open and 5 s while collapsed. The 5 s
  background poll keeps the icon honest and slowly fills the in-memory
  history ring so reopening the popup shows a populated chart.
- **Rolling latency chart** with selectable windows (1 / 5 / 10 / 30 /
  60 min), max / min markers on the internet series, and per-host live
  value labels.
- **Tooltip with per-host latency** when you hover the tray icon.
- **No daemon, no state file, no Python dependency.** The widget owns
  its own ping forks; closing or removing it stops all sampling. Each
  `ping` self-terminates inside ~1.2 s thanks to `-W 1`.

## Requirements

- KDE Plasma 6 (`X-Plasma-API-Minimum-Version: 6.0`)
- `kpackagetool6`
- `ping` and `ip` (typically provided by `iputils` and `iproute2`)

## Installation

### Method 1: Install local `.plasmoid` package

```bash
kpackagetool6 --type Plasma/Applet --install /path/to/org.kde.plasma.pingmonitor-1.0.2.plasmoid
```

Use `--upgrade` instead of `--install` to update an existing install.

### Method 2: Install from source checkout

```bash
git clone https://github.com/pizzimenti/ping-monitor.git
cd ping-monitor
bash install.sh
```

`install.sh` idempotently tears down any leftover `ping-monitor-daemon`
systemd unit and `/usr/local/lib/ping-monitor` helper files from prior
daemon-based installs (only requesting a `pkexec` elevation when those
legacy files are actually present).

Then reload Plasma Shell:

```bash
systemctl --user restart plasma-plasmashell.service
```

## Usage

1. Right-click the panel → Add Widgets.
2. Search for `Ping Monitor`.
3. Drop it onto the panel. The widget declares
   `FormFactors: ["horizontal", "vertical"]`, so it lives in panels —
   not on the desktop.
4. Click the satellite icon to expand the latency chart popup; click
   again (or click away) to collapse. Hover for a per-host latency
   tooltip.

## Development

Quick preview:

```bash
plasmoidviewer --applet org.kde.plasma.pingmonitor
```

Lint QML:

```bash
qmllint contents/ui/main.qml
```

After major QML or metadata changes:

```bash
systemctl --user restart plasma-plasmashell.service
```

If plasmashell aggressively caches plugin metadata, a harder restart
clears it:

```bash
kbuildsycoca6 --noincremental
kquitapp6 plasmashell && kstart plasmashell
```

## Packaging

Create a distributable package:

```bash
bsdtar -a -cf org.kde.plasma.pingmonitor-<version>.plasmoid metadata.json contents README.md LICENSE
```

## Uninstall

```bash
kpackagetool6 --type Plasma/Applet --remove org.kde.plasma.pingmonitor
```

## Troubleshooting

- Widget not visible in Add Widgets after install:
  - `kbuildsycoca6 --noincremental`
  - `kquitapp6 plasmashell && kstart plasmashell`
- Icon stays grey forever (`disabled` tier):
  - Run `ping -c 1 -W 1 1.1.1.1` manually; if that fails the widget
    can't be expected to succeed either.
  - `journalctl --user -t plasmashell | grep ping-monitor`.
- Validate package metadata:
  - `kpackagetool6 --type Plasma/Applet --show org.kde.plasma.pingmonitor`
- Validate UI syntax:
  - `qmllint contents/ui/main.qml`

## License

MIT (see `LICENSE`)
