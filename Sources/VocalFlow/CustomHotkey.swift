import AppKit

/// A user-recorded trigger: either a lone modifier key (e.g. Right Shift) held on its own,
/// or a regular key with optional modifiers (e.g. F5, ⌃⌥Space) held down to record.
struct CustomHotkey: Codable, Equatable {
    let keyCode: UInt16
    /// Raw `NSEvent.ModifierFlags` limited to `CustomHotkey.relevantModifiers`. Empty for
    /// modifier-only hotkeys.
    let modifiers: UInt
    /// Shown in Settings, captured when recorded (e.g. "⌃⌥Space", "F5", "Right Shift").
    let displayName: String

    static let defaultsKey = "custom_hotkey"

    /// Modifiers that must match for a key-combination hotkey. `.function` is left out because
    /// macOS sets it on F-keys and arrows by itself.
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// True for a modifier key held on its own; detected via `flagsChanged`.
    var isModifierOnly: Bool { Self.modifierFlag(forKeyCode: keyCode) != nil }

    /// The flag a modifier key toggles, or nil if `keyCode` isn't a usable modifier key.
    /// Caps Lock is excluded — it latches instead of reporting press/release.
    static func modifierFlag(forKeyCode keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: return .command   // right, left
        case 56, 60: return .shift     // left, right
        case 58, 61: return .option    // left, right
        case 59, 62: return .control   // left, right
        case 63:     return .function
        default:     return nil
        }
    }

    static func modifierKeyName(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 54: return "Right Command (⌘)"
        case 55: return "Left Command (⌘)"
        case 56: return "Left Shift (⇧)"
        case 60: return "Right Shift (⇧)"
        case 58: return "Left Option (⌥)"
        case 61: return "Right Option (⌥)"
        case 59: return "Left Control (⌃)"
        case 62: return "Right Control (⌃)"
        case 63: return "Fn (🌐)"
        default: return "Key \(keyCode)"
        }
    }

    /// Keys that type nothing by themselves, so they're safe to use without a modifier.
    static func isStandaloneKey(_ keyCode: UInt16) -> Bool {
        functionKeyNames[keyCode] != nil
    }

    static let functionKeyNames: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    static let specialKeyNames: [UInt16: String] = [
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 117: "⌦", 115: "Home", 119: "End",
        116: "Page Up", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑", 76: "Enter",
    ]

    static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    /// Builds a hotkey from a key press while recording, or explains why it can't be used.
    static func fromKeyPress(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?)
        -> Result<CustomHotkey, RecordingError>
    {
        if keyCode == 53 { return .failure(.escapeReserved) }
        let mods = flags.intersection(relevantModifiers)
        if mods.isEmpty && !isStandaloneKey(keyCode) { return .failure(.needsModifier) }
        let keyName = functionKeyNames[keyCode] ?? specialKeyNames[keyCode]
            ?? (characters?.uppercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "Key \(keyCode)"
        return .success(CustomHotkey(keyCode: keyCode, modifiers: mods.rawValue,
                                     displayName: symbols(for: mods) + keyName))
    }

    static func fromModifierKey(_ keyCode: UInt16) -> CustomHotkey? {
        guard modifierFlag(forKeyCode: keyCode) != nil else { return nil }
        return CustomHotkey(keyCode: keyCode, modifiers: 0, displayName: modifierKeyName(keyCode))
    }

    enum RecordingError: Error, Equatable {
        case escapeReserved, needsModifier

        var message: String {
            switch self {
            case .escapeReserved: return "Esc is reserved for cancelling a recording."
            case .needsModifier:  return "Add ⌃, ⌥, ⇧ or ⌘ — or use a function key (F1–F20) — so normal typing isn't blocked."
            }
        }
    }

    // MARK: Persistence

    static func load(from defaults: UserDefaults = .standard) -> CustomHotkey? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(CustomHotkey.self, from: data)
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
