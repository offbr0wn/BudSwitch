import AppKit
import CoreAudio
import Foundation

/// Which applications are *actually* emitting audio right now.
///
/// `AppFocusMonitor` could only ask whether an allowlisted app was running, which a
/// browser always is — so any sound at all, from any app, passed the gate. macOS 14.4
/// added a process-level audio API that answers the real question, so the earbuds come
/// back for a video in Brave and not for a notification chime.
enum AudioSourceProbe {

    /// Bundle IDs of every app currently playing to an output device.
    ///
    /// Empty is meaningful only alongside `isSupported`: on an OS without the process
    /// API it is empty because nothing can be known, not because nothing is playing.
    static func playingBundleIDs() -> Set<String> {
        var pids = Set<pid_t>()
        for object in processObjects() where isRunningOutput(object) {
            if let pid = processPID(object) { pids.insert(pid) }
        }
        guard !pids.isEmpty else { return [] }

        // Audio is usually emitted by a helper process (Brave's renderer, for one), so
        // map back through the running-application list, which reports the parent app's
        // bundle ID for its helpers.
        var bundles = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            guard let bundle = app.bundleIdentifier else { continue }
            if pids.contains(app.processIdentifier) { bundles.insert(bundle) }
        }
        // Helpers that are not themselves NSRunningApplications: resolve via the
        // executable path, which still carries the parent bundle for XPC helpers.
        for pid in pids where !bundles.contains(where: { _ in false }) {
            if let bundle = bundleID(forHelperPID: pid) { bundles.insert(bundle) }
        }
        return bundles
    }

    /// Whether this OS exposes per-process audio state at all.
    static var isSupported: Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
    }

    // MARK: - CoreAudio plumbing

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0 else { return [] }

        var ids = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
        else { return false }
        return value != 0
    }

    private static func processPID(_ object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr
        else { return nil }
        return pid
    }

    /// Bundle ID for a helper process that is not itself an NSRunningApplication.
    ///
    /// Helper executables live inside the parent bundle, so walking up from the
    /// executable path to the enclosing .app recovers the owner.
    private static func bundleID(forHelperPID pid: pid_t) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: 4 * 1024)
        guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { return nil }
        var url = URL(fileURLWithPath: String(cString: pathBuffer))
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" {
                return Bundle(url: url)?.bundleIdentifier
            }
        }
        return nil
    }
}
