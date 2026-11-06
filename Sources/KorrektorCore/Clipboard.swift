import AppKit
import Foundation

/// Reading and writing the macOS pasteboard.
///
/// The command-line tool and the app both go through `NSPasteboard`, so a
/// hotkey correction and a `pbpaste | korrektor | pbcopy` call behave alike.
public enum Clipboard {

    public static func read() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    @discardableResult
    public static func write(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    /// A change counter that lets callers wait for another app to fill the
    /// pasteboard after a synthetic ⌘C.
    public static var changeCount: Int {
        NSPasteboard.general.changeCount
    }

    /// Copies items out of the pasteboard so they can be put back afterwards.
    public static func snapshot() -> [NSPasteboardItem] {
        NSPasteboard.general.pasteboardItems?.compactMap { $0.copy() as? NSPasteboardItem } ?? []
    }

    /// Puts a snapshot back, but only when nothing else has taken over the
    /// pasteboard in the meantime.
    public static func restore(_ items: [NSPasteboardItem], ifChangeCountIs changeCount: Int) {
        guard !items.isEmpty, NSPasteboard.general.changeCount == changeCount else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }
}
