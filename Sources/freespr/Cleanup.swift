import Foundation

/// Second-pass cleanup via the cleanup model (gpt-6-luna by default): turns a dictated monologue
/// into paste-ready text using style.md as the developer prompt. On ANY failure it returns the
/// raw transcript unchanged — never drop the user's words. ToneStrip runs after this either way.
struct Cleanup {
    let keyProvider: APIKeyProvider
    let model: String
    /// cleanup_effort from config.toml. A non-reasoning cleanup_model rejects reasoning_effort
    /// with a 400, and the dictation falls back to the raw transcript (logged).
    let effort: String

    /// Dedicated session: an xhigh reasoning pass on a long dictation can exceed the shared
    /// OpenAI.session 90s resource ceiling. 300s ceiling here; raw-transcript fallback is the
    /// safety net if even that blows.
    static let session = OpenAI.makeSession(request: 300, resource: 300)

    /// Chat Completions payload — static so the self-check can assert on the request shape.
    static func payload(model: String, effort: String, transcript: String) -> [String: Any] {
        [
            "model": model,
            "reasoning_effort": effort,
            "messages": [
                ["role": "developer", "content": systemPrompt()],
                ["role": "user", "content": transcript],
            ],
        ]
    }

    /// Calls back with the cleaned text, or nil when cleanup failed (the caller then delivers the
    /// raw transcript). Every failure logs one "cleanup failed" line saying why.
    func clean(_ transcript: String, completion: @escaping (String?) -> Void) {
        func fail(_ why: String) { log("cleanup failed: \(why) — using raw transcript"); completion(nil) }
        let key: String
        do { key = try keyProvider.openAIKey() } catch { fail("no API key (\(error))"); return }

        let payload = Self.payload(model: model, effort: effort, transcript: transcript)
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            fail("could not encode the request"); return
        }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        Self.session.dataTask(with: req) { data, resp, err in
            if let err { fail(err.localizedDescription); return }
            guard let http = resp as? HTTPURLResponse, let data else { fail("no response"); return }
            guard (200..<300).contains(http.statusCode) else {
                fail("HTTP \(http.statusCode): \(OpenAI.errorMessage(data))"); return
            }
            struct R: Decodable {
                struct Choice: Decodable { struct Msg: Decodable { let content: String }; let message: Msg }
                let choices: [Choice]
            }
            guard let r = try? JSONDecoder().decode(R.self, from: data), let first = r.choices.first else {
                fail("unreadable response"); return
            }
            let text = first.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { fail("empty response") } else { completion(text) }
        }.resume()
    }

    /// style.md (user-editable; its "Hard rules" section carries the tone rules). Falls back to a
    /// minimal prompt if style.md is missing.
    static func systemPrompt() -> String {
        if let url = ResourcePaths.resource("style.md"),
           let style = try? String(contentsOf: url, encoding: .utf8) {
            return style
        }
        return "Clean up this dictated text into paste-ready text. Output only the cleaned text."
    }
}
