import CoreAudio
import Foundation

/// Watches for audio starting and stopping on the Mac.
///
/// Listens on `kAudioDevicePropertyDeviceIsRunningSomewhere`, re-attaching whenever the
/// default output device changes — which it does every time the buds connect, so a
/// listener bound to one device would go deaf exactly when it matters.
final class AudioMonitor {

    /// Called with true when audio starts, false when it stops. Always on the main queue.
    private let onChange: (Bool) -> Void

    private let queue = DispatchQueue(label: "com.budswitch.mac.audio-monitor")
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    /// Devices we currently hold a listener on, so they can be detached cleanly.
    private var watched: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    /// Debounce, so a notification chime or a one-second preview doesn't pull the buds
    /// across. Playback must persist this long before it counts as "really playing".
    private let startDebounce: TimeInterval
    private var pendingStart: DispatchWorkItem?

    /// Last reported state, so we only fire on genuine transitions.
    private var lastReported = false

    init(startDebounce: TimeInterval = 2.0, onChange: @escaping (Bool) -> Void) {
        self.startDebounce = startDebounce
        self.onChange = onChange
    }

    deinit {
        // `watched` is mutated on `queue`, so reading it here would be a data race —
        // and deinit cannot safely dispatch onto that queue to synchronise. Detach
        // explicitly via stop() instead; this only covers the listener that is not
        // keyed by device.
        if let block = defaultDeviceListener {
            var addr = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(systemObject, &addr, queue, block)
        }
    }

    /// Detaches every listener. Call before releasing the monitor.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            for (device, block) in self.watched {
                var addr = Self.runningAddress
                AudioObjectRemovePropertyListenerBlock(device, &addr, self.queue, block)
            }
            self.watched.removeAll()
            self.pendingStart?.cancel()
            self.pendingStop?.cancel()
        }
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.attachDefaultDeviceListener()
            self.rebuildDeviceListeners()
        }
    }

    // MARK: - Listeners

    private static let runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Re-attach playback listeners when the output device changes. Without this the
    /// monitor stops seeing playback the moment the buds become the default output.
    private func attachDefaultDeviceListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.queue.async { self?.rebuildDeviceListeners() }
        }
        var addr = Self.defaultOutputAddress
        let status = AudioObjectAddPropertyListenerBlock(systemObject, &addr, queue, block)
        if status == noErr {
            defaultDeviceListener = block
        } else {
            Log.audio.error("failed to observe default output device: \(status, privacy: .public)")
        }
    }

    /// Watches every physical output rather than just the default one.
    ///
    /// Background Music and the Teams loopback driver are installed on this machine and
    /// report `transport == "virt"`. When one of them is the default output it proxies the
    /// real hardware, so reading playback state off the default device alone reports the
    /// virtual device and silently misses real audio.
    private func rebuildDeviceListeners() {
        let devices = AudioRouteProbe.outputDevices().filter { !$0.isVirtual }
        let wanted = Set(devices.map(\.id))

        for (device, block) in watched where !wanted.contains(device) {
            var addr = Self.runningAddress
            AudioObjectRemovePropertyListenerBlock(device, &addr, queue, block)
            watched.removeValue(forKey: device)
        }

        for device in wanted where watched[device] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.evaluate()
            }
            var addr = Self.runningAddress
            let status = AudioObjectAddPropertyListenerBlock(device, &addr, queue, block)
            if status == noErr { watched[device] = block }
        }

        evaluate()
    }

    // MARK: - Evaluation

    /// True when any physical output is playing.
    /// True when the *current default output* is playing.
    ///
    /// Deliberately not "any output is playing". Once the earbuds leave for the phone,
    /// macOS falls back to the built-in speakers — and a video resuming there counted as
    /// playback, so the Mac grabbed the earbuds back while they were in use on the phone.
    ///
    /// If the default output is a virtual device (Background Music, Teams), fall back to
    /// the physical outputs behind it, since the virtual device proxies them.
    private var isPlayingNow: Bool {
        guard let output = AudioRouteProbe.defaultOutputDevice() else { return false }
        if output.isVirtual {
            return AudioRouteProbe.outputDevices()
                .filter { !$0.isVirtual }
                .contains(\.isRunningSomewhere)
        }
        return output.isRunningSomewhere
    }

    private func evaluate() {
        let playing = isPlayingNow

        if playing {
            // Resumed within the grace period — cancel the pending stop.
            pendingStop?.cancel()
            pendingStop = nil
            // Sustained playback is required, not just playback at two instants. Sampling
            // only at the end of the window lets a stream of short bursts — notification
            // chimes, UI sounds — masquerade as continuous audio, because a new burst is
            // usually underway when the timer fires.
            if playbackStartedAt == nil { playbackStartedAt = Date() }
            scheduleSustainCheck()
        } else {
            // Tolerate the natural gaps between tracks and buffer underruns; only treat
            // playback as genuinely stopped after a short grace period.
            playbackStartedAt = nil
            scheduleStopCheck()
        }
    }

    /// When the current continuous run of playback began, or nil if nothing is playing.
    private var playbackStartedAt: Date?
    private var pendingStop: DispatchWorkItem?

    private func scheduleSustainCheck() {
        guard !lastReported, pendingStart == nil else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingStart = nil
            // Must still be playing *and* have been playing continuously for the whole
            // window — a gap resets `playbackStartedAt`, so bursts never qualify.
            guard self.isPlayingNow,
                  let since = self.playbackStartedAt,
                  Date().timeIntervalSince(since) >= self.startDebounce
            else { return }
            self.report(true)
        }
        pendingStart = work
        queue.asyncAfter(deadline: .now() + startDebounce, execute: work)
    }

    private func scheduleStopCheck() {
        pendingStart?.cancel()
        pendingStart = nil
        guard lastReported, pendingStop == nil else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingStop = nil
            guard !self.isPlayingNow else { return }
            self.report(false)
        }
        pendingStop = work
        queue.asyncAfter(deadline: .now() + Self.stopGrace, execute: work)
    }

    /// Gap tolerated between tracks before playback counts as stopped.
    private static let stopGrace: TimeInterval = 3.0

    private func report(_ playing: Bool) {
        guard playing != lastReported else { return }
        lastReported = playing
        Log.audio.log("playback \(playing ? "started" : "stopped", privacy: .public)")
        DispatchQueue.main.async { [onChange] in onChange(playing) }
    }
}

private extension Sequence {
    func contains(_ keyPath: KeyPath<Element, Bool>) -> Bool {
        contains { $0[keyPath: keyPath] }
    }
}
