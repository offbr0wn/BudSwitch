# Getting the buds back on your phone automatically

BudSwitch releases the buds; it can't make your phone connect to them — that has to come
from the phone. On a Samsung Galaxy, **Modes and Routines** can close that gap without
any code.

Pick **one** of the routines below. Start with the first: it's the simplest and covers
the common case.

---

## Before you start

Open **Settings → Modes and Routines**. If it isn't there, install **Modes and Routines**
from the Galaxy Store (it's a Samsung app, free, preinstalled on most recent phones).

Have your Buds4 Pro paired to the phone already — a routine can only connect to a device
you've paired.

---

## Routine 1 — reconnect when you unlock your phone

Best default. You pick your phone up, the buds are back. Nothing to remember.

1. **Modes and Routines → Routines** tab → **+** (top right)
2. **If** → **Phone status** → **Screen unlocked** *(some builds: "Unlocking phone")*
3. **Then** → search **Bluetooth** → **Turn Bluetooth on**
   - Add a second action: **Connect Bluetooth device** → **your Buds4 Pro**
   - If your build has no "Connect Bluetooth device" action, use Routine 2 instead.
4. Name it something like *Buds back to phone*, **Save**.

> Add a condition if it's too eager: under **If**, add **Time** and limit it to the hours
> you actually use the buds, or add **Place → Not at work**.

---

## Routine 2 — reconnect when you open a music app

Fires exactly when you want audio, and never otherwise.

1. **Modes and Routines → Routines** → **+**
2. **If** → **App** → **App opened** → pick **Spotify** (add YouTube Music, Podcasts etc.
   if you use them)
3. **Then** → **Connect Bluetooth device** → **your Buds4 Pro**
4. Save.

This one has the fewest false positives. If a routine ever grabs the buds at the wrong
moment, switch to this.

---

## Routine 3 — reconnect when the buds go idle

Closest to fully automatic, but the most likely to fight with BudSwitch.

1. **Modes and Routines → Routines** → **+**
2. **If** → **Bluetooth** → **Bluetooth device disconnected** → **your Buds4 Pro**
3. **Then** → **Wait** → 30 seconds *(important — see the warning)*
4. **Then** → **Connect Bluetooth device** → **your Buds4 Pro**
5. Save.

> [!WARNING]
> **The delay matters.** Without it, the phone grabs the buds the instant your Mac
> releases them — including the moment *before* your Mac takes them for a call or a video,
> so the two devices tug back and forth. Thirty seconds is longer than BudSwitch's
> 10-second cooldown, which keeps them out of each other's way.
>
> If you still see a tug of war, raise the delay or switch to Routine 1 or 2.

---

## If "Connect Bluetooth device" isn't offered

Some One UI builds only expose *turn Bluetooth on/off*, not *connect to a specific
device*. Two options:

- **Bixby Routines** (older One UI) has the same feature under a different name.
- **[Tasker](https://tasker.joaoapps.com/)** (paid, ~£3) can do it on any Android:
  profile **Event → Display Unlocked**, task **Net → Bluetooth Connect →** the buds' MAC address
  (Settings → About phone → Status, or from the Mac: `system_profiler SPBluetoothDataType`).

---

## Checking it works

1. On the Mac, click **Send to phone** in BudSwitch (or press <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd><kbd>B</kbd>).
2. Trigger the routine — unlock the phone, or open Spotify, depending on which you built.
3. The buds should connect within a couple of seconds.

If nothing happens, check **Modes and Routines → Routines → (your routine) → History**;
it records whether the routine actually fired.

---

## What this does and doesn't fix

It gets the buds back to your phone without opening Bluetooth settings. It does **not**
make the switch instant — there's a trigger and a connect, so expect a second or two.

Truly seamless would need a companion app on the phone watching for the buds to become
free. That's a real project rather than a setting; see
[spike-results.md](spike-results.md) for why the Mac alone can't do it.
