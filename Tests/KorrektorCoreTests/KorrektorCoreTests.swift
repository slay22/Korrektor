import AppKit
import Foundation
import Testing
@testable import KorrektorCore

// MARK: - Splitting

@Suite("TextSplitter")
struct TextSplitterTests {

    @Test("Round trip keeps the document byte for byte")
    func roundTrip() {
        let documents = [
            "Ein Absatz.",
            "Erster Absatz.\n\nZweiter Absatz.",
            "Hallo Herr Müller,\n\n\nbitte prüfen.\n\nViele Grüße\nLeo\n",
            "  führende Leerzeichen\n\nund eine Leerzeile am Ende\n\n",
            "Nur\nZeilen\nohne\nLeerzeile\n",
            "\n\n",
        ]

        for document in documents {
            #expect(TextSplitter.assemble(TextSplitter.segments(of: document)) == document)
        }
    }

    @Test("Blank lines separate paragraphs, single newlines do not")
    func paragraphBoundaries() {
        let segments = TextSplitter.segments(of: "A\nB\n\nC")
        #expect(segments.count == 2)
        #expect(segments[0].body == "A\nB")
        #expect(segments[0].separator == "\n\n")
        #expect(segments[1].body == "C")
    }

    @Test("Rebuild keeps the original separators")
    func rebuildUsesOriginalSeparators() {
        let originals = TextSplitter.segments(of: "Eins.\n\nZwei.\n\nDrei.")
        let rebuilt = TextSplitter.rebuild(from: "Eins!\n\nZwei!\n\nDrei!", using: originals)
        #expect(rebuilt != nil)
        #expect(TextSplitter.assemble(rebuilt!) == "Eins!\n\nZwei!\n\nDrei!")
    }

    @Test("A different paragraph count is reported instead of guessed")
    func rebuildDetectsReshaping() {
        let originals = TextSplitter.segments(of: "Eins.\n\nZwei.")
        #expect(TextSplitter.rebuild(from: "Eins. Zwei.", using: originals) == nil)
    }

    @Test("Chunks respect the token budget and keep the order")
    func chunking() async {
        let text = (1...6).map { "Absatz Nummer \($0) mit etwas Text darin." }.joined(separator: "\n\n")
        let segments = TextSplitter.segments(of: text)
        let chunks = await TextSplitter.chunks(of: segments, maxTokens: 20) { _ in 8 }

        #expect(chunks.count > 1)
        #expect(chunks.flatMap { $0 } == segments)
        for chunk in chunks {
            #expect(chunk.count <= 3)
        }
    }

    @Test("A single paragraph becomes one chunk even when it is too big")
    func oversizedParagraphStaysWhole() async {
        let segments = TextSplitter.segments(of: "Ein sehr langer Absatz.")
        let chunks = await TextSplitter.chunks(of: segments, maxTokens: 5) { _ in 100 }
        #expect(chunks.count == 1)
    }

    @Test("Long paragraphs are cut at sentence boundaries")
    func splitLongBody() {
        let body = String(repeating: "Das ist ein Satz. ", count: 40)
        let pieces = TextSplitter.splitLongBody(body, maxCharacters: 120)

        #expect(pieces.count > 1)
        for piece in pieces {
            #expect(piece.count <= 120)
        }
        #expect(pieces.joined(separator: " ").contains("Das ist ein Satz."))
    }

    @Test("Short paragraphs are left alone")
    func shortBodyUntouched() {
        #expect(TextSplitter.splitLongBody("Kurz.", maxCharacters: 100) == ["Kurz."])
    }
}

// MARK: - Diff

@Suite("Diff")
struct DiffTests {

    @Test("Identical texts produce no changes")
    func identical() {
        #expect(Diff.changeCount(original: "Alles gut.", corrected: "Alles gut.") == 0)
    }

