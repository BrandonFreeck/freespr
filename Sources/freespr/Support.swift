import Foundation

/// Shared error type. `description` is what the user sees on stderr / in `status`.
enum FreesprError: Error, CustomStringConvertible {
    case missingAPIKey
    case keychain(OSStatus)
    case http(Int, String)        // status code, server message
    case decode(String)
    case audio(String)
    case other(String)

    var description: String {
        switch self {
        case .missingAPIKey:
            return "No OpenAI API key found. Run `freespr init` (or set OPENAI_API_KEY for dev)."
        case .keychain(let status):
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain error \(status): \(msg)"
        case .http(let code, let body):
            return "HTTP \(code): \(body)"
        case .decode(let what):
            return "Could not parse response: \(what)"
        case .audio(let what):
            return "Audio error: \(what)"
        case .other(let what):
            return what
        }
    }
}

/// Lines of a user-edited text file (vocab.txt, config.toml), split on exactly LF and CRLF.
/// Swift treats "\r\n" as ONE Character, so `split(separator: "\n")` never splits a file saved
/// with Windows line endings. A lone CR, form feed or U+2028 stays inside its line on purpose.
func textLines(_ text: String) -> [Substring] {
    text.split(omittingEmptySubsequences: true) { $0 == "\n" || $0 == "\r\n" }
}

/// Timestamped log to stderr. The LaunchAgent redirects stderr to ~/Library/Logs/freespr.log.
private let logFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")   // else a 12-hour system pref overrides HH and breaks parsing
    f.dateFormat = "MM-dd HH:mm:ss"   // day included: the log rolls across midnights
    return f
}()

func log(_ message: String) {
    FileHandle.standardError.write(Data("[\(logFmt.string(from: Date()))] \(message)\n".utf8))
}
