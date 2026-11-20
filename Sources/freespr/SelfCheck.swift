import Foundation

/// `freespr config --check` — runs ToneStrip + Config asserts. The one runnable check the
/// build leaves behind (no XCTest bundle → zero deps). Uses explicit comparisons rather than
/// assert() so it also works in a release binary.
enum SelfCheck {
    static func run() -> Int32 {
        var failures = 0

        func eq(_ name: String, _ got: String, _ want: String) {
            if got == want { print("ok   \(name)") }
            else {
                print("FAIL \(name)")
                print("       got:  \(q(got))")
                print("       want: \(q(want))")
                failures += 1
            }
        }
        func ok(_ name: String, _ cond: Bool) {
            if cond { print("ok   \(name)") } else { print("FAIL \(name)"); failures += 1 }
        }
        func q(_ s: String) -> String { "\"\(s.replacingOccurrences(of: "\n", with: "\\n"))\"" }

        // --- ToneStrip ---
        eq("em-dash→hyphen",
           ToneStrip.apply("Plan A — do X", mode: .cleanup), "Plan A - do X")
        eq("absolutely-right cleanup",
           ToneStrip.apply("You're absolutely right, that works", mode: .cleanup), "that works")
        eq("absolutely-right raw keeps phrase",
           ToneStrip.apply("You're absolutely right, that works", mode: .raw),
           "You're absolutely right, that works")
        eq("mid-sentence absolutely right kept",
           ToneStrip.apply("She was absolutely right about it.", mode: .cleanup),
           "She was absolutely right about it.")
        eq("exclamation collapse",
           ToneStrip.apply("Done!!!", mode: .cleanup), "Done!")
        eq("smart quotes + ellipsis",
           ToneStrip.apply("…“sync”…", mode: .cleanup), "...\"sync\"...")
        eq("emoji removed",
           ToneStrip.apply("ship it 🚀", mode: .cleanup), "ship it")
        eq("raw normalizes chars, keeps jargon",
           ToneStrip.apply("Let's circle back — 😀", mode: .raw), "Let's circle back -")
        eq("jargon swap in cleanup",
           ToneStrip.apply("Let's circle back tomorrow.", mode: .cleanup), "Let's follow up tomorrow.")
        eq("AI-filler sign-off dropped",
           ToneStrip.apply("Here is the plan. I hope this helps!", mode: .cleanup), "Here is the plan.")
        eq("trademark/copyright symbols kept",
           ToneStrip.apply("the Acme™ product © 2026", mode: .cleanup), "the Acme™ product © 2026")
        eq("reach out → get in touch",
           ToneStrip.apply("I'll reach out tomorrow.", mode: .cleanup), "I'll get in touch tomorrow.")
        eq("tone: leverage as a noun survives",
           ToneStrip.apply("We have leverage here, and a leveraged buyout.", mode: .cleanup),
           "We have leverage here, and a leveraged buyout.")
        eq("tone: leveraging still becomes using",
           ToneStrip.apply("We're leveraging the cache.", mode: .cleanup), "We're using the cache.")
        eq("tone: strip_ai_tells = false keeps the model's text (whitespace tidy only)",
           ToneStrip.apply("Plan A \u{2014} circle back  \u{1F680} !!", mode: .cleanup, stripTells: false),
           "Plan A \u{2014} circle back \u{1F680}!!")

        // --- Model defaults + cleanup request shape ---
        eq("default transcription model", Config().transcriptionModel, "gpt-transcribe")
        eq("default cleanup model", Config().cleanupModel, "gpt-6-luna")
        let cp = Cleanup.payload(model: Config().cleanupModel, effort: Config().cleanupEffort, transcript: "hi")
        eq("cleanup reasoning effort = cleanup_effort", cp["reasoning_effort"] as? String ?? "", Config().cleanupEffort)
        eq("cleanup_effort parses", Config.parse("cleanup_effort = \"low\"").cleanupEffort, "low")
        eq("cleanup_effort empty → default", Config.parse("cleanup_effort = \"\"").cleanupEffort, Config().cleanupEffort)
        eq("cleanup_effort typo → default", Config.parse("cleanup_effort = \"xhgh\"").cleanupEffort, Config().cleanupEffort)
        eq("cleanup_effort is case-insensitive", Config.parse("cleanup_effort = \"Medium\"").cleanupEffort, "medium")
        let quiet = Config.parse("include_raw_transcript = false")
        eq("cleanup failure delivers the raw transcript",
           Agent.deliverable(transcript: "I hope this helps.", cleaned: nil, config: quiet), "I hope this helps.")
        eq("cleanup the phrase strip empties delivers the raw transcript",
           Agent.deliverable(transcript: "I hope this helps.", cleaned: "I hope this helps.", config: quiet),
           "I hope this helps.")
        eq("cleanup success delivers the cleaned text",
           Agent.deliverable(transcript: "um so ship it", cleaned: "So ship it.", config: quiet), "So ship it.")
        eq("API error text masks key-shaped strings",
           OpenAI.errorMessage(Data(#"{"error":{"message":"Incorrect API key provided: sk-proj-ab12****wxyz."}}"#.utf8)),
           "Incorrect API key provided: sk-….")
        ok("default output is cleaned text only", Config().includeRawTranscript == false)
        ok("default strips AI tells", Config().stripAITells)
        ok("strip_ai_tells = false parses", Config.parse("strip_ai_tells = false").stripAITells == false)
        eq("cleanup instructions use developer role",
           (cp["messages"] as? [[String: String]])?.first?["role"] ?? "", "developer")

        // --- Config round-trip ---
        let defaults = Config()
        ok("config defaults round-trip", Config.parse(defaults.rendered()) == defaults)
        var edited = Config()
        edited.holdThresholdMs = 333
        edited.cleanupDefault = false
        edited.pasteRestoreMs = 400
        edited.maxRecordingSec = 900
        edited.autoPaste = true
        edited.cleanupModel = "gpt-5.4-nano"
        edited.indicator = "off"
        edited.cleanupEffort = "low"
        edited.stripAITells = false
        edited.includeRawTranscript = true
        ok("config edited round-trip", Config.parse(edited.rendered()) == edited)
        ok("config missing key → default",
           Config.parse("hold_threshold_ms = 500").holdThresholdMs == 500
           && Config.parse("hold_threshold_ms = 500").silenceTimeoutSec == 30)
        ok("config garbage int → default",
           Config.parse("hold_threshold_ms = abc").holdThresholdMs == 1250)
        ok("config inline comment",
           Config.parse("hold_threshold_ms = 250 # ms").holdThresholdMs == 250)
        ok("config bool synonyms",
           Config.parse("cleanup_default = no").cleanupDefault == false)
        var zeroHold = Config(); zeroHold.holdThresholdMs = 0
        ok("hold threshold floored to 50ms", zeroHold.holdThreshold == 0.05)
        ok("config include_raw_transcript round-trip", {
            var c = Config(); c.includeRawTranscript = true
            return Config.parse(c.rendered()) == c
        }())
        ok("config indicator round-trip", {
            var c = Config(); c.indicator = "off"
            return Config.parse(c.rendered()) == c
        }())
        ok("config indicator default = glow-on", Config.parse("").indicatorEnabled)
        ok("config indicator off disables", Config.parse("indicator = \"off\"").indicatorEnabled == false)
        ok("config indicator bool spellings disable", Config.parse("indicator = \"no\"").indicatorEnabled == false)
        ok("config indicator unknown → glow-on", Config.parse("indicator = \"banana\"").indicatorEnabled)

        // --- Indicator strip geometry (the pure part; the glow itself is verified by eye) ---
        let sb = NSRect(x: 0, y: 0, width: 1000, height: 500)
        let stripsG = Indicator.stripFrames(around: sb, thickness: 14)
        ok("indicator: 4 edge strips inside the screen",
           stripsG.count == 4 && stripsG.allSatisfy { sb.contains($0.rect) })
        ok("indicator strips hug all four edges",
           stripsG[0].rect.maxY == sb.maxY && stripsG[1].rect.minY == sb.minY
           && stripsG[2].rect.minX == sb.minX && stripsG[3].rect.maxX == sb.maxX)
        ok("indicator sides run full height (windows overlap; draw() miters corners at 45°)", {
            let full = stripsG[2].rect.height == sb.height && stripsG[3].rect.height == sb.height
            let area = stripsG.reduce(CGFloat(0)) { $0 + $1.rect.width * $1.rect.height }
            return full && area == 2 * sb.width * 14 + 2 * 14 * sb.height   // corners counted twice
        }())

        // --- compose output (raw + cleaned) ---
        eq("compose: raw above cleaned",
           Agent.composeOutput(raw: "hello world", cleaned: "Hello world.", includeRaw: true),
           "hello world\n\nHello world.")
        eq("compose: dedup when identical",
           Agent.composeOutput(raw: "same", cleaned: "same", includeRaw: true), "same")
        eq("compose: includeRaw off → cleaned only",
           Agent.composeOutput(raw: "raw", cleaned: "clean", includeRaw: false), "clean")

        // --- Vocab prompt: file order, term-boundary cap, case-insensitive dedup, counts ---
        let v1 = Vocab.build("# comment\nAlpha, Beta\n\nGamma\n", cap: 3000)
        eq("vocab: under the cap sent whole", v1.prompt, "Alpha, Beta, Gamma")
        ok("vocab: under the cap counts 3 kept / 0 dropped", v1.kept == 3 && v1.dropped == 0)
        let v2 = Vocab.build("Alpha\nBeta\nGamma\nDelta", cap: 17)
        eq("vocab: over the cap cut on a term boundary", v2.prompt, "Alpha, Beta")
        ok("vocab: over the cap counts 2 kept / 2 dropped", v2.kept == 2 && v2.dropped == 2)
        let big = (0..<400).map { "term\($0)" }.joined(separator: "\n")
        let v3 = Vocab.build(big)
        ok("vocab: full list never exceeds the 3000 cap",
           v3.prompt.count <= 3000 && v3.prompt.count > 2990 && v3.kept + v3.dropped == 400 && v3.dropped > 0)
        ok("vocab: cut lands on a whole term", v3.prompt.hasSuffix("term\(v3.kept - 1)"))
        let v4 = Vocab.build("vLLM, VLLM\nvllm\nAcmeAI", cap: 3000)
        eq("vocab: case-only duplicates sent once", v4.prompt, "vLLM, AcmeAI")
        ok("vocab: duplicates are not counted as dropped", v4.kept == 2 && v4.dropped == 0)
        ok("vocab: default cap is 3000", Vocab.defaultCap == 3000)

        // --- Windows line endings: split on exactly LF and CRLF, nothing else ---
        let v5 = Vocab.build("# comment\r\nAlpha, Beta\r\n\r\nGamma\r\n", cap: 3000)
        eq("vocab: CRLF file splits into lines, comment skipped", v5.prompt, "Alpha, Beta, Gamma")
        ok("vocab: CRLF file counts 3 kept / 0 dropped", v5.kept == 3 && v5.dropped == 0)
        let v6 = Vocab.build("Al\rpha\nBe\u{0C}ta\n# c\u{2028}omment\nGam\u{2028}ma", cap: 3000)
        eq("vocab: lone CR, form feed, U+2028 stay inside their line",
           v6.prompt, "Al\rpha, Be\u{0C}ta, Gam\u{2028}ma")
        let crlf = Config.parse("# freespr config\r\nhold_threshold_ms = 777\r\ncleanup_default = false\r\n")
        ok("config: CRLF file is read line by line", crlf.holdThresholdMs == 777 && crlf.cleanupDefault == false)

        // --- Daemon microphone state from its log (what `freespr status` shows) ---
        let micLog = "[11-18 09:00:00] microphone: not-determined\n"
            + "[11-18 09:00:05] microphone request answered: granted\n"
            + "[11-18 09:00:05] microphone: authorized\n"
            + "[11-18 10:00:00] microphone blocked — turn ON freespr in System Settings\n"
        ok("mic state: newest sentinel wins, other microphone lines ignored",
           Lifecycle.daemonMicState(fromLog: micLog) == .authorized)
        ok("mic state: a later denial is reported",
           Lifecycle.daemonMicState(fromLog: micLog + "[11-18 11:00:00] microphone: denied\n") == .denied)
        ok("mic state: an unknown token is skipped",
           Lifecycle.daemonMicState(fromLog: micLog + "[11-18 11:00:00] microphone: banana\n") == .authorized)
        ok("mic state: no sentinel → unknown", Lifecycle.daemonMicState(fromLog: "[11-18] hotkey active\n") == nil)

        // --- Purge only removes CLI links that point into freespr.app ---
        let linkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("freespr-selfcheck-links-\(UUID().uuidString)")
        let appBin = linkDir.appendingPathComponent("freespr.app/Contents/MacOS/freespr")
        if (try? FileManager.default.createDirectory(at: appBin.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)) != nil,
           FileManager.default.createFile(atPath: appBin.path, contents: Data()) {
            let fm = FileManager.default, d = linkDir.path
            try? fm.createSymbolicLink(atPath: "\(d)/direct", withDestinationPath: appBin.path)
            try? fm.createSymbolicLink(atPath: "\(d)/chained", withDestinationPath: "direct")
            try? fm.createSymbolicLink(atPath: "\(d)/other", withDestinationPath: "/usr/bin/true")
            fm.createFile(atPath: "\(d)/plain", contents: Data())
            let elsewhere = linkDir.appendingPathComponent("someone/freespr.app/Contents/MacOS/freespr")
            try? fm.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: elsewhere.path, contents: Data())
            try? fm.createSymbolicLink(atPath: "\(d)/foreign", withDestinationPath: elsewhere.path)
            let mine = appBin.path
            ok("purge: links to this account's app binary are ours (direct and chained)",
               Lifecycle.linkPointsIntoApp("\(d)/direct", appBinary: mine)
               && Lifecycle.linkPointsIntoApp("\(d)/chained", appBinary: mine))
            ok("purge: another freespr.app, unrelated link, plain file and missing path are not ours",
               !Lifecycle.linkPointsIntoApp("\(d)/foreign", appBinary: mine)
               && !Lifecycle.linkPointsIntoApp("\(d)/other", appBinary: mine)
               && !Lifecycle.linkPointsIntoApp("\(d)/plain", appBinary: mine)
               && !Lifecycle.linkPointsIntoApp("\(d)/missing", appBinary: mine))
            ok("purge: a folder without our bundle id is not our app",
               !Lifecycle.isOurApp(linkDir.appendingPathComponent("freespr.app").path))
            try? fm.removeItem(at: linkDir)
        } else { ok("purge link fixture created", false) }

        // --- WavWriter header (no mic needed): 0.5s of silence → valid 16k/mono/16-bit WAV ---
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("freespr-selfcheck-\(UUID().uuidString).wav")
        if let w = try? WavWriter(url: wavURL) {
            w.append(Data(count: 8000 * 2))      // 8000 Int16 samples = 0.5s @ 16 kHz
            _ = w.finalize()
            if let bytes = try? Data(contentsOf: wavURL) {
                let riff = String(data: bytes.subdata(in: 0..<4), encoding: .ascii)
                let wave = String(data: bytes.subdata(in: 8..<12), encoding: .ascii)
                let sr = bytes.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                let bits = bytes.subdata(in: 34..<36).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
                let dataLen = bytes.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                ok("wav RIFF/WAVE magic", riff == "RIFF" && wave == "WAVE")
                ok("wav 16kHz/16-bit header", sr == 16000 && bits == 16)
                ok("wav data length patched", dataLen == 16000 && bytes.count == 44 + 16000)
            } else { ok("wav readable", false) }
            try? FileManager.default.removeItem(at: wavURL)
        } else { ok("wav writer opens", false) }

        // --- Leftover recordings: only freespr-<UUID>.wav goes; self-check and other files stay ---
        ok("recording name: freespr-<UUID>.wav", AudioRecorder.isRecordingName("freespr-\(UUID().uuidString).wav"))
        ok("recording name: not a self-check WAV", !AudioRecorder.isRecordingName("freespr-selfcheck-\(UUID().uuidString).wav"))
        ok("recording name: not other freespr files", !AudioRecorder.isRecordingName("freespr-notes.wav"))
        let leftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("freespr-leftover-check-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        if (try? fm.createDirectory(at: leftDir, withIntermediateDirectories: false)) != nil {
            func path(_ name: String) -> String { leftDir.appendingPathComponent(name).path }
            let hourAgo = Date().addingTimeInterval(-3600)
            let old = "freespr-\(UUID().uuidString).wav", fresh = "freespr-\(UUID().uuidString).wav"
            let folder = "freespr-\(UUID().uuidString).wav", link = "freespr-\(UUID().uuidString).wav"
            let plain = ["freespr-selfcheck-\(UUID().uuidString).wav", "freespr-notes.wav", "other.wav"]
            for name in plain + [old, fresh] { fm.createFile(atPath: path(name), contents: Data()) }
            try? fm.createDirectory(atPath: path(folder), withIntermediateDirectories: false)
            try? fm.createSymbolicLink(atPath: path(link), withDestinationPath: path("other.wav"))
            for name in plain + [old, folder] { try? fm.setAttributes([.modificationDate: hourAgo], ofItemAtPath: path(name)) }
            let removed = AudioRecorder.removeLeftoverRecordings(in: leftDir, olderThan: 15 * 60)
            let left = Set((try? fm.contentsOfDirectory(atPath: leftDir.path)) ?? [])
            ok("leftover recordings: removes only an old recording file",
               removed == 1 && left == Set(plain + [fresh, folder, link]))
            ok("leftover recordings: age 0 also takes the fresh one, never a folder or link",
               AudioRecorder.removeLeftoverRecordings(in: leftDir, olderThan: 0) == 1
               && fm.fileExists(atPath: path("other.wav")))
            try? fm.removeItem(at: leftDir)
        } else { ok("leftover fixture created", false) }

        print(failures == 0 ? "\nAll self-checks passed." : "\n\(failures) self-check(s) FAILED.")
        return failures == 0 ? 0 : 1
    }
}