    @Test("A replaced word counts as one change")
    func replacement() {
        let original = "Ich habe kein Zeit."
        let corrected = "Ich habe keine Zeit."
        #expect(Diff.changeCount(original: original, corrected: corrected) == 2)

        let plain = Diff.render(original: original, corrected: corrected, color: false)
        #expect(plain.contains("[-kein-]"))
        #expect(plain.contains("{+keine+}"))
    }

    @Test("Changes keep the surrounding text intact")
    func keepsSurroundings() {
        let unlimited = Diff.changes(original: "a b c", corrected: "a b c")
        #expect(unlimited.allSatisfy { $0.kind == .unchanged })
        #expect(unlimited.map(\.text).joined() == "a b c")
    }

    @Test("A replaced word is rendered with a separator")
    func displaySeparator() {
        let rendered = Diff.render(original: "Ich habe kein Zeit.", corrected: "Ich habe keine Zeit.", color: false)
        #expect(rendered.contains("[-kein-] {+keine+}"))
    }

    @Test("Insertions and removals at the edges are handled")
    func edges() {
        #expect(Diff.changeCount(original: "Text", corrected: "Ein Text") == 1)
        #expect(Diff.changeCount(original: "Ein Text", corrected: "Text") == 1)
    }
}

// MARK: - Language

@Suite("Language")
struct LanguageTests {

    @Test("Language codes are parsed generously")
    func parsing() {
        #expect(LanguageChoice(code: "auto") == .automatic)
        #expect(LanguageChoice(code: "DE") == .fixed(.german))
        #expect(LanguageChoice(code: "de-AT") == .fixed(.german))
        #expect(LanguageChoice(code: "francais") == .fixed(.french))
        #expect(LanguageChoice(code: "Français") == .fixed(.french))
        #expect(LanguageChoice(code: "es-MX") == .fixed(.spanish))
        #expect(LanguageChoice(code: "italiano") == nil)
    }

    @Test("Detection recognises the four supported languages")
    func detection() {
        #expect(LanguageDetector.detect(in: "Ich gehe heute mit meinem Hund in den Park und danach noch einkaufen.") == .german)
        #expect(LanguageDetector.detect(in: "I am going to the park with my dog this afternoon and then shopping.") == .english)
        #expect(LanguageDetector.detect(in: "Je vais au parc avec mon chien cet après-midi et ensuite faire les courses.") == .french)
        #expect(LanguageDetector.detect(in: "Voy al parque con mi perro esta tarde y después a comprar la cena para todos.") == .spanish)
    }
}

// MARK: - Model

@Suite("Proofreader", .enabled(if: ProcessInfo.processInfo.environment["KORREKTOR_LIVE"] == "1"))
struct LiveProofreaderTests {

    @Test("German text is corrected on device")
    func german() async throws {
        let result = try await Proofreader().proofread("Ich habe kein Zeit und das ist nicht gut so.")
        #expect(result.text.contains("keine Zeit"))
    }
}

// MARK: - Hotkey

@Suite("Hotkey")
struct HotkeyTests {

    @Test("Display string follows Apple's modifier order")
    func displayString() {
        let hotkey = Hotkey(keyCode: 40, modifiers: [.command, .shift, .option, .control], label: "K")
        #expect(hotkey.displayString == "⌃⌥⇧⌘K")

        #expect(Hotkey(keyCode: 40, modifiers: [.command, .option], label: "K").displayString == "⌥⌘K")
        #expect(Hotkey.default.displayString == "⌃⌥⌘K")
    }

    @Test("A shortcut needs a modifier that does not swallow plain typing")
    func validity() {
        #expect(Hotkey.default.isValid)
        #expect(!Hotkey(keyCode: 40, modifiers: [], label: "K").isValid)
        #expect(!Hotkey(keyCode: 40, modifiers: [.shift], label: "K").isValid)
        #expect(Hotkey(keyCode: 40, modifiers: [.control], label: "K").isValid)
    }

