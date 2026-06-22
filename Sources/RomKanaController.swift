import Cocoa
import InputMethodKit
import KanaKanjiConverterModuleWithDefaultDictionary

// File logger to diagnose conversion (reading/candidates/commit). Gated by the
// `debugLog` config key; writes to /tmp/romkana_conv.log when enabled.
enum DebugLog {
    nonisolated(unsafe) static var enabled = true
    static func write(_ s: String) {
        guard enabled else { return }
        let line = s + "\n"
        let path = "/tmp/romkana_conv.log"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); fh.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

// The @objc name MUST match Info.plist InputMethodServerControllerClass
// ("RomKana.RomKanaController"), and the binary must be built with
// -module-name RomKana so the runtime class name resolves.
@objc(RomKanaController)
@MainActor
final class RomKanaController: IMKInputController {

    private enum Mode {
        case composing   // user is typing romaji
        case converting  // candidate window is up, choosing one
    }

    private var romajiBuffer = ""
    private var candidateList: [String] = []
    private var selectedCandidate: String?
    private var mode: Mode = .composing
    // Direct latin ("英数") input: typed keys are inserted verbatim, no kana
    // conversion. Toggled with the JIS 英数 / かな keys.
    private var directInput = false
    private let converter = RomajiConverter()
    // User-editable settings (config.json). Reloaded on each activation.
    private var config = Config.load()
    // Local kana-kanji conversion via azooKey + Zenzai (zenz neural model). Runs
    // in-process — no external service. SHARED across controller instances so the
    // zenz model (GGUF + Metal) loads only once, not per text field/session.
    @MainActor private static let shared = KanaKanjiConverter()
    private var kkConverter: KanaKanjiConverter { Self.shared }
    // Warm-up runs once globally to pay the model-load cost off the typing path.
    @MainActor private static var warmedUp = false
    // The Candidate objects behind candidateList, kept so the chosen one can be
    // fed back to azooKey's learning on commit. Cleared on reset.
    private var lastCandidates: [Candidate] = []
    // Set by the menu; the next conversion clears azooKey's learning memory once.
    private var pendingMemoryReset = false

    // Candidate window owned by THIS controller (Typut pattern) so IMK routes
    // candidates(_:) / candidateSelected(_:) callbacks back to us.
    private var candidatesWindow: IMKCandidates!

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        candidatesWindow = IMKCandidates(server: server,
                                         panelType: kIMKSingleColumnScrollingCandidatePanel)
    }

