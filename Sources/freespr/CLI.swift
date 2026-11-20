import Foundation

/// Subcommand router. `run` blocks on the agent run loop and never returns normally;
/// everything else does its work and returns an exit code.
enum CLI {
    static func dispatch(_ args: [String]) -> Int32 {
        let cmd = args.first ?? "help"
        let rest = Array(args.dropFirst())
        switch cmd {
        case "run":
            return Agent.shared.runForever()
        case "init":
            return Lifecycle.initWizard()
        case "status":
            let rc = Lifecycle.status()
            print(Vocab.statusLine())
            return rc
        case "uninstall":
            return Lifecycle.uninstall(purge: rest.contains("--purge"))
        case "config":
            // Hidden: `freespr config --check` runs Config round-trip asserts.
            if rest.contains("--check") { return SelfCheck.run() }
            print(Config.load().rendered()); return 0
        case "test-pipeline", "transcribe":
            // Hidden: run the real STT→cleanup→tone pipeline on a WAV and print it (agentic E2E, no mic).
            guard let path = rest.first else {
                FileHandle.standardError.write(Data("usage: freespr test-pipeline <wav>\n".utf8)); return 64
            }
            switch Pipeline.run(wav: URL(fileURLWithPath: path), config: Config.load()) {
            case .success(let out): print(out); return 0
            case .failure(let e):
                FileHandle.standardError.write(Data("pipeline failed: \(e)\n".utf8)); return 1
            }
        case "version", "--version", "-v":
            print("freespr \(freesprVersion)"); return 0
        case "help", "--help", "-h":
            printUsage(); return 0
        default:
            FileHandle.standardError.write(Data("unknown command: \(cmd)\n\n".utf8))
            printUsage(); return 64 // EX_USAGE
        }
    }

    private static func printUsage() {
        let cfg = Config.load()
        let output = cfg.autoPaste
            ? "The text pastes at the cursor (auto_paste = true in ~/.config/freespr/config.toml)."
            : "The text goes to the clipboard with a ready chime;\nset auto_paste = true in ~/.config/freespr/config.toml to paste at the cursor instead."
        print("""
        freespr \(freesprVersion) — BYOK push-to-talk dictation

        usage: freespr <command>

          init        First-run setup: store OpenAI key, pick options, grant the 2 permissions
                      (Microphone, Accessibility), load the agent.
          run         Run the headless agent (what the LaunchAgent calls). Blocks.
          status      Health check: key stored, agent loaded, the agent's Microphone and Hotkey state.
          uninstall   Unload + remove the LaunchAgent. Add --purge to also remove the config, Keychain key,
                      ~/Applications/freespr.app, the CLI links, the permission grants and the log.
          version     Print version.

        Trigger: hold \(cfg.triggerDescription) alone for \(Agent.seconds(cfg.holdThreshold))s to start recording, and again to stop.
        It auto-stops after \(Agent.seconds(cfg.silenceTimeout))s of silence. \(output)
        """)
    }
}

/// The ONE version source. `make install` stamps it into freespr.app's Info.plist (sed on this line).
let freesprVersion = "0.1.0"
