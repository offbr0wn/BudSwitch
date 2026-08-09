import AppKit
import Carbon.HIToolbox
import Foundation

/// Global hotkey for toggling the buds.
///
/// Uses `RegisterEventHotKey`, which registers one specific combination with the window
/// server. The app is woken only for that key and never sees other keystrokes — so it
/// needs **no Accessibility permission**, verified against a machine with Accessibility
/// denied.
///
/// The obvious-looking alternative, `NSEvent.addGlobalMonitorForEvents`, asks for the
/// entire system-wide keystroke stream. macOS cannot distinguish that from a keylogger,
/// so it is gated behind Accessibility — a prompt this app has no reason to make the user
/// answer.
///
/// The spec warns against hand-rolling Carbon hotkeys and recommends the KeyboardShortcuts
/// package. That package wraps this same API (see its `CarbonKeyboardShortcuts.swift`); it
/// is unbuildable here only because its macros need full Xcode. This is the same
/// mechanism, kept small: register, handle, unregister.
final class Hotkey {

    /// A key combination, stored as a key code plus modifier flags.
    struct Combo: Equatable {
        var keyCode: UInt16
        /// Raw `NSEvent.ModifierFlags` value, device-independent bits only.
        var modifiers: UInt

        var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

        /// Only the four modifiers a shortcut can actually be bound to.
        ///
        /// `deviceIndependentFlagsMask` also carries `.capsLock` and `.numericPad`, so
        /// comparing against it means caps lock being on — or an external keyboard
        /// reporting a numeric pad — silently stops the hotkey from ever matching.
        static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

        /// ⌃⌥⌘B — chosen to avoid collisions with common system and app shortcuts.
        static let `default` = Combo(
            keyCode: UInt16(kVK_ANSI_B),
            modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue
        )

        /// Human-readable form for the menu, e.g. "⌃⌥⌘B".
        ///
        /// Modifier order matches Apple's convention (⌃⌥⇧⌘), so the shortcut reads the
        /// way it does everywhere else in macOS.
        var display: String {
            var result = ""
            if flags.contains(.control) { result += "⌃" }
            if flags.contains(.option) { result += "⌥" }
            if flags.contains(.shift) { result += "⇧" }
            if flags.contains(.command) { result += "⌘" }
            return result + Self.name(for: keyCode)
        }

        /// Keys whose glyph can't be derived from the keyboard layout — either because
        /// they produce no character, or because the character is unreadable in a label.
        private static let specialNames: [UInt16: String] = [
            UInt16(kVK_Space): "Space",
            UInt16(kVK_Return): "↩",
            UInt16(kVK_Tab): "⇥",
            UInt16(kVK_Delete): "⌫",
            UInt16(kVK_ForwardDelete): "⌦",
            UInt16(kVK_Escape): "⎋",
            UInt16(kVK_LeftArrow): "←",
            UInt16(kVK_RightArrow): "→",
            UInt16(kVK_UpArrow): "↑",
            UInt16(kVK_DownArrow): "↓",
            UInt16(kVK_Home): "↖",
            UInt16(kVK_End): "↘",
            UInt16(kVK_PageUp): "⇞",
            UInt16(kVK_PageDown): "⇟",
            UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
            UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
            UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
            UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
            UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
            UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
            UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
        ]

        /// Resolves a key code to its label using the *current* keyboard layout, so a
        /// non-US layout shows the key the user actually pressed rather than the US
        /// equivalent. Falls back to the raw code if the layout can't be read.
        static func name(for keyCode: UInt16) -> String {
            if let special = specialNames[keyCode] { return special }

            guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { return "#\(keyCode)" }

            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)

            let status = data.withUnsafeBytes { buffer -> OSStatus in
                guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                    return OSStatus(-1)
                }
                return UCKeyTranslate(
                    layout,
                    keyCode,
                    UInt16(kUCKeyActionDisplay),
                    0, // no modifiers: we want the key's own label, not the shifted glyph
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
            }

