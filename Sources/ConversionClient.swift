import Foundation

// Talks to the local RomKana conversion service (mozcpy + optional LLM rescore).
// Async + cancelable: a newer request supersedes an older in-flight one so a
// stale response can't overwrite fresh candidates.
actor ConversionClient {
    private let endpoint = URL(string: "http://127.0.0.1:8765/convert")!
    private var inFlight: Task<[String], Error>?

    // reading: the hiragana produced locally from the romaji buffer.
    // Returns ordered candidate strings (kanji-kana), best first.
    func convert(reading: String, context: String = "") async throws -> [String] {
        inFlight?.cancel()
        let task = Task { () throws -> [String] in
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 5
            let body: [String: Any] = [
                "reading": reading,
                "context": context,
                "n_best": 8,
                "use_llm": false,   // dictionary ranking wins for short phrases (Phase 0)
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: req)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cands = obj["candidates"] as? [String] else {
                return []
            }
            return cands
        }
        inFlight = task
        return try await task.value
    }
}
