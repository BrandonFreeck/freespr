import Foundation

/// The Keychain seam. Transcriber/Cleanup depend on this protocol, not on Keychain directly,
/// so the dev (env-var) and production (Keychain) paths swap with one line in Agent.
protocol APIKeyProvider {
    func openAIKey() throws -> String
}

/// Dev fallback: OPENAI_API_KEY env var. Lets freespr run from a terminal (and `make test`)
/// before `freespr init` has stored a key.
struct EnvAPIKeyProvider: APIKeyProvider {
    func openAIKey() throws -> String {
        guard let k = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !k.isEmpty else {
            throw FreesprError.missingAPIKey
        }
        return k
    }
}

/// Production default: Keychain first, env var as a dev convenience fallback.
struct DefaultAPIKeyProvider: APIKeyProvider {
    func openAIKey() throws -> String {
        if Keychain.exists(), let k = try? Keychain.load() { return k }
        return try EnvAPIKeyProvider().openAIKey()
    }
}
