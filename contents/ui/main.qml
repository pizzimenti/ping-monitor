import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import QtCore
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // This plasmoid only has a full representation.
    preferredRepresentation: fullRepresentation

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
    readonly property string currentCommand: "ping-monitor-plasmoid-source"
    property int lastCloudflareSeq: -1
    property int lastGoogleSeq: -1
    property int lastGatewaySeq: -1
    property int daemonTimestamp: 0

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
            && visible
            && Plasmoid.status !== PlasmaCore.Types.HiddenStatus

    property string gatewayIp: ""
    property bool gatewayOnline: false
    property string lastPingReceivedText: "--:--:--"

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

    function parseStateSnapshot(rawText) {
        const next = {
            timestamp: 0,
            gateway_ip: "",
            cloudflare_ping: -1,
            cloudflare_seq: -1,
            google_ping: -1,
            google_seq: -1,
            gateway_ping: -1,
            gateway_seq: -1
        };
        for (const line of (rawText || "").split(/\r?\n/)) {
            if (!line || !line.includes("=")) {
                continue;
            }
            const idx = line.indexOf("=");
            const key = line.slice(0, idx);
            const value = line.slice(idx + 1);
            if (key === "timestamp") {
                next.timestamp = parseInt(value, 10) || 0;
            } else if (key === "gateway_ip") {
                next.gateway_ip = value;
            } else if (key === "cloudflare_ping") {
                next.cloudflare_ping = parseFloat(value);
            } else if (key === "cloudflare_seq") {
                next.cloudflare_seq = parseInt(value, 10) || 0;
            } else if (key === "google_ping") {
                next.google_ping = parseFloat(value);
            } else if (key === "google_seq") {
                next.google_seq = parseInt(value, 10) || 0;
            } else if (key === "gateway_ping") {
                next.gateway_ping = parseFloat(value);
            } else if (key === "gateway_seq") {
                next.gateway_seq = parseInt(value, 10) || 0;
            }
        }

        daemonTimestamp = next.timestamp;
        updateGatewayIp(next.gateway_ip);

        if (next.cloudflare_seq > lastCloudflareSeq) {
            lastCloudflareSeq = next.cloudflare_seq;
            applyPing("cloudflare", isNaN(next.cloudflare_ping) ? -1 : next.cloudflare_ping);
        }
        if (next.google_seq > lastGoogleSeq) {
            lastGoogleSeq = next.google_seq;
            applyPing("google", isNaN(next.google_ping) ? -1 : next.google_ping);
        }
        if (next.gateway_seq > lastGatewaySeq) {
            lastGatewaySeq = next.gateway_seq;
            applyPing("gateway", isNaN(next.gateway_ping) ? -1 : next.gateway_ping);
        }
    }

    function readStateFile() {
        if (!samplingActive) {
            return;
        }
        executableSource.disconnectSource(currentCommand);
        executableSource.connectSource(currentCommand);
    }

    Timer {
        id: statePollTimer
        interval: 1000
        running: root.samplingActive
        repeat: true
        triggeredOnStart: true
        onTriggered: root.readStateFile()
    }

    Plasma5Support.DataSource {
        id: executableSource
        engine: "executable"
        interval: 0
        onNewData: (sourceName, sourceData) => {
            if (sourceName !== root.currentCommand) {
                return;
            }
            root.parseStateSnapshot(sourceData.stdout || "");
            executableSource.disconnectSource(sourceName);
        }
    }

    fullRepresentation: Item {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 18
        Layout.preferredHeight: Kirigami.Units.gridUnit * 10
        Layout.minimumWidth: Kirigami.Units.gridUnit * 12
        Layout.minimumHeight: Kirigami.Units.gridUnit * 6

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
                        font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 0.75
                        opacity: 0.8
                    }
                }

                RowLayout {
                    spacing: 4
                    Rectangle { width: 12; height: 12; radius: 6; color: root.googleColor }
                    Text {
                        text: "8.8.8.8"
                        color: Kirigami.Theme.textColor
                        font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 0.75
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
                        color: Kirigami.Theme.textColor
                        font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 0.75
                        opacity: 0.8
                    }
                }

                Item { Layout.fillWidth: true }
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
                            font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 0.85
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
                    readonly property real publicRealtimeLabelFontSize: Kirigami.Theme.defaultFont.pixelSize * 1.3
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

                    Timer {
                        id: chartUpdateTimer
                        interval: 1000
                        repeat: true
                        running: chartView.visible && root.samplingActive
                        onTriggered: {
                            var now = Date.now()
                            var oldAxisTop = root.axisTopMs()

                            var maxDelta = root.maxPing - root.displayMaxPing
                            if (Math.abs(maxDelta) > 0.25) {
                                root.displayMaxPing += maxDelta * 0.2
                            } else {
                                root.displayMaxPing = root.maxPing
                            }
                            var rebuilt = false
                            if (chartView.ensureBuffers()) {
                                chartView.fillVisibleFromHistory(now)
                                chartView.scrollAccPoints = 0
                                rebuilt = true
                            }
                            chartView.pushHistorySample(now)
                            var pointsPerTick = (chartView.pointCount > 0) ? (chartView.pointCount / root.windowSecs) : 0
                            chartView.scrollAccPoints += pointsPerTick
                            var ds = Math.floor(chartView.scrollAccPoints)
                            if (ds > 0) {
                                chartView.scrollAccPoints -= ds
                                rebuilt = chartView.appendVisibleSamples(ds, now) || rebuilt
                            }

                            var axisChanged = Math.abs(root.axisTopMs() - oldAxisTop) > 0.1

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
                            root.maxPing = Math.max(100, Math.ceil(visibleMax / 25) * 25)
                            if (root.chartDirty || rebuilt || axisChanged) {
                                chartView.rebuildPathsAndExtrema()
                                chartView.updateLiveLabels()
                                root.chartDirty = false
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
                            font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 1.2
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
                            font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 1.2
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
                    font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 0.75
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
                                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 0.64
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
        try { if (statePollTimer) statePollTimer.stop() } catch (e) {}
    }
}
