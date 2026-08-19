import AppKit
import SwiftUI

/// The compact popover shown from the menu-bar icon — an AirPods-in-Control-
/// Center style quick view. Detailed controls live behind the "Settings…"
/// button, which opens the detail window.
struct MenuPopoverView: View {
    @Bindable var bluetooth: BluetoothManager
    @ObservedObject var switching: AppState
    let openDetail: () -> Void

    private var tint: Color { bluetooth.connectedModel?.tint ?? .blue }

    var body: some View {
        VStack(spacing: 16) {
            // `bluetooth.isConnected` means the SPP data channel is open — the path to
            // battery, ANC and EQ. The earbuds can be perfectly connected for audio with
            // no SPP channel, so using it for the header showed "No Buds Connected" while
            // audio was playing through them. Trust the audio route for presence, and let
            // the SPP state decide only whether the detail controls appear.
            if switching.isRouted || bluetooth.isConnected {
                connected
            } else {
                disconnected
                // With no earbuds present the switching card is the only useful control,
                // so it stays visible; when they are connected it sits inside `connected`
                // directly under the device it acts on.
                quickConnect
            }
            footer
        }
        .padding(18)
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .focusEffectDisabled() // no focus ring on the auto-focused default button
    }

    /// Where the earbuds are, and the one button that moves them. Shown whether or not
    /// the SPP channel is up, because switching works without it — the audio route is the
    /// source of truth, not the protocol connection.
    /// Where the earbuds are, and the control that moves them.
    ///
    /// Styled as a grouped card to match the ANC segmented control below it — the earlier
    /// version was bare controls on the popover background and read as detached from the
    /// device it refers to.
    private var quickConnect: some View {
        VStack(spacing: 10) {
            // Mac ——●—— Phone. The filled dot marks the side that currently has the audio,
            // so the row answers "where are my earbuds" before any text is read.
            HStack(spacing: 0) {
                endpoint(symbol: "laptopcomputer", active: switching.isRouted)

                ZStack {
                    Capsule()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: 2)
                    if !switching.isBusy {
                        Circle()
                            .fill(tint)
                            .frame(width: 7, height: 7)
                            .frame(maxWidth: .infinity,
                                   alignment: switching.isRouted ? .leading : .trailing)
                    }
                }
                .frame(height: 12)
                .padding(.horizontal, 8)

                endpoint(symbol: "iphone", active: !switching.isRouted)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: switching.isRouted)

            Button(action: { switching.toggle() }) {
                HStack(spacing: 6) {
                    if switching.isBusy {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                        // Count up rather than show a bare spinner: openConnection blocks
                        // for several seconds and a static spinner reads as a hang.
                        Text(switching.isRouted ? "Releasing… \(switching.busySeconds)s"
                                                : "Connecting… \(switching.busySeconds)s")
                            .monospacedDigit()
                    } else {
                        Image(systemName: switching.isRouted
                              ? "iphone.and.arrow.forward" : "laptopcomputer.and.arrow.down")
                            .font(.system(size: 11))
                        Text(switching.isRouted ? "Send to phone" : "Bring to Mac")
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .disabled(switching.isBusy || switching.selectedAddress == nil)

            HStack(spacing: 6) {
                Toggle(isOn: $switching.isAutomationEnabled) {
                    Text("Switch automatically").font(.system(size: 11))
                }
                .toggleStyle(.checkbox)

                Spacer()

                // Reset appears only once the binding differs from the default, so it
                // does not sit there as permanent clutter.
                if switching.hotkeyCombo != .default {
                    Button { switching.hotkeyCombo = .default } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to \(Hotkey.Combo.default.display)")
                }

                // Click it and press keys to rebind. Takes effect immediately — no
                // relaunch, no defaults write.
                ShortcutRecorder(
                    combo: Binding(
                        get: { switching.hotkeyCombo },
                        set: { switching.hotkeyCombo = $0 }
                    ),
                    isEnabled: switching.isHotkeyEnabled
                )
                .frame(width: 86, height: 19)
                .help("Click, then press the keys you want")
            }

            if let note = switching.lastAutomationNote {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12)))
    }

    private func endpoint(symbol: String, active: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(active ? Color.primary : Color.secondary.opacity(0.45))
            .frame(width: 18)
    }

    private var connected: some View {
        VStack(spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: "airpodspro")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    // Fall back to the device BudSwitch has selected: without an SPP
                    // channel the protocol layer has no name to offer, but we still know
                    // which earbuds these are.
                    Text(verbatim: bluetooth.connectedName
                         ?? bluetooth.connectedModel?.rawValue
                         ?? switching.selectedName ?? "Galaxy Buds")
                        .font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle().fill(bluetooth.isConnected ? .green : .yellow)
                            .frame(width: 6, height: 6)
                        // Distinguish "audio works" from "we can also read battery/ANC".
                        // Claiming plain "Connected" with no SPP channel would leave the
                        // empty battery gauges below unexplained.
                        Text(bluetooth.isConnected ? "Connected" : "Audio connected")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            quickConnect

            // Battery, ANC and EQ deliberately live in the detail window rather than
            // here. This panel exists to answer "where are my earbuds" and move them;
            // stacking the full dashboard under that buried the one control it is for.
            Button(action: openDetail) {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                    Text("Settings…")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Divider()
            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                    Text("Quit")
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var disconnected: some View {
        VStack(spacing: 14) {
            Image(systemName: "airpodspro")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No Buds Connected").font(.headline)
            Text("Connect your Galaxy Buds to get started.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: openDetail) {
                Text("Connect").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.vertical, 10)
    }
}
