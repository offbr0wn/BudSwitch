import Foundation

/// Reports the moment an app *starts* audibly playing.
///
/// The trigger is the start, not the state. "Something is playing" is true for long
/// stretches in which nobody pressed anything, and acting on it meant every route change
/// re-read the same old audio as a fresh reason to take the earbuds. A start is the one
/// event that corresponds to a person pressing play.
///
/// Each app's playback is tracked as a run. A run fires once, after it has been audible
/// continuously for `sustain`, and cannot fire again until it has been silent for
/// `stopGrace` and then starts over. Audio that was already under way when the watcher
/// launched is recorded as an existing run and never fires.
final class PlaybackWatcher {

    /// Called on the main queue with the bundle ID of an app that began playing.
    private let onStart: (String) -> Void
    /// Called on the main queue when "anything is playing" changes.
    private let onPlayingChanged: (Bool) -> Void

    private let queue = DispatchQueue(label: "com.budswitch.mac.playback-watcher", qos: .utility)
    private var timer: DispatchSourceTimer?

    private struct Run {
        /// Start of the current unbroken stretch of sound, nil during a gap.
        var audibleSince: Date?
        var lastHeard: Date
        var hasFired: Bool
    }

    private var runs: [String: Run] = [:]
    private var isPrimed = false
    private var lastReportedPlaying = false
    private var ticks = 0

    /// How long a start must last before it counts. Long enough that a notification
    /// sound in a browser tab, which reads as audible for two to three seconds, does not
    /// pull the earbuds across.
    ///   defaults write com.budswitch.mac playbackSustainSeconds -int 2
    static var sustain: TimeInterval {
        let seconds = UserDefaults.standard.object(forKey: "playbackSustainSeconds") as? Int ?? 3
        return TimeInterval(max(1, min(seconds, 15)))
    }

    /// Silence tolerated inside one run: the gap between tracks, a buffer underrun, the
    /// stream moving to another output. Shorter gaps do not make a new start.
    static let stopGrace: TimeInterval = 4

    private static let interval: TimeInterval = 1

    init(onStart: @escaping (String) -> Void, onPlayingChanged: @escaping (Bool) -> Void) {
        self.onStart = onStart
        self.onPlayingChanged = onPlayingChanged
    }

    deinit { timer?.cancel() }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    // MARK: - Sampling

    private func tick() {
        advance(playing: AudioSourceProbe.playingBundleIDs(), now: Date())

        // PIDs are recycled; do not let an attribution outlive its process for long.
        ticks += 1
        if ticks % 300 == 0 { AudioSourceProbe.resetAttributionCache() }
    }

    /// One sample. Separated from the timer so the run logic can be driven directly.
    func advance(playing: Set<String>, now: Date) {
        for bundle in playing {
            if var run = runs[bundle] {
                if run.audibleSince == nil { run.audibleSince = now }
                run.lastHeard = now
                runs[bundle] = run
            } else {
                // Before the first sample there is no way to tell a start from audio
                // that was already playing, so the baseline never fires.
                runs[bundle] = Run(audibleSince: now, lastHeard: now, hasFired: !isPrimed)
            }
        }

        for (bundle, run) in runs where !playing.contains(bundle) {
            if now.timeIntervalSince(run.lastHeard) > Self.stopGrace {
                runs[bundle] = nil
            } else {
                // A gap resets the sustain clock, so a string of short sounds never adds
                // up to one long one.
                runs[bundle]?.audibleSince = nil
            }
        }
        isPrimed = true

        for (bundle, run) in runs where !run.hasFired {
            guard let since = run.audibleSince,
                  now.timeIntervalSince(since) >= Self.sustain else { continue }
            runs[bundle]?.hasFired = true
            Log.audio.log("playback started: \(bundle, privacy: .public)")
            DispatchQueue.main.async { [onStart] in onStart(bundle) }
        }

        let isPlaying = !runs.isEmpty
        if isPlaying != lastReportedPlaying {
            lastReportedPlaying = isPlaying
            DispatchQueue.main.async { [onPlayingChanged] in onPlayingChanged(isPlaying) }
        }
    }
}
