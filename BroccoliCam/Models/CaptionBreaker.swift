import Foundation
import NaturalLanguage

/// 把一句話斷成一行一行的字幕。稿子和聽到的字用同一套。
/// 順序：句號問號一定斷，其餘在「停頓 → 逗號頓號 → 詞界」裡挑代價最小的切法。
enum CaptionBreaker {
    /// 停這麼久（秒），一行放得下也切開。
    static let longPause = 0.8
    /// 停這麼久，要切的話優先切這裡。
    static let shortPause = 0.25
    /// 沒有稿子時，停超過這麼久就當成一句話講完。
    static let sentencePause = 0.5
    /// 一行至少這麼寬，不然太零碎。
    private static let tinyWidth = 4.0
    /// 這個代價以下是停頓、逗號、中文間的空白；以上是詞界。
    private static let softCost = 3.0
    private static let wordCost = 5.0

    /// 一個字，以及它是第幾個會唸出來的音。標點、空白、符號沒有音。
    struct Glyph {
        let character: Character
        let key: Int?
    }

    struct Span {
        var start: Double
        var end: Double
    }

    struct Line {
        let text: String
        let glyphs: [Glyph]

        /// 這一行蓋到的音。一定連續，因為一行是連續的字。
        var keys: Range<Int>? {
            let all = glyphs.compactMap { $0.key }
            guard let first = all.first, let last = all.last else { return nil }
            return first..<(last + 1)
        }
    }

    private static let strongMarks: Set<Character> = ["。", "！", "？", "；", "!", "?", ";", "…", "⋯", "\n"]
    private static let weakMarks: Set<Character> = ["，", "、", "：", "—", "─", ",", ":"]
    private static let closers: Set<Character> = ["」", "』", "）", "》", "〉", "】", ")", "]", "}", "\u{201D}", "\u{2019}",
                                                  "%", "％", "℃", "°", "～"]
    private static let openers: Set<Character> = ["「", "『", "（", "《", "〈", "【", "(", "[", "{", "\u{201C}", "\u{2018}",
                                                  "$", "＄"]
    /// 不放在句首的語助詞。
    private static let particles: Set<Character> = ["的", "了", "嗎", "呢", "吧", "啊", "啦", "嘛", "喔", "呀", "耶"]

    /// 後面還有話的字，盡量不放在行尾（「都很忙卻｜覺得」）。
    private static let clinging: Set<Character> = [
        "我", "你", "他", "她", "它", "這", "那", "每", "一", "卻", "但", "和", "跟", "與", "就", "也", "都", "很",
        "在", "是", "把", "被", "讓", "給", "從", "對", "不", "沒", "要", "會"
    ]

    // MARK: - 切句

