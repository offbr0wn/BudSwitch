import AppKit
import SwiftUI

/// The transparent overlay shown when the shortcut fires.
///
/// The hotkey works from any app, so without this a press produces no feedback at all
/// unless the menubar panel happens to be open — and a connect can take several seconds,
/// which reads as "nothing happened". This is modelled on the system volume HUD: centred,
/// blurred, non-interactive, and gone on its own.
@MainActor
final class HUD {

    static let shared = HUD()

    private var window: NSPanel?
    private var dismissWork: DispatchWorkItem?

    private init() {}

    /// What the HUD is currently saying.
    struct Content: Equatable {
        var symbol: String
        var title: String
        var isBusy: Bool

        init(symbol: String, title: String, isBusy: Bool) {
            self.symbol = symbol
            self.title = title
            self.isBusy = isBusy
        }
    }

    /// Shows, or updates in place if already visible.
    ///
    /// Updating rather than restacking matters: a switch goes "Connecting…" → "On this
    /// Mac", and two overlapping panels would flicker.
    func show(_ content: Content, dismissAfter delay: TimeInterval?) {
        let panel = window ?? makePanel()
        window = panel

        // Size to the content: titles range from "On this Mac" to a failure reason, and a
        // fixed width would either clip the long ones or leave the short ones adrift.
        let hosting = NSHostingView(rootView: HUDView(content: content))
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // Guard against a zero fitting size, which would produce an invisible window.
        let fitted = hosting.fittingSize
        let size = NSSize(
            width: max(fitted.width, 120),
            height: max(fitted.height, 34)
        )
        panel.setContentSize(size)
        centre(panel)
        Log.app.debug("HUD size \(Int(size.width), privacy: .public)x\(Int(size.height), privacy: .public)")

        if !panel.isVisible {
            panel.alphaValue = 0
            // orderFrontRegardless: the app is LSUIElement and never becomes active, so
            // orderFront alone would not display it over the focused app.
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }

        dismissWork?.cancel()
        dismissWork = nil

        guard let delay else { return }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func dismiss() {
        guard let panel = window, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 40),
            // .nonactivatingPanel keeps focus in whatever app you were using — the HUD
            // must never steal the keyboard from the thing you were typing in.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        // Visible over full-screen apps, and not captured in screen recordings of them.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        return panel
    }

    /// Centred horizontally, and low on the screen like the system HUD — the middle of
    /// the display is where the user is working.
    private func centre(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            // Clear of the Dock, which a smaller pill would otherwise crowd.
            y: frame.minY + frame.height * 0.16
        ))
    }
}

// MARK: - View

private struct HUDView: View {
    let content: HUD.Content

    /// A compact pill rather than a square card. This is a momentary status cue, not
    /// something to read — laying the icon beside the text keeps it small enough to
    /// ignore while still being legible at a glance.
    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                if content.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: content.symbol)
                        .font(.system(size: 15, weight: .medium))
                }
            }
            .frame(width: 18, height: 18)

            Text(content.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            // The same material the system HUD uses, so it belongs on the desktop
            // rather than looking like a web toast.
            VisualEffectBackground()
                .clipShape(Capsule())
        )
    }

}

/// `NSVisualEffectView` bridge — SwiftUI's `.ultraThinMaterial` does not match the system
/// HUD's appearance on a borderless panel.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
