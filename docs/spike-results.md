# Phase 0 spike results

Date: 2026-08-08
Machine: macOS 26.5.2 (25F84), Apple Swift 6.3.1, Xcode 26.6 installed
Test device: **Nothing Ear** (`aa-bb-cc-dd-ee-ff`) as a stand-in for the Buds4 Pro, which
are not yet paired to this Mac. Same code path — the Bluetooth and CoreAudio APIs are
model-agnostic.

## Headline

Connect and disconnect both work reliably from the GUI.

**Update 2026-08-11 — answered with real Buds4 Pro.** The Mac *can* take the buds: a
connect while the buds were idle succeeded and the route followed in 1.7s. What the Mac
**cannot** do is hand them back — releasing drops the link and the buds sit idle until
something connects to them. A Samsung phone does not claim them on its own, so the
phone→Mac direction is complete but Mac→phone requires a manual reconnect on the phone.
That is the gap the Android companion was always meant to fill. See "The remaining gap"
at the end.

The original caveat, written while only a multipoint stand-in was available:

> **The stand-in cannot answer the spike question.** The Nothing Ear supports
> **multipoint**. When the Mac connects while the phone is playing, the buds simply hold
> both links — the Mac never has to take anything. The Buds4 Pro's defining limitation is
> that they *cannot* do this for non-Samsung devices, which is the entire reason BudSwitch
> exists.
>
> A connect that succeeds against a multipoint headset while the phone is playing is
> therefore **not** evidence that the Mac can steal a non-multipoint link. It only shows
> the Mac can join a second link that was available anyway.
>
> No headset currently paired to this Mac (Nothing Ear, Jabra Elite 75t) can reproduce
> non-multipoint contention. **The steal question stays open until the Buds4 Pro are
> paired to both the Mac and the phone.**

## Measured timings

From `os.Logger`, subsystem `com.budswitch.mac`. Two full disconnect→reconnect cycles:

All against the **Nothing Ear (multipoint)**, so these measure *uncontested* connects —
see the caveat above.

| Run | Action | IOBluetooth call | Route settle | **Total** | Result |
|---|---|---|---|---|---|
| 1 | Disconnect | 2.91s | 0.22s | **3.13s** | `kIOReturnSuccess` |
| 1 | Connect | 0.94s | 0.87s | **1.81s** | `kIOReturnSuccess` |
| 2 | Disconnect | — | — | **3.73s** | `kIOReturnSuccess` |
| 2 | Connect | — | — | **3.35s** | `kIOReturnSuccess` |
| 3 (GUI, phone playing) | Disconnect | 0.00s | 0.38s | **0.38s** | `kIOReturnSuccess` |
| 3 (GUI, phone playing) | Connect | 3.02s | 1.43s | **4.45s** | `kIOReturnSuccess` |

Every attempt succeeded. Two things stand out:

**Connect has gotten monotonically slower: 1.81s → 3.35s → 4.45s.** Only the first beat the
2s target and the latest is more than double it. Four samples is too few to call it a
trend, but it is the wrong direction and worth watching. Retry/backoff in Phase 1 is
load-bearing, not defensive.

**Disconnect is wildly variable: 0.38s to 3.73s**, a 10x spread on the same operation. In
run 3 `closeConnection()` returned in ~0ms while earlier runs blocked for ~3s. Do not tune
any timing constant against this sample size — run the scripted 10-iteration acceptance
test first.

## Answers to the Phase 0 questions

**Does `pairedDevices()` work?** Yes — returns all 5 paired devices with address, name and
cached connection state. Addresses come back dash-separated and lowercase
(`aa-bb-cc-dd-ee-ff`).

**Does `closeConnection()` release the device?** Yes. The CoreAudio default output flipped
to MacBook Pro Speakers within 0.22s of the call returning. Whether the phone then *grabs*
the buds unaided is untested — that needs the phone.

**Does `openConnection()` steal the link from the phone?** **Still unanswered, and not
answerable with the devices currently paired.** A GUI test was run with the phone actively
playing, and connect succeeded in 4.45s — but the Nothing Ear is multipoint, so the buds
held both links rather than the Mac taking one. That is the opposite of the Buds4 Pro
situation. See the caveat at the top.

## Findings that changed the design

### 1. A bare CLI cannot touch IOBluetooth — it must be an `.app`

Any IOBluetooth call from a plain executable is killed instantly:

```
TCC: "This app has crashed because it attempted to access privacy-sensitive data
without a usage description... NSBluetoothAlwaysUsageDescription"
```

