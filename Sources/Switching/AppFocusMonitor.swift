import AppKit
import Foundation

/// Decides whether an app that started playing is one you want the earbuds for.
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

    /// Whether audio starting in this app may bring the earbuds to the Mac.
    ///
    /// The app is the one actually making the sound (see `AudioSourceProbe`), not merely
    /// one that happens to be running — a browser always is, so that test let any sound
    /// on the Mac through.
    static func permits(bundle: String) -> Bool {
        guard isEnabled else { return true }

        // Older macOS cannot say which app is playing; fall back to asking whether an
        // allowlisted app is running at all.
        if bundle == AudioSourceProbe.unknownSource {
            let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            return !allowlist.isDisjoint(with: running)
        }
        return isAllowlisted(bundle)
    }

    /// Allowlisted exactly, or a component of an allowlisted app ("…Browser.helper").
    private static func isAllowlisted(_ bundle: String) -> Bool {
        if allowlist.contains(bundle) { return true }
        return allowlist.contains { bundle.hasPrefix($0 + ".") }
    }

    /// Display name for a bundle ID, for log lines and the panel note.
    static func displayName(for bundle: String) -> String {
        if bundle == AudioSourceProbe.unknownSource { return "this Mac" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return bundle
    }
}
