# typewhisper.el

Dictate into Emacs with [TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac), fix misrecognized words with Claude, and teach TypeWhisper those fixes so they don't happen again.

It is built for Japanese dictation mixed with English technical terms. For example, it turns `リアクトのユーズエフェクト` into `ReactのuseEffect`, but it should work for other languages too.

## Features

- **Dictation**: start and stop TypeWhisper dictation from Emacs. The text TypeWhisper pastes is remembered as "the last dictation".
- **Fixing**: send the last dictation (or the region) to Claude through the Claude Code CLI. Only speech recognition errors are fixed, and only inside the target text. The surrounding lines go along as context but are never changed. All fixes form one undo step.
- **Learning**: after fixing, choose which fixes to register as TypeWhisper corrections or terms. Risky entries, such as very short hiragana words, are not selected by default.
- **Dictionary editing**: list, add, edit, and delete corrections and terms.

## Requirements

- macOS with TypeWhisper, with the API server turned on in **Settings > Advanced**
- Emacs 29.1 or later
- `curl`
- [Claude Code](https://claude.com/claude-code) (`claude`), signed in. No API key is needed.

## Installation

With `use-package` and `:vc` (Emacs 30+):

```elisp
(use-package typewhisper
  :vc (:url "https://github.com/wakamenod/typewhisper.el")
  :config
  (typewhisper-mode 1))
```

Or clone the repository and add it to your `load-path`:

```elisp
(add-to-list 'load-path "/path/to/typewhisper.el")
(require 'typewhisper)
(typewhisper-mode 1)
```

The package does not bind any keys. For example:

```elisp
(keymap-global-set "C-c d d" #'typewhisper-dictate)
(keymap-global-set "C-c d f" #'typewhisper-dictate-and-fix)
(keymap-global-set "C-c d x" #'typewhisper-fix)
(keymap-global-set "C-c d c" #'typewhisper-corrections)
(keymap-global-set "C-c d t" #'typewhisper-terms)
```

## Usage

### Dictation

`M-x typewhisper-dictate` starts dictation at point. Run it again to stop. TypeWhisper transcribes the audio and pastes the text into the frontmost app, so keep Emacs in front.

`M-x typewhisper-dictate-and-fix` works the same way, and then runs `typewhisper-fix` on the result.

With `typewhisper-mode`, the mode line shows `TW[REC]` while recording, `TW[…]` while starting or transcribing, and `[fix]` while Claude is working.

If Emacs and TypeWhisper get out of sync, run `M-x typewhisper-cancel`.

### Fixing

`M-x typewhisper-fix` fixes the active region, or the last dictation if there is no region. Claude receives:

- the target text
- `typewhisper-fix-context-lines` lines before and after it, as context only
- your TypeWhisper terms and corrections, as spelling hints
- the major mode of the buffer

Fixed text is highlighted for a moment. Fixes that Claude is unsure about (below `typewhisper-fix-min-confidence`) are not applied. They are shown in the echo area as suggestions.

### Registering fixes

After fixes are applied, the `*TypeWhisper Register*` buffer opens:

| Key       | Action                                                    |
|-----------|-----------------------------------------------------------|
| `m` / `u` | Mark / unmark                                             |
| `t`       | Toggle between a correction and a term                    |
| `c`       | Toggle case sensitivity                                   |
| `C-c C-c` | Register the marked rows                                  |
| `C-c C-k` | Discard                                                   |

A **correction** replaces `wrong` with `right` after transcription. A **term** adds `right` to the vocabulary hints for the speech engine. Terms usually suit English technical terms better.

The Notes column shows warnings. Rows with these problems are not marked by default:

- The original text is too short (`typewhisper-register-min-length`). For hiragana-only text, the limit is `typewhisper-register-min-hiragana-length`.
- The same correction is already registered.
- The wrong text is not in TypeWhisper's raw transcription. An existing correction probably produced it, so review that correction instead.

These rows are marked, but come with a warning:

- The fix changes only letter case.
- The fix would overwrite an existing correction that has a different replacement.

Set `typewhisper-fix-confirm-registration` to nil to skip this step.

### Dictionary

`M-x typewhisper-corrections` and `M-x typewhisper-terms` list the dictionary:

| Key | Action                    |
|-----|---------------------------|
| `a` | Add                       |
| `e` | Edit                      |
| `d` | Delete (asks first)       |
| `s` | Filter by substring       |
| `g` | Reload                    |

## Configuration

| Variable                              | Default    | Description                                        |
|---------------------------------------|------------|----------------------------------------------------|
| `typewhisper-claude-program`          | `"claude"` | Path to the Claude Code CLI                        |
| `typewhisper-claude-model`            | `"sonnet"` | Model for fixing                                   |
| `typewhisper-claude-effort`           | `"low"`    | Effort level, or nil                               |
| `typewhisper-fix-context-lines`       | `3`        | Context lines on each side                         |
| `typewhisper-fix-min-confidence`      | `medium`   | Lowest confidence that is applied                  |
| `typewhisper-fix-include-dictionary`  | `t`        | Send terms and corrections to Claude               |
| `typewhisper-fix-highlight-duration`  | `3`        | Seconds to highlight fixes                         |
| `typewhisper-api-port`                | `nil`      | API port; nil reads TypeWhisper's discovery file   |
| `typewhisper-api-token`               | `nil`      | API token; nil reads TypeWhisper's discovery file  |
| `typewhisper-workflow-id`             | `nil`      | Workflow to use when starting dictation            |

See `M-x customize-group RET typewhisper` for the rest.

`sonnet` with low effort takes about 3 seconds per fix, and handles English technical terms well. `haiku` was slower and less accurate in testing.

If Emacs cannot find `claude` (common when Emacs is started from the Dock), set `typewhisper-claude-program` to its full path, such as `~/.local/bin/claude`.

## How it works

- The API port and token are read from `~/Library/Application Support/TypeWhisper/api-discovery.json`, which TypeWhisper writes while the API server runs. Requests go through `curl`, and the token is passed on stdin so it does not show up in the process list.
- `POST /v1/dictation/start` replies only once the microphone is ready, so every dictation request is asynchronous.
- After dictation stops, the package polls `GET /v1/dictation/transcription` until it is done. It then looks for the pasted text at the place where dictation started.
- Fixing runs `claude -p` with no tools, no MCP servers, and no settings, and asks for structured JSON output.

## Development

```sh
make test      # run the ERT tests
make compile   # byte-compile with warnings as errors
```

## License

GPL-3.0-or-later
