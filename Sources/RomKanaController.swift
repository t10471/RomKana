import Cocoa
import InputMethodKit

// Temporary file logger to diagnose conversion (reading/candidates/commit).
// Writes to /tmp/romkana_conv.log. Remove once conversion UX is verified.
enum DebugLog {
    static func write(_ s: String) {
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
    // Recently committed text, sent as context so the LLM reranker can pick the
    // contextually-natural reading (e.g. 雨/飴). Kept to the last ~24 chars.
    private var recentContext = ""
    // The kana reading of the conversion currently on screen. Set when Space
    // starts a conversion, used at commit time to teach the service which surface
    // the user chose for this reading (adaptive learning), then cleared on reset.
    private var currentReading = ""

    private let converter = RomajiConverter()
    private let conv = ConversionClient()

    // Candidate window owned by THIS controller (Typut pattern) so IMK routes
    // candidates(_:) / candidateSelected(_:) callbacks back to us.
    private var candidatesWindow: IMKCandidates!

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        candidatesWindow = IMKCandidates(server: server,
                                         panelType: kIMKSingleColumnScrollingCandidatePanel)
    }

    // MARK: - Input-method menu (from the menu-bar input-source icon)

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "RomKana")
        let view = NSMenuItem(title: "学習内容を確認",
                              action: #selector(menuViewLearning(_:)), keyEquivalent: "")
        view.target = self
        menu.addItem(view)
        let reset = NSMenuItem(title: "学習をリセット",
                               action: #selector(menuResetLearning(_:)), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        let edit = NSMenuItem(title: "ユーザー辞書を編集…",
                              action: #selector(menuOpenUserDict(_:)), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
        return menu
    }

    // Fetch the learned data, format it readably, and open it in the editor.
    @objc private func menuViewLearning(_ sender: Any?) {
        guard let url = URL(string: "http://127.0.0.1:8765/learned") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            var text = "RomKana 学習内容（読み → 表記:回数）\n\n"
            if let data = data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let learned = obj["learned"] as? [String: Any] {
                if learned.isEmpty {
                    text += "（まだ学習データはありません）\n"
                }
                for key in learned.keys.sorted() {
                    guard let counts = learned[key] as? [String: Any] else { continue }
                    // Keys are "<context-bucket>\t<reading>"; show the bucket if any.
                    let parts = key.components(separatedBy: "\t")
                    let reading = parts.last ?? key
                    let bucket = parts.count > 1 ? parts[0] : ""
                    let label = bucket.isEmpty ? reading : "\(reading)〔前:\(bucket)〕"
                    let pairs = counts.compactMap { (s, v) -> (String, Int)? in
                        guard let n = (v as? Int) ?? (v as? NSNumber)?.intValue else { return nil }
                        return (s, n)
                    }.sorted { $0.1 > $1.1 }
                    let line = pairs.map { "\($0.0):\($0.1)" }.joined(separator: "  ")
                    text += "\(label)  →  \(line)\n"
                }
            } else {
                text += "（取得に失敗しました。変換サービスが動いているか確認してください）\n"
            }
            let path = "/tmp/romkana_learned.txt"
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }.resume()
    }

    // Clear all adaptive learning via the service (fire-and-forget).
    @objc private func menuResetLearning(_ sender: Any?) {
        guard let url = URL(string: "http://127.0.0.1:8765/reset_learn") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)
        URLSession.shared.dataTask(with: req).resume()
    }

    // Open the user dictionary in the default editor (edits hot-reload).
    @objc private func menuOpenUserDict(_ sender: Any?) {
        let path = ("~/Library/Application Support/RomKana/userdict.json" as NSString)
            .expandingTildeInPath
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
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
        case 36: // Return -> commit the kana reading as-is
            guard !romajiBuffer.isEmpty else { return false }
            commit(composedReading(), client)
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

    // MARK: - Conversion request (bounded synchronous wait, no later reorder)

    // On Space we briefly wait for the LLM-reranked result, then show it — so the
    // top candidate is contextually ranked from the first frame and never jumps.
    // The dictionary (fast) and the LLM rerank (~0.1-0.2s) are fired together; if
    // the LLM answers within the deadline we use its order, otherwise we fall back
    // to the dictionary order that has already arrived. Whatever we show is final.
    private func startConversion(_ client: IMKTextInput) {
        // Spaces present → Sumibi-style segmented conversion (each space-delimited
        // chunk converted independently). Dictionary-only: with manual segmenting
        // the dict's top-1 is both faster and better than the LLM here.
        if romajiBuffer.contains(" ") {
            startSegmentedConversion(romajiBuffer, client)
            return
        }
        let reading = composedReading()
        let raw = romajiBuffer
        DebugLog.write("CONVERT romaji=\(raw) -> reading=\(reading)")
        mode = .converting
        currentReading = reading

        var dictResult: [String]?
        var llmResult: [String]?
        let dictSem = DispatchSemaphore(value: 0)
        let llmSem = DispatchSemaphore(value: 0)
        fetchAsync(reading: reading, context: recentContext, useLLM: false) {
            dictResult = $0; dictSem.signal()
        }
        fetchAsync(reading: reading, context: recentContext, useLLM: true) {
            llmResult = $0; llmSem.signal()
        }

        // Prefer the LLM order if it lands in time (no jump, LLM-quality #1);
        // otherwise show the dictionary order that is already in.
        let dict: [String]
        if llmSem.wait(timeout: .now() + .milliseconds(400)) == .success,
           let llm = llmResult, !llm.isEmpty {
            dict = llm
            DebugLog.write("CONVERT used=llm")
        } else {
            _ = dictSem.wait(timeout: .now() + .milliseconds(300))
            dict = dictResult ?? []
            DebugLog.write("CONVERT used=dict(fallback)")
        }
        showCandidates(buildCandidateList(dict: dict, reading: reading, raw: raw), client)
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

    // Convert space-separated input as independent chunks and concatenate the
    // result (Sumibi-style). Acronyms/English (romaji that doesn't form kana,
    // e.g. "llm") are kept verbatim; everything else is converted by reading.
    private func startSegmentedConversion(_ raw: String, _ client: IMKTextInput) {
        mode = .converting
        currentReading = ""  // the joined whole isn't a reusable reading — don't learn it
        var segs: [[String: String]] = []
        for piece in raw.split(separator: " ", omittingEmptySubsequences: true) {
            let p = String(piece)
            let kana = converter.toKana(p, finalize: true)
            // Keep verbatim when it's English/an acronym: either capitalized
            // (deliberate, e.g. "AI", "Tokyo") or un-convertible latin (e.g. "llm").
            let capitalized = p.range(of: "^[A-Z][A-Za-z]*$", options: .regularExpression) != nil
            if capitalized || kana.range(of: "[A-Za-z]", options: .regularExpression) != nil {
                segs.append(["t": p])
            } else {
                segs.append(["r": kana])    // convert this reading
            }
        }
        DebugLog.write("CONVERT segmented n=\(segs.count)")
        let list = fetchSegmented(segments: segs, context: recentContext)
        showCandidates(list.isEmpty ? [composedReading()] : list, client)
    }

    // Blocking call to the segmented endpoint (dictionary-only, ~30ms).
    private func fetchSegmented(segments: [[String: String]], context: String) -> [String] {
        guard let url = URL(string: "http://127.0.0.1:8765/convert") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 6
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "segments": segments, "context": context, "n_best": 6, "use_llm": false,
        ])
        var out: [String] = []
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            if let data = data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cands = obj["candidates"] as? [String] {
                out = cands
            }
        }.resume()
        _ = sem.wait(timeout: .now() + 2)
        return out
    }

    // Turn the service's dictionary candidates into the final popup list: always
    // offer the raw kana reading, fold in typed latin (for English words), and
    // dedupe preserving order. Used for BOTH the instant dictionary result and
    // the later reranked result so the two lists are structurally identical and
    // only their order differs.
    private func buildCandidateList(dict: [String], reading: String, raw: String) -> [String] {
        var list = dict.isEmpty ? [reading] : dict
        if !list.contains(reading) { list.append(reading) } // always offer the raw reading
        // English mixed in: offer the typed latin as candidates. If the reading
        // still holds latin (un-convertible romaji like "llm"), surface them
        // first; otherwise keep kana primary (e.g. "namae").
        if raw.range(of: "^[A-Za-z]+$", options: .regularExpression) != nil {
            var latin: [String] = []
            for v in [raw, raw.uppercased(), raw.capitalized, raw.lowercased()]
                where !latin.contains(v) { latin.append(v) }
            let readingHasLatin = reading.range(of: "[A-Za-z]", options: .regularExpression) != nil
            list = readingHasLatin ? latin + list : list + latin
        }
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    // Non-blocking call to the conversion service; `done` runs on a background
    // queue with the candidate list (empty array on any failure). Callers wait on
    // a semaphore with a deadline, so a slow/dead service can't hang the IME.
    private func fetchAsync(reading: String, context: String, useLLM: Bool,
                            done: @escaping ([String]) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:8765/convert") else { done([]); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 6
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "reading": reading, "context": context, "n_best": 8, "use_llm": useLLM,
        ])
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data = data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cands = obj["candidates"] as? [String] {
                done(cands)
            } else {
                done([])
            }
        }.resume()
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
        DebugLog.write("COMMIT '\(text)' selected=\(selectedCandidate ?? "nil")")
        hideCandidates()
        client.insertText(text,
                          replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        let priorContext = recentContext  // text that preceded this conversion
        // Remember it as context for the next conversion's LLM rerank.
        recentContext = String((recentContext + text).suffix(24))
        // Teach the service which surface was chosen for this reading IN THIS
        // context, so a repeated context→choice habit replays next time.
        if !currentReading.isEmpty {
            learn(reading: currentReading, surface: text, context: priorContext)
        }
        reset(client)
    }

    private func reset(_ client: IMKTextInput) {
        romajiBuffer = ""
        candidateList = []
        selectedCandidate = nil
        currentReading = ""
        mode = .composing
        hideCandidates()
        clearMarked(client)
    }

    // Fire-and-forget: tell the service the user committed `surface` for
    // `reading`. The service records the choice and promotes it in future
    // conversions (adaptive learning).
    private func learn(reading: String, surface: String, context: String) {
        guard reading != surface, !surface.isEmpty,
              let url = URL(string: "http://127.0.0.1:8765/learn") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "reading": reading, "surface": surface, "context": context,
        ])
        URLSession.shared.dataTask(with: req).resume()
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
