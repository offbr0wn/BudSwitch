import SwiftUI

/// The menubar panel.
///
/// One job: answer "where are my earbuds right now?" at a glance. The route line is the
/// centrepiece — it shows the buds sitting at one end of a Mac↔Phone track, which is the
/// literal thing the app manages. Everything else stays quiet so that reads instantly.
struct MenuView: View {
    @ObservedObject var state: AppState

    private let width: CGFloat = 288

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            RouteLine(
                isHere: state.isRouted,
                isBusy: state.isBusy,
                isDualLinked: state.isLinkedButIdle
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            actionButton
            if state.hotkeyConflicted { hotkeyConflictRow }
            automationRow
            if state.outputIsVirtual { virtualWarning }
            Divider().padding(.vertical, 10)
            deviceList
            if let latest = state.history.first {
                Divider().padding(.vertical, 8)
                lastAttempt(latest)
            }
            Divider().padding(.vertical, 8)
            hotkeyRow
            Divider().padding(.vertical, 8)
            footer
        }
        .padding(.vertical, 12)
        .frame(width: width)
        .onAppear {
            // Permission may have been granted since launch; re-check on every open
            // rather than trusting a value cached at startup.
            state.refreshHotkeyStatus()
            state.refreshRoute()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.selectedName ?? "No device selected")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text(statusLine)
                    .font(.system(size: 11))
                    // The one line worth reading first, so it gets full contrast while
                    // everything below stays secondary.
                    .foregroundStyle(state.isRouted ? .primary : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // A live playback dot: the app's whole premise is reacting to audio, so
            // showing that it can see audio right now makes the automation legible.
            if state.isPlaying {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                    Text("audio")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var statusLine: String {
        guard state.selectedAddress != nil else { return "Pick a device below" }
        if state.isBusy { return state.isRouted ? "Releasing…" : "Connecting…" }
        if state.isRouted { return "Playing on this Mac" }
        // Multipoint: still attached here, just not the active output.
        if state.isLinkedButIdle { return "Connected — ready to switch instantly" }
        return "Available to your phone"
    }

    // MARK: - Action

    /// Deliberately understated. The route line is the thing to look at; the button is
    /// just how you act on it, so it stays quiet rather than competing.
    private var actionButton: some View {
        Button(action: { state.toggle() }) {
            HStack(spacing: 6) {
                if state.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
                Text(actionTitle)
                    .font(.system(size: 12, weight: .medium))

                // Teach the shortcut where the action is, rather than hiding it in a
                // settings screen the user has no reason to open.
                if state.isHotkeyEnabled, !state.isBusy {
                    Text(state.hotkeyDisplay)
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(state.isBusy || state.selectedAddress == nil)
        .padding(.horizontal, 16)
    }

    /// Names the action only. The header already reports progress, and repeating
    /// "Connecting…" in both places was noise rather than reassurance.
    private var actionTitle: String {
        if state.isRouted { return "Send to phone" }
        // Linked already: this is the instant route-only path, so don't imply a wait.
        return state.isLinkedButIdle ? "Switch to Mac" : "Bring to Mac"
    }

    /// The automatic-switching toggle, plus a plain-language line explaining what the
    /// automation last did. Without the explanation, automatic switches feel arbitrary.
    private var automationRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: $state.isAutomationEnabled) {
                Text("Switch automatically")
                    .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)

            if state.isAutomationEnabled {
                Text(state.lastAutomationNote ?? "Connects when Brave plays, releases when idle")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    /// Shown when the combination could not be registered — another app already owns it.
    /// Without this the shortcut would just silently do nothing.
    private var hotkeyConflictRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("\(state.hotkeyDisplay) is taken by another app — pick another")
        }
        .font(.system(size: 10))
        .foregroundStyle(.orange)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Warnings

    /// Background Music and Teams sit in front of the real hardware, so the route reading
    /// below them can't be trusted. Say what it means, not just that it happened.
    private var virtualWarning: some View {
        Label {
            Text("\(state.currentOutputName) is handling audio — route may read wrong")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.system(size: 10))
        .foregroundStyle(.orange)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: - Devices

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("DEVICE")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.6)
                Spacer()
                Button("Refresh") { state.refreshDevices() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    // Small text needs a bigger hit target than its glyphs.
                    .contentShape(Rectangle())
                    .help("Re-scan paired Bluetooth audio devices")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            ForEach(state.pairedDevices) { device in
                DeviceRow(
                    device: device,
                    isSelected: device.address == state.selectedAddress,
                    isLive: state.isLive(device)
                ) {
                    state.select(address: device.address, name: device.name)
                }
            }
        }
    }

    // MARK: - Telemetry

    /// Timings are data, so they get a monospaced face — it makes 1.81s and 3.35s
    /// directly comparable across attempts.
    private func lastAttempt(_ record: SpikeRecord) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(record.outcome.isNoOp
                      ? Color.secondary
                      : (record.outcome.isSuccess ? Color.green : Color.orange))
                .frame(width: 5, height: 5)

            Text(record.attempts > 1
                 ? "\(record.action.rawValue) · \(record.outcome.label) · try \(record.attempts)"
                 : "\(record.action.rawValue) · \(record.outcome.label)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            // Sub-second switches are the multipoint fast path; milliseconds tell that
            // story where "0.00s" would just look like a rounding error.
            Text(record.elapsed < 1
                 ? String(format: "%.0fms", record.elapsed * 1000)
                 : String(format: "%.2fs", record.elapsed))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(record.elapsed <= 2.0 ? .secondary : .primary)
        }
        .padding(.horizontal, 16)
    }

    private var hotkeyRow: some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { state.isHotkeyEnabled },
                set: { state.isHotkeyEnabled = $0 }
            )) {
                Text("Global shortcut")
                    .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)

