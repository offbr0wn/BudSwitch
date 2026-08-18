import AppKit
import Foundation

/// Sleep, wake, lock and unlock.
///
/// `willSleepNotification` gives a short window before the machine goes down, so the
/// release has to be fired immediately and synchronously rather than queued.
final class PowerMonitor {

    private let onRelease: (String) -> Void
    private let onWake: () -> Void
    private var tokens: [NSObjectProtocol] = []

    init(onRelease: @escaping (String) -> Void, onWake: @escaping () -> Void) {
        self.onRelease = onRelease
        self.onWake = onWake
    }

    deinit {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        for token in tokens {
            workspace.removeObserver(token)
            distributed.removeObserver(token)
        }
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter

        tokens.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Log.app.log("system will sleep")
            self?.onRelease("sleep")
        })

        tokens.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Log.app.log("system woke")
            self?.onWake()
        })

        // Screen lock is not a workspace notification.
        let distributed = DistributedNotificationCenter.default()
        tokens.append(distributed.addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Log.app.log("screen locked")
            self?.onRelease("lock")
        })
    }

    /// The radio is unreliable immediately after wake, so callers wait this long before
    /// touching Bluetooth.
    static let wakeSettleDelay: TimeInterval = 2.0
}
