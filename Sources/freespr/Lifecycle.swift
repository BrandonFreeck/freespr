import Foundation
import AppKit

/// init / status / uninstall + LaunchAgent management. The interactive setup that turns the
/// installed binary into a set-and-forget agent.
enum Lifecycle {
    static let label = "com.freespr.agent"
    static var serviceTarget: String { "gui/\(getuid())/\(label)" }
    static var logPath: String { ResourcePaths.home.appendingPathComponent("Library/Logs/freespr.log").path }

    // MARK: - init

    static func initWizard() -> Int32 {
        print("freespr setup\n=============")

        // 1. API key → Keychain (no-echo entry).
        if Keychain.exists() {
            print("\nOpenAI API key: already stored. Replace it? [y/N] ", terminator: "")
            if (readLine() ?? "").lowercased().hasPrefix("y") { promptAndStoreKey() }
        } else {
            promptAndStoreKey()
        }

        // 2. Config (light prompts; everything else stays default and is hand-editable later).
        var cfg = Config.load()
        print("\nClean up dictation by default with \(cfg.cleanupModel)? [Y/n] ", terminator: "")
        let ans = (readLine() ?? "").lowercased()
        cfg.cleanupDefault = !ans.hasPrefix("n")
        do { try cfg.write(); print("  wrote \(ResourcePaths.configFile.path)") }
        catch { print("  could not write config: \(error)") }

        // 3. Resources (vocab.txt / style.md) into the config dir if not already there.
        copyResourceIfAbsent("vocab.txt")
        copyResourceIfAbsent("style.md")

        // 4. Request Mic here (Terminal) so its prompt surfaces, and open the Accessibility pane. The
        // Accessibility grant that actually matters is the one the DAEMON requests in its own bundle
        // context (Agent.runForever → AXIsProcessTrustedWithOptions), which attaches to com.freespr.agent;
        // flipping freespr ON in the pane lets the daemon self-heal within ~3s. (Input Monitoring was the
        // bug: it has no prompt API, so the grant stranded on the CLI path and never reached the daemon.)
        print("\nRequesting permissions — turn ON freespr when it appears (or a prompt shows):")
        print("  • Microphone")
        print("  • Accessibility (the global hotkey)")
        Permissions.requestMicrophone()
        _ = Permissions.hasAccessibility(prompt: true)
        Permissions.openPane(Permissions.axPane)

        // 5. Start the always-on agent and confirm via its log that the tap actually came up.
        print("\nStarting the background agent…")
        do { try writeLaunchAgent() } catch { print("  could not write plist: \(error)"); return 1 }
        let logMark = currentLogOffset()
        loadLaunchAgent()
        print("Waiting for the hotkey to go live (turn freespr ON in Accessibility)…")
        if waitForHotkeyLive(since: logMark, timeout: 120) {
            print("  hotkey is LIVE ✓")
        } else {
            print("  not live yet — make sure freespr is CHECKED in Accessibility, then `freespr status`.")
            print("  (Self-heals within ~3s of the toggle; no restart needed.)")
        }

        // 5. Report.
        print("")
        return status()
    }

    private static func promptAndStoreKey() {
        let key = readSecret("\nPaste your OpenAI API key (input hidden): ")
        guard !key.isEmpty else { print("  no key entered — skipped."); return }
        if !key.hasPrefix("sk-") { print("  note: key doesn't start with \"sk-\" — storing anyway.") }
        do { try Keychain.store(key); print("  stored in Keychain.") }
        catch { print("  Keychain error: \(error)") }
    }