    @Test("Labels for keys without a printable character")
    func labels() {
        #expect(Hotkey.label(forKeyCode: 40, characters: "k") == "K")
        #expect(Hotkey.label(forKeyCode: 122, characters: nil) == "F1")
        #expect(Hotkey.label(forKeyCode: 126, characters: "\u{F700}") == "↑")
        #expect(Hotkey.label(forKeyCode: 49, characters: " ") == "Space")
    }

    @Test("Shortcuts survive a round trip through storage")
    func persistence() {
        let original = Hotkey(keyCode: 97, modifiers: [.control, .shift], label: "F6")
        guard let stored = original.defaultsValue else {
            Issue.record("could not encode")
            return
        }
        #expect(Hotkey(defaultsValue: stored) == original)
        #expect(Hotkey(defaultsValue: nil) == nil)
        #expect(Hotkey(defaultsValue: "not json") == nil)
    }

    @Test("Recording maps modifier flags to the model")
    func recording() {
        let hotkey = Hotkey(modifierFlags: [.command, .option], keyCode: 40, characters: "k")
        #expect(hotkey.modifiers == [.command, .option])
        #expect(hotkey.label == "K")
        #expect(hotkey.displayString == "⌥⌘K")
    }
}

@Suite("HotkeyCapture")
struct HotkeyCaptureTests {

    private func keyDown(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    @Test("A recorded combination becomes a hotkey")
    func records() {
        let hotkey = HotkeyCapture.hotkey(from: keyDown("j", keyCode: 38, modifiers: [.control, .option]))
        #expect(hotkey?.keyCode == 38)
        #expect(hotkey?.modifiers == [.control, .option])
        #expect(hotkey?.displayString == "⌃⌥J")
    }

    @Test("Keys that would swallow ordinary typing are rejected")
    func rejects() {
        #expect(HotkeyCapture.hotkey(from: keyDown("j", keyCode: 38, modifiers: [])) == nil)
        #expect(HotkeyCapture.hotkey(from: keyDown("j", keyCode: 38, modifiers: [.shift])) == nil)
    }

    @Test("Escape is the cancel key")
    func cancelKey() {
        #expect(HotkeyCapture.cancelKeyCode == 53)
        #expect(HotkeyCapture.hotkey(from: keyDown("\u{1B}", keyCode: 53, modifiers: [])) == nil)
    }
}

@Suite("HotkeyRecordingSession")
struct HotkeyRecordingSessionTests {

    private func keyDown(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    @Test("A valid press hands the combination on — exactly once")
    func appliesCapture() {
        var received: [Hotkey] = []
        let session = HotkeyRecordingSession { received.append($0) }

        let captured = session.handle(keyDown("j", keyCode: 38, modifiers: [.control, .option]))

        #expect(captured?.displayString == "⌃⌥J")
        #expect(received.map(\.displayString) == ["⌃⌥J"])
        #expect(!session.isActive)

        // A second press must not fire again.
        session.handle(keyDown("k", keyCode: 40, modifiers: [.control]))
        #expect(received.count == 1)
    }

    @Test("A rejected press keeps the session listening")
    func keepsListening() {
        var received: [Hotkey] = []
        let session = HotkeyRecordingSession { received.append($0) }

        #expect(session.handle(keyDown("j", keyCode: 38, modifiers: [])) == nil)
        #expect(session.isActive)
        #expect(received.isEmpty)

        #expect(session.handle(keyDown("j", keyCode: 38, modifiers: [.command]))?.displayString == "⌘J")
        #expect(received.count == 1)
    }

    @Test("Escape cancels without capturing")
    func cancels() {
        var received: [Hotkey] = []
        let session = HotkeyRecordingSession { received.append($0) }

        session.handle(keyDown("\u{1B}", keyCode: 53, modifiers: []))
        #expect(received.isEmpty)
        #expect(!session.isActive)
    }
}
