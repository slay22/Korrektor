# AGENTS.md

Instructions for agents working in this repository. Humans: the README is the user-facing document;
this file is the "don't break these things" list.

## What this is

Korrektor is an on-device proofreader for German, English, French and Spanish, built on Apple's
Foundation Models framework (macOS 27, Apple silicon). Three surfaces share one core:

- `korrektor` — CLI: text in, corrected text out, result also on the clipboard.
- `Korrektor.app` — SwiftUI window: type/paste, correct, diff, copy.
- a configurable **global shortcut** that either replaces the selection in place, copies the
  correction, or opens the window with whatever was just copied (the mode Leo uses).

Everything runs locally. **No network calls, no telemetry, no analytics.** That is the product, not an
implementation detail: the texts are unpublished editorial material.

## Build, test, run

```bash
make            # CLI (release) + app bundle → build/Korrektor.app
make test       # 27 tests, no model needed, ~0.01 s
make live-test  # one test against the real model (needs Apple Intelligence)
make install    # → ~/.local/bin/korrektor and ~/Applications/Korrektor.app
```

SwiftUI macros need the **full Xcode toolchain**; the Makefile and `Scripts/build-app.sh` export
`DEVELOPER_DIR` for you. The Command Line Tools alone build the core and the CLI but not the app.

## Layout

```
Sources/KorrektorCore/   Proofreader, TextSplitter, Diff, DocumentLanguage, Hotkey, SelectionCorrection, Clipboard, Prompts
Sources/korrektor/       CLI: argument parsing, input/output, exit codes
Sources/KorrektorUI/     SwiftUI window, settings, menu bar item, HUD, Carbon shortcut
Tests/                   Core tests (no model)
Scripts/build-app.sh     assembles the .app bundle from the SwiftPM product
```

Two public entry points carry almost everything:

- `Proofreader.proofread(_:onProgress:)` — text in, `ProofreadingResult` (text + warnings) out.
- `SelectionCorrector.run()` — one shortcut press for the selection modes, `SelectionOutcome` out.

Keep the windows/CLI thin: behaviour belongs behind those two.

## Traps that have already bitten

1. **The app's SwiftPM product must stay `KorrektorApp`.** `.build/release` would otherwise hold both
   `korrektor` and `Korrektor`, which are the same file on a case-insensitive volume — the app build
   silently overwrote the CLI binary and `korrektor --version` launched a GUI event loop. The
   Makefile runs a check that fails loudly if this regresses.
2. **Ad-hoc signing makes the TCC grant per-build.** `codesign -d -r-` shows a bare `cdhash`, so every
   rebuild is a different app to macOS: System Settings can show the Accessibility switch on while the
   running build reports "Not granted". That is not a bug in this code. `SIGN_IDENTITY="Name" make app`
   with a self-signed code-signing certificate makes the requirement stable.
3. **Paragraph separators are a data-integrity invariant.** `TextSplitter.segments` keeps the blank
   lines outside the text body and `rebuild(from:using:)` puts the originals back. If the model returns
   a different number of paragraphs, `rebuild` returns nil and the section is redone paragraph by
   paragraph. Do not "simplify" this into plain string reassembly — it exists so a model that drops a
   blank line cannot lose text.
4. **The shortcut recorder needs its ordering.** `HotkeyRecordingSession.handle` reads the capture
   closure *before* clearing it. An earlier version cleared it first, so every recording was silently
   discarded — the UI looked fine and the shortcut never changed. There is a test for exactly this.
5. **Suspend the registered hotkey while recording.** Carbon swallows the active combination
   system-wide, including inside our own Settings window, so the current shortcut could never be
   re-recorded. Recording also requires Korrektor to be frontmost; the pane says so, because on this
   Mac another tool moves focus when the user turns their head.
6. **Never touch password fields.** `SelectionCorrector` refuses `AXSecureTextField`, and the ⌘C/⌘V
   fallback is off by default and only runs inside a known text role — it can copy more than the
   selection otherwise (a password ended up on the clipboard once during testing).

## Conventions

- UI strings, CLI output, README and errors: **English**. Code comments explain *why*, not *what*.
- Errors are German→English `LocalizedError` cases in `KorrektorError`; user-facing text lives there,
  not scattered in the CLI or views.
- The version string exists twice — `KorrektorCommand.version` and `VERSION` in
  `Scripts/build-app.sh`. Bump both.
- Tests must not touch the network, the model, or other apps' UI. Model-backed checks go behind
  `KORREKTOR_LIVE=1`.

## Model facts (verified on this machine)

- `SystemLanguageModel` with `useCase: .general`, `guardrails: .permissiveContentTransformations`
  (journalistic text trips the default guardrails).
- 8192-token context, ~4.6 chars per token for German, ~80 tokens/s generation.
- All four target languages appear in `supportedLanguages`; the prompt pins the language so nothing
  gets translated.
- Spelling and punctuation are reliable; agreement and word order are not. That is what the optional
  second pass (`-t`, `thorough`) is for: narrow prompt, double the time, finds real leftovers in short
  texts and nothing in long clean ones.

## Done means

- `make test` green, and `make live-test` green when the model is available.
- Manual check if you touched the UI: window layout, settings pane, menu bar item, and one real
  hotkey press (the shortcut path cannot be exercised from a test — synthesising keystrokes needs
  Accessibility permission).
- If you changed behaviour the user can see, update `README.md`. If you changed a rule in this file,
  say why in the commit body.