    /// Byte offset of the current end of the log — so we only watch lines the daemon writes AFTER
    /// this point (a stale "hotkey active" from a previous run won't false-positive).
    private static func currentLogOffset() -> UInt64 {
        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: logPath)) else { return 0 }
        defer { try? fh.close() }
        return (try? fh.seekToEnd()) ?? 0
    }

    /// Poll the daemon's own log (its real TCC context) for the tap going live. This is the only
    /// honest "is the hotkey actually working" signal from `init`.
    private static func waitForHotkeyLive(since offset: UInt64, timeout: TimeInterval) -> Bool {
        let url = URL(fileURLWithPath: logPath)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 2.0)
            guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
            try? fh.seek(toOffset: offset)
            let data = (try? fh.readToEnd()) ?? Data()
            try? fh.close()
            if let text = String(data: data, encoding: .utf8), text.contains("hotkey active") { return true }
        }
        return false
    }

    // MARK: - status

    @discardableResult
    static func status() -> Int32 {
        print("freespr status")
        print("--------------")
        let cfg = Config.load()
        let keyOK = Keychain.exists()
        line("OpenAI key (Keychain)", keyOK)
        // Permission rows come from the DAEMON's own log sentinels. An in-process check here would
        // report Terminal's grants, not the agent's, so nothing below asks TCC directly.
        let daemonLog = (try? String(contentsOf: URL(fileURLWithPath: logPath), encoding: .utf8)) ?? ""
        let mic = daemonMicState(fromLog: daemonLog)
        switch mic {
        case .some(.authorized):    print("  [x] Microphone — the headless daemon has access")
        case .some(.denied):        print("  [ ] Microphone DENIED — turn freespr ON in System Settings ▸ Privacy & Security ▸ Microphone")
        case .some(.restricted):    print("  [ ] Microphone RESTRICTED by a device policy — an administrator has to allow it")
        case .some(.notDetermined): print("  [-] Microphone not asked yet — hold the trigger once and click Allow")
        case .none:                 print("  [-] Microphone state unknown — the agent hasn't logged it yet (it does at launch)")
        }
        let micBlocked = mic == .denied || mic == .restricted
        let pid = agentPID()
        let agentOK = pid != nil
        line(pid.map { "Background agent running (pid \($0))" } ?? "Background agent running", agentOK)
        let hk = daemonHotkeyLive(fromLog: daemonLog)
        switch hk {
        case .some(true):  print("  [x] Hotkey LIVE — the headless daemon has the tap")
        case .some(false): print("  [ ] Hotkey NOT live — turn freespr ON in System Settings ▸ Privacy & Security ▸ Accessibility")
        case .none:        print("  [-] Hotkey state unknown — run `freespr init` and re-check")
        }
        line("Config file", FileManager.default.fileExists(atPath: ResourcePaths.configFile.path))
        line("vocab.txt", ResourcePaths.resource("vocab.txt") != nil)
        line("style.md", ResourcePaths.resource("style.md") != nil)
        print("Mode: \(cfg.cleanupDefault ? "cleanup" : "raw") | output: \(cfg.autoPaste ? "auto-paste" : "clipboard") | indicator: \(cfg.indicator) | trigger: \(cfg.triggerDescription) | log: \(logPath)")
        // Gate on the DAEMON's real state. An unknown or not-yet-asked microphone doesn't fail it.
        var fixes: [String] = []
        if !keyOK      { fixes.append("store an OpenAI key (`freespr init`)") }
        if !agentOK    { fixes.append("start the background agent (`freespr init`, or `make reload` in the clone)") }
        if hk != true  { fixes.append("turn freespr ON in Privacy & Security ▸ Accessibility") }
        if micBlocked  { fixes.append("turn freespr ON in Privacy & Security ▸ Microphone") }
        let healthy = fixes.isEmpty
        print(healthy ? "\nAll good — hold a trigger key and talk." : "\nNot ready — " + fixes.joined(separator: "; ") + ".")
        return healthy ? 0 : 1
    }

    /// The daemon's REAL hotkey state, read from its own log (the Terminal-context permission checks
    /// can't see the daemon). Sentinels come from two writers — launch (Agent) and the mid-session
    /// watchdog (HotkeyTap) — the newest one wins. nil = neither logged yet.
    private static func daemonHotkeyLive(fromLog text: String) -> Bool? {
        for line in text.split(separator: "\n").reversed() {
            if line.contains("hotkey active") || line.contains("watchdog: tap recreated")
                || line.contains("watchdog: hotkey tap recovered") { return true }
            if line.contains("Accessibility needed") || line.contains("watchdog: hotkey DEAD") { return false }
        }
        return nil
    }

    /// The daemon's microphone state from its own log: the newest `[timestamp] microphone: <state>`
    /// line wins (Agent logs it at launch, after a permission prompt, and whenever it changes at
    /// hotkey time). nil = never logged (old binary, or the agent hasn't started). Pure, for SelfCheck.
    static func daemonMicState(fromLog text: String) -> Permissions.MicState? {
        let anchor = "] " + Permissions.MicState.sentinel
        for line in text.split(separator: "\n").reversed() {
            guard let r = line.range(of: anchor) else { continue }
            let token = line[r.upperBound...].prefix { !$0.isWhitespace }
            if let state = Permissions.MicState(rawValue: String(token)) { return state }
        }
        return nil
    }

    private static func line(_ label: String, _ ok: Bool) {
        print("  [\(ok ? "x" : " ")] \(label)")
    }

    // MARK: - uninstall

    static func uninstall(purge: Bool) -> Int32 {
        Shell.run("/bin/launchctl", ["bootout", serviceTarget])
        report("LaunchAgent \(label)", remove(ResourcePaths.launchAgentPlist.path))

        var doPurge = purge
        if !purge {
            print("Also delete everything else freespr installed: config (~/.config/freespr), the stored API key, "
                + "~/Applications/freespr.app, the freespr CLI links, its Accessibility + Microphone grants and the log? [y/N] ",
                  terminator: "")
            doPurge = (readLine() ?? "").lowercased().hasPrefix("y")
        }
        guard doPurge else {
            print("Kept config, API key, app, CLI links, grants and log (use --purge to remove them).")
            return 0
        }

        report("config \(ResourcePaths.configDir.path)", remove(ResourcePaths.configDir.path))
        if Keychain.exists() {
            do { try Keychain.delete(); report("API key (Keychain)", "removed") }
            catch { report("API key (Keychain)", "FAILED: \(error)") }
        } else {
            report("API key (Keychain)", "skipped (not found)")
        }

        // Decide on both CLI links BEFORE deleting anything: /usr/local/bin/freespr usually points at
        // ~/.local/bin/freespr, which points into the app, so the chain only resolves while it exists.
        let home = ResourcePaths.home.path
        let links = ["\(home)/.local/bin/freespr", "/usr/local/bin/freespr"]
        let ours = links.map { ($0, linkPointsIntoApp($0)) }

        // TCC before the app: tccutil may resolve the bundle id through the installed app.
        // Service names are the kTCCService* suffixes (tccutil formats "kTCCService%s").
        for service in ["Accessibility", "Microphone"] {
            let r = Shell.run("/usr/bin/tccutil", ["reset", service, label])
            report("\(service) permission for \(label)",
                   r.status == 0 ? "reset" : "skipped (tccutil: \(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
        }

        let appThere = (try? FileManager.default.attributesOfItem(atPath: appPath)) != nil
        report("app \(appPath)", !appThere || isOurApp(appPath) ? remove(appPath)
               : "skipped (its bundle id isn't \(label))")
        for (path, isOurs) in ours {
            report("CLI link \(path)", isOurs ? remove(path) : "skipped (not a freespr.app link)")
        }
        report("log \(logPath)", remove(logPath))
        let leftovers = AudioRecorder.removeLeftoverRecordings(olderThan: 0)   // the agent was booted out above
        report("leftover recordings", leftovers == 0 ? "skipped (none found)" : "removed \(leftovers)")

        print("""

        Kept: the self-signed signing identity, if you ran `make cert`. To remove it and its trust setting:
          security delete-identity -c freespr-codesign -t ~/Library/Keychains/login.keychain-db
        (-t also deletes the certificate's user trust settings; macOS may ask for your login password.)
        """)
        return 0
    }

    static var appPath: String { ResourcePaths.home.appendingPathComponent("Applications/freespr.app").path }
    static var appBinaryPath: String { appPath + "/Contents/MacOS/freespr" }

    /// True when the folder at `path` is a FreeSPR bundle (its Info.plist names our bundle id).
    static func isOurApp(_ path: String) -> Bool {
        (NSDictionary(contentsOfFile: path + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String) == label
    }

    /// Remove a file, directory or symlink (never following it). Safe when it's already gone.
    private static func remove(_ path: String) -> String {
        let exists = (try? FileManager.default.attributesOfItem(atPath: path)) != nil   // lstat: sees dangling links
        guard exists else { return "skipped (not found)" }
        do { try FileManager.default.removeItem(atPath: path); return "removed" }
        catch { return "FAILED: \(error.localizedDescription)" }
    }

    private static func report(_ item: String, _ result: String) { print("  \(item): \(result)") }

    /// True only if `path` is a symlink whose whole chain ends at this account's own app binary, so
    /// purge never deletes an unrelated `freespr`, or a link to someone else's install. Call it while
    /// the app still exists.
    static func linkPointsIntoApp(_ path: String, appBinary: String = appBinaryPath) -> Bool {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil,
              FileManager.default.fileExists(atPath: appBinary) else { return false }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: appBinary).resolvingSymlinksInPath().path
    }

    // MARK: - LaunchAgent

    static func writeLaunchAgent() throws {
        // Point at the .app bundle's binary, and declare AssociatedBundleIdentifiers = the bundle id.
        // That key is what tells launchd→TCC "this background process IS com.freespr.agent", which is
        // what lets the HEADLESS agent hold its grants as the bundle (Accessibility, Microphone) and
        // surfaces it named in the Privacy panes. Prefer the installed bundle path; fall back to whatever invoked us.
        let bundleBinary = ResourcePaths.home
            .appendingPathComponent("Applications/freespr.app/Contents/MacOS/freespr").path
        let binary = FileManager.default.fileExists(atPath: bundleBinary)
            ? bundleBinary
            : (ResourcePaths.invokedExecutablePath
               ?? ResourcePaths.home.appendingPathComponent(".local/bin/freespr").path)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>AssociatedBundleIdentifiers</key>
            <string>com.freespr.agent</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binary)</string>
                <string>run</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>StandardOutPath</key>
            <string>\(logPath)</string>
            <key>StandardErrorPath</key>
            <string>\(logPath)</string>
        </dict>
        </plist>
        """
        let dir = ResourcePaths.launchAgentPlist.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try plist.write(to: ResourcePaths.launchAgentPlist, atomically: true, encoding: .utf8)
    }

    static func loadLaunchAgent() {
        Shell.run("/bin/launchctl", ["bootout", serviceTarget])                  // ignore if not loaded
        Shell.run("/bin/launchctl", ["enable", serviceTarget])                   // clear any disabled override BEFORE bootstrap
        let r = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", ResourcePaths.launchAgentPlist.path])
        Shell.run("/bin/launchctl", ["kickstart", "-k", serviceTarget])
        if r.status != 0 { print("  launchctl bootstrap: \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    /// The agent's pid when launchd has it loaded AND running; nil when it's absent or not running
    /// (loaded but crashed or exited), which the log sentinels alone can't tell apart from healthy.
    static func agentPID() -> Int? {
        let r = Shell.run("/bin/launchctl", ["print", serviceTarget])
        guard r.status == 0 else { return nil }
        for line in r.out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("pid = "), let n = Int(t.dropFirst(6)) { return n }
        }
        return nil
    }

    // MARK: - helpers

    private static func copyResourceIfAbsent(_ name: String) {
        let dest = ResourcePaths.configDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { return }
        // Look for a shipped copy next to the binary (skip the dest path itself).
        for dir in ResourcePaths.binaryAdjacentDirs {
            let src = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.createDirectory(at: ResourcePaths.configDir, withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: src, to: dest)
                print("  installed \(name) → \(dest.path)")
                return
            }
        }
    }

    /// No-echo terminal read for the API key. If stdin isn't a TTY (piped/redirected), skip the
    /// termios dance entirely — tcgetattr would fail, leaving `original` zeroed, and restoring that
    /// garbage would corrupt the caller's terminal.
    private static func readSecret(_ prompt: String) -> String {
        FileHandle.standardOutput.write(Data(prompt.utf8))
        var original = termios()
        let isTTY = isatty(STDIN_FILENO) != 0 && tcgetattr(STDIN_FILENO, &original) == 0
        if isTTY {
            var noEcho = original
            noEcho.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(STDIN_FILENO, TCSANOW, &noEcho)
        }
        defer { if isTTY { tcsetattr(STDIN_FILENO, TCSANOW, &original); print("") } }
        return (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
    }
}

/// Minimal subprocess runner (launchctl).
enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
