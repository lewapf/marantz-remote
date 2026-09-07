import QtQuick
import Quickshell
import Quickshell.Io

// Talks to a Denon/Marantz receiver over its "IP Control" protocol: a
// plain-text line protocol on TCP port 23 (PWON, MVUP, MUOFF, SICD, ...).
// No pairing, no cert — just a socket. Quickshell has no raw TCP socket
// type of its own (Quickshell.Io's Socket is a QLocalSocket, i.e. Unix
// sockets), so the connection itself is held open by a small bash process
// using bash's built-in /dev/tcp/<host>/<port> redirection.
Item {
  id: root
  visible: false

  readonly property string home: Quickshell.env("HOME") || ""

  // "setup" | "discovering" | "connecting" | "connected" | "error"
  property string phase: "setup"
  property string ip: ""
  property string lastIp: ""
  property string errorMessage: ""
  property var discovered: []

  property bool power: false
  property bool muted: false
  property string currentInput: ""
  property string tunerPreset: ""
  property string tunerStation: ""
  // FM/AM direct-tune frequency, human-readable ("87.50 MHz" / "1620 kHz"),
  // reported as "TFAN<5 digits>" — FM ships as MHz*100 (08750 -> 87.50),
  // AM as plain kHz (01620 -> 1620); the two ranges don't overlap so the
  // magnitude alone tells them apart. Empty until the first TFAN report,
  // which only ever arrives on an FM/AM-tuned unit (DAB reports via TPAN/
  // DAENL instead, never TFAN).
  property string tunerFreq: ""

  // Zone2: same "ZZ..." style commands as main zone, prefixed "Z2" instead
  // of bare (e.g. "Z2ON"/"Z2OFF" for power, "Z2MUON"/"Z2MUOFF" for mute,
  // "Z2UP"/"Z2DOWN" for volume, "Z2<source>" for input). No separate
  // absolute-volume readout — like main-zone MV, only UP/DOWN exist, and
  // the receiver echoes the new level back as "Z2<nn>".
  property bool zone2Power: false
  property bool zone2Muted: false
  property string zone2Input: ""
  property real zone2Volume: -1
  // Master volume as the receiver reports it: "MV50" = 50.0, "MV505" =
  // 50.5 (third digit is the half-dB step). -1 until the first MV report.
  property real volume: -1
  // Volume ceiling from "MVMAX nn" (e.g. 98) — used to scale the bar-widget
  // volume meter. Falls back to 98 (this receiver's reported max) until the
  // first report arrives.
  property real volumeMax: 98
  // Receiver's on-screen setup/option menu state (MNMEN ON/OFF reports).
  property bool menuOpen: false

  // Bass/treble, reported as "PSBAS 50"/"PSTRE 50" with 50 = 0dB and each
  // unit a further 1dB (so 44..56 spans -6dB..+6dB) — null until the first
  // report arrives.
  property var bass: null
  property var treble: null

  // Surround/sound mode, e.g. "STEREO", "MOVIE", "PURE DIRECT" — reported
  // verbatim from "MS<mode>".
  property string soundMode: ""
  // Eco mode, one of "AUTO"/"ON"/"OFF" — reported verbatim from "ECO<mode>".
  // Confirmed live against this receiver.
  property string ecoMode: ""
  // Front-panel display dimmer, one of "BRI"/"DIM"/"DAR"/"OFF" — reported
  // verbatim from "DIM<level>". Confirmed live against this receiver.
  property string dimLevel: ""
  // Front-panel display text, mirrored from "NSE0".."NSE8" reports (the
  // same scrolling-text buffer the receiver uses for NET/USB "now playing"
  // info). Index 0..8 by row; "" until a row has been reported.
  property var displayLines: ["", "", "", "", "", "", "", "", ""]
  // Sleep timer in minutes; 0 = off, null = not yet reported.
  property var sleepMinutes: null

  // Auto-reconnect after a dropped connection: a few quick retries to the
  // last known IP, then give up into the error phase so the user sees it.
  property int _retriesLeft: 0
  readonly property int _maxRetries: 3

  FileView {
    id: lastIpFile
    path: root.home + "/.config/marantz-remote/last-ip"
    watchChanges: false
    printErrors: false
    onLoaded: {
      var value = text().trim()
      if (value) {
        root.lastIp = value
        root.ip = value
      }
    }
  }

  function rememberIp(value) {
    root.lastIp = value
    lastIpFile.setText(value + "\n")
  }

  // Reads socket bytes one at a time, framing on CR (the receiver's own
  // framing) and re-emitting LF-terminated lines so SplitParser sees one
  // status line per read; writes go back the other way with CR appended,
  // which is what the receiver expects on its end.
  //
  // Hardening against a hung or misbehaving peer (unreachable host, a
  // device that accepts the TCP connection but never talks, or one that
  // streams a line that never ends): a watchdog kills the connect attempt
  // after CONNECT_TIMEOUT; the byte-reader's `read -t IO_TIMEOUT` bounds
  // how long any single read may block and doubles as the frame's max
  // length check via MAX_LINE, so a stalled or oversized frame ends the
  // reader loop and it signals the whole script to exit (closing fd 3)
  // rather than leaving a zombie connection Quickshell never learns about;
  // writes get the same IO_TIMEOUT via `timeout`, in case the socket send
  // buffer is stuck.
  readonly property string _connectScript: [
    'CONNECT_TIMEOUT=8',
    'IO_TIMEOUT=300',
    'MAX_LINE=1024',
    'printf -v CR "\\r"',
    'trap \'echo ERR_CONNECT; exit 1\' TERM',
    '( sleep "$CONNECT_TIMEOUT"; kill -TERM $$ 2>/dev/null ) &',
    'WATCHDOG=$!',
    'exec 3<>"/dev/tcp/$1/23" || { kill $WATCHDOG 2>/dev/null; echo ERR_CONNECT; exit 1; }',
    'kill $WATCHDOG 2>/dev/null',
    'trap - TERM',
    'echo CONNECTED',
    '(',
    '  buf=""',
    '  while IFS= read -r -t "$IO_TIMEOUT" -N 1 ch <&3; do',
    '    if [ "$ch" = "$CR" ]; then',
    '      printf "%s\\n" "$buf"',
    '      buf=""',
    '    else',
    '      buf="$buf$ch"',
    '      if [ ${#buf} -gt "$MAX_LINE" ]; then',
    '        break',
    '      fi',
    '    fi',
    '  done',
    '  kill -TERM $$ 2>/dev/null',
    ') &',
    'CATPID=$!',
    'trap \'kill $CATPID 2>/dev/null\' EXIT',
    'while IFS= read -r line; do',
    '  timeout "$IO_TIMEOUT" bash -c \'printf "%s\\r" "$1" >&3\' -- "$line" || break',
    'done',
    'kill $CATPID 2>/dev/null'
  ].join('\n')

  Process {
    id: ampProc
    stdinEnabled: true
    running: false

    stdout: SplitParser {
      onRead: function(line) {
        if (line === "CONNECTED") {
          root.phase = "connected"
          root._retriesLeft = root._maxRetries
          root.rememberIp(root.ip)
          // Ask the receiver for its current state instead of assuming
          // power-off/unmuted — another remote or the front panel may
          // already have it on.
          root.sendCmd("PW?")
          root.sendCmd("MU?")
          root.sendCmd("SI?")
          root.sendCmd("MV?")
          root.sendCmd("MNMEN?")
          root.sendCmd("PSBAS ?")
          root.sendCmd("PSTRE ?")
          root.sendCmd("MS?")
          root.sendCmd("ECO?")
          root.sendCmd("DIM ?")
          root.sendCmd("SLP?")
          root.sendCmd("Z2?")
          root.sendCmd("Z2MU?")
          root.sendCmd("NSE")
          root.sendCmd("TFAN?")
        } else if (line === "ERR_CONNECT") {
          if (root._retriesLeft > 0) {
            root._retriesLeft--
            retryTimer.start()
          } else {
            root.errorMessage = "Couldn't reach " + root.ip + ":23"
            root.phase = "error"
          }
        } else {
          root.applyStatusLine(line)
        }
      }
    }

    onExited: {
      if (root.phase === "connected") {
        if (root._retriesLeft > 0) {
          root._retriesLeft--
          root.phase = "connecting"
          retryTimer.start()
        } else {
          root.errorMessage = "Connection lost"
          root.phase = "error"
        }
      }
    }
  }

  Timer {
    id: retryTimer
    interval: 2000
    onTriggered: root.connect(root.ip)
  }

  // Denon/Marantz receivers advertise themselves over SSDP/UPnP, not mDNS
  // (that's what PiloTV's Android TV used) — a multicast M-SEARCH on
  // 239.255.255.250:1900, collecting whichever unicast replies mention
  // Denon or Marantz in their SSDP headers. Bash's /dev/udp doesn't give
  // enough control for "send one packet, collect several replies over a
  // few seconds", so this one shells out to python3 (already on the
  // system, no extra dependency) instead of bash.
  readonly property string _discoverScript: [
    'import socket, time, re, sys',
    'def msearch(st):',
    '    return ("M-SEARCH * HTTP/1.1\\r\\nHOST: 239.255.255.250:1900\\r\\nMAN: \\"ssdp:discover\\"\\r\\nMX: 4\\r\\nST: " + st + "\\r\\n\\r\\n").encode()',
    'sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)',
    'sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)',
    'sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 4)',
    'sock.bind(("", 0))',
    '# M-SEARCH rides plain UDP — repeat the send a few times so one lost',
    '# packet does not turn into "no receivers found"; MediaRenderer is the',
    '# ST Denon/Marantz units answer most reliably, ssdp:all is the net.',
    'for _ in range(3):',
    '    for st in ("urn:schemas-upnp-org:device:MediaRenderer:1", "ssdp:all"):',
    '        sock.sendto(msearch(st), ("239.255.255.250", 1900))',
    '    time.sleep(0.3)',
    'sock.settimeout(6)',
    'seen = set()',
    'end = time.time() + 6',
    'while time.time() < end:',
    '    try:',
    '        data, addr = sock.recvfrom(4096)',
    '    except socket.timeout:',
    '        break',
    '    ip = addr[0]',
    '    if ip in seen:',
    '        continue',
    '    text = data.decode(errors="ignore")',
    '    if not re.search(r"denon|marantz", text, re.IGNORECASE):',
    '        continue',
    '    seen.add(ip)',
    '    m = re.search(r"SERVER:\\s*(.+)", text, re.IGNORECASE)',
    '    name = m.group(1).strip() if m else "Receiver"',
    '    print("FOUND " + ip + " " + name)',
    '    sys.stdout.flush()',
    'print("DISCOVER_DONE")'
  ].join('\n')

  Process {
    id: discoverProc
    running: false
    command: ["python3", "-c", root._discoverScript]

    stdout: SplitParser {
      onRead: function(line) {
        if (line.indexOf("FOUND ") === 0) {
          var rest = line.substring(6)
          var sp = rest.indexOf(" ")
          var ip = sp > 0 ? rest.substring(0, sp) : rest
          var name = sp > 0 ? rest.substring(sp + 1) : rest
          root.discovered = root.discovered.concat([{ ip: ip, name: name }])
        } else if (line === "DISCOVER_DONE") {
          if (root.phase === "discovering") root.phase = "setup"
        }
      }
    }

    onExited: {
      if (root.phase === "discovering") root.phase = "setup"
    }
  }

  function discover() {
    if (discoverProc.running) return
    root.phase = "discovering"
    root.discovered = []
    discoverProc.running = true
  }

  function applyStatusLine(line) {
    if (line.indexOf("PWON") === 0) root.power = true
    else if (line.indexOf("PWSTANDBY") === 0) root.power = false
    else if (line.indexOf("MUON") === 0) root.muted = true
    else if (line.indexOf("MUOFF") === 0) root.muted = false
    // TPAN carries the current tuner preset number (e.g. "TPAN02") whether
    // the active band is DAB (this unit) or FM/AM — verified live against
    // the actual receiver, unlike the frequency (TFAN) commands, which
    // only apply in FM/AM mode and were left out since this unit's last
    // known band is DAB.
    else if (line.indexOf("TPAN") === 0) root.tunerPreset = line.substring(4)
    else if (/^TFAN\d+$/.test(line)) {
      var freqRaw = parseInt(line.substring(4), 10)
      root.tunerFreq = freqRaw >= 5000
        ? (freqRaw / 100).toFixed(2) + " MHz"
        : freqRaw + " kHz"
    }
    // "MVMAX 98" is the volume ceiling report — parsed for the bar-widget
    // meter's scale, not treated as a volume level. Actual level: "MV50" =
    // 50.0, "MV505" = 50.5 (third digit is the half-dB step).
    else if (line.indexOf("MVMAX") === 0) {
      var mvMax = parseInt(line.substring(5).trim(), 10)
      if (!isNaN(mvMax)) root.volumeMax = mvMax
    }
    else if (line.indexOf("MV") === 0) {
      var mv = line.substring(2).trim()
      if (/^\d+$/.test(mv)) {
        root.volume = mv.length > 2
          ? parseInt(mv.substring(0, 2), 10) + (mv.charAt(2) === "5" ? 0.5 : 0)
          : parseInt(mv, 10)
      }
    }
    else if (line.indexOf("MNMEN ON") === 0) root.menuOpen = true
    else if (line.indexOf("MNMEN OFF") === 0) root.menuOpen = false
    // DAB-only: station name, e.g. "DAENL Antenne DE      " (padded).
    else if (line.indexOf("DAENL") === 0) root.tunerStation = line.substring(5).trim()
    // "PSBAS 50"/"PSTRE 50" — 50 is the 0dB center, each unit another 1dB.
    else if (line.indexOf("PSBAS") === 0) {
      var bas = parseInt(line.substring(5).trim(), 10)
      if (!isNaN(bas)) root.bass = bas - 50
    }
    else if (line.indexOf("PSTRE") === 0) {
      var tre = parseInt(line.substring(5).trim(), 10)
      if (!isNaN(tre)) root.treble = tre - 50
    }
    // "SLP030" = 30 minutes remaining; "SLPOFF" = timer not set.
    else if (line.indexOf("SLP") === 0) {
      var slp = line.substring(3).trim()
      if (slp === "OFF") root.sleepMinutes = 0
      else if (/^\d+$/.test(slp)) root.sleepMinutes = parseInt(slp, 10)
    }
    // Surround/sound mode, e.g. "MSSTEREO", "MSPURE DIRECT". Must come
    // before the SI check below since "SI" is not a prefix of "MS", but
    // stays after every other M-prefixed check above to avoid stealing
    // MU/MV/MNMEN lines.
    else if (line.indexOf("MS") === 0) root.soundMode = line.substring(2).trim()
    // "ECOAUTO"/"ECOON"/"ECOOFF" — must come before the SI check below for
    // the same reason as MS above, though "ECO" isn't a prefix collision
    // risk with anything else currently parsed.
    else if (line.indexOf("ECO") === 0) root.ecoMode = line.substring(3).trim()
    else if (line.indexOf("DIM") === 0) root.dimLevel = line.substring(3).trim()
    // Front-panel display buffer: "NSE0<text>".."NSE8<text>", one row per
    // line, pushed unsolicited whenever the receiver's own display changes
    // (net radio/USB "now playing" scroll) as well as in reply to "NSE".
    else if (/^NSE\d/.test(line)) {
      var nseRow = parseInt(line.charAt(3), 10)
      var nseLines = root.displayLines.slice()
      nseLines[nseRow] = line.substring(4)
      root.displayLines = nseLines
    }
    else if (line.indexOf("SI") === 0) root.currentInput = line.substring(2)
    // Zone2 — mirrors the main-zone parsing above, but every report is
    // prefixed "Z2". Exact-match ON/OFF/MUON/MUOFF checked before the
    // digits-only volume check and the input-code fallback so they never
    // get misread as a source name.
    else if (line === "Z2ON") root.zone2Power = true
    else if (line === "Z2OFF") root.zone2Power = false
    else if (line === "Z2MUON") root.zone2Muted = true
    else if (line === "Z2MUOFF") root.zone2Muted = false
    else if (line.indexOf("Z2") === 0) {
      var z2rest = line.substring(2)
      if (/^\d+$/.test(z2rest)) {
        root.zone2Volume = z2rest.length > 2
          ? parseInt(z2rest.substring(0, 2), 10) + (z2rest.charAt(2) === "5" ? 0.5 : 0)
          : parseInt(z2rest, 10)
      } else {
        root.zone2Input = z2rest
      }
    }
  }

  function connect(targetIp) {
    if (!targetIp) return
    root.ip = targetIp
    root.errorMessage = ""
    root.phase = "connecting"
    if (ampProc.running) ampProc.running = false
    ampProc.command = ["bash", "-c", root._connectScript, "marantz-remote", targetIp]
    ampProc.running = true
  }

  function disconnect() {
    root._retriesLeft = 0
    retryTimer.stop()
    root.phase = "setup"
    if (ampProc.running) ampProc.running = false
  }

  // Called when the popup opens: quietly get back to a useful state
  // instead of showing a dead setup form — reconnect to the last known
  // receiver if there is one, otherwise start a scan.
  function ensureConnected() {
    if (root.phase === "connected" || root.phase === "connecting" || root.phase === "discovering") return
    if (root.lastIp) connect(root.lastIp)
    else discover()
  }

  function sendCmd(cmd) {
    if (!ampProc.running || root.phase !== "connected") return
    ampProc.write(cmd + "\n")
  }

  // Some receivers auto-link Zone2 to main power internally (a firmware/menu
  // setting outside IP-control's reach), so a bare PWON can bring Zone2 up
  // even though this app never sent Z2ON. Guard against that: after turning
  // main power on, explicitly re-assert whatever Zone2's state was right
  // before the toggle, so an off Zone2 stays off.
  function togglePower() {
    var turningOn = !root.power
    var zone2WasOn = root.zone2Power
    sendCmd(turningOn ? "PWON" : "PWSTANDBY")
    if (turningOn && !zone2WasOn) sendCmd("Z2OFF")
  }

  function toggleMute() {
    sendCmd(root.muted ? "MUOFF" : "MUON")
  }

  function volumeUp() { sendCmd("MVUP") }
  function volumeDown() { sendCmd("MVDOWN") }
  function bassUp() { sendCmd("PSBAS UP") }
  function bassDown() { sendCmd("PSBAS DOWN") }
  function trebleUp() { sendCmd("PSTRE UP") }
  function trebleDown() { sendCmd("PSTRE DOWN") }

  function setSoundMode(mode) { sendCmd("MS" + mode) }

  function setEcoMode(mode) { sendCmd("ECO" + mode) }

  function setDimLevel(level) { sendCmd("DIM " + level) }

  function toggleZone2Power() { sendCmd(root.zone2Power ? "Z2OFF" : "Z2ON") }
  function toggleZone2Mute() { sendCmd(root.zone2Muted ? "Z2MUOFF" : "Z2MUON") }
  function zone2VolumeUp() { sendCmd("Z2UP") }
  function zone2VolumeDown() { sendCmd("Z2DOWN") }
  function selectZone2Input(code) { sendCmd("Z2" + code) }

  // No UP/DOWN on this one — the protocol only takes an absolute minute
  // value (001-120) or OFF, so the panel computes the next step and sends
  // the whole new value each time.
  function setSleep(minutes) {
    if (minutes <= 0) sendCmd("SLPOFF")
    else sendCmd("SLP" + String(Math.round(minutes)).padStart(3, "0"))
  }
  function selectInput(code) { sendCmd("SI" + code) }
  function presetUp() { sendCmd("TPANUP") }
  function presetDown() { sendCmd("TPANDOWN") }
  // FM/AM direct frequency step (analog tuning) — distinct from TPANUP/
  // DOWN above, which only walks saved presets. FM/AM-only: no DAB
  // equivalent exists, but the receiver doesn't report which band is
  // active until a TFAN line arrives, so the panel keeps these always
  // visible rather than gating on unknown band state.
  function freqUp() { sendCmd("TFANUP") }
  function freqDown() { sendCmd("TFANDOWN") }

  // On-screen setup/option menu navigation (the receiver echoes
  // "MNMEN ON"/"MNMEN OFF" back, which drives menuOpen).
  function menuToggle() { sendCmd(root.menuOpen ? "MNMEN OFF" : "MNMEN ON") }
  function cursorUp() { sendCmd("MNCUP") }
  function cursorDown() { sendCmd("MNCDN") }
  function cursorLeft() { sendCmd("MNCLT") }
  function cursorRight() { sendCmd("MNCRT") }
  function menuEnter() { sendCmd("MNENT") }
  function menuReturn() { sendCmd("MNRTN") }
  function menuOption() { sendCmd("MNOPT") }
  function menuInfo() { sendCmd("MNINF") }
}
