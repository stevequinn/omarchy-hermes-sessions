import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Hermes Sessions bar widget — v2 config variant (second plugin, gear).
// Adds Local vs SSH-remote mode (key-based, user@host). Original logic preserved.
Panel {
  id: root
  moduleName: "kelso.hermes-sessions"
  ipcTarget: "kelso.hermes-sessions"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string logTag: "hermes-sessions"

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // ------------------------------------------------------------- data

  property var snapshot: null
  property bool loading: false

  readonly property var sessions: snapshot ? (snapshot.sessions || []) : []
  readonly property var active: snapshot ? snapshot.active : null

  property bool cursorActive: false
  property bool newSessionFocused: false
  property int focusedIndex: 0

  property int refreshIntervalSec: Math.max(10, Number(setting("refreshIntervalSec", 30)))

  readonly property int maxSnapshotBytes: 16384

  readonly property var profiles: snapshot ? (snapshot.profiles || ["default"]) : ["default"]
  property string selectedProfileOverride: ""
  readonly property string selectedProfile: {
    if (selectedProfileOverride && profiles.indexOf(selectedProfileOverride) !== -1) return selectedProfileOverride
    var p = snapshot ? snapshot.selectedProfile : null
    if (p && profiles.indexOf(p) !== -1) return p
    var saved = setting("selectedProfile", "")
    if (saved && profiles.indexOf(saved) !== -1) return saved
    return profiles[0] || "default"
  }
  readonly property var filteredSessions: sessions.filter(function(s){ var prof = s.profile || "default"; return prof === selectedProfile })
  readonly property var visibleSessions: filteredSessions.slice(0, 8)

  // --- v2 config ---
  property string remoteHost: String(setting("remoteHost", "") || "")
  property string remoteMode: String(setting("remoteMode", "local") || "local") // local | ssh
  property bool useTui: setting("useTui", true) !== false
  property bool showConfig: false
  property string pendingHost: ""
  property string pendingMode: "local"
  property bool pendingUseTui: true
  property string testStatus: "" // "", "testing", "ok", "failed"
  property string testMessage: ""

  function effectiveRemoteHost() {
    if (root.remoteMode === "ssh" && String(root.remoteHost).trim() !== "") return String(root.remoteHost).trim()
    return ""
  }

  function persistRemoteConfig(host, mode, useTuiVal) {
    var h = String(host || "").trim()
    var m = (mode === "ssh" ? "ssh" : "local")
    var t = (useTuiVal !== undefined ? !!useTuiVal : root.useTui)
    // Update local props immediately so UI reflects
    root.remoteHost = h
    root.remoteMode = m
    root.useTui = t
    // Persist via shell's updateEntryInline (correct API — setting(k,v) is getter only)
    if (bar && bar.shell && bar.shell.updateEntryInline) {
      var s = {}
      // copy existing settings shallow
      if (root.settings) for (var k in root.settings) s[k] = root.settings[k]
      s["remoteHost"] = h
      s["remoteMode"] = m
      s["useTui"] = t
      s["id"] = root.moduleName
      root.settings = s
      bar.shell.updateEntryInline(root.moduleName, s)
    } else {
      // fallback (won't persist correctly but keeps runtime)
      setting("remoteHost", h)
      setting("remoteMode", m)
      setting("useTui", t)
    }
  }

  function openConfig() {
    root.pendingHost = String(root.remoteHost)
    root.pendingMode = String(root.remoteMode)
    root.pendingUseTui = root.useTui
    root.testStatus = ""
    root.testMessage = ""
    root.showConfig = true
    root.cursorActive = false
    root.newSessionFocused = false
    if (listFlick) listFlick.contentY = 0
    Qt.callLater(function(){ if (hostField) hostField.forceActiveFocus() })
  }
  function closeConfig(save) {
    if (save) {
      root.persistRemoteConfig(root.pendingHost, root.pendingMode, root.pendingUseTui)
      // refresh after save with new host
      root.refreshWithProfile(root.selectedProfile)
    } else {
      root.testStatus = ""
      root.testMessage = ""
    }
    root.showConfig = false
    if (listFlick) listFlick.contentY = 0
    Qt.callLater(function(){ keyCatcher.forceActiveFocus() })
  }
  function testConnection() {
    if (testConnectionProcess.running) return
    var host = String(root.pendingHost).trim()
    if (root.pendingMode === "local" || host === "") {
      root.testStatus = "ok"
      root.testMessage = "Local mode — no SSH needed."
      return
    }
    root.testStatus = "testing"
    root.testMessage = "Testing " + host + "…"
    // Use snapshot's probe logic via ssh BatchMode — we test via simple ssh exit
    testConnectionProcess.command = ["bash", "-c", "ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \"" + host.replace(/\"/g, '\\"') + "\" \"exit\" 2>&1; echo EXIT:$?"]
    testConnectionProcess.running = true
  }

  function refresh() {
    if (snapshotProcess.running) return
    loading = true
    var host = effectiveRemoteHost()
    if (host !== "") {
      // inject env so snapshot.sh picks REMOTE_HOST without writing remote.conf
      snapshotProcess.command = ["env", "HERMES_REMOTE_HOST=" + host, scriptPath("snapshot.sh")]
    } else {
      // force local (empty host) — snapshot.sh treats empty as local fallback
      snapshotProcess.command = ["env", "HERMES_REMOTE_HOST=", scriptPath("snapshot.sh")]
    }
    snapshotProcess.running = true
  }

  function scriptPath(name) {
    return Qt.resolvedUrl("scripts/" + name).toString().replace(/^file:\/\//, "")
  }

  Process {
    id: snapshotProcess
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loading = false
        if (String(text).length > root.maxSnapshotBytes) {
          console.warn(root.logTag, "snapshot too large, discarded:", String(text).length, "bytes")
          return
        }
        try {
          root.snapshot = JSON.parse(String(text))
        } catch (e) {
          console.warn(root.logTag, "bad snapshot", e)
        }
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text).trim() !== "") console.warn(root.logTag, String(text).trim())
    }
  }

  // Test connection process (async, non-blocking bar)
  Process {
    id: testConnectionProcess
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = String(text)
        var m = out.match(/EXIT:(\d+)/)
        var code = m ? parseInt(m[1], 10) : 1
        if (code === 0) {
          root.testStatus = "ok"
          root.testMessage = "OK — SSH reachable (key ok)."
        } else {
          root.testStatus = "failed"
          // strip EXIT line
          var cleaned = out.replace(/EXIT:\d+\s*$/, "").trim().split("\n").slice(-2).join(" ").trim()
          if (!cleaned) cleaned = "Exit " + code
          root.testMessage = "Failed — " + cleaned + " — check key: ssh-copy-id " + String(root.pendingHost).trim()
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text).trim() !== "" && root.testStatus === "testing") {
        // stdout handler will finalize; keep for debug
        console.warn(root.logTag, "test ssh stderr:", String(text).trim())
      }
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }
  property double nowMs: Date.now()

  onOpenedChanged: if (opened) {
    root.cursorActive = false
    root.focusedIndex = 0
    if (root.showConfig) {
      Qt.callLater(function() { if (hostField) hostField.forceActiveFocus() })
    } else {
      root.refreshWithProfile(root.selectedProfile)
      if (listFlick) listFlick.contentY = 0
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  function persistProfile(profile) {
    if (!profile) return
    root.selectedProfileOverride = String(profile)
    if (bar && bar.shell && bar.shell.updateEntryInline) {
      var s = {}
      if (root.settings) for (var k in root.settings) s[k] = root.settings[k]
      s["selectedProfile"] = String(profile)
      s["id"] = root.moduleName
      root.settings = s
      bar.shell.updateEntryInline(root.moduleName, s)
    } else {
      setting("selectedProfile", String(profile))
    }
  }

  function selectProfile(profile) {
    if (!profile || profile === root.selectedProfile) return
    root.persistProfile(profile)
    root.cursorActive = false
    root.newSessionFocused = false
    root.focusedIndex = 0
    if (listFlick) listFlick.contentY = 0
    root.refreshWithProfile(profile)
  }

  function refreshWithProfile(profile) {
    if (snapshotProcess.running) return
    loading = true
    var host = effectiveRemoteHost()
    var cmd = []
    if (host !== "") cmd = ["env", "HERMES_REMOTE_HOST=" + host, scriptPath("snapshot.sh")]
    else cmd = ["env", "HERMES_REMOTE_HOST=", scriptPath("snapshot.sh")]
    if (profile) cmd.push(String(profile))
    snapshotProcess.command = cmd
    snapshotProcess.running = true
  }

  function openSession(sessionId, profile) {
    if (!sessionId) return
    var prof = profile || root.selectedProfile
    var host = effectiveRemoteHost()
    var useTuiStr = root.useTui ? "1" : "0"
    console.warn(root.logTag, "openSession requested:", sessionId, "profile:", prof, "host:", host || "(local)", "useTui:", useTuiStr)
    var appId = "hermes-tui-" + String(sessionId)
    var args = [scriptPath("hermes-tui-session"), String(sessionId)]
    if (prof) args.push(String(prof))
    else args.push("")
    args.push(useTuiStr)
    var command
    if (host !== "") {
      command = ["env", "HERMES_REMOTE_HOST=" + host, "HERMES_USE_TUI=" + useTuiStr, "omarchy-launch-or-focus-tui", "--app-id=" + appId].concat(args)
    } else {
      command = ["env", "HERMES_REMOTE_HOST=", "HERMES_USE_TUI=" + useTuiStr, "omarchy-launch-or-focus-tui", "--app-id=" + appId].concat(args)
    }
    Quickshell.execDetached(command)
    root.close()
  }

  function launchNewSession() {
    var prof = root.selectedProfile
    var host = effectiveRemoteHost()
    var useTuiStr = root.useTui ? "1" : "0"
    console.warn(root.logTag, "launchNewSession requested profile:", prof, "host:", host || "(local)", "useTui:", useTuiStr)
    var appId = "hermes-tui-new-" + Date.now()
    var args = [scriptPath("hermes-tui-session"), "__new__"]
    if (prof) args.push(String(prof))
    else args.push("")
    args.push(useTuiStr)
    var command
    if (host !== "") {
      command = ["env", "HERMES_REMOTE_HOST=" + host, "HERMES_USE_TUI=" + useTuiStr, "omarchy-launch-or-focus-tui", "--app-id=" + appId].concat(args)
    } else {
      command = ["env", "HERMES_REMOTE_HOST=", "HERMES_USE_TUI=" + useTuiStr, "omarchy-launch-or-focus-tui", "--app-id=" + appId].concat(args)
    }
    Quickshell.execDetached(command)
    root.close()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
  }

  // ------------------------------------------------------------ helpers

  function statusLine() {
    if (!root.snapshot) return "Checking…"
    if (!active) return "Idle — no recent activity"
    if (active.live) return "Working"
    return "Last seen " + relativeTime(active.lastActiveTs)
  }

  function relativeTime(ts) {
    var nowSec = nowMs / 1000
    var d = Math.max(0, nowSec - Number(ts || 0))
    if (d < 90) return "just now"
    if (d < 3600) return Math.floor(d / 60) + "m ago"
    if (d < 86400) return Math.floor(d / 3600) + "h ago"
    return Math.floor(d / 86400) + "d ago"
  }

  function workspaceShort(s) {
    var p = String(s.cwd || "").replace(/^\/home\/[^\/]+/, "~")
    var parts = p.split("/").filter(function(x) { return x !== "" })
    return parts.length > 0 ? parts[parts.length - 1] : p
  }

  function sessionSubtitle(s) {
    var parts = []
    parts.push(workspaceShort(s))
    if (String(s.model || "") !== "") parts.push(s.model)
    parts.push(s.messages + " msg" + (s.messages === 1 ? "" : "s"))
    return parts.join(" · ")
  }

  visible: sessions.length > 0 || profiles.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰚩"
    active: !!root.active && root.active.live
    activeColor: root.accent
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.showConfig ? hostField : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.showConfig

      onMoveRequested: function(dx, dy) {
        if (root.showConfig) return
        if (dx !== 0) {
          if (root.profiles.length <= 1) return
          var idx = root.profiles.indexOf(root.selectedProfile)
          if (idx === -1) idx = 0
          var step = dx > 0 ? 1 : -1
          var newIdx = (idx + step + root.profiles.length) % root.profiles.length
          root.selectProfile(root.profiles[newIdx])
          return
        }
        if (dy === 0 || root.visibleSessions.length === 0) return
        var count = root.visibleSessions.length
        if (dy < 0) {
          if (!root.cursorActive) {
            root.cursorActive = true
            root.newSessionFocused = false
            root.focusedIndex = count - 1
          } else if (root.focusedIndex > 0) {
            root.focusedIndex--
          } else if (root.newSessionFocused) {
            root.cursorActive = false
          } else {
            root.newSessionFocused = true
          }
        } else {
          if (root.newSessionFocused) {
            root.newSessionFocused = false
            root.cursorActive = true
            root.focusedIndex = 0
          } else if (!root.cursorActive) {
            root.cursorActive = true
            root.newSessionFocused = false
            root.focusedIndex = 0
          } else if (root.focusedIndex < count - 1) {
            root.focusedIndex++
          }
        }
        var rowTop = (root.focusedIndex + 1) * Style.space(52)
        var rowBottom = rowTop + Style.space(52)
        if (rowTop < listFlick.contentY)
          listFlick.contentY = Math.max(0, rowTop - Style.space(8))
        else if (rowBottom > listFlick.contentY + listFlick.height)
          listFlick.contentY = Math.min(listFlick.contentHeight - listFlick.height,
                                        rowBottom - listFlick.height + Style.space(8))
      }
      onCloseRequested: {
        if (root.showConfig) root.closeConfig(false)
        else root.close()
      }
      onActivateRequested: {
        if (root.showConfig) return
        if (root.newSessionFocused) launchNewSession()
        else if (cursorActive && focusedIndex < visibleSessions.length)
          openSession(visibleSessions[focusedIndex].id, visibleSessions[focusedIndex].profile)
        else
          launchNewSession()
      }

      Flickable {
        id: listFlick
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
          x: Style.space(6)
          width: listFlick.width - Style.space(12)
          spacing: Style.space(14)

          // ===== MAIN VIEW (hidden when config open) =====
          Column {
            id: mainView
            visible: !root.showConfig
            width: parent.width
            spacing: Style.space(14)

            // Hero + gear
            Row {
              width: parent.width
              spacing: Style.space(8)

              PanelHero {
                width: parent.width - gearBtn.width - Style.space(8)
                title: "Hermes Agent"
                meta: root.statusLine()
                foreground: root.foreground
                fontFamily: root.fontFamily

                iconComponent: Component {
                  Item {
                    width: Style.font.display
                    height: Style.font.display
                    Rectangle {
                      id: pulseDot
                      anchors.centerIn: parent
                      width: 12; height: 12; radius: 6
                      color: root.active && root.active.live ? root.accent : root.dim
                      opacity: root.active && root.active.live ? 1.0 : 0.55
                      SequentialAnimation on scale {
                        running: !!root.active && root.active.live && root.opened && !root.showConfig
                        loops: Animation.Infinite
                        NumberAnimation { to: 1.35; duration: 900; easing.type: Easing.InOutQuad }
                        NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutQuad }
                      }
                      SequentialAnimation on opacity {
                        running: !!root.active && root.active.live && root.opened && !root.showConfig
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.45; duration: 900; easing.type: Easing.InOutQuad }
                        NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutQuad }
                      }
                    }
                  }
                }
              }

              // Gear button
              Rectangle {
                id: gearBtn
                width: 36; height: 36; radius: 18
                color: gearMouse.containsMouse ? root.alpha(root.foreground, 0.08) : "transparent"
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  anchors.centerIn: parent
                  text: "󰒓"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: 18
                }
                MouseArea {
                  id: gearMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openConfig()
                }
              }
            }

            Text {
              visible: !!root.active
              width: parent.width
              text: root.active ? root.active.title : ""
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            BorderSurface {
              width: parent.width
              implicitHeight: newSessionRow.implicitHeight + Style.space(18)
              color: newSessionMouse.containsMouse || root.newSessionFocused
                ? root.alpha(root.accent, 0.16)
                : root.alpha(root.accent, 0.08)
              borderSpec: Border.flat(root.alpha(root.accent, root.newSessionFocused ? 0.9 : 0.45), 1)
              radius: Style.cornerRadius
              Behavior on color { ColorAnimation { duration: 60 } }
              MouseArea {
                id: newSessionMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.launchNewSession()
              }
              Row {
                id: newSessionRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(8)
                Text {
                  text: "󰐕"
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  width: parent.width - 34
                  text: root.loading && root.selectedProfile
                    ? "Loading " + root.selectedProfile + "…"
                    : "New session - " + (root.selectedProfile || "")
                  elide: Text.ElideRight
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  width: 30
                  text: "↵"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }

            Rectangle {
              visible: root.profiles.length > 1
              width: parent.width
              height: tabsRow.implicitHeight + Style.space(12)
              radius: Style.cornerRadius
              color: root.alpha(root.foreground, 0.05)
              Row {
                id: tabsRow
                anchors.centerIn: parent
                spacing: Style.space(4)
                Repeater {
                  model: root.profiles
                  delegate: Rectangle {
                    required property var modelData
                    property bool isSelected: modelData === root.selectedProfile
                    width: tabLabel.implicitWidth + Style.space(20)
                    height: tabLabel.implicitHeight + Style.space(10)
                    radius: height / 2
                    color: isSelected ? root.accent : "transparent"
                    Behavior on color { ColorAnimation { duration: 80 } }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.selectProfile(modelData)
                    }
                    Text {
                      id: tabLabel
                      anchors.centerIn: parent
                      text: modelData
                      textFormat: Text.PlainText
                      color: isSelected ? Color.background : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: isSelected
                    }
                  }
                }
              }
            }

            PanelSectionHeader {
              width: parent.width
              text: root.visibleSessions.length > 0
                ? "RECENT SESSIONS · " + root.selectedProfile.toUpperCase() + " · ↵ OPEN · ↑↓ SESSÃO · ←→ PERFIL"
                : "RECENT SESSIONS · " + root.selectedProfile.toUpperCase() + " · ←→ PERFIL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.visibleSessions
              delegate: CursorSurface {
                id: row
                required property var modelData
                required property int index
                hasCursor: root.cursorActive && index === root.focusedIndex
                current: modelData.live
                bordered: false
                foreground: root.foreground
                accent: root.accent
                width: parent.width
                implicitHeight: sessionColumn.implicitHeight + Style.space(20)
                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.LeftButton
                  cursorShape: Qt.PointingHandCursor
                  onContainsMouseChanged: if (containsMouse) {
                    root.cursorActive = true
                    root.focusedIndex = index
                  }
                  onClicked: root.openSession(modelData.id, modelData.profile)
                }
                Column {
                  id: sessionColumn
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(12)
                  anchors.rightMargin: Style.space(12)
                  spacing: Style.space(3)
                  Row {
                    width: parent.width
                    spacing: Style.space(6)
                    Rectangle {
                      visible: modelData.live
                      width: 7; height: 7; radius: 3.5
                      color: root.accent
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                      width: parent.width - (modelData.live ? 13 : 0) - ageLabel.width - latestPill.width - Style.space(12)
                      text: modelData.title
                      textFormat: Text.PlainText
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Rectangle {
                      id: latestPill
                      visible: index === 0
                      radius: height / 2
                      width: latestText.implicitWidth + Style.space(10)
                      height: latestText.implicitHeight + Style.space(4)
                      color: root.alpha(root.accent, 0.18)
                      anchors.verticalCenter: parent.verticalCenter
                      Text {
                        id: latestText
                        anchors.centerIn: parent
                        text: "LATEST"
                        color: root.accent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption - 1 > 8 ? Style.font.caption - 1 : 8
                        font.letterSpacing: 0.5
                      }
                    }
                    Text {
                      id: ageLabel
                      text: root.relativeTime(modelData.lastActiveTs)
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                  Row {
                    width: parent.width
                    spacing: Style.space(6)
                    Text {
                      width: parent.width
                      text: root.sessionSubtitle(modelData)
                      textFormat: Text.PlainText
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }
                }
                PanelToolTip {
                  visible: rowMouse.containsMouse
                  text: modelData.cwd
                  fontFamily: root.fontFamily
                }
              }
            }

            Text {
              visible: root.visibleSessions.length === 0 && !root.loading
              width: parent.width
              topPadding: Style.space(24)
              text: root.snapshot
                ? "No sessions yet.\nStart one with the button above."
                : "Checking for sessions…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            Item { width: parent.width; height: Style.space(2) }
          }

          // ===== CONFIG VIEW =====
          Column {
            id: configView
            visible: root.showConfig
            width: parent.width
            spacing: Style.space(12)

            // Back header
            Row {
              width: parent.width
              spacing: Style.space(8)
              Rectangle {
                width: 28; height: 28; radius: 14
                color: backMouse.containsMouse ? root.alpha(root.foreground, 0.08) : "transparent"
                Text { anchors.centerIn: parent; text: "‹"; color: root.foreground; font.pixelSize: 18; font.bold: true }
                MouseArea { id: backMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.closeConfig(false) }
              }
              Text {
                text: "Configuração"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Text {
              width: parent.width
              text: "Escolha como conectar ao Hermes. Modo SSH requer chave já configurada."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // Mode segmented control
            Rectangle {
              width: parent.width
              height: modeRow.implicitHeight + Style.space(10)
              radius: Style.cornerRadius
              color: root.alpha(root.foreground, 0.05)
              Row {
                id: modeRow
                anchors.centerIn: parent
                spacing: Style.space(4)
                Repeater {
                  model: [{key:"local", label:"Local"}, {key:"ssh", label:"SSH remoto"}]
                  delegate: Rectangle {
                    required property var modelData
                    property bool isSel: modelData.key === root.pendingMode
                    width: modeLabel.implicitWidth + Style.space(24)
                    height: modeLabel.implicitHeight + Style.space(10)
                    radius: height/2
                    color: isSel ? root.accent : "transparent"
                    Behavior on color { ColorAnimation { duration: 80 } }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.pendingMode = modelData.key }
                    Text {
                      id: modeLabel
                      anchors.centerIn: parent
                      text: modelData.label
                      color: isSel ? Color.background : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: isSel
                    }
                  }
                }
              }
            }

            // Interface toggle (TUI vs clássico)
            Column {
              width: parent.width
              spacing: Style.space(6)
              Text {
                text: "Interface"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              Rectangle {
                width: parent.width
                height: tuiRow.implicitHeight + Style.space(10)
                radius: Style.cornerRadius
                color: root.alpha(root.foreground, 0.05)
                Row {
                  id: tuiRow
                  anchors.centerIn: parent
                  spacing: Style.space(4)
                  Repeater {
                    model: [{key:true, label:"TUI"}, {key:false, label:"Clássico"}]
                    delegate: Rectangle {
                      required property var modelData
                      property bool isSel: modelData.key === root.pendingUseTui
                      width: tuiLabel.implicitWidth + Style.space(24)
                      height: tuiLabel.implicitHeight + Style.space(10)
                      radius: height/2
                      color: isSel ? root.accent : "transparent"
                      Behavior on color { ColorAnimation { duration: 80 } }
                      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.pendingUseTui = modelData.key }
                      Text {
                        id: tuiLabel
                        anchors.centerIn: parent
                        text: modelData.label
                        color: isSel ? Color.background : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: isSel
                      }
                    }
                  }
                }
              }
              Text {
                width: parent.width
                text: root.pendingUseTui ? "Abre sessões em TUI (--tui)." : "Abre sessões sem --tui (clássico)."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption - 1 > 9 ? Style.font.caption - 1 : 9
                wrapMode: Text.WordWrap
              }
            }

            // Host field (visible even in local for preview, but disabled hint)
            Column {
              width: parent.width
              spacing: Style.space(6)
              Text {
                text: "SSH host (user@host)"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              TextField {
                id: hostField
                width: parent.width
                placeholderText: root.pendingMode === "ssh" ? "ex: raspberry@berry ou user@192.168.1.10" : "ignorado em modo Local"
                text: root.pendingHost
                enabled: root.pendingMode === "ssh"
                opacity: enabled ? 1.0 : 0.5
                foreground: root.foreground
                accent: root.accent
                onTextChanged: root.pendingHost = text
                onAccepted: root.testConnection()
                Keys.onEscapePressed: root.closeConfig(false)
              }
              Text {
                width: parent.width
                text: "Requer chave SSH configurada. No terminal: ssh-keygen -t ed25519 && ssh-copy-id " + (String(root.pendingHost).trim() !== "" ? String(root.pendingHost).trim() : "user@host")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption - 1 > 9 ? Style.font.caption - 1 : 9
                wrapMode: Text.WordWrap
              }
            }

            // Test connection
            BorderSurface {
              width: parent.width
              implicitHeight: testRow.implicitHeight + Style.space(12)
              color: testMouse.containsMouse ? root.alpha(root.accent, 0.12) : root.alpha(root.foreground, 0.06)
              borderSpec: Border.flat(root.alpha(root.accent, 0.35), 1)
              radius: Style.cornerRadius
              Row {
                id: testRow
                anchors.centerIn: parent
                spacing: Style.space(8)
                Text { text: testConnectionProcess.running ? "◐" : "󰢿"; color: root.accent; font.family: root.fontFamily; font.pixelSize: Style.font.body; anchors.verticalCenter: parent.verticalCenter }
                Text {
                  text: testConnectionProcess.running ? "Testando…" : "Testar conexão"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
              MouseArea {
                id: testMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                enabled: !testConnectionProcess.running
                onClicked: root.testConnection()
              }
            }

            Text {
              visible: root.testStatus !== ""
              width: parent.width
              text: root.testMessage
              color: root.testStatus === "ok" ? root.accent : (root.testStatus === "failed" ? "#e05d44" : root.dim)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // Current effective hint
            Text {
              width: parent.width
              text: "Atual: " + (root.remoteMode === "ssh" && String(root.remoteHost).trim() !== "" ? String(root.remoteHost).trim() + " (SSH)" : "Local (~/.hermes)")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              // Cancel
              BorderSurface {
                width: (parent.width - Style.space(8)) / 2
                implicitHeight: 36
                radius: Style.cornerRadius
                color: cancelMouse.containsMouse ? root.alpha(root.foreground, 0.08) : root.alpha(root.foreground, 0.04)
                borderSpec: Border.flat(root.alpha(root.foreground, 0.15), 1)
                Text { anchors.centerIn: parent; text: "Cancelar"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
                MouseArea { id: cancelMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.closeConfig(false) }
              }
              // Save
              Rectangle {
                width: (parent.width - Style.space(8)) / 2
                height: 36
                radius: Style.cornerRadius
                color: saveMouse.containsMouse ? Qt.darker(root.accent, 1.15) : root.accent
                Behavior on color { ColorAnimation { duration: 80 } }
                Text { anchors.centerIn: parent; text: "Salvar"; color: Color.background; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
                MouseArea { id: saveMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.closeConfig(true) }
              }
            }

            Item { width: parent.width; height: Style.space(4) }
          }

          Item { width: parent.width; height: Style.space(2) }
        }
      }
    }
  }
}
