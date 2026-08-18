import CoreAudio
import Foundation

/// Answers "are the buds actually the live audio route?" using CoreAudio alone.
///
/// This exists because `IOBluetoothDevice.openConnection()` is documented as creating a
/// *baseband* connection — a successful return says an ACL link exists, not that A2DP
/// audio routes to the Mac. `isConnected()` is cached on top of that and goes stale.
///
/// CoreAudio device UIDs embed the Bluetooth MAC (`AA-BB-CC-DD-EE-FF:output`), so matching
/// the default output UID against the device address gives a trustworthy signal — and it
/// needs no entitlement and triggers no TCC prompt.
enum AudioRouteProbe {

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    // MARK: - Public

    struct DeviceInfo {
        let id: AudioDeviceID
        let uid: String
        let name: String
        /// Four-char transport code: `blue` (Bluetooth), `bltn` (built-in), `virt`, `grup`.
        let transport: String
        let isRunningSomewhere: Bool

        var isBluetooth: Bool { transport == "blue" }

        /// Virtual devices proxy to real hardware. "Background Music" and the Teams
        /// loopback driver are both installed on this machine and can become the system
        /// default, at which point reading playback state off the default device reports
        /// the virtual device instead of the real one.
        var isVirtual: Bool { transport == "virt" }
    }

    /// The current default output device, or nil if CoreAudio has none.
    static func defaultOutputDevice() -> DeviceInfo? {
        guard let id = defaultOutputDeviceID() else { return nil }
        return info(for: id)
    }

    /// True when the default output device is the given Bluetooth address.
    ///
    /// This is the source of truth for connection state throughout the app.
    static func isRoutedToDevice(address: String) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        return uid(device.uid, matches: address)
    }

    /// All output devices, used by the menu to show what CoreAudio currently sees.
    static func outputDevices() -> [DeviceInfo] {
        allDeviceIDs()
            .compactMap(info(for:))
            .filter { $0.hasOutput }
    }

    /// True when any physical output is playing right now.
    ///
    /// Read live rather than trusting a cached flag: the release path must not act on a
    /// stale "not playing" value and pull the buds out from under active audio.
    static func isAnythingPlaying() -> Bool {
        outputDevices().contains { !$0.isVirtual && $0.isRunningSomewhere }
    }

    /// All input devices. A live input is how an active call is detected — releasing the
    /// buds mid-call would drop the microphone too.
    static func inputDevices() -> [DeviceInfo] {
        allDeviceIDs()
            .compactMap(info(for:))
            .filter { $0.hasInput }
    }

    /// Polls until the device disappears from CoreAudio entirely, meaning the audio link
    /// really dropped.
    ///
    /// Checking "is it no longer the default output" is not enough on the release path:
    /// the speaker fallback moves the output itself, so that test would pass even if the
    /// link were still up and the phone still couldn't claim the buds.
    ///
    /// - Returns: seconds elapsed once the link cleared, or nil if it never did.
    static func waitForLinkDrop(
        address: String,
        timeout: TimeInterval = 5.0,
        pollInterval: TimeInterval = 0.1
    ) -> TimeInterval? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if outputDevice(forAddress: address) == nil {
                return Date().timeIntervalSince(start)
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return nil
    }

    /// Polls until the route matches `expected`, or the timeout expires.
    ///
    /// `openConnection()` returns as soon as the baseband link is up, but the audio route
    /// takes additional time to follow (or never does). Callers time against this, not
    /// against the IOBluetooth call.
    ///
    /// - Returns: seconds elapsed once settled, or nil if it never reached `expected`.
    static func waitForRoute(
        address: String,
        expected: Bool,
        timeout: TimeInterval = 5.0,
        pollInterval: TimeInterval = 0.1
    ) -> TimeInterval? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if isRoutedToDevice(address: address) == expected {
                return Date().timeIntervalSince(start)
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return nil
    }

    /// Makes a device the system default output.
    ///
    /// Measured at under 3ms — roughly a thousand times faster than a Bluetooth
    /// reconnect, and it never touches the radio. For a multipoint headset already linked
    /// to both machines this is the whole switch: the link stays up, only the route moves.
    @discardableResult
    static func setDefaultOutput(deviceID: AudioDeviceID) -> Bool {
        var value = deviceID
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectSetPropertyData(
            systemObject,
            &addr,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &value
        )
        if status != noErr {
            Log.audio.error("setDefaultOutput failed status=\(status, privacy: .public)")
        }
        return status == noErr
    }

    /// The output device matching a Bluetooth address, if macOS currently exposes one.
    ///
    /// A device only appears here while it holds an active audio link, which is what
    /// makes it a usable multipoint signal.
    ///
    /// Deliberately avoids `outputDevices()`: the `hasOutput` stream query blocks while
    /// the Bluetooth stack settles, and paying it for every device turned a ~1ms lookup
    /// into 2.5s. Match on the UID first and only inspect the one device that matters.
    static func outputDevice(forAddress address: String) -> DeviceInfo? {
        for id in allDeviceIDs() {
            guard let uidString = string(id, kAudioDevicePropertyDeviceUID),
                  uid(uidString, matches: address) else { continue }
            guard let candidate = info(for: id), candidate.hasOutput else { continue }
            return candidate
        }
        return nil
    }

    /// The best device to fall back to when releasing the buds — built-in speakers.
    static func builtInOutput() -> DeviceInfo? {
        outputDevices().first { $0.transport == "bltn" }
    }

    /// Matches a CoreAudio UID against a Bluetooth address.
    ///
    /// `IOBluetoothDevice.addressString` yields `aa-bb-cc-dd-ee-ff` and CoreAudio yields
    /// `AA-BB-CC-DD-EE-FF:output`, so normalise separators and case before comparing.
    static func uid(_ uid: String, matches address: String) -> Bool {
        let normalizedUID = normalize(uid)
        let normalizedAddress = normalize(address)
        guard !normalizedAddress.isEmpty else { return false }
        return normalizedUID.hasPrefix(normalizedAddress)
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }

    // MARK: - CoreAudio plumbing

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    static func info(for deviceID: AudioDeviceID) -> DeviceInfo? {
        guard let uid = string(deviceID, kAudioDevicePropertyDeviceUID) else { return nil }
        return DeviceInfo(
            id: deviceID,
            uid: uid,
            name: string(deviceID, kAudioDevicePropertyDeviceNameCFString) ?? "Unknown",
            transport: transportCode(deviceID) ?? "????",
            isRunningSomewhere: (uint32(deviceID, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0
        )
    }

    /// CFString properties hand back a +1 reference; take it unmanaged so ARC doesn't
    /// try to release a value it never retained.
    private static func string(
        _ deviceID: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = address(selector)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr else {
            return nil
        }
        var result: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &result) { pointer in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, pointer)
        }
        guard status == noErr, let value = result else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32(
        _ deviceID: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var addr = address(selector)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    /// Transport type is a packed four-char code.
    private static func transportCode(_ deviceID: AudioDeviceID) -> String? {
        guard let raw = uint32(deviceID, kAudioDevicePropertyTransportType) else { return nil }
        return withUnsafeBytes(of: raw.bigEndian) { String(bytes: $0, encoding: .ascii) }
    }
}

extension AudioRouteProbe.DeviceInfo {
    /// A device is an output if it has at least one output stream.
    var hasOutput: Bool { hasStreams(scope: kAudioDevicePropertyScopeOutput) }

    /// A device is an input if it has at least one input stream.
    var hasInput: Bool { hasStreams(scope: kAudioDevicePropertyScopeInput) }

    private func hasStreams(scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }
}
