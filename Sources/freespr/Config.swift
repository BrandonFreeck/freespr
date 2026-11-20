import Foundation

/// freespr settings. Flat TOML at ~/.config/freespr/config.toml, hand-editable. Any missing
/// or unparseable key silently falls back to its default here so a bad hand-edit never takes
/// the headless agent down. The API key is NOT in here (Keychain only).
struct Config: Equatable {
    var triggerRightCmd   = true
    var triggerRightCtrl  = true
    var holdThresholdMs   = 1250    // ms held-alone before it fires (while still held); long = no accidents
    var silenceTimeoutSec = 30
    var maxRecordingSec   = 600     // hard cap on one recording (10 min); 0 = no cap
    var autoPaste         = false   // false = copy to clipboard + ready chime; true = paste at cursor
    var pasteRestoreMs    = 250             // delay before restoring the clipboard after paste (auto mode)
    var transcriptionModel = "gpt-transcribe"
    var cleanupModel       = "gpt-6-luna"
    var cleanupEffort      = "xhigh"        // reasoning_effort sent with every cleanup call
    var cleanupDefault     = true           // false = raw (transcribe-only) by default
    var includeRawTranscript = false        // cleanup mode: raw transcript + blank line + cleaned
    var stripAITells       = true           // deterministic pass after the model (ToneStrip)
    var indicator          = "glow"         // "glow" | "off"

    // Convenience views for the rest of the code.
    // Floor at 50ms: a 0 threshold would make the "held alone past threshold" test always true,
    // so even an instantaneous tap would toggle (defeating the quick-tap-passes-through design).
    var holdThreshold: TimeInterval { Double(max(50, holdThresholdMs)) / 1000.0 }
    var silenceTimeout: TimeInterval { Double(max(1, silenceTimeoutSec)) }
    var maxRecording: TimeInterval { maxRecordingSec <= 0 ? 0 : Double(max(5, maxRecordingSec)) }  // 0 = uncapped
    var pasteRestore: TimeInterval { Double(max(0, pasteRestoreMs)) / 1000.0 }
    // Reuses bool()'s off/false/no/0 spellings; anything unrecognized glows ON so a
    // typo can never silently kill the mic-is-hot cue. Upgrade path: a real mode enum if v2 adds "menubar".
    var indicatorEnabled: Bool { Config.bool(indicator, true) }

    /// Human-readable trigger label (single source — used by both the run banner and `status`).
    var triggerDescription: String {
        switch (triggerRightCmd, triggerRightCtrl) {
        case (true, true):  return "Right-Cmd or Right-Ctrl"
        case (true, false): return "Right-Cmd"
        case (false, true): return "Right-Ctrl"
        default:            return "none!"
        }
    }

    /// Load from disk, or defaults if the file is missing/unreadable.
    static func load() -> Config {
        guard let text = try? String(contentsOf: ResourcePaths.configFile, encoding: .utf8) else {
            return Config()
        }
        return parse(text)
    }

