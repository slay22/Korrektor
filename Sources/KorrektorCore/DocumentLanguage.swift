import Foundation
import NaturalLanguage

/// The languages Korrektor is designed for.
public enum DocumentLanguage: String, CaseIterable, Sendable, Hashable {
    case german = "de"
    case english = "en"
    case french = "fr"
    case spanish = "es"

    /// Name used in the UI.
    public var displayName: String {
        switch self {
        case .german: "German"
        case .english: "English"
        case .french: "French"
        case .spanish: "Spanish"
        }
    }

    /// Short code as accepted on the command line.
    public var code: String { rawValue }

    init?(nlLanguage: NLLanguage) {
        switch nlLanguage {
        case .german: self = .german
        case .english: self = .english
        case .french: self = .french
        case .spanish: self = .spanish
        default: return nil
        }
    }
}

/// What the caller asked for: a fixed language, or "figure it out".
public enum LanguageChoice: Sendable, Hashable {
    case automatic
    case fixed(DocumentLanguage)

    /// Parses `auto`, `de`, `de-DE`, `german`, … Returns nil for anything unknown.
    public init?(code: String) {
        let normalized = code.lowercased()
        if ["auto", "automatic", ""].contains(normalized) {
            self = .automatic
            return
        }
        let base = normalized.split(separator: "-").first.map(String.init) ?? normalized
        switch base {
        case "de", "ger", "german", "deutsch": self = .fixed(.german)
        case "en", "eng", "english": self = .fixed(.english)
        case "fr", "fre", "fra", "french", "francais", "français": self = .fixed(.french)
        case "es", "spa", "spanish", "espanol", "español": self = .fixed(.spanish)
        default: return nil
        }
    }

    public var language: DocumentLanguage? {
        switch self {
        case .automatic: nil
        case .fixed(let language): language
        }
    }

    /// Round-trips through `init?(code:)`, so settings can be stored as a string.
    public var code: String {
        switch self {
        case .automatic: "auto"
        case .fixed(let language): language.code
        }
    }
}

public enum LanguageDetector {
    /// Best guess at the document language, restricted to the supported four.
    /// Returns nil when the text is too short or the language is not one we handle.
    public static func detect(in text: String) -> DocumentLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        return DocumentLanguage(nlLanguage: dominant)
    }
}