    // When the IME is selected, warm zenz once (load GGUF + Metal + first inference
    // graph) with a throwaway conversion, so the user's first real Shift+Space is
    // already fast (~60ms) instead of paying the ~1–2s model-load cost then.
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        config = Config.load()              // pick up config.json edits on re-select
        DebugLog.enabled = config.debugLog
        DebugLog.write("ACTIVATE")
        loadUserDictionary()  // every activation, so userdict.json edits take effect
        guard !Self.warmedUp else { return }
        Self.warmedUp = true
        let warmup = config.warmupReading
        Task { @MainActor in
            var c = ComposingText()
            c.insertAtCursorPosition(warmup, inputStyle: .direct)
            _ = Self.shared.requestCandidates(c, options: self.convertOptions())
        }
    }

    // MARK: - Input-method menu (from the menu-bar input-source icon)

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "RomKana")
        let reset = NSMenuItem(title: "学習をリセット",
                               action: #selector(menuResetLearning(_:)), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        let edit = NSMenuItem(title: "ユーザー辞書を編集…（再選択で反映）",
                              action: #selector(menuOpenUserDict(_:)), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
        let settings = NSMenuItem(title: "設定を編集…（再選択で反映）",
                                  action: #selector(menuOpenConfig(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        return menu
    }

    // Clear azooKey's learning memory. Applied on the next conversion via
    // ConvertRequestOptions.shouldResetMemory.
    @objc private func menuResetLearning(_ sender: Any?) {
        pendingMemoryReset = true
    }

    // Open the user dictionary JSON; loadUserDictionary() re-reads it on re-select.
    @objc private func menuOpenUserDict(_ sender: Any?) {
        NSWorkspace.shared.open(Config.userDictURL)
    }

    // Open config.json; Config.load() re-reads it on re-select.
    @objc private func menuOpenConfig(_ sender: Any?) {
        _ = Config.load()  // ensure the file exists before opening
        NSWorkspace.shared.open(Config.configURL)
    }

    // MARK: - Event entry point

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event, event.type == .keyDown,
              let client = sender as? IMKTextInput else { return false }

        // Input-mode toggle (JIS 英数 / かな keys).
        switch event.keyCode {
        case 102: // 英数 -> direct latin input
            flush(client); directInput = true; return true
        case 104: // かな -> kana input
            flush(client); directInput = false; return true
        default: break
        }

        if directInput { return handleDirect(event, client) }

        switch mode {
        case .composing:  return handleComposing(event, client)
        case .converting: return handleConverting(event, client)
        }
    }

    // Direct ("英数") mode: insert printable characters verbatim; let the app
    // handle navigation/delete/return so it behaves like a plain keyboard.
    private func handleDirect(_ event: NSEvent, _ client: IMKTextInput) -> Bool {
        if !event.modifierFlags.intersection([.command, .control]).isEmpty { return false }
        switch event.keyCode {
        case 36, 48, 51, 53, 76, 123, 124, 125, 126:
            return false // return/tab/delete/escape/arrows -> app
        default:
            guard let chars = event.characters, let sc = chars.unicodeScalars.first,
                  sc.value >= 0x20, sc.value <= 0x7E else { return false }
            client.insertText(chars, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            return true
        }
    }

    // Commit whatever is in progress (used before switching input mode).
    private func flush(_ client: IMKTextInput) {
        if mode == .converting {
            commit(currentSelection(), client)
        } else if !romajiBuffer.isEmpty {
            commit(composedReading(), client)
        }
    }

    // MARK: - Composing (typing romaji)

    private func handleComposing(_ event: NSEvent, _ client: IMKTextInput) -> Bool {
        switch event.keyCode {
        case 49: // Space inserts a literal space; Shift+Space converts (Sumibi-style)
            guard !romajiBuffer.isEmpty else { return false } // empty -> pass plain space
            if event.modifierFlags.contains(.shift) {
                startConversion(client)
            } else {
                romajiBuffer.append(" ")
                renderComposing(client)
            }
            return true
        case 36: // Return -> commit kana; Shift+Return -> commit raw romaji
            guard !romajiBuffer.isEmpty else { return false }
            if event.modifierFlags.contains(.shift) {
                commit(romajiBuffer, client)
            } else {
                commit(composedReading(), client)
            }
            return true
        case 51: // Backspace — delete one typed character (the romaji is shown as-is)
            guard !romajiBuffer.isEmpty else { return false }
            romajiBuffer.removeLast()
            if romajiBuffer.isEmpty { clearMarked(client) } else { renderComposing(client) }
            return true
        case 53: // Escape
            guard !romajiBuffer.isEmpty else { return false }
            reset(client)
            return true
        default:
            if let ch = asciiLetter(event) {
                romajiBuffer.append(ch)
                renderComposing(client)
                return true
            }
            // Symbols / digits: append to the buffer so they join the SAME
            // composition instead of cutting it off. e.g. "、" "。" "ー" or a
            // mid-sentence number stay part of the long reading.
            if let sym = composableSymbol(event) {
                romajiBuffer.append(sym)
                renderComposing(client)
                return true
            }
            // Truly non-composable key (arrows, function keys): flush and pass through.
            if !romajiBuffer.isEmpty { commit(composedReading(), client) }
            return false
        }
    }

    // MARK: - Converting (choosing a candidate via the candidate window)

    private func handleConverting(_ event: NSEvent, _ client: IMKTextInput) -> Bool {
        switch event.keyCode {
        case 36: // Return -> commit the highlighted candidate
            commit(currentSelection(), client)
            return true
        case 53, 51: // Escape / Backspace -> back to romaji editing
            hideCandidates()
            mode = .composing
            renderComposing(client)
            return true
        case 49, 48, 125: // Space / Tab / Down -> next candidate (Enter commits)
            moveSelection(.down)
            return true
        case 126: // Up -> previous candidate
            moveSelection(.up)
            return true
        default:
            if let ch = asciiLetter(event) {
                // Accept the highlighted candidate, then start a fresh composition.
                commit(currentSelection(), client)
                romajiBuffer.append(ch)
                renderComposing(client)
                return true
            }
            if let sym = composableSymbol(event) {
                commit(currentSelection(), client)
                romajiBuffer.append(sym)
                renderComposing(client)
                return true
            }
            commit(currentSelection(), client)
            return false
        }
    }

    private func currentSelection() -> String {
        selectedCandidate ?? candidateList.first ?? composedReading()
    }

    // The kana reading of the typed romaji. Spaces are Sumibi-style word
    // separators: each space-delimited chunk is converted independently (so a
    // trailing "n" resolves per word) and joined — the reading itself has no
    // spaces.
    private func composedReading() -> String {
        romajiBuffer.split(separator: " ", omittingEmptySubsequences: true)
            .map { converter.toKana(String($0), finalize: true) }
            .joined()
    }

    // MARK: - Conversion request (in-process azooKey + Zenzai)

    // Convert the typed romaji — turned into a kana reading — in-process via
    // azooKey's dictionary + Zenzai (the zenz neural model). requestCandidates is
    // synchronous and fast (~60ms), so we run it on the event and show the result.
    // The chosen candidate is fed back to learning on commit; azooKey tracks
    // sentence context internally via setCompletedData.
    private func startConversion(_ client: IMKTextInput) {
        let raw = romajiBuffer
        guard !raw.isEmpty else { return }
        mode = .converting

        // Sumibi-style: if spaces were typed, treat each space-delimited chunk as a
        // segment. The spaces ARE the user's segment boundaries, so we can offer
        // per-segment alternatives cleanly: candidate #0 is every chunk's best
        // joined; then for each chunk we emit one variant that swaps just that chunk
        // to an alternative (e.g. 制度が→精度が), keeping the rest. This lets the
        // user pick the right homophone for one word without clutter.
        if raw.contains(" ") {
            let chunks = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let perChunk = chunks.map { convertChunkCandidates($0) }   // [[String]] best-first
            let best = perChunk.map { $0.first ?? "" }
            var list = [best.joined()]
            for i in perChunk.indices {
                for alt in perChunk[i].dropFirst() {
                    var combo = best
                    combo[i] = alt
                    list.append(combo.joined())
                }
            }
            let kana = composedReading()
            if !list.contains(kana) { list.append(kana) }
            var seen = Set<String>()
            list = list.filter { seen.insert($0).inserted }
            lastCandidates = []  // joined result has no single Candidate to learn
            DebugLog.write("CONVERT(seg) raw=\(raw) -> \(list.prefix(4))")
            showCandidates(list, client)
            return
        }

        let reading = composedReading()
        DebugLog.write("CONVERT romaji=\(raw) -> reading=\(reading)")
        var composing = ComposingText()
        composing.insertAtCursorPosition(reading, inputStyle: .direct)
        let result = kkConverter.requestCandidates(composing, options: convertOptions())
        pendingMemoryReset = false

        // mainResults mixes whole-sentence conversions with shorter clause/prefix
        // fragments ("制度が", "精度", "セイド" …). Keep ONLY candidates that cover the
        // ENTIRE input, and drop the fragments — they are the "partial candidates"
        // that otherwise clutter the list. Sentence-level homophone alternatives
        // ("精度が…" vs "制度が…") are themselves full-coverage, so they survive.
        let inputCount = composing.input.count
        lastCandidates = result.mainResults
        var fullCands = result.mainResults.filter { $0.correspondingCount == inputCount }
        if fullCands.isEmpty { fullCands = result.mainResults }  // safety net
        var list = fullCands.map { $0.text }
        if list.isEmpty { list = [reading] }
        // Capitalized acronym typed without spaces (e.g. "API"): offer it verbatim
        // near the top so it isn't lost to lowercasing.
        if let v = latinVerbatim(raw), !list.contains(v) { list.insert(v, at: min(1, list.count)) }
        if !list.contains(reading) { list.append(reading) }
        var seen = Set<String>()
        list = list.filter { seen.insert($0).inserted }
        showCandidates(list, client)
    }

    // Convert one space-delimited chunk to its top whole-chunk candidates (best
    // first). English/acronyms stay verbatim. Only candidates covering the whole
    // chunk are kept, so we get e.g. ["制度が", "精度が"] not partial fragments.
    private func convertChunkCandidates(_ piece: String) -> [String] {
        let limit = config.chunkCandidateLimit
        if let v = latinVerbatim(piece) { return [v] }
        let kana = converter.toKana(piece, finalize: true)
        if kana.range(of: "[A-Za-z]", options: .regularExpression) != nil { return [piece] }
        var c = ComposingText()
        c.insertAtCursorPosition(kana, inputStyle: .direct)
        let inputCount = c.input.count
        let res = kkConverter.requestCandidates(c, options: convertOptions())
        var full = res.mainResults.filter { $0.correspondingCount == inputCount }.map { $0.text }
        if full.isEmpty { full = res.mainResults.map { $0.text } }
        if full.isEmpty { full = [kana] }
        var seen = Set<String>()
        full = full.filter { seen.insert($0).inserted }
        return Array(full.prefix(limit))
    }

    // English/acronym to keep verbatim: matches config.latinVerbatimPattern
    // (default: a capitalized latin word — AI, LLM, Tokyo).
    private func latinVerbatim(_ s: String) -> String? {
        s.range(of: config.latinVerbatimPattern, options: .regularExpression) != nil ? s : nil
    }

    // azooKey conversion options: bundled default dictionary + Zenzai (zenz GGUF
    // shipped inside the app) + built-in learning persisted under Application
    // Support. shouldResetMemory wipes the learning once when the menu requests it.
    private func convertOptions() -> ConvertRequestOptions {
        // Resources are shipped as plain folders inside the .app (codesign-clean),
        // referenced explicitly rather than via SwiftPM's Bundle.module (whose
        // accessor only looks beside the executable / .build path).
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let dictionary = resources.appendingPathComponent(config.dictionaryFolder, isDirectory: true)
        let support = Config.supportDir
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let zenzai: ConvertRequestOptions.ZenzaiMode
        let weight = resources.appendingPathComponent(config.modelFile)
        if FileManager.default.fileExists(atPath: weight.path) {
            zenzai = .on(weight: weight, inferenceLimit: config.inferenceLimit, personalizationMode: nil)
        } else {
            zenzai = .off
        }
        return ConvertRequestOptions(
            N_best: config.nBest,
            requireJapanesePrediction: false,
            requireEnglishPrediction: false,
            keyboardLanguage: .ja_JP,
            learningType: config.learning ? .inputAndOutput : .nothing,
            shouldResetMemory: pendingMemoryReset,
            dictionaryResourceURL: dictionary,
            memoryDirectoryURL: support,
            sharedContainerURL: support,
            zenzaiMode: zenzai,
            metadata: .init(versionString: "RomKana")
        )
    }

    // Load the hand-edited user dictionary (reading→surfaces JSON) into azooKey's
    // dynamic user dict, so registered words (AI, OK, おねしゃす, 社内語…) appear as
    // candidates. Runs on each activation so edits take effect when you re-select
    // the IME. importDynamicUserDict replaces the whole set in one call.
    private func loadUserDictionary() {
        let url = Config.userDictURL
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
        else { DebugLog.write("USERDICT not loaded (file/parse failed) path=\(url.path)"); return }
        var elements: [DicdataElement] = []
        for (reading, surfaces) in dict {
            // ruby must be katakana; convert the hiragana reading (ー and others pass through).
            let ruby = String(reading.unicodeScalars.map {
                (0x3041...0x3096).contains($0.value)
                    ? Character(UnicodeScalar($0.value + 0x60)!) : Character($0)
            })
            for surface in surfaces where !surface.isEmpty {
                elements.append(DicdataElement(
                    word: surface, ruby: ruby,
                    cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid,
                    value: PValue(config.userDictWeight)))
            }
        }
        kkConverter.sendToDicdataStore(.importDynamicUserDict(elements))
        DebugLog.write("USERDICT loaded \(elements.count) entries (e.g. \(elements.last.map { "\($0.ruby)->\($0.word)" } ?? "none"))")
    }

    // Install a finished candidate list: select the top, mirror it inline, and
    // raise the popup. The order is already final, so this runs once per Space.
    private func showCandidates(_ list: [String], _ client: IMKTextInput) {
        candidateList = list
        selectedCandidate = list.first
        DebugLog.write("CANDIDATES " + list.prefix(8).enumerated()
            .map { "[\($0.0)]\($0.1)" }.joined(separator: " "))
        if let top = list.first { setMarked(top, client) }
        presentCandidates()
    }

    // MARK: - Candidate window

    private func presentCandidates() {
        guard let window = candidatesWindow else { return }
        window.update()
        // Position relative to the text cursor (no-arg show() can land offscreen).
        window.show(kIMKLocateCandidatesBelowHint)
        DebugLog.write("PRESENT visible=\(window.isVisible()) frame=\(window.candidateFrame())")
    }

    private func hideCandidates() {
        candidatesWindow?.hide()
    }

    private enum Move { case up, down }

    // Drive the candidate window's selection by feeding it an arrow-key event.
    // (Space is mapped to "next" by synthesizing a Down arrow.)
    private func moveSelection(_ dir: Move) {
        guard let window = candidatesWindow, !candidateList.isEmpty else { return }
        let count = candidateList.count
        let cur = selectedCandidate.flatMap { candidateList.firstIndex(of: $0) } ?? 0
        // IMKCandidates does not wrap on its own, so at an edge we send the
        // opposite arrow (count-1) times to roll around to the other end.
        if dir == .down && cur == count - 1 {
            for _ in 0..<(count - 1) { sendArrow(.up, to: window) }
        } else if dir == .up && cur == 0 {
            for _ in 0..<(count - 1) { sendArrow(.down, to: window) }
        } else {
            sendArrow(dir, to: window)
        }
        DebugLog.write("moveSelection \(dir) cur=\(cur) -> selected=\(selectedCandidate ?? "nil")")
    }

    // Feed the candidate window a real arrow-key event. interpretKeyEvents only
    // maps to moveDown:/moveUp: when the event carries the proper arrow
    // function-key character + .function/.numericPad flags.
    private func sendArrow(_ dir: Move, to window: IMKCandidates) {
        let fnKey = (dir == .down) ? NSDownArrowFunctionKey : NSUpArrowFunctionKey
        let chars = String(UnicodeScalar(fnKey)!)
        let keyCode: UInt16 = (dir == .down) ? 125 : 126
        if let arrow = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
            timestamp: 0, windowNumber: 0, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode) {
            window.interpretKeyEvents([arrow])
        }
    }

    // IMK queries this to populate the candidate window.
    override func candidates(_ sender: Any!) -> [Any]! {
        DebugLog.write("candidates() queried -> \(candidateList.count) items")
        return candidateList
    }

    // User pressed Enter / clicked a row inside the candidate window.
    override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard let client = self.client() as? IMKTextInput else { return }
        commit(candidateString.string, client)
    }

    // Highlight moved within the candidate window: mirror it inline.
    override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {
        DebugLog.write("selectionChanged -> \(candidateString.string)")
        selectedCandidate = candidateString.string
        if let client = self.client() as? IMKTextInput {
            setMarked(candidateString.string, client)
        }
    }

    // MARK: - Rendering / commit helpers

    // Show the raw romaji exactly as typed (Sumibi-style): the composing region
    // stays latin until Space converts it. (Kana/kanji appear only on convert.)
    private func renderComposing(_ client: IMKTextInput) {
        setMarked(romajiBuffer, client)
    }

    private func setMarked(_ text: String, _ client: IMKTextInput) {
        let attr = NSAttributedString(
            string: text,
            attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue])
        client.setMarkedText(attr,
                             selectionRange: NSRange(location: text.count, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }

    private func clearMarked(_ client: IMKTextInput) {
        client.setMarkedText("",
                             selectionRange: NSRange(location: 0, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }

    private func commit(_ text: String, _ client: IMKTextInput) {
        hideCandidates()
        client.insertText(text,
                          replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        // Feed the chosen candidate back to azooKey's learning memory and its
        // sentence-context cache. Only fires when committing a real candidate
        // (plain-kana commits aren't in lastCandidates).
        if let cand = lastCandidates.first(where: { $0.text == text }) {
            kkConverter.updateLearningData(cand)
            kkConverter.setCompletedData(cand)
        }
        reset(client)
    }

    private func reset(_ client: IMKTextInput) {
        romajiBuffer = ""
        candidateList = []
        selectedCandidate = nil
        lastCandidates = []
        mode = .composing
        hideCandidates()
        clearMarked(client)
    }

    // IMK calls this when focus changes etc. — flush whatever is composing.
    override func commitComposition(_ sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        if mode == .converting {
            commit(currentSelection(), client)
        } else if !romajiBuffer.isEmpty {
            commit(composedReading(), client)
        }
    }

    private func asciiLetter(_ event: NSEvent) -> String? {
        guard let chars = event.characters, chars.count == 1,
              let scalar = chars.unicodeScalars.first,
              scalar.isASCII,
              CharacterSet.lowercaseLetters.contains(scalar)
                || CharacterSet.uppercaseLetters.contains(scalar) else { return nil }
        // Ignore when Command/Control are held (shortcuts).
        if event.modifierFlags.intersection([.command, .control]).isEmpty == false { return nil }
        // Preserve case in the buffer (toKana lowercases internally) so typed
        // English like "LLM" can be offered verbatim as a candidate.
        return chars
    }

    // Printable ASCII symbols/digits (not letters) that should JOIN the current
    // composition rather than terminate it. Letters are handled by asciiLetter;
    // space/return/delete/escape are caught earlier by keyCode. Command/Control
    // chords are excluded so shortcuts still pass through.
    private func composableSymbol(_ event: NSEvent) -> String? {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty,
              let chars = event.characters, chars.count == 1,
              let scalar = chars.unicodeScalars.first,
              scalar.isASCII, scalar.value >= 0x21, scalar.value <= 0x7E else { return nil }
        return chars
    }
}
