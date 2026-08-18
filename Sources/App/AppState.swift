import AppKit
import Combine
import Foundation
import SwiftUI

/// Observable root state for the menubar.
@MainActor
final class AppState: ObservableObject {

    /// Devices offered in the picker.
    @Published private(set) var pairedDevices: [BluetoothController.PairedDevice] = []

    @Published private(set) var selectedAddress: String? = DeviceStore.address
    @Published private(set) var selectedName: String? = DeviceStore.name

    /// Whether the selected device is the live audio route. Source of truth for the icon.
    @Published private(set) var isRouted = false

    /// What CoreAudio currently reports as the default output.
    @Published private(set) var currentOutputName = "—"

    /// Set when the default output is a virtual device such as Background Music, which
    /// proxies real hardware and makes route/playback state untrustworthy.
    @Published private(set) var outputIsVirtual = false

    /// True when the selected device has an audio link to this Mac while *not* being the
    /// active output — it is attached and idle, waiting to be switched to.
    ///
    /// This is how multipoint reveals itself: a non-multipoint headset connected to the
    /// phone vanishes from CoreAudio entirely, so it can never be in this state. When it
    /// is true, taking the buds back costs about a millisecond instead of seconds.
    @Published private(set) var isLinkedButIdle = false

    /// Most recent attempts, newest first. This is the spike readout.
    @Published private(set) var history: [SpikeRecord] = []

    /// Menubar glyph. Overridable without a rebuild:
    ///   defaults write com.budswitch.mac menubarSymbol -string "laptopcomputer.and.iphone"
    /// Falls back to the default if the name isn't a real SF Symbol.
    var menubarSymbol: String {
        guard let custom = UserDefaults.standard.string(forKey: "menubarSymbol"),
              NSImage(systemSymbolName: custom, accessibilityDescription: nil) != nil
        else { return "headphones" }
        return custom
    }

    /// True while a blocking Bluetooth call is in flight, so the menu can disable actions.
    @Published private(set) var isBusy = false

    /// Seconds the in-flight switch has been running. `openConnection()` blocks for
    /// 6–20s on this hardware regardless of the page timeout we request, so a static
    /// spinner reads as a frozen app. Counting up shows it is still working.
    @Published private(set) var busySeconds = 0

    private var busyTimer: Timer?

    private var pollTimer: Timer?

    /// `isConnected()` is cached and there is no push notification for route changes,
    /// so poll. 2s keeps the menubar honest without being wasteful.
    private let pollInterval: TimeInterval = 2.0

    // MARK: - Automation

    /// Master switch. The panic toggle — turns every automatic trigger off at once.
    ///   defaults write com.budswitch.mac automationEnabled -bool false
    @Published var isAutomationEnabled: Bool = {
        UserDefaults.standard.object(forKey: "automationEnabled") as? Bool ?? true
    }() {
        didSet {
            UserDefaults.standard.set(isAutomationEnabled, forKey: "automationEnabled")
            Log.app.log("automation \(self.isAutomationEnabled ? "enabled" : "disabled", privacy: .public)")
        }
    }

    /// Why the last automatic decision went the way it did, shown in the panel so the
    /// automation is explainable rather than mysterious.
    @Published private(set) var lastAutomationNote: String?

    /// Whether the Mac is playing audio right now. Surfaced so the panel can show that
    /// the automation is actually watching, rather than looking inert.
    @Published private(set) var isPlaying = false

    private var arbiter = Arbiter()
    private var audioMonitor: AudioMonitor?
    private var idleMonitor: IdleMonitor?
    private var powerMonitor: PowerMonitor?
    private var hotkey: Hotkey?

    /// The bound combination, for display in the menu.
    var hotkeyDisplay: String { Hotkey.combo.display }

    /// The binding itself. Setting it persists the choice and re-arms the monitor, so a
    /// new shortcut takes effect immediately rather than after a relaunch.
    var hotkeyCombo: Hotkey.Combo {
        get { Hotkey.combo }
        set {
            guard newValue != Hotkey.combo else { return }
            Hotkey.combo = newValue
            hotkey?.reload()
            Log.app.log("hotkey rebound to \(newValue.display, privacy: .public)")
            refreshHotkeyStatus()
            objectWillChange.send()
        }
    }

    /// Set when the chosen combination could not be registered — almost always because
    /// another app already owns it. This is the only way the hotkey can fail now that it
    /// needs no permission.
    @Published private(set) var hotkeyConflicted = false

