# FreeSPR

Push-to-talk dictation for macOS that runs on your own OpenAI API key. Hold a key, talk, hold it
again, and cleaned-up text lands on your clipboard, ready to paste into any app.

**Status:** a tool I built for myself and share in case you find it useful. It's provided as is,
with no support. I use it every day and fix what bites me, but it has only run on my own Macs so
far, and I can't promise a reply to issues or pull requests.

## How it works

1. Hold **Right Command** or **Right Control** by itself for about 1.25 seconds. A chime plays
   and a blue glow around the screen edge means it's recording.
2. Talk. Hold the key again to stop, or just stop talking: it stops itself after 30 seconds of
   silence, and after 10 minutes in any case.
3. The recording goes to OpenAI's `gpt-transcribe`, and the transcript goes to `gpt-6-luna`
   with the instructions in your `style.md`, which remove filler words and false starts while
   keeping your wording.
4. A third chime means the text is on your clipboard. Paste it with Cmd+V.

A quick tap of either key, or using it in a shortcut like Right Command+C, passes through
untouched. FreeSPR has no window and no menu bar icon. It runs as a background agent that starts
at login, and you manage it from Terminal.

## Requirements

- macOS 14 (Sonoma) or later.
- Swift 6.1 or later. The Xcode Command Line Tools are enough: `xcode-select --install`.
- An OpenAI API key on an account with billing set up. You pay OpenAI for your own usage; see
  [Cost](#cost).
- A keyboard with a Right Command or Right Control key.

## Install

```sh
git clone https://github.com/BrandonFreeck/freespr.git
cd freespr
make cert         # one time, optional but recommended; asks for your login password (see below)
make install      # builds ~/Applications/freespr.app and links ~/.local/bin/freespr to it
freespr init      # stores your API key, asks one question, requests the 2 permissions, starts the agent
freespr status    # every row should be green
```

If `~/.local/bin` isn't on your PATH, `make install` links the command into `/usr/local/bin` when
it can, or prints the line to add to `~/.zshrc`.

### What `make cert` asks for, and why

macOS ties the Microphone and Accessibility permissions to an app's code signature. A plain local
build is signed "ad hoc", and that signature changes on every rebuild, so macOS forgets both
permissions each time you update.

`make cert` creates a self-signed certificate named `freespr-codesign` in your login keychain and
trusts it for code signing only. Only Apple's `codesign` tool may use its private key. macOS asks
for your login password once to trust it. On your first `make install` afterwards, macOS may ask
whether `codesign` may use the key: click **Always Allow**. From then on, rebuilds keep your
permissions.

The certificate never leaves your Mac and isn't an Apple Developer ID; nothing is notarized. You
can skip `make cert` and re-grant both permissions after each update instead.

## Permissions

`freespr init` asks for the Microphone and opens the Accessibility pane. Turn **freespr** on for
both. If you miss the Microphone prompt, FreeSPR asks again the first time you hold the key:

| Permission | Why | System Settings ▸ Privacy & Security ▸ |
|---|---|---|
| **Microphone** | To record you. | Microphone |
| **Accessibility** | The global hotkey, and typing at the cursor if you set `auto_paste = true`. | Accessibility |

Input Monitoring isn't used. If the hotkey does nothing, this is almost always the reason: see
[Troubleshooting](#troubleshooting).

## Privacy

FreeSPR sends your words to OpenAI on every dictation. Know what that means before you use it.

- **What's sent:** the audio of each recording goes to OpenAI's transcription API, along with your
  vocabulary list. With cleanup on (the default), the transcript and your `style.md` then go to
  OpenAI's chat completions API. With `cleanup_default = false`, only the transcription call
  happens.
- **Nothing else is sent anywhere.** There's no FreeSPR server, no analytics and no telemetry.
  The only network calls are those two, made directly from your Mac to `api.openai.com` with
  your key.
- **What OpenAI keeps:** OpenAI's [data controls page](https://developers.openai.com/api/docs/guides/your-data)
  says API data isn't used to train its models by default, and that it may keep request logs
  for up to 30 days to monitor abuse. It lists the transcription endpoint as not kept for
  abuse monitoring and chat completions as kept for up to 30 days. Read that page for the current
  terms; FreeSPR can't change them. Your use is also covered by OpenAI's
  [usage policies](https://openai.com/policies/usage-policies).
- **On your Mac:** each recording is a temporary WAV file, deleted once it's been sent for
  transcription. One left behind because FreeSPR stopped mid-recording is deleted the next time
  it starts, once it's 15 minutes old, or by `freespr uninstall --purge`. The log at `~/Library/Logs/freespr.log` records events and character counts,
  never what you said. When OpenAI returns an error, its message is logged with anything shaped
  like an API key masked. Your API key is stored in the macOS Keychain (service
  `freespr`), never in a file.
- **Your clipboard:** the result goes on the clipboard, so anything that keeps clipboard history
  keeps your dictation too. With `auto_paste = true`, FreeSPR types the text at your cursor and
  puts your previous clipboard back about a quarter second later.

## Cost

You pay OpenAI per dictation. Measured on November 18, 2026 with the default settings:

| Dictation | Transcription | Cleanup | Total |
|---|---|---|---|
| 9 seconds | US$0.0007 | US$0.0001 | under a tenth of a cent |
| 73 seconds | US$0.0055 | US$0.0003 | about six tenths of a cent |

Transcription costs US$0.0045 per minute of audio, and the length of your vocabulary list doesn't
change that. Cleanup with `gpt-6-luna` adds a few hundredths of a cent. So the bill follows how
long you talk: about half a cent per minute, or roughly US$0.30 per hour of dictation.

Lowering `cleanup_effort` saves almost no money but some time: cleaning the 73-second dictation
took 5.1 seconds at `xhigh` and 2.9 seconds at `medium`.

Prices come from [OpenAI's pricing page](https://developers.openai.com/api/docs/pricing) as of
November 2026. Set `cleanup_default = false` to skip cleanup and pay only for transcription. You
can set a monthly budget for your key in the OpenAI dashboard.

## Settings

Everything lives in `~/.config/freespr/`. `make install` creates these files only when they're
missing, so updating never overwrites your edits.

### `config.toml`

A flat file you edit by hand. A missing or garbled setting falls back to its default, so a typo
can't stop the agent. Changes apply the next time the agent starts: `make reload`, or log out
and back in.

| Setting | Default | What it does |
|---|---|---|
| `trigger_right_cmd` / `trigger_right_ctrl` | `true` / `true` | Which keys start and stop recording. |
| `hold_threshold_ms` | `1250` | How long to hold the key by itself before it fires. |
| `silence_timeout_sec` | `30` | Stop after this many seconds of silence. |
| `max_recording_sec` | `600` | Longest single recording; `0` means no limit. |
| `auto_paste` | `false` | `false`: the text goes on the clipboard with a ready chime. `true`: it's typed at your cursor. |
| `paste_restore_ms` | `250` | With `auto_paste`: wait this long before putting your old clipboard back. Raise it for slow apps. |
| `transcription_model` | `"gpt-transcribe"` | The OpenAI transcription model. |
| `cleanup_model` | `"gpt-6-luna"` | The OpenAI model that cleans up the transcript. It must be a reasoning model. |
| `cleanup_effort` | `"xhigh"` | Reasoning effort for cleanup: `none`, `low`, `medium`, `high`, `xhigh` or `max`. Lower is faster; the cost barely changes. |
| `cleanup_default` | `true` | `false` delivers the raw transcript with no cleanup call. |
| `include_raw_transcript` | `false` | `true` puts the raw transcript above the cleaned text, which helps when you paste into a chatbot. |
| `strip_ai_tells` | `true` | After the model: em dashes become hyphens, curly quotes become straight, emoji are removed, and with cleanup on, stock phrases like "I hope this helps" are dropped. |
| `indicator` | `"glow"` | The screen-edge glow: blue while recording, green while transcribing, purple when delivered. `"off"` hides it. |

### `vocab.txt`

Names and terms you want spelled right, such as product names, people and jargon. They're sent
as a hint with every transcription.

- Separate terms with commas or new lines. Lines starting with `#` are comments.
- The list sent to OpenAI is capped at 3,000 characters. The file's order is its priority: terms
  past the cap, at the bottom, aren't sent.
- `freespr status` says how many terms were kept and how many were dropped.

### `style.md`

The instructions the cleanup model gets with every dictation. The default removes filler and
false starts, applies spoken corrections like "Tuesday, no wait, Wednesday", and keeps your
wording and tone. Its "Hard rules" section bans em dashes, emoji and stock AI phrases. Rewrite
any of it: for example, ask for bullet points, a more formal tone, or a different language.

## Commands

| Command | What it does |
|---|---|
| `freespr init` | First-run setup. Run it again to replace your API key. |
| `freespr status` | Health check: API key, agent, Microphone, hotkey and vocabulary. |
| `freespr uninstall` | Stops and removes the agent, then asks whether to remove everything else. |
| `freespr uninstall --purge` | Removes everything without asking (see [Uninstall](#uninstall)). |
| `freespr version` | Prints the version. |
| `freespr run` | Runs the agent in the foreground. The background agent runs this for you. |

## Update

```sh
cd freespr
git pull
make reinstall    # clean rebuild, reinstall, and restart the agent
```

`make reinstall` wipes the build folder, so it takes a minute. Plain `make install` doesn't
restart the agent; follow it with `make reload`.

## Uninstall

```sh
freespr uninstall --purge
```

That removes the background agent, `~/.config/freespr`, the API key in your Keychain, the
Microphone and Accessibility entries, `~/Applications/freespr.app`, the `freespr` command links,
the log and any leftover recordings. Without `--purge` it removes the agent and asks before removing the rest.

If you ran `make cert`, remove the certificate too:

```sh
security delete-identity -c freespr-codesign -t ~/Library/Keychains/login.keychain-db
```

Then delete the cloned folder.

## Troubleshooting

Start with `freespr status`; it names what's wrong and how to fix it. The log is at
`~/Library/Logs/freespr.log`, and `tail -n 30 ~/Library/Logs/freespr.log` shows the latest events.

- **Holding the key does nothing.** Accessibility is off for freespr. Turn it on in System
  Settings ▸ Privacy & Security ▸ Accessibility; the hotkey comes back within a few seconds. If
  freespr is already on there after an update, switch it off and on again, and run `make cert`
  so it stops happening.
- **An error sound plays and nothing records.** Microphone access is off for freespr. FreeSPR
  opens the Microphone pane for you; turn freespr on there.
- **The text comes back uncleaned.** The cleanup call failed and FreeSPR fell back to the raw
  transcript, so you never lose words. The log line starting `cleanup failed` says why: often
  billing, a revoked key, a network timeout, or a `cleanup_model` that isn't a reasoning model.
- **Nothing comes back at all.** Look for `transcription failed` in the log. A wrong or revoked
  key is the usual cause; run `freespr init` to replace it.
- **Words keep coming out wrong.** Add them to `vocab.txt`, near the top.

When you open an issue, include the output of `freespr status` and the last 30 lines of the log.
The log doesn't contain what you dictated, but OpenAI error messages can mention your account, so
skim it first.

## Build and test

```sh
make build        # compile only, to .build/release/freespr
make check        # offline self-checks; no permissions, no network
make test         # one live end-to-end run through OpenAI on your key (a fraction of a cent)
```

`make test` speaks a fixed sentence with the macOS `say` command, sends it through the real
transcription and cleanup calls, and checks that a vocabulary term survived. It uses this
folder's `vocab.txt`, `style.md` and `config.toml`, not your own, and never touches your
clipboard.

Single binary, no third-party dependencies. Not affiliated with OpenAI.

## License

[MIT](LICENSE). Provided as is, with no warranty and no support.
