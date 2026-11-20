import Foundation

/// vocab.txt → a single comma-joined string fed to the transcription `prompt` param to bias
/// jargon/spelling. Terms are de-duplicated case-insensitively and kept in file order (file order
/// is priority); the string is cut on a term boundary at `defaultCap` characters, and the terms
/// past the cut are counted so `status` and the agent log can report them instead of dropping
/// them silently.
enum Vocab {
    static let defaultCap = 3000

    struct Result { let prompt: String; let kept: Int; let dropped: Int }

    /// Pure: file text + cap → prompt string and kept/dropped term counts.
    static func build(_ text: String, cap: Int = defaultCap) -> Result {
        var seen = Set<String>()
        var terms: [String] = []
        for rawLine in textLines(text) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            for part in line.split(separator: ",") {
                let t = part.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
                terms.append(t)
            }
        }

        var result = ""
        var kept = 0
        for t in terms {
            let candidate = result.isEmpty ? t : result + ", " + t
            if candidate.count > cap { break }
            result = candidate
            kept += 1
        }
        return Result(prompt: result, kept: kept, dropped: terms.count - kept)
    }

    static func load(cap: Int = defaultCap) -> Result {
        guard let url = ResourcePaths.resource("vocab.txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return Result(prompt: "", kept: 0, dropped: 0)
        }
        return build(text, cap: cap)
    }

    static func promptString(cap: Int = defaultCap) -> String { load(cap: cap).prompt }

    /// One line for `freespr status`, e.g. `Vocab: 73 terms sent, 0 dropped (cap 3000 chars)`.
    static func statusLine() -> String {
        let r = load()
        return "Vocab: \(r.kept) terms sent, \(r.dropped) dropped (cap \(defaultCap) chars)"
    }
}
