import Foundation
import FoundationModels

// MARK: - Options and results

public struct ProofreadingOptions: Sendable {
    /// Leave it to `LanguageDetector`, or pin the language the author wrote in.
    public var language: LanguageChoice
    /// Second, narrowly focused pass over the result. Slower, catches the
    /// agreement and word-order errors a model this size likes to skip.
    public var thorough: Bool
    /// Override the automatic token budget per request.
    public var maximumTokensPerChunk: Int?

    public init(
        language: LanguageChoice = .automatic,
        thorough: Bool = false,
        maximumTokensPerChunk: Int? = nil
    ) {
        self.language = language
        self.thorough = thorough
        self.maximumTokensPerChunk = maximumTokensPerChunk
    }
}

public enum ProofreadingPhase: Sendable, Equatable {
    case correcting
    case reviewing
}

public struct ProofreadingProgress: Sendable, Equatable {
    public let phase: ProofreadingPhase
    /// Zero-based index of the section that is about to be sent.
    public let finishedChunks: Int
    public let totalChunks: Int

    public init(phase: ProofreadingPhase, finishedChunks: Int, totalChunks: Int) {
        self.phase = phase
        self.finishedChunks = finishedChunks
        self.totalChunks = totalChunks
    }

    public var status: String {
        let verb = phase == .correcting ? "Correcting" : "Reviewing"
        guard totalChunks > 1 else { return "\(verb) …" }
        return "\(verb) part \(min(finishedChunks + 1, totalChunks)) of \(totalChunks) …"
    }
}

public struct ProofreadingResult: Sendable {
    public let text: String
    /// Language used for the correction. nil when it could not be determined.
    public let language: DocumentLanguage?
    public let languageWasDetected: Bool
    public let warnings: [String]
}

// MARK: - Availability

public enum ModelAvailability: Sendable, Equatable {
    case available
    case unavailable(String)

    public var message: String? {
        if case .unavailable(let message) = self { return message }
        return nil
    }
}

// MARK: - Errors

public enum KorrektorError: LocalizedError, Sendable, Equatable {
    case modelUnavailable(String)
    case emptyInput
    case emptyResponse
    case guardrailViolation
    case refusal
    case contextOverflow
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let message):
            message
        case .emptyInput:
            "No text was given."
        case .emptyResponse:
            "The model returned an empty section. The text was left unchanged."
        case .guardrailViolation:
            "The model declined to process this text because of its safety rules. That happens with very short or unusual passages — try rephrasing that section or run it again."
        case .refusal:
            "The model declined to process this text."
        case .contextOverflow:
            "The text is too long for the model, even after splitting."
        case .failed(let message):
            "Correction failed: \(message)"
        }
    }
}

// MARK: - The proofreader

/// Corrects spelling, grammar and punctuation in German, English, French and
/// Spanish, on device, without touching anything else about the text.
///
/// This is the whole public surface: hand it a string, get a string back. All of
/// the machinery — splitting, token budgets, retries, the second pass — lives
/// behind that one call.
public struct Proofreader: Sendable {
    public let options: ProofreadingOptions

    public init(options: ProofreadingOptions = ProofreadingOptions()) {
        self.options = options
    }

