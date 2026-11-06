import Foundation

public struct WordChange: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case unchanged
        case removed
        case added
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Word-level comparison between the author's text and the correction.
///
/// Editors want to see what changed before pasting, so this stays a plain
/// sequence of unchanged/removed/added words plus two ways to display it.
public enum Diff {

    public static func changes(original: String, corrected: String) -> [WordChange] {
        let originalTokens = tokens(original)
        let correctedTokens = tokens(corrected)
        guard originalTokens != correctedTokens else {
            return originalTokens.map { WordChange(kind: .unchanged, text: $0) }
        }

        let difference = correctedTokens.difference(from: originalTokens)
        var removals: Set<Int> = []
        var insertions: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }

        var result: [WordChange] = []
        var originalIndex = 0
        var correctedIndex = 0

        while originalIndex < originalTokens.count || correctedIndex < correctedTokens.count {
            if originalIndex < originalTokens.count, removals.contains(originalIndex) {
                append(.removed, originalTokens[originalIndex], to: &result)
                originalIndex += 1
            } else if correctedIndex < correctedTokens.count, insertions.contains(correctedIndex) {
                append(.added, correctedTokens[correctedIndex], to: &result)
                correctedIndex += 1
            } else if originalIndex < originalTokens.count, correctedIndex < correctedTokens.count {
                append(.unchanged, correctedTokens[correctedIndex], to: &result)
                originalIndex += 1
                correctedIndex += 1
            } else {
                break
            }
        }

        return result
    }

    /// Like `changes`, but with a space inserted where a removed and an added
    /// word sit next to each other, so `kein`/`keine` reads as "kein keine"
    /// instead of "keinkeine".
    public static func displayChanges(original: String, corrected: String) -> [WordChange] {
        var result: [WordChange] = []
        for change in changes(original: original, corrected: corrected) {
            if let last = result.last,
               last.kind != change.kind,
               last.kind != .unchanged,
               change.kind != .unchanged,
               !last.text.hasSuffix(" "),
               !change.text.hasPrefix(" ") {
                result.append(WordChange(kind: .unchanged, text: " "))
            }
            result.append(change)
        }
        return result
    }

    /// Number of words that were changed, added or removed.
    public static func changeCount(original: String, corrected: String) -> Int {
        changes(original: original, corrected: corrected)
            .filter { $0.kind != .unchanged }
            .count
    }

    /// Inline rendering: `[-removed-]` and `{+added+}`, optionally coloured.
    public static func render(original: String, corrected: String, color: Bool) -> String {
        let changeList = displayChanges(original: original, corrected: corrected)
        var output = ""

        for change in changeList {
            switch change.kind {
            case .unchanged:
                output += change.text
            case .removed:
                let body = change.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                output += color ? "\u{1B}[9m\u{1B}[31m\(body)\u{1B}[0m" : "[-\(body)-]"
            case .added:
                let body = change.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                output += color ? "\u{1B}[32m\(body)\u{1B}[0m" : "{+\(body)+}"
            }
        }

        return output
    }

    private static func append(_ kind: WordChange.Kind, _ text: String, to result: inout [WordChange]) {
        if let last = result.last, last.kind == kind {
            result[result.count - 1] = WordChange(kind: kind, text: last.text + text)
        } else {
            result.append(WordChange(kind: kind, text: text))
        }
    }

    private static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentIsWhitespace: Bool?

        for character in text {
            let isWhitespace = character.isWhitespace
            if let previous = currentIsWhitespace, previous != isWhitespace {
                tokens.append(current)
                current = ""
            }
            currentIsWhitespace = isWhitespace
            current.append(character)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}