    var isHotkeyEnabled: Bool {
        get { Hotkey.isEnabled }
        set {
            Hotkey.isEnabled = newValue
            newValue ? hotkey?.start() : hotkey?.stop()
            objectWillChange.send()
            refreshHotkeyStatus()
        }
    }

    func refreshHotkeyStatus() {
        hotkeyConflicted = hotkey?.isConflicted ?? false
    }

    init() {
        start()
    }

    /// Builds the state without touching IOBluetooth.
    ///
    /// On modern macOS `pairedDevices()` returns an empty list until CoreBluetooth
    /// authorises, and an empty list is indistinguishable from "your device was
    /// unpaired" — which would clear the saved selection. Callers that own a
    /// CoreBluetooth session pass `deferStart: true` and call
    /// `startWhenBluetoothReady()` once it reports `.poweredOn`.
    init(deferStart: Bool) {
        guard !deferStart else { return }
        start()
    }

    private var hasStarted = false

    /// Starts device enumeration, monitors and the hotkey. Safe to call more than once.
    func startWhenBluetoothReady() {
        guard !hasStarted else { return }
        start()
    }

    private func start() {
        hasStarted = true
        refreshDevices()
        refreshRoute()
        startPolling()
        if let address = selectedAddress {
            BluetoothController.prewarm(address: address)
        }
        startAutomation()
    }

