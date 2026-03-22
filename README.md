# Ping Monitor

KDE Plasma 6 widget that monitors latency to:
- Cloudflare (`1.1.1.1`)
- Google DNS (`8.8.8.8`)
- Your default gateway (optional, auto-detected)

It renders a rolling 90-second latency chart with live value labels.

## Features

- Rolling 90s RTT chart for internet and gateway targets
- Public ping cadence: 1 second per host, staggered by 500 ms
- Gateway ping cadence: 500 ms
- Automatic stale-stream recovery for public ping processes
- Max/min markers for internet series (gateway excluded)

## Requirements

- KDE Plasma 6
- `kpackagetool6`
- `ping` and `ip` (typically provided by `iputils` and `iproute2`)

## Installation

### Method 1: KDE Store (recommended)

1. Right-click Desktop or Panel -> Add Widgets.
2. Click `Get New Widgets...`.
3. Search for `Ping Monitor` and install.

### Method 2: Install local `.plasmoid` package

```bash
kpackagetool6 --type Plasma/Applet --install /path/to/org.kde.plasma.pingmonitor-1.0.2.plasmoid
```

Use `--upgrade` instead of `--install` to update an existing install.

### Method 3: Install from source checkout

```bash
git clone https://github.com/pizzimenti/plasma-ping-monitor.git
cd plasma-ping-monitor
kpackagetool6 --type Plasma/Applet --upgrade . || kpackagetool6 --type Plasma/Applet --install .
```

Then reload Plasma Shell:

```bash
systemctl --user restart plasma-plasmashell.service
```

## Usage

1. Right-click Desktop or Panel -> Add Widgets.
2. Search for `Ping Monitor`.
3. Add it to your desktop or panel.

## Development

Quick preview:

```bash
plasmawindowed .
# or
plasmoidviewer .
```

Lint QML:

```bash
qmllint contents/ui/main.qml
```

After major QML or metadata changes:

```bash
systemctl --user restart plasma-plasmashell.service
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

- Widget not visible after install:
  - `kbuildsycoca6`
  - `systemctl --user restart plasma-plasmashell.service`
- Validate package metadata:
  - `kpackagetool6 --type Plasma/Applet --show org.kde.plasma.pingmonitor`
- Validate UI syntax:
  - `qmllint contents/ui/main.qml`

## License

MIT (see `LICENSE`)
