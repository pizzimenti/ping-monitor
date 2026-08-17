import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtQuick.Shapes
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // Panel widget: tray icon by default, popup chart on click. Mirrors the
    // wifimimo / audiomux / dell-fans pattern in this widget family.
    preferredRepresentation: compactRepresentation

    // Two cadences, switched by root.expanded (the PlasmoidItem property,
    // not the Plasmoid attached object — `expanded` is not on the attached
    // namespace):
    //   - fast (1 Hz) while the popup is open: drives the live chart.
    //   - slow (every 5 s) while collapsed: keeps the tray icon's tier
    //     (good/warn/alert/disabled) honest and slowly fills the in-memory
    //     history ring buffer, so reopening the popup shows a populated
    //     chart instead of a blank canvas. Matches wifimimo's daemon-side
    //     slow cadence even though we have no daemon — the work is just
    //     three ping forks every 5 s.
    readonly property int fastPingMs: 1000
    readonly property int slowPingMs: 5000
    readonly property int currentPingInterval: root.expanded ? fastPingMs : slowPingMs

    // Latest parsed ping values (ms); -1 means timeout/unavailable.
    property real currentCloudflarePing: -1
    property real currentGooglePing: -1
    property real currentGatewayPing: -1

    // Dynamic Y-scale target and eased display value for the chart.
    property real maxPing: 100
    property real displayMaxPing: 100

    // Smoothed values currently rendered in the chart/labels.
    property real displayCloudflarePing: -1
    property real displayGooglePing: -1
    property real displayGatewayPing: -1

    property bool chartDirty: false

    // Fixed ping targets. The plasmoid spawns a short-lived `ping -c 1 -W 1`
    // for each of these once per second; no daemon, no state file. -W 1 caps
    // each fork at ~1.2s so cleanup is automatic — even if disconnectSource
    // failed to kill a child, nothing lingers.
    readonly property string cloudflareHost: "1.1.1.1"
    readonly property string googleHost: "8.8.8.8"
    readonly property string cloudflareCommand: "ping -n -c 1 -W 1 " + cloudflareHost
    readonly property string googleCommand: "ping -n -c 1 -W 1 " + googleHost
    property string gatewayCommand: ""
    // Two probes in one fork. `show default` gives the gateway to ping;
    // `route get` resolves how a packet to the internet would *actually*
    // leave, which is a different question once policy routing is involved.
    readonly property string gatewayLookupCommand: "ip -4 route show default; ip route get " + cloudflareHost

    // --- Tailscale exit node ---------------------------------------------
    // Toggling routes all egress through a peer on the tailnet. Useful on
    // hostile/low-reputation guest wifi (captive-portal networks that NAT
    // through a datacenter ASN), where services see a bot-like source IP.
    //
    // `tailscale set` normally needs root, but ithilien has OperatorUser set
    // to the desktop user, so plasmashell can drive it with no polkit prompt.
    // If that pref is ever cleared the set commands fail with a non-zero exit
    // and the button reverts — it will not silently appear to work.
    readonly property string exitNodeHost: "mistral"
    // Peers are needed, not just top-level ExitNodeStatus: eligibility lives on
    // the peer entry (ExitNodeOption), and without it we can't tell "not
    // approved as an exit node" from "approved but not selected".
    readonly property string exitNodeStatusCommand: "tailscale status --json"
    readonly property string exitNodeOnCommand: "tailscale set --exit-node=" + exitNodeHost + " --exit-node-allow-lan-access"
    readonly property string exitNodeOffCommand: "tailscale set --exit-node="

    // Did the last status poll produce usable output? False when tailscaled is
    // down or the binary is missing, which is distinct from "off" — we don't
    // know the state, so the button greys out rather than inviting a click.
    property bool exitNodeStatusOk: false
    // tailscaled's BackendState is "Running"; false while logged out, stopped,
    // or still starting.
    property bool exitNodeBackendUp: false
    // The configured peer exists and the tailnet has approved it to offer
    // exit-node service (admin console "Use as exit node").
    property bool exitNodePeerFound: false
    property bool exitNodeApproved: false
    property bool exitNodePeerOnline: false
    // Exit node engaged (per tailscaled, not per our own last click).
    property bool exitNodeOn: false
    // A set command is in flight; suppresses double-fires and re-polls.
    property bool exitNodeBusy: false
    property string exitNodeIp: ""
    property bool exitNodeFailed: false

    // Usable as a target to switch ON. Requires the peer to be reachable —
    // selecting an offline exit node is legal in Tailscale but blackholes all
    // egress, so the button refuses rather than handing the user a dead link.
    readonly property bool exitNodeAvailable: exitNodeStatusOk
            && exitNodeBackendUp && exitNodePeerFound && exitNodeApproved
            && exitNodePeerOnline

    // Clickable. Turning OFF must stay possible even when the peer has gone
    // offline or lost approval — that is exactly the state where egress is
    // blackholed and the user most needs the escape hatch. Only an in-flight
    // command or a failed status poll blocks it.
    readonly property bool exitNodeActionable: !exitNodeBusy
            && exitNodeStatusOk
            && (exitNodeOn || exitNodeAvailable)

    readonly property string exitNodeReason: {
        if (exitNodeBusy) {
            return "Applying…"
        }
        if (!exitNodeStatusOk) {
            return "Tailscale status unavailable"
        }
        if (!exitNodeBackendUp) {
            return "Tailscale is not connected"
        }
        if (!exitNodePeerFound) {
            return exitNodeHost + " is not on this tailnet"
        }
        if (!exitNodeApproved) {
            return exitNodeHost + " is not an approved exit node"
        }
        if (exitNodeOn && !exitNodePeerOnline) {
            return "Routing via " + exitNodeHost + " (peer offline)"
        }
        if (!exitNodePeerOnline) {
            return exitNodeHost + " is offline"
        }
        // Reported last, so a specific diagnosis above wins. What lands here is
        // the confusing case: everything looks healthy but `tailscale set` was
        // rejected anyway — e.g. OperatorUser cleared, so the command needs a
        // root the widget doesn't have.
        if (exitNodeFailed) {
            return "Last change was rejected by tailscale"
        }
        return exitNodeOn
                ? "Routing via " + exitNodeHost
                : "Direct egress"
    }

    // --- Egress identity --------------------------------------------------
    // Who the internet thinks we are. Only meaningful to look up from the
    // outside, so this is the one thing the widget can't answer locally.
    //
    // Deliberately not on a timer: the answer only changes when the exit node
    // flips or the underlying network does, and polling a third party on a
    // schedule leaks our address more often than it needs to. Refresh is
    // driven by those two events plus popup expand — i.e. when someone is
    // actually looking.
    readonly property string egressCommand: "curl -s --max-time 5 https://ipinfo.io/json"
    property string egressIp: ""
    property string egressOrg: ""
    property bool egressOk: false
    // Whether the exit node was engaged at the moment these values were read.
    // The label's colour derives from this rather than the live exitNodeOn, so
    // colour and text always describe the same observation — binding colour to
    // live state made it flip seconds before the text caught up, briefly
    // showing "tunnelled" styling over the previous network's address.
    property bool egressViaExitNode: false
    // Routing as it stood when the in-flight request was dispatched. The
    // lookup has a five-second window, and reading the snapshot when the
    // response lands would attribute the result to whatever routing exists by
    // then — which, if the exit node flipped mid-request, is not the routing
    // that produced the address.
    property bool egressRequestViaExitNode: false
    // Current values may no longer describe the current network. Set when the
    // default route or the exit node changes, cleared once a fresh lookup
    // lands. Drives both the dimmed presentation and the expand-time refetch.
    property bool egressStale: false

    // Identity of the default route, not just its gateway address. Roaming
    // between two networks that both use 192.168.1.1 leaves the gateway
    // unchanged, so keying off it alone would never notice the move and the
    // widget would keep asserting the previous network's ISP. Interface and
    // local source address disambiguate.
    property string routeFingerprint: ""

    // --- Text scale -------------------------------------------------------
    // Every font size in the widget derives from this, so the whole popup
    // scales from one number rather than needing eight edits.
    readonly property real fontScale: 1.25
    readonly property real baseFontSize: Kirigami.Theme.defaultFont.pixelSize * fontScale

    property int windowSecs: 60
    readonly property var windowOptions: [
        { label: "1 min", secs: 60 },
        { label: "5 min", secs: 300 },
        { label: "10 min", secs: 600 },
        { label: "30 min", secs: 1800 },
        { label: "60 min", secs: 3600 }
    ]
    readonly property int gridIntervals: 2
    readonly property int gridLineCount: gridIntervals + 1

    readonly property color cloudflareColor: Kirigami.Theme.positiveTextColor
    readonly property color googleColor: Kirigami.Theme.negativeTextColor
    readonly property color gatewayColor: "#4aa3ff"

    property bool shuttingDown: false
    readonly property bool samplingActive: !shuttingDown
            && Plasmoid.status !== PlasmaCore.Types.HiddenStatus

    property string gatewayIp: ""
    property bool gatewayOnline: false
    property string lastPingReceivedText: "--:--:--"

    // --- Icon-tier state machine ----------------------------------------
    // alert    : both 1.1.1.1 and 8.8.8.8 timing out (internet unreachable).
    // warn     : one of cloudflare/google timing out OR fastest latency > warnLatencyMs.
    // good     : both responding, fastest latency ≤ warnLatencyMs.
    // disabled : no data yet (just started, slow-poll hasn't returned).
    // Threshold sized for "is something wrong": typical residential
    // internet sits 5–40 ms, datacenter access 1–10 ms. 150 ms is well
    // above normal but below pathologically broken, so it catches
    // congestion/wifi issues without crying wolf on a transient spike.
    readonly property int warnLatencyMs: 150

    readonly property bool cloudflareUp: currentCloudflarePing >= 0
    readonly property bool googleUp: currentGooglePing >= 0
    readonly property real fastestInternetPing: {
        if (cloudflareUp && googleUp) {
            return Math.min(currentCloudflarePing, currentGooglePing)
        }
        if (cloudflareUp) {
            return currentCloudflarePing
        }
        if (googleUp) {
            return currentGooglePing
        }
        return -1
    }
    readonly property bool hasAnyData: cloudflareUp || googleUp || currentGatewayPing >= 0

    readonly property string iconTier: {
        if (!hasAnyData) {
            return "disabled"
        }
        if (!cloudflareUp && !googleUp) {
            return "alert"
        }
        if (!cloudflareUp || !googleUp || fastestInternetPing > warnLatencyMs) {
            return "warn"
        }
        return "good"
    }
    readonly property color iconColor: {
        if (iconTier === "alert") {
            return Kirigami.Theme.negativeTextColor
        }
        if (iconTier === "warn") {
            return Kirigami.Theme.neutralTextColor
        }
        if (iconTier === "good") {
            return Kirigami.Theme.positiveTextColor
        }
        return Kirigami.Theme.textColor
    }
    readonly property real iconOpacity: iconTier === "disabled" ? 0.45 : 1.0

    Plasmoid.icon: "kstars_satellites"
    // Alert tier forces the icon out of the auto-hide tray section so an
    // outage is actually visible. Other tiers stay Active so the icon is
    // always present but doesn't push past the system-tray collapse.
    Plasmoid.status: iconTier === "alert"
            ? PlasmaCore.Types.NeedsAttentionStatus
            : PlasmaCore.Types.ActiveStatus

    toolTipMainText: "Ping Monitor"
    toolTipSubText: {
        var lines = []
        if (!hasAnyData) {
            lines.push("Waiting for first sample…")
        } else {
            lines.push("1.1.1.1: " + (cloudflareUp ? currentCloudflarePing.toFixed(0) + " ms" : "timeout"))
            lines.push("8.8.8.8: " + (googleUp ? currentGooglePing.toFixed(0) + " ms" : "timeout"))
            if (gatewayIp.length > 0) {
                lines.push(gatewayIp + ": " + (currentGatewayPing >= 0 ? currentGatewayPing.toFixed(0) + " ms" : "timeout"))
            }
        }
        // Only worth a line when engaged — "not using an exit node" is the
        // default state and doesn't need saying on every hover. Gated on the
        // poll having succeeded too: exitNodeOn holds its last value when a
        // poll fails, and asserting stale routing here would contradict the
        // popup, which drops to a neutral label in the same situation.
        if (exitNodeStatusOk && exitNodeOn) {
            lines.push("Exit node: " + exitNodeHost
                    + (exitNodePeerOnline ? "" : " (offline)"))
        }
        return lines.join("\n")
    }
    toolTipTextFormat: Text.PlainText

    function updateGatewayIp(newIp) {
        var ip = (newIp || "").trim()
        if (ip === gatewayIp) {
            return
        }
        gatewayIp = ip
        if (gatewayIp.length === 0) {
            applyPing("gateway", -1)
        } else if (gatewayIp.length > 0) {
            gatewayOnline = false
            currentGatewayPing = -1
            displayGatewayPing = -1
        }
    }

    function formatHms(ms) {
        if (ms <= 0) {
            return "--:--:--"
        }
        var d = new Date(ms)
        function two(n) { return (n < 10 ? "0" : "") + n }
        return two(d.getHours()) + ":" + two(d.getMinutes()) + ":" + two(d.getSeconds())
    }

    function setWindowSeconds(seconds) {
        if (seconds <= 0 || seconds === windowSecs) {
            return
        }
        windowSecs = seconds
    }

    // Axis scale: 2 chunks (3 lines), at least 25ms per chunk (minimum range 0..100ms).
    function axisStepMs() {
        var base = Math.max(100, displayMaxPing)
        var step = Math.ceil((base / gridIntervals) / 25) * 25
        return Math.max(50, step)
    }

    function axisTopMs() {
        return axisStepMs() * gridIntervals
    }

    // Parse-independent ping application path used by both providers.
    // `ping` is in ms; invalid/timeout values are normalized to -1.
    function applyPing(target, ping) {
        var value = (ping >= 0 && ping < 1000) ? ping : -1
        var now = Date.now()

        if (target === "cloudflare") {
            if (value < 0) {
                currentCloudflarePing = -1
                displayCloudflarePing = -1
            } else {
                currentCloudflarePing = value
                displayCloudflarePing = value
                lastPingReceivedText = formatHms(now)
            }
        } else if (target === "google") {
            if (value < 0) {
                currentGooglePing = -1
                displayGooglePing = -1
            } else {
                currentGooglePing = value
                displayGooglePing = value
                lastPingReceivedText = formatHms(now)
            }
        } else if (target === "gateway") {
            if (value < 0) {
                currentGatewayPing = -1
                displayGatewayPing = -1
                gatewayOnline = false
            } else {
                currentGatewayPing = value
                displayGatewayPing = value
                gatewayOnline = true
            }
        }
        chartDirty = true
    }

    // Parse the first "time=X ms" (or "time<X ms") field from a `ping -c 1`
    // stdout chunk. Returns -1 for timeout/unreachable/parse failure.
    function parsePingMs(rawText) {
        const text = rawText || "";
        const lower = text.toLowerCase();
        if (lower.indexOf("100% packet loss") !== -1
                || lower.indexOf("unreachable") !== -1
                || lower.indexOf("no answer yet") !== -1) {
            return -1;
        }
        const match = text.match(/time[=<]([\d.]+)\s*ms/i);
        if (!match) {
            return -1;
        }
        const value = parseFloat(match[1]);
        if (isNaN(value) || value < 0) {
            return -1;
        }
        return value;
    }

    // Pull the gateway IP out of `ip -4 route show default` output.
    function parseGatewayIp(rawText) {
        const lines = (rawText || "").split(/\r?\n/);
        for (const line of lines) {
            const parts = line.trim().split(/\s+/);
            if (parts.length >= 3 && parts[0] === "default" && parts[1] === "via") {
                return parts[2];
            }
        }
        return "";
    }

    // Pull exit-node state out of `tailscale status --json`. ExitNodeStatus is
    // null when no exit node is selected, otherwise an object carrying the
    // peer's reachability and tailnet addresses.
    //
    // Returns null (not an "off" result) when the output can't be parsed, so a
    // transient failure — tailscaled restarting, the fork getting killed —
    // leaves the button showing its last known good state instead of flapping
    // to "off" and inviting a click that would toggle the wrong way.
    // Entries may be bare ("100.90.1.121") or carry a prefix length
    // ("100.90.1.121/32") depending on which part of the status blob they came
    // from, so strip the suffix unconditionally.
    function firstIPv4(addresses) {
        const list = addresses || [];
        for (var i = 0; i < list.length; ++i) {
            const bare = String(list[i]).split("/")[0];
            if (bare.indexOf(":") === -1) {
                return bare;
            }
        }
        return "";
    }

    function parseExitNodeStatus(rawText) {
        var data;
        try {
            data = JSON.parse(rawText || "");
        } catch (e) {
            return null;
        }
        if (!data || typeof data !== "object") {
            return null;
        }

        const result = {
            backendUp: data["BackendState"] === "Running",
            peerFound: false,
            approved: false,
            peerOnline: false,
            on: false,
            ip: ""
        };

        // Match on HostName, falling back to the MagicDNS name so a host whose
        // tailnet hostname has been rewritten still resolves.
        const wanted = root.exitNodeHost.toLowerCase();
        const peers = data["Peer"] || {};
        for (const key in peers) {
            const peer = peers[key];
            if (!peer) {
                continue;
            }
            const hostName = String(peer["HostName"] || "").toLowerCase();
            const dnsName = String(peer["DNSName"] || "").toLowerCase();
            if (hostName !== wanted && dnsName.indexOf(wanted + ".") !== 0) {
                continue;
            }
            result.peerFound = true;
            result.approved = peer["ExitNodeOption"] === true;
            result.peerOnline = peer["Online"] === true;
            result.on = peer["ExitNode"] === true;
            result.ip = firstIPv4(peer["TailscaleIPs"]);
            break;
        }
        return result;
    }

    function applyExitNodeStatus(parsed) {
        if (!parsed) {
            // The poll failed — tailscaled down, binary missing, output
            // truncated. We no longer know the real state, so drop to the
            // disabled presentation instead of acting on stale flags.
            exitNodeStatusOk = false;
            return;
        }
        exitNodeStatusOk = true;
        exitNodeBackendUp = parsed.backendUp;
        exitNodePeerFound = parsed.peerFound;
        exitNodeApproved = parsed.approved;
        exitNodePeerOnline = parsed.peerOnline;
        exitNodeOn = parsed.on;
        exitNodeIp = parsed.ip;
    }

    // Identity of the path packets to the internet actually take, read from
    // `ip route get <probe>` rather than the default route.
    //
    // The default route is the wrong thing to watch. A VPN — including this
    // widget's own Tailscale exit node — redirects egress through policy
    // routing or a split default (0.0.0.0/1 + 128.0.0.0/1) while leaving the
    // physical `default` line untouched, so keying off it would miss the
    // change entirely. `route get` resolves the effective route: with the exit
    // node engaged it reports `dev tailscale0 table 52` while `show default`
    // still reports the wifi gateway.
    //
    // via/dev/table/src together also cover the plain roaming case, since two
    // networks sharing a gateway address still differ in interface or lease.
    // `uid` and the trailing `cache` line are constant noise and excluded.
    function parseRouteFingerprint(rawText) {
        const lines = (rawText || "").split(/\r?\n/);
        for (const line of lines) {
            const parts = line.trim().split(/\s+/);
            if (parts.length < 3 || parts[0] !== root.cloudflareHost) {
                continue;
            }
            var via = "";
            var dev = "";
            var table = "";
            var src = "";
            for (var i = 1; i < parts.length - 1; ++i) {
                if (parts[i] === "via") {
                    via = parts[i + 1];
                } else if (parts[i] === "dev") {
                    dev = parts[i + 1];
                } else if (parts[i] === "table") {
                    table = parts[i + 1];
                } else if (parts[i] === "src") {
                    src = parts[i + 1];
                }
            }
            return via + "|" + dev + "|" + table + "|" + src;
        }
        return "";
    }

    // ipinfo returns `org` as "AS<number> <Legal Entity Name>", which is too
    // long for the popup and mostly noise. Reduce it to the recognisable part.
    //
    // Stripping the ASN and the corporate suffix, then taking the first word,
    // handles most ISPs: "AS7922 Comcast Cable Communications, LLC" -> Comcast,
    // "AS21928 T-Mobile USA, Inc." -> T-Mobile, "AS63182 RapidScale, Inc" ->
    // RapidScale. It cannot recover a trade name that shares no prefix with
    // the legal name, so those need an explicit entry — Starlink's operator
    // registers as "Space Exploration Technologies Corporation", which the
    // heuristic would render as "Space".
    readonly property var orgAliases: ({
        "space exploration technologies": "SpaceX"
    })

    function abbreviateOrg(rawOrg) {
        var text = String(rawOrg || "").trim();
        if (text.length === 0) {
            return "";
        }
        text = text.replace(/^AS\d+\s+/i, "");
        text = text.replace(/[,\s]+(inc|llc|l\.l\.c|ltd|limited|corp|corporation|company|co|plc|gmbh|ag|sa|bv|nv)\.?$/i, "");

        const lowered = text.toLowerCase();
        for (const key in orgAliases) {
            if (lowered.indexOf(key) === 0) {
                return orgAliases[key];
            }
        }
        return text.split(/\s+/)[0].replace(/,+$/, "");
    }

    function parseEgress(rawText) {
        var data;
        try {
            data = JSON.parse(rawText || "");
        } catch (e) {
            return null;
        }
        if (!data || typeof data !== "object" || !data["ip"]) {
            return null;
        }
        return {
            ip: String(data["ip"]),
            org: abbreviateOrg(data["org"])
        };
    }

    function applyEgress(parsed) {
        if (!parsed) {
            egressOk = false;
            return;
        }
        // Routing moved while this request was in flight, so the address it
        // returned describes a path we are no longer on. Discard it and go
        // again rather than publishing an answer to a stale question.
        if ((exitNodeStatusOk && exitNodeOn) !== egressRequestViaExitNode) {
            invalidateEgress();
            return;
        }
        egressOk = true;
        egressStale = false;
        egressIp = parsed.ip;
        egressOrg = parsed.org;
        // Taken at dispatch, not now, so the label can never colour itself
        // for a state its text doesn't reflect.
        egressViaExitNode = egressRequestViaExitNode;
    }

    // Both triggers mean the displayed identity may no longer be true. Mark it
    // stale rather than clearing it: hiding the label outright would shift the
    // layout for the few seconds a lookup takes, whereas dimming keeps the row
    // stable while still signalling "re-checking".
    function invalidateEgress() {
        egressStale = true;
        egressRefreshDebounce.restart();
    }

    function refreshEgress() {
        if (!samplingActive) {
            return;
        }
        egressRequestViaExitNode = exitNodeStatusOk && exitNodeOn;
        executableSource.disconnectSource(egressCommand);
        executableSource.connectSource(egressCommand);
    }

    function refreshExitNode() {
        if (!samplingActive) {
            return;
        }
        executableSource.disconnectSource(exitNodeStatusCommand);
        executableSource.connectSource(exitNodeStatusCommand);
    }

    function toggleExitNode() {
        if (!exitNodeActionable) {
            return;
        }
        exitNodeBusy = true;
        exitNodeFailed = false;
        const command = exitNodeOn ? exitNodeOffCommand : exitNodeOnCommand;
        executableSource.disconnectSource(command);
        executableSource.connectSource(command);
        exitNodeBusyTimeout.restart();
    }

    function spawnPing(command) {
        if (!command) {
            return;
        }
        // Re-connecting an already-connected source is a no-op for the engine
        // but the disconnect-then-connect dance forces a fresh run. -W 1 caps
        // the in-flight ping at ~1.2s so even back-to-back ticks won't pile up.
        executableSource.disconnectSource(command);
        executableSource.connectSource(command);
    }

    function pingAllTargets() {
        if (!samplingActive) {
            return;
        }
        spawnPing(cloudflareCommand);
        spawnPing(googleCommand);
        if (gatewayCommand.length > 0) {
            spawnPing(gatewayCommand);
        }
    }

    function refreshGateway() {
        if (!samplingActive) {
            return;
        }
        executableSource.disconnectSource(gatewayLookupCommand);
        executableSource.connectSource(gatewayLookupCommand);
    }

    Timer {
        id: pingTimer
        interval: root.currentPingInterval
        running: root.samplingActive
        repeat: true
        triggeredOnStart: true
        onTriggered: root.pingAllTargets()
    }

    // Also drives the exit-node poll. Exit-node state only changes on explicit
    // action (this button, the CLI, another device), so it rides the slow
    // 30 s cadence rather than earning a timer of its own — one extra fork
    // every 30 s against the three pings every 1–5 s the widget already spawns.
    Timer {
        id: gatewayRefreshTimer
        interval: 30000
        running: root.samplingActive
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            root.refreshGateway()
            root.refreshExitNode()
        }
    }

    // The ping forks self-cap via `-W 1`, but `tailscale set` has no timeout —
    // it blocks for as long as the backend takes. A wedged or unspawnable
    // tailscaled would therefore leave exitNodeBusy latched, and since
    // exitNodeActionable requires !exitNodeBusy the button would stay dead
    // until the widget is reloaded. Release the flag on a watchdog and re-poll
    // so the UI recovers on its own.
    // Coalesces egress re-lookups. Both triggers (exit node flipped, gateway
    // changed) often fire together, and routing needs a moment to settle after
    // either — querying instantly would return the address we just left.
    Timer {
        id: egressRefreshDebounce
        interval: 2500
        repeat: false
        onTriggered: root.refreshEgress()
    }

    onExitNodeOnChanged: invalidateEgress()
    onRouteFingerprintChanged: invalidateEgress()

    Timer {
        id: exitNodeBusyTimeout
        interval: 15000
        repeat: false
        onTriggered: {
            if (root.exitNodeBusy) {
                root.exitNodeBusy = false
                root.exitNodeFailed = true
                root.refreshExitNode()
            }
        }
    }

    Plasma5Support.DataSource {
        id: executableSource
        engine: "executable"
        interval: 0
        onNewData: (sourceName, sourceData) => {
            const stdout = sourceData["stdout"] || "";
            if (sourceName === root.cloudflareCommand) {
                root.applyPing("cloudflare", root.parsePingMs(stdout));
            } else if (sourceName === root.googleCommand) {
                root.applyPing("google", root.parsePingMs(stdout));
            } else if (sourceName === root.gatewayLookupCommand) {
                const ip = root.parseGatewayIp(stdout);
                // Keep the last known fingerprint if the probe produced
                // nothing — `route get` can transiently fail while an
                // interface is reconfiguring, and letting that write an empty
                // value would invalidate the egress cache on every blip.
                const fingerprint = root.parseRouteFingerprint(stdout);
                if (fingerprint.length > 0) {
                    root.routeFingerprint = fingerprint;
                }
                root.updateGatewayIp(ip);
                root.gatewayCommand = ip.length > 0
                        ? "ping -n -c 1 -W 1 " + ip
                        : "";
            } else if (sourceName === root.gatewayCommand && root.gatewayCommand.length > 0) {
                root.applyPing("gateway", root.parsePingMs(stdout));
            } else if (sourceName === root.egressCommand) {
                const egressFailed = (sourceData["exit code"] || 0) !== 0;
                root.applyEgress(egressFailed ? null : root.parseEgress(stdout));
            } else if (sourceName === root.exitNodeStatusCommand) {
                const failed = (sourceData["exit code"] || 0) !== 0;
                root.applyExitNodeStatus(failed ? null : root.parseExitNodeStatus(stdout));
            } else if (sourceName === root.exitNodeOnCommand || sourceName === root.exitNodeOffCommand) {
                // `tailscale set` blocks until the backend has applied the
                // pref, so the state re-poll below is not racing the change.
                exitNodeBusyTimeout.stop();
                root.exitNodeBusy = false;
                root.exitNodeFailed = (sourceData["exit code"] || 0) !== 0;
                root.refreshExitNode();
            }
            executableSource.disconnectSource(sourceName);
        }
    }

    Component.onCompleted: {
        // Kick the first poll cycle immediately so the icon colour
        // converges within ~1 s of the widget being added, instead of
        // waiting up to slowPingMs (10 s) for the first scheduled tick.
        refreshGateway()
        pingAllTargets()
    }

    onExpandedChanged: function() {
        // When the popup opens, fire a fresh 1 s-cadence ping right away
        // so the chart starts updating without waiting for the timer's
        // next tick (which could be up to 10 s away if we were collapsed).
        if (root.expanded) {
            pingAllTargets()
            // The exit-node button is about to become clickable, so re-poll
            // rather than presenting state up to 30 s stale.
            refreshExitNode()
            // Only when we have nothing to show, or what we have is known to
            // be out of date. Re-querying on every popup open would hit a
            // third party repeatedly to be told the same thing.
            if (!egressOk || egressStale) {
                refreshEgress()
            }
        }
    }

    // Tray icon — colored satellite (from kstars's icon set) that flips
    // between the four iconTier colors. Click toggles the popup chart.
    // The Layout.fill* / Layout.min* dance is panel-orientation-aware so
    // we behave correctly in both horizontal (RowLayout) and vertical
    // (ColumnLayout) panel containments:
    //   - Horizontal panel: fill height (panel's fixed dimension), let
    //     width fall out as a square matched to height.
    //   - Vertical panel: fill width (panel's fixed dimension), let
    //     height fall out as a square matched to width.
    // Without this guard, Layout.fillHeight in a vertical panel would
    // claim the whole panel column. Mirrors the systemmonitor stock
    // applet's CompactRepresentation layout idiom.
    compactRepresentation: MouseArea {
        readonly property bool verticalPanel: Plasmoid.formFactor === PlasmaCore.Types.Vertical
        acceptedButtons: Qt.LeftButton
        Layout.fillWidth: verticalPanel
        Layout.fillHeight: !verticalPanel
        Layout.minimumWidth: verticalPanel ? Kirigami.Units.iconSizes.small : height
        Layout.minimumHeight: verticalPanel ? width : Kirigami.Units.iconSizes.small
        Layout.preferredWidth: verticalPanel ? Kirigami.Units.iconSizes.smallMedium : height
        Layout.preferredHeight: verticalPanel ? width : Kirigami.Units.iconSizes.smallMedium
        onClicked: root.expanded = !root.expanded

        Kirigami.Icon {
            anchors.fill: parent
            source: "kstars_satellites"
            isMask: true
            color: root.iconColor
            opacity: root.iconOpacity
            active: root.expanded
        }
    }

    fullRepresentation: PlasmaExtras.Representation {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 30
        Layout.minimumHeight: Kirigami.Units.gridUnit * 14
        Layout.preferredWidth: Kirigami.Units.gridUnit * 36
        Layout.preferredHeight: Kirigami.Units.gridUnit * 16
        collapseMarginsHint: true

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.3)
            radius: 4
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: Kirigami.Units.smallSpacing * 2
            anchors.rightMargin: Kirigami.Units.smallSpacing * 2
            anchors.topMargin: 2
            anchors.bottomMargin: 2
            spacing: 2

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.gridUnit

                RowLayout {
                    spacing: 4
                    Rectangle { width: 12; height: 12; radius: 6; color: root.cloudflareColor }
                    Text {
                        text: "1.1.1.1"
                        color: Kirigami.Theme.textColor
                        font.pixelSize: root.baseFontSize * 0.75
                        opacity: 0.8
                    }
                }

                RowLayout {
                    spacing: 4
                    Rectangle { width: 12; height: 12; radius: 6; color: root.googleColor }
                    Text {
                        text: "8.8.8.8"
                        color: Kirigami.Theme.textColor
                        font.pixelSize: root.baseFontSize * 0.75
                        opacity: 0.8
                    }
                }

                RowLayout {
                    visible: root.gatewayIp.length > 0
                    spacing: 4
                    Rectangle {
                        width: 12
                        height: 12
                        radius: 6
                        color: root.gatewayColor
                        visible: root.gatewayOnline
                    }
                    Text {
                        text: root.gatewayIp
                        textFormat: Text.PlainText
                        color: Kirigami.Theme.textColor
                        font.pixelSize: root.baseFontSize * 0.75
                        opacity: 0.8
                    }
                }

                Item { Layout.fillWidth: true }

                // Egress identity — who the internet currently sees us as.
                // Coloured by routing so the distinction reads without parsing
                // the text: amber means traffic is leaving via the exit node,
                // muted means it is going out locally.
                Text {
                    visible: root.egressOk && text.length > 0
                    Layout.maximumWidth: Kirigami.Units.gridUnit * 14
                    text: {
                        if (!root.egressOk) {
                            return ""
                        }
                        if (root.egressOrg.length > 0 && root.egressIp.length > 0) {
                            return root.egressOrg + " · " + root.egressIp
                        }
                        return root.egressOrg.length > 0 ? root.egressOrg : root.egressIp
                    }
                    // Snapshot, not live state — see egressViaExitNode.
                    color: root.egressViaExitNode
                            ? "#ffd54a"
                            : Qt.rgba(1, 1, 1, 0.55)
                    // Dimmed while a re-lookup is pending, so the moment
                    // between "route changed" and "new answer arrived" reads
                    // as provisional rather than as fact.
                    opacity: root.egressStale ? 0.45 : 1.0
                    // egressOrg and egressIp come from an HTTP response.
                    // Text.AutoText would interpret crafted markup as rich
                    // text and can load inline images, so pin it to literal
                    // text — matching toolTipTextFormat elsewhere in the file.
                    textFormat: Text.PlainText
                    font.pixelSize: root.baseFontSize * 0.75
                    elide: Text.ElideRight
                }

                // Tailscale exit-node toggle. Shares the pill idiom of the
                // window-range buttons below, and greys out whenever the
                // toggle can't be honoured — tailscaled down, peer missing,
                // not approved by the tailnet, or unreachable.
                Rectangle {
                    id: exitNodeButton
                    readonly property bool actionable: root.exitNodeActionable
                    readonly property bool engaged: root.exitNodeOn

                    Layout.preferredWidth: exitNodeText.implicitWidth + 12
                    Layout.preferredHeight: exitNodeText.implicitHeight + 5
                    radius: 3
                    opacity: actionable ? 1.0 : 0.45
                    color: engaged ? Qt.rgba(1, 1, 1, 0.20) : Qt.rgba(1, 1, 1, 0.08)
                    border.width: 1
                    border.color: engaged ? Qt.rgba(1, 1, 1, 0.45) : Qt.rgba(1, 1, 1, 0.18)

                    Text {
                        id: exitNodeText
                        anchors.centerIn: parent
                        // Neutral label while the state is unknown, so a failed
                        // poll doesn't assert "direct" egress that we can't
                        // actually vouch for.
                        text: {
                            if (!root.exitNodeStatusOk) {
                                return "exit node"
                            }
                            return root.exitNodeOn
                                    ? "via " + root.exitNodeHost
                                    : "direct"
                        }
                        color: {
                            if (root.exitNodeOn && !root.exitNodePeerOnline) {
                                return Kirigami.Theme.negativeTextColor
                            }
                            if (root.exitNodeOn) {
                                return "#ffd54a"
                            }
                            return Qt.rgba(1, 1, 1, 0.75)
                        }
                        font.pixelSize: root.baseFontSize * 0.64
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: exitNodeButton.actionable
                                ? Qt.PointingHandCursor
                                : Qt.ArrowCursor
                        // Swallow clicks rather than relying on the guard in
                        // toggleExitNode(), so a disabled button gives no
                        // press feedback at all.
                        acceptedButtons: exitNodeButton.actionable
                                ? Qt.LeftButton
                                : Qt.NoButton
                        onClicked: root.toggleExitNode()
                        QQC2.ToolTip.visible: containsMouse
                        QQC2.ToolTip.text: root.exitNodeReason
                    }
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                // Static grid lines remain independent from the dynamic chart layer.
                Repeater {
                    model: root.gridLineCount
                    Item {
                        required property int index
                        x: 0
                        y: 12 + (parent.height - 24) * index / root.gridIntervals
                        width: parent.width
                        height: 1

                        Rectangle {
                            width: parent.width - 90
                            height: 1
                            color: Kirigami.Theme.textColor
                            opacity: 0.1
                        }

                        Text {
                            x: (parent.width - 90) - width - 4
                            y: -height
                            text: ((root.gridIntervals - index) * root.axisStepMs()) + " ms"
                            color: Qt.rgba(1, 1, 1, 0.45)
                            font.pixelSize: root.baseFontSize * 0.85
                            opacity: 1
                        }
                    }
                }

                Item {
                    id: chartView
                    anchors.fill: parent

                    Connections {
                        target: root
                        function onWindowSecsChanged() {
                            chartView.scrollAccPoints = 0
                            chartView.refreshVisibleFromHistory()
                        }
                    }

                    readonly property real padY: 12
                    readonly property real rightMargin: 58
                    readonly property real chartW: Math.max(0, width - rightMargin)
                    readonly property real chartH: Math.max(0, height - padY * 2)
                    readonly property real publicRealtimeLabelFontSize: root.baseFontSize * 1.3
                    // Gateway has one extra character (e.g. "1.1ms"), so scale down to match public-label width.
                    readonly property real gatewayRealtimeLabelFontSize: publicRealtimeLabelFontSize * 0.8
                    // 4px sampling keeps point count low while remaining visually smooth.
                    readonly property real sampleStepPx: 4

                    property var cloudflareSamples: []
                    property var googleSamples: []
                    property var gatewaySamples: []
                    property int pointCount: 0
                    property int cloudflareValidPoints: 0
                    property int googleValidPoints: 0
                    property int gatewayValidPoints: 0
                    property real scrollAccPoints: 0
                    property real lastPathScale: -1
                    readonly property int maxSmoothingLagSecs: 18
                    readonly property int maxHistorySecs: 3600 + maxSmoothingLagSecs * 2
                    readonly property int historyCapacity: maxHistorySecs + 32
                    property var historyTimes: new Array(historyCapacity)
                    property var historyCloudflare: new Array(historyCapacity)
                    property var historyGoogle: new Array(historyCapacity)
                    property var historyGateway: new Array(historyCapacity)
                    property int historyStart: 0
                    property int historyCount: 0
                    property real lastRenderedWidth: -1
                    property real lastRenderedHeight: -1

                    property string cloudflarePath: ""
                    property string googlePath: ""
                    property string gatewayPath: ""

                    property real cachedMax: -1
                    property real cachedMin: -1
                    property int cachedMaxIndex: -1
                    property int cachedMinIndex: -1
                    property real cachedCloudflareX: -1
                    property real cachedGoogleX: -1
                    property real cachedGatewayX: -1
                    property real cachedCloudflareY: -1
                    property real cachedGoogleY: -1
                    property real cachedGatewayY: -1
                    property real cachedCloudflareLabelY: -1
                    property real cachedGoogleLabelY: -1
                    property real cachedGatewayLabelY: -1
                    property real cachedCloudflareLabelValue: -1
                    property real cachedGoogleLabelValue: -1
                    property real cachedGatewayLabelValue: -1
                    property real cachedMaxY: -1
                    property real cachedMinY: -1
                    readonly property bool idleMode: (cloudflareValidPoints === 0
                            && googleValidPoints === 0
                            && gatewayValidPoints === 0
                            && root.currentCloudflarePing < 0
                            && root.currentGooglePing < 0
                            && root.currentGatewayPing < 0
                            && root.displayCloudflarePing < 0
                            && root.displayGooglePing < 0
                            && root.displayGatewayPing < 0)

                    function computeY(v, maxVal) {
                        if (v < 0 || chartH <= 0) {
                            return -1
                        }
                        return padY + chartH - (Math.min(v, maxVal) / maxVal) * chartH
                    }

                    function ensureBuffers() {
                        var needed = Math.max(8, Math.floor(chartW / sampleStepPx))
                        if (needed === pointCount && cloudflareSamples.length === needed
                                && googleSamples.length === needed && gatewaySamples.length === needed) {
                            return false
                        }
                        pointCount = needed
                        cloudflareSamples = new Array(needed)
                        googleSamples = new Array(needed)
                        gatewaySamples = new Array(needed)
                        for (var i = 0; i < needed; ++i) {
                            cloudflareSamples[i] = -1
                            googleSamples[i] = -1
                            gatewaySamples[i] = -1
                        }
                        cloudflareValidPoints = 0
                        googleValidPoints = 0
                        gatewayValidPoints = 0
                        return true
                    }

                    function normalizedSample(v) {
                        return (v >= 0 && !isNaN(v)) ? v : -1
                    }

                    function historyPhysicalIndex(logicalIndex) {
                        return (historyStart + logicalIndex) % historyCapacity
                    }

                    function historyTimeAt(logicalIndex) {
                        return historyTimes[historyPhysicalIndex(logicalIndex)]
                    }

                    function historySampleAt(source, logicalIndex) {
                        return source[historyPhysicalIndex(logicalIndex)]
                    }

                    function pushHistorySample(nowMs) {
                        var cloudflareValue = normalizedSample((root.currentCloudflarePing >= 0 && root.displayCloudflarePing >= 0) ? root.displayCloudflarePing : -1)
                        var googleValue = normalizedSample((root.currentGooglePing >= 0 && root.displayGooglePing >= 0) ? root.displayGooglePing : -1)
                        var gatewayValue = normalizedSample((root.currentGatewayPing >= 0 && root.displayGatewayPing >= 0) ? root.displayGatewayPing : -1)

                        var writeIndex
                        if (historyCount < historyCapacity) {
                            writeIndex = historyPhysicalIndex(historyCount)
                            historyCount += 1
                        } else {
                            writeIndex = historyStart
                            historyStart = (historyStart + 1) % historyCapacity
                        }
                        historyTimes[writeIndex] = nowMs
                        historyCloudflare[writeIndex] = cloudflareValue
                        historyGoogle[writeIndex] = googleValue
                        historyGateway[writeIndex] = gatewayValue

                        var cutoff = nowMs - maxHistorySecs * 1000
                        while (historyCount > 0 && historyTimeAt(0) < cutoff) {
                            historyStart = (historyStart + 1) % historyCapacity
                            historyCount -= 1
                        }
                    }

                    function smoothingRadiusSecs() {
                        if (root.windowSecs >= 3600) {
                            return 18
                        }
                        if (root.windowSecs >= 1800) {
                            return 9
                        }
                        if (root.windowSecs >= 600) {
                            return 3
                        }
                        return 0
                    }

                    function localizedSmoothedValue(source, tMs, radiusSecs) {
                        if (radiusSecs <= 0) {
                            return interpolatedHistoryValue(source, tMs)
                        }

                        var sum = 0
                        var weightSum = 0
                        for (var dt = -radiusSecs; dt <= radiusSecs; ++dt) {
                            var v = interpolatedHistoryValue(source, tMs + dt * 1000)
                            if (v >= 0) {
                                var w = (radiusSecs + 1) - Math.abs(dt)
                                sum += v * w
                                weightSum += w
                            }
                        }
                        return (weightSum > 0) ? (sum / weightSum) : -1
                    }

                    function fillVisibleFromHistory(nowMs) {
                        var cloudflareCount = 0
                        var googleCount = 0
                        var gatewayCount = 0

                        if (pointCount <= 0) {
                            cloudflareValidPoints = 0
                            googleValidPoints = 0
                            gatewayValidPoints = 0
                            return
                        }

                        var sampleCount = historyCount
                        if (sampleCount <= 0) {
                            for (var clearIdx = 0; clearIdx < pointCount; ++clearIdx) {
                                cloudflareSamples[clearIdx] = -1
                                googleSamples[clearIdx] = -1
                                gatewaySamples[clearIdx] = -1
                            }
                            cloudflareValidPoints = 0
                            googleValidPoints = 0
                            gatewayValidPoints = 0
                            return
                        }

                        var radiusSecs = smoothingRadiusSecs()
                        var lagMs = radiusSecs * 1000
                        var windowMs = root.windowSecs * 1000
                        var renderEndMs = nowMs - lagMs
                        var startMs = renderEndMs - windowMs
                        var span = Math.max(1, pointCount - 1)

                        for (var j = 0; j < pointCount; ++j) {
                            var t = startMs + (windowMs * j / span)
                            var cloudflareValue = localizedSmoothedValue(historyCloudflare, t, radiusSecs)
                            var googleValue = localizedSmoothedValue(historyGoogle, t, radiusSecs)
                            var gatewayValue = localizedSmoothedValue(historyGateway, t, radiusSecs)
                            cloudflareSamples[j] = cloudflareValue
                            googleSamples[j] = googleValue
                            gatewaySamples[j] = gatewayValue
                            if (cloudflareValue >= 0) {
                                cloudflareCount += 1
                            }
                            if (googleValue >= 0) {
                                googleCount += 1
                            }
                            if (gatewayValue >= 0) {
                                gatewayCount += 1
                            }
                        }

                        cloudflareValidPoints = cloudflareCount
                        googleValidPoints = googleCount
                        gatewayValidPoints = gatewayCount
                    }

                    function recountVisibleValidity() {
                        var cloudflareCount = 0
                        var googleCount = 0
                        var gatewayCount = 0
                        for (var i = 0; i < pointCount; ++i) {
                            if (cloudflareSamples[i] >= 0 && !isNaN(cloudflareSamples[i])) {
                                cloudflareCount += 1
                            }
                            if (googleSamples[i] >= 0 && !isNaN(googleSamples[i])) {
                                googleCount += 1
                            }
                            if (gatewaySamples[i] >= 0 && !isNaN(gatewaySamples[i])) {
                                gatewayCount += 1
                            }
                        }
                        cloudflareValidPoints = cloudflareCount
                        googleValidPoints = googleCount
                        gatewayValidPoints = gatewayCount
                    }

                    function appendVisibleSamples(count, nowMs) {
                        if (pointCount <= 0 || count <= 0) {
                            return false
                        }
                        if (count >= pointCount) {
                            fillVisibleFromHistory(nowMs)
                            return true
                        }

                        var kept = pointCount - count
                        for (var i = 0; i < kept; ++i) {
                            cloudflareSamples[i] = cloudflareSamples[i + count]
                            googleSamples[i] = googleSamples[i + count]
                            gatewaySamples[i] = gatewaySamples[i + count]
                        }

                        var windowMs = root.windowSecs * 1000
                        var span = Math.max(1, pointCount - 1)
                        var sampleStepMs = windowMs / span
                        var lagMs = smoothingRadiusSecs() * 1000
                        var renderEndMs = nowMs - lagMs

                        for (var j = 0; j < count; ++j) {
                            var t = renderEndMs - (count - 1 - j) * sampleStepMs
                            cloudflareSamples[kept + j] = sampledSeriesValue(historyCloudflare, t)
                            googleSamples[kept + j] = sampledSeriesValue(historyGoogle, t)
                            gatewaySamples[kept + j] = sampledSeriesValue(historyGateway, t)
                        }

                        recountVisibleValidity()
                        return true
                    }

                    function historyIndexAtOrBefore(tMs) {
                        var n = historyCount
                        if (n <= 0 || tMs < historyTimeAt(0)) {
                            return -1
                        }
                        var lo = 0
                        var hi = n - 1
                        while (lo < hi) {
                            var mid = Math.floor((lo + hi + 1) / 2)
                            if (historyTimeAt(mid) <= tMs) {
                                lo = mid
                            } else {
                                hi = mid - 1
                            }
                        }
                        return lo
                    }

                    function interpolatedHistoryValue(source, tMs) {
                        var n = historyCount
                        if (n <= 0 || tMs < historyTimeAt(0)) {
                            return -1
                        }
                        var idx = historyIndexAtOrBefore(tMs)
                        if (idx < 0) {
                            return -1
                        }
                        if (idx >= n - 1) {
                            return normalizedSample(historySampleAt(source, n - 1))
                        }

                        var t0 = historyTimeAt(idx)
                        var t1 = historyTimeAt(idx + 1)
                        var v0 = normalizedSample(historySampleAt(source, idx))
                        var v1 = normalizedSample(historySampleAt(source, idx + 1))
                        if (v0 < 0 && v1 < 0) {
                            return -1
                        }
                        if (v0 < 0) {
                            return v1
                        }
                        if (v1 < 0 || t1 <= t0) {
                            return v0
                        }

                        var a = (tMs - t0) / (t1 - t0)
                        return v0 + (v1 - v0) * a
                    }

                    function sampledSeriesValue(source, tMs) {
                        return localizedSmoothedValue(source, tMs, smoothingRadiusSecs())
                    }

                    function refreshVisibleFromHistory() {
                        var nowMs = Date.now()
                        ensureBuffers()
                        fillVisibleFromHistory(nowMs)
                        scrollAccPoints = 0
                        lastRenderedWidth = width
                        lastRenderedHeight = height
                        rebuildPathsAndExtrema()
                        updateLiveLabels()
                    }

                    function scheduleResizeRefresh() {
                        if (Math.abs(width - lastRenderedWidth) < sampleStepPx
                                && Math.abs(height - lastRenderedHeight) < sampleStepPx) {
                            return
                        }
                        resizeDebounce.restart()
                    }

                    function rebuildPathsAndExtrema() {
                        var maxVal = Math.max(1, root.axisTopMs())
                        var cloudflarePathOutput = ""
                        var googlePathOutput = ""
                        var gatewayPathOutput = ""
                        var cloudflareStarted = false
                        var googleStarted = false
                        var gatewayStarted = false
                        var localMax = -Infinity
                        var localMin = Infinity
                        var localMaxIndex = -1
                        var localMinIndex = -1

                        for (var i = 0; i < pointCount; ++i) {
                            var x = i * sampleStepPx
                            var cloudflareSample = cloudflareSamples[i]
                            var googleSample = googleSamples[i]
                            var gatewaySample = gatewaySamples[i]

                            if (cloudflareSample >= 0 && !isNaN(cloudflareSample)) {
                                var cloudflareY = computeY(cloudflareSample, maxVal)
                                if (cloudflareStarted) {
                                    cloudflarePathOutput += " L " + x + " " + cloudflareY
                                } else {
                                    cloudflarePathOutput += "M " + x + " " + cloudflareY
                                    cloudflareStarted = true
                                }
                                if (cloudflareSample > localMax) {
                                    localMax = cloudflareSample
                                    localMaxIndex = i
                                }
                                if (cloudflareSample < localMin) {
                                    localMin = cloudflareSample
                                    localMinIndex = i
                                }
                            } else {
                                cloudflareStarted = false
                            }

                            if (googleSample >= 0 && !isNaN(googleSample)) {
                                var googleY = computeY(googleSample, maxVal)
                                if (googleStarted) {
                                    googlePathOutput += " L " + x + " " + googleY
                                } else {
                                    googlePathOutput += "M " + x + " " + googleY
                                    googleStarted = true
                                }
                                if (googleSample > localMax) {
                                    localMax = googleSample
                                    localMaxIndex = i
                                }
                                if (googleSample < localMin) {
                                    localMin = googleSample
                                    localMinIndex = i
                                }
                            } else {
                                googleStarted = false
                            }

                            if (gatewaySample >= 0 && !isNaN(gatewaySample)) {
                                var gatewayY = computeY(gatewaySample, maxVal)
                                if (gatewayStarted) {
                                    gatewayPathOutput += " L " + x + " " + gatewayY
                                } else {
                                    gatewayPathOutput += "M " + x + " " + gatewayY
                                    gatewayStarted = true
                                }
                            } else {
                                gatewayStarted = false
                            }
                        }

                        cloudflarePath = cloudflarePathOutput
                        googlePath = googlePathOutput
                        gatewayPath = gatewayPathOutput
                        cachedMaxIndex = localMaxIndex
                        cachedMinIndex = localMinIndex
                        cachedMax = (localMaxIndex >= 0) ? localMax : -1
                        cachedMin = (localMinIndex >= 0) ? localMin : -1
                        cachedMaxY = (cachedMaxIndex >= 0) ? computeY(cachedMax, maxVal) : -1
                        cachedMinY = (cachedMinIndex >= 0) ? computeY(cachedMin, maxVal) : -1
                        lastPathScale = maxVal
                    }

                    function latestSeriesPoint(source, maxVal) {
                        for (var i = pointCount - 1; i >= 0; --i) {
                            var v = source[i]
                            if (v >= 0 && !isNaN(v)) {
                                return {
                                    x: i * sampleStepPx,
                                    y: computeY(v, maxVal),
                                    value: v
                                }
                            }
                        }
                        return null
                    }

                    function updateLiveLabels() {
                        var maxVal = Math.max(1, root.axisTopMs())
                        var cloudflarePoint = latestSeriesPoint(cloudflareSamples, maxVal)
                        var googlePoint = latestSeriesPoint(googleSamples, maxVal)
                        var gatewayPoint = latestSeriesPoint(gatewaySamples, maxVal)
                        var cloudflareY = cloudflarePoint ? cloudflarePoint.y : -1
                        var googleY = googlePoint ? googlePoint.y : -1
                        var gatewayY = gatewayPoint ? gatewayPoint.y : -1
                        var fontSize = publicRealtimeLabelFontSize
                        var minGap = fontSize + 4
                        var topBound = fontSize
                        var bottomBound = height - 2
                        if (bottomBound < topBound) {
                            bottomBound = topBound
                        }

                        var labels = []
                        if (cloudflareY >= 0) {
                            labels.push({ target: "cloudflare", desiredY: cloudflareY, adjustedY: cloudflareY })
                        }
                        if (googleY >= 0) {
                            labels.push({ target: "google", desiredY: googleY, adjustedY: googleY })
                        }
                        if (gatewayY >= 0) {
                            labels.push({ target: "gateway", desiredY: gatewayY, adjustedY: gatewayY })
                        }
                        labels.sort(function(a, b) { return a.desiredY - b.desiredY })

                        for (var i = 0; i < labels.length; ++i) {
                            var y = labels[i].desiredY
                            if (i > 0 && y < labels[i - 1].adjustedY + minGap) {
                                y = labels[i - 1].adjustedY + minGap
                            }
                            labels[i].adjustedY = y
                        }

                        if (labels.length > 0 && labels[labels.length - 1].adjustedY > bottomBound) {
                            labels[labels.length - 1].adjustedY = bottomBound
                            for (var j = labels.length - 2; j >= 0; --j) {
                                var maxAllowed = labels[j + 1].adjustedY - minGap
                                if (labels[j].adjustedY > maxAllowed) {
                                    labels[j].adjustedY = maxAllowed
                                }
                            }
                            if (labels[0].adjustedY < topBound) {
                                labels[0].adjustedY = topBound
                                for (var k = 1; k < labels.length; ++k) {
                                    var minAllowed = labels[k - 1].adjustedY + minGap
                                    if (labels[k].adjustedY < minAllowed) {
                                        labels[k].adjustedY = minAllowed
                                    }
                                }
                            }
                        }

                        var cloudflareLabelY = -1
                        var googleLabelY = -1
                        var gatewayLabelY = -1
                        for (var m = 0; m < labels.length; ++m) {
                            var entry = labels[m]
                            if (entry.target === "cloudflare") {
                                cloudflareLabelY = entry.adjustedY
                            } else if (entry.target === "google") {
                                googleLabelY = entry.adjustedY
                            } else if (entry.target === "gateway") {
                                gatewayLabelY = entry.adjustedY
                            }
                        }

                        cachedCloudflareX = cloudflarePoint ? cloudflarePoint.x : -1
                        cachedGoogleX = googlePoint ? googlePoint.x : -1
                        cachedGatewayX = gatewayPoint ? gatewayPoint.x : -1
                        cachedCloudflareY = cloudflareY
                        cachedGoogleY = googleY
                        cachedGatewayY = gatewayY
                        cachedCloudflareLabelY = cloudflareLabelY
                        cachedGoogleLabelY = googleLabelY
                        cachedGatewayLabelY = gatewayLabelY
                        cachedCloudflareLabelValue = cloudflarePoint ? cloudflarePoint.value : -1
                        cachedGoogleLabelValue = googlePoint ? googlePoint.value : -1
                        cachedGatewayLabelValue = gatewayPoint ? gatewayPoint.value : -1
                    }

                    onWidthChanged: {
                        scheduleResizeRefresh()
                    }

                    onHeightChanged: {
                        scheduleResizeRefresh()
                    }

                    Component.onCompleted: {
                        refreshVisibleFromHistory()
                    }

                    Timer {
                        id: resizeDebounce
                        interval: 150
                        repeat: false
                        onTriggered: chartView.refreshVisibleFromHistory()
                    }

                    // History keeps filling at the pingTimer cadence (1 s
                    // expanded / 5 s collapsed) so the chart re-opens with
                    // recent data already buffered. Path rebuilds and the
                    // axis easing only happen while the popup is expanded —
                    // there's no point spending CPU painting an invisible
                    // chart.
                    Timer {
                        id: chartUpdateTimer
                        interval: root.currentPingInterval
                        repeat: true
                        running: root.samplingActive
                        onTriggered: {
                            var now = Date.now()
                            chartView.pushHistorySample(now)

                            if (!root.expanded || !chartView.visible) {
                                return
                            }

                            var oldAxisTop = root.axisTopMs()

                            // Compute this tick's desired ceiling from the
                            // current visible window (plus any in-flight
                            // sample that hasn't propagated into cachedMax
                            // yet, for sub-10-min windows where transients
                            // matter).
                            var visibleMax = chartView.cachedMax
                            if (root.windowSecs < 600) {
                                if (root.displayCloudflarePing > visibleMax) {
                                    visibleMax = root.displayCloudflarePing
                                }
                                if (root.displayGooglePing > visibleMax) {
                                    visibleMax = root.displayGooglePing
                                }
                                if (root.displayGatewayPing > visibleMax) {
                                    visibleMax = root.displayGatewayPing
                                }
                            }
                            if (visibleMax < 0) {
                                visibleMax = 100
                            }
                            var newMaxPing = Math.max(100, Math.ceil(visibleMax / 25) * 25)
                            root.maxPing = newMaxPing

                            // Directional easing for the rendered axis
                            // ceiling. Snap up immediately on expansion so
                            // a sudden RTT spike isn't clipped at the
                            // previous tick's lower ceiling; ease down at
                            // 5 %/tick on contraction so the chart doesn't
                            // jitter the axis after every transient peak
                            // ages out of the visible window.
                            if (newMaxPing >= root.displayMaxPing) {
                                root.displayMaxPing = newMaxPing
                            } else {
                                var maxDelta = newMaxPing - root.displayMaxPing
                                if (Math.abs(maxDelta) > 0.25) {
                                    root.displayMaxPing += maxDelta * 0.05
                                } else {
                                    root.displayMaxPing = newMaxPing
                                }
                            }

                            var rebuilt = false
                            if (chartView.ensureBuffers()) {
                                chartView.fillVisibleFromHistory(now)
                                chartView.scrollAccPoints = 0
                                rebuilt = true
                            }
                            var pointsPerTick = (chartView.pointCount > 0) ? (chartView.pointCount / root.windowSecs) : 0
                            chartView.scrollAccPoints += pointsPerTick
                            var ds = Math.floor(chartView.scrollAccPoints)
                            if (ds > 0) {
                                chartView.scrollAccPoints -= ds
                                rebuilt = chartView.appendVisibleSamples(ds, now) || rebuilt
                            }

                            var axisChanged = Math.abs(root.axisTopMs() - oldAxisTop) > 0.1

                            if (root.chartDirty || rebuilt || axisChanged) {
                                chartView.rebuildPathsAndExtrema()
                                chartView.updateLiveLabels()
                                root.chartDirty = false
                            }
                        }
                    }

                    // Catch-up render when the popup is reopened after a
                    // collapsed stretch — `chartUpdateTimer` was skipping
                    // path rebuilds, so the chart visuals are stale relative
                    // to what's now in the history ring buffer.
                    Connections {
                        target: root
                        function onExpandedChanged() {
                            if (root.expanded) {
                                chartView.refreshVisibleFromHistory()
                            }
                        }
                    }

                    Component.onDestruction: {
                        try { if (chartUpdateTimer) chartUpdateTimer.stop() } catch (e) {}
                    }

                    Item {
                        id: blurScene
                        anchors.fill: parent
                        visible: !chartView.idleMode
                    }

                    Shape {
                        id: chartShape
                        parent: blurScene
                        anchors.fill: parent
                        antialiasing: true
                        preferredRendererType: Shape.CurveRenderer

                        ShapePath {
                            strokeColor: root.cloudflareColor
                            strokeWidth: 2
                            fillColor: "transparent"
                            capStyle: ShapePath.RoundCap
                            joinStyle: ShapePath.RoundJoin
                            PathSvg { path: chartView.cloudflarePath }
                        }

                        ShapePath {
                            strokeColor: root.googleColor
                            strokeWidth: 2
                            fillColor: "transparent"
                            capStyle: ShapePath.RoundCap
                            joinStyle: ShapePath.RoundJoin
                            PathSvg { path: chartView.googlePath }
                        }

                        ShapePath {
                            strokeColor: root.gatewayColor
                            strokeWidth: 2
                            fillColor: "transparent"
                            capStyle: ShapePath.RoundCap
                            joinStyle: ShapePath.RoundJoin
                            PathSvg { path: chartView.gatewayPath }
                        }
                    }

                    Rectangle {
                        parent: blurScene
                        visible: chartView.cachedMaxIndex >= 0 && chartView.cachedMaxY >= 0
                        width: 8
                        height: 8
                        radius: 4
                        color: "#ffdd44"
                        x: chartView.cachedMaxIndex * chartView.sampleStepPx - width / 2
                        y: chartView.cachedMaxY - height / 2
                    }

                    Rectangle {
                        id: maxBubble
                        visible: !chartView.idleMode && chartView.cachedMaxIndex >= 0 && chartView.cachedMaxY >= 0
                        radius: 3
                        color: Qt.rgba(1, 1, 1, 0.08)
                        width: maxText.implicitWidth + 6
                        height: maxText.implicitHeight + 4
                        property real dotX: chartView.cachedMaxIndex * chartView.sampleStepPx
                        x: (dotX + 8 + width > chartView.chartW - 10) ? Math.max(0, dotX - 8 - width) : dotX + 8
                        y: Math.max(2, Math.min(chartView.height - height - 2, chartView.cachedMaxY - 10 - height / 2))
                        border.width: 1
                        border.color: Qt.rgba(1, 1, 1, 0.2)

                        Text {
                            id: maxText
                            anchors.centerIn: parent
                            color: "#ffdd44"
                            font.pixelSize: root.baseFontSize * 1.2
                            font.bold: true
                            text: chartView.cachedMax >= 0 ? chartView.cachedMax.toFixed(1) + " ms" : ""
                        }
                    }

                    Rectangle {
                        parent: blurScene
                        visible: chartView.cachedMinIndex >= 0 && chartView.cachedMinY >= 0 && chartView.cachedMax - chartView.cachedMin >= 1
                        width: 8
                        height: 8
                        radius: 4
                        color: "#ffdd44"
                        x: chartView.cachedMinIndex * chartView.sampleStepPx - width / 2
                        y: chartView.cachedMinY - height / 2
                    }

                    Rectangle {
                        id: minBubble
                        visible: !chartView.idleMode && chartView.cachedMinIndex >= 0 && chartView.cachedMinY >= 0 && chartView.cachedMax - chartView.cachedMin >= 1
                        radius: 3
                        color: Qt.rgba(1, 1, 1, 0.08)
                        width: minText.implicitWidth + 6
                        height: minText.implicitHeight + 4
                        property real dotX: chartView.cachedMinIndex * chartView.sampleStepPx
                        x: (dotX + 8 + width > chartView.chartW - 10) ? Math.max(0, dotX - 8 - width) : dotX + 8
                        y: Math.max(2, Math.min(chartView.height - height - 2, chartView.cachedMinY - 10 - height / 2))
                        border.width: 1
                        border.color: Qt.rgba(1, 1, 1, 0.2)

                        Text {
                            id: minText
                            anchors.centerIn: parent
                            color: "#ffdd44"
                            font.pixelSize: root.baseFontSize * 1.2
                            font.bold: true
                            text: chartView.cachedMin >= 0 ? chartView.cachedMin.toFixed(1) + " ms" : ""
                        }
                    }

                    Rectangle {
                        parent: blurScene
                        visible: chartView.cachedCloudflareY >= 0 && chartView.cachedCloudflareX >= 0
                        width: 10
                        height: 10
                        radius: 5
                        color: root.cloudflareColor
                        x: chartView.cachedCloudflareX - width / 2
                        y: chartView.cachedCloudflareY - height / 2
                    }

                    Text {
                        parent: blurScene
                        visible: chartView.cachedCloudflareY >= 0 && chartView.cachedCloudflareX >= 0
                        text: Math.round(chartView.cachedCloudflareLabelValue) + "ms"
                        color: root.cloudflareColor
                        font.pixelSize: chartView.publicRealtimeLabelFontSize
                        x: chartView.cachedCloudflareX + 8
                        y: chartView.cachedCloudflareLabelY - height / 2
                    }

                    Rectangle {
                        parent: blurScene
                        visible: chartView.cachedGoogleY >= 0 && chartView.cachedGoogleX >= 0
                        width: 10
                        height: 10
                        radius: 5
                        color: root.googleColor
                        x: chartView.cachedGoogleX - width / 2
                        y: chartView.cachedGoogleY - height / 2
                    }

                    Text {
                        parent: blurScene
                        visible: chartView.cachedGoogleY >= 0 && chartView.cachedGoogleX >= 0
                        text: Math.round(chartView.cachedGoogleLabelValue) + "ms"
                        color: root.googleColor
                        font.pixelSize: chartView.publicRealtimeLabelFontSize
                        x: chartView.cachedGoogleX + 8
                        y: chartView.cachedGoogleLabelY - height / 2
                    }

                    Rectangle {
                        parent: blurScene
                        visible: chartView.cachedGatewayY >= 0 && chartView.cachedGatewayX >= 0
                        width: 10
                        height: 10
                        radius: 5
                        color: root.gatewayColor
                        x: chartView.cachedGatewayX - width / 2
                        y: chartView.cachedGatewayY - height / 2
                    }

                    Text {
                        parent: blurScene
                        visible: chartView.cachedGatewayY >= 0 && chartView.cachedGatewayX >= 0
                        text: chartView.cachedGatewayLabelValue.toFixed(1) + "ms"
                        color: root.gatewayColor
                        font.pixelSize: chartView.gatewayRealtimeLabelFontSize
                        x: chartView.cachedGatewayX + 8
                        y: chartView.cachedGatewayLabelY - height / 2
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 4

                Text {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.ceil(font.pixelSize * 1.05)
                    horizontalAlignment: Text.AlignLeft
                    verticalAlignment: Text.AlignVCenter
                    text: "Last Internet Ping Received: " + root.lastPingReceivedText
                    color: Qt.rgba(1, 1, 1, 0.45)
                    font.pixelSize: root.baseFontSize * 0.75
                    elide: Text.ElideRight
                    opacity: 1
                }

                RowLayout {
                    spacing: 2

                    Repeater {
                        model: root.windowOptions

                        Rectangle {
                            required property var modelData
                            readonly property bool active: root.windowSecs === modelData.secs
                            Layout.preferredWidth: rangeText.implicitWidth + 8
                            Layout.preferredHeight: rangeText.implicitHeight + 4
                            radius: 3
                            color: active ? Qt.rgba(1, 1, 1, 0.20) : Qt.rgba(1, 1, 1, 0.08)
                            border.width: 1
                            border.color: active ? Qt.rgba(1, 1, 1, 0.45) : Qt.rgba(1, 1, 1, 0.18)

                            Text {
                                id: rangeText
                                anchors.centerIn: parent
                                text: modelData.label
                                color: active ? "#ffd54a" : Qt.rgba(1, 1, 1, 0.75)
                                font.pixelSize: root.baseFontSize * 0.64
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.setWindowSeconds(modelData.secs)
                            }
                        }
                    }
                }
            }
        }
    }

    Component.onDestruction: {
        shuttingDown = true
        try { if (pingTimer) pingTimer.stop() } catch (e) {}
        try { if (gatewayRefreshTimer) gatewayRefreshTimer.stop() } catch (e) {}
        // Best-effort cleanup of any in-flight ping forks. With -W 1 each ping
        // self-terminates inside ~1.2s anyway, so this is belt-and-suspenders.
        try {
            if (executableSource) {
                executableSource.disconnectSource(cloudflareCommand)
                executableSource.disconnectSource(googleCommand)
                executableSource.disconnectSource(gatewayLookupCommand)
                if (gatewayCommand.length > 0) {
                    executableSource.disconnectSource(gatewayCommand)
                }
                executableSource.disconnectSource(egressCommand)
                executableSource.disconnectSource(exitNodeStatusCommand)
                executableSource.disconnectSource(exitNodeOnCommand)
                executableSource.disconnectSource(exitNodeOffCommand)
            }
        } catch (e) {}
    }
}
