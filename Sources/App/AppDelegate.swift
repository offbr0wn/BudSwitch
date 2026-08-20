import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let showPanelNotification = Notification.Name("com.nivorbit.budsapp.showPanel")

    private var statusBarController: StatusBarController?
    private let bluetooth = BluetoothManager()

    /// BudSwitch's switching engine: audio/idle/power monitors, the arbiter and the
    /// global hotkey. Held here so it lives for the process, same as `bluetooth`.
    private var switching: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: if another copy (same bundle id) is already running,
        // hand off to it and quit. Two instances would fight over the one RFCOMM
        // channel to the buds and show duplicate menu-bar icons.
        let me = NSRunningApplication.current
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: me.bundleIdentifier ?? "")
            .filter { $0 != me }
        if let existing = others.first {
            // Tell the already-running copy to surface its panel, then quit.
            existing.activate(options: [])
            DistributedNotificationCenter.default().postNotificationName(
                Self.showPanelNotification, object: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        // Let a re-launch (which hands off here and quits) re-open our panel.
        DistributedNotificationCenter.default().addObserver(
            forName: Self.showPanelNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusBarController?.showPanel() }
        }
        // An accessory app has no menu bar of its own, so install a minimal main
        // menu purely to wire up the standard ⌘Q quit key equivalent.
        setupMainMenu()
        // AppState enumerates paired devices on init, and IOBluetooth returns an empty
        // list until CoreBluetooth authorises — which would look like "no devices" and
        // clear the saved selection. Build a placeholder now for the UI to bind to, then
        // start the real engine when Bluetooth reports ready.
        let state = AppState(deferStart: true)
        switching = state
        bluetooth.onBluetoothReady = { [weak state] in state?.startWhenBluetoothReady() }
        let controller = StatusBarController(bluetooth: bluetooth, switching: state)
        statusBarController = controller
        // Deliberately no panel on auto-connect. It fired on every reconnect — including
        // the automatic ones this app performs itself — and stole focus mid-task. The
        // menubar icon already switches to the connected glyph with the battery level,
        // which is the whole message without a window appearing over your work.
        // Prime permission and auto-connect to an already-connected Galaxy Buds.
        bluetooth.startAutoConnect()

        // Wait for the status item to be laid out before showing the launch panel.
        // A fixed delay was not enough on a busy menu bar — the panel anchored to a
        // button still reporting a zero rect and appeared at the far left of the screen.
        showPanelWhenStatusItemReady(attemptsRemaining: 25)
        startObservingStatus()
    }

    /// Polls briefly for the status item to settle, then shows the panel. Gives up
    /// after ~2.5s and shows it anyway rather than never appearing.
    private func showPanelWhenStatusItemReady(attemptsRemaining: Int) {
        guard let controller = statusBarController else { return }
        if controller.isStatusItemPositioned || attemptsRemaining <= 0 {
            controller.showPanel()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.showPanelWhenStatusItemReady(attemptsRemaining: attemptsRemaining - 1)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        statusBarController?.showPanel()
        return true
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: String(localized: "Quit Galaxy Buds"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func startObservingStatus() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bluetooth.pollAutoConnect()
                self.statusBarController?.updateIcon(
                    connected: self.bluetooth.isConnected,
                    batteryLeft: self.bluetooth.status.batteryLeft,
                    batteryRight: self.bluetooth.status.batteryRight,
                    leftPresent: self.bluetooth.status.placementLeft != .inCase
                        && self.bluetooth.status.placementLeft != .inClosedCase,
                    rightPresent: self.bluetooth.status.placementRight != .inCase
                        && self.bluetooth.status.placementRight != .inClosedCase
                )
            }
        }
    }
}
