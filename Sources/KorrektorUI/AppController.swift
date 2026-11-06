import AppKit
import KorrektorCore
import SwiftUI

@MainActor
final class AppController {
    static let shared = AppController()

    /// Set by the window so the shortcut can reopen it after it was closed.
    /// Deliberately no focus juggling: the user pastes back into the app they
    /// came from themselves.
    var windowOpener: (@MainActor () -> Void)?

    private init() {}

    func start() {
        let settings = AppSettings.shared
        settings.onChange = { [weak self] in self?.applySettings() }
        applySettings()
    }

    /// Used while a new shortcut is being recorded.
    func suspendHotkey() {
        HotkeyRegistrar.shared.unregister()
    }

    /// Registers whatever the settings say right now.
    func resumeHotkey() {
        applySettings()
    }

    /// (Re-)registers the global shortcut whenever a setting it depends on changes.
    private func applySettings() {
        let settings = AppSettings.shared

        guard settings.hotkeyEnabled else {
            HotkeyRegistrar.shared.unregister()
            settings.hotkeyProblem = nil
            return
        }

        let combo = settings.hotkey.displayString
        let registered = HotkeyRegistrar.shared.register(settings.hotkey) { [weak self] in
            self?.correctSelection()
        }
        settings.hotkeyProblem = registered
            ? nil
            : "\(combo) is already used by macOS or another app. Pick another shortcut."
    }

    /// "Copy in, paste out": take what the user just copied, correct it in the
    /// window and leave the result on the clipboard. No Accessibility needed.
    private func startReview() {
        guard let text = Clipboard.read(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            HUD.shared.show("Nothing on the clipboard", style: .failure)
            return
        }

        windowOpener?()
        NSApp.activate()

        Task { @MainActor in
            await KorrektorViewModel.shared.loadForReview(text)
        }
    }

    /// The whole point of the app: correct what is selected, right where it is.
    /// Also reachable from the menu bar item, which is handy when the shortcut
    /// is taken or Accessibility access is missing.
    func correctSelection() {
        let settings = AppSettings.shared

        if settings.mode == .reviewInWindow {
            startReview()
            return
        }

        let corrector = SelectionCorrector(
            options: settings.proofreadingOptions,
            mode: settings.mode,
            clipboardFallback: settings.clipboardFallback
        )

        Task { @MainActor in
            HUD.shared.show("Correcting …", style: .working)
            let outcome = await corrector.run { progress in
                Task { @MainActor in
                    HUD.shared.show(progress.status, style: .working)
                }
            }

            switch outcome {
            case .noAccessibilityPermission:
                HUD.shared.show("Accessibility access needed", style: .failure)
                AccessibilityAccess.request()
                AccessibilityAccess.openSystemSettings()
            case .failed(let message):
                HUD.shared.show(message, style: .failure)
            case .nothingSelected, .secureField:
                HUD.shared.show(outcome.message, style: .failure)
            case .replaced, .copied:
                HUD.shared.show(outcome.message, style: .success)
            }
        }
    }
}
