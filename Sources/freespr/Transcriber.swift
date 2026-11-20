import Foundation

/// Speech-to-text via OpenAI gpt-transcribe. Hand-built multipart/form-data upload (no
/// third-party). The vocab prompt biases jargon/spelling — the whole reason to build vs. buy.
struct Transcriber {
    let keyProvider: APIKeyProvider
    let model: String
    let vocabPrompt: String

    func transcribe(wav: URL, completion: @escaping (Result<String, Error>) -> Void) {
        let key: String
        do { key = try keyProvider.openAIKey() } catch { completion(.failure(error)); return }
        guard let audio = try? Data(contentsOf: wav) else {
            completion(.failure(FreesprError.audio("cannot read WAV at \(wav.path)"))); return
        }

        let boundary = "freespr-\(UUID().uuidString)"
        var body = Data()
        func line(_ s: String) { body.append(Data(s.utf8)) }
        func field(_ name: String, _ value: String) {
            line("--\(boundary)\r\n")
            line("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            line("\(value)\r\n")
        }
        // File part
        line("--\(boundary)\r\n")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        line("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        line("\r\n")
        // Text fields
        field("model", model)
        field("response_format", "json")
        if !vocabPrompt.isEmpty { field("prompt", vocabPrompt) }
        line("--\(boundary)--\r\n")

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        OpenAI.session.uploadTask(with: req, from: body) { data, resp, err in
            if let err { completion(.failure(err)); return }
            guard let http = resp as? HTTPURLResponse, let data else {
                completion(.failure(FreesprError.other("no response from transcription"))); return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(FreesprError.http(http.statusCode, OpenAI.errorMessage(data)))); return
            }
            struct R: Decodable { let text: String }
            if let r = try? JSONDecoder().decode(R.self, from: data) {
                completion(.success(r.text.trimmingCharacters(in: .whitespacesAndNewlines)))
            } else {
                completion(.failure(FreesprError.decode("transcription response")))
            }
        }.resume()
    }
}

/// Shared OpenAI helpers.
enum OpenAI {
    /// Shared transcription session with BOUNDED timeouts. URLSession's default
    /// `timeoutIntervalForResource` is 7 days, so a stalled OpenAI connection would hang the agent
    /// in "transcribing" with the hotkey dead indefinitely. 30s request idle / 90s total ceiling.
    /// (Cleanup has its own wider session — see Cleanup.session.)
    static let session = makeSession(request: 30, resource: 90)

    /// One factory so transport policy never drifts between the transcribe and cleanup sessions.
    static func makeSession(request: TimeInterval, resource: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = request
        cfg.timeoutIntervalForResource = resource
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }

    /// OpenAI's error message for the log: anything shaped like an API key masked, at most 300 chars.
    static func errorMessage(_ data: Data) -> String {
        struct E: Decodable { struct Inner: Decodable { let message: String }; let error: Inner }
        let text = (try? JSONDecoder().decode(E.self, from: data))?.error.message
            ?? String(data: data, encoding: .utf8) ?? "unknown error"
        let masked = text.replacingOccurrences(of: #"sk-[A-Za-z0-9_*\-]+"#, with: "sk-…", options: .regularExpression)
        return masked.count > 300 ? String(masked.prefix(300)) + "…" : masked
    }
}
