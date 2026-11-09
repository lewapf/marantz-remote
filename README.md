# Marantz Remote

An [Omarchy](https://omarchy.org/) bar-widget plugin that controls a
Denon/Marantz AV receiver over its "IP Control" protocol — power, volume,
mute, input select, bass/treble, sound mode, sleep timer, tuner presets, and
the receiver's on-screen setup menu, all from a bar popup.

No external app, pairing, or account needed. The plugin talks directly to
the receiver over a plain TCP socket on your local network.

## Features

- **Power / volume / mute** — live dB readout (receiver-reported, not a
  guessed percentage), a draggable volume slider (right-click mutes), and
  scroll-for-volume / middle-click-for-mute right on the bar icon
- **Input select** — TV, CD, GAME, NET, PHONO, BT, TUNER
- **Bass / treble** — ±6 dB
- **Sound mode** — Stereo, Direct, Pure Direct
- **Sleep timer** — 15-minute steps, 0–120 minutes
- **Tuner presets** — step through presets, station name shown for DAB
- **Setup menu navigation** — full d-pad (up/down/left/right/enter/back/
  option/info) for the receiver's on-screen menu
- **Auto-discovery** — SSDP scan finds Denon/Marantz receivers on the LAN,
  no IP typing required
- **Remembers your receiver** — connects to the last IP when the shell
  starts, so the bar readout is live without opening the popup; retries
  quickly after a drop, then keeps retrying in the background with backoff
  (receiver unplugged, network down after resume) until you disconnect
- **Reliable command delivery** — commands are paced ~60ms apart, as the
  receiver drops ones that arrive too close together; a 30s heartbeat
  detects a dead connection within ~95s
- **IPC / keybindings** — drive the receiver from scripts or Hyprland binds
  (see below)
- **Full keyboard navigation** — arrow keys / enter, plus `-`/`=` as volume
  shortcuts and Backspace to close

## Requirements

- An Omarchy desktop running `omarchy-shell`
- A Denon or Marantz AV receiver on the same network with network standby /
  IP control enabled (check the receiver's network settings)
- `bash`, `python3`, and coreutils (`stdbuf`, `tr`, `cat`) available on
  `$PATH` — present on any standard Omarchy install. `python3` is only used
  for the discovery scan; the persistent receiver connection itself is a
  plain `bash` process using `/dev/tcp`, no extra runtime or package needed.

## Installation

```bash
omarchy plugin add https://github.com/lewapf/marantz-remote.git
omarchy plugin enable io.github.lewapf.marantz-remote
```

Or from **Setup › Plugins** in Omarchy, choose **Add**, and paste the repo
URL.

Plugins run as unsandboxed code inside `omarchy-shell` — review the source
before enabling anything you add. Omarchy clones it disabled by default so
you can look it over first.

## Update

```bash
omarchy plugin update io.github.lewapf.marantz-remote
```

## Remove

```bash
omarchy plugin disable io.github.lewapf.marantz-remote   # takes it off the bar
omarchy plugin remove io.github.lewapf.marantz-remote    # deletes the plugin checkout
```

Removal deletes `~/.config/omarchy/plugins/io.github.lewapf.marantz-remote/`.
The last-connected IP and the Zone2 link setting live outside the plugin
checkout, under `~/.config/marantz-remote/`, and survive a remove/reinstall.

## Usage

1. Click the bar icon to open the popup.
2. If no receiver is known yet, either enter its IP address directly or hit
   **Scan for receivers** to find it via SSDP.
3. Once connected, the receiver's IP is remembered under
   `~/.config/marantz-remote/last-ip` and it reconnects automatically the
   next time the popup opens.
4. Use **Disconnect** at the bottom of the panel to forget the active
   session (the last IP is kept for next time).

## IPC

Everything goes through `omarchy-shell marantz-remote <function> [args]`:

| Function | Effect |
|---|---|
| `toggle` / `open` / `close` | Popup |
| `volumeUp` / `volumeDown` | One volume step |
| `setVolume <dB>` | Absolute level, e.g. `setVolume -30` |
| `toggleMute` / `mute` / `unmute` | Mute |
| `togglePower` / `powerOn` / `powerOff` | Main-zone power |
| `input <code>` | Input, e.g. `input CD`, `input TV` |
| `reconnect` | Reconnect to the current receiver |
| `status` | Prints the status line, e.g. `-30.5dB · CD` |

Example Hyprland bindings (in `~/.config/hypr/bindings.lua`):

```lua
o.bind("SUPER + XF86AudioRaiseVolume", "Receiver volume up", "omarchy-shell marantz-remote volumeUp", { locked = true, repeating = true })
o.bind("SUPER + XF86AudioLowerVolume", "Receiver volume down", "omarchy-shell marantz-remote volumeDown", { locked = true, repeating = true })
o.bind("SUPER + XF86AudioMute", "Receiver mute", "omarchy-shell marantz-remote toggleMute", { locked = true })
```

## How it works

Denon/Marantz receivers speak a plain-text line protocol on TCP port 23
(`PWON`, `MVUP`, `MUOFF`, `SICD`, ...) — no pairing or certificate required.
Quickshell's own `Socket` type is Unix-domain only, so the plugin opens the
TCP connection with a small long-lived `bash` process using bash's built-in
`/dev/tcp/<host>/23` redirection, and reads/writes status lines over its
stdin/stdout. Discovery uses one SSDP `M-SEARCH` multicast via a short-lived
`python3` script, since sending one packet and collecting several replies
over a few seconds isn't something bash's `/dev/udp` gives enough control
over.

## Troubleshooting

- **"Couldn't reach `<ip>`:23"** — check the receiver is powered on standby
  (not fully off) and that network standby/control is enabled in its
  network settings; confirm it's reachable with `nc -zv <ip> 23`.
- **Scan finds nothing** — SSDP relies on multicast, which some routers/APs
  block between VLANs or on client-isolated Wi-Fi networks; enter the IP
  manually instead (check your router's DHCP client list).
- **Values don't update** — the plugin only reflects what the receiver
  reports back over the socket; power-cycling the receiver's network
  connection (unplug/replug, or toggle network standby) usually resolves a
  stuck session.

## Development

```bash
omarchy plugin validate "$HOME/.config/omarchy/plugins/io.github.lewapf.marantz-remote"
qmllint -I "$OMARCHY_PATH/shell" Panel.qml Amp.qml
```

## License

MIT — see [LICENSE](LICENSE).