            guard status == noErr, length > 0 else { return "#\(keyCode)" }
            return String(utf16CodeUnits: characters, count: length).uppercased()
        }

        /// A shortcut with no modifiers — or only Shift — would fire while typing.
        var isSafe: Bool {
            let mods = flags.intersection(Self.relevant)
            if mods.contains(.control) || mods.contains(.option) || mods.contains(.command) {
                return true
            }
            // Function keys are safe bare; they produce no text.
            return Self.specialNames[keyCode]?.hasPrefix("F") == true
        }
    }

    /// Persisted so a custom binding survives relaunch.
    ///   defaults write com.budswitch.mac hotkeyKeyCode -int 11
    ///   defaults write com.budswitch.mac hotkeyModifiers -int 1572864
    static var combo: Combo {
        get {
            let defaults = UserDefaults.standard
            guard let code = defaults.object(forKey: "hotkeyKeyCode") as? Int,
                  let mods = defaults.object(forKey: "hotkeyModifiers") as? Int
            else { return .default }
            return Combo(keyCode: UInt16(code), modifiers: UInt(mods))
        }
        set {
            UserDefaults.standard.set(Int(newValue.keyCode), forKey: "hotkeyKeyCode")
            UserDefaults.standard.set(Int(newValue.modifiers), forKey: "hotkeyModifiers")
        }
    }

    /// Whether the hotkey is armed at all.
    ///   defaults write com.budswitch.mac hotkeyEnabled -bool false
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "hotkeyEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hotkeyEnabled") }
    }

    /// Always true: `RegisterEventHotKey` needs no permission at all.
    ///
    /// Kept so callers don't have to care which mechanism is in use.
    static var hasPermission: Bool { true }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// Registered instances, keyed by the id handed to Carbon. The C callback gets no
    /// context pointer worth trusting across re-registration, so it looks up here.
    private static var instances: [UInt32: Hotkey] = [:]
    private static var nextID: UInt32 = 1

    private var id: UInt32 = 0

    init(action: @escaping () -> Void) {
        self.action = action
    }

    deinit { stop() }

    func start() {
        stop()
        guard Self.isEnabled else { return }

        let combo = Self.combo
        id = Self.nextID
        Self.nextID += 1
        Self.instances[id] = self

        // One handler for hot-key presses. Installed per instance and torn down in stop(),
        // so repeated rebinding doesn't stack handlers.
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var pressedID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &pressedID
            )
            guard status == noErr,
                  let hotkey = Hotkey.instances[pressedID.id]
            else { return OSStatus(eventNotHandledErr) }

            Log.app.log("hotkey pressed")
            DispatchQueue.main.async { hotkey.action() }
            return noErr
        }, 1, &spec, nil, &handlerRef)

        // Registers *this combination* with the window server. The app is woken only for
        // this key — it never sees other keystrokes, which is exactly why no Accessibility
        // permission is required. A global NSEvent monitor, by contrast, asks for the
        // entire keystroke stream and is gated accordingly.
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            Self.carbonModifiers(from: combo.flags),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            Log.app.log("hotkey armed: \(combo.display, privacy: .public)")
        } else {
            // Most likely another app already owns the combination.
            Log.app.error("hotkey registration failed for \(combo.display, privacy: .public): \(status, privacy: .public)")
            Self.instances.removeValue(forKey: id)
        }
    }

    /// True when the current binding failed to register — usually taken by another app.
    var isConflicted: Bool {
        Self.isEnabled && hotKeyRef == nil
    }

    func stop() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = handlerRef { RemoveEventHandler(ref) }
        hotKeyRef = nil
        handlerRef = nil
        Self.instances.removeValue(forKey: id)
    }

    /// Re-arms after a binding change.
    func reload() { start() }

    private static let signature = OSType(0x42535731) // 'BSW1'

    /// Carbon uses its own modifier constants, not `NSEvent.ModifierFlags`.
    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
}
