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

            if bluetooth.isConnected {
                HStack(spacing: 28) {
                    CircularBatteryGauge(level: bluetooth.status.batteryLeft, label: "Left",
                     present: bluetooth.status.batteryLeft > 0 && bluetooth.status.placementLeft != .inCase && bluetooth.status.placementLeft != .inClosedCase,
                     diameter: 76)
                    CircularBatteryGauge(level: bluetooth.status.batteryRight, label: "Right",
                     present: bluetooth.status.batteryRight > 0 && bluetooth.status.placementRight != .inCase && bluetooth.status.placementRight != .inClosedCase,
                     diameter: 76)
                }
            } else {
                // Audio is routing but the SPP channel is not open, so there is no
                // battery or ANC data to show. Offer the action rather than empty dials.
                VStack(spacing: 6) {
                    Text("Battery and controls need a data connection")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Connect") { bluetooth.startAutoConnect() }
                        .controlSize(.small)
                }
            }

            if bluetooth.connectedModel?.supportsANC == true {
                listenMode
                if bluetooth.status.noiseControlMode == .anc {
                    ancStrength
                }
            }

            equalizerRow

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

    private var listenMode: some View {
        let modes: [NoiseControlMode] =
            bluetooth.connectedModel?.supportsAdaptiveANC == true
            ? [.off, .ambient, .adaptive, .anc]
            : [.off, .ambient, .anc]
        return HStack(spacing: 2) {
            ForEach(modes) { mode in
                let selected = bluetooth.status.noiseControlMode == mode
                Button(action: { bluetooth.setNoiseControl(mode) }) {
                    VStack(spacing: 3) {
                        Image(systemName: mode.iconName).font(.system(size: 15))
                        Text(LocalizedStringKey(mode.shortName)).font(.system(size: 9))
                    }
                    .foregroundStyle(selected ? tint : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selected ? Color(nsColor: .controlBackgroundColor) : .clear)
                            .shadow(color: selected ? .black.opacity(0.12) : .clear, radius: 1, y: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12)))
    }

    private var ancStrength: some View {
        HStack(spacing: 10) {
            Text("ANC strength").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Low").font(.system(size: 10)).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { bluetooth.status.ancLevelHigh ? 1.0 : 0.0 },
                set: { bluetooth.setAncLevelHigh($0 >= 0.5) }
            ), in: 0...1, step: 1)
            Text("High").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var equalizerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 13)).foregroundStyle(.secondary)
            Text("Equalizer").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(EqualizerPreset.allCases) { preset in
                    Button { bluetooth.setEqualizer(preset) } label: {
                        Text(LocalizedStringKey(preset.displayName))
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(bluetooth.status.equalizerPreset.displayName))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                }
                .font(.system(size: 12))
                .foregroundStyle(.primary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
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
