# Korrektor

On-device proofreading for **German, English, French and Spanish** with Apple's Foundation Models
framework. No network. Select text anywhere, press your shortcut, and the correction is back where
you wrote it — or on the clipboard.

## Requirements

- macOS 27, Apple silicon
- Apple Intelligence enabled (System Settings → Apple Intelligence & Siri)
- Check with `korrektor --check`

The model runs locally; no text ever leaves the machine.

## Install

```bash
cd Korrektor
make install          # builds the CLI and the app
```

- CLI: `~/.local/bin/korrektor` (must be on your `PATH`)
- App: `~/Applications/Korrektor.app`

To run straight from the project instead: `make` and then `./.build/release/korrektor`.

## Global shortcut

The point of the app: select text in any app — Mail, Outlook, Teams, Word, a browser — press
the shortcut, and the selection is corrected in place.

1. Open **Korrektor → Settings…** (`⌘,`)
2. Turn on **Correct the selected text with a shortcut**
3. Press **Change** and record the combination you want (default: `⌃⌥⌘K`). Recording needs Korrektor to
   be the frontmost app — if another window has focus the pane says so, because the keys go there.
   While you record, the registered shortcut is suspended, so the current combination can be recorded
   again and no action fires half way through.
4. Grant **Accessibility** access when macOS asks — otherwise Korrektor cannot see or replace your
   selection. The button in Settings → Permissions opens the right pane.

The shortcut is yours to choose because other tools on your Mac already own combinations. Two notes:

- macOS does not reliably tell an app when a combination is already taken by someone else. If
  nothing happens when you press it, pick a different one.
- **The permission is tied to the build, not to the app's name.** The app is signed ad-hoc, so its
  designated requirement is a bare content hash (`codesign -d -r-` shows `cdhash H"…"`). Every rebuild
  is a different app to macOS: the switch in System Settings can look *on* — that row is the stored
  grant for an older build — while the running build reports "Not granted". Either re-grant after the
  last build (`tccutil reset Accessibility de.arte.korrektor`, relaunch, switch on), or sign with a
  stable identity:

  ```bash
  # once: Keychain Access → Certificate Assistant → Create a Certificate
  #       name "Korrektor Dev", type Code Signing, self signed
  SIGN_IDENTITY="Korrektor Dev" make app
  ```

  With a real signing identity the requirement is the identifier plus the certificate, so rebuilds
  keep the grant. In *Copy, then review in the window* mode none of this matters — that mode needs no
  Accessibility access at all.

**What the shortcut does** (Settings → *When the shortcut is pressed*)

- **Replace the selected text** (default) — the correction goes back where the selection was.
- **Only copy the correction** — the document stays untouched, the result is on the clipboard.
- **Copy, then review in the window** — takes what you just copied, fills the window with it,
  corrects it straight away and leaves the result on the clipboard. You edit, press `⌘↩` to
  correct again, and paste back into the app you came from whenever you like. **This mode needs no
  Accessibility access**, because the clipboard carries the text both ways.

### The copy-in, paste-out loop

The mode that matches how most people already work: `⌘C` in any app → press the shortcut → Korrektor
opens with the text and starts correcting → the result is on the clipboard and follows every edit you
make in the **Correction** pane → switch back and `⌘V`.

- `⌘↩` corrects again — from the **Original** pane, so you always see the diff against what you wrote.
- Editing the **Correction** pane updates the clipboard about a second later.
- Typing in **Original** deliberately does *not* touch the clipboard: work in progress is not a result.
- Korrektor does not steal focus back — you switch apps yourself and paste.

There is also **Correct selection now** in the menu bar item, which does the same without the
shortcut — useful when the shortcut is taken or Accessibility is missing.

**Fallback for apps that hide their selection.** Some apps (Electron-based, some browsers) do not
expose the selection to Accessibility. With *Fall back to ⌘C and ⌘V* on, Korrektor copies and pastes
instead. It is off by default because the fallback can act on more than you selected (in an editor
without a selection, `⌘C` copies the whole line). It only ever runs inside a text area, never in a
password field, and puts your clipboard back afterwards.

## Command line

```bash
korrektor "I have no time today."                    # text as an argument
korrektor -c                                         # from the clipboard
pbpaste | korrektor -q | pbcopy                       # pipes, no status noise
korrektor -c -l de -d                                # force German, show the changes
korrektor -t < draft.txt > draft-corrected.txt        # second pass, into a file
```

Without a text argument and without `-c`, `korrektor` reads stdin; in a terminal it reads until
`Ctrl-D`. The result always goes to stdout **and** onto the clipboard (`-n` turns the copying off).