It aborts on the *first* IOBluetooth call (`IOBluetoothHostController.default()`), before
`pairedDevices()` is reached. Embedding the plist via `-sectcreate` **and** ad-hoc signing
was still not enough.

What works: a real `.app` bundle **launched through LaunchServices** (`open BudSwitch.app`).
Running the same binary directly still aborts. This is why the spike was built as a menubar
app rather than the CLI the original plan called for.

### 2. `openConnection()` is baseband-only — the return code is not the success signal

The SDK header is explicit that it creates *"a baseband connection"*. A `kIOReturnSuccess`
says an ACL link exists, not that A2DP audio routes to the Mac. So the app judges success
by the **audio route**, not the return code, and reports a distinct `baseband only (no
audio)` outcome for the case where the link comes up but audio never follows.

Also handled: since 10.7 an already-open link returns an error rather than being masked
into success. Treated as success when the route is already correct.

### 3. CoreAudio device UIDs embed the MAC address

`AA-BB-CC-DD-EE-FF:output`. This makes connection state answerable through CoreAudio alone
— no IOBluetooth, no entitlement, no TCC prompt — and avoids the cached, stale-prone
`isConnected()`. `AudioRouteProbe` is built on this and is the source of truth for the
menubar icon and for verifying every switch.

### 4. Virtual audio devices are a real hazard on this machine

**Background Music** (`BGMDevice`) and **Microsoft Teams Audio**
(`MSLoopbackDriverDevice_UID`) are both installed and report `transport=virt`. If either
becomes the default output it proxies the real hardware, and reading playback state off the
default device silently reports the virtual device instead. The menu surfaces a warning
when the default output is virtual; Phase 2's playback detection must handle this
explicitly or it will fail silently.

### 5. Callbacks must not be forced onto the main thread

First cut delivered completions via `DispatchQueue.main.async`. That deadlocks any caller
that blocks the main thread awaiting the result — caught via `sample` showing the main
thread parked in `semaphore_wait` with callbacks never firing. `BluetoothController` now
delivers on its background queue and `AppState` hops to `@MainActor` itself.

## Decision gate

Phase 2's phone→Mac trigger still hinges on the untested steal. Everything else built here
— the menubar shell, device picker, route probe, retry surface — holds regardless of that
answer, so none of it is wasted.

**To finish the spike — requires the Buds4 Pro.** No currently paired headset can answer
it, because both are multipoint. Once the Buds4 Pro are paired to *both* the Mac and the
phone:

1. Select them in the menubar device picker (the app stores one address; pick the Buds4
   Pro instead of the Nothing Ear).
2. Play audio on the phone through the buds.
3. Click **Bring to Mac** and read the result line.

Three possible outcomes:

- *success* → the Mac can steal a non-multipoint link. Phase 2 proceeds as designed.
- *baseband only (no audio)* → the link opens but the phone keeps the A2DP profile. The
  Android companion must release first. This is the outcome the `basebandOnly` case exists
  to catch, and the most likely one given Buds4 Pro have no multipoint for non-Samsung
  devices.
- *failed / timed out* → the phone holds the link outright. Companion required.

Until then, treat the phone→Mac direction as **unproven**. The Mac→phone release direction
is solid and independent of this result.


---

## The remaining gap (2026-08-11)

Tested with real **Galaxy Buds4 Pro** (paired to a Samsung Galaxy phone and this Mac).

| Direction | Works? | Detail |
|---|---|---|
| Buds → Mac | **Yes** | Connect succeeded, route followed in 1.7s |
| Mac → buds released | **Yes** | `closeConnection()` in 0.22s, link drops cleanly |
| Buds → phone | **No** | Buds sit idle; the phone does not claim them |

**Why.** BudSwitch can only *release* the buds. It has no way to make the phone connect —
that has to be initiated from the phone side. The Buds4 Pro have no multipoint for
non-Samsung devices, and Samsung Auto Switch is Galaxy-only, so nothing on the phone is
watching for the buds to become free.

**What would fix it,** roughly in order of effort:

1. **Play something on the phone.** Starting audio makes Android connect to its last
   device. Zero code, but it is a manual step.
2. **A Bluetooth routine on the phone.** Samsung Modes and Routines (or Tasker) can
   trigger "connect to Buds4 Pro" on an event — e.g. when the buds disconnect, or on a
   schedule. Still no code, and closer to automatic.
3. **The Android companion.** A small app watching for the buds to become available and
   connecting via `BluetoothAdapter`. This is what the original spec anticipated, and it
   is the only route to genuinely seamless.

Nothing on the Mac side can close this gap — worth stating plainly so it is not mistaken
for a BudSwitch bug.
