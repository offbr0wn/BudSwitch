import AppKit
import CoreAudio
import Foundation
import IOKit.pwr_mgt

/// Which applications are *audibly playing* right now.
///
/// Two signals, because neither is enough alone:
///
/// - **Output streams** (CoreAudio's process objects, macOS 14.2+) say which apps hold an
///   open stream. That is not the same as making sound: measured on Chromium, the stream
///   outlives a pause by about eight seconds, and a tab with a live `AudioContext` holds
///   one indefinitely. Used as a trigger, that pulled the earbuds back for paused video.
/// - **Media power assertions.** Chromium browsers hold an assertion named
///   "Playing audio" exactly while a tab is audible. Measured: it appears with playback
///   and is gone about a second after pausing. That is the play/pause signal.
///
/// So an app counts as playing when it holds a stream *and*, if it is an app that
/// publishes the assertion, the assertion is present. Apps that never publish one fall
/// back to the stream alone, which is the best the OS offers for them.
enum AudioSourceProbe {

    /// Bundle IDs of every app audibly playing right now.
    static func playingBundleIDs() -> Set<String> {
        guard isSupported else { return legacyPlaying() }

        let streams = streamBundleIDs()
        let audible = audibleBundleIDs()

        lock.lock()
        // Any app seen publishing the assertion is held to it from then on, which
        // extends the rule to Chromium apps missing from the built-in list.
        publishesAudibility.formUnion(audible)
        let known = publishesAudibility
        lock.unlock()

        return streams.filter { bundle in
            let publishes = known.contains(bundle)
                || audibilityPublishers.contains { bundle == $0 || bundle.hasPrefix($0 + ".") }
            return !publishes || audible.contains(bundle)
        }
    }

    /// Stands in for "some app" on an OS with no per-process audio API.
    static let unknownSource = "*"

    /// Whether this OS exposes per-process audio state at all.
    static let isSupported: Bool = {
        var address = processListAddress
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
    }()

    // MARK: - Signal 1: output streams

    /// Apps holding an open output stream. Open, not necessarily audible.
    static func streamBundleIDs() -> Set<String> {
        var bundles = Set<String>()
        for object in processObjects() where isRunningOutput(object) {
            guard let pid = processPID(object) else { continue }
            if let bundle = owningBundleID(pid: pid) ?? processBundleID(object) {
                bundles.insert(bundle)
            }
        }
        return bundles
    }

    // MARK: - Signal 2: audibility assertions

    /// Assertion names that mean "this app is audibly playing media".
    private static let audibleAssertionNames: Set<String> = ["Playing audio"]

    /// Apps known to publish that assertion, so they are held to it from the first
    /// sample rather than only after it has been observed once.
    private static let audibilityPublishers: Set<String> = [
        "com.brave.Browser",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "org.chromium.Chromium",
    ]

    private static let lock = NSLock()
    private static var publishesAudibility = Set<String>()

    /// Apps currently holding an audibility assertion.
    static func audibleBundleIDs() -> Set<String> {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [] }

        var bundles = Set<String>()
        for (pid, assertions) in byProcess {
            let audible = assertions.contains {
                guard let name = $0[kIOPMAssertionNameKey] as? String else { return false }
                return audibleAssertionNames.contains(name)
            }
            guard audible, let bundle = owningBundleID(pid: pid.int32Value) else { continue }
            bundles.insert(bundle)
        }
        return bundles
    }

    // MARK: - Process → app

    /// The app a process belongs to.
    ///
    /// Browsers play through helper processes nested inside the main bundle, so this
    /// walks to the *outermost* .app: "Brave Browser Helper" resolves to
    /// com.brave.Browser, the ID the user actually allowlists, and the stream and the
    /// assertion — held by different processes of the same app — land on the same key.
    private static func owningBundleID(pid: pid_t) -> String? {
        lock.lock()
        let cached = bundleCache[pid]
        lock.unlock()
        if let cached { return cached.isEmpty ? nil : cached }

        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        var resolved: String?
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let components = URL(fileURLWithPath: String(cString: buffer)).pathComponents
            if let index = components.firstIndex(where: { $0.hasSuffix(".app") }) {
                let path = NSString.path(withComponents: Array(components[...index]))
                resolved = Bundle(path: path)?.bundleIdentifier
            }
        }

        lock.lock()
        // Bounded: PIDs are recycled, and a stale entry would attribute a new process
        // to whatever app owned the number before.
        if bundleCache.count > 512 { bundleCache.removeAll() }
        bundleCache[pid] = resolved ?? ""
        lock.unlock()
        return resolved
    }

    private static var bundleCache: [pid_t: String] = [:]

    /// Drops cached attributions. Called periodically so a recycled PID cannot keep a
    /// dead app's identity for long.
    static func resetAttributionCache() {
        lock.lock()
        bundleCache.removeAll()
        lock.unlock()
    }

    // MARK: - CoreAudio plumbing

    private static var processListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = processListAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0 else { return [] }

        var ids = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        // The list can shrink between the size query and the read.
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
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

    /// CoreAudio's own idea of the process's bundle ID. Used only when the executable
    /// is not inside an .app at all, such as a system XPC service.
    private static func processBundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?, !string.isEmpty
        else { return nil }
        return string
    }

    // MARK: - Older macOS

    /// Without the process API all that can be known is whether the output is running.
    private static func legacyPlaying() -> Set<String> {
        guard let output = AudioRouteProbe.defaultOutputDevice() else { return [] }
        let running = output.isVirtual
            ? AudioRouteProbe.outputDevices().contains { !$0.isVirtual && $0.isRunningSomewhere }
            : output.isRunningSomewhere
        return running ? [unknownSource] : []
    }
}
