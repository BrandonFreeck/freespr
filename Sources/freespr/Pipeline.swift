import Foundation

/// Runs the REAL content pipeline (Transcriber → Cleanup → ToneStrip → composeOutput) on a given
/// WAV, SYNCHRONOUSLY — for `freespr test-pipeline`, the agentic E2E entry that skips the mic +
/// hotkey. It prints the result instead of touching the clipboard, so a test run can never
/// overwrite a dictation the user hasn't pasted yet. Mirrors `Agent.handleTranscript`'s branch structure and reuses every component
/// verbatim (no logic duplicated); the only new bit is driving the async network calls synchronously
/// (a one-shot CLI doesn't pump the main run loop the live Agent relies on).
enum Pipeline {
    static func run(wav: URL, config: Config) -> Result<String, Error> {
        // Env key ONLY (OPENAI_API_KEY) — never the Keychain. A `.build`/test binary isn't the signed
        // identity that stored the key, so a Keychain READ pops a GUI prompt and blocks forever.
        // `make test` passes the key in, from OPENAI_API_KEY or the Keychain item.
        let keyProvider = EnvAPIKeyProvider()

        // 1. Transcribe (real gpt-transcribe + vocab bias).
        let transcriber = Transcriber(keyProvider: keyProvider,
                                      model: config.transcriptionModel,
                                      vocabPrompt: Vocab.promptString())
        let result: Result<String, Error> = waitFor { transcriber.transcribe(wav: wav, completion: $0) }
        let transcript: String
        switch result {
        case .failure(let e): return .failure(e)
        case .success(let t): transcript = t
        }
        guard !transcript.isEmpty else { return .failure(FreesprError.other("empty transcript")) }

        // 2. Cleanup + tone strip + compose — same branches as Agent.handleTranscript.
        let output: String
        if config.cleanupDefault {
            let cleaned: String? = waitFor {
                Cleanup(keyProvider: keyProvider, model: config.cleanupModel, effort: config.cleanupEffort).clean(transcript, completion: $0)
            }
            output = Agent.deliverable(transcript: transcript, cleaned: cleaned, config: config)
        } else {
            output = ToneStrip.apply(transcript, mode: .raw, stripTells: config.stripAITells)
        }

        return .success(output)
    }

    /// Block until an async, completion-handler API fires. Safe here: URLSession completions run on a
    /// background queue (not the main run loop), so the wait can't deadlock a runloop-less CLI.
    private static func waitFor<T>(_ start: (@escaping (T) -> Void) -> Void) -> T {
        let sem = DispatchSemaphore(value: 0)
        var box: T!
        start { value in box = value; sem.signal() }
        sem.wait()
        return box
    }
}
