import Foundation
import IOBluetooth

/// Connect and disconnect, with the timing instrumentation the Phase 0 spike needs.
///
/// Everything here runs off the main thread: `openConnection()` is synchronous and the
/// header warns it blocks until the link is established or the page attempt times out,
/// which is seconds in practice.
enum BluetoothController {

    struct PairedDevice: Identifiable, Hashable {
        var id: String { address }
        let address: String
        let name: String
        /// Cached by IOBluetooth and prone to going stale — display only, never a decision.
        let isConnectedCached: Bool
    }

    /// Serial so two menu clicks can't run overlapping blocking calls.
    private static let queue = DispatchQueue(label: "com.budswitch.mac.bluetooth")

    /// Pause *after* each attempt. Three attempts total; the last has no trailing wait.
    private static let retryDelays: [TimeInterval] = [0.5, 1.0, 0]

    /// Page timeout in Bluetooth slots of 0.625ms. Requested, but macOS does not honour
    /// it — see `openWithDeadline`.
    private static let pageTimeout: BluetoothHCIPageTimeout = 4096

    /// How long to wait for a connect before giving up on it.
    ///
    /// Successful connects measured 6–9s on Buds4 Pro, so this has to clear that. Failures
    /// block a flat 20s, which is what made the UI look frozen.
    private static let connectDeadline: TimeInterval = 12

    /// Runs `openConnection` and returns as soon as the earbuds are *actually usable*.
    ///
    /// Two things made this necessary. macOS ignores the page timeout we request, so the
    /// call itself blocks 2–20s. And the call returning is the wrong signal anyway: the
    /// audio route often flips to the earbuds seconds before `openConnection` returns —
    /// observed returning `kIOReturnTimeout` at 12s on a connection that had already
    /// succeeded at 10s, so a perfectly good switch was reported as "buds didn't respond".
    ///
    /// So poll the route while the call runs and finish the moment audio lands. The
    /// blocking call is left to complete on its own thread; an in-flight HCI request
    /// cannot be cancelled, and letting it finish is harmless.
    private static func openWithDeadline(_ device: IOBluetoothDevice, address: String) -> IOReturn {
        let semaphore = DispatchSemaphore(value: 0)
        var result = kIOReturnTimeout
        Thread.detachNewThread {
            result = device.openConnection(nil, withPageTimeout: pageTimeout, authenticationRequired: false)
            semaphore.signal()
        }

        let deadline = Date().addingTimeInterval(connectDeadline)
        while Date() < deadline {
            // The route is the thing the user cares about — once audio is on the earbuds
            // the switch is done, whatever the call is still doing.
            if AudioRouteProbe.isRoutedToDevice(address: address) { return kIOReturnSuccess }
            if semaphore.wait(timeout: .now() + 0.15) == .success { return result }
        }
        // One last look: the route may have landed inside the final poll gap.
        return AudioRouteProbe.isRoutedToDevice(address: address) ? kIOReturnSuccess : kIOReturnTimeout
    }

    /// Cached device objects, keyed by address.
    ///
    /// `+[IOBluetoothDevice deviceWithAddressString:]` is not merely slow — when the
    /// device is unreachable it can block **indefinitely**. Verified with `sample`: two
    /// separate processes sat in that constructor for minutes, never reaching
    /// `openConnection()`, so the page timeout never even applied.
    ///
    /// The object stays valid across connection state changes, so constructing it once
    /// per address keeps that hazard off every subsequent switch.
    private static var deviceCache: [String: IOBluetoothDevice] = [:]
    private static let cacheLock = NSLock()

    private static func cachedDevice(for address: String) -> IOBluetoothDevice? {
        cacheLock.lock()
        if let hit = deviceCache[address] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        // Built outside the lock: this is the call that can block for minutes, and holding
        // the lock through it would stall every other caller too.
        guard let device = IOBluetoothDevice(addressString: address) else { return nil }

        cacheLock.lock()
        deviceCache[address] = device
        cacheLock.unlock()
        return device
    }

    /// Warms the cache off the hot path, so the first switch doesn't pay for construction.
    static func prewarm(address: String) {
        queue.async { _ = cachedDevice(for: address) }
    }

    // MARK: - Enumeration

