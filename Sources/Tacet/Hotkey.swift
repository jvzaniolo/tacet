import AppKit
import Carbon.HIToolbox
import Observation

/// The global shortcut: the same as clicking the arrow, from any app.
/// ⇧⌘< (Shift-comma on US and ABNT2 keyboards; it looks like the « arrow)
/// unless the user records another one in Settings. Not ⇧⌘←: a global hot
/// key would take "select to start of line" from every text field.
///
/// Carbon's RegisterEventHotKey needs no permission. An NSEvent global
/// monitor or an event tap would need Input Monitoring or Accessibility,
/// and Tacet's only grant is the switches file. Recording uses a local
/// monitor on Tacet's own window, which needs nothing either.
@MainActor
@Observable
final class Hotkey {
    enum Problem: Equatable {
        /// Only Shift, or no modifier: it would fire while typing.
        case needsModifier
        /// macOS uses it (System Settings › Keyboard › Keyboard Shortcuts).
        case system(String)
        /// Another app registered it first.
        case taken(String)
    }

    private static let shortcutKey = "shortcut"

    /// nil: the user removed it (Esc in the recorder).
    private(set) var shortcut: Shortcut? = {
        guard let saved = UserDefaults.standard.dictionary(forKey: shortcutKey) else { return .standard }
        return Shortcut(defaults: saved)   // an empty dictionary: removed
    }()
    /// Set, but another app already has it.
    private(set) var isTaken = false
    var isActive: Bool { shortcut != nil && !isTaken && !isPaused }
    /// While Settings records a new shortcut, so pressing the current one
    /// reaches the recorder.
    private var isPaused = false

    @ObservationIgnored var onPress: (() -> Void)?
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?

    func start() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            // Carbon delivers hot keys on the main thread.
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                Log.write("Shortcut: pressed")
                hotkey.onPress?()
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr { Log.write("Shortcut: event handler failed (\(status))") }
        apply()
    }

    /// Tries again if another app had the shortcut (it may have quit).
    func retryIfTaken() {
        if isTaken { apply() }
    }

    func pause() {
        isPaused = true
        unregister()
    }

    func resume() {
        isPaused = false
        apply()
    }

    /// Switches to a recorded shortcut, or keeps the current one and says why not.
    func change(to new: Shortcut) -> Problem? {
        if !new.hasModifier { return .needsModifier }
        if new.isSystemShortcut { return .system(new.display) }
        unregister()
        if register(new) != noErr {
            if let shortcut, !isPaused { _ = register(shortcut) }
            return .taken(new.display)
        }
        shortcut = new
        isTaken = false
        UserDefaults.standard.set(new.defaults, forKey: Self.shortcutKey)
        Log.write("Shortcut: changed")
        if isPaused { unregister() }
        return nil
    }

    func remove() {
        unregister()
        shortcut = nil
        isTaken = false
        UserDefaults.standard.set([String: Any](), forKey: Self.shortcutKey)
        Log.write("Shortcut: removed")
    }

    func restoreDefault() -> Problem? {
        shortcut == .standard ? nil : change(to: .standard)
    }

    private func apply() {
        unregister()
        guard let shortcut, !isPaused else {
            isTaken = false
            return
        }
        let status = register(shortcut)
        isTaken = status != noErr
        Log.write(isTaken ? "Shortcut: taken by another app (\(status))" : "Shortcut: registered")
    }

    private func register(_ shortcut: Shortcut) -> OSStatus {
        let id = EventHotKeyID(signature: OSType(0x5461_6374), id: 1)   // 'Tact'
        // Exclusive: fail, rather than share, if another app registered it.
        return RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(),
                                   OptionBits(kEventHotKeyExclusive), &hotKey)
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}