    static func glyphs(of text: String) -> [Glyph] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var result: [Glyph] = []
        var count = 0
        for character in normalized {
            if SpokenKeys.key(for: character) != nil {
                result.append(Glyph(character: character, key: count))
                count += 1
            } else {
                result.append(Glyph(character: character, key: nil))
            }
        }
        return result
    }

    /// 照句號、問號、換行切。沒有字可以唸的（單獨一個符號）丟掉。
    static func sentences(_ glyphs: [Glyph]) -> [[Glyph]] {
        var result: [[Glyph]] = []
        var current: [Glyph] = []
        func flush() {
            if current.contains(where: { $0.key != nil }) {
                result.append(current)
            }
            current = []
        }
        for (index, glyph) in glyphs.enumerated() {
            let character = glyph.character
            let previous: Character? = index > 0 ? glyphs[index - 1].character : nil
            let next: Character? = index + 1 < glyphs.count ? glyphs[index + 1].character : nil
            if strongMarks.contains(character) || isFullStop(character, previous: previous, next: next) {
                flush()
            } else if current.isEmpty, closers.contains(character), !result.isEmpty {
                // 「他說『好。』」的後引號跟著前一句走，不能跑到下一句開頭。
                result[result.count - 1].append(glyph)
            } else {
                current.append(glyph)
            }
        }
        flush()
        return result
    }

    /// 句子裡再照逗號頓號切成小段，回傳每一小段蓋到的音。對時用，不影響斷行。
    static func clauses(_ sentence: [Glyph]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var first: Int?
        var last = 0
        for (index, glyph) in sentence.enumerated() {
            if let key = glyph.key {
                if first == nil { first = key }
                last = key
                continue
            }
            let previous: Character? = index > 0 ? sentence[index - 1].character : nil
            let next: Character? = index + 1 < sentence.count ? sentence[index + 1].character : nil
            if isWeak(glyph.character, previous: previous, next: next), let lower = first {
                result.append(lower..<(last + 1))
                first = nil
            }
        }
        if let lower = first {
            result.append(lower..<(last + 1))
        }
        return result
    }

    /// 英文句點：前面是英文字母、後面不是接著的英數，才算一句話結束（3.5、domy.org 不算）。
    private static func isFullStop(_ character: Character, previous: Character?, next: Character?) -> Bool {
        guard character == ".", let previous, previous.isASCII, previous.isLetter else { return false }
        guard let next else { return true }
        return next.isWhitespace || !next.isASCII
    }

    /// 半形逗號冒號夾在英數中間（1,000、10:30、https:）不算停頓。
    private static func isWeak(_ character: Character, previous: Character?, next: Character?) -> Bool {
        guard weakMarks.contains(character) else { return false }
        guard character.isASCII, let previous, let next else { return true }
        let inside = previous.isASCII && !previous.isWhitespace && next.isASCII && !next.isWhitespace
        return !inside
    }

    // MARK: - 斷行

    private enum Joint {
        case none, space, weak
    }

    /// 不可以切開的一塊：一個詞、一個英文單字、一串數字，連同黏在旁邊的引號和語助詞。
    private struct Atom {
        var glyphs: [Glyph]
        var width: Double
        var after: Joint = .none

        var firstKey: Int? { glyphs.first(where: { $0.key != nil })?.key }
        var lastKey: Int? { glyphs.last(where: { $0.key != nil })?.key }
    }

    /// times 是每個音的時間，不知道的是 nil。forced 裡的音前面一定要換行。
    static func lines(_ sentence: [Glyph], maxChars: Int, times: [Span?], forced: Set<Int>,
                      boundaries: (String) -> Set<Int>) -> [Line] {
        let limit = Double(max(4, maxChars))
        let atoms = self.atoms(sentence, limit: limit, boundaries: boundaries)
        guard !atoms.isEmpty else { return [] }
        let count = atoms.count

        var mustBreak = [Bool](repeating: false, count: count + 1)
        for (index, atom) in atoms.enumerated() where index > 0 {
            if let first = atom.firstKey, let last = atom.lastKey,
               forced.contains(where: { $0 >= first && $0 <= last }) {
                mustBreak[index] = true
            }
        }

        // 每個切點的代價。停頓最便宜，詞界最貴。
        var jointCost = [Double](repeating: 0, count: count + 1)
        if count > 1 {
            for index in 1..<count {
                jointCost[index] = mustBreak[index]
                    ? 0 : cost(between: atoms[index - 1], and: atoms[index], times: times)
            }
        }

        var best = [Double](repeating: .infinity, count: count + 1)
        var origin = [Int](repeating: 0, count: count + 1)
        best[0] = 0
        for end in 1...count {
            var width = 0.0
            var start = end - 1
            // 這一行裡面有沒有跨過停頓或逗號。
            var crosses = false
            while start >= 0 {
                let joined = start < end - 1
                if joined && mustBreak[start + 1] { break }
                if joined && jointCost[start + 1] <= softCost { crosses = true }
                width += atoms[start].width
                if joined && atoms[start].after != .none { width += 0.5 }
                if joined && width > limit { break }

                let slack = max(0, (limit - width) / limit)
                var total = best[start] + 10 + 4 * slack * slack + jointCost[end]
                let isWhole = start == 0 && end == count
                if !isWhole {
                    if width < tinyWidth { total += 8 }
                    // 跨過逗號又斷在詞中間（「答案很簡單 因為你｜沒有先決定」），寧可在逗號那裡就換行。
                    let cutsEnd = end < count && jointCost[end] >= wordCost
                    let cutsStart = start > 0 && jointCost[start] >= wordCost
                    if crosses && (cutsEnd || cutsStart) { total += 14 }
                    if let first = atoms[start].firstKey, let last = atoms[end - 1].lastKey,
                       let from = times[first], let to = times[last],
                       to.end - from.start < CaptionAligner.minimumDuration {
                        total += 8
                    }
                }
                if total < best[end] {
                    best[end] = total
                    origin[end] = start
                }
                start -= 1
            }
        }

        var cuts: [Range<Int>] = []
        var end = count
        while end > 0 {
            cuts.append(origin[end]..<end)
            end = origin[end]
        }
        return cuts.reversed().map { line(from: Array(atoms[$0])) }
    }

    private static func cost(between left: Atom, and right: Atom, times: [Span?]) -> Double {
        var gap = 0.0
        if let last = left.lastKey, let first = right.firstKey, let from = times[last], let to = times[first] {
            gap = to.start - from.end
        }
        if gap >= longPause { return -14 }
        if gap >= shortPause { return 0 }
        switch left.after {
        case .weak:
            return 2
        case .space:
            let leftASCII = left.glyphs.last?.character.isASCII ?? false
            let rightASCII = right.glyphs.first?.character.isASCII ?? false
            return leftASCII && rightASCII ? wordCost : softCost
        case .none:
            guard let last = left.glyphs.last?.character else { return 6 }
            return clinging.contains(last) ? 9 : 6
        }
    }

    private static func line(from atoms: [Atom]) -> Line {
        var glyphs: [Glyph] = []
        for (index, atom) in atoms.enumerated() {
            glyphs.append(contentsOf: atom.glyphs)
            if index + 1 < atoms.count, atom.after != .none {
                glyphs.append(Glyph(character: " ", key: nil))
            }
        }
        return Line(text: text(of: glyphs), glyphs: glyphs)
    }

    private static func text(of glyphs: [Glyph]) -> String {
        String(glyphs.map { $0.character })
    }

    private static func atoms(_ sentence: [Glyph], limit: Double, boundaries: (String) -> Set<Int>) -> [Atom] {
        let cuts = boundaries(text(of: sentence))
        var result: [Atom] = []
        for (index, glyph) in sentence.enumerated() {
            let character = glyph.character
            let previous: Character? = index > 0 ? sentence[index - 1].character : nil
            let next: Character? = index + 1 < sentence.count ? sentence[index + 1].character : nil
            let tail = result.count - 1
            if character.isWhitespace {
                if tail >= 0, result[tail].after == .none { result[tail].after = .space }
                continue
            }
            if isWeak(character, previous: previous, next: next) {
                if tail >= 0 { result[tail].after = .weak }
                continue
            }
            let width = SubtitleLines.width(of: String(character))
            guard tail >= 0 else {
                result.append(Atom(glyphs: [glyph], width: width))
                continue
            }
            let isCloser = closers.contains(character)
            if result[tail].after == .space, particles.contains(character), cuts.contains(index + 1) {
                // 「ChatGPT 的」中間有空白，語助詞還是跟著前面走。
                result[tail].glyphs.append(Glyph(character: " ", key: nil))
                result[tail].glyphs.append(glyph)
                result[tail].width += width + 0.5
                result[tail].after = .none
                continue
            }
            if result[tail].after != .none, !isCloser {
                result.append(Atom(glyphs: [glyph], width: width))
                continue
            }
            let glued = isCloser || isGlued(character, after: previous, at: index, cuts: cuts)
            let bothASCII = character.isASCII && (previous?.isASCII ?? false)
            // 詞界給得太長（斷詞失靈），超過一行就硬切；英數不切。
            let overflow = result[tail].width + width > limit && !bothASCII && !isCloser
            if overflow || (cuts.contains(index) && !glued) {
                result.append(Atom(glyphs: [glyph], width: width))
            } else {
                result[tail].glyphs.append(glyph)
                result[tail].width += width
            }
        }
        return result
    }

    /// 這個字要黏著前一個字，不可以當一行的開頭。
    private static func isGlued(_ character: Character, after previous: Character?, at index: Int,
                                cuts: Set<Int>) -> Bool {
        guard let previous else { return false }
        if previous.isASCII && character.isASCII { return true }
        if openers.contains(previous) { return true }
        // 「100 元」「3 天」的數字跟著單位走。
        if previous.isASCII && previous.isNumber && character.isLetter { return true }
        // 「了解」「的確」開頭也是這些字，要整個詞就是那一個字才算語助詞。
        return particles.contains(character) && cuts.contains(index + 1)
    }

    static func isParticle(_ character: Character) -> Bool {
        particles.contains(character)
    }

    // MARK: - 詞界

    /// 系統斷詞。回傳可以切的位置（第幾個字之前），頭尾也算。
    static func wordBoundaries(_ text: String) -> Set<Int> {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(.traditionalChinese)
        var cuts: Set<Int> = [0, text.count]
        var cursor = text.startIndex
        var offset = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            offset += text.distance(from: cursor, to: range.lowerBound)
            cuts.insert(offset)
            offset += text.distance(from: range.lowerBound, to: range.upperBound)
            cuts.insert(offset)
            cursor = range.upperBound
            return true
        }
        return cuts
    }
}
