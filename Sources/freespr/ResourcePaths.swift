import Foundation

/// Where the daemon finds its files at runtime. User-editable config/vocab/style live in
/// ~/.config/freespr/; shipped copies next to the binary (or ../share/freespr for Homebrew)
/// are the fallback so a fresh binary still works before `init` copies them in.
enum ResourcePaths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var configDir: URL { home.appendingPathComponent(".config/freespr", isDirectory: true) }
    static var configFile: URL { configDir.appendingPathComponent("config.toml") }
    static var launchAgentPlist: URL {
        home.appendingPathComponent("Library/LaunchAgents/com.freespr.agent.plist")
    }

    static func ensureConfigDir() throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    }

    /// Resolve a resource by name (vocab.txt / style.md): user config dir first, then
    /// binary-adjacent shipped copies. Returns nil if absent everywhere.
    static func resource(_ name: String) -> URL? {
        let candidates = [configDir.appendingPathComponent(name)]
            + binaryAdjacentDirs.map { $0.appendingPathComponent(name) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var binaryAdjacentDirs: [URL] {
        guard let exe = executableURL else { return [] }
        let binDir = exe.deletingLastPathComponent()
        return [
            binDir,                                                                       // alongside the binary
            binDir.deletingLastPathComponent().appendingPathComponent("share/freespr"),   // ../share/freespr (Homebrew)
        ]
    }

    /// The running binary's real path (symlinks resolved, so a /usr/local/bin → ~/.local/bin
    /// symlink still locates sibling shipped resources).
    static var executableURL: URL? {
        Bundle.main.executableURL?.resolvingSymlinksInPath()
    }

    /// Path as invoked, symlinks NOT resolved — used for the LaunchAgent exec path so a Homebrew
    /// prefix symlink ($(brew --prefix)/bin/freespr) stays stable instead of resolving to a
    /// versioned Cellar path that `brew upgrade` deletes (which would silently kill the daemon).
    static var invokedExecutablePath: String? {
        Bundle.main.executableURL?.path
    }
}
