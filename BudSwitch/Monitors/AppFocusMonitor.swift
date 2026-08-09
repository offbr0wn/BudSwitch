import AppKit
import Foundation

/// Decides whether the app currently making sound is one you want the buds for.
///
/// macOS gives no public API for "which app is emitting audio", so this approximates it
/// with the running-application set: if an allowlisted app is running, audio starting is
/// attributed to it. That is deliberately permissive — the alternative, using only the
/// frontmost app, breaks the common case of music playing while you work elsewhere.
enum AppFocusMonitor {

    /// Bundle IDs that may pull the buds to the Mac. Brave is the primary one here;
    /// the rest cover media and calls.
    static let defaultAllowlist: Set<String> = [
        "com.brave.Browser",
        "com.spotify.client",
        "com.apple.Music",
        "com.apple.Safari",
        "com.google.Chrome",
        "us.zoom.xos",
        "com.tinyspeck.slackmacgap",
        "com.microsoft.teams2",
    ]

    /// Effective allowlist. Override without a rebuild:
    ///   defaults write com.budswitch.mac allowlist -array com.brave.Browser com.spotify.client
    static var allowlist: Set<String> {
        if let custom = UserDefaults.standard.array(forKey: "allowlist") as? [String],
           !custom.isEmpty {
            return Set(custom)
        }
        return defaultAllowlist
    }

    /// Whether the allowlist should gate connects at all.
    ///   defaults write com.budswitch.mac allowlistEnabled -bool false
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "allowlistEnabled") as? Bool ?? true
    }

    /// True when an allowlisted app is running and could plausibly be the audio source.
    static func allowsConnect() -> (allowed: Bool, reason: String) {
        guard isEnabled else { return (true, "allowlist off") }

        let running = NSWorkspace.shared.runningApplications
            .compactMap(\.bundleIdentifier)
        let matches = allowlist.intersection(running)

        guard !matches.isEmpty else {
            return (false, "no allowlisted app running")
        }

        // Prefer naming the frontmost match — it's the most likely source and makes the
        // log line useful when working out why a switch did or didn't happen.
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           matches.contains(front) {
            return (true, front)
        }
        return (true, matches.sorted().joined(separator: ","))
    }
}
