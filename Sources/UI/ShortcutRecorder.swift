import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click it, press a combination, done.
///
/// Built on `NSView` rather than SwiftUI's focus handling because a recorder must swallow
/// keys the app would otherwise act on — including ⌘Q — and only `performKeyEquivalent`
/// intercepts those before the menu system sees them.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var combo: Hotkey.Combo
    var isEnabled: Bool

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = { combo = $0 }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.combo = combo
        view.isEnabledForRecording = isEnabled
        view.needsDisplay = true
    }
}

final class RecorderView: NSView {

    var combo: Hotkey.Combo = .default
    var isEnabledForRecording = true
    var onCapture: ((Hotkey.Combo) -> Void)?

    private var isRecording = false {
        didSet {
            needsDisplay = true
            guard isRecording, let window else { return }
            // The menu-bar panel is non-activating, so it is not key when clicked and a
            // non-key window does not deliver keyDown to its first responder — the
            // recorder would sit on "Press keys…" and capture nothing. Ask for key status
            // explicitly, then take first responder.
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(self)
        }
    }

    /// Set briefly when a rejected combination is pressed, to explain the refusal.
    private var rejection: String?

    override var acceptsFirstResponder: Bool { isEnabledForRecording }
    override var isFlipped: Bool { true }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        guard isEnabledForRecording else { return }
        rejection = nil
        isRecording.toggle()
    }

    /// Intercepts before the menu system, so ⌘Q and friends can be recorded rather than
    /// quitting the app mid-capture.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        return capture(event)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording, capture(event) else {
            super.keyDown(with: event)
            return
        }
    }

    private func capture(_ event: NSEvent) -> Bool {
        // Escape cancels without changing anything.
        if event.keyCode == UInt16(kVK_Escape),
           event.modifierFlags.intersection(Hotkey.Combo.relevant).isEmpty {
            isRecording = false
            return true
        }

        let mods = event.modifierFlags.intersection(Hotkey.Combo.relevant)
        let candidate = Hotkey.Combo(keyCode: event.keyCode, modifiers: mods.rawValue)

        // A bare letter would fire mid-sentence. Refuse it and say why, rather than
        // accepting a binding that makes the keyboard unusable.
        guard candidate.isSafe else {
            rejection = "Use two of ⌃⌥⌘"
            needsDisplay = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.rejection = nil
                self?.needsDisplay = true
            }
            return true
        }

        combo = candidate
        onCapture?(candidate)
        isRecording = false
        return true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let rounded = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)

        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            rounded.fill()
            NSColor.controlAccentColor.setStroke()
            rounded.lineWidth = 1.5
            rounded.stroke()
        } else {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            rounded.fill()
        }

        let text: String
        let color: NSColor
        if let rejection {
            text = rejection
            color = .systemOrange
        } else if isRecording {
            text = "Press keys…"
            color = .controlAccentColor
        } else {
            text = combo.display
            color = isEnabledForRecording ? .secondaryLabelColor : .tertiaryLabelColor
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}
