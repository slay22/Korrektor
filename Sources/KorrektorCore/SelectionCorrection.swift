import AppKit
import ApplicationServices
import Foundation

// MARK: - Permissions

/// The one permission Korrektor needs for the global shortcut: reading and
/// replacing the selection in other apps goes through the Accessibility API.
public enum AccessibilityAccess {
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks macOS to show the "grant access" dialog.
    public static func request() {
        // Same value as kAXTrustedCheckOptionPrompt, written out because the
        // constant itself is a global var and not concurrency-safe to read.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - What a shortcut press should do

public enum CorrectionMode: String, Codable, Sendable, CaseIterable {
    /// Replace the selected text with the correction.
    case replaceSelection
    /// Leave the text alone and only put the correction on the clipboard.
    case clipboardOnly
    /// Read what was just copied, correct it in the window, put the result back
    /// on the clipboard. Copy in, paste out — no Accessibility access needed.
    case reviewInWindow

    public var label: String {
        switch self {
        case .replaceSelection: "Replace the selected text"
        case .clipboardOnly: "Only copy the correction"
        case .reviewInWindow: "Copy, then review in the window"
        }
    }

    public var explanation: String {
        switch self {
        case .replaceSelection:
            "The corrected text goes back where the selection was. Needs Accessibility access."
        case .clipboardOnly:
            "The document is left untouched and the correction waits on the clipboard. Needs Accessibility access."
        case .reviewInWindow:
            "Takes the text you just copied, corrects it in the window, and keeps the result on the clipboard for you to paste back. Needs no Accessibility access."
        }
    }

    /// The two selection modes read and write other apps' text.
    public var needsAccessibility: Bool {
        self != .reviewInWindow
    }
}

public enum SelectionOutcome: Sendable, Equatable {
    case replaced(changes: Int)
    case copied(changes: Int)
    case nothingSelected
    case noAccessibilityPermission
    case secureField
    case failed(String)

    public var message: String {
        switch self {
        case .replaced(let changes):
            changes == 0 ? "No changes needed" : "Corrected · \(changes) change\(changes == 1 ? "" : "s")"
        case .copied(let changes):
            changes == 0 ? "Copied · no changes needed" : "Copied · \(changes) change\(changes == 1 ? "" : "s")"
        case .nothingSelected:
            "Select some text first"
        case .secureField:
            "Password fields are left alone"
        case .noAccessibilityPermission:
            "Accessibility access needed — open Korrektor settings"
        case .failed(let message):
            message
        }
    }
}

// MARK: - Correcting what is selected

/// One shortcut press, from selection to clipboard: read the selection in the
/// frontmost app, correct it, and either replace it or just copy the result.
///
/// Reading prefers the Accessibility API and falls back to a synthetic ⌘C,
/// because editors disagree about which of the two they support. Writing is the
/// reverse: paste with ⌘V whenever Accessibility writing is not available.
public struct SelectionCorrector: Sendable {
    public var options: ProofreadingOptions
    public var mode: CorrectionMode
    /// Allow the ⌘C/⌘V detour for apps that hide their selection.
    public var clipboardFallback: Bool

    public init(options: ProofreadingOptions, mode: CorrectionMode, clipboardFallback: Bool) {
        self.options = options
        self.mode = mode
        self.clipboardFallback = clipboardFallback
    }

    public func run(onProgress: (@Sendable (ProofreadingProgress) -> Void)? = nil) async -> SelectionOutcome {
        guard AccessibilityAccess.isTrusted else { return .noAccessibilityPermission }

        let element = Accessibility.focusedElement()
        guard let element, !Accessibility.isSecureTextElement(element) else {
            return .secureField
        }

        var selection = Accessibility.selectedText(of: element)
        var readWithCommandC = false

        // The ⌘C detour only makes sense inside something that holds text: in a
        // window that does not, ⌘C can copy whatever happens to be focused.
        if selection?.isEmpty ?? true, clipboardFallback, Accessibility.isTextElement(element) {
            if let copied = await KeyboardCommand.copySelection(), !copied.isEmpty {
                selection = copied
                readWithCommandC = true
            }
        }

        guard let text = selection, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .nothingSelected
        }

        let result: ProofreadingResult
        do {
            result = try await Proofreader(options: options).proofread(text, onProgress: onProgress)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failed(message)
        }

        let changes = Diff.changeCount(original: text, corrected: result.text)
        if mode == .clipboardOnly {
            Clipboard.write(result.text)
            return .copied(changes: changes)
        }

        if !readWithCommandC, Accessibility.replaceSelectedText(of: element, with: result.text) {
            return .replaced(changes: changes)
        }

        await KeyboardCommand.pasteReplacingSelection(result.text)
        return .replaced(changes: changes)
    }
}

// MARK: - Accessibility plumbing

enum Accessibility {

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    static func role(of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    /// Passwords are never read, corrected or replaced.
    static func isSecureTextElement(_ element: AXUIElement) -> Bool {
        role(of: element) == "AXSecureTextField"
    }

    /// Whether ⌘C/⌘V is worth trying: the focused element looks like a place
    /// that holds editable text rather than a list, a canvas or a toolbar.
    static func isTextElement(_ element: AXUIElement) -> Bool {
        guard let role = role(of: element) else { return false }
        return [
            "AXTextField", "AXTextArea", "AXComboBox", "AXWebArea", "AXSearchField",
        ].contains(role)
    }

    static func selectedText(of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    /// Returns false when the app does not let us write its selection, which is
    /// the signal to fall back to pasting.
    static func replaceSelectedText(of element: AXUIElement, with text: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }
}

// MARK: - Synthetic keystrokes

enum KeyboardCommand {

    private enum Key {
        static let c: CGKeyCode = 8
        static let v: CGKeyCode = 9
    }

    /// ⌘C, then wait until the pasteboard actually changes.
    static func copySelection() async -> String? {
        let before = Clipboard.changeCount
        postCommandKey(Key.c)

        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(20))
            if Clipboard.changeCount != before {
                return Clipboard.read()
            }
        }
        return nil
    }

    /// ⌘V with the correction on the clipboard, then hand the clipboard back.
    static func pasteReplacingSelection(_ text: String) async {
        let saved = Clipboard.snapshot()
        Clipboard.write(text)
        let ourChangeCount = Clipboard.changeCount

        postCommandKey(Key.v)

        // Give the receiving app time to read the pasteboard before restoring.
        try? await Task.sleep(for: .milliseconds(400))
        Clipboard.restore(saved, ifChangeCountIs: ourChangeCount)
    }

    private static func postCommandKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
