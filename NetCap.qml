import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.grantedmefluffy.omarchy-netcap"
  ipcTarget: "netcap"
  manageIpc: false

  readonly property string backend: localPath("netcap.sh")
  readonly property string rootBackend: localPath("netcap-root.sh")
  readonly property real quotaGiB: Number(setting("monthlyQuotaGiB", 100))
  readonly property real downloadMbps: Number(setting("downloadMbps", 100))
  readonly property real uploadMbps: Number(setting("uploadMbps", 20))
  readonly property real throttledDownloadMbps: Number(setting("throttledDownloadMbps", 1))
  readonly property real throttledUploadMbps: Number(setting("throttledUploadMbps", 1))
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var usage: ({})
  property string actionStatus: ""
  property bool busy: false
  property bool quotaActionAttempted: false

  readonly property real quotaBytes: quotaGiB * 1073741824
  readonly property real usagePercent: quotaBytes > 0
    ? Math.min(100, (Number(usage.usedBytes || 0) / quotaBytes) * 100) : 0
  readonly property bool quotaReached: quotaBytes > 0 && Number(usage.usedBytes || 0) >= quotaBytes
  readonly property bool managed: usage.active === true
  readonly property string usageText: formatBytes(Number(usage.usedBytes || 0)) + " of " + quotaGiB + " GiB"

  function localPath(name) {
    return decodeURIComponent(String(Qt.resolvedUrl(name)).replace(/^file:\/\//, ""))
  }

  function formatBytes(bytes) {
    var gib = bytes / 1073741824
    return gib >= 1 ? gib.toFixed(2) + " GiB" : (bytes / 1048576).toFixed(1) + " MiB"
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function showStatus(message) {
    actionStatus = message
    clearStatus.restart()
  }

  function requestedRates(throttled) {
    var down = throttled ? throttledDownloadMbps : downloadMbps
    var up = throttled ? throttledUploadMbps : uploadMbps
    if (!isFinite(down) || !isFinite(up) || down < 0.008 || up < 0.008 ||
        down > 100000 || up > 100000) {
      showStatus("Invalid speed settings; limits were not changed")
      return false
    }
    return [Math.round(down * 1000), Math.round(up * 1000)]
  }

  function applyLimits(throttled, automatic) {
    if (busy) return
    if (!usage.interface) {
      showStatus("No active network interface")
      return
    }
    var rates = requestedRates(throttled)
    if (!rates) return
    busy = true
    rootProc.command = ["pkexec", rootBackend, "apply", usage.interface, String(rates[0]), String(rates[1])]
    rootProc.mode = automatic ? "automatic" : (throttled ? "throttled" : "normal")
    rootProc.running = true
  }

  function clearLimits() {
    if (busy) return
    if (!usage.interface) {
      showStatus("No active network interface")
      return
    }
    busy = true
    rootProc.command = ["pkexec", rootBackend, "clear", usage.interface]
    rootProc.mode = "clear"
    rootProc.running = true
  }

  function maybeThrottle() {
    if (!managed || !quotaReached || quotaActionAttempted || busy) return
    var rates = requestedRates(true)
    if (!rates) {
      quotaActionAttempted = true
      return
    }
    if (Number(usage.downKbit) === rates[0] && Number(usage.upKbit) === rates[1]) {
      quotaActionAttempted = true
      return
    }
    quotaActionAttempted = true
    applyLimits(true, true)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    refresh()
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  Component.onCompleted: refresh()

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function status(): string {
      return root.usageText + (root.managed ? " · limits active" : " · limits off")
    }
  }

  Timer {
    interval: 10000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: clearStatus
    interval: 8000
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: statusProc
    command: [root.backend]
    stderr: StdioCollector { id: statusError; waitForEnd: true }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.usage = JSON.parse(text)
          root.maybeThrottle()
        } catch (e) {
          root.actionStatus = "Could not read network usage: " + e
        }
      }
    }
    onRunningChanged: {
      if (!running && statusProc.exitCode !== 0 && statusError.text.trim() !== "")
        root.actionStatus = statusError.text.trim()
    }
  }

  Process {
    id: rootProc
    command: []
    property string mode: ""
    stderr: StdioCollector { id: rootError; waitForEnd: true }
    onRunningChanged: {
      if (running) return
      var mode = rootProc.mode
      root.busy = false
      rootProc.mode = ""
      if (rootProc.exitCode === 0) {
        if (mode === "clear") root.showStatus("Speed limits removed")
        else if (mode === "automatic") root.showStatus("Quota reached — reduced speeds applied")
        else root.showStatus("Speed limits applied")
        root.quotaActionAttempted = false
        root.refresh()
      } else {
        root.showStatus(rootError.text.trim() ||
          (rootProc.exitCode === 126 ? "Administrator authorization cancelled; network unchanged" : "Could not change speed limits"))
      }
    }
  }

  component InfoRow: Row {
    id: infoRow
    required property string label
    required property string value
    width: parent.width
    spacing: Style.space(8)

    Text {
      width: infoRow.width * 0.66
      text: infoRow.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Text {
      width: infoRow.width - infoRow.width * 0.66 - infoRow.spacing
      text: infoRow.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰓅"
    foreground: root.quotaReached ? root.urgent : root.barForeground
    tooltipText: root.usageText
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Network data"
            meta: root.usage.interface ? root.usage.interface : "No active connection"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰓅"
                color: root.quotaReached ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader { text: "MONTHLY USAGE"; foreground: root.foreground; fontFamily: root.fontFamily }
            InfoRow { label: root.usageText; value: Math.floor(root.usagePercent) + "%" }
            InfoRow { label: "Download"; value: root.formatBytes(Number(root.usage.rxBytes || 0)) }
            InfoRow { label: "Upload"; value: root.formatBytes(Number(root.usage.txBytes || 0)) }
          }

          Rectangle {
            width: parent.width
            height: Style.space(6)
            radius: height / 2
            color: Qt.darker(root.foreground, 1.7)

            Rectangle {
              width: parent.width * root.usagePercent / 100
              height: parent.height
              radius: parent.radius
              color: root.quotaReached ? root.urgent : root.foreground
            }
          }

          PanelSectionHeader { text: "SPEED LIMITS"; foreground: root.foreground; fontFamily: root.fontFamily }

          Text {
            width: parent.width
            text: root.quotaReached
              ? (root.managed ? "Monthly quota reached. Speeds are being throttled." : "Monthly quota reached. Apply limits to throttle the connection.")
              : "At " + root.quotaGiB + " GiB, speeds drop to " + root.throttledDownloadMbps + "/" + root.throttledUploadMbps + " Mbps (down/up)."
            color: root.quotaReached ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            text: root.managed
              ? "Current cap: " + (Number(root.usage.downKbit) / 1000) + " Mbps down · " + (Number(root.usage.upKbit) / 1000) + " Mbps up"
              : "Caps: " + root.downloadMbps + " Mbps down · " + root.uploadMbps + " Mbps up"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)

            Button {
              text: root.managed ? "Update caps" : "Apply caps"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.busy && !!root.usage.interface
              tooltipText: "Requests administrator approval through pkexec"
              onClicked: root.applyLimits(root.quotaReached, false)
            }

            Button {
              text: "Remove caps"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.busy && root.managed
              onClicked: root.clearLimits()
            }

            Button {
              text: "Refresh"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.busy
              onClicked: root.refresh()
            }
          }

          Text {
            width: parent.width
            visible: root.actionStatus !== ""
            text: root.actionStatus
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            text: "Usage is counted from the first sample and saved locally. Automatic throttling runs while the Omarchy shell is active. Linux traffic-control shaping needs pkexec; if authorization is cancelled, network settings stay unchanged."
            color: Qt.darker(root.foreground, 1.35)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