    private func startAutomation() {
        let audio = AudioMonitor { [weak self] playing in
            self?.handlePlayback(playing)
        }
        audio.start()
        audioMonitor = audio

        let idle = IdleMonitor { [weak self] in
            self?.handleRelease(trigger: .release, reason: "idle")
        }
        idle.start()
        idleMonitor = idle

        let power = PowerMonitor { [weak self] reason in
            self?.handleRelease(trigger: .release, reason: reason)
        } onWake: { [weak self] in
            // The radio is unreliable right after wake; let it settle before trusting it.
            DispatchQueue.main.asyncAfter(deadline: .now() + PowerMonitor.wakeSettleDelay) {
                self?.refreshRoute()
            }
        }
        power.start()
        powerMonitor = power

        // The hotkey is priority 100 — it overrides automation and ignores the cooldown,
        // so it never feels ignored.
        let key = Hotkey { [weak self] in
            // The HUD is for the shortcut specifically — a menu click already has the
            // panel open in front of the user.
            self?.toggle(showHUD: true)
        }
        key.start()
        hotkey = key
        refreshHotkeyStatus()

        // Scriptable trigger, equivalent to pressing the shortcut:
        //   osascript -e 'do shell script "..."' or, more simply, from any script:
        //   /usr/bin/osascript -e 'tell application id "com.budswitch.mac" to «event»'
        // In practice: notify com.budswitch.mac.toggle
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.budswitch.mac.toggle"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Log.app.log("toggle requested via notification")
            guard let self else { return }
            Task { @MainActor in self.toggle(showHUD: true) }
        }
    }

    // MARK: - Trigger handling

    private func handlePlayback(_ playing: Bool) {
        isPlaying = playing

        // Playback stopping is not a release trigger on its own — pausing a track
        // shouldn't hand the buds to your phone. Idle handles that.
        guard playing else { return }
        guard automationAllowed(), !isRouted else { return }

        let gate = AppFocusMonitor.allowsConnect()
        guard gate.allowed else {
            note("ignored playback — \(gate.reason)")
            return
        }

        let verdict = arbiter.permits(.playback)
        guard verdict.allowed else {
            note("ignored playback — \(verdict.reason)")
            return
        }

        note("connecting — audio from \(gate.reason)")
        arbiter.didSwitch(.playback)
        connect()
    }

    private func handleRelease(trigger: Arbiter.Trigger, reason: String) {
        guard automationAllowed(), isRouted else { return }

        // Never cut a call. Dropping the link takes the microphone with it.
        if Arbiter.isCallActive() {
            note("kept — call in progress")
            return
        }

        // Never release while audio is playing. Idle is measured from keyboard and mouse
        // input, and watching a video or listening to an album is precisely when you stop
        // touching them — so idle alone would pull the buds mid-playback, which it did.
        if isPlaying || AudioRouteProbe.isAnythingPlaying() {
            note("kept — still playing")
            return
        }

        let verdict = arbiter.permits(trigger)
        guard verdict.allowed else {
            note("ignored \(reason) — \(verdict.reason)")
            return
        }

        note("releasing — \(reason)")
        arbiter.didSwitch(trigger)
        disconnect()
    }

    private func automationAllowed() -> Bool {
        guard isAutomationEnabled else { return false }
        guard selectedAddress != nil else { return false }
        return true
    }

    private var noteExpiry: DispatchWorkItem?

    private func note(_ message: String) {
        lastAutomationNote = message
        Log.app.log("automation: \(message, privacy: .public)")

        // Expire it. A note like "ignored playback — cooldown 10s remaining" is useful
        // for a moment and misleading an hour later, when it describes nothing current.
        noteExpiry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.lastAutomationNote = nil
        }
        noteExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// Builds a state with fixed values and no polling, for previews and UI snapshots.
    init(
        previewRouted: Bool,
        outputName: String = "Earbuds",
        outputIsVirtual: Bool = false,
        devices: [BluetoothController.PairedDevice] = [],
        history: [SpikeRecord] = [],
        isBusy: Bool = false,
        liveAddress: String? = nil,
        linkedButIdle: Bool = false
    ) {
        self.isPreview = true
        self.previewLiveAddress = liveAddress ?? (previewRouted ? devices.first?.address : "")
        self.isRouted = previewRouted
        self.isLinkedButIdle = linkedButIdle
        self.currentOutputName = outputName
        self.outputIsVirtual = outputIsVirtual
        self.pairedDevices = devices
        self.history = history
        self.isBusy = isBusy
        self.selectedAddress = devices.first?.address
        self.selectedName = devices.first?.name
    }

    deinit {
        pollTimer?.invalidate()
        // AudioMonitor holds CoreAudio listener blocks that outlive the object unless
        // detached explicitly; without this its stop() was dead code.
        audioMonitor?.stop()
        hotkey?.stop()
    }

    // MARK: - Device selection

    func refreshDevices() {
        pairedDevices = BluetoothController.pairedDevices()
        Log.app.log("found \(self.pairedDevices.count, privacy: .public) paired devices")

        // Drop a selection whose device has been unpaired behind our back. Without this
        // the picker keeps showing a device that no longer exists and every switch fails
        // with kIOReturnNoDevice and no explanation.
        if let address = selectedAddress,
           !pairedDevices.contains(where: { $0.address == address }) {
            Log.app.log("selected device \(address, privacy: .public) is no longer paired — clearing")
            DeviceStore.address = nil
            DeviceStore.name = nil
            selectedAddress = nil
            selectedName = nil
            note("device was unpaired — pick another")
        }

        // Default to a device that is currently the audio route, so the app is useful
        // immediately without making the user open the picker. Also re-runs after the
        // clear above, so unpairing one device falls through to a sensible replacement.
        if selectedAddress == nil,
           let routed = pairedDevices.first(where: {
               AudioRouteProbe.isRoutedToDevice(address: $0.address)
           }) {
            select(address: routed.address, name: routed.name)
        }
    }

    func select(address: String, name: String) {
        DeviceStore.select(address: address, name: name)
        selectedAddress = address
        selectedName = name
        refreshRoute()
        // Pay the (potentially very long) IOBluetoothDevice construction now, in the
        // background, rather than on the first switch the user asks for.
        BluetoothController.prewarm(address: address)
    }

    // MARK: - Route state

    private func startPolling() {
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refreshRoute() }
        }
        // .common so polling keeps running while a menu is open — otherwise the panel
        // freezes its own state display exactly when it is being looked at.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func refreshRoute() {
        // Previews carry fixed state; re-reading the real hardware here would overwrite it
        // the moment the view appears.
        guard !isPreview else { return }

        let output = AudioRouteProbe.defaultOutputDevice()
        currentOutputName = output?.name ?? "—"
        outputIsVirtual = output?.isVirtual ?? false

        guard let address = selectedAddress else {
            isRouted = false
            isLinkedButIdle = false
            return
        }
        let routed = AudioRouteProbe.isRoutedToDevice(address: address)
        isLinkedButIdle = !routed && AudioRouteProbe.outputDevice(forAddress: address) != nil
        if routed != isRouted {
            Log.audio.log("route changed: \(address, privacy: .public) routed=\(routed, privacy: .public)")
        }
        isRouted = routed
    }

    /// Reliability over the recorded attempts. Non-multipoint devices are the only ones
    /// that meaningfully fail, so this is the number that says whether the retry strategy
    /// is good enough — the spec's bar is 9 out of 10.
    var reliability: (successes: Int, total: Int, needsRetryCount: Int)? {
        // No-ops aren't switches. Counting them would let repeated clicks pad the success
        // rate that the 9-out-of-10 acceptance bar is measured against.
        let real = history.filter { !$0.outcome.isNoOp }
        guard !real.isEmpty else { return nil }
        return (
            real.filter(\.outcome.isSuccess).count,
            real.count,
            real.filter { $0.attempts > 1 }.count
        )
    }

    /// Slowest real switch. Surfaces the worst case rather than letting a good average
    /// hide it — measured connects have ranged 1.8s to 6.8s.
    var slowestSwitch: TimeInterval? {
        history.filter { !$0.outcome.isNoOp }.map(\.elapsed).max()
    }

    /// Whether a device currently holds the audio route, independent of which one is
    /// selected. Routed through here so snapshots can supply a fixed answer.
    func isLive(_ device: BluetoothController.PairedDevice) -> Bool {
        if let forced = previewLiveAddress { return device.address == forced }
        return AudioRouteProbe.isRoutedToDevice(address: device.address)
    }

    /// Non-nil only in previews.
    private var previewLiveAddress: String?

    /// True for states built by the preview initializer, which must not be overwritten
    /// by live hardware reads.
    private var isPreview = false

    // MARK: - Actions

    func connect() {
        run { address, done in BluetoothController.connect(address: address, completion: done) }
    }

    func disconnect() {
        run { address, done in BluetoothController.disconnect(address: address, completion: done) }
    }

    /// Menu and hotkey entry point. Records a manual switch so automation backs off for
    /// the cooldown rather than immediately undoing what you just asked for.
    ///
    /// - Parameter showHUD: true when triggered by the shortcut, which fires from any app
    ///   and would otherwise give no feedback at all.
    func toggle(showHUD wantsHUD: Bool = false) {
        let showHUD = wantsHUD && Self.isHUDEnabled
        guard selectedAddress != nil else {
            // Not an error report — it answers "did my keypress register?", which is the
            // one thing the shortcut cannot otherwise communicate.
            if showHUD {
                HUD.shared.show(
                    .init(symbol: "headphones", title: "No device selected", isBusy: false),
                    dismissAfter: 1.3
                )
            }
            return
        }

        // A second press during a switch would be swallowed silently.
        guard !isBusy else { return }

        let goingToMac = !isRouted
        hudRequested = showHUD

        if showHUD {
            HUD.shared.show(
                .init(
                    symbol: goingToMac ? "laptopcomputer" : "iphone",
                    title: goingToMac ? "Connecting…" : "Releasing…",
                    isBusy: true
                ),
                // No auto-dismiss: it stays until the switch resolves, however long
                // that takes. The result call replaces it.
                dismissAfter: nil
            )
        }

        arbiter.didSwitch(.manual)
        note(isRouted ? "released by you" : "connected by you")
        isRouted ? disconnect() : connect()
    }

    /// Whether the in-flight switch should report its result on the HUD.
    private var hudRequested = false

    /// Show the overlay when the shortcut fires.
    ///   defaults write com.budswitch.mac showHUD -bool false
    static var isHUDEnabled: Bool {
        UserDefaults.standard.object(forKey: "showHUD") as? Bool ?? true
    }

    /// Replaces the progress HUD with the outcome.
    private func showResultHUD(_ record: SpikeRecord) {
        guard hudRequested else { return }
        hudRequested = false

        // Report where the buds ended up, judged by the live audio route rather than the
        // operation's own verdict. The route is what the user cares about, and it stays
        // accurate even when the underlying call reports a timeout it recovered from.
        let onMac = isRouted

        HUD.shared.show(
            .init(
                symbol: onMac ? "laptopcomputer" : "iphone",
                title: onMac ? "On this Mac" : "Sent to phone",
                isBusy: false
            ),
            dismissAfter: 1.3
        )
    }

    private func run(
        _ operation: (String, @escaping (SpikeRecord) -> Void) -> Void
    ) {
        guard let address = selectedAddress, !isBusy else { return }
        isBusy = true
        busySeconds = 0
        busyTimer?.invalidate()
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            // Bind before the Task: re-capturing the weak optional inside concurrently
            // executing code is rejected by Swift 5.10.
            guard let self else { return }
            Task { @MainActor in self.busySeconds += 1 }
        }
        RunLoop.main.add(ticker, forMode: .common)
        busyTimer = ticker
        operation(address) { [weak self] record in
            Task { @MainActor in
                guard let self else { return }
                self.history.insert(record, at: 0)
                if self.history.count > 10 { self.history.removeLast() }
                self.isBusy = false
                self.busyTimer?.invalidate()
                self.busyTimer = nil
                self.refreshRoute()
                self.showResultHUD(record)
            }
        }
    }
}
