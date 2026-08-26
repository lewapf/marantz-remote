import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar icon + popup, same shape as PiloTV's panel (see ~/projects/pilotv-omarchy):
// a Panel base for the bar button + KeyboardPanel popup, all protocol logic
// in the sibling Amp item, this file is presentation only.
Panel {
  id: root
  moduleName: "marantz-remote"
  ipcTarget: "marantz-remote"

  property var settings: ({})
  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  Amp {
    id: amp
  }

  readonly property bool isConnected: amp.phase === "connected"

  // Opening the popup while not connected quietly reconnects to the last
  // receiver (or starts a scan if none is known) instead of presenting a
  // dead setup form.
  onOpenedChanged: {
    if (root.opened) {
      amp.ensureConnected()
      root.cursorActive = false
      root.focusKey = ""
    }
  }

  function statusText() {
    switch (amp.phase) {
      case "connected":
        if (!amp.power) return "Standby"
        var vol = amp.muted ? "Muted" : (amp.volume >= 0 ? (amp.volume - 80 > 0 ? "+" : "") + (amp.volume - 80).toFixed(1) + "dB" : "")
        return vol || "Connected"
      case "connecting": return "Connecting · " + amp.ip
      case "error": return amp.errorMessage || "Error"
      default: return amp.lastIp ? "Not connected" : "No receiver set up yet"
    }
  }

  function submitIp() {
    var value = ipField.text.trim()
    if (value !== "") amp.connect(value)
  }

  function adjustSleep(delta) {
    var current = amp.sleepMinutes || 0
    amp.setSleep(Math.max(0, Math.min(120, current + delta)))
  }

  // ---------- Keyboard navigation ----------
  // Rows of focus keys in on-screen reading order. Only one of the two
  // branches is ever visible at once (setup vs. connected), and the tuner
  // preset row/discovered list rows come and go with state — recomputed
  // whenever anything that changes the visible layout changes.
  readonly property var focusRows: {
    var rows = []
    if (!root.isConnected) {
      if (amp.phase === "connecting") return rows
      rows.push(["connect"])
      rows.push(["scan"])
      for (var i = 0; i < amp.discovered.length; i++) rows.push(["disc-" + i])
      return rows
    }
    rows.push(["power", "voldown", "mute", "volup"])
    rows.push(["in-tv", "in-cd", "in-game", "in-net"])
    rows.push(["in-phono", "in-bt", "in-tuner"])
    if (amp.currentInput === "TUNER") rows.push(["freqdown", "frequp"])
    if (amp.currentInput === "TUNER") rows.push(["presetdown", "presetup"])
    rows.push(["sound-toggle"])
    if (root.soundExpanded) rows.push(["bassdown", "bassup", "trebledown", "trebleup"])
    if (root.soundExpanded) rows.push(["mode-stereo", "mode-direct", "mode-puredirect"])
    rows.push(["sleep-toggle"])
    if (root.sleepExpanded) rows.push(["sleepdown", "sleepup"])
    if (root.sleepExpanded) rows.push(["eco-auto", "eco-on", "eco-off"])
    if (root.sleepExpanded) rows.push(["dim-bri", "dim-dim", "dim-dar", "dim-off"])
    rows.push(["z2-toggle"])
    if (root.zone2Expanded) {
      rows.push(["z2power", "z2voldown", "z2mute", "z2volup"])
      rows.push(["z2-tv", "z2-cd", "z2-game", "z2-net"])
      rows.push(["z2-phono", "z2-bt", "z2-tuner"])
    }
    rows.push(["settings-toggle"])
    if (root.settingsExpanded) {
      rows.push(["menu-toggle", "cursor-up", "menu-option"])
      rows.push(["cursor-left", "menu-enter", "cursor-right"])
      rows.push(["menu-return", "cursor-down", "menu-info"])
    }
    rows.push(["disconnect"])
    return rows
  }

  property bool cursorActive: false
  property string focusKey: ""

  // Zone2 and the setup-menu d-pad are the least-used sections (this unit
  // has no zone2 hardware wired up, and the on-screen menu is a rare
  // visit) — collapsed by default so the common controls stay reachable
  // without scrolling.
  property bool zone2Expanded: false
  property bool settingsExpanded: false
  property bool soundExpanded: false
  property bool sleepExpanded: false

  function findFocusPos(key) {
    for (var r = 0; r < focusRows.length; r++) {
      var c = focusRows[r].indexOf(key)
      if (c >= 0) return { r: r, c: c }
    }
    return null
  }

  // Reveal the cursor on the first arrow press without moving it (matches
  // the rest of the kit); subsequent presses walk the row/column grid.
  function moveCursor(dx, dy) {
    var rows = root.focusRows
    if (rows.length === 0) return
    if (!root.cursorActive) {
      root.cursorActive = true
      if (!root.findFocusPos(root.focusKey)) root.focusKey = rows[0][0]
      return
    }
    var pos = root.findFocusPos(root.focusKey)
    if (!pos) { root.focusKey = rows[0][0]; return }
    var r = pos.r, c = pos.c
    if (dy !== 0) {
      r = Math.max(0, Math.min(rows.length - 1, r + dy))
      c = Math.min(c, rows[r].length - 1)
    }
    if (dx !== 0) c = Math.max(0, Math.min(rows[r].length - 1, c + dx))
    root.focusKey = rows[r][c]
  }

  // Keep the cursor on a valid target whenever the visible layout changes
  // underneath it (e.g. leaving the tuner input, a discovered receiver
  // list changing size).
  onFocusRowsChanged: {
    if (focusRows.length === 0) { cursorActive = false; return }
    if (!findFocusPos(focusKey)) focusKey = focusRows[0][0]
  }

  function activateFocused() {
    if (!root.cursorActive) return
    if (root.focusKey.indexOf("disc-") === 0) {
      var d = amp.discovered[parseInt(root.focusKey.substring(5), 10)]
      if (d) amp.connect(d.ip)
      return
    }
    switch (root.focusKey) {
      case "connect": root.submitIp(); break
      case "scan": amp.discover(); break
      case "power": amp.togglePower(); break
      case "eco-auto": amp.setEcoMode("AUTO"); break
      case "eco-on": amp.setEcoMode("ON"); break
      case "eco-off": amp.setEcoMode("OFF"); break
      case "dim-bri": amp.setDimLevel("BRI"); break
      case "dim-dim": amp.setDimLevel("DIM"); break
      case "dim-dar": amp.setDimLevel("DAR"); break
      case "dim-off": amp.setDimLevel("OFF"); break
      case "voldown": amp.volumeDown(); break
      case "mute": amp.toggleMute(); break
      case "volup": amp.volumeUp(); break
      case "in-tv": amp.selectInput("TV"); break
      case "in-cd": amp.selectInput("CD"); break
      case "in-game": amp.selectInput("GAME"); break
      case "in-net": amp.selectInput("NET"); break
      case "in-phono": amp.selectInput("PHONO"); break
      case "in-bt": amp.selectInput("BT"); break
      case "in-tuner": amp.selectInput("TUNER"); break
      case "bassdown": amp.bassDown(); break
      case "bassup": amp.bassUp(); break
      case "trebledown": amp.trebleDown(); break
      case "trebleup": amp.trebleUp(); break
      case "mode-stereo": amp.setSoundMode("STEREO"); break
      case "mode-direct": amp.setSoundMode("DIRECT"); break
      case "mode-puredirect": amp.setSoundMode("PURE DIRECT"); break
      case "sleepdown": root.adjustSleep(-15); break
      case "sleepup": root.adjustSleep(15); break
      case "freqdown": amp.freqDown(); break
      case "frequp": amp.freqUp(); break
      case "presetdown": amp.presetDown(); break
      case "presetup": amp.presetUp(); break
      case "menu-toggle": amp.menuToggle(); break
      case "cursor-up": amp.cursorUp(); break
      case "menu-option": amp.menuOption(); break
      case "cursor-left": amp.cursorLeft(); break
      case "menu-enter": amp.menuEnter(); break
      case "cursor-right": amp.cursorRight(); break
      case "menu-return": amp.menuReturn(); break
      case "cursor-down": amp.cursorDown(); break
      case "menu-info": amp.menuInfo(); break
      case "sound-toggle": root.soundExpanded = !root.soundExpanded; break
      case "sleep-toggle": root.sleepExpanded = !root.sleepExpanded; break
      case "z2-toggle": root.zone2Expanded = !root.zone2Expanded; break
      case "settings-toggle": root.settingsExpanded = !root.settingsExpanded; break
      case "z2power": amp.toggleZone2Power(); break
      case "z2voldown": amp.zone2VolumeDown(); break
      case "z2mute": amp.toggleZone2Mute(); break
      case "z2volup": amp.zone2VolumeUp(); break
      case "z2-tv": amp.selectZone2Input("TV"); break
      case "z2-cd": amp.selectZone2Input("CD"); break
      case "z2-game": amp.selectZone2Input("GAME"); break
      case "z2-net": amp.selectZone2Input("NET"); break
      case "z2-phono": amp.selectZone2Input("PHONO"); break
      case "z2-bt": amp.selectZone2Input("BT"); break
      case "z2-tuner": amp.selectZone2Input("TUNER"); break
      case "disconnect": amp.disconnect(); break
    }
  }

  function hasCursor(key) { return root.cursorActive && root.focusKey === key }

  function discoveredLabel(name, ip) {
    var n = String(name || ip || "")
    var max = 20
    if (n.length > max) n = n.substring(0, max - 1) + "…"
    return n
  }

  // Volume readout next to the icon, bar-widget style (mirrors how the
  // stock audio widget shows level inline) — hidden in vertical bars, where
  // there's no horizontal room for it, and whenever there's nothing
  // meaningful to show (off, muted, or not connected).
  readonly property bool showVolume: !root.bar.vertical && amp.phase === "connected" && amp.power && !amp.muted && amp.volume >= 0
  readonly property string volumeLabel: (amp.volume - 80 > 0 ? "+" : "") + (amp.volume - 80).toFixed(1)
  readonly property real volumeFraction: amp.volumeMax > 0 ? Math.max(0, Math.min(1, amp.volume / amp.volumeMax)) : 0

  // Without this the bar's open-panel underline defaults to 55% of the
  // slot width, which was tuned for the icon alone — with the volume label
  // appended the mark fell short of it. Span the whole row instead.
  readonly property real openPanelIndicatorWidth: barRow.implicitWidth

  visible: true
  implicitWidth: barRow.implicitWidth
  implicitHeight: barRow.implicitHeight

  Row {
    id: barRow
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    BarIconButton {
      id: button
      bar: root.bar
      text: "󰓃"
      tooltipText: "Marantz Remote — " + root.statusText()
      active: amp.phase === "connected" && amp.power
      onPressed: function(b) { root.toggle() }
    }

    Text {
      visible: root.showVolume
      text: root.volumeLabel
      color: root.bar.barForeground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
      renderType: Text.NativeRendering
      anchors.verticalCenter: button.verticalCenter

      MouseArea {
        anchors.fill: parent
        anchors.margins: Style.space(-4)
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggle()
      }
    }

  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: hotkeys
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    // Wraps PanelKeyCatcher to add two keys it doesn't know about:
    // Backspace (close, an alternate to Escape) and -/= (volume, without
    // needing the cursor on a volume button). Its own Keys.onPressed runs
    // first; anything it doesn't accept falls through to keyCatcher via
    // forwardTo, so arrows/enter/tab/etc keep working unchanged.
    Item {
      id: hotkeys
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.forwardTo: [keyCatcher]
      Keys.onPressed: function(event) {
        if (ipField.activeFocus) return
        if (event.key === Qt.Key_Backspace) {
          root.close(); event.accepted = true; return
        }
        if (event.key === Qt.Key_Minus) {
          amp.volumeDown(); event.accepted = true; return
        }
        if (event.key === Qt.Key_Equal) {
          amp.volumeUp(); event.accepted = true; return
        }
      }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        blocked: ipField.activeFocus

        onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
        onActivateRequested: root.activateFocused()
        onCloseRequested: root.close()
        onTabRequested: function(direction) { root.switchPanel(direction) }

          Column {
            id: column
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: Style.space(10)

          // ---------- Hero: compact icon + status line, same shape as
          // PiloTV's hero (see ~/projects/pilotv-omarchy). Volume/mute/input
          // state shows inline in statusText() and via selected buttons
          // below instead of a separate stat block.
          Item {
            width: parent.width
            implicitHeight: heroIcon.implicitHeight

            Text {
              id: heroIcon
              text: "󰓃"
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              color: root.bar.foreground
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: heroStatus
              text: root.statusText()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }

            // Volume meter, filling the space between the icon and the
            // status text — filled by volumeFraction (amp.volume scaled
            // against amp.volumeMax). Muted still shows the bar (dimmed)
            // rather than hiding it.
            Rectangle {
              visible: root.isConnected && amp.power && amp.volume >= 0
              height: Style.space(6)
              radius: height / 2
              color: Qt.darker(root.bar.foreground, 2.2)
              opacity: amp.muted ? 0.5 : 1
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(8)
              anchors.right: heroStatus.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter

              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                radius: parent.radius
                width: parent.width * root.volumeFraction
                color: root.bar.foreground
              }
            }
          }

          // Mirrors the receiver's own front-panel/net-radio display text
          // (amp.displayLines, fed by "NSE" reports) — same idea as the
          // tuner station readout below, but for whatever the amp itself is
          // currently showing (NET/USB "now playing", etc).
          Text {
            width: parent.width
            visible: root.isConnected && text !== ""
            text: amp.displayLines.filter(function(l) { return l.trim() !== "" }).join("  ·  ")
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
          }

          PanelSeparator { foreground: root.bar.foreground; visible: !root.isConnected }

          // ---------- Setup: IP entry + discovery ----------
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: amp.phase === "setup" || amp.phase === "discovering" || amp.phase === "error"

            Row {
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: ipField
                width: parent.width - connectBtn.width - parent.spacing
                placeholderText: "Receiver IP address"
                foreground: root.bar.foreground
                onAccepted: root.submitIp()
                Component.onCompleted: text = amp.lastIp
              }

              Button {
                id: connectBtn
                text: "Connect"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                hasCursor: root.hasCursor("connect")
                onClicked: root.submitIp()
              }
            }

            Button {
              width: parent.width
              text: amp.phase === "discovering" ? "Scanning…" : "Scan for receivers"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              hasCursor: root.hasCursor("scan")
              onClicked: amp.discover()
            }

            Text {
              visible: amp.phase === "error"
              width: parent.width
              text: amp.errorMessage
              color: "#e06c75"
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
            }

            // Button.qml has no elide/wrap of its own — a long SSDP SERVER
            // string would render past the button's fixed width instead of
            // stopping at it (learned the hard way on PiloTV's discovered
            // list), so truncate before it ever gets there.
            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: amp.discovered.length > 0

              PanelSectionHeader { text: "DISCOVERED"; width: parent.width; horizontalAlignment: Text.AlignHCenter; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }

              Repeater {
                model: amp.discovered
                Button {
                  required property var modelData
                  required property int index
                  width: parent.width
                  text: root.discoveredLabel(modelData.name, modelData.ip)
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  bordered: true
                  hasCursor: root.hasCursor("disc-" + index)
                  onClicked: amp.connect(modelData.ip)
                }
              }
            }
          }

          // ---------- Connecting ----------
          Text {
            width: parent.width
            visible: amp.phase === "connecting"
            text: "Connecting…"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
          }

          // ---------- Controls ----------
          Column {
            id: controls
            width: parent.width
            spacing: Style.space(8)
            visible: root.isConnected

            readonly property real colWidth: (width - Style.space(4) * 3) / 4

            // Top row: general-purpose controls, all bigger than the rest
            // of the panel's buttons (larger font + padding) since these
            // get pressed constantly.
            Row {
              width: parent.width
              spacing: Style.space(4)

              readonly property real btnWidth: (width - spacing * 3) / 4

              RemoteButton { width: parent.btnWidth; text: "PWR"; foreground: "#e06c75"; selected: amp.power; fontSize: Style.font.subtitle; verticalPadding: Style.space(10); hasCursor: root.hasCursor("power"); onClicked: amp.togglePower() }
              RemoteButton { width: parent.btnWidth; text: "VOL-"; fontSize: Style.font.subtitle; verticalPadding: Style.space(10); hasCursor: root.hasCursor("voldown"); onClicked: amp.volumeDown() }
              RemoteButton { width: parent.btnWidth; text: "MUTE"; selected: amp.muted; fontSize: Style.font.subtitle; verticalPadding: Style.space(10); hasCursor: root.hasCursor("mute"); onClicked: amp.toggleMute() }
              RemoteButton { width: parent.btnWidth; text: "VOL+"; fontSize: Style.font.subtitle; verticalPadding: Style.space(10); hasCursor: root.hasCursor("volup"); onClicked: amp.volumeUp() }
            }

            PanelSectionHeader { text: "INPUT"; width: parent.width; horizontalAlignment: Text.AlignHCenter; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }

            Grid {
              width: parent.width
              columns: 4
              rowSpacing: Style.space(4)
              columnSpacing: Style.space(4)

              InputButton { text: "TV"; selected: amp.currentInput === "TV"; hasCursor: root.hasCursor("in-tv"); onClicked: amp.selectInput("TV") }
              InputButton { text: "CD"; selected: amp.currentInput === "CD"; hasCursor: root.hasCursor("in-cd"); onClicked: amp.selectInput("CD") }
              InputButton { text: "GAME"; selected: amp.currentInput === "GAME"; hasCursor: root.hasCursor("in-game"); onClicked: amp.selectInput("GAME") }
              InputButton { text: "NET"; selected: amp.currentInput === "NET"; hasCursor: root.hasCursor("in-net"); onClicked: amp.selectInput("NET") }
              InputButton { text: "PHONO"; selected: amp.currentInput === "PHONO"; hasCursor: root.hasCursor("in-phono"); onClicked: amp.selectInput("PHONO") }
              InputButton { text: "BT"; selected: amp.currentInput === "BT"; hasCursor: root.hasCursor("in-bt"); onClicked: amp.selectInput("BT") }
              InputButton { text: "TUNER"; selected: amp.currentInput === "TUNER"; hasCursor: root.hasCursor("in-tuner"); onClicked: amp.selectInput("TUNER") }
            }

            // TUNE-/TUNE+ on the physical remote (distinct from the CH/PAGE
            // pair below) — frequency seek via TFANUP/DOWN, which only take
            // effect in FM/AM tuner mode. TUNER-specific, same as CH/PAGE
            // below.
            Row {
              width: parent.width
              spacing: Style.space(4)
              visible: amp.currentInput === "TUNER"
              RemoteButton { width: (parent.width - parent.spacing) / 2; text: "TUNE-"; hasCursor: root.hasCursor("freqdown"); onClicked: amp.freqDown() }
              RemoteButton { width: (parent.width - parent.spacing) / 2; text: "TUNE+"; hasCursor: root.hasCursor("frequp"); onClicked: amp.freqUp() }
            }

            // CH/PAGE on the physical remote — preset step in tuner mode,
            // station name shown above it. TUNER-specific, so gated on
            // that input unlike TUNE-/TUNE+ above.
            Column {
              width: parent.width
              spacing: Style.space(6)
              visible: amp.currentInput === "TUNER"

              Text { width: parent.width; text: amp.tunerStation !== "" ? amp.tunerStation : (amp.tunerPreset !== "" ? "Preset " + amp.tunerPreset : "—"); color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight }

              Text { width: parent.width; visible: amp.tunerFreq !== ""; text: amp.tunerFreq; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; horizontalAlignment: Text.AlignHCenter }

              PanelSectionHeader { text: "CH / PAGE"; width: parent.width; horizontalAlignment: Text.AlignHCenter; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }

              Row {
                width: parent.width
                spacing: Style.space(4)
                RemoteButton { width: (parent.width - parent.spacing) / 2; text: "◀"; hasCursor: root.hasCursor("presetdown"); onClicked: amp.presetDown() }
                RemoteButton { width: (parent.width - parent.spacing) / 2; text: "▶"; hasCursor: root.hasCursor("presetup"); onClicked: amp.presetUp() }
              }
            }

            // ---------- Sound: tone (bass/treble, -6dB..+6dB around a 0dB
            // center — Denon/Marantz has no direct "set" feedback loop
            // faster than UP/DOWN + report, so the value only moves once the
            // receiver echoes the new PSBAS/PSTRE line back) and sound mode,
            // merged under one header since both are audio-tuning controls.
            CollapsibleHeader { label: "SOUND"; expanded: root.soundExpanded; hasCursor: root.hasCursor("sound-toggle"); onToggled: root.soundExpanded = !root.soundExpanded }

            Row {
              width: parent.width
              spacing: Style.space(4)
              visible: root.soundExpanded

              ToneRow {
                width: (parent.width - parent.spacing) / 2
                label: "BASS"
                value: amp.bass
                downHasCursor: root.hasCursor("bassdown")
                upHasCursor: root.hasCursor("bassup")
                onDownClicked: amp.bassDown()
                onUpClicked: amp.bassUp()
              }

              ToneRow {
                width: (parent.width - parent.spacing) / 2
                label: "TREBLE"
                value: amp.treble
                downHasCursor: root.hasCursor("trebledown")
                upHasCursor: root.hasCursor("trebleup")
                onDownClicked: amp.trebleDown()
                onUpClicked: amp.trebleUp()
              }
            }

            Grid {
              width: parent.width
              columns: 3
              rowSpacing: Style.space(4)
              columnSpacing: Style.space(4)
              visible: root.soundExpanded

              readonly property real cellWidth: (width - columnSpacing * 2) / 3

              RemoteButton { width: parent.cellWidth; text: "STEREO"; selected: amp.soundMode === "STEREO"; hasCursor: root.hasCursor("mode-stereo"); onClicked: amp.setSoundMode("STEREO") }
              RemoteButton { width: parent.cellWidth; text: "DIRECT"; selected: amp.soundMode === "DIRECT"; hasCursor: root.hasCursor("mode-direct"); onClicked: amp.setSoundMode("DIRECT") }
              RemoteButton { width: parent.cellWidth; text: "PURE DIR"; selected: amp.soundMode === "PURE DIRECT"; hasCursor: root.hasCursor("mode-puredirect"); onClicked: amp.setSoundMode("PURE DIRECT") }
            }

            // ---------- Power: sleep timer + eco profile, merged under one
            // header since both are power-consumption settings rather than
            // audio or navigation controls.
            CollapsibleHeader { label: "POWER"; expanded: root.sleepExpanded; hasCursor: root.hasCursor("sleep-toggle"); onToggled: root.sleepExpanded = !root.sleepExpanded }

            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: root.sleepExpanded

              Text { width: parent.width; text: "SLEEP  " + (amp.sleepMinutes !== null ? (amp.sleepMinutes > 0 ? amp.sleepMinutes + " MIN" : "OFF") : "—"); color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; horizontalAlignment: Text.AlignHCenter }

              Row {
                width: parent.width
                spacing: Style.space(4)
                RemoteButton { width: (parent.width - parent.spacing) / 2; text: "-"; hasCursor: root.hasCursor("sleepdown"); onClicked: root.adjustSleep(-15) }
                RemoteButton { width: (parent.width - parent.spacing) / 2; text: "+"; hasCursor: root.hasCursor("sleepup"); onClicked: root.adjustSleep(15) }
              }
            }

            // Eco power-save profile — confirmed live against this receiver.
            Grid {
              width: parent.width
              columns: 3
              rowSpacing: Style.space(4)
              columnSpacing: Style.space(4)
              visible: root.sleepExpanded

              readonly property real cellWidth: (width - columnSpacing * 2) / 3

              RemoteButton { width: parent.cellWidth; text: "ECO AUTO"; selected: amp.ecoMode === "AUTO"; hasCursor: root.hasCursor("eco-auto"); onClicked: amp.setEcoMode("AUTO") }
              RemoteButton { width: parent.cellWidth; text: "ECO ON"; selected: amp.ecoMode === "ON"; hasCursor: root.hasCursor("eco-on"); onClicked: amp.setEcoMode("ON") }
              RemoteButton { width: parent.cellWidth; text: "ECO OFF"; selected: amp.ecoMode === "OFF"; hasCursor: root.hasCursor("eco-off"); onClicked: amp.setEcoMode("OFF") }
            }

            // Front-panel dimmer — matches the remote's physical DIMMER
            // button, grouped here since that button sits right next to
            // SLEEP on the remote too. Confirmed live against this
            // receiver.
            Grid {
              width: parent.width
              columns: 4
              rowSpacing: Style.space(4)
              columnSpacing: Style.space(4)
              visible: root.sleepExpanded

              readonly property real cellWidth: (width - columnSpacing * 3) / 4

              RemoteButton { width: parent.cellWidth; text: "BRIGHT"; selected: amp.dimLevel === "BRI"; hasCursor: root.hasCursor("dim-bri"); onClicked: amp.setDimLevel("BRI") }
              RemoteButton { width: parent.cellWidth; text: "DIM"; selected: amp.dimLevel === "DIM"; hasCursor: root.hasCursor("dim-dim"); onClicked: amp.setDimLevel("DIM") }
              RemoteButton { width: parent.cellWidth; text: "DARK"; selected: amp.dimLevel === "DAR"; hasCursor: root.hasCursor("dim-dar"); onClicked: amp.setDimLevel("DAR") }
              RemoteButton { width: parent.cellWidth; text: "OFF"; selected: amp.dimLevel === "OFF"; hasCursor: root.hasCursor("dim-off"); onClicked: amp.setDimLevel("OFF") }
            }

            // Receiver's on-screen setup/option menu. D-pad stays visible
            // whenever connected — not every model echoes "MNMEN ON" back,
            // so gating on that report left the d-pad unreachable.
            CollapsibleHeader { label: "ZONE 2"; expanded: root.zone2Expanded; hasCursor: root.hasCursor("z2-toggle"); onToggled: root.zone2Expanded = !root.zone2Expanded }

            Column {
              width: parent.width
              spacing: Style.space(8)
              visible: root.zone2Expanded

              Grid {
                width: parent.width
                columns: 4
                rowSpacing: Style.space(4)
                columnSpacing: Style.space(4)

                RemoteButton { width: controls.colWidth; text: "PWR"; foreground: "#e06c75"; selected: amp.zone2Power; hasCursor: root.hasCursor("z2power"); onClicked: amp.toggleZone2Power() }
                RemoteButton { width: controls.colWidth; text: "VOL-"; hasCursor: root.hasCursor("z2voldown"); onClicked: amp.zone2VolumeDown() }
                RemoteButton { width: controls.colWidth; text: "MUTE"; selected: amp.zone2Muted; hasCursor: root.hasCursor("z2mute"); onClicked: amp.toggleZone2Mute() }
                RemoteButton { width: controls.colWidth; text: "VOL+"; hasCursor: root.hasCursor("z2volup"); onClicked: amp.zone2VolumeUp() }
              }

              Grid {
                width: parent.width
                columns: 4
                rowSpacing: Style.space(4)
                columnSpacing: Style.space(4)

                InputButton { text: "TV"; selected: amp.zone2Input === "TV"; hasCursor: root.hasCursor("z2-tv"); onClicked: amp.selectZone2Input("TV") }
                InputButton { text: "CD"; selected: amp.zone2Input === "CD"; hasCursor: root.hasCursor("z2-cd"); onClicked: amp.selectZone2Input("CD") }
                InputButton { text: "GAME"; selected: amp.zone2Input === "GAME"; hasCursor: root.hasCursor("z2-game"); onClicked: amp.selectZone2Input("GAME") }
                InputButton { text: "NET"; selected: amp.zone2Input === "NET"; hasCursor: root.hasCursor("z2-net"); onClicked: amp.selectZone2Input("NET") }
                InputButton { text: "PHONO"; selected: amp.zone2Input === "PHONO"; hasCursor: root.hasCursor("z2-phono"); onClicked: amp.selectZone2Input("PHONO") }
                InputButton { text: "BT"; selected: amp.zone2Input === "BT"; hasCursor: root.hasCursor("z2-bt"); onClicked: amp.selectZone2Input("BT") }
                InputButton { text: "TUNER"; selected: amp.zone2Input === "TUNER"; hasCursor: root.hasCursor("z2-tuner"); onClicked: amp.selectZone2Input("TUNER") }
              }
            }

            CollapsibleHeader { label: "SETUP MENU"; expanded: root.settingsExpanded; hasCursor: root.hasCursor("settings-toggle"); onToggled: root.settingsExpanded = !root.settingsExpanded }

            // Corners: menu toggle (top-left), option menu (top-right),
            // info overlay (bottom-right) — MNMEN / MNOPT / MNINF.
            Grid {
              width: parent.width
              columns: 3
              rowSpacing: Style.space(4)
              columnSpacing: Style.space(4)
              visible: root.settingsExpanded

              readonly property real cellWidth: (width - columnSpacing * 2) / 3

              RemoteButton { width: parent.cellWidth; text: "MENU"; selected: amp.menuOpen; hasCursor: root.hasCursor("menu-toggle"); onClicked: amp.menuToggle() }
              RemoteButton { width: parent.cellWidth; text: "UP"; hasCursor: root.hasCursor("cursor-up"); onClicked: amp.cursorUp() }
              RemoteButton { width: parent.cellWidth; text: "OPTION"; hasCursor: root.hasCursor("menu-option"); onClicked: amp.menuOption() }

              RemoteButton { width: parent.cellWidth; text: "LEFT"; hasCursor: root.hasCursor("cursor-left"); onClicked: amp.cursorLeft() }
              RemoteButton { width: parent.cellWidth; text: "ENTER"; hasCursor: root.hasCursor("menu-enter"); onClicked: amp.menuEnter() }
              RemoteButton { width: parent.cellWidth; text: "RIGHT"; hasCursor: root.hasCursor("cursor-right"); onClicked: amp.cursorRight() }

              RemoteButton { width: parent.cellWidth; text: "BACK"; hasCursor: root.hasCursor("menu-return"); onClicked: amp.menuReturn() }
              RemoteButton { width: parent.cellWidth; text: "DOWN"; hasCursor: root.hasCursor("cursor-down"); onClicked: amp.cursorDown() }
              RemoteButton { width: parent.cellWidth; text: "INFO"; hasCursor: root.hasCursor("menu-info"); onClicked: amp.menuInfo() }
            }

            Text {
              text: amp.ip + "  ·  Disconnect"
              color: root.hasCursor("disconnect") ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.underline: root.hasCursor("disconnect")
              anchors.horizontalCenter: parent.horizontalCenter

              MouseArea {
                anchors.fill: parent
                anchors.margins: Style.space(-4)
                cursorShape: Qt.PointingHandCursor
                onClicked: amp.disconnect()
              }
            }
          }
        }
      }
    }
  }

  // Clickable section header: chevron + label toggles a collapsed
  // section, keyboard-reachable like every other control (hasCursor drives
  // the same underline convention used on the disconnect link below).
  component CollapsibleHeader: Item {
    id: sectionHeader
    property string label: ""
    property bool expanded: false
    property bool hasCursor: false
    signal toggled()

    width: parent.width
    implicitHeight: headerText.implicitHeight

    PanelSectionHeader {
      id: headerText
      text: (sectionHeader.expanded ? "▾ " : "▸ ") + sectionHeader.label
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
      font.underline: sectionHeader.hasCursor
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: sectionHeader.toggled()
    }
  }

  component RemoteButton: Button {
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    bordered: false
  }

  // Input row: source code as text rather than an icon glyph, sized down
  // so "PHONO"/"TUNER" still fit a quarter-width column.
  component InputButton: Button {
    width: controls.colWidth
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    bordered: false
  }

  // Label + current dB readout + "-"/"+" text buttons (no icon glyphs).
  component ToneRow: Column {
    id: toneRow
    property string label: ""
    property var value: null
    property bool downHasCursor: false
    property bool upHasCursor: false
    signal downClicked()
    signal upClicked()

    spacing: Style.space(4)

    Text { width: parent.width; text: toneRow.label + (toneRow.value !== null ? "  " + (toneRow.value > 0 ? "+" : "") + toneRow.value + "dB" : ""); color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; horizontalAlignment: Text.AlignHCenter }

    Row {
      width: parent.width
      spacing: Style.space(4)
      Button { width: (parent.width - parent.spacing) / 2; text: "-"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily; bordered: false; hasCursor: toneRow.downHasCursor; onClicked: toneRow.downClicked() }
      Button { width: (parent.width - parent.spacing) / 2; text: "+"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily; bordered: false; hasCursor: toneRow.upHasCursor; onClicked: toneRow.upClicked() }
    }
  }
}