    public static func availability() -> ModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable("This Mac does not support Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return .unavailable("Apple Intelligence is turned off. Enable it in System Settings under “Apple Intelligence & Siri”.")
            case .modelNotReady:
                return .unavailable("The language model is still loading. Try again in a few minutes.")
            @unknown default:
                return .unavailable("The language model is currently unavailable.")
            }
        }
    }

    public func proofread(
        _ text: String,
        onProgress: (@Sendable (ProofreadingProgress) -> Void)? = nil
    ) async throws -> ProofreadingResult {
        if let message = Proofreader.availability().message {
            throw KorrektorError.modelUnavailable(message)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KorrektorError.emptyInput
        }

        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        let counter = TokenCounter(model: model)
        let budget = options.maximumTokensPerChunk ?? max(400, min(3000, (model.contextSize - 800) / 2))

        let detected = LanguageDetector.detect(in: text)
        let language = options.language.language ?? detected
        var warnings: [String] = []

        if let fixed = options.language.language, let detected, detected != fixed {
            warnings.append("The text looks like \(detected.displayName), but it was corrected as \(fixed.displayName).")
        }
        if language == nil, options.language == .automatic {
            warnings.append("Language not recognised — corrected without a language hint.")
        }
        if let language, !SystemLanguageModel.default.supportsLocale(Locale(identifier: language.code)) {
            warnings.append("This system does not fully support \(language.displayName) for the model.")
        }

        // Whitespace around the document belongs to the author, not to the model.
        let leading = String(text.prefix(while: { $0.isWhitespace }))
        let trailing = String(String(text.reversed().prefix(while: { $0.isWhitespace }).reversed()))
        let core = String(text.dropFirst(leading.count).dropLast(trailing.count))

        var corrected = try await transform(
            core,
            instructions: Prompts.proofreading(language: language),
            phase: .correcting,
            budget: budget,
            model: model,
            counter: counter,
            onProgress: onProgress
        )
        warnings += corrected.warnings

        if options.thorough {
            let second = try await transform(
                corrected.text,
                instructions: Prompts.finalReview(language: language),
                phase: .reviewing,
                budget: budget,
                model: model,
                counter: counter,
                onProgress: onProgress
            )
            warnings += second.warnings
            corrected.text = second.text
        }

        return ProofreadingResult(
            text: leading + corrected.text + trailing,
            language: language,
            languageWasDetected: options.language == .automatic,
            warnings: warnings
        )
    }
}

// MARK: - The pipeline

extension Proofreader {

    private struct Outcome {
        var text: String
        var warnings: [String]
    }

    private struct ChunkOutcome {
        var segments: [Segment]
        var warnings: [String]
    }

    private func transform(
        _ text: String,
        instructions: String,
        phase: ProofreadingPhase,
        budget: Int,
        model: SystemLanguageModel,
        counter: TokenCounter,
        onProgress: (@Sendable (ProofreadingProgress) -> Void)?
    ) async throws -> Outcome {
        let segments = await expandOversizedParagraphs(
            TextSplitter.segments(of: text),
            budget: budget,
            counter: counter
        )
        let chunks = await TextSplitter.chunks(of: segments, maxTokens: budget) { text in
            await counter.count(text)
        }

        var correctedSegments: [Segment] = []
        var warnings: [String] = []

        for (index, chunk) in chunks.enumerated() {
            onProgress?(ProofreadingProgress(phase: phase, finishedChunks: index, totalChunks: chunks.count))
            let outcome = try await correct(
                chunk: chunk,
                instructions: instructions,
                phase: phase,
                depth: 0,
                budget: budget,
                model: model
            )
            correctedSegments += outcome.segments
            warnings += outcome.warnings
        }

        return Outcome(
            text: TextSplitter.assemble(correctedSegments),
            warnings: warnings
        )
    }

    /// A paragraph that alone exceeds the budget cannot be sent whole, so it is
    /// cut at sentence boundaries before chunking.
    private func expandOversizedParagraphs(
        _ segments: [Segment],
        budget: Int,
        counter: TokenCounter
    ) async -> [Segment] {
        var result: [Segment] = []
        for segment in segments {
            guard await counter.count(segment.body) > budget, segment.body.count > 200 else {
                result.append(segment)
                continue
            }
            let pieces = TextSplitter.splitLongBody(segment.body, maxCharacters: budget * 4)
            for (index, piece) in pieces.enumerated() {
                result.append(
                    Segment(
                        body: piece.trimmingCharacters(in: .whitespacesAndNewlines),
                        separator: index == pieces.count - 1 ? segment.separator : " "
                    )
                )
            }
        }
        return result
    }

