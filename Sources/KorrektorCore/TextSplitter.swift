import Foundation

/// A paragraph of a document: the text itself plus the line breaks that followed it.
///
/// Keeping the separator separate from the body is what lets Korrektor put a
/// corrected document back together byte-for-byte the way the author wrote it,
/// even when the model decides to drop a blank line.
public struct Segment: Sendable, Equatable {
    public var body: String
    public var separator: String

    public init(body: String, separator: String) {
        self.body = body
        self.separator = separator
    }
}

/// Turns documents into paragraphs and back again, and cuts them into
/// model-sized pieces.
///
/// Paragraphs are separated by runs of two or more newlines. Single newlines
/// stay inside a paragraph, so the signature block of a letter survives as one
/// unit instead of being dotted around.
public enum TextSplitter {

    public static func segments(of text: String) -> [Segment] {
        var segments: [Segment] = []
        var body = ""
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            guard character == "\n" else {
                body.append(character)
                index = text.index(after: index)
                continue
            }

            var end = index
            while end < text.endIndex, text[end] == "\n" {
                end = text.index(after: end)
            }
            let run = String(text[index..<end])
            if run.count >= 2 {
                segments.append(Segment(body: body, separator: run))
                body = ""
            } else {
                body += run
            }
            index = end
        }

        if !body.isEmpty || segments.isEmpty {
            segments.append(Segment(body: body, separator: ""))
        }

        return segments.map(movingTrailingNewlinesIntoSeparator)
    }

    public static func assemble(_ segments: [Segment]) -> String {
        segments.reduce(into: "") { result, segment in
            result += segment.body
            result += segment.separator
        }
    }

    /// Pairs the model's answer with the original paragraph separators.
    ///
    /// Returns nil when the model changed the number of paragraphs, which is the
    /// signal to fall back to correcting paragraph by paragraph.
    public static func rebuild(from corrected: String, using originals: [Segment]) -> [Segment]? {
        let correctedSegments = segments(of: corrected)
        guard correctedSegments.count == originals.count else { return nil }

        return zip(originals, correctedSegments).map { original, corrected in
            Segment(
                body: corrected.body.trimmingTrailingWhitespace(),
                separator: original.separator
            )
        }
    }

    /// Groups consecutive paragraphs into chunks of at most `maxTokens` tokens.
    public static func chunks(
        of segments: [Segment],
        maxTokens: Int,
        tokenCount: (String) async -> Int
    ) async -> [[Segment]] {
        var chunks: [[Segment]] = []
        var current: [Segment] = []
        var currentTokens = 0

        for segment in segments {
            let tokens = await tokenCount(segment.body + segment.separator)
            if !current.isEmpty, currentTokens + tokens > maxTokens {
                chunks.append(current)
                current = []
                currentTokens = 0
            }
            current.append(segment)
            currentTokens += tokens
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        // A one-paragraph tail is cheaper to fold into its neighbour than to send
        // as an extra request, as long as the result still fits.
        if chunks.count >= 2, chunks[chunks.count - 1].count == 1 {
            let tail = chunks[chunks.count - 1]
            let previous = chunks[chunks.count - 2]
            let merged = previous + tail
            var mergedTokens = 0
            for segment in merged {
                mergedTokens += await tokenCount(segment.body + segment.separator)
            }
            if mergedTokens <= maxTokens {
                chunks[chunks.count - 2] = merged
                chunks.removeLast()
            }
        }

        return chunks
    }

    /// Cuts a single oversized paragraph at sentence boundaries.
    ///
    /// Only used for paragraphs that alone exceed the model's budget. The pieces
    /// are corrected separately and joined with a single space, which is the one
    /// place where Korrektor cannot promise byte-exact layout.
    public static func splitLongBody(_ body: String, maxCharacters: Int) -> [String] {
        guard body.count > maxCharacters else { return [body] }

        var pieces: [String] = []
        var current = ""
        var sentence = ""

        func flushSentence() {
            if current.count + sentence.count > maxCharacters, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current += sentence
            sentence = ""
        }

        for character in body {
            sentence.append(character)
            if [".", "!", "?", ":", "\n"].contains(character) {
                flushSentence()
            }
        }
        if !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            flushSentence()
        }
        if !current.isEmpty {
            pieces.append(current)
        }

        return pieces.flatMap { hardSplit($0, maxCharacters: maxCharacters) }
    }

    private static func hardSplit(_ text: String, maxCharacters: Int) -> [String] {
        guard text.count > maxCharacters else { return [text] }

        var pieces: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count > maxCharacters, !current.isEmpty {
                pieces.append(current)
                current = String(word)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            pieces.append(current)
        }
        return pieces
    }

    private static func movingTrailingNewlinesIntoSeparator(_ segment: Segment) -> Segment {
        var body = segment.body
        var moved = ""
        while body.hasSuffix("\n") {
            body.removeLast()
            moved = "\n" + moved
        }
        return Segment(body: body, separator: moved + segment.separator)
    }
}

extension String {
    func trimmingTrailingWhitespace() -> String {
        var result = self
        while let last = result.last, last.isWhitespace {
            result.removeLast()
        }
        return result
    }
}
