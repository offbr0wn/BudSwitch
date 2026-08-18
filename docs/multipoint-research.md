# Can we enable multipoint on the Buds4 Pro from a Mac?

Short answer: **not proven, and probably not from the Mac alone.** This records what the
forum workarounds actually do and what the protocol offers, so nobody has to re-derive it.

## What the Windows "workaround" actually is

Read in full ([XDA thread](https://xdaforums.com/t/how-to-samsung-multi-control-with-non-samsung-windows-pc.4640205/),
smitel, Nov 2023). The method is:

1. Download **Samsung System Support Service** 1.5.5900.0 from the Microsoft Update Catalog.
2. Use Device Manager to force that driver onto an unrelated "Other Device" — the author
   pairs a Galaxy phone to create candidates like `CONTINUITY_MSG_SPP`.
3. That pulls in **Samsung Settings** and **Samsung Cloud Sync** from the Microsoft Store.
4. If the backend crashes, **patch the binary in a hex editor** — write `0xc3` (an x86
   `ret`) at offset `0x68140` of `SamsungSystemSupportEngine.exe` to stub out a function.
5. Register the patched binary as a Windows service and reboot.
6. Sign in to a **Samsung Account**, which installs Samsung Continuity Service.

Every step is Windows-specific: Microsoft Update Catalog, Device Manager driver forcing,
Microsoft Store apps, `sc create`, and an x86 binary patch. None of it has a macOS
equivalent — there is no Samsung System Support Service for macOS to install, force, or
patch.

It also confirms what this feature actually is. Note step 6: it requires a **Samsung
Account**. The buds are not being unlocked; the PC is being dressed up as a Galaxy Book so
Samsung's account-bound service will talk to it.

The threads describe **Samsung Multi Control**, not multipoint. Those are
different things:

- **Multipoint** — the earbuds hold two audio links at once and switch between them. The
  Buds4 Pro firmware supports this only between Samsung Galaxy devices.
- **Multi Control / Auto Switch** — a *Samsung ecosystem* feature. The phone, tablet and
  Galaxy Book coordinate over a Samsung account and tell the buds where to go. The buds are
  followers, not the decision-maker.

The Windows workaround does not unlock a firmware capability. It makes a non-Samsung PC
look like a Galaxy Book to that ecosystem, and the coordination still runs through
Samsung's software and account. That is why it needs Windows-specific Samsung components.

## What the protocol exposes

From [GalaxyBudsClient](https://github.com/timschneeb/GalaxyBudsClient), the most complete
open reverse-engineering of the Galaxy Buds SPP protocol:

| Message | ID | Direction | Status |
| :-- | :-- | :-- | :-- |
| `AUTO_SWITCH_AUDIO_OUTPUT` | 115 (0x73) | — | **Declared, never sent.** No encoder, no UI, no caller. |
| `MULTIPOINT_INFO` | 118 (0x76) | buds → host | Decoded only. Reports focus state and streaming mask. |

`MULTIPOINT_INFO` carries `AudioFocusStates` (foreground/background), `MultipointStates`
(`HaveDevices` / `HaveOneDevice`) and a `StreamingMaskFlags` bitfield for
A2DP/HFP/CIS/BIS. Useful telemetry — it tells you what the buds think is going on — but it
is a **report, not a control**.

Re-checked 2026-08-18 against the repository tree rather than code search:
`AUTO_SWITCH_AUDIO_OUTPUT` appears **only in the enum declaration** — no encoder, no
caller, nothing. `MULTIPOINT_INFO` appears only in its decoder. GalaxyBudsClient ships
**no setter for either**. If a working "turn multipoint on" command existed, that project
would have it.

## What this means for BudSwitch

**Worth building** — `MULTIPOINT_INFO` is readable over SPP and would let the app show
*why* a switch failed ("phone is holding the audio profile") instead of a bare timeout.
That is a real UX improvement over what BudSwitch does today.

**Not worth promising** — sending `AUTO_SWITCH_AUDIO_OUTPUT` is a guess. Nobody has
published a payload for it, and firmware that rejects the Samsung handshake will likely
ignore it. It could be tried as an experiment; it should not be advertised as a feature.

**Out of scope** — replicating Samsung Multi Control would mean impersonating a Galaxy
device against Samsung's account-bound service. That is the "no Samsung protocol spoofing"
constraint the project set at the start, and it has not changed.

## The honest alternative

BudSwitch plus a phone-side routine already produces multipoint-like behaviour on hardware
that does not support it. See [phone-routine.md](phone-routine.md). Measured end to end
with real Buds4 Pro: release in 0.32s, reconnect in 2.57s.