    /// Paired *audio* devices. Must be called from a process launched via LaunchServices —
    /// a bare CLI binary is killed by TCC on the first IOBluetooth call.
    ///
    /// Mice, keyboards and gamepads are filtered out: they can never hold an audio route,
    /// so offering them in the picker would be meaningless.
    static func pairedDevices() -> [PairedDevice] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            Log.bluetooth.error("pairedDevices() returned nil or unexpected type")
            return []
        }
        return devices.compactMap { device in
            guard let address = device.addressString, isAudio(device) else { return nil }
            return PairedDevice(
                address: address,
                name: device.name ?? "Unknown",
                isConnectedCached: device.isConnected()
            )
        }
    }

    /// Audio devices report major class `Audio`. Peripherals (mice, keyboards, gamepads)
    /// report `Peripheral` and are excluded.
    private static func isAudio(_ device: IOBluetoothDevice) -> Bool {
        device.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio)
    }

    // MARK: - Actions

    /// Connect, then wait for audio to actually route to the device.
    ///
    /// The IOBluetooth return code alone is not success: `openConnection()` opens a
    /// baseband link, and A2DP may or may not follow. The verdict comes from
    /// `AudioRouteProbe`.
    ///
    /// - Important: `completion` runs on a background queue, not the main thread.
    ///   Callers hop to the main actor themselves. Delivering on the main queue here
    ///   would deadlock any caller that blocks the main thread waiting for the result.
    static func connect(address: String, completion: @escaping (SpikeRecord) -> Void) {
        perform(.connect, address: address, completion: completion)
    }

    static func disconnect(address: String, completion: @escaping (SpikeRecord) -> Void) {
        perform(.disconnect, address: address, completion: completion)
    }

    private static func perform(
        _ action: SpikeRecord.Action,
        address: String,
        completion: @escaping (SpikeRecord) -> Void
    ) {
        queue.async {
            let start = Date()
            Log.bluetooth.log("\(action.rawValue, privacy: .public) requested for \(address, privacy: .public)")

            // Fast path first, before touching IOBluetooth at all. If the device already
            // has an audio link to this Mac, the buds are multipoint (or simply still
            // attached) and there is nothing to negotiate — moving the system output is
            // the entire switch. Constructing an IOBluetoothDevice alone costs seconds,
            // so this has to run ahead of it to actually be instant.
            if action == .connect,
               let existing = AudioRouteProbe.outputDevice(forAddress: address),
               AudioRouteProbe.setDefaultOutput(deviceID: existing.id) {
                let elapsed = Date().timeIntervalSince(start)
                Log.bluetooth.log(
                    "\(action.rawValue, privacy: .public) via audio route in \(String(format: "%.3f", elapsed), privacy: .public)s (link already up)"
                )
                completion(SpikeRecord(
                    action: action,
                    outcome: .routeOnly,
                    elapsed: elapsed,
                    ioReturn: kIOReturnSuccess,
                    date: Date()
                ))
                return
            }

            // Nothing to release if the device isn't linked to this Mac at all. Without
            // this, a redundant Disconnect spends ~4s tearing down a link that either
            // doesn't exist or — on multipoint — is one the user wanted kept.
            if action == .disconnect, AudioRouteProbe.outputDevice(forAddress: address) == nil {
                let elapsed = Date().timeIntervalSince(start)
                Log.bluetooth.log("\(action.rawValue, privacy: .public) skipped — not linked to this Mac")
                completion(SpikeRecord(
                    action: action,
                    outcome: .alreadyThere,
                    elapsed: elapsed,
                    ioReturn: kIOReturnSuccess,
                    date: Date()
                ))
                return
            }

            guard let device = cachedDevice(for: address) else {
                // nil means a malformed address or the device was unpaired behind our back.
                Log.bluetooth.error("IOBluetoothDevice(addressString:) returned nil for \(address, privacy: .public)")
                let record = SpikeRecord(
                    action: action,
                    outcome: .failed(kIOReturnNoDevice),
                    elapsed: Date().timeIntervalSince(start),
                    ioReturn: kIOReturnNoDevice,
                    date: Date()
                )
                completion(record)
                return
            }

            let expectRouted = (action == .connect)

            // Retry with backoff. The radio is unreliable — measured connects on this
            // machine ranged 1.8s to 4.5s — and non-multipoint buds have to actually
            // negotiate the link, so a single attempt is not enough.
            var rawResult = kIOReturnSuccess
            var attempt = 0
            for delay in Self.retryDelays {
                attempt += 1
                // macOS ignores the page timeout we ask for: measured connects block
                // 6–9s on success and a flat 20s on failure. Run the call on its own
                // thread and stop waiting after `connectDeadline`, so an unreachable
                // device costs seconds rather than twenty. The call itself keeps running
                // and is harmless — we simply stop blocking the queue on it.
                if expectRouted {
                    rawResult = Self.openWithDeadline(device, address: address)
                } else {
                    rawResult = device.closeConnection()
                }

                // An already-open link reports as an error; that's still a win.
                if rawResult == kIOReturnSuccess { break }

                // A timeout means the buds did not answer the page — they are out of
                // range, in the case, or held by another device. Retrying cannot change
                // any of those, and each attempt blocks ~15s despite the page timeout we
                // ask for, so three of them cost 47s to reach the same answer.
                if rawResult == kIOReturnTimeout {
                    Log.bluetooth.log("\(action.rawValue, privacy: .public) timed out — buds unreachable, not retrying")
                    break
                }
                if expectRouted, IOReturnName.alreadyConnected.contains(rawResult) { break }
                // The desired state may have been reached even when the call reports
                // failure. Connecting is judged by audio arriving; releasing by the link
                // dropping — "not the current output" would also be true when the route
                // simply moved elsewhere, which is not the same thing.
                let reached = expectRouted
                    ? AudioRouteProbe.isRoutedToDevice(address: address)
                    : AudioRouteProbe.outputDevice(forAddress: address) == nil
                if reached { break }

                if delay > 0 {
                    Log.bluetooth.log(
                        "\(action.rawValue, privacy: .public) attempt \(attempt, privacy: .public) returned \(IOReturnName.describe(rawResult), privacy: .public), retrying in \(delay, privacy: .public)s"
                    )
                    Thread.sleep(forTimeInterval: delay)
                }
            }
            let callElapsed = Date().timeIntervalSince(start)

            // Since 10.7 an already-open link surfaces as an error rather than being
            // masked into success. If the device is already in the state we wanted, the
            // error doesn't matter. Judged per direction for the same reason as above.
            let alreadyThere = expectRouted
                ? AudioRouteProbe.isRoutedToDevice(address: address)
                : AudioRouteProbe.outputDevice(forAddress: address) == nil
            let callSucceeded = rawResult == kIOReturnSuccess
                || alreadyThere
                || (expectRouted && IOReturnName.alreadyConnected.contains(rawResult))

            Log.bluetooth.log(
                """
                \(action.rawValue, privacy: .public) call returned \
                \(IOReturnName.describe(rawResult), privacy: .public) in \
                \(String(format: "%.2f", callElapsed), privacy: .public)s
                """
            )

            let outcome: SpikeRecord.Outcome
            var settled = callElapsed

            // Connecting is verified by audio arriving; releasing is verified by the link
            // actually dropping. Using "no longer the default output" for release would be
            // satisfied by our own speaker fallback, reporting success while the buds stay
            // held by this Mac.
            let confirmation = expectRouted
                // A2DP can take several seconds to follow the baseband link — measured
                // 5.9s after openConnection returned success. Too short a window here
                // reports a working connect as "baseband only (no audio)", so allow for
                // the slow case rather than the typical one.
                ? AudioRouteProbe.waitForRoute(address: address, expected: true, timeout: 8.0)
                // Shorter than the connect wait: the release is confirmed by the route
                // check below if the link lingers, so there is no need to block for 5s.
                : AudioRouteProbe.waitForLinkDrop(address: address, timeout: 2.0)

            if !callSucceeded {
                outcome = .failed(rawResult)
            } else if let routeElapsed = confirmation {
                // Total time the user actually feels: the call plus the route settling.
                settled = callElapsed + routeElapsed
                outcome = .success
            } else if !expectRouted,
                      let routeElapsed = AudioRouteProbe.waitForRoute(
                          address: address, expected: false, timeout: 2.0
                      ) {
                // The device can linger in CoreAudio after the link is torn down, so
                // waitForLinkDrop times out even though the release worked. What matters
                // to the user is that audio has left the buds — so fall back to the route,
                // allowing a moment for CoreAudio to catch up with the radio.
                settled = callElapsed + routeElapsed
                outcome = .success
            } else {
                // The link came up but audio never followed — the failure mode that a
                // return-code-only check would have reported as success.
                outcome = expectRouted ? .basebandOnly : .timedOut
            }

            // Park audio on the built-in speakers *after* verifying, so the fallback can't
            // satisfy the check it is supposed to be independent of. Releasing a device
            // can otherwise leave macOS with no sensible output.
            if !expectRouted, let builtIn = AudioRouteProbe.builtInOutput() {
                AudioRouteProbe.setDefaultOutput(deviceID: builtIn.id)
            }

            let record = SpikeRecord(
                action: action,
                outcome: outcome,
                elapsed: settled,
                ioReturn: rawResult,
                date: Date(),
                attempts: attempt
            )

            if outcome.isSuccess {
                Log.bluetooth.log("\(record.summary, privacy: .public)")
            } else {
                Log.bluetooth.error("\(record.summary, privacy: .public)")
            }

            completion(record)
        }
    }
}
