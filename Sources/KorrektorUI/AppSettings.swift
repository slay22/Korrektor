import KorrektorCore
import SwiftUI

/// Everything the app remembers between launches, shared by the window, the
/// shortcut handler and the settings pane.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let language = "language"
        static let thorough = "thorough"
        static let automaticCopy = "automaticCopy"
        static let hotkeyEnabled = "hotkeyEnabled"
        static let hotkey = "hotkey"
        static let mode = "mode"
        static let clipboardFallback = "clipboardFallback"
    }

    var languageChoice: LanguageChoice = .automatic {
        didSet { defaults.set(languageChoice.code, forKey: Key.language); notifyChange() }
    }
    var thorough = false {
        didSet { defaults.set(thorough, forKey: Key.thorough); notifyChange() }
    }
    var automaticCopy = true {
        didSet { defaults.set(automaticCopy, forKey: Key.automaticCopy) }
    }
    var hotkeyEnabled = false {
        didSet { defaults.set(hotkeyEnabled, forKey: Key.hotkeyEnabled); notifyChange() }
    }
    var hotkey: Hotkey = .default {
        didSet { defaults.set(hotkey.defaultsValue, forKey: Key.hotkey); notifyChange() }
    }
    var mode: CorrectionMode = .replaceSelection {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode); notifyChange() }
    }
    var clipboardFallback = false {
        didSet { defaults.set(clipboardFallback, forKey: Key.clipboardFallback); notifyChange() }
    }

    /// nil when the shortcut is registered, otherwise why it is not.
    var hotkeyProblem: String?

    /// Called whenever something the shortcut depends on changes.
    var onChange: (@MainActor () -> Void)?

    var proofreadingOptions: ProofreadingOptions {
        ProofreadingOptions(language: languageChoice, thorough: thorough)
    }

    private init() {
        if let stored = defaults.string(forKey: Key.language), let choice = LanguageChoice(code: stored) {
            languageChoice = choice
        }
        thorough = defaults.bool(forKey: Key.thorough)
        if defaults.object(forKey: Key.automaticCopy) != nil {
            automaticCopy = defaults.bool(forKey: Key.automaticCopy)
        }
        hotkeyEnabled = defaults.bool(forKey: Key.hotkeyEnabled)
        if let stored = Hotkey(defaultsValue: defaults.string(forKey: Key.hotkey)) {
            hotkey = stored
        }
        if let stored = defaults.string(forKey: Key.mode), let mode = CorrectionMode(rawValue: stored) {
            self.mode = mode
        }
        if defaults.object(forKey: Key.clipboardFallback) != nil {
            clipboardFallback = defaults.bool(forKey: Key.clipboardFallback)
        }
    }

    private func notifyChange() {
        onChange?()
    }
}
