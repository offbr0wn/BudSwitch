## Install

1. Download **BudSwitch-__VERSION__.dmg** below.
2. Drag **BudSwitch** onto **Applications**.
3. Open it. macOS will block the first launch — see below.

> [!IMPORTANT]
> **macOS will refuse to open BudSwitch the first time.** It isn't notarized, so you get
> *"Apple could not verify BudSwitch is free of malware"* with only **Done** and
> **Move to Bin**. Click **Done** — do not move it to the bin.
>
> **On macOS 15 Sequoia and later**, open **System Settings → Privacy & Security**, scroll
> to the bottom, and click **Open Anyway** next to the BudSwitch message. Confirm, and it
> launches. Once per machine.
>
> **On macOS 14 Sonoma**, right-click the app in Applications → **Open** → **Open**.
>
> Prefer one command? This does the same thing:
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/BudSwitch.app
> ```
>
> Notarization needs a paid Apple Developer account. The app **is** code-signed and its
> signature verifies — it just isn't registered with Apple.

Allow **Bluetooth** when asked — it's the only permission BudSwitch needs.

> [!NOTE]
> **"Send to phone" releases the buds; it can't make your phone grab them.** Connecting has
> to be initiated from the phone, so on earbuds without multipoint they sit idle until
> something connects. Start playing audio on your phone and it picks them up straight away.

**Requirements:** macOS 14 (Sonoma) or later. Universal — Apple Silicon and Intel. Your
earbuds must already be paired in System Settings → Bluetooth.
