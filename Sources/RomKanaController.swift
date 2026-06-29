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
        case converting  // candidate window is up, choosing one (single flat list)
        case bunsetsu    // 文節変換: 文を文節に分け、文節ごとに選び直す
    }

    // One 文節 in 文節変換: its kana reading, the candidates for that reading
    // (best-first), and which one is selected. The surface is the chosen text.
    private struct Clause {
        var reading: String          // この文節のかな（境界の真実はこの長さ）
        var candidates: [Candidate]  // best-first。初期は firstClause の暫定1件
        var selected: Int
        var expanded = false         // Space で全候補を取得済みか（遅延取得）
        var surface: String {
            candidates.indices.contains(selected) ? candidates[selected].text : reading
        }
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

    // 文節変換 state (mode == .bunsetsu). `clauses` joined by reading equals the
    // whole sentence reading; each clause length is its boundary. `focusedClause`
    // is the one ←/→ moves over and Space/Option+arrows act on. `clauseWindowUp`
    // tracks whether the candidate window currently shows the focused clause.
    private var clauses: [Clause] = []
    private var focusedClause = 0
    private var clauseWindowUp = false

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
        case .bunsetsu:   return handleBunsetsu(event, client)
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
        if mode == .bunsetsu {
            commitClauses(client)
        } else if mode == .converting {
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

    // MARK: - 文節変換 key handling

    // The sentence is split into 文節, the focused one highlighted. ←/→ move the
    // focus; Space shows that clause's candidates; Option+←/→ resize its boundary;
    // Enter commits the whole sentence; Esc/Backspace return to romaji editing.
    private func handleBunsetsu(_ event: NSEvent, _ client: IMKTextInput) -> Bool {
        // Boundary resize is on Option+←/→, NOT Shift+←/→: converting with
        // Shift+Space tends to leave Shift held when the user then presses an arrow,
        // which would fire a resize instead of moving focus. So ←/→ always move the
        // focus regardless of Shift; Option+←/→ resizes the focused 文節.
        let resize = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case 124: // → : Option で境界を右へ伸ばす / それ以外はフォーカスを右へ
            if resize { growFocused(client) } else { moveFocus(1, client) }
            return true
        case 123: // ← : Option で境界を左へ縮める / それ以外はフォーカスを左へ
            if resize { shrinkFocused(client) } else { moveFocus(-1, client) }
            return true
        case 49: // Space : フォーカス文節の候補ウィンドウを出す / 出ていれば次候補
            if clauseWindowUp {
                moveSelection(.down)
            } else {
                expandFocusedCandidates()
                presentClauseCandidates(client)
            }
            return true
        case 125: // ↓ : 候補ウィンドウ表示中のみ次候補
            if clauseWindowUp { moveSelection(.down) }
            return true
        case 126: // ↑ : 候補ウィンドウ表示中のみ前候補
            if clauseWindowUp { moveSelection(.up) }
            return true
        case 36: // Return : ウィンドウ表示中は選択確定して文節モード継続 / なければ全文確定
            if clauseWindowUp {
                hideCandidates(); clauseWindowUp = false
                renderBunsetsu(client)
            } else {
                commitClauses(client)
            }
            return true
        case 53: // Escape : ウィンドウ→文節→ローマ字、と段階的に戻す
            if clauseWindowUp {
                hideCandidates(); clauseWindowUp = false
                renderBunsetsu(client)
            } else {
                hideCandidates()
                clauses = []; focusedClause = 0
                mode = .composing
                renderComposing(client)  // romajiBuffer is preserved → original romaji
            }
            return true
        case 51: // Backspace : 文節モードを抜けてローマ字編集へ戻す
            hideCandidates()
            clauses = []; focusedClause = 0; clauseWindowUp = false
            mode = .composing
            renderComposing(client)
            return true
        default:
            // Letters/symbols: commit the sentence, then start a fresh composition.
            if let ch = asciiLetter(event) {
                commitClauses(client)
                romajiBuffer.append(ch)
                renderComposing(client)
                return true
            }
            if let sym = composableSymbol(event) {
                commitClauses(client)
                romajiBuffer.append(sym)
                renderComposing(client)
                return true
            }
            commitClauses(client)
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

        // 文節変換: split the reading into 文節 and let the user move across them
        // (←/→), pick per-clause candidates (Space), resize boundaries (Option+←/→),
        // and commit the whole sentence (Enter). Skipped for capitalized-acronym
        // input (kept verbatim by the flat-list path below).
        if config.clauseConversion, latinVerbatim(raw) == nil {
            let cs = splitIntoClauses(reading)
            if !cs.isEmpty {
                clauses = cs
                focusedClause = 0
                clauseWindowUp = false
                lastCandidates = []   // learning is driven per-clause on commit
                mode = .bunsetsu
                renderBunsetsu(client)
                return
            }
        }

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
        if let v = latinVerbatim(piece) { return [v] }
        let kana = converter.toKana(piece, finalize: true)
        if kana.range(of: "[A-Za-z]", options: .regularExpression) != nil { return [piece] }
        let cands = convertReadingCandidates(kana, limit: config.chunkCandidateLimit)
        return cands.isEmpty ? [kana] : cands.map { $0.text }
    }

    // Convert one kana reading to the candidates that cover the WHOLE reading
    // (best-first), keeping the Candidate objects so the chosen one can be fed to
    // azooKey learning on commit. Partial fragments are dropped; deduped by
    // surface text; capped at `limit`. Used by both the space-chunk path (via
    // convertChunkCandidates) and 文節変換 (per-clause candidates).
    private func convertReadingCandidates(_ kana: String, limit: Int, mergeNoZenzai: Bool = true) -> [Candidate] {
        guard !kana.isEmpty else { return [] }
        func fullCoverage(useZenzai: Bool) -> [Candidate] {
            var c = ComposingText()
            c.insertAtCursorPosition(kana, inputStyle: .direct)
            let inputCount = c.input.count
            let res = kkConverter.requestCandidates(c, options: convertOptions(useZenzai: useZenzai))
            let full = res.mainResults.filter { $0.correspondingCount == inputCount }
            return full.isEmpty ? res.mainResults : full
        }
        // Zenzai keeps only its favored surface at full coverage, dropping homophones
        // (e.g. for かえってきた it returns 帰ってきた but not 返ってきた). The plain
        // dictionary lattice still has them, so append the ones Zenzai dropped — this
        // is what lets the user reach 返って/返ってきた when fixing a clause.
        var ordered = fullCoverage(useZenzai: true)
        if mergeNoZenzai { ordered += fullCoverage(useZenzai: false) }
        var seen = Set<String>()
        let deduped = ordered.filter { seen.insert($0.text).inserted }
        return Array(deduped.prefix(limit))
    }

    // MARK: - 文節変換 (clause-by-clause conversion)

    // Split the whole-sentence reading into 文節 from the best whole-sentence
    // candidate's構成要素 (its DicdataElement list): each element covers ruby.count
    // input kana, so we slice the reading at those boundaries and seed each clause
    // with a Candidate built from that element (surface = its word, learnable).
    // We deliberately do NOT use firstClauseResults as the primary source — it can
    // collapse a whole sentence into a single clause (e.g. "今日は歯医者に行く").
    // Each clause's full candidate list is fetched lazily (Space → expandFocusedCandidates).
    private func splitIntoClauses(_ reading: String) -> [Clause] {
        var composing = ComposingText()
        composing.insertAtCursorPosition(reading, inputStyle: .direct)
        let res = kkConverter.requestCandidates(composing, options: convertOptions())
        pendingMemoryReset = false
        let chars = Array(reading)
        let total = chars.count
        let best = res.mainResults.first(where: { $0.correspondingCount == total })
                 ?? res.mainResults.first
        let data = best?.data ?? []

        // best.data usually gives clean, context-aware 文節 boundaries. But on some
        // inputs the lattice mis-merges across a 文節 boundary into one element that
        // starts mid-word (e.g. きいてかえって… → 聞い | て帰ってき | た | もの). Then a
        // homophone like 返って is unreachable, because かえって never appears as its own
        // clause. Detect that and re-segment greedily instead. Detection runs on the
        // deterministic Zenzai-off conversion (Zenzai's sampled best.data varies
        // run-to-run, which made this fire inconsistently); also re-segment if the
        // Zenzai best.data itself happens to look merged this run.
        var offComposing = ComposingText()
        offComposing.insertAtCursorPosition(reading, inputStyle: .direct)
        let offData = (kkConverter.requestCandidates(offComposing, options: convertOptions(useZenzai: false))
            .mainResults.first(where: { $0.correspondingCount == total }))?.data ?? []
        if data.isEmpty || dataLooksMerged(offData) || dataLooksMerged(data) {
            let segs = greedyClauseReadings(reading)
            if data.isEmpty || segs.count > 1 {
                let result = segs.map { r -> Clause in
                    Clause(reading: r, candidates: convertReadingCandidates(r, limit: 1, mergeNoZenzai: false), selected: 0)
                }
                DebugLog.write("SPLIT(greedy) \(reading) -> "
                    + result.map { "\($0.reading)=\($0.surface)" }.joined(separator: " / "))
                return result.isEmpty ? [Clause(reading: reading, candidates: [], selected: 0)] : result
            }
        }

        var result: [Clause] = []
        var pos = 0
        for elem in data {
            let len = elem.ruby.count
            guard len > 0, pos < total else { continue }
            let end = min(pos + len, total)
            let clauseReading = String(chars[pos..<end])
            let cand = Candidate(text: elem.word, value: 0, correspondingCount: end - pos,
                                 lastMid: elem.mid, data: [elem])
            result.append(Clause(reading: clauseReading, candidates: [cand], selected: 0))
            pos = end
        }
        if pos < total {  // leftover, or no candidate at all: remaining reading as one clause
            result.append(Clause(reading: String(chars[pos..<total]), candidates: [], selected: 0))
        }
        if result.isEmpty {
            result = [Clause(reading: reading, candidates: [], selected: 0)]
        }
        DebugLog.write("SPLIT \(reading) -> "
            + result.map { "\($0.reading)=\($0.surface)" }.joined(separator: " / ")
            + "  [data=" + (best?.data.map { "\($0.word):\($0.ruby)" }.joined(separator: ",") ?? "nil") + "]")
        return result
    }

    // A best.data element that starts with a 付属語/送り仮名 kana (て, の, を …) yet
    // contains a kanji means the lattice merged across a 文節 boundary (e.g.
    // て帰ってき) — the boundaries are wrong and homophones inside become unreachable.
    private func dataLooksMerged(_ data: [DicdataElement]) -> Bool {
        let leadKana: Set<Character> = [
            "て", "で", "っ", "ん", "ー", "ょ", "ゃ", "ゅ", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ",
            "を", "は", "が", "に", "の", "も", "と", "へ", "や",
        ]
        return data.contains { e in
            guard let first = e.word.first, leadKana.contains(first) else { return false }
            return e.word.range(of: "\\p{Han}", options: .regularExpression) != nil
        }
    }

    // Greedy 文節 segmentation of a reading using the dictionary lattice with Zenzai
    // off (we only need boundaries, and it is much faster + stable). Repeatedly take
    // the first 文節 (see firstClauseLen) off the front. A trailing 1-kana clause is
    // almost always a dangling 送り仮名, so merge it back into the previous clause.
    private func greedyClauseReadings(_ reading: String) -> [String] {
        var out: [String] = []
        var chars = Array(reading)
        var guardLoop = 0
        while !chars.isEmpty, guardLoop < 64 {
            guardLoop += 1
            let n = min(max(1, firstClauseLen(String(chars))), chars.count)
            out.append(String(chars[0..<n]))
            chars.removeFirst(n)
        }
        var merged: [String] = []
        for c in out {
            if c.count == 1, !merged.isEmpty { merged[merged.count - 1] += c }
            else { merged.append(c) }
        }
        return merged
    }

    // Number of maximal kanji (Han) runs in a surface. A single 文節 has exactly one
    // content word, so one kanji-run; a candidate spanning two 文節 (e.g. 聞いて帰って)
    // has two — we use that to avoid cutting across a 文節 boundary.
    private func kanjiRuns(_ s: String) -> Int {
        var runs = 0
        var inRun = false
        for ch in s {
            let isHan = String(ch).range(of: "\\p{Han}", options: .regularExpression) != nil
            if isHan, !inRun { runs += 1 }
            inRun = isHan
        }
        return runs
    }

    // First-文節 length of a reading: the LONGEST proper-prefix candidate whose surface
    // has exactly one kanji-run (= one content word + its 送り仮名/付属語). firstClause
    // and the whole-sentence best.data both mis-merge te-form chains (聞い|て帰ってき),
    // so this dictionary-only (Zenzai off, deterministic) scan is more reliable.
    private func firstClauseLen(_ rest: String) -> Int {
        let len = rest.count
        guard len > 1 else { return len }
        var c = ComposingText()
        c.insertAtCursorPosition(rest, inputStyle: .direct)
        let res = kkConverter.requestCandidates(c, options: convertOptions(useZenzai: false))
        var bestLen = 0
        for cand in res.mainResults
        where cand.correspondingCount > 0 && cand.correspondingCount < len {
            if kanjiRuns(cand.text) == 1, cand.correspondingCount > bestLen {
                bestLen = cand.correspondingCount
            }
        }
        return bestLen > 0 ? bestLen : len
    }

    // Lazily fetch the full candidate list for the focused clause (best-first),
    // keeping whatever surface is currently shown selected. Called before showing
    // the candidate window so Space reveals all alternatives for that clause.
    private func expandFocusedCandidates() {
        guard clauses.indices.contains(focusedClause) else { return }
        var clause = clauses[focusedClause]
        guard !clause.expanded else { return }
        let current = clause.surface
        var cands = convertReadingCandidates(clause.reading, limit: config.nBest)
        if !cands.isEmpty {
            if let idx = cands.firstIndex(where: { $0.text == current }) {
                clause.selected = idx
            } else if clause.candidates.indices.contains(clause.selected) {
                // The firstClause best wasn't in the whole-reading list — keep it.
                cands.insert(clause.candidates[clause.selected], at: 0)
                clause.selected = 0
            } else {
                clause.selected = 0
            }
            clause.candidates = cands
        }
        clause.expanded = true
        clauses[focusedClause] = clause
    }

    // Rebuild candidates for clause i after its reading changed (boundary resize).
    private func reconvertClause(_ i: Int) {
        guard clauses.indices.contains(i) else { return }
        let cands = convertReadingCandidates(clauses[i].reading, limit: config.nBest)
        clauses[i].candidates = cands
        clauses[i].selected = 0
        clauses[i].expanded = true
    }

    // ←/→ : move the focus across clauses, closing the candidate window first.
    private func moveFocus(_ delta: Int, _ client: IMKTextInput) {
        guard !clauses.isEmpty else { return }
        if clauseWindowUp { hideCandidates(); clauseWindowUp = false }
        focusedClause = max(0, min(clauses.count - 1, focusedClause + delta))
        renderBunsetsu(client)
    }

    // Option+→ : grow the focused clause by one kana, taken from the next clause.
    private func growFocused(_ client: IMKTextInput) {
        guard clauses.indices.contains(focusedClause) else { return }
        let next = focusedClause + 1
        guard clauses.indices.contains(next), !clauses[next].reading.isEmpty else { return }
        let ch = clauses[next].reading.removeFirst()
        clauses[focusedClause].reading.append(ch)
        if clauses[next].reading.isEmpty {
            clauses.remove(at: next)        // absorbed the whole next clause
        } else {
            reconvertClause(next)
        }
        reconvertClause(focusedClause)
        clampFocus()
        if clauseWindowUp { hideCandidates(); clauseWindowUp = false }
        renderBunsetsu(client)
    }

    // Option+← : shrink the focused clause by one kana, given to the next clause
    // (a new trailing clause is created if the focused one is last).
    private func shrinkFocused(_ client: IMKTextInput) {
        guard clauses.indices.contains(focusedClause),
              clauses[focusedClause].reading.count > 1 else { return }   // keep ≥1 kana
        let ch = clauses[focusedClause].reading.removeLast()
        let next = focusedClause + 1
        if clauses.indices.contains(next) {
            clauses[next].reading = String(ch) + clauses[next].reading
        } else {
            clauses.insert(Clause(reading: String(ch), candidates: [], selected: 0), at: next)
        }
        reconvertClause(next)
        reconvertClause(focusedClause)
        clampFocus()
        if clauseWindowUp { hideCandidates(); clauseWindowUp = false }
        renderBunsetsu(client)
    }

    private func clampFocus() {
        focusedClause = clauses.isEmpty ? 0 : max(0, min(clauses.count - 1, focusedClause))
    }

    // Markers wrapping the focused 文節 in the preedit so the selection is visible
    // even in terminals (WezTerm etc.) that ignore marked-text attributes. These
    // are display-only — commit uses the bare surfaces, no markers.
    private static let focusOpen = "《"
    private static let focusClose = "》"

    // Draw the whole sentence as marked text. The focused 文節 is wrapped in 《》 so
    // it's visible everywhere; additionally each clause is tagged with
    // .markedClauseSegment and the focused one gets a thick accent underline +
    // background, which GUI clients (NSTextView) render richly. Ranges are UTF-16.
    private func renderBunsetsu(_ client: IMKTextInput) {
        let display = NSMutableString()
        var focusRange = NSRange(location: 0, length: 0)
        var segRanges: [(Int, NSRange)] = []
        for (i, c) in clauses.enumerated() {
            let shown = i == focusedClause ? Self.focusOpen + c.surface + Self.focusClose : c.surface
            let start = display.length
            display.append(shown)
            let range = NSRange(location: start, length: (shown as NSString).length)
            segRanges.append((i, range))
            if i == focusedClause { focusRange = range }
        }
        let attr = NSMutableAttributedString(string: display as String)
        for (i, range) in segRanges where range.length > 0 {
            attr.addAttribute(.markedClauseSegment, value: i, range: range)
            if i == focusedClause {
                attr.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue,
                    .underlineColor: NSColor.controlAccentColor,
                    .backgroundColor: NSColor.selectedTextBackgroundColor,
                ], range: range)
            } else {
                attr.addAttribute(.underlineStyle,
                                  value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        client.setMarkedText(attr,
                             selectionRange: focusRange,
                             replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        DebugLog.write("BUNSETSU [" + clauses.enumerated()
            .map { ($0.0 == focusedClause ? "*" : "") + $0.1.surface }.joined(separator: "|") + "]")
    }

    private func presentClauseCandidates(_ client: IMKTextInput) {
        guard clauses.indices.contains(focusedClause),
              !clauses[focusedClause].candidates.isEmpty else { return }
        clauseWindowUp = true
        presentCandidates()
    }

    // Set the focused clause's selection to the candidate with this surface.
    private func selectClauseSurface(_ surface: String) {
        guard clauses.indices.contains(focusedClause) else { return }
        if let idx = clauses[focusedClause].candidates.firstIndex(where: { $0.text == surface }) {
            clauses[focusedClause].selected = idx
        }
    }

    // Enter : insert the whole sentence and feed each clause's chosen Candidate to
    // azooKey learning left-to-right, so sentence context chains correctly. Clauses
    // with no Candidate (raw-kana fallback) are skipped, like the flat-list commit.
    private func commitClauses(_ client: IMKTextInput) {
        hideCandidates()
        let text = clauses.map { $0.surface }.joined()
        client.insertText(text,
                          replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        if config.learning {
            for c in clauses where c.candidates.indices.contains(c.selected) {
                let cand = c.candidates[c.selected]
                kkConverter.updateLearningData(cand)
                kkConverter.setCompletedData(cand)
            }
        }
        appendHistory(text)
        reset(client)
    }

    // English/acronym to keep verbatim: matches config.latinVerbatimPattern
    // (default: a capitalized latin word — AI, LLM, Tokyo).
    private func latinVerbatim(_ s: String) -> String? {
        s.range(of: config.latinVerbatimPattern, options: .regularExpression) != nil ? s : nil
    }

    // azooKey conversion options: bundled default dictionary + Zenzai (zenz GGUF
    // shipped inside the app) + built-in learning persisted under Application
    // Support. shouldResetMemory wipes the learning once when the menu requests it.
    // `useZenzai: false` turns off the neural reranker (dictionary lattice only).
    // Used where we only need word boundaries (文節 splitting) — much faster — or to
    // recover homophones Zenzai drops from the full-coverage list (e.g. 返ってきた).
    private func convertOptions(useZenzai: Bool = true) -> ConvertRequestOptions {
        // Resources are shipped as plain folders inside the .app (codesign-clean),
        // referenced explicitly rather than via SwiftPM's Bundle.module (whose
        // accessor only looks beside the executable / .build path).
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let dictionary = resources.appendingPathComponent(config.dictionaryFolder, isDirectory: true)
        let support = Config.supportDir
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let zenzai: ConvertRequestOptions.ZenzaiMode
        let weight = resources.appendingPathComponent(config.modelFile)
        if useZenzai, FileManager.default.fileExists(atPath: weight.path) {
            zenzai = .on(weight: weight, inferenceLimit: config.inferenceLimit,
                         personalizationMode: personalizationMode())
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

    // Build Zenzai personalization (個人N-gram) if enabled AND both the bundled base
    // model and a trained personal model are present. Zenzai then blends "personal ÷
    // base" to lift your own vocabulary/phrasing. Returns nil (current behavior) when
    // disabled or either model is missing — so it's a no-op until you train one.
    private func personalizationMode() -> ConvertRequestOptions.ZenzaiMode.PersonalizationMode? {
        guard config.personalization else { return nil }
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let basePrefix = resources.appendingPathComponent("base_n5_lm/lm")
        let personalPrefix = Config.supportDir.appendingPathComponent("personal_lm/lm")
        let fm = FileManager.default
        guard fm.fileExists(atPath: basePrefix.path + "_c_abc.marisa"),
              fm.fileExists(atPath: personalPrefix.path + "_c_abc.marisa") else {
            DebugLog.write("PERSONALIZATION off (model missing) base=\(basePrefix.path) personal=\(personalPrefix.path)")
            return nil
        }
        DebugLog.write("PERSONALIZATION on alpha=\(config.personalizationAlpha) n=\(config.personalizationN)")
        return .init(baseNgramLanguageModel: basePrefix.path,
                     personalNgramLanguageModel: personalPrefix.path,
                     n: config.personalizationN, d: 0.75, alpha: config.personalizationAlpha)
    }

    // Append a committed sentence to the personalization history (one line per
    // sentence) so scripts/train_personal.sh can later train a personal N-gram.
    // Only sentences containing kana/kanji are kept (latin-only / symbol commits are
    // skipped). Local file only; see README on privacy.
    private func appendHistory(_ text: String) {
        guard config.personalization else { return }   // 個人最適化ON時のみ履歴を残す
        guard text.range(of: "[\\p{Hiragana}\\p{Katakana}\\p{Han}]",
                         options: .regularExpression) != nil,
              let data = (text + "\n").data(using: .utf8) else { return }
        let url = Config.supportDir.appendingPathComponent("personalization_history.txt")
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            fh.seekToEndOfFile(); fh.write(data)
        } else {
            try? FileManager.default.createDirectory(
                at: Config.supportDir, withIntermediateDirectories: true)
            try? data.write(to: url)
        }
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
    // The candidate texts currently driving the window: the focused clause's
    // candidates in 文節 mode, otherwise the flat candidateList.
    private func activeCandidateTexts() -> [String] {
        if mode == .bunsetsu, clauses.indices.contains(focusedClause) {
            return clauses[focusedClause].candidates.map { $0.text }
        }
        return candidateList
    }

    private func moveSelection(_ dir: Move) {
        let texts = activeCandidateTexts()
        guard let window = candidatesWindow, !texts.isEmpty else { return }
        let count = texts.count
        let cur = selectedCandidate.flatMap { texts.firstIndex(of: $0) } ?? 0
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
        let texts = activeCandidateTexts()
        DebugLog.write("candidates() queried -> \(texts.count) items")
        return texts
    }

    // User pressed Enter / clicked a row inside the candidate window.
    override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard let client = self.client() as? IMKTextInput else { return }
        if mode == .bunsetsu {
            // Choose this surface for the focused clause; stay in 文節 mode.
            selectClauseSurface(candidateString.string)
            hideCandidates(); clauseWindowUp = false
            renderBunsetsu(client)
            return
        }
        commit(candidateString.string, client)
    }

    // Highlight moved within the candidate window: mirror it inline.
    override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {
        DebugLog.write("selectionChanged -> \(candidateString.string)")
        selectedCandidate = candidateString.string
        guard let client = self.client() as? IMKTextInput else { return }
        if mode == .bunsetsu {
            selectClauseSurface(candidateString.string)
            renderBunsetsu(client)
            return
        }
        setMarked(candidateString.string, client)
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
        appendHistory(text)
        reset(client)
    }

    private func reset(_ client: IMKTextInput) {
        romajiBuffer = ""
        candidateList = []
        selectedCandidate = nil
        lastCandidates = []
        clauses = []
        focusedClause = 0
        clauseWindowUp = false
        mode = .composing
        hideCandidates()
        clearMarked(client)
    }

    // IMK calls this when focus changes etc. — flush whatever is composing.
    override func commitComposition(_ sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        if mode == .bunsetsu {
            commitClauses(client)
        } else if mode == .converting {
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
