# Changelog

## 0.1.0 (unreleased)

First public release.

- Push-to-talk dictation: hold Right Command or Right Control by itself to start and stop.
  Recording stops on its own after 30 seconds of silence or 10 minutes.
- Transcription with OpenAI `gpt-transcribe`, biased by your `vocab.txt` (up to 3,000
  characters, in priority order; `freespr status` reports terms that didn't fit).
- Cleanup with OpenAI `gpt-6-luna`, driven by your `style.md`, plus an optional deterministic
  pass that removes em dashes, emoji and stock AI phrases (`strip_ai_tells`).
- Output to the clipboard with a ready chime, or typed at the cursor with `auto_paste = true`.
- A screen-edge glow shows recording, transcribing and delivered states.
- `freespr status` checks the key, the agent, Microphone access and the hotkey, and says how to
  fix what's wrong. A denied microphone plays an error sound and opens its settings pane instead
  of recording silence.
- `freespr uninstall --purge` removes everything FreeSPR installed, including its permission
  entries, except the `make cert` signing certificate, which it tells you how to remove.
- `make cert` creates a local signing certificate so permissions survive rebuilds. Only
  `codesign` may use its private key directly; the README explains the trade-off that any program
  running as you can still sign as FreeSPR through `codesign`.
- A recording left behind by an interrupted session is deleted when FreeSPR starts and finds it
  unchanged for at least 15 minutes, and by `uninstall --purge`.
