import Foundation
import AppKit

/// The headless agent: wires Hotkey → Audio → (Cleanup) → Paste through a small main-thread
/// state machine, and owns the AppKit run loop. This is the only file that knows the whole
/// pipeline; every component is swappable.
final class Agent {
    static let shared = Agent()

    private enum State { case idle, recording, transcribing }
    private var state: State = .idle {
        didSet {   // single choke point: happy AND failure paths — a stuck glow is impossible
            switch state {
            case .idle:         indicator?.clear()
            case .recording:    indicator?.set(.recording)
            case .transcribing: indicator?.set(.transcribing)
            }
        }
    }

    private let config = Config.load()
    private let chimes = Chimes()
    private lazy var indicator: Indicator? = config.indicatorEnabled ? Indicator() : nil   // off = no object
    private let keyProvider: APIKeyProvider = DefaultAPIKeyProvider()
    private var hotkey: HotkeyTap?
    private var recorder: AudioRecorder?
    private var requestedAccessibility = false
    private var lastLoggedMic: Permissions.MicState?
    private var requestingMic = false
    private var openedMicPane = false
    private var signalSources: [DispatchSourceSignal] = []

    /// Blocks on the AppKit run loop. Returns only on a fatal setup issue or termination.
    func runForever() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // live AppKit app, no Dock icon / menu bar

        guard config.triggerRightCmd || config.triggerRightCtrl else {
            log("No trigger key enabled in config — nothing to listen for. Edit ~/.config/freespr/config.toml.")
            return 78 // EX_CONFIG
        }

        let leftovers = AudioRecorder.removeLeftoverRecordings(olderThan: 15 * 60)
        if leftovers > 0 { log("removed \(leftovers) recording(s) left behind by an interrupted session") }

        // Request permissions in OUR OWN process context — the only one that matches this headless
        // launchd agent. A Terminal-run `status`/`init` sees Terminal's grants, not the daemon's, so
        // it CANNOT grant on our behalf; the daemon has to ask. Guarded by our own checks (accurate
        // in this context), so a granted agent never re-prompts.
        // Microphone: log the daemon's own state once (the sentinel `freespr status` reads), and ask
        // only while undecided — a denied state never re-prompts, so it gets told at hotkey time.
        let mic = noteMicState()
        if mic == .notDetermined { requestMicAccess() }
        if !Permissions.hasAccessibility() {
            log("Accessibility needed for the hotkey — turn ON freespr in System Settings ▸ Privacy & Security ▸ Accessibility.")
            _ = Permissions.hasAccessibility(prompt: true)   // prompts in OUR bundle context → grant attaches to com.freespr.agent
        }

        let hk = HotkeyTap(triggerRightCmd: config.triggerRightCmd,
                           triggerRightCtrl: config.triggerRightCtrl,
                           threshold: config.holdThreshold)
        hk.onToggle = { [weak self] in self?.toggle() }
        hotkey = hk

