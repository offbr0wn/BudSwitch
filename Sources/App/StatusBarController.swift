import AppKit
import SwiftUI

/// Owns the menu-bar status item, the compact quick panel, and the detail
/// window. Clicking the menu-bar icon toggles a borderless panel that drops
/// straight down from the icon (no popover arrow, like the native AirPods
/// menu); the panel's "Settings…" button opens the detail window.
@MainActor
final class StatusBarController {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var detailWindow: NSWindow?
    private var outsideClickMonitor: Any?
    private let bluetooth: BluetoothManager
    private let switching: AppState

    init(bluetooth: BluetoothManager, switching: AppState) {
        self.switching = switching
        self.bluetooth = bluetooth
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.behavior = .removalAllowed
        statusItem?.autosaveName = "GalaxyBudsStatusItem"
        if let button = statusItem?.button {
            applyIcon(to: button)
            button.action = #selector(togglePanel)
            button.target = self
        }
        // On notched Macs the item is sometimes parked at the default far-right
        // slot (under the Control Center cluster) instead of being given a real
        // position. Toggling visibility on the next runloop forces a re-layout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.statusItem?.isVisible = false
            self?.statusItem?.isVisible = true
        }
    }

    private func applyIcon(to button: NSStatusBarButton) {
        for name in ["airpodspro", "airpods", "headphones"] {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Galaxy Buds") {
                image.isTemplate = true
                button.image = image
                return
            }
        }
        button.title = "Buds"
    }

    // MARK: - Quick panel

    /// A non-activating panel that can still take key focus.
    ///
    /// `.nonactivatingPanel` keeps the app in the background when the panel opens, which
    /// is right for a menu-bar popover — but a window that never becomes key never routes
    /// keyDown to its first responder, so the shortcut recorder sat on "Press keys…"
    /// forever. Overriding `canBecomeKey` restores keyboard input without making the app
    /// steal focus on open.
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingController(
            rootView: MenuPopoverView(bluetooth: bluetooth, switching: switching) { [weak self] in
                self?.openDetailWindow()
            }
        )
        let panel = KeyablePanel(contentViewController: hosting)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        return panel
    }

    /// Shown on launch / reopen so the user can find the app even if the
    /// menu-bar icon is hard to spot.
    func showPanel() {
        guard panel?.isVisible != true else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        positionPanel(panel)
        panel.orderFront(nil)
        installOutsideClickMonitor()
    }

    @objc private func togglePanel() {
        if panel?.isVisible == true {
            closePanel()
        } else {
            showPanel()
        }
    }

    /// Positions the panel just under the menu-bar icon, but always clamped to be
    /// fully on-screen — so it's reachable even when the icon is hidden behind
    /// the notch or off the edge of a full menu bar.
    private func positionPanel(_ panel: NSPanel) {
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 300, height: 360)
        panel.setContentSize(size)

        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var origin: NSPoint
        if let button = statusItem?.button, let buttonWindow = button.window {
            let r = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            origin = NSPoint(x: r.midX - size.width / 2, y: r.minY - size.height - 4)
        } else {
            // No visible status button — fall back to top-centre of the screen.
            origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 8)
        }
        origin.x = min(max(frame.minX + 8, origin.x), frame.maxX - size.width - 8)
        origin.y = min(max(frame.minY + 8, origin.y), frame.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }

    private func closePanel() {
        panel?.orderOut(nil)
        removeOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    // MARK: - Detail window

    func openDetailWindow() {
        closePanel()
        if detailWindow == nil {
            let root = PopoverView(bluetooth: bluetooth)
                .frame(width: 440, height: 600)
                .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = []
            let win = NSWindow(contentViewController: hosting)
            win.title = "Galaxy Buds"
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.isReleasedWhenClosed = false
            win.backgroundColor = .windowBackgroundColor
            win.setContentSize(NSSize(width: 440, height: 600))
            win.center()
            detailWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        detailWindow?.makeKeyAndOrderFront(nil)
    }

    /// - Parameters:
    ///   - batteryLeft/Right: 0 means "no reading", not "flat". A bud sitting in the case
    ///     reports 0, so a plain `min()` showed 0% whenever one bud was stowed.
    ///   - leftPresent/rightPresent: whether that bud is actually out of the case.
    func updateIcon(
        connected: Bool,
        batteryLeft: Int,
        batteryRight: Int,
        leftPresent: Bool = true,
        rightPresent: Bool = true
    ) {
        guard let button = statusItem?.button else { return }
        // Report the lowest reading among buds actually in use — that is the one that
        // will run out first. Ignore any bud that is in the case or reporting nothing.
        let readings = [
            (leftPresent, batteryLeft),
            (rightPresent, batteryRight),
        ].filter { $0.0 && $0.1 > 0 }.map(\.1)
        let battery = connected && !readings.isEmpty ? "\(readings.min() ?? 0)%" : ""
        if button.image != nil {
            // The SF Symbol is always visible; show battery beside it when connected.
            button.title = battery.isEmpty ? "" : " \(battery)"
        } else {
            // No symbol available on this OS — keep a text label at all times so the
            // variable-length item never collapses to zero width and vanishes.
            button.title = battery.isEmpty ? "Buds" : "Buds \(battery)"
        }
    }

    deinit {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