    static func parse(_ text: String) -> Config {
        var kv: [String: String] = [:]
        for rawLine in textLines(text) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") {                                  // quoted string: take up to next quote
                let body = val.dropFirst()
                if let close = body.firstIndex(of: "\"") {
                    val = String(body[..<close])
                } else {
                    val = String(body)
                }
            } else if let hash = val.firstIndex(of: "#") {            // strip inline comment on bare values
                val = val[..<hash].trimmingCharacters(in: .whitespaces)
            }
            kv[key] = val
        }

        var c = Config()
        if let v = kv["trigger_right_cmd"]   { c.triggerRightCmd   = bool(v, c.triggerRightCmd) }
        if let v = kv["trigger_right_ctrl"]  { c.triggerRightCtrl  = bool(v, c.triggerRightCtrl) }
        if let v = kv["hold_threshold_ms"]   { c.holdThresholdMs   = Int(v) ?? c.holdThresholdMs }
        if let v = kv["silence_timeout_sec"] { c.silenceTimeoutSec = Int(v) ?? c.silenceTimeoutSec }
        if let v = kv["max_recording_sec"]   { c.maxRecordingSec   = Int(v) ?? c.maxRecordingSec }
        if let v = kv["auto_paste"]          { c.autoPaste         = bool(v, c.autoPaste) }
        if let v = kv["paste_restore_ms"]    { c.pasteRestoreMs    = Int(v) ?? c.pasteRestoreMs }
        if let v = kv["transcription_model"] { c.transcriptionModel = v.isEmpty ? c.transcriptionModel : v }
        if let v = kv["cleanup_model"]       { c.cleanupModel      = v.isEmpty ? c.cleanupModel : v }
        if let v = kv["cleanup_effort"]      { c.cleanupEffort     = efforts.contains(v.lowercased()) ? v.lowercased() : c.cleanupEffort }
        if let v = kv["cleanup_default"]     { c.cleanupDefault    = bool(v, c.cleanupDefault) }
        if let v = kv["include_raw_transcript"] { c.includeRawTranscript = bool(v, c.includeRawTranscript) }
        if let v = kv["strip_ai_tells"]      { c.stripAITells      = bool(v, c.stripAITells) }
        if let v = kv["indicator"]           { c.indicator          = v.isEmpty ? c.indicator : v }
        return c
    }

    /// reasoning_effort values OpenAI documents; a typo falls back to the default like any bad key.
    static let efforts: Set<String> = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    private static func bool(_ s: String, _ fallback: Bool) -> Bool {
        switch s.lowercased() {
        case "true", "yes", "1", "on": return true
        case "false", "no", "0", "off": return false
        default: return fallback
        }
    }

    /// Render to the commented template. Round-trips through `parse`.
    func rendered() -> String {
        """
        # freespr config — flat TOML, hand-edit freely.
        # Any missing/garbled key falls back to its built-in default. The OpenAI key lives in
        # the macOS Keychain (service "freespr", account "openai-api-key"), never here.

        # --- Trigger ---
        # Hold either modifier ALONE past hold_threshold_ms to toggle recording. A quick tap,
        # or the key used in a shortcut (e.g. Right-Cmd+C), passes through untouched.
        trigger_right_cmd  = \(triggerRightCmd)
        trigger_right_ctrl = \(triggerRightCtrl)
        hold_threshold_ms  = \(holdThresholdMs)

        # --- Recording ---
        silence_timeout_sec = \(silenceTimeoutSec)
        max_recording_sec   = \(maxRecordingSec)   # hard cap on one recording (0 = no cap)

        # --- Output ---
        # auto_paste = false: result goes to the clipboard and a third chime plays when ready —
        # you paste it yourself (no surprise paste at the wrong cursor). true: type it at the cursor.
        auto_paste = \(autoPaste)
        paste_restore_ms = \(pasteRestoreMs)   # auto_paste mode only: delay before restoring your clipboard

        # --- Models ---
        transcription_model = "\(transcriptionModel)"
        # cleanup_model must be a reasoning model: cleanup sends reasoning_effort = cleanup_effort,
        # and a non-reasoning model rejects it (HTTP 400, so every dictation falls back to raw).
        cleanup_model       = "\(cleanupModel)"
        # none, low, medium, high, xhigh or max. Higher reads your intent better but takes longer.
        cleanup_effort      = "\(cleanupEffort)"

        # --- Cleanup ---
        cleanup_default = \(cleanupDefault)
        # When cleaning, also paste the raw transcript above the cleaned text (blank line between).
        # Handy for feeding an LLM: it can recover your intent if the cleanup gets weird.
        include_raw_transcript = \(includeRawTranscript)
        # After the model: em dashes to hyphens, curly quotes to straight, emoji removed, and (cleanup
        # only) stock AI phrases dropped or swapped. false = deliver the text as the model wrote it.
        strip_ai_tells = \(stripAITells)

        # --- Indicator ---
        # Screen-edge glow frame: blue breathing = recording, green = transcribing, purple bloom =
        # text delivered. "glow" (default) or "off".
        indicator = "\(indicator)"
        """
    }

    func write() throws {
        try ResourcePaths.ensureConfigDir()
        try rendered().write(to: ResourcePaths.configFile, atomically: true, encoding: .utf8)
    }
}