            Spacer(minLength: 4)

            if state.hotkeyCombo != .default {
                Button {
                    state.hotkeyCombo = .default
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Reset to \(Hotkey.Combo.default.display)")
            }

            ShortcutRecorder(
                combo: Binding(
                    get: { state.hotkeyCombo },
                    set: { state.hotkeyCombo = $0 }
                ),
                isEnabled: state.isHotkeyEnabled
            )
            .frame(width: 92, height: 20)
            .help(state.isHotkeyEnabled
                  ? "Click, then press the keys you want"
                  : "Turn on the global shortcut to change it")
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            // Diagnostics live here, at the lowest weight on the panel: useful when
            // something looks wrong, ignorable the rest of the time.
            Text(footerText)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(footerDetail)

            Spacer(minLength: 4)

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 16)
    }

    private var footerText: String {
        guard let stats = state.reliability, stats.total > 1 else {
            return state.currentOutputName
        }
        return "\(state.currentOutputName) · \(stats.successes)/\(stats.total)"
    }

    /// Tooltip carries the fuller picture rather than spending panel rows on it.
    private var footerDetail: String {
        var parts = ["Output: \(state.currentOutputName)"]
        if let stats = state.reliability, stats.total > 1 {
            parts.append("\(stats.successes) of \(stats.total) switches succeeded")
            if stats.needsRetryCount > 0 {
                parts.append("\(stats.needsRetryCount) needed a retry")
            }
        }
        if let worst = state.slowestSwitch {
            parts.append(String(format: "slowest %.1fs", worst))
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Route line

/// The signature element: buds shown sitting at one end of a Mac↔Phone track.
///
/// Chosen over a plain "connected" dot because the app's whole job is *which side holds
/// the buds* — this shows that directly, and the puck animating along the track makes the
/// handoff legible.
private struct RouteLine: View {
    let isHere: Bool
    let isBusy: Bool
    /// Multipoint: linked to this Mac *and* the phone at once.
    var isDualLinked = false

    @State private var pulse = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                endpoint(symbol: "laptopcomputer", active: isHere || isDualLinked)
                track
                endpoint(symbol: "iphone", active: !isHere || isDualLinked)
            }
            .frame(height: 26)

            HStack(spacing: 0) {
                caption("This Mac", active: isHere, alignment: .leading)
                Spacer(minLength: 0)
                caption("Phone", active: !isHere, alignment: .trailing)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: isHere)
        .onChange(of: isBusy) { _, busy in
            // Respect the accessibility setting rather than pulsing regardless.
            pulse = busy && !reduceMotion
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var track: some View {
        GeometryReader { geo in
            ZStack(alignment: puckAlignment) {
                Capsule()
                    .fill(isDualLinked ? AnyShapeStyle(Color.accentColor.opacity(0.35)) : AnyShapeStyle(.quaternary))
                    .frame(height: 2)
                    .frame(maxHeight: .infinity)

                // The buds themselves, parked at whichever end currently holds them —
                // or centred when linked to both at once.
                Image(systemName: "earbuds")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHere || isDualLinked ? Color.accentColor : Color.secondary)
                    .padding(3)
                    .background(Circle().fill(.background))
                    .overlay(
                        Circle().strokeBorder(
                            isHere || isDualLinked
                                ? Color.accentColor
                                : Color.secondary.opacity(0.5),
                            lineWidth: 1.5
                        )
                    )
                    // Pulse while switching. A connect can take several seconds, and a
                    // static line makes the app look hung exactly when it is working.
                    .scaleEffect(isBusy && pulse ? 1.18 : 1.0)
                    .opacity(isBusy && pulse ? 0.55 : 1)
                    .animation(
                        isBusy
                            ? .easeInOut(duration: 0.65).repeatForever(autoreverses: true)
                            : .default,
                        value: pulse
                    )
                    .frame(maxHeight: .infinity)
            }
            .frame(width: geo.size.width)
        }
        .frame(height: 26)
    }

    /// Centred while dual-linked, otherwise parked at whichever side holds the audio.
    private var puckAlignment: Alignment {
        if isDualLinked { return .center }
        return isHere ? .leading : .trailing
    }

    private func endpoint(symbol: String, active: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(active ? Color.primary : Color.secondary.opacity(0.45))
            .frame(width: 26)
    }

    private func caption(
        _ text: String,
        active: Bool,
        alignment: Alignment
    ) -> some View {
        Text(text)
            .font(.system(size: 9, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? Color.primary : Color.secondary.opacity(0.6))
            .frame(width: 60, alignment: alignment)
    }
}

// MARK: - Device row

private struct DeviceRow: View {
    let device: BluetoothController.PairedDevice
    let isSelected: Bool
    /// Whether this device currently holds the audio route — independent of selection.
    let isLive: Bool
    let select: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 7) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))

                Text(device.name)
                    .font(.system(size: 12))
                    .lineLimit(1)

                Spacer(minLength: 4)

                if isLive {
                    Text("live")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(device.address)
    }
}
