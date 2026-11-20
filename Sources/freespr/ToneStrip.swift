import Foundation

enum ToneMode {
    case cleanup   // full pass: character normalization + phrase strip
    case raw       // light pass: character normalization only (stays faithful to spoken words)
}

/// Deterministic anti-AI-tell strip. Runs AFTER the LLM in BOTH modes so a model slip
/// can't reintroduce a banned token. The hard tells (em dash, smart quotes, emoji,
/// "you're absolutely right", AI-filler sign-offs, exclamation spam) have clean,
/// unambiguous fixes — those we enforce here. Fuzzy word swaps that risk mangling
/// meaning (e.g. bare "synergy") are left to the LLM system prompt, not done blindly here.
///
/// The prompt-side twin of these rules is the "Hard rules" section of style.md.
/// `strip_ai_tells = false` in config.toml skips everything here but the whitespace tidy.
enum ToneStrip {
    static func apply(_ input: String, mode: ToneMode, stripTells: Bool = true) -> String {
        var s = input
        if stripTells {
            s = normalizeCharacters(s)                   // both modes
            if mode == .cleanup { s = stripPhrases(s) }  // cleanup only
        }
        s = collapseWhitespace(s)                        // always, last
        return s
    }

    // MARK: - Character normalization (both modes)

    static func normalizeCharacters(_ input: String) -> String {
        var s = input
        // The headline rule: em dash + horizontal bar → spaced hyphen (whitespace collapse
        // tidies "A — B" and "A—B" alike). En dash → plain hyphen so number ranges (10–20)
        // stay tight.
        s = s.replacingOccurrences(of: "\u{2014}", with: " - ") // — em dash
        s = s.replacingOccurrences(of: "\u{2015}", with: " - ") // ― horizontal bar
        s = s.replacingOccurrences(of: "\u{2013}", with: "-")   // – en dash
        // Smart quotes → straight (also normalizes apostrophes so phrase matching works).
        s = s.replacingOccurrences(of: "\u{201C}", with: "\"")  // “
        s = s.replacingOccurrences(of: "\u{201D}", with: "\"")  // ”
        s = s.replacingOccurrences(of: "\u{2018}", with: "'")   // ‘
        s = s.replacingOccurrences(of: "\u{2019}", with: "'")   // ’
        s = s.replacingOccurrences(of: "\u{2026}", with: "...") // … ellipsis
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")   // non-breaking space
        s = stripEmoji(s)
        return s
    }

    private static func stripEmoji(_ input: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in input.unicodeScalars {
            if scalar.isASCII { out.append(scalar); continue } // keep digits/#/* and all text
            let p = scalar.properties
            // Strip default-presentation emoji (🚀😀) and modifiers/joiners, but NOT text-default
            // symbols that merely have Emoji=Yes (™ © ® and the like) — those are real text.
            if p.isEmojiPresentation || p.isEmojiModifier || p.isEmojiModifierBase { continue }
            if scalar.value == 0x200D || scalar.value == 0xFE0F || scalar.value == 0xFE0E { continue } // ZWJ / VS16 / VS15
            out.append(scalar)
        }
        return String(out)
    }

    // MARK: - Phrase strip (cleanup mode only)

    static func stripPhrases(_ input: String) -> String {
        var s = input

        // "you're absolutely right" / "absolutely right" — only at the start of the text or a
        // sentence, so legit mid-sentence usage ("she was absolutely right about X") survives.
        // Keep the captured boundary ($1).
        s = regexReplace(s, #"(^|[.!?]\s+)(you're\s+)?absolutely\s+right\b[\s,!.]*"#, "$1")

        // LLM preambles (style.md says output cleaned text only; backstop anyway). Leading only.
        s = regexReplace(s, #"^\s*(sure|certainly|of course|got it)[,!.]?\s+(here's|here is)\b[^\n:]*:\s*"#, "")
        s = regexReplace(s, #"^\s*(here's|here is)\s+(the\s+|your\s+)?(cleaned|edited|revised|polished)[^\n:]*:\s*"#, "")

        // Generic AI-filler sign-offs → drop the clause.
        s = regexReplace(s, #"\s*\bi hope (this|it)( email| message)?\s*(is\s+)?(helps|helpful)\b[.!]*"#, "")
        s = regexReplace(s, #"\s*\bi hope (this|you|this email|this message)\b[^.!?\n]*finds you well[^.!?\n]*[.!?]*"#, "")
        s = regexReplace(s, #"\s*\bfeel free to (reach out|ask|contact me|let me know)\b[^.!?\n]*[.!?]*"#, "")
        s = regexReplace(s, #"\s*\blet me know if you (have any questions|need anything|have questions|'?d like)\b[^.!?\n]*[.!?]*"#, "")

        // Grammar-safe corporate-jargon swaps. Bare "synergy" is left to the LLM (no drop-in
        // replacement), and so are "leverage" and "leveraged": they're nouns and adjectives too
        // ("we have leverage", "a leveraged buyout"), so a blind swap to "use" mangles them.
        s = regexReplace(s, #"\bcircle back\b"#, "follow up")
        s = regexReplace(s, #"\btouch base\b"#, "check in")
        s = regexReplace(s, #"\breach out to\b"#, "contact")
        s = regexReplace(s, #"\breach out\b"#, "get in touch")
        s = regexReplace(s, #"\bleveraging\b"#, "using")

        // Exclamation spam: collapse runs to one (a single ! for genuine warmth is fine).
        s = regexReplace(s, #"!{2,}"#, "!", caseInsensitive: false)

        return s
    }

    // MARK: - Whitespace cleanup (both modes, last)

    static func collapseWhitespace(_ input: String) -> String {
        var s = input
        s = regexReplace(s, #"\s+([,.!?;:])"#, "$1", caseInsensitive: false) // no space before punctuation
        s = regexReplace(s, #"[ \t]{2,}"#, " ", caseInsensitive: false)      // collapse horizontal runs
        s = regexReplace(s, #"[ \t]+\n"#, "\n", caseInsensitive: false)      // trailing spaces per line
        s = regexReplace(s, #"\n{3,}"#, "\n\n", caseInsensitive: false)      // max one blank line
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Regex helper

    private static func regexReplace(_ s: String, _ pattern: String, _ template: String, caseInsensitive: Bool = true) -> String {
        let opts: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
    }
}