    private func correct(
        chunk: [Segment],
        instructions: String,
        phase: ProofreadingPhase,
        depth: Int,
        budget: Int,
        model: SystemLanguageModel
    ) async throws -> ChunkOutcome {
        let source = TextSplitter.assemble(chunk)

        do {
            let session = LanguageModelSession(model: model, instructions: instructions)
            let prompt = phase == .correcting
                ? Prompts.request(for: source)
                : Prompts.reviewRequest(for: source)
            let response = try await session.respond(to: prompt).content
            return try await repair(response, of: chunk, source: source, instructions: instructions, phase: phase, depth: depth, budget: budget, model: model)
        } catch let error as KorrektorError {
            throw error
        } catch {
            if isContextOverflow(error), chunk.count > 1, depth < 3 {
                let half = chunk.count / 2
                let left = try await correct(chunk: Array(chunk[..<half]), instructions: instructions, phase: phase, depth: depth + 1, budget: budget, model: model)
                let right = try await correct(chunk: Array(chunk[half...]), instructions: instructions, phase: phase, depth: depth + 1, budget: budget, model: model)
                return ChunkOutcome(
                    segments: left.segments + right.segments,
                    warnings: left.warnings + right.warnings
                )
            }
            throw map(error)
        }
    }

    private func repair(
        _ response: String,
        of chunk: [Segment],
        source: String,
        instructions: String,
        phase: ProofreadingPhase,
        depth: Int,
        budget: Int,
        model: SystemLanguageModel
    ) async throws -> ChunkOutcome {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceTrimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty, !sourceTrimmed.isEmpty {
            throw KorrektorError.emptyResponse
        }

        var warnings: [String] = []
        if sourceTrimmed.count > 80, trimmed.count < Int(Double(sourceTrimmed.count) * 0.6) {
            warnings.append("One section got much shorter (\(sourceTrimmed.count) → \(trimmed.count) characters).")
        }

        if let rebuilt = TextSplitter.rebuild(from: response, using: chunk) {
            return ChunkOutcome(segments: rebuilt, warnings: warnings)
        }

        // The model reshaped the paragraphs. Correct them one by one so no
        // paragraph can be silently merged into another.
        guard chunk.count > 1, depth < 3 else {
            let body = trimmed.isEmpty ? sourceTrimmed : trimmed
            return ChunkOutcome(
                segments: [Segment(body: body, separator: chunk.last?.separator ?? "")],
                warnings: warnings
            )
        }

        var segments: [Segment] = []
        for segment in chunk {
            let outcome = try await correct(
                chunk: [segment],
                instructions: instructions,
                phase: phase,
                depth: depth + 1,
                budget: budget,
                model: model
            )
            segments += outcome.segments
            warnings += outcome.warnings
        }
        warnings.append("Paragraphs were corrected one by one because the model changed the paragraph structure.")
        return ChunkOutcome(segments: segments, warnings: warnings)
    }

    private func isContextOverflow(_ error: Error) -> Bool {
        guard let languageModelError = error as? LanguageModelError else { return false }
        if case .contextSizeExceeded = languageModelError { return true }
        return false
    }

    private func map(_ error: Error) -> KorrektorError {
        if let korrektorError = error as? KorrektorError { return korrektorError }
        guard let languageModelError = error as? LanguageModelError else {
            if let localized = error as? LocalizedError, let description = localized.errorDescription {
                return .failed(description)
            }
            return .failed(error.localizedDescription)
        }

        switch languageModelError {
        case .contextSizeExceeded:
            return .contextOverflow
        case .guardrailViolation:
            return .guardrailViolation
        case .refusal:
            return .refusal
        case .timeout:
            return .failed("The model timed out.")
        case .rateLimited:
            return .failed("The model is busy. Wait a moment and try again.")
        case .unsupportedLanguageOrLocale:
            return .failed("This device does not support the language of the text.")
        default:
            return .failed(languageModelError.localizedDescription)
        }
    }
}

// MARK: - Token counting

/// Exact counts from the model's own tokenizer, with a character-based estimate
/// as a fallback so a tokenizer hiccup never blocks the correction.
struct TokenCounter: Sendable {
    let model: SystemLanguageModel

    func count(_ text: String) async -> Int {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        if let exact = try? await model.tokenCount(for: text) {
            return exact
        }
        return max(1, text.count / 4)
    }
}