/// A key (by its position, so it survives layout changes) and modifiers.
struct Shortcut: Equatable {
    let keyCode: UInt32
    let modifiers: NSEvent.ModifierFlags

    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_Comma), modifiers: [.command, .shift])

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .option, .control, .shift])
    }

    init(event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags)
    }

    init?(defaults: [String: Any]?) {
        guard let code = defaults?["keyCode"] as? Int, let mods = defaults?["modifiers"] as? Int else { return nil }
        self.init(keyCode: UInt32(code), modifiers: NSEvent.ModifierFlags(rawValue: UInt(mods)))
    }

    var defaults: [String: Any] { ["keyCode": Int(keyCode), "modifiers": Int(modifiers.rawValue)] }

    /// ⌘, ⌥ or ⌃ (Shift alone isn't enough), except on the function keys.
    var hasModifier: Bool {
        !modifiers.intersection([.command, .option, .control]).isEmpty || Self.functionKeys.contains(Int(keyCode))
    }

    var carbonModifiers: UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        return UInt32(flags)
    }

    /// Enabled macOS shortcuts (Spotlight, screenshots, Mission Control…):
    /// registering one succeeds, but it never fires.
    var isSystemShortcut: Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        return list.contains { entry in
            (entry[kHISymbolicHotKeyEnabled] as? Bool ?? false)
                && (entry[kHISymbolicHotKeyCode] as? Int).map { UInt32($0) } == keyCode
                && (entry[kHISymbolicHotKeyModifiers] as? Int).map { UInt32($0) & UInt32(cmdKey | optionKey | controlKey | shiftKey) } == carbonModifiers
        }
    }

    /// How menus write it: modifiers in macOS order (⌃⌥⇧⌘), then the key as
    /// the current layout types it. With Shift, a symbol key shows its
    /// shifted character: ⇧⌘< rather than ⇧⌘, (letters stay uppercase).
    var display: String { Self.symbols(modifiers) + keyName }

    static func symbols(_ modifiers: NSEvent.ModifierFlags) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text
    }

    /// For the show/hide item in the arrow's menu.
    var keyEquivalent: String {
        if let special = Self.special[Int(keyCode)] { return special.equivalent }
        return Self.character(for: keyCode, shift: modifiers.contains(.shift))?.lowercased() ?? ""
    }

    private var keyName: String {
        if let special = Self.special[Int(keyCode)] { return special.name }
        return Self.character(for: keyCode, shift: modifiers.contains(.shift))?.uppercased() ?? "?"
    }

    private static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                                                 kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                                                 kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    private static let special: [Int: (name: String, equivalent: String)] = {
        func f(_ n: Int) -> String { String(Character(UnicodeScalar(NSF1FunctionKey + n - 1)!)) }
        func k(_ c: Int) -> String { String(Character(UnicodeScalar(c)!)) }
        var table: [Int: (String, String)] = [
            kVK_Space: (String(localized: "Space"), " "), kVK_Return: ("↩", "\r"), kVK_Tab: ("⇥", "\t"),
            kVK_Delete: ("⌫", k(NSBackspaceCharacter)), kVK_ForwardDelete: ("⌦", k(NSDeleteFunctionKey)),
            kVK_Escape: ("⎋", "\u{1b}"), kVK_Home: ("↖", k(NSHomeFunctionKey)), kVK_End: ("↘", k(NSEndFunctionKey)),
            kVK_PageUp: ("⇞", k(NSPageUpFunctionKey)), kVK_PageDown: ("⇟", k(NSPageDownFunctionKey)),
            kVK_LeftArrow: ("←", k(NSLeftArrowFunctionKey)), kVK_RightArrow: ("→", k(NSRightArrowFunctionKey)),
            kVK_UpArrow: ("↑", k(NSUpArrowFunctionKey)), kVK_DownArrow: ("↓", k(NSDownArrowFunctionKey)),
        ]
        for (i, code) in [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                          kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20].enumerated() {
            table[code] = ("F\(i + 1)", f(i + 1))
        }
        return table
    }()

    /// What the key types in the current keyboard layout.
    private static func character(for keyCode: UInt32, shift: Bool) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { bytes in
            UCKeyTranslate(bytes.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self), UInt16(keyCode),
                           UInt16(kUCKeyActionDisplay), shift ? UInt32(shiftKey >> 8) : 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
