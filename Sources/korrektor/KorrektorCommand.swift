import Darwin
import Foundation
import KorrektorCore

@main
struct KorrektorCommand {

    static let version = "1.1.0"

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())

        do {
            let configuration = try Configuration(arguments: arguments)

            if configuration.showHelp {
                print(helpText)
                return
            }
            if configuration.showVersion {
                print("korrektor \(version)")
                return
            }
            if configuration.checkOnly {
                try checkModel()
                return
            }

            let input = try readInput(configuration)
            try await correct(input, configuration)
        } catch let error as Configuration.ParseError {
            writeToStandardError("korrektor: \(error.message)\n\n\(hintText)\n")
            exit(2)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            writeToStandardError(colorize("korrektor: ", .red) + message + "\n")
            exit(1)
        }
    }

    // MARK: - Steps

    private static func checkModel() throws {
        switch Proofreader.availability() {
        case .available:
            print("The language model is available.")
        case .unavailable(let message):
            print(message)
            exit(1)
        }
    }

    private static func readInput(_ configuration: Configuration) throws -> String {
        if !configuration.textArguments.isEmpty {
            return configuration.textArguments.joined(separator: " ")
        }

        if configuration.readClipboard {
            guard let text = Clipboard.read(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Configuration.ParseError(message: "The clipboard contains no text.")
            }
            return text
        }

        let isTerminal = isatty(STDIN_FILENO) == 1
        if isTerminal {
            writeToStandardError("Type or paste your text, finish with Ctrl-D:\n")
        }

        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Configuration.ParseError(message: "No text given.")
        }
        return text
    }

    private static func correct(_ input: String, _ configuration: Configuration) async throws {
        let options = ProofreadingOptions(language: configuration.language, thorough: configuration.thorough)
        let proofreader = Proofreader(options: options)

        let showProgress = !configuration.quiet && isatty(STDERR_FILENO) == 1
        let result = try await proofreader.proofread(input) { progress in
            guard showProgress else { return }
            writeToStandardError("\r\u{1B}[K\(progress.status)")
        }
        if showProgress {
            writeToStandardError("\r\u{1B}[K")
        }

        let changeCount = Diff.changeCount(original: input, corrected: result.text)
        let output = configuration.showDiff
            ? Diff.render(original: input, corrected: result.text, color: isatty(STDOUT_FILENO) == 1)
            : result.text
        print(output, terminator: result.text.hasSuffix("\n") && !configuration.showDiff ? "" : "\n")

        var copied = false
        if configuration.copyResult {
            copied = Clipboard.write(result.text)
        }

        guard !configuration.quiet else { return }

        var summary = "Done"
        if result.languageWasDetected, let language = result.language {
            summary += " · \(language.displayName) detected"
        } else if let language = result.language {
            summary += " · \(language.displayName)"
        }
        summary += changeCount == 0
            ? " · no changes"
            : " · \(changeCount) change\(changeCount == 1 ? "" : "s")"
        if copied {
            summary += " · on the clipboard"
        } else if configuration.copyResult {
            summary += " · " + colorize("could not write the clipboard", .yellow)
        }
        writeToStandardError(summary + "\n")

        for warning in result.warnings {
            writeToStandardError(colorize("Note: ", .yellow) + warning + "\n")
        }
    }

    // MARK: - Text

    private static let hintText = "»korrektor --help« lists the options."

    private static let helpText = """
    korrektor \(version) — on-device proofreading with Apple Intelligence

    USAGE
      korrektor [TEXT …] [options]

    Without a text argument the input comes from the clipboard (with -c),
    otherwise from stdin, otherwise from the keyboard (finish with Ctrl-D).
    The corrected text goes to stdout and onto the clipboard.

    OPTIONS
      -l, --lang <language>  auto, de, en, fr, es  (default: auto)
      -c, --clipboard        read the text from the clipboard
      -n, --no-copy          do not put the result on the clipboard
      -t, --thorough         second pass: more accurate, takes longer
      -d, --diff             show the changes instead of plain text
      -q, --quiet            no status messages
          --check            only report whether the model is available
      -h, --help             this help
      -v, --version          print the version

    EXAMPLES
      korrektor "Hello, I have no time today."
      pbpaste | korrektor -q | pbcopy
      korrektor -c -l de -d
      korrektor -t < draft.txt > draft-corrected.txt
    """
}

// MARK: - Configuration

struct Configuration {

    struct ParseError: Error {
        let message: String
    }

    var textArguments: [String] = []
    var language: LanguageChoice = .automatic
    var thorough = false
    var readClipboard = false
    var copyResult = true
    var showDiff = false
    var quiet = false
    var checkOnly = false
    var showHelp = false
    var showVersion = false

    init(arguments: [String]) throws {
        var index = 0
        var literalOnly = false

        while index < arguments.count {
            let argument = arguments[index]
            index += 1

            if literalOnly {
                textArguments.append(argument)
                continue
            }

            switch argument {
            case "--":
                literalOnly = true
            case "-h", "--help":
                showHelp = true
            case "-v", "--version":
                showVersion = true
            case "-c", "--clipboard":
                readClipboard = true
            case "-n", "--no-copy":
                copyResult = false
            case "-t", "--thorough":
                thorough = true
            case "-d", "--diff":
                showDiff = true
            case "-q", "--quiet":
                quiet = true
            case "--check":
                checkOnly = true
            case "-l", "--lang", "--language":
                guard index < arguments.count else {
                    throw ParseError(message: "\(argument) needs a language.")
                }
                let value = arguments[index]
                index += 1
                try setLanguage(value)
            default:
                if argument.hasPrefix("--lang=") || argument.hasPrefix("--language=") {
                    try setLanguage(String(argument.split(separator: "=", maxSplits: 1)[1]))
                } else if argument.hasPrefix("-"), argument.count > 1 {
                    throw ParseError(message: "Unknown option \(argument).")
                } else {
                    textArguments.append(argument)
                }
            }
        }
    }

    private mutating func setLanguage(_ value: String) throws {
        guard let choice = LanguageChoice(code: value) else {
            throw ParseError(message: "Unknown language “\(value)”. Allowed: auto, de, en, fr, es.")
        }
        language = choice
    }
}

// MARK: - Terminal colours

enum Color {
    case red, yellow
}

func writeToStandardError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}

func colorize(_ text: String, _ color: Color) -> String {
    guard isatty(STDERR_FILENO) == 1 || isatty(STDOUT_FILENO) == 1 else { return text }
    switch color {
    case .red: return "\u{1B}[31m\(text)\u{1B}[0m"
    case .yellow: return "\u{1B}[33m\(text)\u{1B}[0m"
    }
}
