import Foundation
import IOKit
import os

/// Every state transition goes through here. This app gets debugged from logs.
///
/// Stream them live with:
///   log stream --predicate 'subsystem == "com.budswitch.mac"' --level debug
enum Log {
    static let subsystem = "com.budswitch.mac"

    static let bluetooth = Logger(subsystem: subsystem, category: "bluetooth")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let app = Logger(subsystem: subsystem, category: "app")
}

/// A single timed Bluetooth attempt, kept so the menu can show what just happened.
struct SpikeRecord: Identifiable, Equatable {
    enum Action: String {
        case connect = "Connect"
        case disconnect = "Disconnect"
    }

    /// What actually happened, judged by the audio route rather than the return code.
    enum Outcome: Equatable {
        /// Audio route reached the desired state.
        case success
        /// Switched by moving the system output alone — the Bluetooth link was already up.
        /// This is the multipoint fast path, and it is ~1000x quicker than a reconnect.
        case routeOnly
        /// Nothing to do; the device was already in the requested state.
        case alreadyThere
        /// The IOBluetooth call succeeded but audio never followed.
        case basebandOnly
        /// The call itself failed.
        case failed(IOReturn)
        /// The call ran past the timeout without resolving.
        case timedOut

        var label: String {
            switch self {
            case .success: return "success"
            case .routeOnly: return "instant (link was up)"
            case .alreadyThere: return "already there"
            case .basebandOnly: return "baseband only (no audio)"
            case .failed(kIOReturnTimeout): return "buds didn't respond"
            case .failed(let code): return "failed (\(IOReturnName.describe(code)))"
            case .timedOut: return "timed out"
            }
        }

        var isSuccess: Bool { self == .success || self == .routeOnly || self == .alreadyThere }

        /// A no-op, not a switch. Excluded from reliability stats so redundant clicks
        /// can't pad the success rate the acceptance test is measured against.
        var isNoOp: Bool { self == .alreadyThere }
    }

    let id = UUID()
    let action: Action
    let outcome: Outcome
    /// Time until the audio route settled — the number that matters for the <2s target.
    let elapsed: TimeInterval
    /// Raw result of the IOBluetooth call, kept separate from the audio verdict.
    let ioReturn: IOReturn
    let date: Date
    /// Which attempt landed. >1 means the radio needed retries — the signal that
    /// distinguishes "worked" from "barely worked" on non-multipoint devices.
    var attempts: Int = 1

    var summary: String {
        let base = String(format: "%@ — %@ in %.2fs", action.rawValue, outcome.label, elapsed)
        return attempts > 1 ? "\(base) (attempt \(attempts))" : base
    }
}

/// `IOReturn` values are opaque integers in logs; name the ones we actually hit.
enum IOReturnName {
    /// Codes that mean "the link is already up" rather than a real failure.
    ///
    /// Since 10.7 `openConnection()` stopped masking an existing connection into success,
    /// so these have to be translated back. IOKit has no dedicated "connection exists"
    /// code — the radio reports the condition as busy or still-open.
    static let alreadyConnected: Set<IOReturn> = [
        kIOReturnBusy,
        kIOReturnStillOpen,
        kIOReturnExclusiveAccess,
    ]

    static func describe(_ code: IOReturn) -> String {
        switch code {
        case kIOReturnSuccess: return "kIOReturnSuccess"
        case kIOReturnExclusiveAccess: return "kIOReturnExclusiveAccess"
        case kIOReturnBusy: return "kIOReturnBusy"
        case kIOReturnStillOpen: return "kIOReturnStillOpen"
        case kIOReturnNotOpen: return "kIOReturnNotOpen"
        case kIOReturnNoDevice: return "kIOReturnNoDevice"
        case kIOReturnTimeout: return "kIOReturnTimeout"
        default: return "0x\(String(UInt32(bitPattern: code), radix: 16))"
        }
    }
}
