# Changelog

All notable changes to Ping Monitor are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.3.0] — 2026-08-19

### Added

- **Orbit-ring tray indicator.** While the tailnet routes through an exit
  node, the satellite tray icon gains a faint blue orbit ring with a
  small moon at its upper right — tunnel state reads from the panel
  without opening the popup. Keyed to *any* selected exit node (the
  honest "is my traffic tunneled" signal), not just the widget's
  configured host. Gateway blue rather than amber because the warn tier
  already colours the satellite amber, and an amber orbit around an
  amber glyph vanishes at 22 px. The glyph yields 20% while decorated
  and returns to full size when direct.

### Fixed

- **Startup race that classified tunnel data as direct egress.** On
  widget load, the egress lookup and the first exit-node status poll
  were dispatched in the same tick; if the lookup returned first, it was
  classified against pre-poll defaults and committed the exit node's
  address with direct (grey) styling — visible later as colour updating
  out of step with text. The lookup now defers until the first
  successful status poll. Transient poll failures after that first poll
  still classify from last-known state (the round-4 invariant from
  PR #3), now stated in comments alongside the new gate.
- **Transition presentation.** The 45%-opacity dim on a stale egress
  label produced two unintended intermediate colours and read as a
  font-size change. While a re-lookup is pending the label now shows a
  neutral muted "…" — there is no consistent IP state to report during a
  transition, so it reports none. Text and colour only ever land
  together, from a completed lookup.

## [2.2.0] — 2026-08-17

### Added

- **Egress identity in the legend row.** Shows the abbreviated ISP and
  public IP of wherever your traffic is actually leaving from, e.g.
  `SpaceX · 98.97.42.196`. Coloured by routing — amber while leaving via
  the exit node, muted while going out locally — so the distinction reads
  without parsing the text.

  ipinfo returns `org` as `AS<number> <Legal Entity Name>`, which is too
  long for the popup and mostly noise. Stripping the ASN and a trailing
  corporate suffix, then taking the first word, handles most providers:
  `AS7922 Comcast Cable Communications, LLC` → Comcast,
  `AS21928 T-Mobile USA, Inc.` → T-Mobile, `AS7018 AT&T Services, Inc.`
  → AT&T.

  That rule cannot recover a trade name sharing no prefix with the legal
  name, so those get an explicit alias. Starlink is the motivating case:
  its operator registers as `Space Exploration Technologies Corporation`,
  which the heuristic alone renders as "Space" — a real word that looks
  like a plausible brand, so it would read as correct while being wrong.

### Changed

- **All popup text is larger.** Every font size now derives from a single
  `fontScale` (1.25) via `baseFontSize`, rather than eight independently
  hardcoded multipliers. Previous sizes were hard to read at a glance,
  and the scale is now adjustable from one number.

### Notes

- The egress lookup queries `ipinfo.io`, so your address is visible to a
  third party. Unavoidable for a public-IP display — only an outside
  observer can answer the question.
- It is deliberately not on a timer. The answer only changes when the
  exit node flips or the underlying network does, so refresh is driven by
  those two events (debounced 2.5 s, since routing needs a moment to
  settle or it would re-read the address just left) plus popup expand
  when nothing is cached yet. Repeated opens do not re-query.

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
