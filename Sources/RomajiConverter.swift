import Foundation

// Local, synchronous, instant romaji -> hiragana conversion used ONLY for the
// inline marked-text preview while the user types. It is intentionally simple:
// the real kana-kanji conversion (segmentation, kanji choice) is done by the LLM.
// Incomplete trailing romaji is left as-is so the user sees what they typed.
struct RomajiConverter {

    // `finalize` is set when the reading is about to be converted/committed
    // (not for the live preview): a trailing lone "n" becomes "ん" so words
    // ending in ん don't leak a latin "n" into the dictionary lookup.
    func toKana(_ input: String, finalize: Bool = false) -> String {
        let s = Array(input.lowercased())
        var out = ""
        var i = 0
        while i < s.count {
            // "tch" -> っ + ち系 (e.g. "matcha" -> まっちゃ)
            if s[i] == "t", i + 2 < s.count, s[i + 1] == "c", s[i + 2] == "h" {
                out += "っ"
                i += 1
                continue
            }
            // sokuon: doubled consonant (not n, not a vowel) -> っ
            if i + 1 < s.count, s[i] == s[i + 1], isConsonant(s[i]), s[i] != "n" {
                out += "っ"
                i += 1
                continue
            }
            // 撥音 ん handling
            if s[i] == "n" {
                if i + 1 < s.count, s[i + 1] == "n" || s[i + 1] == "'" {
                    out += "ん"
                    i += 2
                    continue
                }
                if i + 1 < s.count, isConsonant(s[i + 1]), s[i + 1] != "y" {
                    out += "ん"
                    i += 1
                    continue
                }
                if i + 1 == s.count {
                    // trailing single 'n': "ん" when finalizing, else keep as
                    // latin so the user can still type e.g. "na" -> な.
                    out += finalize ? "ん" : "n"
                    i += 1
                    continue
                }
                // else fall through to table (na/ni/nya/...)
            }
            // greedy longest match: try 3, then 2, then 1 chars
            var matched = false
            for len in stride(from: 3, through: 1, by: -1) where i + len <= s.count {
                let chunk = String(s[i..<(i + len)])
                if let kana = Self.table[chunk] {
                    out += kana
                    i += len
                    matched = true
                    break
                }
            }
            if !matched {
                // a lone consonant being typed -> keep latin until resolved
                out += String(s[i])
                i += 1
            }
        }
        return out
    }

    private func isConsonant(_ c: Character) -> Bool {
        return "bcdfghjklmpqrstvwxyz".contains(c)
    }

    private static let table: [String: String] = [
        // vowels
        "a": "あ", "i": "い", "u": "う", "e": "え", "o": "お",
        // k / g
        "ka": "か", "ki": "き", "ku": "く", "ke": "け", "ko": "こ",
        "ga": "が", "gi": "ぎ", "gu": "ぐ", "ge": "げ", "go": "ご",
        "kya": "きゃ", "kyu": "きゅ", "kyo": "きょ",
        "gya": "ぎゃ", "gyu": "ぎゅ", "gyo": "ぎょ",
        // s / z
        "sa": "さ", "si": "し", "shi": "し", "su": "す", "se": "せ", "so": "そ",
        "za": "ざ", "zi": "じ", "ji": "じ", "zu": "ず", "ze": "ぜ", "zo": "ぞ",
        "sha": "しゃ", "shu": "しゅ", "sho": "しょ",
        "sya": "しゃ", "syu": "しゅ", "syo": "しょ",
        "ja": "じゃ", "ju": "じゅ", "jo": "じょ",
        "jya": "じゃ", "jyu": "じゅ", "jyo": "じょ",
        "zya": "じゃ", "zyu": "じゅ", "zyo": "じょ",
        // t / d
        "ta": "た", "ti": "ち", "chi": "ち", "tu": "つ", "tsu": "つ", "te": "て", "to": "と",
        "da": "だ", "di": "ぢ", "du": "づ", "de": "で", "do": "ど",
        "cha": "ちゃ", "chu": "ちゅ", "cho": "ちょ",
        "cya": "ちゃ", "cyu": "ちゅ", "cyo": "ちょ",
        "tya": "ちゃ", "tyu": "ちゅ", "tyo": "ちょ",
        "tsa": "つぁ", "tse": "つぇ", "tso": "つぉ",
        // n
        "na": "な", "ni": "に", "nu": "ぬ", "ne": "ね", "no": "の",
        "nya": "にゃ", "nyu": "にゅ", "nyo": "にょ",
        // h / b / p / f
        "ha": "は", "hi": "ひ", "hu": "ふ", "fu": "ふ", "he": "へ", "ho": "ほ",
        "ba": "ば", "bi": "び", "bu": "ぶ", "be": "べ", "bo": "ぼ",
        "pa": "ぱ", "pi": "ぴ", "pu": "ぷ", "pe": "ぺ", "po": "ぽ",
        "hya": "ひゃ", "hyu": "ひゅ", "hyo": "ひょ",
        "bya": "びゃ", "byu": "びゅ", "byo": "びょ",
        "pya": "ぴゃ", "pyu": "ぴゅ", "pyo": "ぴょ",
        "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ",
        // m
        "ma": "ま", "mi": "み", "mu": "む", "me": "め", "mo": "も",
        "mya": "みゃ", "myu": "みゅ", "myo": "みょ",
        // y
        "ya": "や", "yu": "ゆ", "yo": "よ",
        // r
        "ra": "ら", "ri": "り", "ru": "る", "re": "れ", "ro": "ろ",
        "rya": "りゃ", "ryu": "りゅ", "ryo": "りょ",
        // w
        "wa": "わ", "wi": "うぃ", "we": "うぇ", "wo": "を",
        // v
        "va": "ゔぁ", "vi": "ゔぃ", "vu": "ゔ", "ve": "ゔぇ", "vo": "ゔぉ",
        // small vowels (xa / la)
        "xa": "ぁ", "xi": "ぃ", "xu": "ぅ", "xe": "ぇ", "xo": "ぉ",
        "la": "ぁ", "li": "ぃ", "lu": "ぅ", "le": "ぇ", "lo": "ぉ",
        "xtu": "っ", "ltu": "っ", "xtsu": "っ",
        // foreign-sound (外来語) syllables — without these, e.g. "zye"/"je"
        // (じぇ in プロジェクト) leak latin into the reading.
        "je": "じぇ", "jye": "じぇ", "zye": "じぇ",
        "che": "ちぇ", "she": "しぇ",
        "thi": "てぃ", "dhi": "でぃ", "thu": "てゅ", "dhu": "でゅ",
        "twu": "とぅ", "dwu": "どぅ",
        "tsi": "つぃ", "ye": "いぇ", "who": "うぉ",
        "kwa": "くぁ", "qa": "くぁ", "gwa": "ぐぁ", "fyu": "ふゅ",
        // punctuation
        "-": "ー", ".": "。", ",": "、", "[": "「", "]": "」",
    ]
}
