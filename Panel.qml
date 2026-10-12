import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "djjeane.docker-monitor"
  ipcTarget: "djjeane.docker-monitor"
  property var dockerData: ({})
  property int dataVersion: 0
  property bool loading: false

  property string viewMode: "list"
  property string selectedContainer: ""
  property string logText: ""
  property bool logLoading: false
  property string actionInProgress: ""

  property var prevStates: ({})
  property bool initialLoad: true
  property var collapsedGroups: ({})

  readonly property string barIcon: "󰡨"
  readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(fg, 1.45)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : "JetBrainsMono Nerd Font"
  readonly property int pollInterval: {
    var v = settings ? settings.pollIntervalSec : undefined
    return (typeof v === "number" && v >= 5) ? v : 10
  }
  readonly property bool showStopped: {
    var v = settings ? settings.showStoppedContainers : undefined
    return v === undefined || v === null ? true : v === true
  }
  readonly property bool notifyEnabled: {
    var v = settings ? settings.notificationsEnabled : undefined
    return v === undefined || v === null ? true : v === true
  }
  readonly property int logLines: {
    var v = settings ? settings.logLines : undefined
    return (typeof v === "number" && v >= 25) ? v : 100
  }

  function refresh() {
    if (!monitorProc.running) {
      loading = true
      monitorProc.running = true
    }
  }

  function handleOutput(raw) {
    var parsed = Model.parseData(raw)
    if (!parsed.containers) { loading = false; return }

    if (!initialLoad && notifyEnabled) {
      var changes = Model.detectChanges(prevStates, parsed.containers)
      for (var i = 0; i < changes.length; i++)
        sendNotification(changes[i])
    }

    prevStates = Model.buildStateMap(parsed.containers)
    dockerData = parsed
    dataVersion++
    loading = false
    initialLoad = false
  }

  function sendNotification(change) {
    var urgency = "normal"
    var icon = "dialog-information"
    if (change.type === "stopped") { urgency = "critical"; icon = "dialog-error" }
    else if (change.type === "unhealthy") { urgency = "normal"; icon = "dialog-warning" }
    else if (change.type === "started") { urgency = "low"; icon = "dialog-information" }
    var title = "Docker"
    if (change.type === "stopped") title = "Container Down"
    else if (change.type === "unhealthy") title = "Container Unhealthy"
    else if (change.type === "started") title = "Container Started"
    notifyProc.command = ["notify-send", "-a", "Docker Monitor", "-u", urgency, "-i", icon, title, change.message]
    notifyProc.running = true
  }

  function triggerPress(button) {
    if (button === Qt.MiddleButton) { refresh(); return }
    if (opened) close()
    else { open(); refresh() }
  }

  function containerAction(name, action) {
    actionInProgress = name + ":" + action
    actionProc.command = ["docker", action, name]
    actionProc.running = true
  }

  function viewLogs(name) {
    selectedContainer = name
    logText = ""
    logLoading = true
    viewMode = "logs"
    logProc.command = ["bash", pathFromUrl(Qt.resolvedUrl("scripts/docker_logs.sh")), name, String(logLines)]
    logProc.running = true
  }

  function refreshLogs() {
    if (selectedContainer === "") return
    logLoading = true
    logProc.command = ["bash", pathFromUrl(Qt.resolvedUrl("scripts/docker_logs.sh")), selectedContainer, String(logLines)]
    logProc.running = true
  }

  function backToList() {
    viewMode = "list"
    selectedContainer = ""
    logText = ""
  }

  function pathFromUrl(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0)
      return decodeURIComponent(value.substring(7))
    return value
  }

  function isGroupCollapsed(project) {
    return collapsedGroups[project] === true
  }

  function toggleGroup(project) {
    var next = {}
    for (var k in collapsedGroups) next[k] = collapsedGroups[k]
    next[project] = !next[project]
    collapsedGroups = next
  }

  function filteredGroups() {
    var groups = dockerData.groups || []
    if (showStopped) return groups
    var result = []
    for (var i = 0; i < groups.length; i++) {
      var g = groups[i]
      var filtered = []
      for (var j = 0; j < g.containers.length; j++) {
        var s = g.containers[j].state
        if (s === "running" || s === "paused" || s === "restarting")
          filtered.push(g.containers[j])
      }
      if (filtered.length > 0) {
        result.push({
          project: g.project,
          running: g.running,
          total: g.total,
          containers: filtered
        })
      }
    }
    return result
  }

  onOpenedChanged: {
    if (opened) {
      pollTimer.running = true
      refresh()
    } else {
      viewMode = "list"
      selectedContainer = ""
      idleTimer.restart()
    }
  }

  Component.onCompleted: refresh()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: monitorProc
    command: ["python3", pathFromUrl(Qt.resolvedUrl("scripts/docker_monitor.py"))]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleOutput(text)
    }
  }

  Process {
    id: actionProc
    onExited: function(code, status) {
      root.actionInProgress = ""
      Qt.callLater(root.refresh)
    }
  }

  Process {
    id: logProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.logText = text
        root.logLoading = false
      }
    }
  }

  Process { id: notifyProc }

  Timer {
    id: pollTimer
    interval: root.pollInterval * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: idleTimer
    interval: 60000
    running: false
    repeat: false
    onTriggered: pollTimer.interval = 30000
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barIcon
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(27)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    tooltipText: {
      var s = root.dockerData.summary
      if (!s) return "Docker"
      var parts = [s.running + " running"]
      if (s.stopped > 0) parts.push(s.stopped + " stopped")
      if (s.paused > 0) parts.push(s.paused + " paused")
      return "Docker: " + parts.join(", ")
    }
    onPressed: function(b) { root.triggerPress(b) }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.viewMode === "logs" ? Style.space(600) : Style.space(420))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: {
        if (root.viewMode === "logs") root.backToList()
        else root.close()
      }
      onTextKey: function(t) {
        if (t === "r" || t === "R") {
          if (root.viewMode === "logs") root.refreshLogs()
          else root.refresh()
        }
        if ((t === "b" || t === "B") && root.viewMode === "logs")
          root.backToList()
      }

      ColumnLayout {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        // ── Header ──
        RowLayout {
          Layout.fillWidth: true
          spacing: 8

          Text {
            text: root.viewMode === "logs" ? "󰈙  " + root.selectedContainer : "󰡨  Docker"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            elide: Text.ElideRight
          }

          Text {
            visible: root.viewMode === "list" && root.dataVersion > 0 && root.dockerData.summary !== undefined
            text: {
              var s = root.dockerData.summary
              if (!s) return ""
              var parts = []
              if (s.running > 0) parts.push(s.running + " up")
              if (s.stopped > 0) parts.push(s.stopped + " down")
              if (s.paused > 0) parts.push(s.paused + " paused")
              return parts.join(" · ")
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            Layout.alignment: Qt.AlignVCenter
          }

          Button {
            visible: root.viewMode === "logs"
            text: "Back"
            foreground: root.fg
            tooltipText: "Back to container list"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.backToList()
          }

          Button {
            text: "Refresh"
            foreground: root.fg
            tooltipText: root.viewMode === "logs" ? "Reload logs" : "Refresh containers"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.viewMode === "logs" ? root.refreshLogs() : root.refresh()
          }
        }

        PanelSeparator {
          Layout.fillWidth: true
          foreground: root.fg
        }

        // ── List view ──
        Text {
          visible: root.viewMode === "list" && root.loading && root.dataVersion === 0
          Layout.fillWidth: true
          text: "Loading containers…"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
        }

        Flickable {
          id: containerList
          visible: root.viewMode === "list" && root.dataVersion > 0
          Layout.fillWidth: true
          implicitHeight: Math.min(groupColumn.implicitHeight, Style.space(550))
          contentHeight: groupColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          ColumnLayout {
            id: groupColumn
            width: containerList.width
            spacing: Style.space(4)

            Repeater {
              model: root.dataVersion >= 0 ? root.filteredGroups() : []

              delegate: ColumnLayout {
                required property var modelData
                required property int index
                Layout.fillWidth: true
                spacing: Style.space(3)

                // Group header
                MouseArea {
                  Layout.fillWidth: true
                  implicitHeight: groupHeader.implicitHeight
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleGroup(modelData.project)

                  RowLayout {
                    id: groupHeader
                    anchors.left: parent.left
                    anchors.right: parent.right
                    spacing: Style.space(6)

                    Text {
                      text: root.isGroupCollapsed(modelData.project) ? "▸" : "▾"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      Layout.alignment: Qt.AlignVCenter
                    }

                    Text {
                      text: modelData.project
                      color: root.fg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                      Layout.fillWidth: true
                      Layout.alignment: Qt.AlignVCenter
                    }

                    Text {
                      text: modelData.running + "/" + modelData.total
                      color: modelData.running === modelData.total ? "#22c55e" : (modelData.running === 0 ? "#6b7280" : "#eab308")
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      Layout.alignment: Qt.AlignVCenter
                    }
                  }
                }

                // Container cards (collapsible)
                ColumnLayout {
                  visible: !root.isGroupCollapsed(modelData.project)
                  Layout.fillWidth: true
                  Layout.leftMargin: Style.space(6)
                  spacing: Style.space(4)

                  Repeater {
                    model: modelData.containers

                    delegate: BorderSurface {
                      required property var modelData
                      required property int index
                      Layout.fillWidth: true
                      color: {
                        if (Model.isUnhealthy(modelData.status))
                          return Qt.rgba(1, 0.6, 0, 0.08)
                        return Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.055)
                      }
                      borderSpec: {
                        if (Model.isUnhealthy(modelData.status))
                          return Border.flat(Qt.rgba(1, 0.6, 0, 0.2), 1)
                        return Border.flat(Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05), 1)
                      }
                      radius: Style.cornerRadius
                      padding: Style.space(8)
                      implicitHeight: cardBody.implicitHeight + contentTopInset + contentBottomInset

                      ColumnLayout {
                        id: cardBody
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.topMargin: parent.contentTopInset
                        anchors.rightMargin: parent.contentRightInset
                        anchors.bottomMargin: parent.contentBottomInset
                        anchors.leftMargin: parent.contentLeftInset
                        spacing: Style.space(3)

                        RowLayout {
                          Layout.fillWidth: true
                          spacing: Style.space(6)

                          Text {
                            text: Model.stateGlyph(modelData.state)
                            color: Model.stateColor(modelData.state)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            Layout.alignment: Qt.AlignVCenter
                          }

                          Text {
                            text: modelData.name || "unknown"
                            color: root.fg
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            font.bold: true
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                          }

                          Text {
                            visible: modelData.state === "running" && (modelData.cpu || 0) > 0
                            text: modelData.cpu + "%"
                            color: Model.cpuColor(modelData.cpu || 0) || root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            Layout.alignment: Qt.AlignVCenter
                          }

                          Text {
                            visible: modelData.state === "running" && (modelData.memUsage || "") !== ""
                            text: {
                              var mu = modelData.memUsage || ""
                              var slash = mu.indexOf(" / ")
                              return slash > 0 ? mu.substring(0, slash) : mu
                            }
                            color: Model.memColor(modelData.memPct || 0) || root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            Layout.alignment: Qt.AlignVCenter
                          }
                        }

                        RowLayout {
                          Layout.fillWidth: true
                          Layout.leftMargin: Style.space(14)
                          spacing: Style.space(6)

                          Text {
                            text: Model.shortImage(modelData.image)
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                          }

                          Text {
                            text: modelData.status || ""
                            color: Model.isUnhealthy(modelData.status) ? "#eab308" : root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                          }

                          RowLayout {
                            spacing: Style.space(2)

                            Button {
                              visible: modelData.state !== "running" && modelData.state !== "paused"
                              text: "start"
                              foreground: "#22c55e"
                              fontFamily: root.fontFamily
                              fontSize: Style.font.caption
                              horizontalPadding: Style.space(6)
                              verticalPadding: Style.space(2)
                              enabled: root.actionInProgress === ""
                              onClicked: root.containerAction(modelData.name, "start")
                            }

                            Button {
                              visible: modelData.state === "running"
                              text: "stop"
                              foreground: "#ef4444"
                              fontFamily: root.fontFamily
                              fontSize: Style.font.caption
                              horizontalPadding: Style.space(6)
                              verticalPadding: Style.space(2)
                              enabled: root.actionInProgress === ""
                              onClicked: root.containerAction(modelData.name, "stop")
                            }

                            Button {
                              visible: modelData.state === "running"
                              text: "restart"
                              foreground: "#3b82f6"
                              fontFamily: root.fontFamily
                              fontSize: Style.font.caption
                              horizontalPadding: Style.space(6)
                              verticalPadding: Style.space(2)
                              enabled: root.actionInProgress === ""
                              onClicked: root.containerAction(modelData.name, "restart")
                            }

                            Button {
                              visible: modelData.state === "paused"
                              text: "unpause"
                              foreground: "#22c55e"
                              fontFamily: root.fontFamily
                              fontSize: Style.font.caption
                              horizontalPadding: Style.space(6)
                              verticalPadding: Style.space(2)
                              enabled: root.actionInProgress === ""
                              onClicked: root.containerAction(modelData.name, "unpause")
                            }

                            Button {
                              text: "logs"
                              foreground: root.fg
                              fontFamily: root.fontFamily
                              fontSize: Style.font.caption
                              horizontalPadding: Style.space(6)
                              verticalPadding: Style.space(2)
                              onClicked: root.viewLogs(modelData.name)
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }

        // ── Log view ──
        Text {
          visible: root.viewMode === "logs" && root.logLoading
          Layout.fillWidth: true
          text: "Loading logs…"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
        }

        Flickable {
          id: logView
          visible: root.viewMode === "logs" && !root.logLoading
          Layout.fillWidth: true
          implicitHeight: Math.min(logContent.implicitHeight, Style.space(500))
          contentHeight: logContent.implicitHeight
          contentWidth: logContent.implicitWidth
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          onContentHeightChanged: {
            if (contentHeight > height)
              contentY = contentHeight - height
          }

          Text {
            id: logContent
            text: root.logText || "No logs available"
            color: root.logText ? root.fg : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WrapAnywhere
            width: logView.width
          }
        }

        // ── Footer ──
        Text {
          Layout.fillWidth: true
          text: root.viewMode === "logs" ? "b back · r reload · esc closes" : "r refreshes · esc closes"
          color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.3)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }
}
