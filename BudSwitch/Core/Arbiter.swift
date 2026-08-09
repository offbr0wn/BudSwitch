import Foundation

/// Decides which trigger wins, and stops the app from thrashing the radio.
///
/// Without this, idle and playback can fight: idle releases the buds, playback sees the
/// route change and reconnects, idle fires again. The cooldown breaks those loops.
struct Arbiter {

    enum Trigger: Int, CustomStringConvertible {
        /// Explicit user action. Always wins, ignores cooldown.
        case manual = 100
        /// A call is live on the Mac — never release during one.
        case call = 90
        case playback = 50
        case userActivity = 10
        /// Idle, sleep, lock. Release only.
        case release = 0

        var description: String {
            switch self {
            case .manual: return "manual"
            case .call: return "call"
            case .playback: return "playback"
            case .userActivity: return "activity"
            case .release: return "release"
            }
        }
    }

    /// A switch blocks anything below priority 90 for this long.
    private let cooldown: TimeInterval = 10

    private var lastSwitch: Date?
    private var lastTrigger: Trigger?

    /// Whether a trigger may act right now.
    mutating func permits(_ trigger: Trigger) -> (allowed: Bool, reason: String) {
        // Manual always wins — the hotkey and menu must never feel ignored.
        if trigger == .manual { return (true, "manual override") }

        if let last = lastSwitch {
            let since = Date().timeIntervalSince(last)
            if since < cooldown, trigger.rawValue < Trigger.call.rawValue {
                return (false, String(format: "cooldown %.0fs remaining", cooldown - since))
            }
        }

        // Equal priority: most recent wins, so this is allowed to proceed.
        if let previous = lastTrigger, previous.rawValue > trigger.rawValue,
           Date().timeIntervalSince(lastSwitch ?? .distantPast) < cooldown {
            return (false, "outranked by \(previous)")
        }

        return (true, "\(trigger)")
    }

    /// Record that a switch happened, starting the cooldown.
    mutating func didSwitch(_ trigger: Trigger) {
        lastSwitch = Date()
        lastTrigger = trigger
    }

    /// True while a call is active on the Mac, judged by an input device being live.
    ///
    /// Releasing mid-call would drop the mic as well as the audio, which is the one
    /// failure the spec calls out as unacceptable.
    static func isCallActive() -> Bool {
        AudioRouteProbe.inputDevices().contains { $0.isRunningSomewhere && !$0.isVirtual }
    }
}
