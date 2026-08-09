# BudSwitch

A macOS menubar app that moves your Bluetooth earbuds between your Mac and your phone —
automatically, in about a second.

Most earbuds can only hold one connection at a time. Switching means opening Bluetooth
settings on one device, disconnecting, then reconnecting on the other. BudSwitch does it
for you: start playing something on your Mac and the buds come to you; walk away and they
go back to your phone.

Built for **Samsung Galaxy Buds4 Pro**, which have no true multipoint for non-Samsung
devices and whose Auto Switch is Galaxy-only. It works with any paired Bluetooth audio
device, and takes a much faster path when the device *does* support multipoint.

---

## Install

1. Download the `.dmg` from [Releases](../../releases).
2. Drag **BudSwitch** onto **Applications**.
3. **Right-click** the app in Applications → **Open** → **Open**.

> Step 3 matters. Double-clicking shows *"Apple could not verify BudSwitch is free of
> malware"* with no way past it. Right-click → Open gives you the button to continue. You
> only do this once.
>
> This is because the app isn't notarized — that requires a paid Apple Developer account.
> The app is code-signed and its signature verifies; it simply isn't registered with Apple.

Allow **Bluetooth** when asked. It's the only permission needed — the keyboard shortcut
requires nothing extra.

Then look for the headphones icon in your menubar. There's no Dock icon and no window;
that icon is the whole app.

**Requirements:** macOS 14 (Sonoma) or later. Universal — Apple Silicon and Intel. Your
earbuds must already be paired in System Settings → Bluetooth; BudSwitch switches between
devices you've paired, it doesn't pair them.

---

## What it does

| Trigger | Action |
|---|---|
| Audio starts from an allowlisted app | Buds connect to the Mac |
| Mac idle 5 minutes, nothing playing | Buds released — your phone can take them |
| Mac sleeps or locks | Buds released immediately |
| **⌃⌥⌘B** from anywhere | Toggle, always wins |

The menubar icon is filled when the buds are on your Mac, dimmed when they're not.

### Guards

These exist because the naive version of each one was wrong:

- **Never releases while audio is playing.** Idle is measured from keyboard and mouse
  input — and watching a film is exactly when you touch neither. Playing audio counts as
  activity, so the buds stay put, and the timer re-arms so they still go to your phone
  once playback actually ends.
- **Never releases during a call.** Detected via a live audio *input*, since dropping the
  link takes your microphone with it.
- **Pausing doesn't release.** Only idle, sleep and lock do.
- **Sustained audio only.** Playback must run for 2 seconds continuously, so notification
  chimes and UI sounds don't yank your buds off your phone.
- **10-second cooldown** after every switch, so triggers can't fight each other.

---

## Configuration

Most of it is in the menubar panel: the device picker, "Switch automatically", the global
shortcut (click it and press new keys), and an on/off toggle for each.

The rest is `defaults`, applied on next launch:

```bash
defaults write com.budswitch.mac idleMinutes -int 15
```

| Key | Default | What it does |
|---|---|---|
| `idleMinutes` | `5` | Minutes idle before releasing (1–30) |
| `allowlist` | see below | Bundle IDs allowed to trigger a connect |
| `allowlistEnabled` | `true` | `false` lets *any* audio trigger a connect |
| `automationEnabled` | `true` | Master switch for all automatic triggers |
| `showHUD` | `true` | The overlay shown when you press the shortcut |
| `menubarSymbol` | `headphones` | Any SF Symbol name |
| `hotkeyEnabled` | `true` | Global shortcut on/off |

Default allowlist: Brave, Spotify, Music, Safari, Chrome, Zoom, Slack, Teams.

```bash
defaults write com.budswitch.mac allowlist -array com.brave.Browser com.spotify.client
```

---

## Building

```bash
./build.sh                  # → build/BudSwitch.app
./package.sh dmg            # → dist/BudSwitch-<version>.dmg
```

`build.sh` compiles a universal binary with `swiftc` directly — no Xcode project. If
`xcodebuild` complains about the developer directory:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

**Always launch via `open`, not by running the binary.** A bare executable is killed by
TCC on its first IOBluetooth call, regardless of signing. Only a `.app` launched through
LaunchServices gets Bluetooth access.

### Layout

```
BudSwitch/
  App/         BudSwitchApp (MenuBarExtra entry), AppState
  Bluetooth/   BluetoothController (connect/disconnect), DeviceStore
  Monitors/    AudioRouteProbe, AudioMonitor, IdleMonitor,
               PowerMonitor, AppFocusMonitor
  Core/        Logger, Arbiter (trigger priority), Hotkey
  UI/          MenuView, HUD, ShortcutRecorder
Resources/     Info.plist, AppIcon.icns, makeicon.swift
```

### Logs

Every state transition is logged. Use `log stream`, not `log show` — the log store lags by
minutes and will make you think things are broken when they aren't:

```bash
log stream --predicate 'subsystem == "com.budswitch.mac"' --level debug
```

---

## How it works

Three decisions carry most of the design.

**Connection state comes from CoreAudio, not IOBluetooth.** `openConnection()` creates a
*baseband* link — a successful return doesn't mean audio routes to the Mac — and
`isConnected()` is cached and goes stale. CoreAudio device UIDs embed the Bluetooth MAC
(`AA-BB-CC-DD-EE-FF:output`), so matching the default output UID against the device address
gives a trustworthy signal. It needs no entitlement and triggers no permission prompt.

**Multipoint devices take a shortcut.** If the buds already hold an audio link to this Mac,
there's nothing to negotiate — switching is just moving the system output. That's **~6ms**,
versus 1.8–6.8s through Bluetooth. Detection is free: a device only appears in CoreAudio's
output list while it holds a link, so "present but not the default output" *is* the
multipoint signal.

**Non-multipoint devices get retries.** A real Bluetooth negotiation, 3 attempts with
0.5s/1s backoff, judged by whether audio actually arrived. Measured connects have ranged
1.8s to 6.8s on the same hardware, so a single attempt isn't enough.

### Gotchas worth knowing

- `IOBluetoothDevice(addressString:)` can block **indefinitely** when the device is
  unreachable — not just slowly. Constructed once per address and cached, off the hot path.
- Virtual audio devices (Background Music, Teams) can become the default output and mask
  real hardware. They're excluded from playback detection and flagged in the UI.
- The global shortcut uses `RegisterEventHotKey`, not `NSEvent.addGlobalMonitorForEvents`.
  The latter asks for the entire system keystroke stream and is gated behind Accessibility;
  the former registers one combination and needs no permission at all.

---

## Status

Working and in daily use. The remaining open question is the **phone → Mac steal**: whether
`openConnection()` can take the link from a phone that currently holds non-multipoint buds.
It can't be tested with a multipoint headset — those simply hold both links, which is the
opposite situation. See [docs/spike-results.md](docs/spike-results.md).

The Mac → phone direction is solid and independent of that answer.

Not built yet: launch at login (`SMAppService`), a log viewer in settings, and the optional
Android companion that would release from the phone side.
