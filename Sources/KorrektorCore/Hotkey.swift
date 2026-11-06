import AppKit
import Foundation

/// A global keyboard shortcut: one key plus the modifiers held with it.
///
/// Stored as the raw virtual key code (so it survives layout changes) together
/// with the label captured at recording time, which keeps the UI readable for
/// keys that have no character of their own.
public struct Hotkey: Sendable, Equatable, Codable {
    public struct Modifiers: OptionSet, Sendable, Hashable, Codable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        /// A global shortcut needs at least one of these; Shift alone would
        /// swallow ordinary typing everywhere in the system.
        public static let required: Modifiers = [.control, .option, .command]
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers
    /// Human-readable key, e.g. "K" or "F5". Captured when recorded.
    public var label: String

    public init(keyCode: UInt16, modifiers: Modifiers, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    public static let `default` = Hotkey(keyCode: 40, modifiers: [.control, .option, .command], label: "K")

    public var isValid: Bool {
        !modifiers.intersection(Modifiers.required).isEmpty && !label.isEmpty
    }

    /// "⌃⌥⇧⌘K", in Apple's own modifier order.
    public var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + label
    }

    /// Built from a recorded key press.
    public init(modifierFlags: NSEvent.ModifierFlags, keyCode: UInt16, characters: String?) {
        var modifiers: Modifiers = []
        if modifierFlags.contains(.control) { modifiers.insert(.control) }
        if modifierFlags.contains(.option) { modifiers.insert(.option) }
        if modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if modifierFlags.contains(.command) { modifiers.insert(.command) }
        self.init(keyCode: keyCode, modifiers: modifiers, label: Hotkey.label(forKeyCode: keyCode, characters: characters))
    }

    /// Turns a recorded key press into something printable.
    ///
    /// Function keys and arrows arrive as private-use characters, so they are
    /// mapped by name; everything else keeps the character the user pressed.
    public static func label(forKeyCode keyCode: UInt16, characters: String?) -> String {
        if let characters, let scalar = characters.unicodeScalars.first, characters.unicodeScalars.count == 1 {
            switch scalar.value {
            case 0xF700: return "↑"
            case 0xF701: return "↓"
            case 0xF702: return "←"
            case 0xF703: return "→"
            case 0xF704...0xF70F: return "F\(scalar.value - 0xF703)"
            case 0xF727: return "Insert"
            case 0xF728: return "⌦"
            case 0xF729: return "Home"
            case 0xF72B: return "End"
            case 0xF72C: return "Page Up"
            case 0xF72D: return "Page Down"
            case 0x09: return "Tab"
            case 0x0D: return "Return"
            case 0x1B: return "Escape"
            case 0x20: return "Space"
            case 0x7F: return "⌫"
            default: break
            }
            if scalar.properties.generalCategory != .control, scalar.properties.generalCategory != .unassigned {
                return characters.uppercased()
            }
        }
        return namedKeys[keyCode] ?? "Key \(keyCode)"
    }

    /// Fallback for keys that carry no printable character.
    private static let namedKeys: [UInt16: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "⌫", 53: "Escape", 76: "Enter",
        71: "Clear", 114: "Help", 115: "Home", 116: "Page Up", 117: "⌦", 119: "End",
        121: "Page Down", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
        97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

// MARK: - Recording

/// Turns a recorded key press into a shortcut, and decides what may *not*
/// become one.
public enum HotkeyCapture {
    /// Escape cancels a recording.
    public static let cancelKeyCode: UInt16 = 53

    /// nil when the press is not allowed to be a global shortcut: a bare key or
    /// Shift alone would intercept ordinary typing everywhere in the system.
    public static func hotkey(from event: NSEvent) -> Hotkey? {
        let hotkey = Hotkey(
            modifierFlags: event.modifierFlags,
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers
        )
        return hotkey.isValid ? hotkey : nil
    }
}

/// The state machine behind the recorder: which press counts, and — the part
/// that broke once — whether the recorded combination is actually handed on.
///
/// The app only feeds it key events and reacts to the result; keeping the
/// "apply the closure exactly once, before dropping it" rule here makes that
/// testable without a running app or a real keyboard.
public final class HotkeyRecordingSession {
    public private(set) var isActive = true

    private var onCapture: ((Hotkey) -> Void)?

    public init(onCapture: @escaping (Hotkey) -> Void) {
        self.onCapture = onCapture
    }

    /// Handles one key press. Returns the combination that finished the
    /// recording, or nil when the session either ignores the press or is done
    /// listening (invalid key, Escape).
    @discardableResult
    public func handle(_ event: NSEvent) -> Hotkey? {
        guard isActive else { return nil }

        guard event.keyCode != HotkeyCapture.cancelKeyCode else {
            cancel()
            return nil
        }
        guard let hotkey = HotkeyCapture.hotkey(from: event) else {
            return nil // keep listening: the press just was not allowed
        }

        let apply = onCapture
        isActive = false
        onCapture = nil
        apply?(hotkey)
        return hotkey
    }

    public func cancel() {
        isActive = false
        onCapture = nil
    }
}

// MARK: - Persistence

public extension Hotkey {
    /// Stored as JSON in UserDefaults so a shortcut survives restarts.
    init?(defaultsValue: String?) {
        guard let defaultsValue, let data = defaultsValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Hotkey.self, from: data) else { return nil }
        self = decoded
    }

    var defaultsValue: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
