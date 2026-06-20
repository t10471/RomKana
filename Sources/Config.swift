import Foundation

// User-editable settings, loaded from ~/Library/Application Support/RomKana/config.json.
// Every field has a built-in default, and a missing file or missing key just falls
// back to that default — so the app always runs, and the JSON can override only the
// keys you care about. Edits take effect when you re-select the IME (loaded on each
// activation, alongside userdict.json).
struct Config {
    var nBest = 9                                    // azooKey N-best breadth
    var inferenceLimit = 10                          // Zenzai per-convert inference cap
    var chunkCandidateLimit = 4                      // alternatives kept per space-chunk
    var learning = true                              // azooKey built-in learning on/off
    var userDictWeight = -10                         // value for userdict entries (lower = stronger)
    var modelFile = "ggml-model-Q5_K_M.gguf"         // zenz GGUF inside the .app Resources
    var dictionaryFolder = "Dictionary"              // azooKey dictionary folder inside Resources
    var warmupReading = "てすと"                      // throwaway reading converted on activate
    var latinVerbatimPattern = "^[A-Z][A-Za-z0-9]*$" // capitalized latin kept verbatim (AI, LLM)
    var debugLog = true                              // write /tmp/romkana_conv.log

    // All RomKana state lives in one Application Support folder.
    static let supportDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("RomKana", isDirectory: true)
    static var configURL: URL { supportDir.appendingPathComponent("config.json") }
    static var userDictURL: URL { supportDir.appendingPathComponent("userdict.json") }

    // Load config.json over the defaults. Reads key-by-key so a partial file (only
    // a few overrides) works. Writes a fully-populated default file on first run so
    // every editable key is discoverable.
    static func load() -> Config {
        try? FileManager.default.createDirectory(
            at: supportDir, withIntermediateDirectories: true)
        var cfg = Config()
        guard let data = try? Data(contentsOf: configURL),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            cfg.writeDefault()  // no file yet → drop a documented default
            return cfg
        }
        if let v = o["nBest"] as? Int { cfg.nBest = v }
        if let v = o["inferenceLimit"] as? Int { cfg.inferenceLimit = v }
        if let v = o["chunkCandidateLimit"] as? Int { cfg.chunkCandidateLimit = v }
        if let v = o["learning"] as? Bool { cfg.learning = v }
        if let v = o["userDictWeight"] as? Int { cfg.userDictWeight = v }
        if let v = o["modelFile"] as? String { cfg.modelFile = v }
        if let v = o["dictionaryFolder"] as? String { cfg.dictionaryFolder = v }
        if let v = o["warmupReading"] as? String { cfg.warmupReading = v }
        if let v = o["latinVerbatimPattern"] as? String { cfg.latinVerbatimPattern = v }
        if let v = o["debugLog"] as? Bool { cfg.debugLog = v }
        return cfg
    }

    // Serialize current values to config.json (used to seed the default file).
    func writeDefault() {
        let dict: [String: Any] = [
            "nBest": nBest,
            "inferenceLimit": inferenceLimit,
            "chunkCandidateLimit": chunkCandidateLimit,
            "learning": learning,
            "userDictWeight": userDictWeight,
            "modelFile": modelFile,
            "dictionaryFolder": dictionaryFolder,
            "warmupReading": warmupReading,
            "latinVerbatimPattern": latinVerbatimPattern,
            "debugLog": debugLog,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: Config.configURL)
    }
}
