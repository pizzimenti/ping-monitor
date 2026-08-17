# Changelog

All notable changes to Ping Monitor are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.0] — 2026-08-17

### Added

- **Tailscale exit-node toggle** in the popup's legend row. Routes all
  egress through a peer on your tailnet and back, without dropping to a
  terminal. Built for hostile guest wifi — captive-portal networks that
  NAT through a datacenter ASN get treated as bot-like by upstream
  services (captchas, forced re-auth, short-lived sessions), and routing
  through a peer on a residential line clears it.

  The toggle sits beside the latency it visibly changes: engaging the
  exit node moves the 1.1.1.1 and 8.8.8.8 traces to the peer's RTT, so
  the chart itself confirms the switch took effect.

  - State is read from `tailscale status --json`, not tracked from the
    last click, so changes made from the CLI or another device show up.
  - Eligibility comes off the peer entry (`ExitNodeOption` / `Online` /
    `ExitNode`), which distinguishes "not approved by the tailnet" from
    "approved but not selected" — the top-level `ExitNodeStatus` cannot.
  - The button greys out with a hover-tooltip reason when the toggle
    can't be honoured: tailscaled down, peer absent, unapproved, or
    unreachable. It stays clickable whenever the exit node is currently
    engaged even if the peer has since gone offline, because that is
    exactly the state where egress is blackholed and the escape hatch
    matters most.
  - A failed or unparseable poll presents as unknown rather than "off",
    so a transient failure can't offer a button that toggles the wrong
    way.
  - Tray tooltip gains an `Exit node: <host>` line while engaged.

  The exit-node host is currently a hardcoded property (`mistral`); there
  is no configuration UI yet. Requires `OperatorUser` to be set to the
  desktop user, otherwise `tailscale set` needs a root the widget does
  not have — in that case the command is rejected and the button reverts
  rather than appearing to work.

### Notes

- Polling adds one short-lived `tailscale status --json` fork every 30 s,
  riding the existing gateway-refresh timer rather than adding one.
- IPv6 egress through an exit node is not supported on a tailnet whose
  peer doesn't forward it. Tailscale has no IPv4-only exit node —
  `--advertise-exit-node` requires advertising both default routes — so
  `::/0` is advertised but inert.

## [2.0.0] — 2026-05-15

### Breaking changes

- **Widget moved from desktop to system tray.** Ping Monitor is now a
  panel-only widget (`FormFactors: ["horizontal", "vertical"]`). Add it
  via right-click panel → Add Widgets; it no longer appears in the
  desktop's Add Widgets dialog and refuses desktop placement. Anyone
  upgrading from 1.0.x will need to re-add the widget to a panel.
- **Companion daemon removed.** The `ping-monitor-daemon` systemd
  `--user` service is gone, along with its state file and the Python
  runtime dependency. `install.sh` tears the legacy unit and
  `/usr/local/` helper files down idempotently (only requesting a
  `pkexec` elevation when they're actually present).

### Added

- **Colored satellite tray icon** (`kstars_satellites`) with a
  four-tier state machine driven by Kirigami theme colors:
  - `good` (positive / green): both 1.1.1.1 and 8.8.8.8 up, fastest
    public RTT ≤ 150 ms.
  - `warn` (neutral / amber): one of the public targets timing out,
    or fastest RTT > 150 ms.
  - `alert` (negative / red): both public targets unreachable.
    `Plasmoid.status` flips to `NeedsAttentionStatus` during outages
    so the tray refuses to auto-hide the icon.
  - `disabled` (theme text @ 45 %): no recent samples yet.
- **Click-to-expand popup chart** wrapping the existing rolling-window
  latency chart in `PlasmaExtras.Representation`. Window selector
  (1 / 5 / 10 / 30 / 60 min), max / min markers, per-host live value
  labels — all carried over from 1.0.x.
- **Per-host latency tooltip** on tray-icon hover.
- **Expansion-driven cadence.** Three `ping -c 1 -W 1` forks per
  cycle; 1 s while the popup is open, 5 s while collapsed. History
  pushes happen at either rate so reopening the popup shows a
  populated chart instead of a blank canvas.
- `Component.onCompleted` and `onExpandedChanged` kick an immediate
  ping cycle so the icon converges within ~1 s of being added and the
  popup chart starts updating without waiting for the next timer
  tick.
- `Layout.fillHeight` / `Layout.fillWidth` panel-orientation-aware
  sizing so the icon scales to panel height in horizontal panels and
  to panel width in vertical panels.
- `CHANGELOG.md` (this file).

### Changed

- **README rewritten** for the panel-widget architecture: drops the
  daemon / Python references, documents the icon tiers, cadence
  model, and the panel-only installation flow.
- `chartUpdateTimer` rebuild work now gates on `Plasmoid.expanded`;
  history fills regardless of expansion state, so collapsed-widget
  CPU is just the three ping forks every 5 s (~0.6 forks/sec across
  all hosts, each self-terminating inside 1.2 s via `-W 1`).
- `maxPing` axis easing is now directional — snap up immediately on
  expansion (so RTT spikes aren't visually clipped at the previous
  tick's ceiling), ease down at 5 %/tick on contraction (so the
  axis doesn't jitter after every transient peak ages out of the
  visible window).
- Tray icon size driven by `Layout.fillHeight` instead of a hard
  `iconSizes.smallMedium` hint, so it matches the panel's height
  rather than always being pinned at 22 px.

### Removed

- `ping-monitor-daemon.py` and its `ping-monitor-daemon.service`
  systemd unit.
- `ping-monitor-plasmoid-source.py` helper.
- Python 3 from the runtime requirements list.
- Desktop-form `fullRepresentation`-as-default behavior.

### Fixed

- `Plasmoid.expanded` binding bug that left `currentPingInterval`
  evaluating to `undefined` and the ping timer in a degenerate state;
  use the PlasmoidItem property `root.expanded` instead.

## [1.0.2] — 2026-04-08

### Changed

- Daemon removed in favor of QML-spawned ping forks. The
  `ping-monitor-daemon` service was decoupled from the widget's
  lifetime and kept pinging after the widget was closed; the QML
  now owns its own short-lived `ping -c 1 -W 1` forks instead.

## [1.0.1] — earlier 2026

- Initial public release.

[2.0.0]: https://github.com/pizzimenti/ping-monitor/releases/tag/v2.0.0
[1.0.2]: https://github.com/pizzimenti/ping-monitor/releases/tag/v1.0.2
[1.0.1]: https://github.com/pizzimenti/ping-monitor/releases/tag/v1.0.1