        installSignalHandlers(app)
        log("freespr running. Hold \(config.triggerDescription) alone for \(Agent.seconds(config.holdThreshold))s to start dictating, again to stop " +
            "(auto-stops after \(Int(config.silenceTimeout))s silence). Mode: \(config.cleanupDefault ? "cleanup" : "raw") / \(config.autoPaste ? "auto-paste" : "clipboard").")
        let vocab = Vocab.load()
        if vocab.dropped > 0 {
            log("WARNING: vocab.txt has \(vocab.dropped) term(s) past the \(Vocab.defaultCap)-char prompt cap; they are not sent. File order is priority, so move the terms you need most to the top.")
        }
        startTapWithRetry()
        app.run()
        return 0
    }

    /// Create the event tap; if it fails (Accessibility not granted in OUR context), prompt for it
    /// once — which surfaces freespr in the Accessibility pane attached to our bundle id — then keep
    /// retrying every 3s so the agent self-heals the instant you flip the toggle. No restart needed.
    private func startTapWithRetry() {
        if hotkey?.start() == true {
            log("hotkey active — listening for \(config.triggerDescription).")
            return
        }
        if !requestedAccessibility {
            requestedAccessibility = true
            log("Accessibility needed — opening the pane. Turn ON freespr there; it starts within ~3s.")
            _ = Permissions.hasAccessibility(prompt: true)
            Permissions.openPane(Permissions.axPane)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startTapWithRetry() }
    }

    // MARK: - Microphone (main thread)

    /// Read the daemon's microphone state and log the sentinel whenever it differs from the last one
    /// logged, so `freespr status` (newest sentinel wins) follows a grant or revoke made mid-run.
    @discardableResult
    private func noteMicState() -> Permissions.MicState {
        let mic = Permissions.MicState.current()
        if mic != lastLoggedMic {
            lastLoggedMic = mic
            log(mic.logLine)
        }
        return mic
    }

    private func requestMicAccess() {
        guard !requestingMic else { return }
        requestingMic = true
        log("Requesting Microphone access — click Allow in the prompt.")
        Permissions.requestMicrophone { [weak self] granted in
            // Completion arrives on an arbitrary queue (AVCaptureDevice.h); hop to main for agent state.
            DispatchQueue.main.async {
                guard let self else { return }
                self.requestingMic = false
                log("microphone request answered: \(granted ? "granted" : "refused")")
                self.lastLoggedMic = nil   // always log the post-request sentinel
                self.noteMicState()
            }
        }
    }

    /// True when recording may start. Otherwise explains why, once per press, and records nothing.
    private func micReadyForRecording() -> Bool {
        switch noteMicState() {
        case .authorized:
            openedMicPane = false   // a later revoke opens the pane again
            return true
        case .notDetermined:
            requestMicAccess()
            log("microphone not granted yet — answer the prompt, then hold the trigger again.")
            return false
        case .denied, .restricted:
            log("microphone blocked — turn ON freespr in System Settings ▸ Privacy & Security ▸ Microphone, then hold the trigger again.")
            chimes.error()
            if !openedMicPane {
                openedMicPane = true
                Permissions.openPane(Permissions.micPane)
            }
            return false
        }
    }

    /// "1.25" for 1.25s, "2" for 2.0s — shared by the launch banner and `freespr help`.
    static func seconds(_ t: TimeInterval) -> String {
        t == t.rounded() ? String(Int(t)) : String(format: "%g", t)
    }

    // MARK: - State machine (main thread)

    private func toggle() {
        switch state {
        case .idle:         if micReadyForRecording() { startRecording() }
        case .recording:    stopAndTranscribe()
        case .transcribing: log("still transcribing — ignoring toggle")
        }
    }

    private func startRecording() {
        let rec = AudioRecorder(silenceTimeout: config.silenceTimeout, maxDuration: config.maxRecording)
        rec.onAutoStop = { [weak self] reason in
            guard let self, self.state == .recording else { return }
            log("auto-stop: \(reason)")
            self.stopAndTranscribe()
        }
        do {
            _ = try rec.start()
            recorder = rec
            state = .recording
            chimes.start()
            log("recording…")
        } catch {
            log("could not start recording: \(error)")
        }
    }

    private func stopAndTranscribe() {
        guard let rec = recorder, let wav = rec.stop() else {
            recorder = nil      // failure branch: clear the stale recorder and stop the chime too
            chimes.stop()
            state = .idle
            return
        }
        recorder = nil
        chimes.stop()
        state = .transcribing
        log("transcribing…")

        let transcriber = Transcriber(keyProvider: keyProvider,
                                      model: config.transcriptionModel,
                                      vocabPrompt: Vocab.promptString())
        transcriber.transcribe(wav: wav) { [weak self] result in
            try? FileManager.default.removeItem(at: wav)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let e):
                    log("transcription failed: \(e)")
                    self.state = .idle
                case .success(let text):
                    self.handleTranscript(text)
                }
            }
        }
    }

    private func handleTranscript(_ text: String) {
        guard !text.isEmpty else { log("empty transcript"); state = .idle; return }
        if config.cleanupDefault {
            Cleanup(keyProvider: keyProvider, model: config.cleanupModel, effort: config.cleanupEffort).clean(text) { [weak self] cleaned in
                guard let self else { return }
                let final = Agent.deliverable(transcript: text, cleaned: cleaned, config: self.config)
                DispatchQueue.main.async { self.finish(final) }
            }
        } else {
            finish(ToneStrip.apply(text, mode: .raw, stripTells: config.stripAITells))
        }
    }

    /// Cleanup-mode paste payload. With includeRaw, prepend the raw transcript + a blank line so an
    /// LLM downstream can recover intent if the cleanup went sideways. Skip the prepend when the two
    /// are identical (e.g. cleanup fell back to the raw transcript) to avoid pasting the same text twice.
    /// Cleanup-mode text to deliver. The raw transcript gets the light tone pass only. A failed
    /// cleanup (nil), or a cleanup the phrase strip empties ("I hope this helps."), delivers the raw
    /// transcript instead, so a dictation is never lost.
    static func deliverable(transcript: String, cleaned: String?, config: Config) -> String {
        let raw = ToneStrip.apply(transcript, mode: .raw, stripTells: config.stripAITells)
        let tidy = cleaned.map { ToneStrip.apply($0, mode: .cleanup, stripTells: config.stripAITells) } ?? ""
        if cleaned != nil && tidy.isEmpty { log("cleanup failed: the tone pass left nothing — using raw transcript") }
        return composeOutput(raw: raw, cleaned: tidy.isEmpty ? raw : tidy, includeRaw: config.includeRawTranscript)
    }

    static func composeOutput(raw: String, cleaned: String, includeRaw: Bool) -> String {
        guard includeRaw, !raw.isEmpty, raw != cleaned else { return cleaned }
        return raw + "\n\n" + cleaned
    }

    private func finish(_ text: String) {
        if config.autoPaste {
            Paster.paste(text, restoreAfter: config.pasteRestore)
            log("pasted \(text.count) chars at cursor")
        } else {
            Paster.copy(text)            // clipboard + a distinct chime; user pastes when ready
            chimes.ready()
            log("copied \(text.count) chars to clipboard")
        }
        state = .idle
        indicator?.flourish()   // purple completion bloom, after the state frame clears
    }

    // MARK: - Signals (clean Ctrl-C / launchctl stop)

    private func installSignalHandlers(_ app: NSApplication) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.hotkey?.stop()
                app.terminate(nil)
            }
            src.resume()
            signalSources.append(src)
        }
    }
}