| Option | Purpose |
| --- | --- |
| `-l, --lang auto\|de\|en\|fr\|es` | Pin the language instead of detecting it (default: `auto`) |
| `-c, --clipboard` | Read the text from the clipboard |
| `-n, --no-copy` | Do not put the result on the clipboard |
| `-t, --thorough` | Second pass: checks grammar, cases and word order again |
| `-d, --diff` | Show the changes instead of plain text (`[-old-] {+new+}`) |
| `-q, --quiet` | No status messages on stderr |
| `--check` | Only report whether the model is available |

Exit codes: `0` success, `1` failure (model unavailable, correction failed), `2` bad usage.

## The window

`open ~/Applications/Korrektor.app`

- Language (`Auto` or fixed) and **Second pass** at the top
- **Original** (type or *Paste*) and **Correction** side by side
- **Correct** = `⌘↩`; the result is copied automatically (can be turned off)
- **Show changes** marks what changed (red = gone, green = new)
- Settings are remembered; closing the window keeps the shortcut alive

## How it works

- **Touch nothing but mistakes.** The prompt allows spelling, grammar, punctuation and
  capitalisation only. Wording, style, length, meaning, numbers, names, URLs and markup stay as they
  were.
- **Paragraphs stay paragraphs.** The text is split into paragraphs and the separators come back
  from the original, so a model that drops a blank line cannot lose text. If it reshapes the
  paragraph structure, that section is redone paragraph by paragraph.
- **Large texts** are cut along the model's token budget (8192): paragraphs are batched, overlong
  paragraphs are split at sentence boundaries.
- **Language** is detected with `NLLanguageRecognizer`; the four supported languages are pinned in
  the prompt so nothing gets translated.
- **Guardrails** run as `permissiveContentTransformations`, so journalistic text does not trip the
  safety filter.
- **Second pass** (`-t`): a narrow prompt that only looks for agreement, cases, tense and word
  order. Finds real leftovers in short texts, costs double the time, and often finds nothing in long
  clean ones.
- **The shortcut** registers through Carbon's `RegisterEventHotKey` (works system-wide, swallows the
  key press, needs no permission of its own). Reading and replacing the selection goes through the
  Accessibility API; a synthetic `⌘C`/`⌘V` exists only as the opt-in fallback above.

## Limits

- The on-device model has ~3B parameters. Spelling and punctuation are very reliable; grammar and
  word order are not — that is what `-t` is for.
- Roughly 80 tokens/second: 100 words ≈ 2 s, 1000 words ≈ 20 s (double with `-t`).
- Very short or unusual texts can trip the guardrails; a second attempt or more context usually
  helps.
- Not a substitute for review: anything going to APAX or to a client is read by a human first.
- The shortcut does not fire while macOS has *Secure Keyboard Entry* on (some terminals and password
  prompts enable it) — that is the system protecting you, not a bug.

## Development

```bash
make            # CLI + app
make test       # 27 tests without the model (splitting, diff, languages, shortcut recording)
make live-test  # one test against the real model
make run        # launch the app
```

The SwiftUI macros need the full Xcode toolchain; the Makefile sets `DEVELOPER_DIR` for you (the
Command Line Tools alone are not enough for the app).

Note on naming: the app's SwiftPM product is called `KorrektorApp`, not `Korrektor`, because
`.build/release` would otherwise contain both `korrektor` and `Korrektor` — the same file on a
case-insensitive volume, where the app build silently overwrites the CLI binary. The bundle's
executable is renamed to `Korrektor` when it is assembled.

```
Sources/KorrektorCore/     # Proofreader, TextSplitter, Diff, Hotkey, SelectionCorrection, Clipboard
Sources/korrektor/         # CLI
Sources/KorrektorUI/       # SwiftUI window, settings, menu bar item, HUD, Carbon shortcut
Tests/KorrektorCoreTests/  # tests without the model
Scripts/build-app.sh       # builds the .app bundle
AGENTS.md                  # rules and traps for anyone (or anything) changing this code
```

If you are about to change the code, read [AGENTS.md](AGENTS.md) first — it lists the constraints
that are not obvious from the source, including the two that already caused silent breakage.

`Proofreader.proofread(_:onProgress:)` is the whole text interface: text in, corrected text plus
warnings out. `SelectionCorrector.run()` is the whole shortcut interface: selection in, outcome out.
Splitting, token budgets, retries, the second pass and the Accessibility plumbing sit underneath.

## Next steps (not built)

- Services menu entry ("Services → Correct"), a hotkey-free alternative for apps that refuse
  Accessibility.
- House spellings and vocabulary (ARTE names, titles, format names) as a glossary in the prompt.
- Correction log as a review trail for editors.
- Feeding Anmeldung texts from the APAX skill through the same pipeline.
