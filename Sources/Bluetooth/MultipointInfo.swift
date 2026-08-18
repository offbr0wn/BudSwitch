import Foundation

/// What the earbuds report about holding more than one connection.
///
/// Decoded from `MULTIPOINT_INFO` (118). Payload layout verified against
/// GalaxyBudsClient's `MultipointInfoDecoder.cs`:
///
///     [0] revision
///     [1] supportMultipoint    1 = yes
///     [2] multipointState      0 = HaveDevices, 1 = HaveOneDevice
///     [3] audioFocusState      0 = foreground, 1 = background
///     [4] streamingMask        bitfield, see StreamingMask
///
/// This is a **report, not a control**. There is no published payload for the matching
/// setter, so multipoint cannot be switched on from the Mac — see
/// `docs/multipoint-research.md`. What it buys us is an explanation: when a connect
/// fails and this host is in the background, the phone is holding the audio.
struct MultipointInfo: Equatable, Sendable {

    struct StreamingMask: OptionSet, Equatable, Sendable {
        let rawValue: UInt8
        static let a2dpMusic = StreamingMask(rawValue: 1)
        static let hfpCall = StreamingMask(rawValue: 2)
        static let cisMusic = StreamingMask(rawValue: 4)
        static let bis = StreamingMask(rawValue: 8)
        static let cisCall = StreamingMask(rawValue: 16)
    }

    let revision: UInt8
    /// Whether the earbuds claim multipoint support at all.
    let supportsMultipoint: Bool
    /// True when the earbuds hold links to more than one device.
    let hasMultipleDevices: Bool
    /// True when *this* host owns the audio. False means another device — typically the
    /// phone — currently has it.
    let hasAudioFocus: Bool
    let streaming: StreamingMask

    /// Anything actually playing, on any profile.
    var isStreaming: Bool { !streaming.isEmpty }

    init?(payload: Data) {
        // Five bytes minimum; firmware may append more, which we ignore rather than
        // reject so a future revision doesn't break the decode.
        guard payload.count >= 5 else { return nil }
        let b = [UInt8](payload)
        revision = b[0]
        supportsMultipoint = b[1] == 1
        hasMultipleDevices = b[2] == 0      // 0 = HaveDevices, 1 = HaveOneDevice
        hasAudioFocus = b[3] == 0           // 0 = foreground, 1 = background
        streaming = StreamingMask(rawValue: b[4])
    }

    /// Plain-language reason a switch to this Mac may have failed, or nil if nothing
    /// about the reported state explains it.
    var blockingReason: String? {
        guard !hasAudioFocus else { return nil }
        return hasMultipleDevices
            ? "another device is holding the audio"
            : "your phone is holding the audio"
    }
}
