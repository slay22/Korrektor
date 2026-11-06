import KorrektorCore
import SwiftUI

// MARK: - View model

@MainActor
@Observable
final class KorrektorViewModel {
    /// One window, one view model: the shortcut fills the same window the user
    /// is already working in.
    static let shared = KorrektorViewModel()

    var input = ""
    var output = "" {
        didSet { scheduleAutomaticCopy() }
    }
    var showsDiff = false

    /// Settings live in one place; the window edits them directly.
    var settings = AppSettings.shared

    var languageChoice: LanguageChoice {
        get { settings.languageChoice }
        set { settings.languageChoice = newValue }
    }

    var thorough: Bool {
        get { settings.thorough }
        set { settings.thorough = newValue }
    }

    var automaticCopy: Bool {
        get { settings.automaticCopy }
        set { settings.automaticCopy = newValue }
    }

    private(set) var isWorking = false
    private(set) var statusMessage = ""
    private(set) var errorMessage: String?
    private(set) var changeCount = 0
    private(set) var detectedLanguage: DocumentLanguage?
    private(set) var warnings: [String] = []

    private var automaticCopyTask: Task<Void, Never>?

    var hasResult: Bool { !output.isEmpty }

    var canCorrect: Bool {
        !isWorking && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the shortcut does in "review in the window" mode: fill the window
    /// with the copied text and start correcting straight away.
    func loadForReview(_ text: String) async {
        input = text
        output = ""
        showsDiff = false
        changeCount = 0
        errorMessage = nil
        warnings = []
        await correct()
    }

    func correct() async {
        guard !isWorking else { return }
        let text = input
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isWorking = true
        errorMessage = nil
        warnings = []
        statusMessage = "Correcting …"
        defer { isWorking = false }

        let progressHandler: @Sendable (ProofreadingProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.statusMessage = progress.status
            }
        }

        do {
            let result = try await Proofreader(options: settings.proofreadingOptions)
                .proofread(text, onProgress: progressHandler)

            output = result.text
            detectedLanguage = result.language
            warnings = result.warnings
            changeCount = Diff.changeCount(original: text, corrected: result.text)

            var parts: [String] = []
            if let language = result.language {
                parts.append(result.languageWasDetected ? "\(language.displayName) detected" : language.displayName)
            }
            parts.append(changeCount == 0 ? "no changes" : "\(changeCount) change\(changeCount == 1 ? "" : "s")")
            if automaticCopy {
                parts.append(Clipboard.write(result.text) ? "copied ✓" : "clipboard not writable")
            }
            statusMessage = parts.joined(separator: " · ")
            if changeCount == 0 { showsDiff = false }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statusMessage = ""
        }
    }

    func pasteFromClipboard() {
        guard let text = Clipboard.read(), !text.isEmpty else {
            errorMessage = "The clipboard contains no text."
            return
        }
        input = text
        errorMessage = nil
        statusMessage = ""
        output = ""
        showsDiff = false
        changeCount = 0
    }

    func copyResult() {
        guard hasResult else { return }
        statusMessage = Clipboard.write(output) ? "Copied to the clipboard ✓" : "Clipboard not writable"
    }

    func clear() {
        input = ""
        output = ""
        errorMessage = nil
        statusMessage = ""
        changeCount = 0
        showsDiff = false
        warnings = []
    }

    /// Rewriting the correction must reach the clipboard again, otherwise the
    /// "copy in, paste out" loop breaks as soon as the user touches a sentence.
    /// Only the correction pane is mirrored — typing in the original is work in
    /// progress and has no business overwriting the clipboard.
    private func scheduleAutomaticCopy() {
        automaticCopyTask?.cancel()
        guard automaticCopy, !isWorking, !output.isEmpty else { return }

        let text = output
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        automaticCopyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, !self.isWorking else { return }
            if Clipboard.write(text) {
                self.statusMessage = "Copied to the clipboard ✓"
            }
        }
    }

    var attributedDiff: AttributedString {
        guard hasResult else { return AttributedString() }
        var result = AttributedString()
        for change in Diff.displayChanges(original: input, corrected: output) {
            var piece = AttributedString(change.text)
            switch change.kind {
            case .unchanged:
                break
            case .removed:
                piece.foregroundColor = .red
                piece.strikethroughStyle = .single
            case .added:
                piece.foregroundColor = .green
            }
            result += piece
        }
        return result
    }
}

// MARK: - View

struct ContentView: View {
    @State private var viewModel = KorrektorViewModel.shared
    @FocusState private var inputFocused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()

            VSplitView {
                inputPane
                outputPane
            }

            Divider()
            footer
        }
        .onAppear {
            inputFocused = true
            // Lets the shortcut reopen the window after it was closed.
            AppController.shared.windowOpener = { openWindow(id: "main") }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Picker("Language", selection: $viewModel.languageChoice) {
                    Text("Auto").tag(LanguageChoice.automatic)
                    ForEach(DocumentLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(LanguageChoice.fixed(language))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                Toggle("Second pass", isOn: $viewModel.thorough)
                    .toggleStyle(.checkbox)
                    .help("Checks grammar, cases and word order once more afterwards. Takes longer.")
            }

            HStack {
                Button("Paste") { viewModel.pasteFromClipboard() }
                    .help("Paste the text from the clipboard")
                Button("Clear") { viewModel.clear() }
                Spacer()
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var inputPane: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Original")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            TextEditor(text: $viewModel.input)
                .font(.system(.body, design: .default))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .focused($inputFocused)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .frame(minHeight: 180)
    }

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(viewModel.showsDiff ? "Changes" : "Correction")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if viewModel.changeCount > 0 {
                    Toggle("Show changes", isOn: $viewModel.showsDiff)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if viewModel.showsDiff {
                ScrollView {
                    Text(viewModel.attributedDiff)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            } else {
                TextEditor(text: $viewModel.output)
                    .font(.system(.body, design: .default))
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .frame(minHeight: 180)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    if viewModel.isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(viewModel.statusMessage.isEmpty && !viewModel.hasResult
                         ? "Type or paste text, then ⌘↩"
                         : viewModel.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(height: 20)
            }

            if let warning = viewModel.warnings.first {
                Text("Note: \(warning)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Toggle("Copy automatically", isOn: $viewModel.automaticCopy)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .help("Keeps the clipboard in step with the correction, including your own edits.")

                Spacer()

                Button("Copy") { viewModel.copyResult() }
                    .disabled(!viewModel.hasResult)

                Button {
                    Task { await viewModel.correct() }
                } label: {
                    Text(viewModel.isWorking ? "Correcting …" : "Correct")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canCorrect)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
