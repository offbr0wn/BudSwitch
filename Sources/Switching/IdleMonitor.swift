import AppKit
import Foundation

/// Fires once when the Mac has been untouched for the configured interval.
///
/// There is no push notification for idle, so this polls. `CGEventSource` needs no
/// permission — verified, it returns a value without prompting.
final class IdleMonitor {

    private let onIdle: () -> Void
    private var timer: Timer?

    /// How long without input counts as idle.
    ///   defaults write com.budswitch.mac idleMinutes -int 10
    static var threshold: TimeInterval {
        let minutes = UserDefaults.standard.object(forKey: "idleMinutes") as? Int ?? 5
        return TimeInterval(min(max(minutes, 1), 30) * 60)
    }

    /// Set once we've fired, so idle triggers a single release rather than one per poll.
    private var hasFired = false

    init(onIdle: @escaping () -> Void) {
        self.onIdle = onIdle
    }

    deinit { timer?.invalidate() }

    func start() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.check()
        }
        // .common so polling continues while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    static func secondsSinceInput() -> TimeInterval {
        guard let anyEvent = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyEvent)
    }

    private func check() {
        let idle = Self.secondsSinceInput()

        // Playing audio counts as activity. Idle is measured from keyboard and mouse
        // input, and watching a film is exactly when you touch neither — without this the
        // Mac is "idle" mid-playback and hands the buds to the phone.
        //
        // Treating it as activity (rather than just refusing the release) also re-arms
        // the trigger, so the buds are still released once playback actually ends.
        if AudioRouteProbe.isAnythingPlaying() {
            hasFired = false
            return
        }

        // Reset as soon as the machine is touched, arming the next release.
        guard idle >= Self.threshold else {
            hasFired = false
            return
        }

        guard !hasFired else { return }
        hasFired = true
        Log.app.log("idle for \(Int(idle), privacy: .public)s — releasing")
        onIdle()
    }
}
